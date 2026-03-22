# server-manager — Инженерная документация

> Для разработчиков и DevOps-инженеров, работающих с кодом скрипта.

---

## hy-webhook.py — архитектура

### Endpoints

| Метод | Путь | Описание |
|---|---|---|
| `POST` | `/webhook` | Вебхук от Remnawave. Проверяет `X-Remnawave-Signature`, обрабатывает событие в фоновом потоке |
| `POST` | `/auth` | HTTP auth для Hysteria2. Формат: `{"auth": "username:password", "addr": "ip:port"}`. Отвечает `{"ok": true/false, "id": "username"}` |
| `GET` | `/uri/:shortUuid` | Персональный `hy2://` URI для sub-injector. Запрашивает username через Remnawave API, кэшируется TTL=60с |
| `GET` | `/health` | Статус: количество пользователей, домен/порт Hysteria2, режим proxy |

### Обрабатываемые события

| Событие | Действие |
|---|---|
| `user.created` | Добавить в `users.json`, обновить `config.yaml` |
| `user.deleted` | Удалить из `users.json`, обновить `config.yaml` |
| `user.disabled` | То же что `deleted` |
| `user.enabled` | То же что `created` |
| `user.revoked` | То же что `created` (пользователь может восстановиться) |
| `user.modified` | Добавить если нет в `users.json` — покрывает старых пользователей |
| `user.expired` | Удалить (то же что `deleted`) |

### Переменные окружения (`/etc/hy-webhook.env`)

| Переменная | По умолчанию | Описание |
|---|---|---|
| `WEBHOOK_SECRET` | — | Секрет из `WEBHOOK_SECRET_HEADER` в `.env` Remnawave |
| `LISTEN_PORT` | `8766` | Порт webhook сервера |
| `LISTEN_HOST` | `0.0.0.0` | Хост (0.0.0.0 — доступен из Docker через gateway) |
| `REMNAWAVE_URL` | `http://127.0.0.1:3000` | URL Remnawave API |
| `HYSTERIA_CONFIG` | `/etc/hysteria/config.yaml` | Путь к конфигу |
| `USERS_DB` | `/var/lib/hy-webhook/users.json` | БД пользователей |
| `PROXY_PORT` | `3020` | Порт встроенного proxy (0 = отключён) |
| `URI_CACHE_TTL` | `60` | TTL кэша `/uri/:shortUuid` в секундах |
| `DEBUG_LOG` | `0` | `1` — подробное логирование |
| `HY_DOMAIN` | auto | Домен Hysteria2 (авто из config.yaml) |
| `HY_PORT` | `8443` | Порт Hysteria2 (авто из config.yaml) |
| `HY_NAME` | `Hysteria2` | Название в `#` части URI |
| `INJECT_UA_PATTERNS` | hiddify,happ,... | UA паттерны для инъекции через встроенный proxy |

### HTTP auth vs userpass

```
userpass (старый режим):
  Пользователи в config.yaml → при добавлении нужен перезапуск hysteria
  → VPN соединения разрываются на ~30с

HTTP auth (рекомендуется):
  auth.type: http → hysteria делает POST /auth при каждом подключении
  → hy-webhook проверяет users.json без перезапуска
  → пользователи добавляются мгновенно, соединения не рвутся
```

Переключить режим: **Hysteria2 → Подписка → Интеграция → 2) Режим аутентификации**

---

## Архитектура

### Загрузка модулей

```bash
# server-manager.sh (точка входа)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "")"

# SHA256 контрольные суммы — заполните для защиты от компрометации репозитория
declare -A _MODULE_SHA256=(
    ["common"]=""   # sha256sum lib/common.sh | awk '{print $1}'
    ["panel"]=""
    ["telemt"]=""
    ["hysteria"]=""
    ["migrate"]=""
)

_load_module() {
    local mod="$1"
    local local_path="${SCRIPT_DIR}/lib/${mod}.sh"
    if [ -n "$SCRIPT_DIR" ] && [ -f "$local_path" ]; then
        source "$local_path"                        # локально из репо
    else
        local tmp; tmp=$(mktemp)
        curl -fsSL "${REPO_RAW}/lib/${mod}.sh" -o "$tmp"
        # Проверяем SHA256 если задан
        local expected="${_MODULE_SHA256[$mod]:-}"
        if [ -n "$expected" ]; then
            local actual; actual=$(sha256sum "$tmp" | awk '{print $1}')
            [ "$actual" = "$expected" ] || { rm -f "$tmp"; echo "SHA256 mismatch: $mod"; exit 1; }
        fi
        source "$tmp"; rm -f "$tmp"
    fi
}
```

При `curl | bash` — `SCRIPT_DIR` пустой, модули скачиваются с GitHub и опционально проверяются по SHA256. При локальном запуске — из `lib/`.

