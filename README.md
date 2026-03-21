<div align="center">

# 🛠️ server-manager

> Модульная система установки и управления VPN-инфраструктурой на базе Remnawave + Hysteria2 + MTProxy.

```bash
curl -fsSL https://raw.githubusercontent.com/stump3/server-manager/main/server-manager.sh | bash
```

[![Docs](https://img.shields.io/badge/docs-интерактивные-3b82f6?style=flat-square)](https://stump3.github.io/server-manager/README.html)
[![Changelog](https://img.shields.io/badge/changelog-v2.4.0-22c55e?style=flat-square)](https://github.com/stump3/server-manager/blob/main/docs/CHANGELOG.md)
[![Engineer](https://img.shields.io/badge/инженерам-ENGINEER.md-f59e0b?style=flat-square)](https://github.com/stump3/server-manager/blob/main/docs/ENGINEER.md)

</div>

---

## Документация

| Файл | Описание |
|---|---|
| 📖 [docs/README.html](https://stump3.github.io/server-manager/README.html) | Интерактивная документация — тёмная тема, навигация, схемы архитектуры |
| 📋 [CHANGELOG.md](https://github.com/stump3/server-manager/blob/main/docs/CHANGELOG.md) | История изменений по версиям |
| 🔧 [docs/ENGINEER.md](https://github.com/stump3/server-manager/blob/main/docs/ENGINEER.md) | Для разработчиков — архитектура, API, диагностика |
| 📡 [docs/TELEMT_CONFIG.md](https://github.com/stump3/server-manager/blob/main/docs/TELEMT_CONFIG.md) | Справочник всех параметров конфига telemt (MTProxy) |

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
│   ├── panel.sh                # Remnawave Panel + Extensions (1750 строк)
│   ├── telemt.sh               # MTProxy (telemt)
│   ├── hysteria.sh             # Hysteria2 (1213 строк)
│   └── migrate.sh              # Перенос сервисов (248 строк)
├── integrations/
│   ├── hy-sub-install.sh       # Установка интеграции Hysteria2 → Remnawave
│   └── hy-webhook.py           # Webhook-сервис + reverse-proxy с инъекцией URI
└── sub-injector/
    ├── src/main.rs             # Rust/Axum reverse-proxy с per-user инъекцией
    ├── Cargo.toml
    └── config.toml.example     # Пример конфига
```

---

## Быстрый старт

```bash
curl -fsSL https://raw.githubusercontent.com/stump3/server-manager/main/server-manager.sh | bash
```

При первом запуске скрипт автоматически клонирует репозиторий в `/root/server-manager/` и перезапускается оттуда. Все компоненты — `lib/`, `integrations/`, `sub-injector/` — будут на месте.

Повторный запуск:

```bash
server-manager
```

Или:

```bash
bash /root/server-manager/server-manager.sh
```

Обновление через меню `5) Обновить скрипт` подтянет все изменения из репозитория.

---

## Главное меню

```
  SERVER-MANAGER  v2603.200312
  ────────────────────────────────────────────

  Remnawave Panel  ● запущена  v2.6.4
  MTProxy (telemt) ● запущен (systemd)
  Hysteria2        ● запущена  v2.7.1

  ────────────────────────────────────────────

  1)  🛡️  Remnawave Panel
  2)  📡  MTProxy (telemt)
  3)  🚀  Hysteria2
  4)  📦  Перенос

  5)  🔄  Обновить скрипт

  0)  Выход
```

---

## Remnawave Panel

### Режимы установки

| Режим | Описание |
|---|---|
| Панель + Нода | Reality selfsteal, Xray и панель на одном сервере |
| Только панель | Нода на отдельном сервере |

### Архитектура selfsteal (MODE=1)

```
Клиент → TCP 443 → Xray (rw-core) → unix:/dev/shm/nginx.sock → nginx → Remnawave
```

> **Важно:** nginx НЕ слушает порт 443. Порт 443 занимает Xray, который форвардит трафик в unix-сокет nginx через proxy_protocol.

### SSL

| Метод | Описание |
|---|---|
| Cloudflare DNS-01 | Wildcard сертификат, рекомендуется |
| ACME HTTP-01 | Let's Encrypt, простой |
| Gcore DNS-01 | Wildcard через Gcore |

### Меню Remnawave Panel

```
  1)  🔧  Установка
  2)  ⚙️  Управление
  3)  🌐  WARP Native
  4)  🎨  Страница подписки
  5)  🖼️  Selfsteal шаблон
  6)  📦  Миграция на другой сервер
  7)  🗑️  Удалить панель
```

### Меню управления (rp)

```
 1)  📋  Логи
 2)  📊  Статус
 3)  🔄  Перезапустить
 4)  ▶️  Старт
 5)  📦  Обновить
 6)  🔒  SSL
 7)  💾  Бэкап
 8)  🏥  Диагноз
 9)  🔓  Открыть порт 8443
