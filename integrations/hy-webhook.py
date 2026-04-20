#!/usr/bin/env python3
"""
Remnawave → Hysteria2 Webhook Sync + Subscription Proxy

Порт 8766 (localhost) — webhook сервис:
  POST /webhook          — вебхук от Remnawave
  GET  /health           — статус
  GET  /uri/:shortUuid   — персональный hy2:// URI

Порт 3020 (публичный) — reverse-proxy с инъекцией:
  GET  /*                — проксирует на subscription-page (:3010)
                           при совпадении User-Agent добавляет hy2://
"""

import base64
import hashlib
import hmac
import json
import logging
import os
import re
import subprocess
import sys
import threading
import time
import urllib.request
import urllib.error
from http.server import BaseHTTPRequestHandler, HTTPServer
from socketserver import ThreadingMixIn

class ThreadedHTTPServer(ThreadingMixIn, HTTPServer):
    """Многопоточный HTTP сервер — каждый запрос в отдельном потоке."""
    daemon_threads = True

# ── Конфиг ────────────────────────────────────────────────────────
WEBHOOK_SECRET  = os.environ.get("WEBHOOK_SECRET", "")
WEBHOOK_SECRET_HEADER = os.environ.get("WEBHOOK_SECRET_HEADER", "X-Remnawave-Signature")
HYSTERIA_CONFIG = os.environ.get("HYSTERIA_CONFIG", "/etc/hysteria/config.yaml")
USERS_DB        = os.environ.get("USERS_DB", "/var/lib/hy-webhook/users.json")
LISTEN_PORT     = int(os.environ.get("LISTEN_PORT", "8766"))
LISTEN_HOST     = os.environ.get("LISTEN_HOST", "0.0.0.0")
HYSTERIA_SVC    = os.environ.get("HYSTERIA_SVC", "hysteria-server")
REMNAWAVE_URL   = os.environ.get("REMNAWAVE_URL", "http://127.0.0.1:3000")
REMNAWAVE_TOKEN = os.environ.get("REMNAWAVE_TOKEN", "")
HY_DOMAIN       = os.environ.get("HY_DOMAIN", "")
HY_PORT         = os.environ.get("HY_PORT", "8443")
HY_NAME         = os.environ.get("HY_NAME", "Hysteria2")
URI_CACHE_TTL   = int(os.environ.get("URI_CACHE_TTL", "60"))
DEBUG_LOG       = os.environ.get("DEBUG_LOG", "")       # "1" для расширенного логирования

# Proxy настройки
PROXY_PORT      = int(os.environ.get("PROXY_PORT", "3020"))
UPSTREAM_URL    = os.environ.get("UPSTREAM_URL", "http://127.0.0.1:3010")

# User-Agent паттерны для инъекции
INJECT_UA_PATTERNS = [
    p.strip().lower()
    for p in os.environ.get(
        "INJECT_UA_PATTERNS",
        "hiddify,happ,nekobox,nekoray,v2rayng,sing-box,clash.meta,mihomo"
    ).split(",")
    if p.strip()
]

_LOG_LEVEL = logging.DEBUG if os.environ.get("DEBUG_LOG", "").lower() in ("1", "true", "yes") else logging.INFO
logging.basicConfig(
    level=_LOG_LEVEL,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)]
)
log = logging.getLogger("hy-webhook")

# ── TTL кэш (потокобезопасный) ────────────────────────────────────

class TTLCache:
    def __init__(self, ttl):
        self._ttl   = ttl
        self._store = {}
        self._lock  = threading.Lock()

    def get(self, key):
        with self._lock:
            e = self._store.get(key)
            if e is None:
                return None
            v, exp = e
            if time.monotonic() > exp:
                del self._store[key]
                return None
            return v

    def set(self, key, value):
        with self._lock:
            self._store[key] = (value, time.monotonic() + self._ttl)

    def clear(self):
        with self._lock:
            self._store.clear()

_uri_cache = TTLCache(URI_CACHE_TTL)

# ── Утилиты ───────────────────────────────────────────────────────

def load_users():
    os.makedirs(os.path.dirname(USERS_DB), exist_ok=True)
    try:
        with open(USERS_DB) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}

def save_users(users):
    os.makedirs(os.path.dirname(USERS_DB), exist_ok=True)
    with open(USERS_DB, "w") as f:
        json.dump(users, f, indent=2)

def gen_password(username):
    return hashlib.sha256(f"{username}:{WEBHOOK_SECRET}".encode()).hexdigest()[:32]

