#!/usr/bin/env python3
"""
Remnawave → Hysteria2 Webhook Sync Service
Слушает вебхуки Remnawave и синхронизирует пользователей с Hysteria2
"""

import hashlib
import hmac
import json
import logging
import os
import re
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

# ── Конфиг ────────────────────────────────────────────────────────
WEBHOOK_SECRET  = os.environ.get("WEBHOOK_SECRET", "")       # из .env панели WEBHOOK_SECRET_HEADER
HYSTERIA_CONFIG = os.environ.get("HYSTERIA_CONFIG", "/etc/hysteria/config.yaml")
USERS_DB        = os.environ.get("USERS_DB", "/var/lib/hy-webhook/users.json")
LISTEN_PORT     = int(os.environ.get("LISTEN_PORT", "8766"))
HYSTERIA_SVC    = os.environ.get("HYSTERIA_SVC", "hysteria-server")

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)]
)
log = logging.getLogger("hy-webhook")

# ── Утилиты ───────────────────────────────────────────────────────

def load_users() -> dict:
    """Загружает БД пользователей {username: password}"""
    os.makedirs(os.path.dirname(USERS_DB), exist_ok=True)
    try:
        with open(USERS_DB) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def save_users(users: dict):
    """Сохраняет БД пользователей"""
    os.makedirs(os.path.dirname(USERS_DB), exist_ok=True)
    with open(USERS_DB, "w") as f:
        json.dump(users, f, indent=2)


def gen_password(username: str) -> str:
    """Генерирует детерминированный пароль из username + секрет"""
    seed = f"{username}:{WEBHOOK_SECRET}"
    return hashlib.sha256(seed.encode()).hexdigest()[:32]


def reload_hysteria():
    """Перезапускает hysteria-server"""
    try:
        result = subprocess.run(
            ["systemctl", "reload-or-restart", HYSTERIA_SVC],
            capture_output=True, text=True, timeout=10
        )
        if result.returncode == 0:
            log.info("Hysteria2 перезапущен")
        else:
            log.warning(f"Ошибка перезапуска: {result.stderr}")
    except Exception as e:
        log.error(f"Не удалось перезапустить hysteria: {e}")


def update_hysteria_config(users: dict):
    """Обновляет блок userpass в конфиге Hysteria2"""
    try:
        with open(HYSTERIA_CONFIG) as f:
            config = f.read()

        # Строим новый блок userpass
        userpass_lines = ["  userpass:"]
        for username, password in users.items():
            # Экранируем специальные символы в имени
            safe_name = re.sub(r'[^\w\-.]', '_', username)
            userpass_lines.append(f'    {safe_name}: "{password}"')
        new_userpass = "\n".join(userpass_lines)

        # Заменяем существующий блок userpass
        pattern = r'(\s*userpass:\s*\n(?:\s+[^\n]+\n?)*)'
        if re.search(pattern, config):
            config = re.sub(pattern, "\n" + new_userpass + "\n", config)
        else:
            # Если нет — добавляем после auth:
            config = re.sub(
                r'(auth:\s*\n\s*type:\s*userpass\s*\n)',
                r'\1' + new_userpass + "\n",
                config
            )

        with open(HYSTERIA_CONFIG, "w") as f:
            f.write(config)

        log.info(f"Конфиг обновлён, пользователей: {len(users)}")
        return True
    except Exception as e:
        log.error(f"Ошибка обновления конфига: {e}")
        return False


def verify_signature(body: bytes, signature: str) -> bool:
    """Проверяет подпись вебхука"""
    if not WEBHOOK_SECRET:
        return True  # без секрета — принимаем всё
    expected = hmac.new(
        WEBHOOK_SECRET.encode(),
        body,
        hashlib.sha256
    ).hexdigest()
    return hmac.compare_digest(expected, signature.lower().replace("sha256=", ""))


# ── Обработка событий ─────────────────────────────────────────────

def handle_user_created(username: str, users: dict) -> bool:
    if username in users:
        log.info(f"Пользователь {username} уже существует")
        return False
    password = gen_password(username)
    users[username] = password
    log.info(f"Добавлен пользователь: {username}")
    return True


def handle_user_deleted(username: str, users: dict) -> bool:
    safe_name = re.sub(r'[^\w\-.]', '_', username)
    changed = False
    if username in users:
        del users[username]
        changed = True
    if safe_name in users and safe_name != username:
        del users[safe_name]
        changed = True
    if changed:
        log.info(f"Удалён пользователь: {username}")
    return changed


def handle_user_disabled(username: str, users: dict) -> bool:
    return handle_user_deleted(username, users)


def handle_user_enabled(username: str, users: dict) -> bool:
    return handle_user_created(username, users)


def process_event(payload: dict):
    """Обрабатывает вебхук событие"""
    scope = payload.get("scope", "")
    event = payload.get("event", "")
    data  = payload.get("data", {})

    if scope != "user":
        return

    username = data.get("username", "")
    if not username:
        log.warning("Нет username в payload")
        return

    log.info(f"Событие: {event}, пользователь: {username}")

    users = load_users()
    changed = False

    if event == "user.created":
        changed = handle_user_created(username, users)
    elif event == "user.deleted":
        changed = handle_user_deleted(username, users)
    elif event == "user.disabled":
        changed = handle_user_disabled(username, users)
    elif event in ("user.enabled", "user.revoked"):
        # revoked — отзыв подписки, но пользователь может восстановиться
        changed = handle_user_enabled(username, users)
    else:
        log.debug(f"Событие {event} не обрабатывается")
        return

    if changed:
        save_users(users)
        if update_hysteria_config(users):
            reload_hysteria()


# ── HTTP сервер ───────────────────────────────────────────────────

class WebhookHandler(BaseHTTPRequestHandler):

    def log_message(self, format, *args):
        pass  # подавляем стандартный лог

    def do_GET(self):
        if self.path == "/health":
            users = load_users()
            body = json.dumps({"status": "ok", "users": len(users)}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        if self.path != "/webhook":
            self.send_response(404)
            self.end_headers()
            return

        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length)

        # Проверяем подпись
        signature = self.headers.get("X-Webhook-Signature", "")
        if WEBHOOK_SECRET and not verify_signature(body, signature):
            log.warning("Неверная подпись вебхука")
            self.send_response(401)
            self.end_headers()
            return

        try:
            payload = json.loads(body)
            process_event(payload)
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok")
        except json.JSONDecodeError:
            log.error("Невалидный JSON")
            self.send_response(400)
            self.end_headers()
        except Exception as e:
            log.error(f"Ошибка обработки: {e}")
            self.send_response(500)
            self.end_headers()


def main():
    log.info(f"Запуск hy-webhook на порту {LISTEN_PORT}")
    log.info(f"Hysteria конфиг: {HYSTERIA_CONFIG}")
    log.info(f"БД пользователей: {USERS_DB}")
    log.info(f"Секрет: {'установлен' if WEBHOOK_SECRET else 'не установлен'}")

    # Синхронизируем текущих пользователей при старте
    users = load_users()
    if users:
        log.info(f"Загружено {len(users)} пользователей из БД")
        update_hysteria_config(users)

    server = HTTPServer(("127.0.0.1", LISTEN_PORT), WebhookHandler)
    log.info("Готов принимать вебхуки")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("Остановка")


if __name__ == "__main__":
    main()
