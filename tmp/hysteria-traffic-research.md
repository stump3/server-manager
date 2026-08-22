# Hysteria2 → Remnawave: учёт трафика

**Статус:** исследование завершено  
**Дата:** апрель 2026

---

## Идея

Hysteria2 ведёт статистику трафика по пользователям через встроенный API (`trafficStats`).  
Цель — снимать эту статистику и зачислять байты пользователям в Remnawave, чтобы:

- лимиты трафика работали и для Hysteria2-соединений
- панель отображала реальное потребление

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
| `GET` | `/traffic?clear=1` | Трафик по username, опционально сбрасывает счётчики |
| `POST` | `/kick` | Принудительно отключить клиентов по ID |
| `GET` | `/online` | Онлайн-клиенты и число подключений |
| `GET` | `/dump/streams` | Детали QUIC-стримов (дебаг) |

#### `GET /traffic?clear=1` — ответ

```json
{
  "admin": { "tx": 514,  "rx": 4017   },
  "user1": { "tx": 7790, "rx": 446623 }
}
```

`tx`/`rx` — байты с момента последнего `?clear=1`. Идеально для дельта-опроса.

#### `POST /kick` — тело запроса

```json
["admin", "user1"]
```

⚠️ Клиент переподключится из-за reconnect-логики. Блокировка работает только вместе  
с удалением из auth-бэкенда — hy-webhook это уже делает при `user.deleted`.

**На сервере `trafficStats` не включён** — в `config.yaml` секция отсутствует.

---

## Remnawave Users Controller API — полный список

Согласно официальной документации, доступны следующие эндпоинты:

```
POST   /api/users                                    — создать пользователя
PATCH  /api/users                                    — обновить пользователя
GET    /api/users                                    — список всех
DELETE /api/users/{uuid}                             — удалить
GET    /api/users/{uuid}                             — получить по UUID
GET    /api/users/by-username/{username}             — получить по username
GET    /api/users/by-short-uuid/{shortUuid}          — получить по shortUuid
GET    /api/users/by-id/{id}                         — получить по id
GET    /api/users/by-telegram-id/{telegramId}        — получить по telegram id
GET    /api/users/by-email/{email}                   — получить по email
GET    /api/users/by-tag/{tag}                       — получить по тегу
GET    /api/users/tags                               — список тегов
GET    /api/users/{uuid}/accessible-nodes            — доступные ноды
GET    /api/users/{uuid}/subscription-request-history
POST   /api/users/resolve
POST   /api/users/{uuid}/actions/revoke              — отозвать подписку
POST   /api/users/{uuid}/actions/disable             — отключить
POST   /api/users/{uuid}/actions/enable              — включить
POST   /api/users/{uuid}/actions/reset-traffic       — сбросить трафик в 0
```

### Поля `UpdateUserRequestDto` (`PATCH /api/users`)

```
username, uuid, status, trafficLimitBytes, trafficLimitStrategy,
expireAt, description, tag, telegramId, email,
hwidDeviceLimit, activeInternalSquads, externalSquadUuid
```

`usedTrafficBytes` в DTO **отсутствует**.

### Поле `userTraffic` в ответах (read-only)

Все GET/POST/PATCH возвращают вложенный объект:

```json
"userTraffic": {
  "usedTrafficBytes": 1,
  "lifetimeUsedTrafficBytes": 1,
  "onlineAt": null,
  "firstConnectedAt": null,
  "lastConnectedNodeUuid": null
}
```

Поля видны в ответе, но **записать их через API нельзя** — ни один DTO их не принимает.

---

## Итог по REST API

**Публичного эндпоинта для инкремента трафика не существует.**

Единственный traffic-метод `reset-traffic` сбрасывает `usedTrafficBytes` в 0 — обратная операция.

---

## Попытка прямой записи в PostgreSQL

Порт `6767` открыт в `docker-compose.yml` на `127.0.0.1` — БД доступна с хоста.

Попытка найти таблицу по имени из исходников:

```bash
docker exec remnawave-db psql -U postgres -d postgres -c '\d "userTraffic"'
# → Did not find any relation named "userTraffic"
```

