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
│   └── hy-webhook.py          # Webhook синхронизации пользователей
└── docs/
    ├── README.md
    └── README.html            # Интерактивная документация
```

---

## Быстрый старт

```bash
curl -fsSL https://raw.githubusercontent.com/stump3/server-manager/main/server-manager.sh | bash
```

Или скачать и запустить локально:

```bash
curl -fsSL https://raw.githubusercontent.com/stump3/server-manager/main/server-manager.sh \
    -o server-manager.sh && bash server-manager.sh
```

---

## Главное меню

```
  SERVER-MANAGER  v2603.190312
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
| Панель + Нода | Reality selfsteal, всё на одном сервере |
| Только панель | Нода на отдельном сервере |

### SSL

| Метод | Описание |
|---|---|
| Cloudflare DNS-01 | Wildcard, рекомендуется |
| ACME HTTP-01 | Let's Encrypt, простой |
| Gcore DNS-01 | Wildcard через Gcore |

### Меню управления

```
1) 🔧  Установка
2) ⚙️   Управление     → статус, логи, перезапуск, обновление, SSL, бэкап
3) 🌐  WARP Native     → установка, добавление в Xray профиль
4) 🎨  Страница подписки → Orion шаблон, брендинг
5) 🖼️   Selfsteal шаблон → случайный / Simple / SNI / Nothing SNI
6) 🔄  Обновить скрипт
7) 📦  Миграция на другой сервер
8) 🗑️   Удалить панель
```

### Доступ к панели

После установки сохраняется в `/root/remnawave-credentials.txt`:

```
Панель:     https://panel.example.com
Cookie URL: https://panel.example.com/auth/login?KEY=VALUE
Логин:      xxxxxxxx
Пароль:     xxxxxxxxxxxxxxxx
```

---

## MTProxy (telemt)

### Режимы

| Режим | Описание |
|---|---|
| systemd | Бинарник с GitHub Releases, автозапуск |
| Docker | Образ с Docker Hub |

### Пользователи

Hot reload без перезапуска сервиса — добавление, удаление, ссылки `tg://proxy`.

---

## Hysteria2

### Установка

- Домен (ACME HTTP-01)
- CA: Let's Encrypt / ZeroSSL / Buypass
- **Port Hopping** — диапазон UDP портов, обход блокировок по порту
- IPv6 поддержка
- Masquerade: proxy → URL или file
- Алгоритм: BBR / Brutal

### Port Hopping

```yaml
# config.yaml
listen: 0.0.0.0:8443,20000-29999
```

```
# URI клиента
hy2://user:pass@domain:8443,20000-29999?sni=domain&alpn=h3
```

Совместимые клиенты: Hiddify, Nekoray, v2rayN 7.x+

### Важно

Hysteria2 использует порт **8443 UDP**. Порт 443 TCP занят nginx (Remnawave). Конфликта нет — разные протоколы и порты.

---

## Интеграция Hysteria2 → Подписка Remnawave

Добавляет `hy2://` URI в подписку Remnawave автоматически при создании пользователя.

```bash
curl -fsSL https://raw.githubusercontent.com/stump3/server-manager/main/integrations/hy-sub-install.sh \
    -o hy-sub-install.sh
curl -fsSL https://raw.githubusercontent.com/stump3/server-manager/main/integrations/hy-webhook.py \
    -o hy-webhook.py
bash hy-sub-install.sh
```

**Схема:**

```
Remnawave (user.created)
    ↓  POST http://127.0.0.1:8766/webhook
hy-webhook
    ↓  обновляет /etc/hysteria/config.yaml
Hysteria2 (перезапуск)
```

---

## Перенос

```
1) Перенести Remnawave Panel
2) Перенести MTProxy
3) Перенести Hysteria2
4) Перенести всё
5) Бэкап / Восстановление
```

| Данные | Panel | MTProxy | Hysteria2 |
|---|---|---|---|
| Конфиг | ✓ | ✓ | ✓ |
| БД (pg_dumpall + gzip) | ✓ | — | — |
| SSL сертификаты | ✓ | — | ✓ |
| Пользователи | ✓ | ✓ | ✓ |
| server-manager.sh | ✓ | — | — |

---

## Требования

- Ubuntu 20.04+ / Debian 11+
- Root доступ
- Открытые порты: 80 (certbot), 443 TCP (nginx), 8443 UDP (Hysteria2)

---

## Лицензия

MIT
