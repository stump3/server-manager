# Changelog

## [2.5.0] — 2026-03-21

### Установка и обновление

- **`curl | bash` теперь полноценный установщик** — при первом запуске через `curl | bash` скрипт автоматически клонирует репозиторий в `/root/server-manager/` и перезапускается оттуда. Если репозиторий уже есть — делает `git pull`. Больше не нужно отдельно клонировать вручную
- **Симлинк `/usr/local/bin/server-manager`** — создаётся автоматически, запуск одной командой `server-manager` из любого места
- **Обновление через меню** теперь синхронизирует все папки репозитория — `lib/`, `integrations/`, `sub-injector/` и любые новые папки которые появятся в будущем. Раньше обновлялась только `lib/`. Использует process substitution вместо pipe чтобы корректно отслеживать обновлённые директории
- **Версия из git тега** — `SCRIPT_VERSION_STATIC` в `common.sh` обновляется автоматически через GitHub Actions (`update-version.yml`) при каждом пуше в main. Формат `v2603.ДДHHMM` сохранён. Для сравнения версий при обновлении используется `SCRIPT_VERSION_STATIC` вместо динамического `git log`
- **`server-manager-repo.tar.gz` удалён** из репозитория — был устаревшим артефактом, скрипт обновления использует `archive/refs/heads/main.tar.gz` напрямую с GitHub

### GitHub Actions

- **`update-version.yml`** — новый workflow. При каждом пуше в main берёт дату коммита, записывает в `SCRIPT_VERSION_STATIC` и коммитит обратно с `[skip ci]`
- **`release.yml`** — существующий workflow для сборки `sub-injector`. Исправлен пример конфига в описании релиза: `per_user_url` вместо устаревшего `links_source = ".../{token}"`

### Интеграция Hysteria2 → Remnawave — исправления

- **`NEW_RANGE: unbound variable`** — переменная теперь объявляется как `NEW_RANGE=""` до `case`, проверка изменена на `if [ -n "$NEW_RANGE" ]`. Скрипт падал при выборе `0` (пропустить Port Hopping) из-за `set -euo pipefail`
- **`local` вне функции** — убраны `local SCRIPT_REPO_DIR` и `local INJECTOR_SRC` которые использовались вне функции (bash не поддерживает `local` на верхнем уровне)
- **`Text file busy`** — перед заменой бинарника `sub-injector` теперь выполняется `systemctl stop remna-sub-injector`. Касается как скачивания готового бинарника, так и сборки из исходников
- **Порядок операций при переустановке** — `hy-webhook.py` теперь копируется в `/opt/hy-webhook/` до записи `/etc/hy-webhook.env` и перезапуска сервиса. Раньше сервис перезапускался со старым кодом после записи `PROXY_PORT=0` → падал с `OSError: Address already in use`
- **`PROXY_PORT=0` как флаг отключения** — `hy-webhook.py` теперь корректно обрабатывает `PROXY_PORT=0`: встроенный proxy не запускается, логируется `"Встроенный proxy отключён — используется внешний sub-injector"`. Раньше Python пытался слушать порт 0 и падал
- **Rust/cargo при сборке** — если `~/.cargo/env` существует но `cargo` не в `PATH` (rustup установлен ранее), делается `source ~/.cargo/env` до проверки. Добавлена явная проверка `command -v cargo || err` после установки
- **Локальные исходники sub-injector** — скрипт сначала ищет `../sub-injector/src/main.rs` рядом с репозиторием, и только при отсутствии скачивает с GitHub
- **URL скачивания `hy-webhook.py`** исправлен на `integrations/hy-webhook.py` (был просто `hy-webhook.py` в корне)
- **Сообщение об ошибке** — `cleanup()` теперь показывает рамку с номером строки и командой, подсказку про `journalctl`, и ждёт нажатия Enter перед выходом. Экран больше не очищается мгновенно

---

## [2.4.0] — 2026-03-21

### Интеграция Hysteria2 → Remnawave — новая архитектура

- **sub-injector** — новый компонент (`sub-injector/`). Rust/Axum reverse-proxy (~3 MB бинарник) заменяет хрупкий форк TypeScript subscription-page. Поддерживает `per_user_url` — инжектор сам извлекает токен из пути запроса подписки и делает `GET /uri/{token}` в hy-webhook для получения персонального URI. Конфиг: `sub-injector/config.toml`. При отсутствии готового бинарника собирается из исходников через `cargo build --release`
- **hy-webhook.py** — серьёзное расширение. Добавлены: `GET /uri/:shortUuid` (персональный `hy2://` URI с TTL-кэшем), встроенный reverse-proxy на порту `3020` с UA-фильтрацией и инъекцией URI, поддержка переменных `REMNAWAVE_URL`, `REMNAWAVE_TOKEN`, `HY_DOMAIN`, `HY_PORT`, `HY_NAME`, `INJECT_UA_PATTERNS`. Clash/Sing-Box YAML-конфиги проходят без изменений
- **hy-sub-install.sh** — переработан. Шаг установки форка subscription-page заменён установкой `sub-injector` (systemd unit `remna-sub-injector`). Nginx перенаправляется с `:3010` на `:3020` (injector). Убрана сборка Docker образа (2-5 мин) — установка занимает ~1 минуту. Идемпотентность: проверяет `remna-sub-injector` вместо Docker образа

