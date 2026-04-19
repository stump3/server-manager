# Changelog

## [3.3.1] — 2026-04-19

### Патч — Hysteria2 ↔ Remnawave интеграция

- **Пауза после запуска установки интеграции в меню** — в пункте `1) Установить / переустановить` добавлено ожидание `Нажмите Enter для продолжения...` после выполнения `_hy_integration_install`.  
  Это фиксирует сценарий, когда итог установки исчезал из-за немедленной перерисовки меню и `clear`.

- **Очистка временного `hy-sub-install.sh` при ошибке** — `_hy_integration_install()` теперь удаляет временно скачанный скрипт не только при успехе, но и перед `return 1` в ветке ошибки.

- **Убрана неявная повторная установка `sub-injector`** — после `hy-sub-install.sh` больше не вызывается `_hy_sub_injector_install()` автоматически.  
  Это устраняет второй проход установки (визуально выглядел как «цикл установки» после Enter).

- **Усилен systemd unit `remna-sub-injector`** в `_hy_sub_injector_install()`:
  - добавлен `WorkingDirectory=/opt/remna-sub-injector`
  - `ExecStart` запускает бинарник без передачи `config.toml` аргументом
  - сохранены параметры устойчивости и диагностики: `Restart=on-failure`, `RestartSec=5`, `StandardOutput=journal`, `StandardError=journal`
  
  Это устраняет падения вида `Cannot read config file config.toml` при старте сервиса.

---

## [3.3.0] — 2026-04-18

### MTProxy (telemt) — runtime статистика и IP-история

- **Накопительный трафик пользователей (`Собрано`)** — добавлено сохранение runtime счётчиков в файл статистики:
  - systemd: `/var/lib/telemt/traffic-usage.json`
  - docker: `${HOME}/mtproxy/traffic-usage.json`
  Логика устойчива к сбросу `total_octets` при рестарте/переустановке telemt: при уменьшении счётчика считается новый baseline, а накопление продолжается.

- **История IP по каждому пользователю** — в статистику добавлены `first_seen`, `last_seen`, `hits` по IP.
  Источники — `active_unique_ips_list` и `recent_unique_ips_list` из API `/v1/users`.

- **Retention IP-истории в днях (настраивается из меню)** — новый пункт:
  - `👥 Пользователи → ⚙️ Настройки сбора (трафик/IP)`
  Позволяет задать срок хранения IP-истории (1..3650 дней) и сразу очищает устаревшие записи.

- **Просмотр IP-истории в отдельном меню** — новый пункт:
  - `👥 Пользователи → 🌐 IP история пользователя`
  Выбор пользователя и табличный вывод `IP / First seen / Last seen / Hits`.

### Миграция MTProxy и Panel — совместимость и устойчивость

- **Корректное извлечение `tls_domain` при миграции** — добавлен helper `telemt_get_tls_domain`, который берёт текущий домен из `telemt.toml`.
  Prompt в миграции теперь подставляет фактический домен (например, `1c.ru`), а не fallback `petrovich.ru`.

- **Перенос лимитов и сроков действия пользователей** — добавлен helper `telemt_extract_limits_block`, поддерживающий:
  - новый формат: `access.user_max_tcp_conns`, `access.user_expirations`, `access.user_data_quota`, `access.user_max_unique_ips`
  - legacy формат: `access.user_limits.*`
  Используется как в отдельной миграции MTProxy, так и в «Перенести всё».

- **`panel_migrate` fallback** — если функция `do_migrate` недоступна в `panel.sh`, используется `panel_menu migrate`; при отсутствии обоих entrypoint выводится явная ошибка.

---

## [3.2.0] — 2026-04-14

### Выбор веб-сервера при установке панели: Nginx или Caddy

Установка панели теперь предлагает выбор между двумя веб-серверами до ввода доменов. Выбор сохраняется на весь жизненный цикл установки и отражается во всех генерируемых файлах и скриптах управления.