def reload_hysteria():
    """Перезапускает hysteria в фоне — не блокирует HTTP ответ вебхуку"""
    def _do():
        try:
            r = subprocess.run(
                ["systemctl", "reload-or-restart", HYSTERIA_SVC],
                capture_output=True, text=True, timeout=15
            )
            if r.returncode == 0:
                log.info("Hysteria2 перезапущен")
            else:
                log.warning(f"Ошибка перезапуска: {r.stderr}")
        except Exception as e:
            log.error(f"Не удалось перезапустить hysteria: {e}")
    threading.Thread(target=_do, daemon=True).start()

def update_hysteria_config(users):
    try:
        with open(HYSTERIA_CONFIG) as f:
            config = f.read()
        lines = ["  userpass:"]
        for u, p in users.items():
            safe = re.sub(r'[^\w\-.]', '_', u)
            lines.append(f'    {safe}: "{p}"')
        new_block = "\n".join(lines)
        pattern = r'(\s*userpass:\s*\n(?:\s+[^\n]+\n?)*)'
        if re.search(pattern, config):
            config = re.sub(pattern, "\n" + new_block + "\n", config)
        else:
            config = re.sub(
                r'(auth:\s*\n\s*type:\s*userpass\s*\n)',
                r'\1' + new_block + "\n",
                config
            )
        with open(HYSTERIA_CONFIG, "w") as f:
            f.write(config)
        log.info(f"Конфиг обновлён, пользователей: {len(users)}")
        return True
    except Exception as e:
        log.error(f"Ошибка обновления конфига: {e}")
        return False

def verify_signature(body, signature):
    if not WEBHOOK_SECRET:
        return True
    # Remnawave шлёт секрет в заголовке (имя задаётся через WEBHOOK_SECRET_HEADER),
    # либо HMAC-SHA256 подпись. Сначала пробуем прямое сравнение,
    # затем fallback на HMAC.
    if hmac.compare_digest(WEBHOOK_SECRET, signature):
        return True
    # Fallback: поддержка HMAC-SHA256 на случай других клиентов
    try:
        expected = hmac.new(WEBHOOK_SECRET.encode(), body, hashlib.sha256).hexdigest()
        return hmac.compare_digest(expected, signature.lower().replace("sha256=", ""))
    except Exception:
        return False

def get_hy_domain_port():
    domain, port = HY_DOMAIN, HY_PORT
    if not domain and os.path.exists(HYSTERIA_CONFIG):
        try:
            with open(HYSTERIA_CONFIG) as f:
                cfg = f.read()
            m = re.search(r'domains:\s*\n\s*-\s*(\S+)', cfg)
            if m:
                domain = m.group(1)
            m = re.search(r'^listen:\s*[^:]+:([\d]+(?:,[\d]+-[\d]+)?)', cfg, re.M)
            if m:
                port = m.group(1)
        except Exception:
            pass
    return domain, port

def remnawave_get_username(short_uuid):
    url = f"{REMNAWAVE_URL}/api/users/by-short-uuid/{short_uuid}"
    try:
        req = urllib.request.Request(url)
        if REMNAWAVE_TOKEN:
            req.add_header("Authorization", f"Bearer {REMNAWAVE_TOKEN}")
        req.add_header("X-Forwarded-For", "127.0.0.1")
        req.add_header("X-Forwarded-Proto", "https")
        with urllib.request.urlopen(req, timeout=5) as resp:
            data = json.loads(resp.read())
            return (data.get("response") or {}).get("username")
    except urllib.error.HTTPError as e:
        if e.code != 404:
            log.warning(f"Remnawave API {e.code} для {short_uuid}")
    except Exception as e:
        log.warning(f"Remnawave API ошибка: {e}")
    return None

def build_hy2_uri(username):
    users = load_users()
    safe = re.sub(r'[^\w\-.]', '_', username)
    password = users.get(safe) or users.get(username) or gen_password(username)
    domain, port = get_hy_domain_port()
    if not domain:
        log.warning("Домен Hysteria2 не определён")
        return None
    return f"hy2://{safe}:{password}@{domain}:{port}?sni={domain}&alpn=h3&insecure=0#{HY_NAME}"

def get_uri_for_short_uuid(short_uuid):
    cached = _uri_cache.get(short_uuid)
    if cached is not None:
        return cached if cached != "" else None
    username = remnawave_get_username(short_uuid)
    if not username:
        _uri_cache.set(short_uuid, "")
        return None
    uri = build_hy2_uri(username)
    _uri_cache.set(short_uuid, uri or "")
    log.info(f"URI для {username} (uuid={short_uuid[:8]}...)")
    return uri

