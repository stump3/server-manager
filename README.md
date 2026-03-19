<div align="center">

# 🛠️ server-manager

> Модульная система установки и управления VPN-инфраструктурой.

📖 **[Открыть интерактивную документацию](https://stump3.github.io/server-manager/README.html)** — тёмная тема, навигация, терминальные превью

```bash
curl -fsSL https://raw.githubusercontent.com/stump3/server-manager/main/server-manager.sh | bash
```

</div>

---

## Компоненты

| Компонент | Описание |
|---|---|
| 🛡️ **Remnawave Panel** | VPN-панель с Xray/Reality, cookie-защитой, WARP Native |
| 📡 **MTProxy (telemt)** | Telegram MTProto прокси на Rust, systemd / Docker |
| 🚀 **Hysteria2** | Высокоскоростной VPN поверх QUIC/UDP, Port Hopping |

---

## Структура репозитория

```
server-manager/
├── server-manager.sh          # Точка входа — загружает модули
├── lib/
│   ├── common.sh              # Утилиты, цвета, главное меню
│   ├── panel.sh               # Remnawave Panel + Extensions
│   ├── telemt.sh              # MTProxy (telemt)
│   ├── hysteria.sh            # Hysteria2
│   └── migrate.sh             # Перенос сервисов
├── integrations/
│   ├── hy-sub-install.sh      # Интеграция Hysteria2 → подписка Remnawave
│   └── hy-webhook.py          # Webhook-сервис синхронизации пользователей
└── docs/
    ├── README.md
    └── README.html            # Интерактивная документация
```

---

## Быстрый старт

```bash
# Скачать и запустить
curl -fsSL https://raw.githubusercontent.com/stump3/server-manager/main/server-manager.sh \
    -o server-manager.sh && bash server-manager.sh

# Или через pipe
curl -fsSL https://raw.githubusercontent.com/stump3/server-manager/main/server-manager.sh | bash
```

---

## Главное меню

```
  SERVER-MANAGER  v2603.181008
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

### Установка

```
1) 🆕  Установить
2) 💣  Переустановить (сброс всех данных!)
```

**Параметры:** домен панели, sub-домен, selfsteal-домен, SSL (Cloudflare / Let's Encrypt / Gcore)

### Управление

| Пункт | Действие |
|---|---|
| 📋 Логи | docker logs всех контейнеров |
| 📊 Статус | docker compose ps |
| 🔄 Перезапустить | docker compose restart |
| 📦 Обновить | docker pull + up -d |
| 🔒 SSL | certbot renew |
| 💾 Бэкап | pg_dump + архив конфигов |
| 🏥 Диагноз | проверка портов и сертификатов |
| 💻 Remnawave CLI | docker exec -it remnawave remnawave |

### Расширения

- **🌐 WARP Native** — Cloudflare WARP как outbound в Xray, добавление в профиль через API
- **🎨 Страница подписки** — Orion шаблон, брендинг, восстановление
- **🖼️ Selfsteal шаблон** — случайный / Simple / SNI / Nothing SNI
- **🔄 Обновить скрипт** — проверка и загрузка с GitHub

---

## MTProxy (telemt)

### Режимы

| Режим | Описание |
|---|---|
| systemd | Бинарник с GitHub Releases, автозапуск |
| Docker | Образ с Docker Hub |

### Пользователи

Hot reload — без перезапуска сервиса:
```bash
# Добавить через меню: имя, секрет, лимиты
# Удалить — выбор из списка
# Ссылки — tg://proxy для всех пользователей
```

---

## Hysteria2

### Установка

- Домен (ACME HTTP-01)
- CA: Let's Encrypt / ZeroSSL / Buypass
- **Port Hopping**: один порт или диапазон UDP (обход блокировок)
- **IPv6**: поддержка если есть на сервере
- Masquerade: proxy → URL или file → /var/www/html
- Алгоритм: BBR или Brutal (с указанием скорости канала)

### Port Hopping

```bash
# Включается при установке или через hy-sub-install.sh
listen: 0.0.0.0:8443,20000-29999

# URI клиента
hy2://user:pass@domain:8443,20000-29999?sni=domain&alpn=h3
```

Совместимые клиенты: Hiddify, Nekoray, v2rayN 7.x+

---

## Интеграция Hysteria2 → Подписка Remnawave

Добавляет `hy2://` URI в подписку Remnawave автоматически.

```bash
curl -fsSL https://raw.githubusercontent.com/stump3/server-manager/main/integrations/hy-sub-install.sh \
    -o hy-sub-install.sh
curl -fsSL https://raw.githubusercontent.com/stump3/server-manager/main/integrations/hy-webhook.py \
    -o hy-webhook.py
bash hy-sub-install.sh
```

**Как работает:**

```
Remnawave (user.created)
    ↓  POST /webhook
hy-webhook (порт 8766)
    ↓  обновляет /etc/hysteria/config.yaml
Hysteria2 (перезапуск)
```

**Что устанавливается:**
1. `hy-webhook` — systemd сервис синхронизации пользователей
2. Форк `subscription-page` — добавляет `hy2://` URI к подписке
3. Вебхуки в Remnawave `.env`

---

## Перенос

### Отдельные сервисы

```
1) Перенести Remnawave Panel
2) Перенести MTProxy
3) Перенести Hysteria2
4) Перенести всё
5) Бэкап / Восстановление (backup-restore)
```

### Что переносится

| Данные | Panel | MTProxy | Hysteria2 |
|---|---|---|---|
| Конфиг | ✓ | ✓ | ✓ |
| БД (сжатый pg_dump) | ✓ | — | — |
| SSL сертификаты | ✓ | — | ✓ |
| Пользователи | ✓ | ✓ | ✓ |
| Selfsteal сайт | ✓ | — | — |

---

## Требования

- Ubuntu 20.04+ / Debian 11+
- Root доступ
- Открытые порты: 22 (SSH), 443 (HTTPS), UDP для Hysteria2

---

## Лицензия

MIT