10)  🔐  Закрыть порт 8443
11)  💻  Remnawave CLI
12)  🔧  Переустановить скрипт (rp)
```

### Доступ к панели

После установки cookie URL сохраняется в `/root/remnawave-credentials.txt`:

```
https://panel.example.com/auth/login?KEY=VALUE
```

---

## MTProxy (telemt)

[telemt](https://github.com/telemt/telemt) — реализация Telegram MTProto прокси на Rust + Tokio. Поддерживает TLS-маскировку, anti-replay, Prometheus-метрики и управление через REST API без перезапуска сервиса.

### Режимы запуска

| Режим | Описание |
|---|---|
| systemd | Бинарник с GitHub Releases, автозапуск, hot reload, рекомендуется |
| Docker | Образ `ghcr.io/telemt/telemt:latest` с GitHub Container Registry |

### Меню MTProxy

```
  📡  MTProxy (telemt)
  ────────────────────────────────────────────
  Версия  3.3.27  (systemd)
  Порт    2053

  1)  🔧  Установка
  2)  ⚙️  Управление
  3)  👥  Пользователи  2

  4)  📦  Миграция на другой сервер
  5)  🔀  Сменить режим (systemd ↔ Docker)

  0)  ◀️  Назад
```

```
  MTProxy — Управление
  ────────────────────────────────────────

  1)  📊  Статус и логи
  2)  🔄  Обновить
  3)  ⏹️  Остановить
  4)  🔀  Режим подключения  direct

  0)  ◀️  Назад
```

### Параметры установки

| Параметр | По умолчанию | Описание |
|---|---|---|
| Порт | 8443 | Рекомендуемые Telegram-порты: 443, 2053, 2083, 2087, 2096, 8443 |
| Домен-маскировка | petrovich.ru | Любой крупный HTTPS-сайт |
| Режим подключения | direct | Direct или Middle-End relay (см. ниже) |
| Секрет | авто | 32 hex-символа, генерируется автоматически |

### Direct vs Middle-End relay

При установке скрипт предлагает выбрать режим подключения прокси к серверам Telegram.

**Direct** (`use_middle_proxy = false`) — прокси подключается напрямую к Telegram DC серверам:

```
Клиент → твой сервер → Telegram DC
```

Меньше задержка, меньше RAM, проще конфигурация. Рекомендуется для большинства серверов.

**Middle-End relay** (`use_middle_proxy = true`) — прокси держит пул соединений к официальным Telegram relay-серверам, которые сами маршрутизируют трафик:

```
Клиент → твой сервер → Telegram ME relay → Telegram DC
```

Имеет смысл если у сервера плохая прямая IP-связность с Telegram DC — например, при блокировках на уровне ISP. Потребляет больше RAM (пул `me_writers`), при старте требует время на инициализацию пула.

Режим можно переключить в любой момент: **Управление → 4) Режим подключения**. Изменение требует перезапуска сервиса.

### Управление пользователями

Добавление и удаление пользователей выполняется через REST API telemt — изменения применяются мгновенно без перезапуска сервиса. Поддерживается удаление нескольких пользователей за раз (вводи номера через пробел: `1 3 5`).

#### Ограничения на пользователя

| Параметр | Описание |
|---|---|
| Макс. подключений | Максимум одновременных TCP-соединений |
| Макс. уникальных IP | Ограничение уникальных источников |
| Квота трафика (ГБ) | Лимит суммарного трафика |
| Срок действия (дней) | Автоматическое истечение доступа |

### REST API

telemt предоставляет HTTP API на `127.0.0.1:9091`. Основные эндпоинты:

| Метод | Путь | Описание |
|---|---|---|
| `GET` | `/v1/health` | Статус сервиса |
| `GET` | `/v1/system/info` | Версия, uptime, хэш конфига |
| `GET` | `/v1/stats/summary` | Подключения, пользователи, uptime |
| `GET` | `/v1/runtime/gates` | Режим ME, состояние пула |
| `GET` | `/v1/users` | Список пользователей со ссылками и статистикой |
| `POST` | `/v1/users` | Создать пользователя |
| `PATCH` | `/v1/users/{name}` | Изменить параметры пользователя |
| `DELETE` | `/v1/users/{name}` | Удалить пользователя |

Примеры:

```bash
# Получить ссылки для всех пользователей
curl -s http://127.0.0.1:9091/v1/users | jq '.data[] | {user: .username, link: .links.tls[0]}'

# Добавить пользователя с квотой 10 ГБ
curl -s -X POST http://127.0.0.1:9091/v1/users \
  -H "Content-Type: application/json" \
  -d '{"username":"alice","data_quota_bytes":10737418240}'

# Удалить пользователя
curl -s -X DELETE http://127.0.0.1:9091/v1/users/alice

