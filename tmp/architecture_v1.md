# Architecture

> Финальная синхронизация архитектуры. Документ описывает целевое состояние системы.
> Расхождения между этим документом и кодом — технический долг, подлежащий устранению.

---

## 1. Уровни системы

```
┌─────────────────────────────────────────────────────────────────────┐
│  CLI / TUI                                                          │
│  server-manager.sh → lib/cli/  (non-interactive)                   │
│  server-manager.sh → lib/*/menu.sh  (interactive TUI)              │
├─────────────────────────────────────────────────────────────────────┤
│  Orchestration (Bash)                                               │
│  lib/common.sh  lib/config.sh  lib/versions.sh  lib/ssh.sh         │
│  lib/main_menu.sh                                                   │
├──────────────────────┬──────────────────────┬───────────────────────┤
│  Module: telemt      │  Module: hy2          │  Module: panel        │
│  lib/tmt/            │  lib/hy2/             │  lib/panel/           │
│  core / install /    │  core / install /     │  core / cert /        │
│  users / manage /    │  users / integration /│  install / warp /     │
│  menu + py/          │  menu + py/           │  subpage / menu       │
├──────────────────────┴──────────────────────┴───────────────────────┤
│  Runtime services                                                   │
│  hy-webhook.py (service)   hy_traffic_collect.py (job)             │
│  hy_online_poller.py (thread)   hy_node_register.py (one-shot)     │
│  collect_stats.py (job)                                             │
├──────────────────────────────────────────────────────────────────────┤
│  Infra                                                              │
│  systemd  docker  UFW  certbot  apt                                │
├──────────────┬───────────────────────────────────────────────────────┤
│  Storage     │                                                       │
│  SQLite      │  /var/lib/telemt/stats.db   (telemt stats)           │
│              │  /var/lib/hy-webhook/users.json  (hy2 HTTP auth)     │
│  Files       │  /etc/hysteria/config.yaml  (hy2 config)             │
│              │  /etc/telemt/telemt.toml    (telemt config)           │
│              │  /etc/hy-webhook.env        (runtime ENV)            │
│  PostgreSQL  │  Remnawave DB (downstream only, не source of truth)  │
└──────────────┴───────────────────────────────────────────────────────┘
```

---

## 2. Ingestion модель (telemt)

```
telemt API :9091
    │
    │  GET /v1/users  (каждые 10 минут)
    ▼
collect_stats.py          ← единственный writer
    │  calc_delta()
    │  handle_reset()
    │  BEGIN EXCLUSIVE
    ▼
SQLite /var/lib/telemt/stats.db
    │
    ├── snapshots    (последний known cumulative per user)
    ├── daily        (дельты per day)
    ├── monthly      (дельты per month)
    └── meta         (schema_version, last_collect_ts)
    │
    │  read-only (mode=ro + WAL)
    ▼
render_users.py / status_render.py / user_ips.py
    │
    ▼
CLI (lib/tmt/menu.sh, lib/cli/telemt.sh)
```

**Правила:**
- `collect_stats.py` — единственный процесс который пишет в `stats.db`
- CLI никогда не вызывает telemt API напрямую
- `traffic.json` — **deprecated**, читается только при миграции через `migrate_json_to_sqlite.py`

---

## 2.1 telemt API контракт и ограничения

### telemt как зависимость

telemt рассматривается как black-box runtime компонент.

Ограничения:

* API используется как есть, без модификаций
* логика компенсации (delta, reset, ошибки) реализуется на стороне collector
* telemt не является source of truth для истории — только для текущего состояния

---

### Telemetry requirement (обязательное условие)

telemt должен быть запущен с включённой пользовательской телеметрией:

```toml
[general.telemetry]
user_enabled = true
```

Если отключено:

* `total_octets` всегда будет равен 0
* collector будет записывать нулевой трафик
* это состояние не детектируется через `/v1/users`

➡️ Это жёсткое требование для корректной работы системы.

---

### Контракт API (/v1/users)

collector использует endpoint:

```
GET /v1/users
```

Формат ответа:

```json
{
  "ok": true,
  "data": [
    {
      "username": "alice",
      "total_octets": 524288000,
      "active_unique_ips_list": [],
      "recent_unique_ips_list": []
    }
  ]
}
```

---

### Семантика счётчиков

* `total_octets` — cumulative счётчик
* вычисляется как сумма:

  * octets_from_client
  * octets_to_client
