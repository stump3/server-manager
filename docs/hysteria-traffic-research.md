# Hysteria2 → Remnawave: учёт трафика

**Статус:** исследование завершено, план реализации готов  
**Дата:** апрель 2026

---

## Hysteria2 Traffic Stats API

Включается секцией в `config.yaml`:

```yaml
trafficStats:
  listen: 127.0.0.1:9999
  secret: <опционально>
```

Если `secret` задан — все запросы требуют заголовок `Authorization: <secret>`.

### Эндпоинты

| Метод | Путь | Описание |
|---|---|---|
| `GET` | `/traffic?clear=1` | Трафик по username, сбрасывает счётчики |
| `POST` | `/kick` | Принудительно отключить клиентов по username |
| `GET` | `/online` | Онлайн-клиенты и число подключений |
| `GET` | `/dump/streams` | Детали QUIC-стримов (дебаг) |

#### `GET /traffic?clear=1` — ответ

```json
{
  "admin": { "tx": 514,  "rx": 4017   },
  "user1": { "tx": 7790, "rx": 446623 }
}
```

`tx` — отправлено клиенту (download), `rx` — получено от клиента (upload).  
Значения с момента последнего `?clear=1` — идеально для дельта-опроса.  
**Суммарный трафик пользователя = `tx + rx`.**

#### `POST /kick` — тело запроса

```json
["admin", "user1"]
```

> ⚠️ Клиент переподключится из-за reconnect-логики. Блокировка работает только вместе
> с удалением из auth-бэкенда — `hy-webhook` это уже делает при `user.deleted`.

---

## Эталонные конфиги Hysteria2

### Минимальный рабочий конфиг с HTTP auth

```yaml
listen: 0.0.0.0:8443

acme:
  type: http
  domains:
    - example.com
  email: admin@example.com
  ca: letsencrypt

auth:
  type: http
  http:
    url: http://127.0.0.1:8766/auth
```

### Полный конфиг с trafficStats

```yaml
listen: 0.0.0.0:8443

acme:
  type: http
  domains:
    - cdn.example.com
  email: admin@example.com
  ca: letsencrypt

auth:
  type: http
  http:
    url: http://127.0.0.1:8766/auth

trafficStats:
  listen: 127.0.0.1:9999
  secret: <ваш_секрет>
```

> **Важно:** `type: http` под `acme:` — обязательный параметр. Без него Hysteria2
> использует TLS-ALPN-01 вместо HTTP-01, что часто блокируется (видно в логах как
> `remote error: tls: no application protocol`).

```bash
# Просмотр текущего конфига
cat /etc/hysteria/config.yaml

# Применить изменения
systemctl restart hysteria-server
```

---

## Remnawave: архитектура данных

**БД (PostgreSQL) — источник истины. Панель (NestJS) — API поверх неё.**

Изменение данных напрямую в БД немедленно отображается в панели без перезапуска.

### Технологический стек

| Компонент | Технология | Назначение |
|---|---|---|
| ORM (CRUD) | Prisma | Простые операции, миграции |
| Query Builder | Kysely | Сложные запросы с JOIN |
| База данных | PostgreSQL | Основное хранилище |
| Кеш | Valkey (Redis) | Через unix-сокет `/var/run/valkey/valkey.sock` |

---

## Реальная схема БД (подтверждено на сервере)

### Все таблицы

```
_prisma_migrations                  admin
api_tokens                          config_profile_inbounds
config_profile_inbounds_to_nodes    config_profile_snippets
config_profiles                     external_squads
external_squads_templates           hosts
hosts_to_nodes                      hwid_user_devices
infra_billing_history               infra_billing_nodes
infra_providers                     internal_squad_host_exclusions
internal_squad_inbounds             internal_squad_members
internal_squads                     keygen
node_meta                           node_plugin
nodes                               nodes_traffic_usage_history
nodes_usage_history                 nodes_user_usage_history
passkeys                            remnawave_settings
subscription_page_config            subscription_settings
subscription_templates              torrent_blocker_reports
user_meta                           user_subscription_request_history
user_traffic                        users
```

Итого: **36 таблиц**.

---

### Таблица `users` — полная структура

```sql
docker exec remnawave-db psql -U postgres postgres -c '\d+ users'
```