**Результат:** имя таблицы в реальной БД отличается от исходников (DeepWiki индексировался  
по исходникам от марта 2026, схема, вероятно, изменилась или использует snake_case).

Следующие команды для разведки:

```bash
# Найти все таблицы
docker exec remnawave-db psql -U postgres -d postgres \
  -c "SELECT table_name FROM information_schema.tables WHERE table_schema='public' ORDER BY table_name;"

# После нахождения таблицы трафика:
docker exec remnawave-db psql -U postgres -d postgres -c '\d+ <имя_таблицы>'

# Посмотреть данные
docker exec remnawave-db psql -U postgres -d postgres -c 'SELECT * FROM <имя_таблицы> LIMIT 3;'
```

Предполагаемые варианты имени: `user_traffic`, `UserTraffic`, `users_traffic`.

---

## Варианты реализации

### ❌ Вариант 1 — Публичный REST API
**Невозможен.** Подтверждено полным изучением API — эндпоинта для инкремента нет.

### ⚠️ Вариант 2 — Прямая запись в PostgreSQL
**Технически возможен, риск: хрупкость.**

Схема работы при известной таблице:

```
[фоновый поток каждые 60с]
  → GET hysteria :9999/traffic?clear=1
  → для каждого (username, tx+rx):
      → SELECT uuid FROM users WHERE username = ?
      → UPDATE <traffic_table>
           SET "usedTrafficBytes"          += delta,
               "lifetimeUsedTrafficBytes"  += delta
         WHERE "userId" = (SELECT id FROM users WHERE username = ?)
```

Риски:
- имена колонок могут измениться при обновлении Remnawave
- нет транзакционных гарантий между Hysteria2 и Remnawave
- при краше между `?clear=1` и записью в БД — трафик теряется

Статус: **заблокирован**, нужно найти реальное имя таблицы.

### ✅ Вариант 3 — Локальный мониторинг (без записи в панель)
**Надёжный, без зависимостей от Remnawave.**

```
[фоновый поток каждые 60с]
  → GET :9999/traffic?clear=1
  → аккумулировать в /var/lib/hy-webhook/traffic.json
  → отдавать через GET /traffic-stats в hy-webhook
```

Лимиты в Remnawave не работают, но трафик виден и не теряется.

### ✅ Вариант 4 — /kick при отключении (реализуемо сейчас)
**Не связан с трафиком, улучшает текущую интеграцию.**

При получении `user.deleted` / `user.disabled` / `user.expired` — после удаления из `users.json`:

```
POST http://127.0.0.1:9999/kick
["username"]
```

Пользователь отключается мгновенно. Сейчас hy-webhook этого не делает — активная сессия  
продолжается до следующего реконнекта клиента.

Требует: добавить `trafficStats` секцию в `config.yaml` (она открывает весь admin API).

### 🔮 Вариант 5 — Официальная поддержка Remnawave
Remnawave — XRay-ориентированная система. Hysteria2 не является нодой в её модели.  
Внешние источники трафика в публичном роадмапе не значатся.

---

## Сводная таблица

| Вариант | Трафик в панели | Надёжность | Статус |
|---|---|---|---|
| REST API Remnawave | ✅ | — | ❌ эндпоинта нет |
| Прямо в PostgreSQL | ✅ | ⚠️ хрупко | 🔍 нужна схема БД |
| Локальный мониторинг | ❌ (отдельно) | ✅ | ✅ реализуемо |
| /kick при отключении | — | ✅ | ✅ реализуемо сейчас |
| Официальная поддержка | ✅ | ✅ | ⏳ неизвестно |

---

## Рекомендуемые следующие шаги

**Быстро и без рисков:**
1. Включить `trafficStats` в `config.yaml` — открывает `/kick` и `/online`
2. Добавить `/kick` в hy-webhook при `user.deleted` / `user.disabled` / `user.expired`

**Если нужен трафик в панели:**
1. Найти реальное имя таблицы командами выше
2. Принять риски прямой записи в БД
3. Реализовать поллер в hy-webhook.py как фоновый поток