### Новая схема интеграции

```
Клиент (Hiddify/v2rayNG)
    ↓  GET /sub/TOKEN
remna-sub-injector :3020
    ↓  GET /uri/TOKEN → hy-webhook :8766
    ←  hy2://user:pass@domain:port?...
    ↓  проксирует на upstream :3010
    ←  base64 + hy2:// URI (инъекция)

Клиент (Clash/Sing-Box) → YAML без изменений
```

### Новые пути

| Путь | Назначение |
|---|---|
| `/opt/remna-sub-injector/sub-injector` | Бинарник sub-injector |
| `/opt/remna-sub-injector/config.toml` | Конфиг инжектора |
| `/etc/systemd/system/remna-sub-injector.service` | Systemd unit |

---


## [2.3.0] — 2026-03-20

### MTProxy (telemt) — новые возможности

- **Выбор режима подключения при установке** — скрипт спрашивает Direct (напрямую к Telegram DC, рекомендуется) или Middle-End relay. Параметр `use_middle_proxy` теперь задаётся явно, а не устанавливается в `true` по умолчанию
- **Переключение Direct ↔ ME из меню** — новый пункт «Режим подключения» в подменю Управление. Показывает текущий режим (`direct` / `middle-proxy`), применяет изменение с перезапуском сервиса
- **Управление пользователями через REST API** — добавление (`POST /v1/users`) и удаление (`DELETE /v1/users/{name}`) выполняются через API telemt. Изменения применяются мгновенно без SIGHUP; встроенная валидация секрета и имени
- **Множественное удаление пользователей** — в меню удаления показываются активные подключения и трафик; можно ввести несколько номеров через пробел (`1 3 5`) для одновременного удаления
- **Исправлен Docker-образ** — заменён сторонний `whn0thacked/telemt-docker:latest` на официальный `ghcr.io/telemt/telemt:latest` (GitHub Container Registry). Путь конфига внутри контейнера обновлён на `/run/telemt/config.toml`; добавлены `working_dir` и `tmpfs` для кэша proxy-secret

### README.md

- **Расширен раздел MTProxy** — добавлены: описание Direct vs Middle-End с архитектурными схемами, актуальные меню (Управление, Пользователи), таблица портов с telemt API, раздел REST API с примерами `curl`
- **Обновлена таблица портов** — добавлены порт telemt (`2053`/`8443`), порт API (`9091 localhost`)
- **Бейдж changelog** обновлён до v2.3.0

---

## [2.2.0] — 2026-03-20

### UX / Меню

- **`5) 🔄 Обновить скрипт`** вынесен в главное меню — обновление относится ко всему скрипту, а не только к панели
- **Remnawave Panel** — удалён пункт «Обновить скрипт», нумерация пересчитана (6 → Миграция, 7 → Удалить)
- **Выравнивание эмодзи** в меню: `▶️ Старт`, `⚙️ Управление` (panel/telemt/hysteria), `⏹️ Остановить`, `🔧 Установка` (telemt) — убраны лишние пробелы

### Исправления

- **Рекурсивные меню** → `while true`: `panel_menu`, `panel_warp_menu`, `panel_template_menu`, `panel_subpage_menu`, `panel_submenu_manage`, `migrate_menu`, `telemt_submenu_manage`, `telemt_submenu_users` — устранён потенциальный stack overflow при длительном использовании и падение при `set -e`
- **`|| true` на все case-ветки** в конвертированных меню — функции возвращающие non-zero больше не роняют скрипт при `set -euo pipefail`
- **`panel_update_script`** — теперь скачивает полный архив репозитория (`archive/refs/heads/main.tar.gz`) и обновляет все `lib/*.sh` модули. Ранее скачивался только loader (`server-manager.sh`, 64 строки), а модули оставались устаревшими
- **`_load_module` SHA256** — опциональная проверка контрольной суммы модулей при скачивании с GitHub. Заполните `_MODULE_SHA256` в `server-manager.sh` для защиты от компрометации репозитория
- **`_main_menu_load_cache`** — удалена (мёртвый код)
- **`▶️ Старт`** — исправлен отступ в `panel_submenu_manage`
- **`Enter...` без `/dev/tty`** — исправлены все broken redirects в heredoc `remnawave_panel`
- **`docker stats` выравнивание** — `awk -F"\t" '{printf "%-36s %6s   %s\n"}'` вместо tab-разделителей