**Как получить SHA256 для релиза:**
```bash
for f in lib/*.sh; do echo "$(sha256sum $f | awk '{print $1}')  $(basename $f .sh)"; done
```

### Модули

| Файл | Строк | Экспортирует |
|---|---|---|
| `lib/common.sh` | 384 | `ok/info/warn/err`, `step/header/section`, `confirm/ask`, `gen_*`, `check_dns`, `spinner`, SSH-хелперы, `main_menu` |
| `lib/panel.sh` | 1780 | `panel_menu`, `panel_install`, `panel_submenu_*`, `panel_install_mgmt_script`, `panel_update_script` (вызывается из `main_menu`) |
| `lib/telemt.sh` | 703 | `telemt_main_menu`, `telemt_install`, `telemt_menu_*`, `telemt_submenu_*` |
| `lib/hysteria.sh` | 1213 | `hysteria_menu`, `hysteria_install`, `hysteria_*` |
| `lib/migrate.sh` | 250 | `migrate_menu`, `do_migrate`, `migrate_all` |
| `integrations/hy-webhook.py` | 444 | Webhook-сервис + `GET /uri/:shortUuid` + встроенный proxy |
| `integrations/hy-sub-install.sh` | 484 | Установка hy-webhook + sub-injector |
| `sub-injector/src/main.rs` | 897 | Rust reverse-proxy с per-user URI инъекцией |

---

## Архитектура меню

Все интерактивные меню используют `while true` вместо рекурсии:

```bash
panel_menu() {
    local ver; ver=$(get_remnawave_version 2>/dev/null || true)
    while true; do
        clear
        # ... отрисовка меню ...
        read -rp "  Выбор: " ch < /dev/tty
        case "$ch" in
            1) panel_submenu_install || true ;;  # || true обязателен при set -e
            0) return ;;
        esac
    done
}
```

**Правила:**
- Данные (версии, домены) загружаются **до** `while true` — один раз при входе
- Все вызовы функций в `case` имеют `|| true` — защита от `set -euo pipefail`
- `read -rp "..." < /dev/tty` — обязателен `< /dev/tty`, иначе read не ждёт при pipe-запуске

---

## Bandwidth и маскировка Hysteria2

### Bandwidth

Управление: **Hysteria2 → Управление → 4) 📶 Bandwidth**

Hysteria2 поддерживает два режима управления скоростью:

| Режим | Когда использовать |
|---|---|
| **Без bandwidth** (BBR) | Обычное использование. BBR автоматически подбирает скорость. Рекомендуется если не знаете параметры канала |
| **С bandwidth** (Brutal) | Нестабильный канал с потерями пакетов. Позволяет задать фиксированную скорость — Hysteria2 будет агрессивно держать её даже при потерях |

**Какую скорость ставить:**

Указывайте скорость **серверного канала**, не клиентского. Не завышайте — если задать больше реального канала, Brutal будет перегружать сеть.

```
Сервер 1 Гбит/с      → up: 1 gbps    / down: 1 gbps
Сервер 500 Мбит/с    → up: 500 mbps  / down: 500 mbps
Сервер 100 Мбит/с    → up: 100 mbps  / down: 100 mbps
Выделенный канал     → up: реальный  / down: реальный
```

Форматы значений: `100 mbps`, `1 gbps`, `500 mbps`.

**Важно:** `bandwidth` в конфиге сервера — это лимит на весь сервер, не на одного клиента. Клиент в своём конфиге тоже может задать bandwidth — тогда используется минимум из двух.

**Результат в логах:** при правильно заданном bandwidth клиент подключается с `tx: N` вместо `tx: 0`.

---

### Маскировка (masquerade)

Управление: **Hysteria2 → Управление → 5) 🎭 Маскировка**

Маскировка заставляет Hysteria2 отвечать как обычный HTTPS-сайт на запросы браузеров и DPI-систем. Без маскировки QUIC трафик может быть идентифицирован как Hysteria2.

| Тип | Описание |
|---|---|
| `proxy` | Проксирует запросы на реальный сайт. Самый надёжный вариант |
| `file` | Отдаёт статические файлы из директории |

**Какой сайт выбрать:**

| Сайт | Когда подходит |
|---|---|
| **Bing** | Рекомендуется по умолчанию. Стабильный, быстрый, популярный |
| **Apple CDN** | Хорошо для iOS клиентов — трафик выглядит как Apple сервисы |
| **Hetzner Speed** | Если сервер в Германии — органично выглядит |
| **Свой URL** | Если есть свой сайт на том же IP — идеально |

**Текущая ситуация:** маскировка в вашем конфиге не задана. Рекомендуется включить через меню → выбрать Bing.

---

## API Remnawave — используемые эндпоинты

Все запросы идут на `http://127.0.0.1:3000` с заголовками:
```
Authorization: Bearer <JWT>
X-Forwarded-For: 127.0.0.1
X-Forwarded-Proto: https
Content-Type: application/json
```

