<div align="center">

# 🛠️ server-manager

> Модульная система установки и управления VPN-инфраструктурой на базе Remnawave + Hysteria2 + MTProxy.

```bash
curl -fsSL https://raw.githubusercontent.com/stump3/server-manager/main/server-manager.sh | bash
```

[![Docs](https://img.shields.io/badge/docs-интерактивные-3b82f6?style=flat-square)](https://stump3.github.io/server-manager/README.html)
[![Changelog](https://img.shields.io/badge/changelog-v3.2.0-22c55e?style=flat-square)](docs/CHANGELOG.md)
[![Engineer](https://img.shields.io/badge/инженерам-ENGINEER.md-f59e0b?style=flat-square)](docs/ENGINEER.md)

</div>

---

## Документация

| Файл | Описание |
|---|---|
| 📖 [docs/README.html](docs/README.html) | Интерактивная документация — тёмная тема, навигация, схемы архитектуры |
| 📋 [docs/CHANGELOG.md](docs/CHANGELOG.md) | История изменений по версиям |
| 🔧 [docs/ENGINEER.md](docs/ENGINEER.md) | Для разработчиков — архитектура, API, диагностика, анализ кода |

---

## Компоненты

| Компонент | Описание |
|---|---|
| 🛡️ **Remnawave Panel** | VPN-панель с Xray/Reality selfsteal, cookie-защитой, WARP Native |
| 📡 **MTProxy (telemt)** | Telegram MTProto прокси на Rust, systemd / Docker |
| 🚀 **Hysteria2** | Высокоскоростной VPN поверх QUIC/UDP, Port Hopping |

---

## Структура репозитория

```
server-manager/
├── server-manager.sh           # Точка входа — загружает модули
├── lib/
│   ├── common.sh               # Утилиты, цвета, главное меню, SSH-хелперы
│   ├── panel.sh                # Remnawave Panel + Extensions (2332 строк)
│   ├── telemt.sh               # MTProxy (telemt) (873 строки)
│   ├── hysteria.sh             # Hysteria2 (1513 строк)
│   └── migrate.sh              # Перенос сервисов (255 строк)
└── integrations/
    ├── hy-sub-install.sh       # Интеграция Hysteria2 → подписка Remnawave
    └── hy-webhook.py           # Webhook синхронизации пользователей
```

---

## Быстрый старт

```bash
curl -fsSL https://raw.githubusercontent.com/stump3/server-manager/main/server-manager.sh | bash
```

Или локально:

```bash
git clone https://github.com/stump3/server-manager
cd server-manager
bash server-manager.sh
```

---

## Главное меню

```
  SERVER-MANAGER  v2604.xxxxxx
  ────────────────────────────────────────────

  Remnawave Panel  ● запущена  v2.x.x
  MTProxy (telemt) ● запущен (systemd)
  Hysteria2        ● запущена  v2.x.x

  ────────────────────────────────────────────

  1)  🛡️  Remnawave
  2)  📡  MTProxy (telemt)
  3)  🚀  Hysteria2

  4)  📦  Перенос

  5)  🔄  Обновить скрипт

  0)  Выход
```

---

## Remnawave Panel

### Установка

При установке задаются три вопроса последовательно:

**1. Режим:**
```
  1) Панель + Нода (Reality selfsteal, всё на одном сервере)
  2) Только панель (нода на отдельном сервере)
```

**2. Веб-сервер:**
```
  1) Nginx   (SSL через certbot — Cloudflare / Let's Encrypt / Gcore)
  2) Caddy   (SSL автоматически — встроенный ACME, certbot не нужен)
```

**3. SSL-метод (только для Nginx):**
```
  1) Cloudflare DNS-01 (wildcard, рекомендуется)
  2) ACME HTTP-01 (Let's Encrypt)
  3) Gcore DNS-01 (wildcard)
```

Скрипт автоматически:
- Выпускает сертификаты и настраивает автообновление (Nginx) или делегирует это Caddy (ACME)
- Генерирует `docker-compose.yml`, `.env`, `nginx.conf` / `Caddyfile` с cookie-защитой панели и OAuth2 Telegram
- Регистрирует суперадмина через API
- Генерирует x25519-ключи для Reality
- Создаёт config-profile, ноду, хост и squad
- Устанавливает команду `remnawave_panel` (`rp`)

### Архитектуры

**Selfsteal (MODE=1)**

```
Клиент TCP :443
    │
Xray — Reality selfsteal (порт 443)
    │  unix:/dev/shm/nginx.sock  proxy_protocol xver=1
    │
Nginx / Caddy — unix socket
    ├── panel.example.com  →  Remnawave :3000  (cookie-защита)
    ├── sub.example.com    →  Sub page :3010
    └── node.example.com   →  /var/www/html (decoy)
```

**Только панель (MODE=2)**

```
Клиент TCP :443
    │
Nginx (listen 443) / Caddy (bind 0.0.0.0)
    ├── panel.example.com  →  Remnawave :3000  (cookie-защита)
    ├── sub.example.com    →  Sub page :3010
    └── node.example.com   →  /var/www/html (decoy)
```

### Веб-сервер: Nginx vs Caddy

| | Nginx | Caddy |
|---|---|---|
| SSL | certbot (Cloudflare / LE / Gcore) | встроенный ACME (Let's Encrypt) |
| Конфиг | `nginx.conf` | `Caddyfile` |
| MODE=1 (selfsteal) | unix socket, proxy_protocol | unix socket, proxy_protocol |
| MODE=2 (панель) | listen 443 | bind 0.0.0.0, HTTP автоматически |
| OAuth2 Telegram | `location ^~ /oauth2/` | `@oauth2` matcher |
| `rp ssl` | `certbot renew` + nginx reload | `caddy reload` |
| `rp health` | `nginx -t` + certbot dates | `caddy validate` |

### Управление (команда `rp`)

```bash
rp                  # интерактивное меню
rp status           # статус контейнеров + потребление CPU/RAM
rp logs [nginx|caddy|sub|node]  # логи (default: panel)
rp restart [all|nginx|caddy|panel|sub|node]
rp start / stop
rp update           # docker compose pull + restart
rp ssl              # обновить SSL (certbot или caddy reload)
rp backup           # дамп БД + архив конфигов
rp health           # SSL, веб-сервер, API
rp open_port        # временный доступ через :8443 (только Nginx)
rp close_port       # закрыть :8443
rp migrate          # перенос панели на другой сервер
```

### Порты панели

| Порт | Протокол | Назначение |
|---|---|---|
| 443 | TCP | Xray (selfsteal) / Nginx / Caddy |
| 2222 | TCP | remnanode (внутренний) |
| 3000 | TCP | Remnawave API (localhost) |
| 3001 | TCP | Prometheus metrics (localhost) |
| 3010 | TCP | Subscription page (localhost) |
| 6767 | TCP | PostgreSQL (localhost) |

---

## MTProxy (telemt)

Telegram MTProto прокси на Rust. Два режима запуска: **systemd** (рекомендуется) и **Docker**.

### Меню

```
  1)  🔧  Установка
  2)  ⚙️  Управление
  3)  👥  Пользователи
  0)  ◀️  Назад
```

### REST API

telemt поднимает HTTP API на `127.0.0.1:9091`:

```bash
# Список пользователей
curl http://127.0.0.1:9091/v1/users

# Добавить пользователя
curl -X POST http://127.0.0.1:9091/v1/users \
  -H "Content-Type: application/json" \
  -d '{"name":"user1","secret":"abcdef1234567890abcdef1234567890"}'

# Удалить пользователя
curl -X DELETE http://127.0.0.1:9091/v1/users/user1
```

### Порты MTProxy

| Порт | Протокол | Назначение |
|---|---|---|
| 2053 | TCP | MTProto (основной, меняется при установке) |
| 8443 | TCP | MTProto (альтернативный) |
| 9091 | TCP | REST API (localhost) |

---

## Hysteria2

Высокоскоростной VPN поверх QUIC/UDP. Аутентификация через HTTP webhook (hy-webhook.py) — добавление и удаление пользователей без перезапуска.

### Меню

```
  1)  🔧  Установка
  2)  ⚙️  Управление
  3)  👥  Пользователи
  4)  🔗  Подписка и интеграция
  0)  ◀️  Назад
```

### Схема интеграции с Remnawave

```
Клиент (Hiddify/v2rayNG)
    ↓  GET /sub/TOKEN
remna-sub-injector :3020
    ↓  GET /uri/TOKEN → hy-webhook :8766
    ←  hy2://user:pass@domain:port?...
    ↓  проксирует на Remnawave sub :3010
    ←  base64 подписка с инжектированным hy2:// URI
```

### Порты Hysteria2

| Порт | Протокол | Назначение |
|---|---|---|
| 443 | UDP | Hysteria2 |
| 8766 | TCP | hy-webhook API (localhost) |
| 3020 | TCP | sub-injector (localhost) |

---

## Docker и образы

| Образ | Версия | Назначение |
|---|---|---|
| `remnawave/backend` | 2 | Remnawave Panel API |
| `remnawave/node` | latest | remnanode (Xray) |
| `remnawave/subscription-page` | latest | Страница подписки |
| `postgres` | 18.3 | База данных |
| `valkey/valkey` | 9.0.3-alpine | Redis (Unix socket) |
| `nginx` | 1.28 | Веб-сервер (если выбран) |
| `caddy` | 2.11.2 | Веб-сервер (если выбран) |

Valkey работает через Unix-сокет `/var/run/valkey/valkey.sock` — нет TCP-порта, меньше overhead.

---

## Миграция

Перенос любого компонента на другой сервер через SSH:
- Дамп БД PostgreSQL → восстановление на целевом сервере
- Передача конфигов, SSL-сертификатов, сайта
- Установка зависимостей на целевом сервере
- Запуск стека

Вызов: `rp migrate` или пункт **4) Перенос** в главном меню.