# ── Base64 инъекция ───────────────────────────────────────────────

def inject_into_b64(body: bytes, extra: str) -> bytes:
    """Декодирует base64, добавляет строку, перекодирует."""
    stripped = bytes(b for b in body if b not in b' \t\r\n')
    try:
        decoded = base64.b64decode(stripped).decode("utf-8")
    except Exception:
        return body
    lines = [l for l in decoded.split("\n") if l.strip()]
    lines.append(extra)
    return base64.b64encode("\n".join(lines).encode("utf-8"))

def ua_matches(ua: str) -> bool:
    ua_lower = ua.lower()
    return any(p in ua_lower for p in INJECT_UA_PATTERNS)

def is_yaml_or_json(content_type: str) -> bool:
    ct = content_type.lower()
    return "yaml" in ct or "json" in ct

def extract_token(path: str) -> str | None:
    """Последний сегмент пути длиной >= 8: /sub/TOKEN → TOKEN."""
    segments = [s for s in path.split("?")[0].split("/") if s]
    if segments and len(segments[-1]) >= 8:
        return segments[-1]
    return None

# ── HTTP утилита (stdlib, без внешних зависимостей) ───────────────

HOP_BY_HOP = frozenset([
    "connection", "transfer-encoding", "trailer", "upgrade",
    "keep-alive", "content-length", "proxy-connection",
])

def upstream_get(url: str, headers: dict, timeout: int = 15):
    """GET к upstream. Возвращает (status, headers_dict, body_bytes)."""
    req = urllib.request.Request(url)
    for k, v in headers.items():
        if k.lower() not in HOP_BY_HOP:
            try:
                req.add_header(k, v)
            except Exception:
                pass
    req.add_header("Connection", "close")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, dict(resp.headers), resp.read()
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers), e.read()
    except Exception as e:
        log.warning(f"upstream error {url}: {e}")
        return 502, {}, b"Bad Gateway"

# ── Обработка событий вебхука ─────────────────────────────────────

def handle_user_created(username, users):
    if username in users:
        return False
    users[username] = gen_password(username)
    _uri_cache.clear()
    log.info(f"Добавлен: {username}")
    return True

def handle_user_deleted(username, users):
    safe = re.sub(r'[^\w\-.]', '_', username)
    changed = False
    for k in [username, safe]:
        if k in users:
            del users[k]
            changed = True
    if changed:
        _uri_cache.clear()
        log.info(f"Удалён: {username}")
    return changed

def process_event(payload):
    if payload.get("scope") != "user":
        return
    event    = payload.get("event", "")
    username = (payload.get("data") or {}).get("username", "")
    if not username:
        return
    log.info(f"Событие: {event}, пользователь: {username}")
    users = load_users()
    changed = False
    if event == "user.created":
        changed = handle_user_created(username, users)
    elif event in ("user.deleted", "user.disabled"):
        changed = handle_user_deleted(username, users)
    elif event in ("user.enabled", "user.revoked"):
        changed = handle_user_created(username, users)
    elif event == "user.modified":
        # При редактировании: добавляем если не было — покрывает старых пользователей
        if username not in users:
            log.info(f"user.modified: {username} не в users.json — добавляем")
            changed = handle_user_created(username, users)
        else:
            log.debug(f"user.modified: {username} уже есть, пропускаем")
    elif event == "user.expired":
        # Подписка истекла — отключаем доступ
        changed = handle_user_deleted(username, users)
    else:
        log.debug(f"Событие {event} не обрабатывается")
    if changed:
        save_users(users)
        # HTTP auth mode: hysteria спрашивает /auth при каждом подключении
        # перезапуск не нужен — пользователь появится автоматически
        update_hysteria_config(users)  # обновляем на случай fallback к userpass

# ── Webhook сервер (:8766) ──────────────────────────────────────