| Метод | Путь | Назначение |
|---|---|---|
| POST | `/api/auth/login` | Получить JWT токен |
| GET | `/api/system/tools/x25519/generate` | Сгенерировать Reality ключи |
| GET | `/api/keygen` | Получить публичный ключ панели |
| DELETE | `/api/config-profiles/:uuid` | Удалить дефолтный профиль |
| POST | `/api/config-profiles` | Создать профиль StealConfig |
| POST | `/api/nodes` | Создать ноду с `activeInbounds` |
| POST | `/api/hosts` | Создать хост для подключений |
| GET | `/api/internal-squads` | Получить дефолтный squad |
| PATCH | `/api/internal-squads` | Добавить inbound в squad |
| POST | `/api/tokens` | Создать API токен |
| GET | `/api/users/by-short-uuid/:uuid` | Получить пользователя по shortUuid |

### Функция panel_api

```bash
panel_api() {
    local method="$1" url="$2" token="$3" body="${4:-}"
    local args=(-s -X "$method" "$url"
        -H "Authorization: Bearer $token"
        -H "X-Forwarded-For: 127.0.0.1"
        -H "X-Forwarded-Proto: https"
        -H "Content-Type: application/json")
    [ -n "$body" ] && args+=(-d "$body")
    curl "${args[@]}"
}
```

---

## Selfsteal архитектура — детально

### Схема трафика

```
Клиент (VLESS+Reality)
    │
    ▼ TCP :443
Xray (rw-core, process на хосте)
  - Reality handshake: privateKey + serverNames + shortIds
  - dest: /dev/shm/nginx.sock
  - xver: 1 (proxy_protocol v1)
    │
    ▼ unix:/dev/shm/nginx.sock (proxy_protocol)
nginx (Docker, network_mode: host)
  - listen unix:/dev/shm/nginx.sock ssl proxy_protocol
  - X-Real-IP: $proxy_protocol_addr
    │
    ▼ http://127.0.0.1:3000
Remnawave Panel (Docker, порт 3000)
```

### Порядок запуска

1. `docker compose up -d` — стартуют все контейнеры
2. nginx создаёт `/dev/shm/nginx.sock` при старте
3. Remnawave Panel регистрирует ноду на `172.30.0.1:2222`
4. Нода (remnanode) получает конфиг с inbound `Steal` (порт 443)
5. Xray стартует, занимает `:443`, начинает писать в nginx.sock

### Почему nginx НЕ слушает 443 в MODE=1

Xray должен быть первым получателем на порту 443 — он проводит Reality handshake и определяет легитимных клиентов. Только после этого трафик уходит в nginx через unix-сокет. Если nginx занимает 443 — Xray не может стартовать.

### Диагностика selfsteal

```bash
# 1. Сокет существует?
ls -la /dev/shm/nginx.sock

# 2. Xray занял 443?
ss -tlnp | grep :443
# Должно показать rw-core, НЕ nginx

# 3. Нода получила конфиг?
docker logs remnanode --tail=20 | grep -E "Xray started|SPAWN_ERROR|inbounds"

# 4. Конфиг который получает Xray
docker exec remnanode sh -c '
SOCK=$(ls /run/remnawave-internal-*.sock 2>/dev/null | head -1)
python3 -c "
import socket, json
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(\"$SOCK\")
# NOTE: токен меняется при каждом рестарте, берём из /proc
import subprocess
token = subprocess.getoutput(\"cat /proc/\$(pgrep rw-core)/cmdline 2>/dev/null | tr \\\\0 \\\\n | grep token | cut -d= -f2\")
s.send(f\"GET /internal/get-config?token={token} HTTP/1.0\r\nHost: localhost\r\n\r\n\".encode())
d = b\"\"
while True:
    c = s.recv(4096)
    if not c: break
    d += c
body = d.split(b\"\r\n\r\n\",1)[1]
print(json.dumps(json.loads(body).get(\"inbounds\",[]), indent=2))
"
'
```

---

## hy-webhook + sub-injector — архитектура интеграции

### Схема

