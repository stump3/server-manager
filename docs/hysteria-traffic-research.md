# Hysteria2 → Remnawave: учёт трафика

**Статус:** ✅ реализовано  
**Дата:** апрель 2026

---

## Что реализовано

| Функция | Статус | Где |
|---|---|---|
| Поллинг трафика → PostgreSQL | ✅ | `hy-webhook.py` → `traffic_poller()` |
| `/kick` при отключении пользователя | ✅ | `hy-webhook.py` → `process_event()` |
| Настройка `trafficStats` при установке Hysteria2 | ✅ | `lib/hy2/install.sh` |
| Настройка агрегации при установке интеграции | ✅ | `integrations/hy-sub-install.sh` |
| Буфер `pending.json` от потери данных при краше | ✅ | `hy-webhook.py` → `_save_pending()` |

---

## Hysteria2 Traffic Stats API

Включается секцией в `config.yaml`:

```yaml
trafficStats:
  listen: 127.0.0.1:9999
  secret: <секрет>
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
**Суммарный трафик = `tx + rx`** — именно так считает поллер.

---

## Эталонные конфиги Hysteria2

### Минимальный — HTTP auth

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

### Полный — HTTP auth + trafficStats

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
  secret: <секрет>
```

> **`type: http` под `acme:` обязателен.** Без него Hysteria2 пытается TLS-ALPN-01,
> который часто блокируется — ошибка в логах: `remote error: tls: no application protocol`.

```bash
cat /etc/hysteria/config.yaml   # просмотр
systemctl restart hysteria-server
```

---

## Архитектура учёта трафика

```
Hysteria2 (:8443 UDP)
    │  каждые 60с
    ▼
GET http://127.0.0.1:9999/traffic?clear=1
    │  {username: {tx, rx}}
    ▼
hy-webhook.py → traffic_poller()
    │  delta = tx + rx
    │  _save_pending(delta)        ← буфер на случай краша
    ▼
psycopg2 → PostgreSQL :6767
    │  UPDATE user_traffic
    │  SET used_traffic_bytes          += delta
    │      lifetime_used_traffic_bytes += delta
    │  WHERE t_id = (SELECT t_id FROM users WHERE username = ?)
    ▼
_delete_pending()                  ← успешно — удаляем буфер
    │
    ▼
Remnawave Panel — видит обновлённый трафик
```

```
Remnawave → user.deleted / user.disabled / user.expired
    │
    ▼
hy-webhook.py → process_event() → handle_user_deleted()
    │
    ▼
POST http://127.0.0.1:9999/kick  ["username"]
    │
    ▼
Hysteria2 — разрывает активные сессии немедленно
```

---

## Переменные окружения `/etc/hy-webhook.env`

| Переменная | Дефолт | Описание |
|---|---|---|
| `HY_TRAFFIC_PORT` | `9999` | Порт trafficStats API Hysteria2 |
| `HY_TRAFFIC_SECRET` | `` | Секрет для Authorization заголовка |
| `DATABASE_URL` | `` | DSN PostgreSQL. **Пустой = поллер отключён** |
| `TRAFFIC_POLL_INTERVAL` | `60` | Интервал опроса в секундах |

Если `DATABASE_URL` не задан — `traffic_poller()` завершается сразу с сообщением
`DATABASE_URL не задан — учёт трафика отключён`. Не мешает основной работе.

Стандартный DSN для Remnawave:

```
DATABASE_URL=postgresql://postgres:postgres@127.0.0.1:6767/postgres
```

---

## Зависимость psycopg2

Требуется только если включён учёт трафика (`DATABASE_URL` задан).

```bash
pip3 install psycopg2-binary --break-system-packages
# или
apt-get install -y python3-psycopg2
```

`hy-sub-install.sh` устанавливает автоматически. Если импорт не удался — поллер
логирует ошибку и пропускает цикл, не роняя сервис.

---

## Как включить через скрипт

### При установке Hysteria2

```
Hysteria2 → 1) Установка
...
  Включить сбор трафика? (Y/n): Y
  Секрет trafficStats (Enter — сгенерировать): <Enter>
```

- секрет генерируется автоматически (`openssl rand -hex 16`)
- секция `trafficStats` добавляется в `/etc/hysteria/config.yaml`
- секрет сохраняется в `/etc/hy-webhook.env` (если файл существует)

### При установке интеграции с Remnawave

```
Hysteria2 → 4) Подписка → 3) Интеграция с Remnawave → 1) Установить

  ● trafficStats обнаружен в конфиге Hysteria2
  Включить агрегацию трафика с панелью? (Y/n): Y
```

- устанавливается `psycopg2`
- `DATABASE_URL` и `TRAFFIC_POLL_INTERVAL` записываются в `/etc/hy-webhook.env`
- `hy-webhook` перезапускается

> Если `trafficStats:` не найден в конфиге — скрипт пишет `○ trafficStats не найден`
> и пропускает шаг. Сначала переустановите Hysteria2 с включённым trafficStats.

---

## Ручная активация

