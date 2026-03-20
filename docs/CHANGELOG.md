# Changelog

## [2.2.0] — 2026-03-20

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