```
Remnawave (user.created/deleted/disabled/enabled)
    │
    ▼ POST http://172.30.0.1:8766/webhook
    │  Header: X-Remnawave-Signature: HMAC-SHA256(body, secret)
    │
hy-webhook.py (systemd, :8766 на 0.0.0.0)
    │  1. Verify: HMAC-SHA256(body, WEBHOOK_SECRET) == X-Remnawave-Signature
    │  2. gen_password(username, secret): sha256(u:s)[:32]
    │  3. update users.json
    │  4. _respond(200) — немедленный ответ Remnawave (фоновая обработка)
    │  5. НЕТ перезапуска hysteria (HTTP auth mode)
    │  6. TTL-кэш URI сбрасывается (_uri_cache.clear())
    │
    │  POST /auth (вызывается Hysteria2 при каждом подключении клиента)
    │  1. body: {"addr": "ip:port", "auth": "username:password", "tx": N}
    │  2. Читает users.json, проверяет password
    │  3. Возвращает {"ok": true, "id": username} или {"ok": false}
    │  Преимущество: пользователи добавляются БЕЗ перезапуска hysteria
    │
    │  GET /uri/:shortUuid (вызывается sub-injector)
    │  1. TTL-кэш: URI_CACHE_TTL (по умолчанию 60 сек)
    │  2. GET {REMNAWAVE_URL}/api/users/by-short-uuid/:uuid
    │     Заголовки: Authorization, X-Forwarded-For, X-Forwarded-Proto
    │  3. Читает users.json, находит пароль по username
    │  4. Возвращает hy2://username:pass@domain:port?sni=...&alpn=h3
    │  5. 204 если пользователь не найден
    │
    │  Proxy :3020 (встроенный reverse-proxy, PROXY_PORT=0 = выключен)
    │  1. Принимает запросы клиентов
    │  2. Проверяет User-Agent по INJECT_UA_PATTERNS
    │  3. Если UA совпал + не YAML/JSON → GET /uri/TOKEN
    │  4. Инжектирует hy2:// URI в base64 ответ
    │  5. Проксирует на UPSTREAM_URL (:3010)

sub-injector (Rust/Tokio, :3020)
    │  Основной proxy — заменяет встроенный Python proxy
    │  per_user_url = "http://127.0.0.1:8766/uri"
    │  Извлекает token из пути /TOKEN, GET /uri/TOKEN → URI

nginx sub домен → :3020 (sub-injector или hy-webhook proxy)
```

### HTTP auth vs userpass — почему это важно

При `userpass` режиме: каждое изменение `config.yaml` требует `systemctl restart hysteria-server`.
Перезапуск занимает ~1с, но **разрывает все активные QUIC/UDP соединения**.
Если клиент подключён к панели через Hysteria VPN — браузер теряет связь на 20-30с.

При `http` режиме: hysteria делает `POST /auth` к hy-webhook при каждом новом подключении.
Пользователи добавляются/удаляются мгновенно, без перезапуска сервиса.

Конфиг `/etc/hysteria/config.yaml`:
```yaml
auth:
  type: http
  http:
    url: http://127.0.0.1:8766/auth
    insecure: false
```

### Два режима proxy: встроенный Python vs sub-injector (Rust)

| | hy-webhook встроенный proxy | sub-injector |
|---|---|---|
| Язык | Python (однопоточный) | Rust/Tokio (async) |
| Конфиг | `/etc/hy-webhook.env` | `/opt/remna-sub-injector/config.toml` |
| Производительность | Достаточно для малой нагрузки | Тысячи RPS |
| Настройка UA | `INJECT_UA_PATTERNS` env | `[[injections]]` в TOML |
| Установка | Уже в hy-webhook | Отдельный бинарник |

В `hy-sub-install.sh` по умолчанию устанавливается sub-injector. Встроенный proxy в hy-webhook — запасной вариант.

### UFW — почему 172.16.0.0/12

Docker использует подсети из `172.16.0.0/12` по умолчанию. `remnawave-network` сконфигурирована как `172.30.0.0/16`. Gateway сети (`172.30.0.1`) — это IP хоста внутри Docker сети. Правило `172.16.0.0/12` покрывает все возможные Docker подсети.

```bash
# Проверить gateway текущей сети
docker network inspect remnawave-network | grep Gateway

# Проверить что webhook доступен из контейнера
docker exec remnawave curl -s http://172.30.0.1:8766/health
```

### sub-injector — конфиг

```toml
upstream_url = "http://127.0.0.1:3010"
bind_addr = "0.0.0.0:3020"

[[injections]]
header = "User-Agent"
contains = ["hiddify", "happ", "nekobox", "nekoray", "v2rayng"]
per_user_url = "http://127.0.0.1:8766/uri"
# Инжектор извлекает token из пути запроса и делает:
# GET http://127.0.0.1:8766/uri/{token} → персональный hy2:// URI

# Для статичных URI (MTProxy, общие ссылки):
# links_source = "/data/mtproxy-links.txt"
```

Поля `per_user_url` и `links_source` опциональны и могут комбинироваться. `per_user_url` имеет приоритет.

### Переменные окружения hy-webhook

Файл: `/etc/hy-webhook.env` (права 600)

