<div align="center">

# 🛠️ server-manager

> Модульная система установки и управления VPN-инфраструктурой на базе Remnawave + Hysteria2 + MTProxy.

📖 **[Интерактивная документация](https://stump3.github.io/server-manager/README.html)** — тёмная тема, навигация, схемы архитектуры

```bash
curl -fsSL https://raw.githubusercontent.com/stump3/server-manager/main/server-manager.sh | bash
```

</div>

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

### Меню управления (rp)

```
 1)  📋  Логи
 2)  📊  Статус
 3)  🔄  Перезапуск
 4)  ▶️   Старт
 5)  📦  Обновить
 6)  🔒  SSL
 7)  💾  Бэкап
 8)  🏥  Диагноз
 9)  🔓  Открыть порт 8443
10)  🔐  Закрыть порт 8443
11)  📦  Перенос
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

### Требования

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