# Текущие подключения и uptime
curl -s http://127.0.0.1:9091/v1/stats/summary | jq '.data | {uptime: .uptime_seconds, conns: .connections_total}'
```

> 📖 Полный справочник параметров конфига: [docs/TELEMT_CONFIG.md](docs/TELEMT_CONFIG.md)

---

## Hysteria2

### Установка

- Домен с ACME HTTP-01
- CA: Let's Encrypt / ZeroSSL / Buypass
- **Port Hopping** — диапазон UDP портов, обход блокировок по порту
- IPv6 поддержка
- Алгоритм: BBR / Brutal

### Port Hopping

```yaml
# config.yaml
listen: 0.0.0.0:8443,20000-29999
```

URI клиента: `hy2://user:pass@domain:8443,20000-29999?sni=domain&alpn=h3`

Совместимые клиенты: Hiddify, Nekoray, v2rayN 7.x+

> Hysteria2 использует **8443 UDP**. Порт 443 TCP занят Xray. Конфликта нет.

---

## Интеграция Hysteria2 → Подписка Remnawave

Добавляет персональный `hy2://` URI в подписку Remnawave автоматически при создании/изменении пользователя. Каждый пользователь получает уникальный URI со своим именем и паролем.

```bash
# Путь: Главное меню → 3) Hysteria2 → 4) Подписка → 3) Интеграция с Remnawave
```

### Схема работы

```
Remnawave  ──POST /webhook──►  hy-webhook :8766
                                    │
                            обновляет config.yaml
                                    │
                            Hysteria2 reload

Клиент (Hiddify/v2rayNG)
    ↓  GET /sub/TOKEN
remna-sub-injector :3020
    ↓  GET /uri/TOKEN  ──►  hy-webhook :8766  ──►  Remnawave API
    ←  hy2://user:pass@domain:port?sni=...
    ↓  проксирует на upstream :3010
    ←  base64 ответ + hy2:// URI (инъекция)

Клиент (Clash/Sing-Box)  →  YAML/JSON конфиг без изменений
```

### Компоненты

| Компонент | Тип | Описание |
|---|---|---|
| `hy-webhook.py` | Python systemd | Вебхук-сервис + `GET /uri/:shortUuid` + proxy :3020 |
| `sub-injector` | Rust бинарник | Reverse-proxy с per-user инъекцией URI по UA |

### Преимущества новой архитектуры

- Нет форка TypeScript и пересборки Docker образа — установка занимает ~1 минуту
- Клиенты Clash/Sing-Box получают YAML без изменений (проверка Content-Type)
- Разные наборы URI для разных клиентов через User-Agent фильтрацию
- sub-injector — независимый сервис, не зависит от версии subscription-page

---

## Файлы и пути

### Remnawave Panel

| Путь | Назначение |
|---|---|
| `/opt/remnawave/.env` | Конфигурация панели |
| `/opt/remnawave/docker-compose.yml` | Docker Compose |
| `/opt/remnawave/nginx.conf` | Nginx (cookie-ключ здесь) |
| `/opt/remnawave/backups/` | Бэкапы |
| `/usr/local/bin/remnawave_panel` | Скрипт управления `rp` |
| `/root/remnawave-credentials.txt` | Cookie URL для входа в панель |

### MTProxy (telemt)

| Путь | Назначение |
|---|---|
| `/usr/local/bin/telemt` | Бинарник |
| `/etc/telemt/telemt.toml` | Конфиг (владелец `telemt:telemt`) |
| `/opt/telemt/` | Рабочая директория (cache, tlsfront, proxy-secret) |
| `/etc/systemd/system/telemt.service` | Systemd unit |

### Hysteria2

| Путь | Назначение |
|---|---|
| `/usr/local/bin/hysteria` | Бинарник |
| `/etc/hysteria/config.yaml` | Конфигурация сервера |
| `/etc/systemd/system/hysteria-server.service` | Systemd unit |
| `/etc/systemd/system/hy-webhook.service` | Systemd unit webhook-синхронизации |
| `/root/hysteria-{домен}.txt` | URI подключения |
| `/root/hysteria-{домен}-users.txt` | URI всех пользователей |

### Интеграция (hy-webhook + sub-injector)

| Путь | Назначение |
|---|---|
| `/opt/hy-webhook/hy-webhook.py` | Python сервис |
| `/etc/hy-webhook.env` | Конфиг и секреты (права 600) |
| `/var/lib/hy-webhook/users.json` | База пользователей |
| `/opt/remna-sub-injector/sub-injector` | Бинарник sub-injector |
| `/opt/remna-sub-injector/config.toml` | Конфиг инжектора |
| `/etc/systemd/system/remna-sub-injector.service` | Systemd unit sub-injector |

---

## Требования