| Переменная | Значение по умолчанию | Описание |
|---|---|---|
| `WEBHOOK_SECRET` | hex64 | Ключ для HMAC-SHA256 верификации подписи |
| `HYSTERIA_CONFIG` | `/etc/hysteria/config.yaml` | Путь к конфигу |
| `USERS_DB` | `/var/lib/hy-webhook/users.json` | База пользователей |
| `LISTEN_PORT` | `8766` | Порт webhook-сервера |
| `LISTEN_HOST` | `0.0.0.0` | Интерфейс (0.0.0.0 для доступа из Docker) |
| `HYSTERIA_SVC` | `hysteria-server` | Имя systemd сервиса |
| `REMNAWAVE_URL` | `http://127.0.0.1:3000` | URL Remnawave API |
| `REMNAWAVE_TOKEN` | — | API токен для `/uri/:shortUuid` |
| `HY_DOMAIN` | — | Домен Hysteria2 (в URI) |
| `HY_PORT` | `8443` | Порт Hysteria2 (в URI) |
| `HY_NAME` | `Hysteria2` | Название в URI |
| `URI_CACHE_TTL` | `60` | TTL кэша URI в секундах |
| `PROXY_PORT` | `3020` | Порт встроенного proxy (0 = отключить) |
| `UPSTREAM_URL` | `http://127.0.0.1:3010` | Upstream subscription-page |
| `INJECT_UA_PATTERNS` | `hiddify,happ,...` | UA паттерны для встроенного proxy |
| `DEBUG_LOG` | — | `1` для уровня DEBUG в journalctl |

### Многопоточность и блокировка

hy-webhook использует `ThreadingMixIn + HTTPServer` (`ThreadedHTTPServer`) — каждый входящий запрос обрабатывается в отдельном потоке. Это критично потому что:

1. Remnawave шлёт вебхук и ждёт HTTP ответ (таймаут ~5с)
2. После получения вебхука hy-webhook перезапускает Hysteria2 (`systemctl reload-or-restart`) — это занимает 2-4с
3. При однопоточном сервере следующий запрос ждёт пока предыдущий не завершится → панель зависает

Перезапуск Hysteria2 выполняется в daemon-потоке (`threading.Thread(daemon=True)`) — HTTP ответ `200 ok` отправляется сразу, не дожидаясь завершения перезапуска.

### Верификация подписи Remnawave

Remnawave отправляет подпись в заголовке `X-Remnawave-Signature` как `HMAC-SHA256(request_body, WEBHOOK_SECRET_HEADER)`. Значение `WEBHOOK_SECRET_HEADER` из `.env` панели используется как ключ HMAC.

```python
expected = hmac.new(WEBHOOK_SECRET.encode(), body, hashlib.sha256).hexdigest()
hmac.compare_digest(expected, signature.lower())
```

**Важно:** `WEBHOOK_SECRET` в `/etc/hy-webhook.env` должен совпадать с `WEBHOOK_SECRET_HEADER` в `/opt/remnawave/.env`.

---

## Структура docker-compose.yml

### remnanode — критически важные настройки

```yaml
remnanode:
  image: remnawave/node:latest
  network_mode: host          # обязательно! нода должна видеть 127.0.0.1:3000
  environment:
    - NODE_PORT=2222
    - SECRET_KEY="<base64 JWT>"   # публичный ключ панели
  volumes:
    - /dev/shm:/dev/shm:rw        # для unix-сокета nginx
    - /etc/ssl/certs/hysteria:/etc/ssl/certs/hysteria:ro
```

> `network_mode: host` — нода обращается к панели через `172.30.0.1:2222` (gateway Docker сети), а не через внутреннюю Docker сеть.

### remnawave-nginx — критически важные настройки

```yaml
remnawave-nginx:
  image: nginx:1.28
  network_mode: host            # обязательно! nginx должен видеть 127.0.0.1:3000 и unix-сокет
  command: sh -c 'rm -f /dev/shm/nginx.sock && exec nginx -g "daemon off;"'
  volumes:
    - /dev/shm:/dev/shm:rw      # unix-сокет shared с хостом и remnanode
```

### remnawave-subscription-page — обязательные переменные

```yaml
remnawave-subscription-page:
  image: remnawave-sub-hy:local   # наш форк, собранный локально
  environment:
    - REMNAWAVE_PANEL_URL=http://remnawave:3000   # внутри Docker сети
    - REMNAWAVE_API_TOKEN=<JWT>                   # API токен subscription-page
    - HY_DOMAIN=cdn.example.com
    - HY_PORT=8443
    - HY_NAME=🇩🇪 Germany Hysteria2
    - HY_USERS_DB=/var/lib/hy-webhook/users.json
  volumes:
    - /var/lib/hy-webhook:/var/lib/hy-webhook:ro
```

---

## Отладка частых проблем

### SPAWN_ERROR: xray / address already in use

```bash
# Кто занимает 443?
ss -tlnp | grep :443

# Если nginx — значит nginx.conf содержит listen 443 ssl в MODE=1
# Исправление:
grep "listen 443" /opt/remnawave/nginx.conf
# Должно быть ПУСТО для selfsteal режима
```

