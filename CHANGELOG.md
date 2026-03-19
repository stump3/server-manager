# Changelog

## [2.0.0] — 2026-03

### Архитектура
- Монолит `setup.sh` (4299 строк) разбит на модули
- `server-manager.sh` — точка входа (39 строк)
- `lib/common.sh` — утилиты, цвета, главное меню
- `lib/panel.sh` — Remnawave Panel + Extensions
- `lib/telemt.sh` — MTProxy (telemt)
- `lib/hysteria.sh` — Hysteria2
- `lib/migrate.sh` — перенос сервисов
- `integrations/hy-sub-install.sh` — интеграция Hysteria2 → подписка
- Поддержка `curl | bash` — модули скачиваются автоматически

### Remnawave Panel
- Новое меню: Установка / Управление / WARP / Подписка / Selfsteal / Обновить / Перенос / Удалить
- WARP Native — добавление в профиль Xray через API панели
- Subscription Page — Orion шаблон, брендинг, восстановление
- Selfsteal шаблоны — Simple / SNI / Nothing SNI + случайный
- Remnawave CLI — docker exec -it remnawave remnawave
- Переустановка с подтверждением

### Hysteria2
- Port Hopping — диапазон UDP портов, обход блокировок
- IPv6 поддержка
- Переустановка с сохранением конфига
- Проверка SSL сертификата после установки

### Перенос
- Сжатый дамп БД (pg_dumpall + gzip)
- Проверка размера дампа
- Hysteria2 сертификаты при переносе
- Предложение остановить старый сервер
- backup-restore интеграция

### Исправления
- `curl | bash` — все `read` используют `/dev/tty`
- `BASH_SOURCE[0]` unbound variable при pipe-запуске
- Версия из git commit date
- `migrate_menu` была потеряна при разбивке — восстановлена
- Hysteria2 статус — парсинг пользователя через Python regex

## [1.0.0] — 2025-03
- Remnawave Panel: установка, управление, SSL, бэкап, миграция
- MTProxy (telemt): systemd и Docker, hot reload
- Hysteria2: установка, пользователи, подписка, миграция
- Единое главное меню с живым статусом
