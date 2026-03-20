# server-manager — Инженерная документация

> Для разработчиков и DevOps-инженеров, работающих с кодом скрипта.

---

## Архитектура

### Загрузка модулей

```bash
# server-manager.sh (точка входа)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "")"

_load_module() {
    local mod="$1"
    local local_path="${SCRIPT_DIR}/lib/${mod}.sh"
    if [ -n "$SCRIPT_DIR" ] && [ -f "$local_path" ]; then
        source "$local_path"          # локально из репо
    else
        curl -fsSL "${REPO_RAW}/lib/${mod}.sh" | source /dev/stdin  # с GitHub
    fi
}
```

При `curl | bash` — `SCRIPT_DIR` пустой, модули скачиваются с GitHub. При локальном запуске — из `lib/`.

### Модули

| Файл | Строк | Экспортирует |
|---|---|---|
| `lib/common.sh` | 399 | `ok/info/warn/err`, `step/header/section`, `confirm/ask`, `gen_*`, `check_dns`, `spinner`, SSH-хелперы, `main_menu` |
| `lib/panel.sh` | 1750 | `panel_menu`, `panel_install`, `panel_submenu_*`, `panel_install_mgmt_script` |
| `lib/telemt.sh` | 701 | `telemt_menu`, `telemt_install`, `telemt_menu_*` |
| `lib/hysteria.sh` | 1213 | `hysteria_menu`, `hysteria_install`, `hysteria_*` |
| `lib/migrate.sh` | 248 | `migrate_menu`, `do_migrate`, `migrate_all` |

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

## hy-webhook — архитектура интеграции

### Схема

```
Remnawave (user.created/deleted/disabled/enabled)
    │
    ▼ POST http://172.30.0.1:8766/webhook
    │  Header: X-Remnawave-Signature: <hex(HMAC-SHA256)>
    │
hy-webhook.py (systemd, порт 8766, 0.0.0.0)
    │  1. Verify signature: HMAC-SHA256(body, WEBHOOK_SECRET)
    │  2. sanitize(username): [a-zA-Z0-9_-], min 6 chars
    │  3. gen_password(username, secret): sha256(u:s)[:32]
    │  4. update users.json
    │  5. update /etc/hysteria/config.yaml (userpass block)
    │  6. systemctl reload-or-restart hysteria-server
    │
subscription-page (remnawave-sub-hy:local)
    │  При запросе подписки:
    │  1. Получить shortUuid пользователя
    │  2. GET /api/users/by-short-uuid/:uuid
    │  3. Читает /var/lib/hy-webhook/users.json
    │  4. Находит пароль пользователя
    │  5. Добавляет hy2:// URI в base64 ответ
```

### UFW — почему 172.16.0.0/12

Docker использует подсети из `172.16.0.0/12` по умолчанию. `remnawave-network` сконфигурирована как `172.30.0.0/16`. Gateway сети (`172.30.0.1`) — это IP хоста внутри Docker сети. Правило `172.16.0.0/12` покрывает все возможные Docker подсети.

```bash
# Проверить gateway текущей сети
docker network inspect remnawave-network | grep Gateway

# Проверить что webhook доступен из контейнера
docker exec remnawave curl -s http://172.30.0.1:8766/health
```

### subscription-page — патчи TypeScript

При установке `hy-sub-install.sh` патчит исходники subscription-page перед сборкой Docker образа:

| Патч | Файл | Что делает |
|---|---|---|
| Патч 1 | `root.service.ts` | Добавляет `import fs` |
| Патч 2 | `root.service.ts` | Добавляет `getHysteriaUriForUser()` |
| Патч 3 | `axios.service.ts` | Добавляет `getUserByShortUuid()` |

После патчей Docker пересобирает образ с TypeScript компиляцией (`npm run build`).

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

### subscription-page: Invalid subscription content

```bash
# 1. Контейнер запущен?
docker ps | grep sub

# 2. Переменные окружения заданы?
docker logs remnawave-subscription-page --tail=20 | grep -i "error\|REMNAWAVE"

# 3. Патч применился?
docker exec remnawave-subscription-page \
  grep -c "getHysteriaUriForUser" /opt/app/dist/src/modules/root/root.service.js

# 4. API URL правильный?
docker exec remnawave-subscription-page \
  grep "by-short-uuid\|get-by" /opt/app/dist/src/common/axios/axios.service.js
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

## Переменные окружения hy-webhook

Файл: `/etc/hy-webhook.env` (права 600)

| Переменная | Значение | Описание |
|---|---|---|
| `WEBHOOK_SECRET` | hex64 | HMAC-SHA256 ключ подписи |
| `HYSTERIA_CONFIG` | `/etc/hysteria/config.yaml` | Путь к конфигу |
| `USERS_DB` | `/var/lib/hy-webhook/users.json` | База пользователей |
| `LISTEN_PORT` | `8766` | Порт HTTP сервера |
| `LISTEN_HOST` | `0.0.0.0` | Интерфейс (0.0.0.0 для Docker) |
| `HYSTERIA_SVC` | `hysteria-server` | Имя systemd сервиса |

---

## Changelog инженерных решений

| Дата | Решение | Причина |
|---|---|---|
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