### inbounds:[] — нода получает пустой конфиг

```bash
# Проверить что нода создана с activeInbounds
curl -s http://127.0.0.1:3000/api/nodes \
  -H "Authorization: Bearer <TOKEN>" \
  -H "X-Forwarded-For: 127.0.0.1" \
  -H "X-Forwarded-Proto: https" | python3 -m json.tool | grep -A5 "activeInbounds"

# Если пусто — в панели: Nodes → редактировать → убедиться что inbound отмечен активным
# Или через API PATCH /api/nodes/:uuid с activeInbounds: [inbound_uuid]
```

### hy-webhook не получает события от Remnawave

```bash
# 1. Webhook URL в .env
grep "WEBHOOK" /opt/remnawave/.env
# WEBHOOK_URL должен быть http://172.30.0.1:8766/webhook, НЕ 127.0.0.1

# 2. Доступность из контейнера
docker exec remnawave curl -s http://172.30.0.1:8766/health

# 3. UFW разрешает Docker?
ufw status | grep 8766

# 4. hy-webhook слушает на 0.0.0.0?
ss -tlnp | grep 8766
# Должно быть 0.0.0.0:8766, НЕ 127.0.0.1:8766

# Если 127.0.0.1 — добавить в /etc/hy-webhook.env:
echo "LISTEN_HOST=0.0.0.0" >> /etc/hy-webhook.env
systemctl restart hy-webhook
```

### sub-injector не инжектирует URI

```bash
# 1. Сервис запущен?
systemctl status remna-sub-injector
journalctl -u remna-sub-injector -n 30

# 2. /uri endpoint отвечает?
curl -s http://127.0.0.1:8766/uri/TEST_TOKEN
# 200 с hy2:// или 204 если токен не найден

# 3. nginx направляет на :3020?
grep "3020\|3010" /opt/remnawave/nginx.conf

# 4. Тест инъекции вручную
curl -s -H "User-Agent: hiddify" http://127.0.0.1:3020/sub/TOKEN | base64 -d | grep hy2://
```

### Пользователь не появляется в Hysteria2 при создании в панели

```bash
# 1. Вебхук доходит?
journalctl -u hy-webhook -n 20

# 2. Синхронизировался?
cat /var/lib/hy-webhook/users.json

# 3. Hysteria2 перезапустился?
systemctl status hysteria-server | grep Active
```

---

## Полезные команды для разработки

```bash
# Синтаксис всех модулей
for f in server-manager.sh lib/*.sh; do
    bash -n "$f" && echo "✓ $f" || echo "✗ $f"
done

# Тест загрузки без запуска
python3 -c "
import subprocess
with open('server-manager.sh') as f:
    content = f.read().replace('check_root\nmain_menu', 'echo OK\nexit 0')
with open('/tmp/test.sh', 'w') as f:
    f.write(content)
r = subprocess.run(['bash', '/tmp/test.sh'], capture_output=True, text=True, cwd='.')
print(r.stdout, r.stderr)
"

# Обновить версию в CHANGELOG и закоммитить
git add -A
git commit -m "fix: описание"
git push
# Версия скрипта обновится автоматически из git commit date
```

---



---

## Changelog инженерных решений

| Дата | Решение | Причина |
|---|---|---|
| 2026-03-21 | HTTP auth в hysteria вместо userpass | Перезапуск hysteria разрывал VPN соединения на 30с |
| 2026-03-21 | `POST /auth` эндпоинт в hy-webhook | hysteria проверяет пользователей без перезапуска |
| 2026-03-21 | `X-Forwarded-For/Proto` в API запросах | Remnawave отклонял запросы без reverse proxy заголовков |
| 2026-03-21 | `_respond(200)` до фоновой обработки | Remnawave получал ответ через 3-5с вместо мгновенного |
| 2026-03-21 | `ThreadedHTTPServer` в hy-webhook | Панель зависала на 3-5с при создании пользователя |
| 2026-03-21 | `reload_hysteria()` в daemon-потоке | HTTP ответ не должен ждать перезапуска Hysteria2 |
| 2026-03-21 | Заголовок `X-Remnawave-Signature` | Remnawave использует этот заголовок, не `X-Webhook-Signature` |
| 2026-03-21 | HMAC-SHA256 верификация | Remnawave подписывает body через HMAC, не plain-text |
| 2026-03-21 | `LISTEN_HOST=0.0.0.0` в hy-webhook | Docker не мог достучаться до `127.0.0.1:8766` хоста |
| 2026-03-21 | sub-injector (Rust) вместо форка TypeScript | Форк ломался при каждом обновлении upstream subscription-page |
| 2026-03-21 | `GET /uri/:shortUuid` в hy-webhook + TTL-кэш | sub-injector запрашивает персональный URI для каждого токена |
| 2026-03-21 | Встроенный proxy :3020 в hy-webhook | Запасной вариант без установки sub-injector |
| 2026-03-20 | nginx MODE=1: убран `listen 443 ssl` | Xray не мог занять порт 443 |
| 2026-03-20 | LISTEN_HOST=0.0.0.0 в hy-webhook | Docker контейнеры не видели localhost хоста |
| 2026-03-20 | UFW 172.16.0.0/12 → 8766 | Блокировка трафика от Docker к хосту |
| 2026-03-20 | WEBHOOK_URL=http://172.30.0.1:8766 | 127.0.0.1 из контейнера — это сам контейнер |
| 2026-03-20 | Python heredoc: quoted markers | bash парсил Python как bash-код |
| 2026-03-19 | Нода с activeInbounds через API | Без activeInbounds нода получала пустой конфиг |
| 2026-03-18 | API URL: by-short-uuid вместо get-by | Устаревший URL в исходниках subscription-page |