```bash
# 1. Добавить trafficStats (удалить старую секцию и вписать новую)
python3 -c "
import re
with open('/etc/hysteria/config.yaml') as f: cfg = f.read()
cfg = re.sub(r'\ntrafficStats:.*', '', cfg, flags=re.DOTALL)
with open('/etc/hysteria/config.yaml', 'w') as f: f.write(cfg.rstrip())
"
printf '\ntrafficStats:\n  listen: 127.0.0.1:9999\n  secret: my-secret\n' \
    >> /etc/hysteria/config.yaml
systemctl restart hysteria-server

# 2. Проверить API
curl -s -H "Authorization: my-secret" http://127.0.0.1:9999/traffic

# 3. Установить psycopg2
pip3 install psycopg2-binary --break-system-packages

# 4. Добавить переменные в env
sed -i '/^HY_TRAFFIC_SECRET=/d;/^HY_TRAFFIC_PORT=/d;/^DATABASE_URL=/d;/^TRAFFIC_POLL_INTERVAL=/d' \
    /etc/hy-webhook.env
printf 'HY_TRAFFIC_SECRET=my-secret\nHY_TRAFFIC_PORT=9999\nDATABASE_URL=postgresql://postgres:postgres@127.0.0.1:6767/postgres\nTRAFFIC_POLL_INTERVAL=60\n' \
    >> /etc/hy-webhook.env

# 5. Перезапустить и смотреть логи
systemctl restart hy-webhook
journalctl -u hy-webhook -f
# Ожидаемые строки:
# Traffic poller запущен, интервал 60с
# Traffic записан в БД: N пользователей
```

---

## Реальная схема БД (подтверждено на сервере)

### Все таблицы (36 штук)

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

### Таблица `users`

```bash
docker exec remnawave-db psql -U postgres postgres -c '\d+ users'
```

| Колонка | Тип | Описание |
|---|---|---|
| `t_id` | bigint PK | Технический ID (auto-increment, **нельзя менять**) |
| `uuid` | uuid UNIQUE | Идентификатор для API |
| `short_uuid` | text UNIQUE | Часть URL подписки `/sub/TOKEN` |
| `username` | text UNIQUE | Логин |
| `status` | varchar(10) | `ACTIVE` / `DISABLED` / `LIMITED` / `EXPIRED` |
| `traffic_limit_bytes` | bigint | Лимит трафика (0 = безлимит) |
| `traffic_limit_strategy` | text | `NO_RESET` / `DAY` / `WEEK` / `MONTH` |
| `expire_at` | timestamp | Срок действия |
| `trojan_password` | text | Пароль Trojan |
| `vless_uuid` | uuid | UUID VLESS |
| `ss_password` | text | Пароль Shadowsocks |
| `hwid_device_limit` | integer | Лимит устройств |
| `tag`, `email`, `telegram_id` | — | Дополнительные поля |
| `created_at`, `updated_at` | timestamp | Аудит |

### Таблица `user_traffic` (1:1 с `users` через `t_id`)

```bash
docker exec remnawave-db psql -U postgres postgres -c '\d+ user_traffic'
```

| Колонка | Тип | Описание |
|---|---|---|
| `t_id` | bigint PK/FK | CASCADE DELETE от `users.t_id` |
| `used_traffic_bytes` | bigint | Использовано за текущий период |
| `lifetime_used_traffic_bytes` | bigint | Всего за всё время |
| `online_at` | timestamp | Последнее подключение |
| `last_connected_node_uuid` | uuid | Последняя нода |
| `first_connected_at` | timestamp | Первое подключение |

### Полезные SQL-запросы

```bash
docker exec -it remnawave-db psql -U postgres postgres
```

```sql
-- Пользователи с трафиком
SELECT u.username, u.status,
       round(t.used_traffic_bytes / 1073741824.0, 2)          AS used_gb,
       round(t.lifetime_used_traffic_bytes / 1073741824.0, 2) AS lifetime_gb,
       t.online_at
FROM users u
JOIN user_traffic t ON u.t_id = t.t_id
ORDER BY t.used_traffic_bytes DESC;

-- Сбросить трафик пользователя
UPDATE user_traffic SET used_traffic_bytes = 0
WHERE t_id = (SELECT t_id FROM users WHERE username = 'admin');

-- Добавить байты вручную (например, 1 GB)
UPDATE user_traffic
SET used_traffic_bytes          = used_traffic_bytes + 1073741824,
    lifetime_used_traffic_bytes = lifetime_used_traffic_bytes + 1073741824
WHERE t_id = (SELECT t_id FROM users WHERE username = 'admin');

-- Кто близко к лимиту (>80%)
SELECT u.username,
       round(u.traffic_limit_bytes / 1073741824.0, 2) AS limit_gb,
       round(t.used_traffic_bytes / 1073741824.0, 2)  AS used_gb,
       round(t.used_traffic_bytes * 100.0 / NULLIF(u.traffic_limit_bytes, 0), 1) AS pct
FROM users u
JOIN user_traffic t ON u.t_id = t.t_id
WHERE u.traffic_limit_bytes > 0
ORDER BY pct DESC;
```

---

## Remnawave API — справка по трафику

```
POST /api/users/{uuid}/actions/reset-traffic  — сбросить в 0 (единственный traffic-метод)
```

`usedTrafficBytes` **отсутствует в UpdateUserRequestDto** — записать через REST API нельзя.
Только прямая запись в PostgreSQL.

---

## Итоговая таблица вариантов

| Вариант | Трафик в панели | Надёжность | Статус |
|---|---|---|---|
| REST API Remnawave | ✅ | — | ❌ эндпоинта нет |
| Прямо в PostgreSQL | ✅ | ⚠️ без транзакций с Hysteria | ✅ **реализовано** |
| /kick при отключении | — | ✅ | ✅ **реализовано** |
| Официальная поддержка Remnawave | ✅ | ✅ | ⏳ неизвестно |

---

## Риски и митигации

| Риск | Митигация |
|---|---|
| Краш между `clear=1` и записью в БД | `pending.json` — накатывается при следующем старте |
| Колонки изменятся при обновлении Remnawave | Проверять `\d+ user_traffic` после `docker pull` |
| Параллельная запись Remnawave + поллер | Оба используют `+=`, не `=` — безопасно |
| Задержка срабатывания лимита | Scheduler Remnawave проверяет статусы ~раз в минуту |
| psycopg2 не установлен | Поллер логирует ошибку, не роняет сервис |