---

## [2.1.0] — 2026-03-20

### Критические исправления

- **nginx MODE=1 (selfsteal)**: убран `listen 443 ssl` — nginx теперь слушает ТОЛЬКО `unix:/dev/shm/nginx.sock ssl proxy_protocol`. Ранее nginx занимал порт 443, из-за чего Xray не мог стартовать (`SPAWN_ERROR: xray — address already in use`)
- **hy-sub-install**: исправлен API URL `api/users/get-by/short-uuid/` → `api/users/by-short-uuid/`
- **hy-webhook**: `LISTEN_HOST=0.0.0.0` — webhook теперь доступен из Docker контейнеров
- **hy-webhook**: UFW правило `172.16.0.0/12 → 8766` добавляется автоматически при установке
- **docker-compose**: `REMNAWAVE_PANEL_URL` и `REMNAWAVE_API_TOKEN` добавляются в subscription-page
- **Python heredoc**: SYNCEOF, PATCHEOF, AXPATCHEOF, COMPOSEEOF переведены в quoted `'MARKER'` — bash не интерпретировал Python как bash-код

### Архитектура selfsteal (важно понимать)

```
Браузер / Клиент
    ↓  TCP :443
Xray (rw-core) — слушает 443, Reality selfsteal
    ↓  unix:/dev/shm/nginx.sock (proxy_protocol, xver=1)
nginx — слушает unix-сокет
    ↓  http://127.0.0.1:3000
Remnawave Panel
```

nginx НЕ слушает порт 443 в selfsteal режиме. Сокет `/dev/shm/nginx.sock` создаётся nginx при старте, Xray записывает в него трафик.

---

## [2.0.0] — 2026-03-19

### Архитектура
- Монолит `setup.sh` (4299 строк) разбит на модули
- `server-manager.sh` — точка входа (39 строк), загружает модули локально или с GitHub
- `lib/common.sh` — утилиты, цвета, главное меню, SSH-хелперы
- `lib/panel.sh` — Remnawave Panel + Extensions (1750 строк)
- `lib/telemt.sh` — MTProxy (telemt) (701 строка)
- `lib/hysteria.sh` — Hysteria2 (1213 строк)
- `lib/migrate.sh` — перенос сервисов (248 строк)
- `integrations/hy-sub-install.sh` — интеграция Hysteria2 → подписка
- Поддержка `curl | bash` — модули скачиваются автоматически

### Remnawave Panel
- Новое меню: Установка / Управление / WARP / Подписка / Selfsteal / Обновить / Перенос / Удалить
- WARP Native — добавление в профиль Xray через API панели
- Subscription Page — Orion шаблон, брендинг, восстановление
- Selfsteal шаблоны — Simple / SNI / Nothing SNI + случайный
- Remnawave CLI — `docker exec -it remnawave remnawave`
- Переустановка с подтверждением
- API автоматизация: `create_config_profile`, `create_node`, `create_host`, `update_squad`, `create_api_token`

### Hysteria2
- Port Hopping — диапазон UDP портов, обход блокировок по порту
- IPv6 поддержка
- Переустановка с сохранением конфига
- Проверка SSL сертификата после установки

### Интеграция Hysteria2 → Remnawave
- `hy-webhook.py` — Python HTTP-сервис синхронизации пользователей
- `hy-sub-install.sh` — форк subscription-page с инжекцией `hy2://` URI
- Port Hopping в URI подписки
- Webhook signature `X-Remnawave-Signature` (HMAC-SHA256)

### SSH-рефакторинг
- `ask_ssh_target()` — единый ввод SSH данных (было 5 копий)
- `init_ssh_helpers()` — инициализация RUN/PUT хелперов
- `check_ssh_connection()` — проверка соединения
- `remote_install_deps()` — установка зависимостей на remote

### Исправления
- `curl | bash` — все `read` используют `/dev/tty`
- `BASH_SOURCE[0]` unbound variable при pipe-запуске
- Версия из git commit date
- `migrate_menu` была потеряна при разбивке — восстановлена
- Hysteria2 статус — парсинг пользователя через Python regex

---

## [1.0.0] — 2025-03
- Remnawave Panel: установка, управление, SSL, бэкап, миграция
- MTProxy (telemt): systemd и Docker, hot reload
- Hysteria2: установка, пользователи, подписка, миграция
- Единое главное меню с живым статусом