---

## Потребление RAM — анализ

### Реальные данные (сервер 1.92 GB RAM, полный стек)

```
docker stats (фактическое потребление):
  remnawave (NestJS)         395 MB   ← главный потребитель
  remnanode (Xray rw-core)    88 MB
  subscription-page           76 MB
  remnawave-db (Postgres)     50 MB
  remnawave-redis              6 MB
  remnawave-nginx              5 MB

systemctl (systemd сервисы):
  telemt                      18 MB   (peak 84 MB, swap 47 MB)
  hysteria2                   17 MB   (peak 53 MB, swap  4 MB)
  hy-webhook (python3)         1 MB   (peak 12 MB, swap 10 MB)

postgres worker processes (хост):
  13 процессов × ~15 MB     195 MB   ← max_connections=100 по умолчанию

Итого: ~850 MB из 1.92 GB (44%)
swap использован: ~146 MB
```

### Сравнение с eGames

**Различий нет.** eGames и server-manager генерируют идентичный docker-compose:
- те же образы (`remnawave/backend:2`, `postgres:18.1`, `valkey/valkey:9.0.0-alpine`)
- те же `ulimits: nofile: 1048576`
- нет `mem_limit` ни там ни тут
- нет `NODE_OPTIONS` ни там ни тут
- нет postgres-настроек (`max_connections`, `shared_buffers`) ни там ни тут

395 MB для remnawave — норма для NestJS + BullMQ + TypeORM + PM2 cluster. Снизить невозможно без изменения самого образа.

### Источник данных RAM в панели

Панель показывает RAM через **Xray gRPC Stats API**:
```
remnanode → GetSysStats (:61000) → /proc/meminfo хоста
```
`remnanode` работает с `network_mode: host`, поэтому видит `/proc/meminfo` хоста напрямую. Это системная RAM — всё что занято на хосте, включая Docker, systemd, ядро, buff/cache.

### Потенциальные оптимизации (не реализованы в скрипте)

| Оптимизация | Экономия | Как |
|---|---|---|
| `max_connections=25` в Postgres | ~120 MB | `command: postgres -c max_connections=25 -c shared_buffers=32MB` в docker-compose |
| Swap 2 GB | 0 MB (но предотвращает OOM) | `fallocate -l 2G /swapfile` |
| `mem_limit: 256m` для subscription-page | 0 MB (safety net) | docker-compose |

> Postgres workers — самая реальная экономия. 13 процессов при max_connections=100 это дефолт. Remnawave использует PgBouncer или прямой TypeORM pool — хватит 20-25 соединений.

### Рекомендации по серверу

| RAM | Стек | Комментарий |
|---|---|---|
| 1 GB | ❌ | Не хватит — только remnawave требует ~400 MB |
| 2 GB | ⚠️ | Работает, но в пике уходит в swap. Нужен swap ≥1 GB |
| 4 GB | ✅ | Комфортно для полного стека + запас |
| 8 GB | ✅✅ | Для нескольких нод или высокой нагрузки |

---

## Анализ кода — сравнение с eGames и общие рекомендации

### 🔴 Баги (исправлено)

#### panel_api() не была определена [lib/panel.sh]
`panel_install()` вызывала `panel_api()` 9 раз — функция не существовала. `panel_api_request()` есть, но принимает относительный путь (`/api/...`) и добавляет `PANEL_API` константу сама. `panel_api()` принимает полный URL — это разные сигнатуры, нельзя заменить одну другой.

**Исправление:** добавлена `panel_api()` перед `panel_install()`:
```bash
panel_api() {
    local method="$1" url="$2" token="$3" data="${4:-}"
    local args=(-s -X "$method" "$url"
        -H "Authorization: Bearer $token"
        -H "Content-Type: application/json"
        -H "X-Forwarded-For: 127.0.0.1"
        -H "X-Forwarded-Proto: https"
        -H "X-Remnawave-Client-Type: browser")
    [ -n "$data" ] && args+=(-d "$data")
    curl "${args[@]}"
}
```

