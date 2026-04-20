<div align="center">

# 🛠️ server-manager

> Модульная система установки и управления VPN-инфраструктурой на базе Remnawave + Hysteria2 + MTProxy.

```bash
curl -fsSL https://raw.githubusercontent.com/stump3/server-manager/main/server-manager.sh | bash
```

[![Docs](https://img.shields.io/badge/docs-интерактивные-3b82f6?style=flat-square)](https://stump3.github.io/server-manager/README.html)
[![Changelog](https://img.shields.io/badge/changelog-v3.3.1-22c55e?style=flat-square)](docs/CHANGELOG.md)
[![Engineer](https://img.shields.io/badge/инженерам-ENGINEER.md-f59e0b?style=flat-square)](docs/ENGINEER.md)

</div>

---

## Документация

| Файл | Описание |
|---|---|
| 📖 [docs/README.html](docs/README.html) | Интерактивная документация — тёмная тема, навигация, схемы |
| 📋 [docs/CHANGELOG.md](docs/CHANGELOG.md) | История изменений по версиям |
| 🔧 [docs/ENGINEER.md](docs/ENGINEER.md) | Для разработчиков — архитектура, API, диагностика |

---

## Компоненты

| Компонент | Описание |
|---|---|
| 🛡️ **Remnawave Panel** | VPN-панель с Xray/Reality selfsteal, cookie-защитой, WARP Native |
| 📡 **MTProxy (telemt)** | Telegram MTProto прокси на Rust, ME режим, hot reload |
| 🚀 **Hysteria2** | Высокоскоростной VPN поверх QUIC/UDP, Port Hopping |
| 🪝 **hy-webhook** | Синхронизация пользователей Remnawave → Hysteria2 |
| 🔧 **sub-injector** | Инжектор `hy2://` URI в подписку Remnawave |

---

## Структура репозитория

```
server-manager/
├── server-manager.sh           # Точка входа — загружает модули локально или с GitHub
├── lib/
│   ├── common.sh               # Утилиты, цвета, главное меню, SSH-хелперы
│   ├── panel.sh                # Remnawave Panel + Extensions
│   ├── telemt.sh               # MTProxy (telemt)
│   ├── hysteria.sh             # Loader: подключает модули из lib/hy2/
│   ├── hy2/
│   │   ├── core.sh             # Утилиты, проверки, чтение config.yaml
│   │   ├── install.sh          # hysteria_install
│   │   ├── users.sh            # add/delete/show links
│   │   ├── integration.sh      # Интеграция с Remnawave
│   │   └── menu.sh             # Меню, migrate, merge-sub, submenu_*
│   └── migrate.sh              # Перенос сервисов между серверами
├── integrations/
│   ├── hy-sub-install.sh       # Установка интеграции Hysteria2 → Remnawave
│   └── hy-webhook.py           # Python-сервис синхронизации пользователей
├── sub-injector/               # Rust-прокси для инжекции hy2:// в подписку
│   ├── src/main.rs
│   └── Cargo.toml
└── docs/
    ├── README.html             # Интерактивная документация (GitHub Pages)
    ├── CHANGELOG.md
    └── ENGINEER.md
```

---

## Быстрый старт

```bash
curl -fsSL https://raw.githubusercontent.com/stump3/server-manager/main/server-manager.sh | bash
```

Или локально:

```bash
git clone https://github.com/stump3/server-manager
cd server-manager && bash server-manager.sh
```

---

## Главное меню

```
  SERVER-MANAGER  v2604.190312
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
| Панель + Нода (MODE=1) | Reality selfsteal — Xray и nginx на одном сервере |
| Только панель (MODE=2) | Нода на отдельном сервере, nginx слушает 443 напрямую |

### Архитектура selfsteal (MODE=1)

```
Клиент (VLESS+Reality)
    │
    ▼ TCP :443
Xray (rw-core, process на хосте)
  - Reality handshake
  - dest: /dev/shm/nginx.sock  (proxy_protocol xver=1)
    │
    ▼ unix:/dev/shm/nginx.sock
nginx (Docker, network_mode: host)
  - listen unix:/dev/shm/nginx.sock ssl proxy_protocol
    │
    ├── panel.example.com  ──►  remnawave :3000
    ├── sub.example.com    ──►  remnawave-sub :3010 (или sub-injector :3020)
    └── node.example.com   ──►  /var/www/html (decoy)
```

> **Важно:** nginx НЕ слушает порт 443 в MODE=1. Порт 443 принадлежит Xray.
> Сокет `/dev/shm/nginx.sock` создаётся nginx при старте.

### Docker-стек панели

| Контейнер | Образ | Описание |
|---|---|---|
| remnawave | remnawave/backend:2 | NestJS backend, порт 3000 |
| remnawave-db | postgres:18.x | База данных, порт 6767 |
| remnawave-redis | valkey/valkey:9.x | Redis (unix socket) |
| remnawave-nginx | nginx:1.28 | Reverse proxy, network_mode: host |
| remnawave-subscription-page | remnawave/subscription-page | Страница подписок, порт 3010 |
| remnanode | remnawave/node:latest | Xray core (rw-core), network_mode: host |

### SSL

| Метод | Описание |
|---|---|
| Cloudflare DNS-01 | Wildcard сертификат, рекомендуется |
| ACME HTTP-01 | Let's Encrypt, простой |
| Gcore DNS-01 | Wildcard через Gcore |

### Меню управления (`rp`)

```
 1)  📋  Логи           2)  📊  Статус      3)  🔄  Перезапуск
 4)  ▶️   Старт          5)  📦  Обновить    6)  🔒  SSL
 7)  💾  Бэкап          8)  🏥  Диагноз     9)  🔓  Открыть порт 8443