| Колонка | Тип | Nullable | Описание |
|---|---|---|---|
| `t_id` | bigint | NOT NULL | Технический PK (auto-increment, **нельзя менять**) |
| `uuid` | uuid | NOT NULL | Идентификатор для API |
| `short_uuid` | text | NOT NULL | Короткий UUID — часть URL подписки `/sub/TOKEN` |
| `username` | text | NOT NULL | Логин пользователя |
| `status` | varchar(10) | NOT NULL | `ACTIVE` / `DISABLED` / `LIMITED` / `EXPIRED` |
| `traffic_limit_bytes` | bigint | NOT NULL | Лимит трафика в байтах (0 = безлимит) |
| `traffic_limit_strategy` | text | NOT NULL | `NO_RESET` / `DAY` / `WEEK` / `MONTH` |
| `expire_at` | timestamp | NOT NULL | Срок действия аккаунта |
| `sub_revoked_at` | timestamp | NULL | Когда подписка была отозвана |
| `last_traffic_reset_at` | timestamp | NULL | Последний сброс трафика |
| `last_triggered_threshold` | integer | NOT NULL | Последний сработавший порог уведомлений |
| `trojan_password` | text | NOT NULL | Пароль для протокола Trojan |
| `vless_uuid` | uuid | NOT NULL | UUID для протокола VLESS |
| `ss_password` | text | NOT NULL | Пароль для Shadowsocks |
| `description` | text | NULL | Описание |
| `email` | text | NULL | Email |
| `telegram_id` | bigint | NULL | Telegram ID |
| `hwid_device_limit` | integer | NULL | Лимит устройств (0 = безлимит) |
| `tag` | text | NULL | Тег |
| `external_squad_uuid` | uuid | NULL | Ссылка на reseller-группу |
| `created_at` | timestamp | NOT NULL | Дата создания |
| `updated_at` | timestamp | NOT NULL | Дата обновления |

**Индексы:**
- `users_pkey` — PRIMARY KEY (`t_id`)
- `users_uuid_key` — UNIQUE (`uuid`)
- `users_username_key` — UNIQUE (`username`)
- `users_short_uuid_key` — UNIQUE (`short_uuid`)

**Cascade:** удаление `users` каскадно удаляет `user_traffic`, `hwid_user_devices`,
`internal_squad_members`, `nodes_user_usage_history`, `user_subscription_request_history`.

---

### Таблица `user_traffic` — структура и связь

```sql
docker exec remnawave-db psql -U postgres postgres -c '\d+ user_traffic'
```

Связана с `users` через `t_id` (FK с CASCADE DELETE).

| Колонка | Тип | Описание |
|---|---|---|
| `t_id` | bigint (PK, FK) | Ссылка на `users.t_id` |
| `used_traffic_bytes` | bigint | Использовано за текущий период |
| `lifetime_used_traffic_bytes` | bigint | Всего за всё время |
| `online_at` | timestamp | Последнее подключение |
| `last_connected_node_uuid` | uuid | Последняя нода |
| `first_connected_at` | timestamp | Первое подключение |

---

### Пример реальных данных

```sql
docker exec remnawave-db psql -U postgres postgres -c 'SELECT * FROM users LIMIT 3;'
```

| username | status | traffic_limit_bytes | t_id | short_uuid |
|---|---|---|---|---|
| admin | ACTIVE | 0 (безлимит) | 2 | YFztqJHhDmPS7UqN |
| anton | ACTIVE | 0 (безлимит) | 3 | qMVxz22cXaLd8tkj |
| igor | ACTIVE | 0 (безлимит) | 4 | S_2GLRXB2qmpKAP9 |

---

## Полезные SQL-запросы

```bash
# Подключиться к БД
docker exec -it remnawave-db psql -U postgres postgres
```

```sql
-- Пользователи с трафиком (читаемый формат)
SELECT
    u.username,
    u.status,
    round(t.used_traffic_bytes / 1073741824.0, 2)          AS used_gb,
    round(t.lifetime_used_traffic_bytes / 1073741824.0, 2) AS lifetime_gb,
    t.online_at
FROM users u
JOIN user_traffic t ON u.t_id = t.t_id
ORDER BY t.used_traffic_bytes DESC;

-- Сбросить трафик конкретного пользователя
UPDATE user_traffic
SET used_traffic_bytes = 0
WHERE t_id = (SELECT t_id FROM users WHERE username = 'admin');

-- Вручную добавить байты (например, дельта от Hysteria2)
UPDATE user_traffic
SET used_traffic_bytes          = used_traffic_bytes + 1073741824,
    lifetime_used_traffic_bytes = lifetime_used_traffic_bytes + 1073741824
WHERE t_id = (SELECT t_id FROM users WHERE username = 'admin');

-- Пользователи близкие к лимиту (>80%)
SELECT u.username, u.status,
       u.traffic_limit_bytes / 1073741824.0 AS limit_gb,
       t.used_traffic_bytes / 1073741824.0  AS used_gb,
       round(t.used_traffic_bytes * 100.0 / NULLIF(u.traffic_limit_bytes, 0), 1) AS pct
FROM users u
JOIN user_traffic t ON u.t_id = t.t_id
WHERE u.traffic_limit_bytes > 0
ORDER BY pct DESC;
```