---

### 🟡 Предупреждения

#### jq без проверки установки
`jq` используется 13+ раз в `panel.sh` без `command -v jq` проверки. При запуске отдельных функций (WARP, `panel_api_request`) без предварительного `install_deps` — упадёт без понятного сообщения.

**Рекомендация:** добавить в `common.sh`:
```bash
ensure_jq() {
    command -v jq &>/dev/null && return 0
    info "Установка jq..."
    apt-get install -y -q jq 2>/dev/null || err "Не удалось установить jq"
}
```

#### Смешение jq и python3 для JSON
В `panel.sh` для формирования JSON-запросов используется `jq`, для парсинга ответов — `python3 -c "import json..."`. Это нарушает консистентность и усложняет поддержку.

**Рекомендация:** выбрать один инструмент. `jq` предпочтительнее — быстрее, меньше накладных расходов, не требует Python.

Пример замены:
```bash
# Было
TOKEN=$(echo "$REG" | python3 -c "import sys,json; print(json.load(sys.stdin)['response']['accessToken'])")

# Стало
TOKEN=$(echo "$REG" | jq -r '.response.accessToken // empty')
```

#### set -e в mgmt-скрипте
Внутри heredoc `MGMTEOF` есть `set -e`. При использовании `[ ]`, `grep` без совпадений или других команд с ненулевым exit code — скрипт прервётся молча. eGames не использует `set -e` в mgmt-скрипте.

---

### 🔵 Сравнение с eGames

| Аспект | eGames | server-manager | Победитель |
|---|---|---|---|
| Обработка ошибок API | Подробные сообщения с телом ответа | `\|\| warn "Ошибка"` без деталей | eGames |
| Retry панели | timeout loop с backoff | Цикл без backoff | eGames (minor) |
| Идемпотентность | Повторный запуск ломает конфиг | IS_INSTALLED + переустановка по компонентам | **Наш** |
| Модульность | Монолит 5000+ строк | 5 модулей, curl\|bash поддержка | **Наш** |
| SSH рефакторинг | Дублирование в каждой функции | ask_ssh_target/init_ssh_helpers | **Наш** |
| API Client-Type | X-Remnawave-Client-Type: browser ✓ | X-Remnawave-Client-Type: browser ✓ | Равно |
| Язык | Монолитный bash | Модульный bash | **Наш** |

#### Что взять у eGames

**1. Подробные ошибки API:**
```bash
# eGames паттерн
local response=$(make_api_request POST /api/nodes "$token" "$data")
if ! echo "$response" | jq -e '.response.uuid' >/dev/null 2>&1; then
    local msg=$(echo "$response" | jq -r '.message // "неизвестная ошибка"')
    warn "Ошибка создания ноды: $msg"
    return 1
fi
ok "Нода создана"
```

**2. Валидация UUID перед API вызовами:**
```bash
# eGames всегда проверяет UUID перед PATCH/DELETE
[[ "$uuid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
    || { err "Неверный UUID: $uuid"; return 1; }
```

---

### 📋 Общие рекомендации (не реализованы)

#### 1. Логирование установки
При сбое установки нет файла лога — трудно диагностировать.
```bash
# В server-manager.sh
LOG="/var/log/server-manager-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1
```

#### 2. Healthcheck после установки
После `panel_install` нет проверки что VLESS реально принимает соединения.
```bash
# Smoke test после установки
sleep 5
if curl -sk --max-time 5 "https://${SELFSTEAL_DOMAIN}" >/dev/null 2>&1; then
    ok "443 отвечает ✓"
else
    warn "443 не отвечает — возможно Xray не стартовал"
fi
```

#### 3. Атомарность panel_install
Если `panel_install` прерывается на середине — состояние частично установлено. Повторный запуск может создать дубликаты нод/профилей в панели.
```bash
# Флаг установки
INSTALL_LOCK="/opt/remnawave/.server-manager-installed"
[ -f "$INSTALL_LOCK" ] && { warn "Панель уже установлена. Используйте переустановку."; return 1; }
# ... установка ...
touch "$INSTALL_LOCK"
```

#### 4. Версионирование конфигов
При обновлении скрипта `docker-compose.yml` и `nginx.conf` не обновляются автоматически. Пользователь с устаревшим конфигом получит ошибки.
```bash
# В .env
SERVER_MANAGER_CONFIG_VERSION=2
# При запуске panel_menu
local current=$(grep "SERVER_MANAGER_CONFIG_VERSION" /opt/remnawave/.env | cut -d= -f2)
[ "$current" != "2" ] && warn "Конфиг устарел. Рекомендуется переустановка."
```

#### 5. jq как единый инструмент для JSON
Заменить все `python3 -c "import json..."` на `jq`. Это ускорит выполнение и упростит код.