* значение монотонно растёт в рамках процесса
* при рестарте telemt — сбрасывается в 0

collector обязан обрабатывать reset:

```
delta = current - previous
if delta < 0:
    delta = current
```

---

### Полнота ответа

* при `ok: true` telemt возвращает полный список пользователей
* частичный список при успешном ответе невозможен

Следствие:

* отсутствие пользователя в ответе = пользователь удалён
* sweep может выполняться безопасно при:

```
api_count >= db_count
```

---

### IP данные

* `active_unique_ips_list` — IP с активными соединениями (надёжный источник)
* `recent_unique_ips_list` — IP за короткое окно (~30 секунд)

Следствие:

* collector должен использовать объединение этих списков (active ∪ recent)
* IP история является best-effort, не полной

---

### Ограничения API (принимаются как данность)

* нет timestamp в ответе
* нет snapshot consistency между пользователями
* нет флага partial response
* нет информации о reset процесса
* нет информации о состоянии telemetry

Все эти ограничения компенсируются логикой collector.

---

## 3. Ingestion модель (Hysteria2)

```
Hysteria2 trafficStats :9999
    │
    │  GET /traffic?clear=... (каждые 60 секунд)
    ▼
hy_traffic_collect.py     ← единственный writer трафика
    │  pending_file (crash recovery)
    ▼
PostgreSQL (Remnawave DB)
    │  users, nodes, user_traffic, nodes_user_usage_history

hy-webhook.py             ← HTTP auth + online polling
    ├── WebhookHandler    GET /webhook (auth)
    ├── ProxyHandler      :3020 (reverse proxy)
    └── online_poller()   thread → PostgreSQL online_at (каждые 30с)

hy_node_register.py       ← one-shot при установке
    └── INSERT INTO nodes ... → /etc/hy-webhook.env
```

**Хранилища Hysteria2:**

| Файл | Тип | Владелец | Назначение |
|------|-----|----------|------------|
| `/etc/hysteria/config.yaml` | YAML | `hy_config.py` | Auth, порты, trafficStats |
| `/var/lib/hy-webhook/users.json` | JSON | `hy_users_db.py` | HTTP auth passwords |
| `/etc/hy-webhook.env` | ENV | `hy_node_register.py` | Runtime ENV для сервисов |
| PostgreSQL | DB | `hy_traffic_collect.py` | Traffic history (downstream) |

---

## 4. Границы: кто читает / кто пишет

```
Компонент                   Читает                      Пишет
─────────────────────────────────────────────────────────────────────
collect_stats.py            telemt API                  stats.db
render_users.py             stats.db (ro)               —
status_render.py            telemt API                  —
user_ips.py                 stats.db (ro)               —
stats_settings.py           stats.db                    stats.db (meta)

hy_config.py                config.yaml                 config.yaml (atomic)
hy_users_db.py              users.json                  users.json (atomic)
hy_traffic_collect.py       hy trafficStats API         PostgreSQL
hy_online_poller.py         hy online API               PostgreSQL (online_at)
hy_node_register.py         PostgreSQL                  PostgreSQL, .env (atomic)
hy_webhook_patch.py         hy-webhook.py               hy-webhook.py (atomic)

panel/core.sh               Remnawave API               —
panel/install.sh            —                           /opt/remnawave/, systemd
panel/management.sh         scripts/remnawave_panel.sh  /usr/local/bin/ (install)
panel/branding.py           config.json                 config.json (atomic)

Bash (menu / cli)           всё что выше               ничего напрямую
```

**Запрещённые прямые связи:**
- CLI → telemt API (только через Python-скрипты)
- CLI → PostgreSQL напрямую (только через Python-скрипты)
- CLI → config.yaml через awk/sed (только через `hy_config.py`)
- Любой `.sh` → SQL через `docker exec psql`

---

## 5. Финальная структура репозитория