class WebhookHandler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        if self.path == "/health":
            users = load_users()
            domain, port = get_hy_domain_port()
            self._respond(200, json.dumps({
                "status":          "ok",
                "users":           len(users),
                "hysteria_domain": domain,
                "hysteria_port":   port,
                "proxy_port":      PROXY_PORT,
                "upstream":        UPSTREAM_URL,
                "auth_mode":       "http",
            }).encode(), "application/json")
            return

        m = re.match(r'^/uri/([A-Za-z0-9_\-]+)$', self.path)
        if m:
            uri = get_uri_for_short_uuid(m.group(1))
            if uri:
                self._respond(200, uri.encode(), "text/plain; charset=utf-8")
            else:
                self.send_response(204)
                self.end_headers()
            return

        self.send_response(404)
        self.end_headers()

    def do_POST(self):
        # ── Hysteria2 HTTP auth endpoint ──────────────────────────────
        if self.path == "/auth":
            length = int(self.headers.get("Content-Length", 0))
            body   = json.loads(self.rfile.read(length))
            addr   = body.get("addr", "")
            auth   = body.get("auth", "")
            # auth format: "username:password"
            if ":" in auth:
                username, password = auth.split(":", 1)
            else:
                username, password = auth, ""
            users = load_users()
            safe = re.sub(r"[^\w\-.]", "_", username)
            expected = users.get(safe) or users.get(username)
            if expected and expected == password:
                log.debug(f"Auth OK: {username} from {addr}")
                self._respond(200, json.dumps({"ok": True, "id": username}).encode(), "application/json")
            else:
                log.debug(f"Auth FAIL: {username} from {addr}")
                self._respond(200, json.dumps({"ok": False, "id": ""}).encode(), "application/json")
            return

        if self.path != "/webhook":
            self.send_response(404)
            self.end_headers()
            return
        length = int(self.headers.get("Content-Length", 0))
        body   = self.rfile.read(length)
        sig = self.headers.get(WEBHOOK_SECRET_HEADER, "")
        if WEBHOOK_SECRET and not verify_signature(body, sig):
            log.warning("Неверная подпись")
            self.send_response(401)
            self.end_headers()
            return
        try:
            process_event(json.loads(body))
            self._respond(200, b"ok", "text/plain")
        except json.JSONDecodeError:
            self.send_response(400)
            self.end_headers()
        except Exception as e:
            log.error(f"Ошибка: {e}")
            self.send_response(500)
            self.end_headers()

    def _respond(self, code, body, ct):
        self.send_response(code)
        self.send_header("Content-Type", ct)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

# ── Proxy сервер (0.0.0.0:3020) ───────────────────────────────────

class ProxyHandler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        ua       = self.headers.get("User-Agent", "")
        path     = self.path
        token    = extract_token(path)
        upstream = UPSTREAM_URL.rstrip("/") + path

        fwd = dict(self.headers)
        fwd["X-Forwarded-For"] = self.client_address[0]

        status, resp_headers, body = upstream_get(upstream, fwd)

        ct = resp_headers.get("Content-Type", resp_headers.get("content-type", ""))

        # Инъекция: UA совпадает, не YAML/JSON, есть токен, есть тело
        if ua_matches(ua) and not is_yaml_or_json(ct) and token and body:
            uri = get_uri_for_short_uuid(token)
            if uri:
                new_body = inject_into_b64(body, uri)
                if new_body is not body:  # инъекция прошла
                    body = new_body
                    log.info(f"Injected for token={token[:8]}... ua={ua[:30]}")

        self.send_response(status)
        for k, v in resp_headers.items():
            if k.lower() not in HOP_BY_HOP:
                try:
                    self.send_header(k, v)
                except Exception:
                    pass
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    do_HEAD    = do_GET
    do_OPTIONS = do_GET

def run_proxy():
    server = HTTPServer(("0.0.0.0", PROXY_PORT), ProxyHandler)
    log.info(f"Proxy :{PROXY_PORT} → {UPSTREAM_URL}")
    server.serve_forever()

# ── Точка входа ───────────────────────────────────────────────────

def main():
    log.info(f"hy-webhook :{LISTEN_PORT}  |  proxy :{PROXY_PORT} → {UPSTREAM_URL}")
    log.info(f"Remnawave: {REMNAWAVE_URL}  |  Hysteria: {HYSTERIA_CONFIG}")
    log.info(f"Секрет: {'✓' if WEBHOOK_SECRET else '✗'}  |  URI кэш: {URI_CACHE_TTL}с")
    log.info(f"UA паттерны: {INJECT_UA_PATTERNS}")

    users = load_users()
    if users:
        log.info(f"Загружено {len(users)} пользователей")
        update_hysteria_config(users)

    # Proxy в отдельном потоке (отключается если PROXY_PORT=0)
    if PROXY_PORT > 0:
        threading.Thread(target=run_proxy, daemon=True).start()
    else:
        log.info("Встроенный proxy отключён (PROXY_PORT=0) — используется внешний sub-injector")

    # Webhook сервер в главном потоке
    server = ThreadedHTTPServer((LISTEN_HOST, LISTEN_PORT), WebhookHandler)
    log.info("Готов")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("Остановка")

if __name__ == "__main__":
    main()