---

## Remnawave API — эндпоинты пользователей

```
POST   /api/users                                    — создать
PATCH  /api/users                                    — обновить
GET    /api/users                                    — список всех
DELETE /api/users/{uuid}                             — удалить
GET    /api/users/{uuid}                             — по UUID
GET    /api/users/by-username/{username}             — по username
GET    /api/users/by-short-uuid/{shortUuid}          — по shortUuid
POST   /api/users/{uuid}/actions/revoke              — отозвать подписку
POST   /api/users/{uuid}/actions/disable             — отключить
POST   /api/users/{uuid}/actions/enable              — включить
POST   /api/users/{uuid}/actions/reset-traffic       — сбросить трафик в 0
```

**`PATCH /api/users` — принимает:**
`username, uuid, status, trafficLimitBytes, trafficLimitStrategy, expireAt,
description, tag, telegramId, email, hwidDeviceLimit, activeInternalSquads, externalSquadUuid`

**`usedTrafficBytes` в DTO отсутствует** — записать через API нельзя.
Единственный traffic-метод API — `reset-traffic`, сбрасывает в 0.

---

## Варианты реализации учёта трафика

### ❌ Вариант 1 — REST API Remnawave
Эндпоинта для инкремента трафика не существует. Закрыто.

### ✅ Вариант 2 — Прямая запись в PostgreSQL
**Реализуемо.** Схема известна, порт `6767` открыт на `127.0.0.1`.

Таблица: `user_traffic`, колонки: `used_traffic_bytes`, `lifetime_used_traffic_bytes`.  
JOIN через: `users.t_id = user_traffic.t_id`, поиск по `users.username`.

### ✅ Вариант 3 — Локальный мониторинг
Без записи в панель, надёжно. Трафик копится в `traffic.json`, отдаётся через `/traffic-stats`.

### ✅ Вариант 4 — /kick при отключении
Реализуемо сейчас, не требует трафик-статистики.

---

## План реализации учёта трафика (Вариант 2)

### Шаг 1 — Включить trafficStats в Hysteria2

Добавить в `/etc/hysteria/config.yaml`:

```yaml
trafficStats:
  listen: 127.0.0.1:9999
  secret: my-secret-token
```

```bash
systemctl restart hysteria-server

# Проверить что API работает
curl -s http://127.0.0.1:9999/traffic
```

### Шаг 2 — Добавить поллер в hy-webhook.py

Фоновый поток опрашивает Hysteria2 каждые 60 секунд и пишет дельту напрямую в PostgreSQL.

**Логика (tx + rx = суммарный трафик):**