```
server-manager/
│
├── server-manager.sh              # entry: bootstrap, source modules, routing
│
├── scripts/
│   └── remnawave_panel.sh         # standalone management script (не heredoc)
│
├── lib/
│   ├── common.sh                  # print utils, confirm, ask, generators
│   ├── config.sh                  # глобальные пути и константы
│   ├── versions.sh                # get_remnawave/hysteria/telemt_version()
│   ├── ssh.sh                     # SSH migration helpers
│   ├── main_menu.sh               # main_menu() + status refresh
│   │
│   ├── panel.sh                   # loader (~12 строк)
│   ├── panel/
│   │   ├── core.sh                # panel_api_request, panel_get_token
│   │   ├── cert.sh                # TLS: issue, check, get_domain
│   │   ├── install.sh             # install, reinstall, remove
│   │   ├── management.sh          # management script deploy, self-update
│   │   ├── warp.sh                # WARP Native
│   │   ├── subpage.sh             # subscription page
│   │   ├── template.sh            # selfsteal templates
│   │   ├── migrate.sh             # SSH panel migration
│   │   ├── menu.sh                # panel_menu, panel_submenu_*
│   │   └── py/
│   │       └── panel_branding.py  # update subscription page config JSON
│   │
│   ├── hysteria.sh                # loader (~6 строк)
│   ├── hy2/
│   │   ├── core.sh                # is_installed, is_running, get_domain/port
│   │   ├── install.sh             # install, uninstall
│   │   ├── users.sh               # add, delete, list (без inline Python)
│   │   ├── integration.sh         # webhook, merger, sub-injector
│   │   ├── menu.sh                # routing only
│   │   └── py/
│   │       ├── hy_config.py       # read/write config.yaml (все операции)
│   │       ├── hy_users_db.py     # CRUD users.json
│   │       └── hy_webhook_patch.py # structural patches hy-webhook.py
│   │
│   ├── telemt.sh                  # loader (~12 строк)
│   ├── tmt/
│   │   ├── core.sh                # чистые утилиты без UI
│   │   ├── install.sh             # установка, timer deploy
│   │   ├── users.sh               # CRUD через API + render
│   │   ├── manage.sh              # start/stop/update/logs
│   │   ├── menu.sh                # routing only (точка входа: telemt_section)
│   │   └── py/
│   │       ├── collect_stats.py   # writer: timer → SQLite
│   │       ├── render_users.py    # reader: SQLite → stdout
│   │       ├── status_render.py   # reader: API → JSON stdout
│   │       ├── user_ips.py        # reader: IP history from SQLite
│   │       ├── stats_settings.py  # reader/writer: retention settings
│   │       ├── init_db.py         # one-shot: schema creation
│   │       └── migrate_json_to_sqlite.py  # one-shot: legacy migration
│   │
│   ├── migrate.sh                 # migrate_menu: routing panel/hy2/tmt
│   │
│   └── cli/
│       ├── common.sh              # cli_ok/warn/err, cli_result_ok/err, cli_confirm
│       ├── flags.sh               # cli_context_init, cli_parse_flags → CLI_*
│       ├── exec.sh                # cli_exec_py_stream, cli_exec_py_capture, cli_exec_py_check
│       ├── router.sh              # cli_route: init → parse → dispatch
│       ├── panel.sh               # cli_panel + _cli_panel_*
│       ├── hy2.sh                 # cli_hy2 + _cli_hy2_*
│       ├── telemt.sh              # cli_telemt + _cli_telemt_*
│       └── system.sh              # cli_system + _cli_system_*
│
├── integrations/
│   ├── hy-webhook.py              # HTTP auth service (runtime)
│   ├── hy-merger.py               # subscription merger HTTP service
│   ├── hy-sub-install.sh          # установщик webhook + sub-injector
│   ├── hy_traffic_collect.py      # job: traffic → PostgreSQL
│   ├── hy_online_poller.py        # thread (в webhook) / future: systemd service
│   ├── hy_node_register.py        # one-shot: node registration
│   ├── hy_sync_users.py           # one-shot: userpass → users.json migration
│   └── hy_webhook_patch.py        # structural patches (threading)
│
├── sub-injector/                  # Rust/Axum subscription injector
│   ├── Cargo.toml
│   └── src/main.rs
│
├── tests/
│   └── cli/
│       ├── assert.sh              # assert_json, assert_no_status, assert_exit_code, ...
│       ├── smoke.sh               # CLI Execution Model smoke tests
│       └── run_cli_tests.sh       # CI entry point
│
└── docs/
    ├── ARCHITECTURE.md            # этот файл
    ├── CONTRACTS.md               # ENV/stdin/stdout/exit code per script
    ├── ENGINEER_GUIDELINES.md     # обязательные правила разработки
    ├── CHANGELOG.md
    └── TELEMT_CONFIG.md
```

---

## 6. Статус компонентов

