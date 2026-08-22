# SM Integration: server-manager ↔ telemt

> Инженерный контракт. Определяет границы ответственности и допустимые взаимодействия
> между внешним telemt и server-manager. Нарушения этих правил — архитектурный регресс.

---

## 1. Роль telemt (external)

telemt — внешний runtime-сервис (Rust), управляемый через systemd или Docker.

**Что делает:**
- предоставляет текущее состояние: счётчики трафика, список пользователей, статус гейтов
- принимает команды управления: добавление/удаление пользователей, конфигурация

**Что НЕ делает:**
- не хранит историю трафика
- не является source of truth для статистики
- не знает о server-manager, SQLite и collector

Взаимодействие только через API на `localhost:9091`. Прямой доступ к файлам telemt (кроме `telemt.toml` при установке) — запрещён.

---

## 2. Роль telemt-модуля (lib/tmt/)

`lib/tmt/` — ingestion и storage слой внутри server-manager.

**Обязанности:**
- реализует collector (`collect_stats.py`): единственная точка чтения трафика из API
- владеет SQLite (`stats.db`): создаёт схему, пишет дельты, управляет retention
- предоставляет read-only рендеринг для CLI (`render_users.py`, `status_render.py`, `user_ips.py`)
- управляет жизненным циклом collector: установка и удаление systemd timer

**Не делает:**
- не содержит TUI/CLI логики (только `menu.sh` как routing)
- не управляет другими модулями (hy2, panel)
- не пишет в PostgreSQL и не взаимодействует с Remnawave

---

## 3. Роль server-manager (core)

`server-manager.sh`, `lib/common.sh`, `lib/config.sh`, `lib/cli/` — orchestration layer.

**Обязанности:**
- точка входа, загрузка модулей, routing между TUI и CLI
- предоставляет shared утилиты: print helpers, generators, SSH helpers
- делегирует всю бизнес-логику модулям (`lib/tmt/`, `lib/hy2/`, `lib/panel/`)

**Не делает:**
- не содержит ingestion логики
- не обращается к telemt API напрямую (только через Python-скрипты модуля)
- не читает и не пишет `stats.db` напрямую

---

## 4. Source of truth

| Данные | Source of truth | НЕ является |
|--------|----------------|-------------|
| Исторический трафик | `stats.db` (SQLite) | telemt API |
| Текущие счётчики | telemt API | `stats.db` |
| Конфигурация пользователей | `telemt.toml` | `stats.db`, API |
| Статус сервиса | telemt API (эфемерно) | SQLite |

`traffic.json` — **deprecated**. Не читается, не обновляется. Удаляется после миграции через `migrate_json_to_sqlite.py`.

---

## 5. Data flow

```
telemt API :9091
    │
    │  GET /v1/users  (каждые 10 минут, systemd timer)
    │  только collect_stats.py
    ▼
collect_stats.py
    │  вычисляет delta, обрабатывает reset
    │  BEGIN EXCLUSIVE
    ▼
/var/lib/telemt/stats.db  ←── единственный writer
    │
    │  read-only (uri=ro, WAL)
    ▼
render_users.py / user_ips.py / stats_settings.py
    │
    ▼
lib/tmt/menu.sh  /  lib/cli/telemt.sh
    │
    ▼
Пользователь


Параллельный поток — management (не статистика):

lib/tmt/users.sh  →  telemt API  →  add/delete/list users
                                      (не трафик, не counters)
```

---

## 6. Разрешённые взаимодействия

### server-manager → telemt API

Допустимо только для **management plane**:

| Операция | Endpoint | Кто вызывает |
|----------|----------|-------------|
| Добавить пользователя | `POST /v1/users` | `lib/tmt/users.sh` |
| Удалить пользователя | `DELETE /v1/users/:id` | `lib/tmt/users.sh` |
| Получить список пользователей (без трафика) | `GET /v1/users` | `lib/tmt/users.sh` |
| Получить ссылки | `GET /v1/links/:user` | `lib/tmt/users.sh` |
| Получить статус сервиса | `GET /v1/stats` | `status_render.py` |