10)  🔐  Закрыть       11)  💻  CLI        12)  🔧  Переустановить скрипт (rp)
```

### Доступ к панели

После установки cookie URL сохраняется в `/root/remnawave-credentials.txt`:

```
https://panel.example.com/auth/login?KEY=VALUE
```

---

## MTProxy (telemt)

telemt — MTProto прокси на Rust с ME (Middle-End) режимом.

### Режимы запуска

| Режим | Описание |
|---|---|
| systemd | Бинарник с GitHub Releases, hot reload через SIGHUP |
| Docker | Образ whn0thacked/telemt-docker |

### Ключевые возможности

- **ME режим** (`use_middle_proxy = true`) — обязателен для `ad_tag` / спонсорских каналов
- **Hot reload** — `systemctl reload telemt` применяет изменения конфига без разрыва соединений
- **Per-user лимиты** — `max_tcp_conns`, `max_unique_ips`, `data_quota_bytes`, `expiration_rfc3339`
- **TLS-эмуляция** — трафик выглядит как обычный HTTPS
- **REST API** — управление пользователями через `http://127.0.0.1:9091/v1/users`

### Ad tag (спонсорский канал)

```toml
[general]
ad_tag = "1234567890abcdef1234567890abcdef"
use_middle_proxy = true   # обязательно при ad_tag
```

> `use_middle_proxy = true` обязателен для работы `ad_tag`.
> При `false` — прямое подключение к DC, ad_tag не работает.

---

## Hysteria2

> Начиная с модульной версии, `lib/hysteria.sh` — это loader, а основная логика вынесена в `lib/hy2/*.sh`.
> Это упрощает поддержку и командную разработку без изменения внешнего интерфейса (`_load_module hysteria`).

### Как это работает при `curl | bash`

- `server-manager.sh` загружает `lib/hysteria.sh` через `_load_module hysteria`.
- Loader `lib/hysteria.sh` последовательно подключает `lib/hy2/core.sh`, `install.sh`, `users.sh`, `integration.sh`, `menu.sh`.
- Для удалённого запуска используется универсальный загрузчик `_sm_source_file`, который умеет скачивать не только `lib/*.sh`, но и пути в подпапках (`lib/hy2/*.sh`).

### Установка

