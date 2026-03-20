<div align="center">

# 🛠️ server-manager

> Модульная система установки и управления VPN-инфраструктурой на базе Remnawave + Hysteria2 + MTProxy.

```bash
curl -fsSL https://raw.githubusercontent.com/stump3/server-manager/main/server-manager.sh | bash
```

[![Docs](https://img.shields.io/badge/docs-интерактивные-3b82f6?style=flat-square)](https://stump3.github.io/server-manager/README.html)
[![Changelog](https://img.shields.io/badge/changelog-v2.1.0-22c55e?style=flat-square)](docs/CHANGELOG.md)
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
│   ├── panel.sh                # Remnawave Panel + Extensions (1750 строк)
│   ├── telemt.sh               # MTProxy (telemt) (701 строка)
│   ├── hysteria.sh             # Hysteria2 (1213 строк)
│   └── migrate.sh              # Перенос сервисов (248 строк)
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

| Режим | Описание |
|---|---|
| systemd | Бинарник с GitHub Releases, автозапуск |
| Docker | Образ с Docker Hub |

Hot reload пользователей без перезапуска сервиса.

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

Добавляет `hy2://` URI в подписку Remnawave автоматически при создании/изменении пользователя.

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
                                    │
subscription-page  ◄──  читает users.json  ──►  hy2:// URI в подписку
```

### Обновление

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
# Заменить panel.sh (Remnawave Panel)
curl -fsSL "https://raw.githubusercontent.com/stump3/server-manager/main/lib/panel.sh" \
    -o /root/lib/panel.sh

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
# Заменить panel.sh (Remnawave Panel)
curl -fsSL "https://raw.githubusercontent.com/stump3/server-manager/main/lib/panel.sh" \
    -o /root/lib/panel.sh

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
- `80` TCP — certbot (открывается на время выпуска SSL, потом закрывается)
- `443` TCP — Xray/nginx (Remnawave Panel + selfsteal)
- `8443` UDP — Hysteria2
- `2222` TCP — remnanode (только из Docker сети 172.30.0.0/16)

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

> **Примечание:** 395 MB для remnawave — норма для NestJS + BullMQ + TypeORM стека. eGames и другие скрипты на базе remnawave/backend:2 показывают те же цифры.

### Swap
Рекомендуется минимум **1 GB swap**. При 2 GB RAM telemt и другие сервисы в пике уходят в swap (~47-83 MB).

---

## Лицензия

MIT
