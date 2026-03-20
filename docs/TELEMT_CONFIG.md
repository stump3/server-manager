# Справочник параметров конфига telemt

> Полный список всех ключей `config.toml`, принимаемых telemt.
>
> ⚠️ Параметры предназначены для опытных пользователей и тонкой настройки. Изменение без понимания назначения может привести к нестабильной работе прокси.

Связанные файлы: [`/etc/telemt/telemt.toml`](../integrations/hy-sub-install.sh) · [Upstream: telemt/docs/CONFIG_PARAMS.en.md](https://github.com/telemt/telemt/blob/main/docs/CONFIG_PARAMS.en.md)

---

## Верхний уровень

| Параметр | Тип | По умолчанию | Описание |
|---|---|---|---|
| `include` | `String` | `null` | Подключить внешний `.toml` файл. Рекурсивно обрабатывается до парсинга. Полезно для разделения пользователей и основного конфига. |
| `show_link` | `"*"` или `String[]` | `[]` | Устаревший селектор видимости ссылок: `"*"` — показывать всем, или список имён пользователей. |
| `dc_overrides` | `Map<String, String[]>` | `{}` | Переопределение DC-эндпоинтов для нестандартных DC. Ключ — строковый ID DC, значение — список `ip:port`. |
| `default_dc` | `u8` или `null` | `null` | Дефолтный DC-индекс для нестандартных DC без маппинга. |

---

## [general]

Основные параметры поведения прокси.

| Параметр | Тип | По умолчанию | Описание |
|---|---|---|---|
| `data_path` | `String` или `null` | `null` | Путь к директории runtime-данных. |
| `prefer_ipv6` | `bool` | `false` | Предпочитать IPv6 там где применимо. |
| `fast_mode` | `bool` | `true` | Fast-path оптимизации обработки трафика. |
| `use_middle_proxy` | `bool` | `true` | ME-транспорт. При `false` — прямой маршрут к DC. |
| `proxy_secret_path` | `String` или `null` | `"proxy-secret"` | Путь к файлу proxy-secret инфраструктуры Telegram. |
| `ad_tag` | `String` или `null` | `null` | Глобальный рекламный тег (32 hex-символа). |
| `log_level` | `"debug"` / `"verbose"` / `"normal"` / `"silent"` | `"normal"` | Уровень детализации логов. |
| `disable_colors` | `bool` | `false` | Отключить ANSI-цвета в логах. |
| `update_every` | `u64` или `null` | `300` | Интервал обновления ME-конфига и proxy-secret (секунды). |
| `ntp_check` | `bool` | `true` | Проверка дрейфа NTP при старте. |
| `ntp_servers` | `String[]` | `["pool.ntp.org"]` | NTP-серверы для проверки. |

### Параметры ME-пула (middle proxy)

| Параметр | Тип | По умолчанию | Описание |
|---|---|---|---|
| `middle_proxy_pool_size` | `usize` | `8` | Целевой размер пула активных ME-writer'ов. |
| `me_floor_mode` | `"static"` / `"adaptive"` | `"adaptive"` | Режим управления минимальным числом ME-writer'ов. |
| `me_keepalive_enabled` | `bool` | `true` | Периодический keepalive-трафик через ME. |
| `me_keepalive_interval_secs` | `u64` | `8` | Базовый интервал keepalive (секунды). |
| `me_reinit_every_secs` | `u64` | `900` | Периодический zero-downtime реинит ME-пула (секунды). |
| `me2dc_fallback` | `bool` | `true` | Разрешить fallback с ME на прямой маршрут при сбое. |
| `me_init_retry_attempts` | `u32` | `0` | Попыток инициализации ME-пула при старте (`0` = без ограничений). |
| `hardswap` | `bool` | `true` | Стратегия hardswap для безопасной замены ME writer'ов. |

### Forensic наблюдение (beobachten)

| Параметр | Тип | По умолчанию | Описание |
|---|---|---|---|
| `beobachten` | `bool` | `true` | Включить per-IP forensic-наблюдение (логирование аномалий). |
| `beobachten_minutes` | `u64` | `10` | Окно хранения данных наблюдения (минуты). |
| `beobachten_flush_secs` | `u64` | `15` | Интервал сброса снапшота наблюдения в файл (секунды). |
| `beobachten_file` | `String` | `"cache/beobachten.txt"` | Путь к файлу снапшота. |
| `desync_all_full` | `bool` | `false` | Полные forensic-логи для каждого события crypto-desync. |

### Восстановление и reconnect

| Параметр | Тип | По умолчанию | Описание |
|---|---|---|---|
| `me_reconnect_max_concurrent_per_dc` | `u32` | `8` | Максимум параллельных reconnect-воркеров на DC. |
| `me_reconnect_backoff_base_ms` | `u64` | `500` | Начальный backoff при reconnect (мс). |
| `me_reconnect_backoff_cap_ms` | `u64` | `30000` | Максимальный backoff cap (мс). |
| `upstream_connect_retry_attempts` | `u32` | `2` | Попыток подключения к upstream перед ошибкой. |
| `upstream_connect_budget_ms` | `u64` | `3000` | Общий бюджет времени на один запрос подключения (мс). |
| `upstream_unhealthy_fail_threshold` | `u32` | `5` | Порог последовательных ошибок до маркировки upstream нездоровым. |

---

## [general.modes]

| Параметр | Тип | По умолчанию | Описание |
|---|---|---|---|
| `classic` | `bool` | `false` | Классический режим MTProxy. |
| `secure` | `bool` | `false` | Secure-режим. |
| `tls` | `bool` | `true` | TLS-режим (рекомендуется). |

## [general.links]

| Параметр | Тип | По умолчанию | Описание |
|---|---|---|---|
| `show` | `"*"` или `String[]` | `"*"` | Показывать ссылки для всех (`"*"`) или указанных пользователей. |
| `public_host` | `String` или `null` | `null` | Публичный хост/IP для генерируемых `tg://` ссылок. |
| `public_port` | `u16` или `null` | `null` | Публичный порт для генерируемых `tg://` ссылок. |

## [general.telemetry]

| Параметр | Тип | По умолчанию | Описание |
|---|---|---|---|
| `core_enabled` | `bool` | `true` | Счётчики telemetry для hot-path. |
| `user_enabled` | `bool` | `true` | Per-user telemetry счётчики. |
| `me_level` | `"silent"` / `"normal"` / `"debug"` | `"normal"` | Детализация ME telemetry. |

---

## [network]

| Параметр | Тип | По умолчанию | Описание |
|---|---|---|---|
| `ipv4` | `bool` | `true` | Включить IPv4 сетевой стек. |
| `ipv6` | `bool` | `false` | Включить IPv6 сетевой стек. |
| `prefer` | `u8` | `4` | Предпочтительное IP-семейство: `4` или `6`. |
| `multipath` | `bool` | `false` | Multipath-поведение где поддерживается. |
| `stun_use` | `bool` | `true` | Глобальный переключатель STUN-пробинга. |
| `stun_servers` | `String[]` | Встроенный список (13 хостов) | STUN-серверы для определения публичного IP. |
| `stun_tcp_fallback` | `bool` | `true` | TCP-fallback для STUN когда UDP заблокирован. |
| `http_ip_detect_urls` | `String[]` | `["https://ifconfig.me/ip", ...]` | HTTP-fallback для определения публичного IP. |
| `dns_overrides` | `String[]` | `[]` | DNS-переопределения в формате `host:port:ip`. |

---

## [server]

| Параметр | Тип | По умолчанию | Описание |
|---|---|---|---|
| `port` | `u16` | `443` | Основной порт прослушивания прокси. |
| `listen_addr_ipv4` | `String` или `null` | `"0.0.0.0"` | IPv4-адрес для TCP listener'а. |
| `listen_addr_ipv6` | `String` или `null` | `"::"` | IPv6-адрес для TCP listener'а. |
| `listen_unix_sock` | `String` или `null` | `null` | Путь к Unix-сокету для listener'а. |
| `proxy_protocol` | `bool` | `false` | Включить парсинг HAProxy PROXY protocol на входящих соединениях. |
| `metrics_port` | `u16` или `null` | `null` | Порт метрик (Prometheus). При установке включает metrics listener. |
| `metrics_listen` | `String` или `null` | `null` | Полный адрес метрик `IP:PORT` — имеет приоритет над `metrics_port`. |
| `metrics_whitelist` | `IpNetwork[]` | `["127.0.0.1/32", "::1/128"]` | CIDR-вайтлист для доступа к метрикам. |
| `max_connections` | `u32` | `10000` | Максимум одновременных клиентских подключений. `0` = без ограничений. |

### Prometheus метрики

```toml
[server]
metrics_port = 9090
# или точный адрес:
metrics_listen = "127.0.0.1:9090"
metrics_whitelist = ["127.0.0.1/32", "10.0.0.0/8"]
```

---

## [server.api]

Control-plane REST API (порт 9091 по умолчанию).

| Параметр | Тип | По умолчанию | Описание |
|---|---|---|---|
| `enabled` | `bool` | `true` | Включить REST API. |
| `listen` | `String` | `"0.0.0.0:9091"` | Адрес привязки API (`IP:PORT`). |
| `whitelist` | `IpNetwork[]` | `["127.0.0.0/8"]` | CIDR-вайтлист для API. |
| `auth_header` | `String` | `""` | Ожидаемое значение заголовка `Authorization` (пусто = отключено). |
| `read_only` | `bool` | `false` | Отклонять мутирующие эндпоинты. |
| `request_body_limit_bytes` | `usize` | `65536` | Максимальный размер тела HTTP-запроса. |

---

## [[server.listeners]]

Дополнительные listener'ы (массив).

| Параметр | Тип | Описание |
|---|---|---|
| `ip` | `IpAddr` | IP для привязки listener'а. |
| `announce` | `String` или `null` | Публичный IP/домен, объявляемый в прокси-ссылках. |
| `proxy_protocol` | `bool` или `null` | Переопределение PROXY protocol на уровне listener'а. |
| `reuse_allow` | `bool` | Включить `SO_REUSEPORT` для multi-instance bind. |

---

## [censorship]

Параметры TLS-маскировки и обхода блокировок.

| Параметр | Тип | По умолчанию | Описание |
|---|---|---|---|
| `tls_domain` | `String` | `"petrovich.ru"` | Основной домен для fake-TLS профиля. |
| `tls_domains` | `String[]` | `[]` | Дополнительные TLS-домены для генерации нескольких ссылок. |
| `mask` | `bool` | `true` | Включить режим masking/fronting relay. |
| `mask_host` | `String` или `null` | `null` | Upstream хост для TLS-fronting relay. |
| `mask_port` | `u16` | `443` | Upstream порт для TLS-fronting relay. |
| `tls_emulation` | `bool` | `true` | Эмуляция сертификата/TLS-поведения из кеша реальных фронтов. |
| `tls_front_dir` | `String` | `"tlsfront"` | Директория для кеша TLS-фронтов. |
| `fake_cert_len` | `usize` | `2048` | Длина синтетического сертификата (если нет реального). |
| `server_hello_delay_min_ms` | `u64` | `0` | Минимальная задержка server_hello для anti-fingerprint (мс). |
| `server_hello_delay_max_ms` | `u64` | `0` | Максимальная задержка server_hello для anti-fingerprint (мс). |
| `alpn_enforce` | `bool` | `true` | Принудительно отражать ALPN-предпочтения клиента. |

---

## [access]

Управление пользователями, ограничениями и защитой от replay.

```toml
[access.users]
alice = "deadbeef...32hex"
bob   = "cafebabe...32hex"

[access.user_max_tcp_conns]
alice = 100

[access.user_data_quota]
alice = 10737418240  # 10 GB в байтах

[access.user_expirations]
alice = "2027-01-01T00:00:00Z"

[access.user_max_unique_ips]
alice = 5
```

| Параметр | Тип | По умолчанию | Описание |
|---|---|---|---|
| `users` | `Map<String, String>` | `{"default": "000…000"}` | Учётные данные пользователей. Секрет — 32 hex-символа. |
| `user_max_tcp_conns` | `Map<String, usize>` | `{}` | Максимум одновременных TCP-соединений на пользователя. |
| `user_expirations` | `Map<String, DateTime>` | `{}` | Сроки действия аккаунтов (RFC3339). |
| `user_data_quota` | `Map<String, u64>` | `{}` | Квота трафика на пользователя (байты). |
| `user_max_unique_ips` | `Map<String, usize>` | `{}` | Лимит уникальных IP на пользователя. |
| `user_max_unique_ips_global_each` | `usize` | `0` | Глобальный лимит уникальных IP для пользователей без персонального ограничения. |
| `user_max_unique_ips_mode` | `"active_window"` / `"time_window"` / `"combined"` | `"active_window"` | Режим учёта уникальных IP. |
| `user_max_unique_ips_window_secs` | `u64` | `30` | Окно учёта уникальных IP в секундах (для time_window режимов). |
| `replay_check_len` | `usize` | `65536` | Размер хранилища защиты от replay-атак. |
| `replay_window_secs` | `u64` | `1800` | Окно защиты от replay (секунды). |
| `ignore_time_skew` | `bool` | `false` | Отключить проверку расхождения времени в replay-валидации. |

---

## [timeouts]

| Параметр | Тип | По умолчанию | Описание |
|---|---|---|---|
| `client_handshake` | `u64` | `30` | Таймаут handshake клиента (секунды). |
| `tg_connect` | `u64` | `10` | Таймаут подключения к Telegram DC (секунды). |
| `client_keepalive` | `u64` | `15` | Таймаут keepalive клиента (секунды). |
| `client_ack` | `u64` | `90` | Таймаут ACK клиента (секунды). |
| `me_one_retry` | `u8` | `12` | Попыток быстрого reconnect для one-endpoint DC. |
| `me_one_timeout_ms` | `u64` | `1200` | Таймаут каждой попытки быстрого reconnect (мс). |

---

## [[upstreams]]

Дополнительные upstream'ы для исходящих соединений.

```toml
# Привязка к конкретному IP
[[upstreams]]
type = "direct"
interface = "1.2.3.4"
weight = 1
enabled = true

# SOCKS5 прокси
[[upstreams]]
type = "socks5"
address = "proxy.example.com:1080"
username = "user"
password = "pass"
weight = 2
enabled = true
```

| Параметр | Тип | По умолчанию | Описание |
|---|---|---|---|
| `type` | `"direct"` / `"socks4"` / `"socks5"` | — | Тип upstream (обязательный). |
| `weight` | `u16` | `1` | Вес для взвешенного выбора upstream. |
| `enabled` | `bool` | `true` | Отключённые записи не участвуют в выборе. |
| `scopes` | `String` | `""` | Comma-разделённые теги для фильтрации upstream на уровне запроса. |
| `interface` | `String` или `null` | `null` | Исходящий интерфейс или локальный IP для bind. |
| `bind_addresses` | `String[]` или `null` | `null` | Явные адреса для bind (только `type = "direct"`). |
| `address` | `String` | — | Эндпоинт SOCKS-сервера `host:port` (для socks4/socks5). |
| `username` | `String` или `null` | `null` | Логин SOCKS5. |
| `password` | `String` или `null` | `null` | Пароль SOCKS5. |
| `user_id` | `String` или `null` | `null` | User ID для SOCKS4. |

---

## Пример минимального конфига

```toml
[server]
port = 8443
max_connections = 5000

[censorship]
tls_domain = "petrovich.ru"

[access.users]
alice = "deadbeef0123456789abcdef01234567"

[access.user_max_tcp_conns]
alice = 100

[access.user_max_unique_ips]
alice = 5
```

---

> Полный оригинальный справочник на английском: [telemt/docs/CONFIG_PARAMS.en.md](https://github.com/telemt/telemt/blob/main/docs/CONFIG_PARAMS.en.md)