```python
import threading, time, json, urllib.request, psycopg2, os

HY_TRAFFIC_URL = "http://127.0.0.1:9999/traffic?clear=1"
HY_TRAFFIC_SECRET = os.environ.get("HY_TRAFFIC_SECRET", "")
DB_DSN = os.environ.get("DATABASE_URL", "")      # берём из /etc/hy-webhook.env
POLL_INTERVAL = 60                               # секунды
PENDING_FILE = "/var/lib/hy-webhook/traffic-pending.json"

def fetch_hy_traffic() -> dict:
    """GET /traffic?clear=1 → {username: {tx, rx}}"""
    req = urllib.request.Request(HY_TRAFFIC_URL)
    if HY_TRAFFIC_SECRET:
        req.add_header("Authorization", HY_TRAFFIC_SECRET)
    with urllib.request.urlopen(req, timeout=5) as r:
        return json.loads(r.read())

def write_traffic_to_db(deltas: dict):
    """
    deltas = {username: bytes_total}
    UPDATE user_traffic SET used_traffic_bytes += delta,
                            lifetime_used_traffic_bytes += delta
    WHERE t_id = (SELECT t_id FROM users WHERE username = ?)
    """
    if not deltas:
        return
    conn = psycopg2.connect(DB_DSN)
    try:
        with conn, conn.cursor() as cur:
            for username, delta in deltas.items():
                if delta <= 0:
                    continue
                cur.execute("""
                    UPDATE user_traffic ut
                    SET used_traffic_bytes          = ut.used_traffic_bytes + %s,
                        lifetime_used_traffic_bytes = ut.lifetime_used_traffic_bytes + %s
                    FROM users u
                    WHERE ut.t_id = u.t_id
                      AND u.username = %s
                """, (delta, delta, username))
    finally:
        conn.close()

def save_pending(deltas: dict):
    with open(PENDING_FILE, "w") as f:
        json.dump(deltas, f)

def load_and_clear_pending() -> dict:
    try:
        with open(PENDING_FILE) as f:
            d = json.load(f)
        os.remove(PENDING_FILE)
        return d
    except FileNotFoundError:
        return {}

def traffic_poller():
    # При старте — накатить несохранённые дельты прошлого запуска
    pending = load_and_clear_pending()
    if pending:
        write_traffic_to_db(pending)

    while True:
        time.sleep(POLL_INTERVAL)
        try:
            raw = fetch_hy_traffic()
            # Суммируем tx + rx в одно значение
            deltas = {
                user: stats.get("tx", 0) + stats.get("rx", 0)
                for user, stats in raw.items()
            }
            save_pending(deltas)       # сохраняем до записи в БД
            write_traffic_to_db(deltas)
            os.remove(PENDING_FILE)    # успешно — удаляем буфер
        except Exception as e:
            log.error(f"Traffic poller error: {e}")

# Запустить при старте hy-webhook:
threading.Thread(target=traffic_poller, daemon=True).start()
```

### Шаг 3 — Добавить /kick при отключении пользователя

```python
def kick_hysteria_user(username: str):
    """POST /kick → мгновенно разрывает активные сессии"""
    try:
        body = json.dumps([username]).encode()
        req = urllib.request.Request(
            "http://127.0.0.1:9999/kick",
            data=body,
            headers={
                "Content-Type": "application/json",
                "Authorization": HY_TRAFFIC_SECRET
            },
            method="POST"
        )
        urllib.request.urlopen(req, timeout=5)
        log.info(f"Kicked: {username}")
    except Exception as e:
        log.warning(f"Kick failed for {username}: {e}")

# Добавить вызов в process_event():
elif event in ("user.deleted", "user.disabled", "user.expired"):
    changed = handle_user_deleted(username, users)
    kick_hysteria_user(username)           # ← добавить
```

### Шаг 4 — Добавить переменные в `/etc/hy-webhook.env`

```bash
HY_TRAFFIC_SECRET=my-secret-token
DATABASE_URL=postgresql://postgres:postgres@127.0.0.1:6767/postgres
```

### Шаг 5 — Добавить зависимость psycopg2

```bash
pip install psycopg2-binary --break-system-packages
```

### Шаг 6 — Проверить

```bash
# Трафик до
docker exec remnawave-db psql -U postgres postgres \
  -c "SELECT u.username, t.used_traffic_bytes FROM users u JOIN user_traffic t ON u.t_id = t.t_id;"

# Принудительно опросить (сгенерировать трафик и подождать 60с)
curl -s http://127.0.0.1:9999/traffic

# Трафик после (через 60с)
docker exec remnawave-db psql -U postgres postgres \
  -c "SELECT u.username, t.used_traffic_bytes FROM users u JOIN user_traffic t ON u.t_id = t.t_id;"
```

---

## Итоговая таблица вариантов

| Вариант | Трафик в панели | Надёжность | Статус |
|---|---|---|---|
| REST API Remnawave | ✅ | — | ❌ эндпоинта нет |
| Прямо в PostgreSQL | ✅ | ⚠️ без гарантий транзакций | ✅ план готов |
| Локальный мониторинг | ❌ (отдельно) | ✅ | ✅ реализуемо |
| /kick при отключении | — | ✅ | ✅ план готов |
| Официальная поддержка | ✅ | ✅ | ⏳ неизвестно |

---

## Риски прямой записи в БД

| Риск | Митигация |
|---|---|
| Имена колонок изменятся при обновлении Remnawave | Версионировать запрос, проверять после `docker pull` |
| Краш между `?clear=1` и записью в БД | `pending.json` — буфер дельты, накатывается при следующем старте |
| Одновременная запись Remnawave + поллер | Оба делают `+=`, не `=` — гонки не страшны |
| Remnawave не узнает о превышении лимита сразу | Scheduler проверяет статусы по расписанию, задержка до 1 мин |