### telemt-модуль → telemt API

Допустимо только для **ingestion**:

| Операция | Endpoint | Кто вызывает |
|----------|----------|-------------|
| Чтение трафика | `GET /v1/users` (с counters) | `collect_stats.py` |

### server-manager → SQLite

Допустимо только через Python-скрипты с read-only соединением:

| Скрипт | Режим | Операция |
|--------|-------|----------|
| `render_users.py` | ro | SELECT daily/monthly |
| `user_ips.py` | ro | SELECT ip_history |
| `stats_settings.py` | rw | SELECT/UPDATE meta |
| `status_render.py` | — | не обращается к SQLite |

---

## 7. Запрещённые взаимодействия

```
❌  CLI / Bash → telemt API для чтения трафика или счётчиков
    Причина: нарушает single-writer model, дублирует collector

❌  Любой .sh файл → SQL напрямую (sqlite3 CLI, docker exec psql)
    Причина: нарушает ENGINEER_GUIDELINES §5

❌  Любой модуль кроме collect_stats.py → запись в stats.db
    Причина: нарушает single-writer model

❌  Чтение traffic.json как источника данных
    Причина: deprecated, данные могут быть неактуальны или отсутствовать

❌  Прямой доступ к stats.db вне Python-скриптов (cat, sqlite3 в меню)
    Причина: обходит контракты, нет гарантий консистентности

❌  Дублирование delta-логики за пределами collect_stats.py
    Причина: расщепляет бизнес-логику, создаёт расхождения в данных

❌  status_render.py → stats.db
    Причина: статус сервиса эфемерен, в SQLite не хранится
```

---

## 8. Обязанности collector (`collect_stats.py`)

Collector — единственный компонент с правом записи в `stats.db`.

**Обязан:**
- быть единственным writer'ом для таблиц `snapshots`, `daily`, `monthly`
- вычислять delta как `current - previous` (если `current >= previous`)
- обрабатывать reset счётчика: `if current < previous → delta = current`
- отклонять аномально большие дельты (порог: 100 GB за интервал)
- пропускать цикл при пустом ответе API если `snapshots` непустые
- использовать `BEGIN EXCLUSIVE` для защиты от параллельного запуска
- вызывать `_ensure_schema()` при каждом старте (самодостаточность)
- удалять строки старше retention-периода после каждого успешного commit'а
- сохранять `pending_file` до записи в DB, удалять после успеха

**Не делает:**
- не читает `traffic.json`
- не пишет в PostgreSQL
- не взаимодействует с Remnawave

---

## 9. Обязанности CLI (`lib/cli/telemt.sh`, `lib/tmt/menu.sh`)

**Обязан:**
- читать статистику только через Python-скрипты (`render_users.py`, `user_ips.py`)
- вызывать management API только через `lib/tmt/users.sh`
- использовать `cli_exec_py_stream` / `cli_exec_py_capture` для всех вызовов Python
- соблюдать stdout/stderr контракт (ENGINEER_GUIDELINES §10)

**Не делает:**
- не обращается к telemt API для получения трафика или счётчиков
- не содержит delta-логики или любой другой ingestion-логики
- не пишет в `stats.db` и не читает его напрямую

---

## Сводная таблица границ

```
Компонент              telemt API    stats.db     traffic.json
                       mgmt / stats  read / write
─────────────────────────────────────────────────────────────
collect_stats.py        —  / read     —  / write    —
render_users.py         —  / —       read / —        —
status_render.py        —  / read     —  / —         —
user_ips.py             —  / —       read / —        —
stats_settings.py       —  / —       read / write    —
lib/tmt/users.sh       read / —       —  / —         —
lib/cli/telemt.sh       —  / —        —  / —         —
migrate_json_to_sqlite  —  / —        —  / write    read (one-shot)
любой .sh файл          ❌  / ❌       ❌  / ❌       ❌
```
