# Changelog

## [Unreleased]

### Изменено
- Репозиторий разделён на модули: `lib/common.sh`, `lib/panel.sh`, `lib/telemt.sh`, `lib/hysteria.sh`, `lib/migrate.sh`
- Главный файл переименован `setup.sh` → `server-manager.sh`
- Добавлен `integrations/hy-sub-install.sh` — интеграция Hysteria2 с подпиской Remnawave
- Добавлен Port Hopping в установку Hysteria2
- WARP Native, Subscription Page, Selfsteal шаблоны добавлены в меню Panel
- Улучшен перенос: сжатие дампа, проверка размера, Hysteria сертификаты
- Добавлен backup-restore через внешний скрипт

## [1.0.0] — 2025-03

### Добавлено
- Remnawave Panel: установка, управление, SSL, бэкап, миграция
- MTProxy (telemt): systemd и Docker режимы, hot reload пользователей
- Hysteria2: установка, пользователи, подписка, миграция
- Единое главное меню с живым статусом сервисов