### Остаётся без изменений
| Компонент | Статус |
|-----------|--------|
| `server-manager.sh` | ✅ entry point, расширяется CLI routing |
| `lib/hy2/core.sh` | ✅ чистые утилиты |
| `integrations/hy-webhook.py` | ✅ runtime service |
| `sub-injector/` | ✅ чистая архитектура |
| `lib/migrate.sh` | ✅ без изменений |

### Добавляется (новые файлы)
| Компонент | Приоритет |
|-----------|-----------|
| `lib/config.sh` | P0 |
| `lib/versions.sh` | P0 |
| `lib/ssh.sh` | P0 |
| `lib/main_menu.sh` | P0 |
| `lib/tmt/py/collect_stats.py` | P0 |
| `lib/tmt/py/render_users.py` | P0 |
| `lib/tmt/py/init_db.py` | P0 |
| `lib/hy2/py/hy_config.py` | P0 |
| `lib/hy2/py/hy_users_db.py` | P0 |
| `lib/cli/` (все файлы) | P1 |
| `lib/panel/` (все файлы) | P1 |
| `integrations/hy_traffic_collect.py` | P1 |
| `integrations/hy_online_poller.py` | P1 |
| `integrations/hy_node_register.py` | P1 |
| `lib/tmt/py/migrate_json_to_sqlite.py` | P1 |
| `scripts/remnawave_panel.sh` | P1 |
| `tests/cli/` | P2 |

### Deprecated (удаляется после миграции)
| Компонент | Заменяется на |
|-----------|--------------|
| `traffic.json` | `stats.db` (после `migrate_json_to_sqlite.py`) |
| inline `python3 << EOF` в `.sh` | `lib/*/py/*.py` скрипты |
| `cat > script.py << EOF` | файлы в `integrations/` |
| `docker exec ... psql` | `hy_node_register.py` |
| `echo >> .env` / `sed -i .env` | `_update_env_file()` паттерн |
| `get_hysteria_version()` в `panel.sh` | `lib/versions.sh` |
| `panel_api()` в `common.sh` | `lib/panel/core.sh` |
| SSH helpers в `common.sh` | `lib/ssh.sh` |
| `main_menu()` в `common.sh` | `lib/main_menu.sh` |

---

## 7. Конфликты и расхождения

### Найденные конфликты

**C1: `collect_stats.py` vs `telemt_fetch_links` (текущий writer)**

Сейчас `telemt_fetch_links` (Bash + Python) является единственной точкой записи трафика в `traffic.json`. После введения collector эта функция должна стать read-only (только читает `stats.db`). Пока оба механизма существуют одновременно — конфликт источников правды.

*Резолюция:* `traffic.json` замораживается (не обновляется) сразу после запуска `telemt-stats.timer`. `telemt_fetch_links` переключается на `render_users.py` в том же PR что вводит timer.

**C2: `hy_online_poller.py` читает globals из `hy-webhook.py`**

Текущая реализация online poller — inline в webhook, читает module-level globals. После выноса в отдельный файл (уже выполнено) — ENV читается самостоятельно. Конфликт устранён при условии что `hy-webhook.py` удалил inline-код и импортирует `from hy_online_poller import run`.

*Резолюция:* проверить что в `hy-webhook.py` нет дублирующего poller-кода после рефакторинга.

**C3: `panel.sh` содержит `get_hysteria_version()` и `get_telemt_version()`**

Дублируют функции из `lib/versions.sh`. При загрузке оба модуля в одном bash-пространстве — последний загруженный wins. Если `panel.sh` загружается после `versions.sh` — переопределяет правильные реализации своими (возможно устаревшими).

*Резолюция:* удалить дубли из `panel.sh` в рамках разбивки на `lib/panel/`. До разбивки — загружать `versions.sh` после `panel.sh` в `server-manager.sh`.

**C4: `common.sh` содержит функции из четырёх будущих модулей**

Пока `lib/config.sh`, `lib/ssh.sh`, `lib/main_menu.sh` не созданы — их функции живут в `common.sh`. Bash-пространство единое, конфликта имён нет, но нарушается SRP и затрудняется тестирование.

*Резолюция:* создать новые файлы с теми же функциями, в `common.sh` оставить как дубли на период перехода, удалить дубли после верификации.

### Отсутствующие конфликты (не проблема)