**Nginx** — поведение без изменений: certbot, три метода получения сертификатов (Cloudflare DNS-01, Let's Encrypt HTTP-01, Gcore DNS-01), renew_hook в certbot renewal конфигах, nginx.conf.

**Caddy** — новый путь:
- certbot **не устанавливается** — пакеты certbot и cloudflare-plugin пропускаются
- SSL получается автоматически через встроенный ACME при первом запуске (Let's Encrypt)
- `Caddyfile` генерируется вместо `nginx.conf`
- В selfsteal-режиме (MODE=1) Caddy слушает unix-сокет `/dev/shm/nginx.sock` идентично Nginx — полная совместимость с Xray proxy_protocol
- В режиме только-панель (MODE=2) Caddy слушает напрямую, включая 80/tcp для ACME challenge

#### Четыре шаблона compose

| WEB_SERVER | MODE | Контейнер | Особенности |
|---|---|---|---|
| Nginx | 1 (панель+нода) | remnawave-nginx | unix socket, proxy_protocol, certbot |
| Nginx | 2 (только панель) | remnawave-nginx | listen 443, certbot |
| Caddy | 1 (панель+нода) | remnawave-caddy | unix socket, автоSSL через ACME |
| Caddy | 2 (только панель) | remnawave-caddy | прямой bind, автоSSL через ACME |

#### Caddy: OAuth2 Telegram из коробки

`Caddyfile` содержит обработчики `@oauth2` и `@oauth2_bad` — полный паритет с `location ^~ /oauth2/` в nginx.conf, включая проверку `Referer: oauth.telegram.org`.

#### Скрипт управления `rp` — Caddy-осведомлённость

`_detect_ws()` определяет веб-сервер в рантайме по наличию `remnawave-caddy` в docker-compose.yml. Все команды адаптированы:

- `rp ssl` — для Caddy: `caddy reload` вместо `certbot renew`
- `rp health` — для Caddy: `caddy validate` вместо `nginx -t`; SSL-секция через certbot пропускается
- `rp backup` — сохраняет `Caddyfile` вместо `nginx.conf`
- `rp logs nginx|caddy` — работает для обоих
- `rp restart nginx|caddy` — работает для обоих
- `rp open_port` / `rp close_port` — для Caddy выводит предупреждение (не применимо)

#### `panel_reinstall_mgmt` — поддержка обоих конфигов

При переустановке скрипта `rp` параметры (домен, cookie) извлекаются из `Caddyfile` если `nginx.conf` отсутствует.

---

## [3.1.0] — 2026-03-25

### 🔧 Исправления — hysteria.sh

- **Атомарные записи конфига Hysteria2** — три операции `sed -i` заменены на паттерн `mktemp → модификация → mv`:
  - `hysteria_delete_user()` — удаление строки через `grep -v` в tmpfile
  - `hysteria_add_user()` — вставка новой строки через `awk` в tmpfile  
  - Обновление пароля — `sed` без флага `-i`, результат через tmpfile  
  Если процесс прерывается в момент записи — конфиг остаётся целым, Hysteria2 не теряет рабочее состояние.

- **Устранено двойное объявление `auth_mode` / `auth_badge` в `hysteria_remnawave_integration()`** — переменные объявлялись и вычислялись дважды подряд в одном цикле (строки 1196–1240). Оставлен один блок с унифицированным текстом бейджа. Исключает расхождение при изменении логики определения режима auth.

### 🔧 Исправления — migrate.sh

- **`sleep 20` → `pg_isready` polling** — фиксированное ожидание после `docker compose up -d remnawave-db` заменено циклом `until pg_isready ... do sleep 1 done` с таймаутом 60 секунд. На медленных серверах исключает попытку восстановления дампа до готовности PostgreSQL; на быстрых снижает задержку.

---

## [3.0.0] — 2026-03-21

### HTTP аутентификация Hysteria2 — главное улучшение

- **HTTP auth вместо userpass** — hysteria больше не хранит пользователей в `config.yaml`. При каждом подключении клиента hysteria делает `POST /auth` к hy-webhook который проверяет `users.json`. Добавление/удаление пользователей не требует перезапуска hysteria — соединения активных клиентов не разрываются

- **Схема:** `auth.type: http` + `url: http://127.0.0.1:8766/auth`. hy-webhook отвечает `{"ok": true, "id": username}` или `{"ok": false}`

- **Отменён `reload_hysteria()`** в `process_event` — при HTTP auth режиме перезапуск при изменении пользователей не нужен. `update_hysteria_config()` оставлен как fallback для совместимости

- **Меню управления auth** — новый пункт `2) 🔐 Режим аутентификации` в меню интеграции. Показывает текущий режим (HTTP auth / userpass), позволяет переключать без ручного редактирования конфига. Статус auth режима отображается в шапке меню интеграции

### Диагностика задержек — выводы

В ходе отладки установлено: 30-секундная задержка при создании пользователей через браузер возникала из-за того что клиент подключался к панели **через Hysteria2 VPN**. При перезапуске hysteria VPN соединение рвалось и браузер ждал переподключения. Через VLESS пользователь создавался за <1с. HTTP auth полностью устраняет эту проблему.

### Исправления

- **`process_event` — фоновая обработка** — `_respond(200)` отправляется до запуска обработки в фоне. Remnawave получает ответ немедленно, не дожидаясь обновления `users.json`
- **Debounce перезапуска hysteria** — `threading.Timer(2.0)` батчит несколько событий подряд в один перезапуск (актуально при режиме userpass)
- **`X-Forwarded-For` + `X-Forwarded-Proto`** в запросах к Remnawave API — без них API возвращал `Empty reply` или `Reverse proxy required`
- **URL API** исправлен: `api/users/get-by/short-uuid/` → `api/users/by-short-uuid/`
- **`WEBHOOK_URL`** в `.env` панели исправлен на `http://172.30.0.1:8766/webhook` — из Docker контейнера `127.0.0.1` это сам контейнер, не хост
- **`docker compose up --force-recreate`** вместо `restart` для применения изменений `.env`

---

## [2.5.2] — 2026-03-21

### Патч — hy-webhook и меню интеграции

#### hy-webhook.py

- **Многопоточный HTTP сервер** — `ThreadingMixIn + HTTPServer` → `ThreadedHTTPServer`. Каждый входящий вебхук обрабатывается в отдельном потоке. Панель Remnawave больше не зависает при создании пользователя пока Hysteria2 перезапускается
- **Фоновый перезапуск Hysteria2** — `reload_hysteria()` запускает `systemctl reload-or-restart` в daemon-потоке и сразу возвращает управление. HTTP ответ отправляется до завершения перезапуска
- **Исправлен заголовок подписи** — `X-Webhook-Signature` → `X-Remnawave-Signature`. Remnawave отправляет подпись именно в этом заголовке
- **Исправлена верификация подписи** — Remnawave использует HMAC-SHA256(body, secret), не plain-text. Убран ошибочный plain-text fallback
- **`LISTEN_HOST`** — webhook сервер теперь читает переменную окружения `LISTEN_HOST` (по умолчанию `0.0.0.0`). Docker контейнеры могут достучаться через gateway `172.30.0.1`
- **`DEBUG_LOG`** — новая переменная окружения. При `DEBUG_LOG=1` уровень логирования переключается на `DEBUG`: входящие запросы, детали URI кэша, верификация подписи

#### Меню интеграции (hysteria.sh)

- **Расширенное меню** вместо прямого запуска `hy-sub-install.sh`. Пункт 3 подменю Подписка теперь открывает меню управления интеграцией:
  - `1) Установить / переустановить` — запуск `hy-sub-install.sh`
  - `2) Добавить UA-паттерн` — добавить новый клиент в `contains` конфига sub-injector без ручного редактирования файла
  - `3) Многопоточность` — включить/выключить `ThreadedHTTPServer` на живом сервисе
  - `4) Расширенное логирование` — переключить `DEBUG_LOG` в `/etc/hy-webhook.env` и перезапустить
  - `5) Логи hy-webhook` — `journalctl -u hy-webhook -n 50`
  - `6) Логи sub-injector` — `journalctl -u remna-sub-injector -n 50`

---

## [2.5.1] — 2026-03-21

### Патч — исправления

- **`/root/server-manager/bash`** — `$0` при запуске `bash server-manager.sh` содержит `bash`, а не путь к файлу. Теперь используется `BASH_SOURCE[0]` с fallback на `SCRIPT_DIR/server-manager.sh`. Скрипт обновления больше не показывает некорректный путь
- **Экран очищается после установки интеграции** — после успешного завершения `hy-sub-install.sh` управление возвращалось в меню Hysteria2 которое вызывало `clear`. Добавлен `read "Нажмите Enter..."` в конце скрипта — итоговый вывод (статус сервисов, webhook secret, команды проверки) остаётся на экране

---

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

---

## [1.0.0] — 2025-03
- Remnawave Panel: установка, управление, SSL, бэкап, миграция
- MTProxy (telemt): systemd и Docker, hot reload
- Hysteria2: установка, пользователи, подписка, миграция
- Единое главное меню с живым статусом