- Домен с ACME HTTP-01 (Let's Encrypt / ZeroSSL / Buypass)
- **Port Hopping** — диапазон UDP портов, обход блокировок
- IPv6 поддержка
- Маскировка: proxy → внешний сайт или file → `/var/www/html`
- Алгоритм: BBR / Brutal

### Port Hopping

```yaml
# config.yaml
listen: 0.0.0.0:8443,20000-29999
```

URI клиента: `hy2://user:pass@domain:8443,20000-29999?sni=domain&alpn=h3`

Совместимые клиенты: Hiddify, Nekoray, v2rayN 7.x+

> Hysteria2 использует **8443 UDP**. Порт 443 TCP занят Xray. Конфликта нет.

### Режимы аутентификации

| Режим | Описание |
|---|---|
| `userpass` | Пользователи в config.yaml, требует перезапуска при изменениях |
| `http` | Запрос к hy-webhook `/auth` при подключении, **без перезапуска** |

HTTP auth включается в меню: `Hysteria2 → Подписка → Интеграция → Режим аутентификации`.

---

## Интеграция Hysteria2 → Подписка Remnawave

Добавляет персональный `hy2://` URI в подписку Remnawave автоматически.

```
Главное меню → 3) Hysteria2 → 4) Подписка → 3) Интеграция с Remnawave
```

### Полная схема архитектуры

```
Клиент запрашивает подписку
    │  GET https://sub.example.com/TOKEN
    ▼
nginx (unix socket ← Xray)
    │
    ▼  upstream: 127.0.0.1:3020
sub-injector (Rust, :3020)
    │  1. Проксирует запрос → remnawave-sub :3010
    │  2. Получает base64 подписку (VLESS URI)
    │  3. Определяет клиента по User-Agent
    │  4. GET hy-webhook:8766/uri/TOKEN → персональный hy2://
    │  5. Добавляет hy2:// в конец подписки
    │  6. Возвращает обновлённый base64
    ▼
Клиент получает подписку с VLESS + hy2://
```

```
Remnawave (user.created / deleted / disabled)
    │  POST http://172.30.0.1:8766/webhook
    │  Header: X-Remnawave-Signature (HMAC-SHA256)
    ▼
hy-webhook (Python, :8766, 0.0.0.0)
    │  1. Проверяет подпись
    │  2. Обновляет /var/lib/hy-webhook/users.json
    │  3. Обновляет /etc/hysteria/config.yaml (если userpass режим)
    │  4. systemctl reload/restart hysteria-server
    ▼
Hysteria2 — пользователь добавлен/удалён
```

### Компоненты интеграции

| Компонент | Порт | Описание |
|---|---|---|
| hy-webhook | :8766 (0.0.0.0) | Python HTTP-сервер, принимает вебхуки от Remnawave |
| sub-injector | :3020 (0.0.0.0) | Rust-прокси, инжектирует hy2:// в подписку |
| `/uri` endpoint | :8766/uri/TOKEN | Возвращает персональный hy2:// URI для клиента |
| `/auth` endpoint | :8766/auth | HTTP auth для Hysteria2 (без перезапуска) |

### Настройка webhook в .env Remnawave

```env
WEBHOOK_ENABLED=true
WEBHOOK_URL=http://172.30.0.1:8766/webhook
WEBHOOK_SECRET_HEADER=<hex64>
```

> `172.30.0.1` — gateway Docker сети `remnawave-network`.
> Не `127.0.0.1` — Docker контейнер не видит localhost хоста.

### UFW — почему `172.16.0.0/12`

Docker использует подсети из `172.16.0.0/12`. Правило добавляется автоматически:
```bash
ufw allow in from 172.16.0.0/12 to any port 8766
```

### Дополнительные функции в меню интеграции

| Пункт | Описание |
|---|---|
| Режим аутентификации | Переключение userpass ↔ HTTP auth |
| Добавить UA-паттерн | Новые клиенты для инжекции (clash.meta, mihomo, singbox) |
| Многопоточность hy-webhook | Панель не зависает при перезапуске Hysteria2 |
| Расширенное логирование | DEBUG_LOG для диагностики |

---

## Обновление скрипта

### Через меню (рекомендуется)

```
Главное меню → 5) Обновить скрипт
```

Скачивает архив с GitHub и обновляет все модули `lib/*.sh`.

### Вручную — один модуль

```bash
curl -fsSL "https://raw.githubusercontent.com/stump3/server-manager/main/lib/panel.sh" \
    -o /root/lib/panel.sh
```

### После обновления

Скрипт управления `rp` обновляется отдельно:
```
Remnawave Panel → Управление → 12) Переустановить скрипт (rp)
```

---

## Перенос

```
1) Перенести Remnawave Panel
2) Перенести MTProxy (telemt)
3) Перенести Hysteria2
4) Перенести всё (Panel + MTProxy + Hysteria2)
5) Бэкап / Восстановление (backup-restore)
```

| Данные | Panel | MTProxy | Hysteria2 |
|---|---|---|---|
| Конфиг | ✓ | ✓ | ✓ |
| БД (pg_dumpall + gzip) | ✓ | — | — |
| SSL сертификаты (letsencrypt) | ✓ | — | ✓ |
| ACME сертификат Hysteria | — | — | ✓ |
| Пользователи | ✓ | ✓ | ✓ |

> После переноса Hysteria2 обновите DNS домена на новый IP.
> ACME сертификат переносится — перевыпуск не нужен.

---

## Требования

### Система
- Ubuntu 20.04+ / Debian 11+
- Root доступ
- Docker, docker-compose, jq, openssl

### Порты

| Порт | Протокол | Назначение |
|---|---|---|
| 80 | TCP | certbot ACME, Hysteria2 ACME (временно) |
| 443 | TCP | Xray/nginx (Remnawave selfsteal) |
| 8443 | UDP | Hysteria2 (или другой по выбору) |
| 2053/2087... | TCP | MTProxy (telemt) |
| 2222 | TCP | remnanode (только Docker сеть 172.30.0.0/16) |
| 8766 | TCP | hy-webhook (только 172.16.0.0/12) |

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
| nginx + redis | ~10 MB | Docker |
| **Итого** | **~850 MB** | |

> 395 MB для remnawave — норма для NestJS + BullMQ + TypeORM стека.

### Swap
Рекомендуется минимум **1 GB swap**. При 2 GB RAM сервисы в пике уходят в swap.

```bash
# Добавить 2 GB swap
fallocate -l 2G /swapfile && chmod 600 /swapfile
mkswap /swapfile && swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab
```

---

## Лицензия

MIT