- `/opt/remnawave/` — Remnawave установлена через server-manager
- `/etc/hysteria/config.yaml` — Hysteria2 установлена через server-manager
- UFW разрешает `172.16.0.0/12 → 8766` (добавляется автоматически)

### Webhook в .env Remnawave

```env
WEBHOOK_ENABLED=true
WEBHOOK_URL=http://172.30.0.1:8766/webhook
WEBHOOK_SECRET_HEADER=<hex64>
```

> Адрес `172.30.0.1` — gateway Docker сети `remnawave-network`. Не `127.0.0.1` — Docker контейнер не видит localhost хоста.

---

## Перенос

```
1) Перенести Remnawave Panel
2) Перенести MTProxy
3) Перенести Hysteria2
4) Перенести всё (Panel + MTProxy + Hysteria2)
5) Бэкап / Восстановление
```

| Данные | Panel | MTProxy | Hysteria2 |
|---|---|---|---|
| Конфиг | ✓ | ✓ | ✓ |
| БД (pg_dumpall + gzip) | ✓ | — | — |
| SSL сертификаты | ✓ | — | ✓ |
| Пользователи | ✓ | ✓ | ✓ |

---

## Обновление

### Вариант 1 — через меню (рекомендуется)

Если скрипт уже установлен и запущен:

```
Главное меню → 5) Обновить скрипт
```

Скачивает свежий архив с GitHub и обновляет все модули `lib/*.sh`.

---

### Вариант 2 — полная переустановка с нуля

Если скрипта ещё нет или нужна чистая установка:

```bash
mkdir -p /root/lib

for mod in common panel telemt hysteria migrate; do
    curl -fsSL "https://raw.githubusercontent.com/stump3/server-manager/main/lib/${mod}.sh" \
        -o "/root/lib/${mod}.sh"
done

curl -fsSL "https://raw.githubusercontent.com/stump3/server-manager/main/server-manager.sh" \
    -o /root/server-manager.sh && chmod +x /root/server-manager.sh

bash /root/server-manager.sh
```

---

### Вариант 3 — обновить один модуль

Если нужно обновить только конкретный компонент:

```bash
# Заменить telemt.sh (MTProxy)
curl -fsSL "https://raw.githubusercontent.com/stump3/server-manager/main/lib/telemt.sh" \
    -o /root/lib/telemt.sh

# Или через tar-архив (все модули сразу)
curl -fsSL https://github.com/stump3/server-manager/archive/refs/heads/main.tar.gz \
    | tar -xz --strip-components=2 -C /root/lib server-manager-main/lib
```

---

### После обновления

Скрипт управления `remnawave_panel` (команда `rp`) хранится отдельно в `/usr/local/bin/remnawave_panel`. Он не обновляется автоматически. Чтобы применить изменения:

```
Главное меню → 1) Remnawave Panel → 2) Управление → 12) Переустановить скрипт (rp)
```

---

## Требования

### Система
- Ubuntu 20.04+ / Debian 11+
- Root доступ
- Docker, docker-compose, jq, certbot, openssl

### Порты

| Порт | Протокол | Компонент | Описание |
|---|---|---|---|
| `80` | TCP | certbot | Открывается на время выпуска SSL, потом закрывается |
| `443` | TCP | Xray/nginx | Remnawave Panel + Reality selfsteal |
| `2053` / `8443` | TCP | telemt | MTProxy (по выбору при установке) |
| `8443` | UDP | Hysteria2 | Основной порт + Port Hopping диапазон |
| `2222` | TCP | remnanode | Только из Docker сети 172.30.0.0/16 |
| `8766` | TCP | hy-webhook | Только из Docker сети 172.16.0.0/12 |
| `9091` | TCP | telemt API | Только localhost — управление через REST |
| `3020` | TCP | sub-injector | Reverse-proxy подписок с инъекцией URI |

### RAM

Минимум **2 GB RAM** для полного стека. Рекомендуется **4 GB**.

| Компонент | Потребление | Тип |
|---|---|---|
| remnawave (NestJS) | ~395 MB | Docker |
| remnanode (Xray) | ~88 MB | Docker |
| subscription-page | ~76 MB | Docker |
| remnawave-db (Postgres) | ~50 MB + ~195 MB workers | Docker |
| hysteria2 | ~17 MB (peak 53 MB) | systemd |
| telemt | ~18 MB (peak 83 MB) | systemd |
| hy-webhook | ~1 MB | systemd |
| sub-injector | ~3 MB | systemd |
| nginx + redis | ~10 MB | Docker |
| **Итого** | **~850 MB** | |

> **Примечание:** 395 MB для remnawave — норма для NestJS + BullMQ + TypeORM стека.

### Swap
Рекомендуется минимум **1 GB swap**. При 2 GB RAM telemt и другие сервисы в пике уходят в swap (~47-83 MB).

---

## Лицензия

MIT