- collector vs render: WAL + `mode=ro` делает параллельный доступ безопасным
- `hy_config.py` vs `hy_users_db.py`: разные файлы, нет shared state
- TUI меню vs CLI: оба вызывают одни и те же domain-функции через одно bash-пространство

---

## 8. Verdict

**Архитектура согласована с оговорками.**

Ingestion модель, Python-контракты, CLI-слой и storage-схема — внутренне consistent. Конфликты (C1–C4) известны, локализованы и имеют конкретные резолюции.

### Что исправить до начала реализации collector

```
[ ] C3: добавить lib/versions.sh и загружать его ПОСЛЕ panel.sh в server-manager.sh
        (предотвращает silent override версионных функций)

[ ] C1: зафиксировать момент freeze traffic.json
        (договориться: collector вводится одним PR с переключением render)

[ ] Добавить lib/config.sh с централизованными константами
    (иначе collect_stats.py и init_db.py будут хардкодить пути)

[ ] Убедиться что /etc/telemt/telemt.env существует к моменту запуска timer
    (EnvironmentFile= в systemd unit упадёт если файл отсутствует)
```

### Что можно делать параллельно с реализацией

```
[ ] lib/hy2/py/ — полностью независим от ingestion
[ ] lib/cli/ — независим, не трогает storage
[ ] lib/panel/ — независим от telemt-слоя
[ ] tests/cli/ — независим
```

### Что делать в последнюю очередь

```
[ ] Удаление дублей из common.sh (после верификации новых модулей на prod)
[ ] Удаление traffic.json и migrate_json_to_sqlite.py (после 30 дней работы collector)
[ ] Разбивка panel.sh (самый рискованный рефакторинг, требует staging)
```

---

## 9. Архитектурный аудит (2026-04-24)

### Блокеры (устранить до начала реализации)

- **MP-2: Отсутствует механизм миграции схемы** — `init_db.py` создаёт схему, но не умеет обновлять её при изменениях. Первое изменение схемы потребует ручного вмешательства на каждом сервере. Решение: добавить таблицу миграций и блок применения по `schema_version`.
- **MP-1: Путь ingestion для IP-истории не определён** — `user_ips.py` присутствует в структуре и таблице §4, но в схеме SQLite нет таблицы `ip_history` и ни один компонент в неё не пишет. Необходимо либо добавить таблицу и источник данных, либо убрать `user_ips.py` из архитектуры.
- **HC-1: `status_render.py` не задокументирован как исключение** — §4 запрещает CLI обращаться к telemt API напрямую, но `status_render.py` делает именно это (данные статуса эфемерны и не хранятся в SQLite). Противоречие должно быть явно оговорено в §4 как задокументированное исключение.

### Обязательно (в рамках реализации)

- **FS-1: `collect_stats.py` должен самостоятельно проверять схему** — вызов `_ensure_schema()` при каждом старте (через `CREATE TABLE IF NOT EXISTS`) защищает от race condition между install и первым срабатыванием timer.
- **FS-2: systemd unit должен содержать `ConditionPathExists`** — при отсутствии `/etc/telemt/telemt.env` systemd завершает unit с кодом `203/EXEC` до запуска Python. Добавление `ConditionPathExists=/etc/telemt/telemt.env` делает поведение предсказуемым: unit просто пропускается с понятным статусом.
- **MP-3: Очистка данных по retention должна быть реализована** — без периодического удаления старых строк таблицы `daily` и `monthly` растут бесконечно. Cleanup следует добавить в `collect_stats.py` после commit'а, используя значение из `meta`.

### Известные ограничения

- Частичный ответ telemt API может вызвать временное искажение дельт на один цикл сбора.
- Сброс счётчика в момент сбора может дать завышенную дельту для отдельных пользователей в одном цикле — неустранимо без timestamp от API.
- Telemt API не предоставляет snapshot-консистентности; возможны временные рассинхроны между пользователями в одном ответе.

### Отложено (технический долг)

- Строгость границы CLI/TUI: domain-функции с интерактивными `read -rp` вызываются из CLI без гарантии наличия `CLI_YES` guard.
- Observability: разделить `last_collect_ts` (попытка) и `last_success_ts` (успешная запись); `render_users.py` показывать предупреждение если данные старше 20 минут.
- Рефакторинг `hy-sub-install.sh`: файл содержит deprecated паттерны (SQL через `docker exec`, `echo >> .env`), статус в §6 не определён.
