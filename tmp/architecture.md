# Architecture

> Обновление после аудита ветки `beta`. Документ описывает целевое состояние системы
> с учётом того, что фактически уже есть в коде. Расхождения между этим документом
> и кодом — технический долг, подлежащий устранению маленькими независимыми commits.
>
> Это НЕ план одномоментного рефакторинга. Переход постепенный, с transitional
> compatibility-слоями там, где перенос сейчас создаёт риск.

---

## 1. Принцип перехода

```
server-manager.sh
        ↓
     bootstrap
        ↓
       cli                 ← transitional boundary, пока = { main_menu }
        ↓
        ui                 ← пока живёт внутри common.sh и */menu.sh
        ↓
     domains                (panel / hy2 / telemt)
        ↓
    adapters                (web, tls, remnawave-api, hysteria-api, telemt-api)
        ↓
 external services          (nginx/caddy, certbot/caddy-acme, docker, systemd)
```

Domain-модули **не должны знать**, какой конкретно веб-сервер, TLS-провайдер или транспортный механизм используется. Они обращаются к общему интерфейсу adapter'а, который уже выбрал конкретную реализацию.

---

## 2. Уровни системы (целевое состояние)

```
┌──────────────────────────────────────────────────────────────────────┐
│  CLI (transitional)                                                  │
│  lib/cli/router.sh → cli_run() { main_menu; }                       │
├──────────────────────────────────────────────────────────────────────┤
│  UI (пока не вынесен — живёт в common.sh + */menu.sh)                │
│  lib/ui/main_menu.sh  lib/ui/panel_menu.sh  lib/ui/hysteria_menu.sh  │
├──────────────┬──────────────────┬────────────────────────────────────┤
│  Domain: panel│  Domain: hy2      │  Domain: telemt (legacy, не трогать)│
│  lib/panel/  │  lib/hy2/  ✅     │  lib/telemt.sh (монолит, 1498 строк)│
│  (монолит,   │  частично разбит  │  цель: lib/telemt/{core,install,   │
│   2428 строк)│  (core/install/   │  users,manage,menu,py/}            │
│              │  users/integr/    │                                     │
│              │  menu)            │                                     │
├──────────────┴──────────────────┴────────────────────────────────────┤
│  Common adapter layer (core)                                         │
│  lib/core/config.sh  versions.sh  logging.sh  errors.sh  utils.sh   │
│  (сейчас всё смешано в lib/common.sh)                                │
├──────────────────────────────────────────────────────────────────────┤
│  Integration adapters                                                │
│  ┌─────────────────┐ ┌──────────────────┐ ┌────────────────────────┐│
│  │ Remnawave API    │ │ Hysteria2 adapter │ │ Telemt adapter (future)││
│  │ adapter          │ │                   │ │                        ││
│  │ (REST + future   │ │ hy2 core.sh уже   │ │ telemt_api() →         ││
│  │  XTLS gRPC stats)│ │ частичный adapter │ │ lib/telemt/core.sh     ││
│  └─────────────────┘ └──────────────────┘ └────────────────────────┘│
├──────────────────────────────────────────────────────────────────────┤
│  Web server adapter          │  TLS/certificate adapter               │
│  lib/web/core.sh             │  lib/web/tls.sh                        │
│  lib/web/detect.sh           │                                        │
│  lib/web/providers/          │  Провайдеры:                           │
│    nginx.sh                  │    certbot (dns-cloudflare/            │
│    caddy.sh                  │             standalone-http01/         │
│                               │             dns-gcore)                 │
│                               │    caddy-acme (встроенный)             │
├──────────────────────────────────────────────────────────────────────┤
│  Reality/selfsteal transport (отдельная интеграция, НЕ часть web-adapter)│
│  Xray (rw-core) → /dev/shm/nginx.sock → nginx ИЛИ caddy (оба провайдера│
│  поддерживают unix-socket приёмник в MODE=1)                          │
├──────────────────────────────────────────────────────────────────────┤
│  System layer                                                        │
│  lib/system/services.sh  firewall.sh  network.sh  migrate.sh        │
│  (сейчас: SSH-хелперы разбросаны по common.sh, используются          │
│   в migrate.sh, panel.sh, telemt.sh, hy2/menu.sh)                    │
├──────────────────────────────────────────────────────────────────────┤
│  sub-injector (изолирован, Rust/Axum, отдельный жизненный цикл)     │
├──────────────────────────────────────────────────────────────────────┤
│  Infra: systemd, docker, ufw, apt                                    │
└──────────────────────────────────────────────────────────────────────┘
```

---

## 3. Web server adapter — контракт

**Причина существования:** nginx и Caddy — взаимозаменяемые реализации одного слоя, не два независимых пути в бизнес-логике. Domain-модули (panel, hy2) не должны содержать `if [ "$ws" = "caddy" ]` — это ответственность adapter'а.

**Фактическое текущее состояние:** абстракция уже наполовину существует, размазана по `lib/panel.sh` (~15+ мест ad-hoc branching) и `lib/common.sh` (`remote_install_deps` уже принимает `web_server` параметр). `_detect_ws()` в `panel.sh:1324` — уже фактически `web_server_detect()`, просто не вынесена и не переиспользуется другими модулями.

**Целевая структура:**

```
lib/web/
├── core.sh              # контракт: диспетчер, вызывающий providers/*.sh
├── detect.sh             # web_server_detect() — определяет активный провайдер
├── tls.sh                # TLS-контракт (см. §4, отдельная абстракция)
└── providers/
    ├── nginx.sh           # nginx-специфичная реализация контракта
    └── caddy.sh           # caddy-специфичная реализация контракта
```

**Контракт (концептуальный, не финальная сигнатура):**

```
web_server_detect          → nginx | caddy
web_server_install         → установка выбранного провайдера
web_server_remove
web_server_reload          → nginx -s reload | caddy reload
web_server_restart         → docker compose restart remnawave-{nginx,caddy}
web_server_configure_proxy → генерация reverse-proxy конфига (без TLS-деталей)
web_server_configure_route
web_server_add_site
web_server_remove_site
web_server_get_status      → nginx -t | caddy validate
```

**Критичное ограничение — не предполагать топологию:**

Оба провайдера **не всегда** занимают `:443` напрямую. В selfsteal-топологии (MODE=1) порт `:443` принадлежит Xray, а веб-сервер получает трафик через unix-сокет:

```
MODE=1 (selfsteal, панель+нода):
  Xray :443 → /dev/shm/nginx.sock → nginx (proxy_protocol) ИЛИ caddy

MODE=2 (только панель, без selfsteal):
  nginx :443 напрямую (certbot)
  caddy :443 + :80 напрямую (встроенный ACME)
```

Имя сокета `/dev/shm/nginx.sock` вводит в заблуждение — используется идентично **обоими** провайдерами. При формализации adapter'а имя сокета должно стать нейтральной константой в `lib/web/core.sh`, а не жёстко зашитым `nginx.sock` в каждом providers-файле.

---

## 4. TLS/certificate adapter — отдельная абстракция

**Явно не смешивается с web server adapter.** Сертификат — не то же самое, что веб-сервер, даже если Caddy управляет обоими сама.

```
lib/web/tls.sh

tls_issue_certificate
tls_renew_certificate
tls_install_certificate
tls_remove_certificate
tls_get_status
```

**Фактические провайдеры сейчас (все в `lib/panel.sh`, не изолированы):**

| Provider | Механизм | Используется когда |
|---|---|---|
| certbot + dns-cloudflare | DNS-01, credentials в `~/.secrets/certbot/cloudflare.ini` | nginx, домен на Cloudflare |
| certbot + standalone | HTTP-01, требует `:80` временно, `--http-01-port 80` | nginx, без DNS-провайдера |
| certbot + dns-gcore | DNS-01, credentials в `~/.secrets/certbot/gcore.ini` | nginx, домен на Gcore |
| caddy встроенный ACME | Автоматически при первом запуске | caddy (MODE=1 и MODE=2) |

При извлечении в `tls.sh`: certbot-варианты (три штуки) — это один provider с тремя authenticator-методами, не три отдельных provider'а. Caddy ACME — второй provider, полностью автономный (не вызывает `certbot` вообще — пакет даже не устанавливается, см. `remote_install_deps`).

---

## 5. Reality/selfsteal transport — отдельная интеграция

**Не путать с web server adapter.** Это транспортный механизм Xray, который использует веб-сервер как downstream, но не является его частью.

```
Клиент (VLESS+Reality)
    │ TCP :443
    ▼
Xray (rw-core, host process)
  Reality handshake, xver:1 (proxy_protocol)
    │ unix:/dev/shm/nginx.sock
    ▼
web server adapter (nginx ИЛИ caddy — оба поддерживают этот приёмник)
    │ http://127.0.0.1:3000
    ▼
Remnawave Panel
```

Domain-логика (panel install) взаимодействует с этим через `web_server_configure_proxy` с параметром режима (`selfsteal` / `direct`), не генерируя nginx/caddy-специфичные `listen`-директивы напрямую.

---

## 6. Remnawave / XTLS SDK integration — статус: исследовано, не реализовано

Отдельно от web-server/TLS адаптеров. Это API-адаптер для получения статистики трафика и online-статуса пользователей через собственный gRPC-интерфейс Remnawave Node (Rust), не через HTTP webhook.

**Зафиксированное из предыдущего исследования (в коде репозитория пока отсутствует):**

```
@remnawave/xtls-sdk v0.16.0

StatsService методы:
  getSysStats, getAllUsersStats, getUserStats, getUserOnlineStatus,
  getAllInboundsStats, getInboundStats, getAllOutboundsStats,
  getOutboundStats, getUsersStats, getUsersStatsLegacy, rawClient

getAllUsersStats(reset=false) → client.queryStats({ pattern: 'user>>>', reset })
RPC endpoint: /xray.app.stats.command.StatsService/QueryStats

Ответ: stat[] → { name, value }
  name формат: user>>>USERNAME>>>...>>>uplink|downlink
SDK агрегирует в: { username, uplink, downlink }

Подтверждённый реальный ответ:
  { isOk: true, data: { users: [
      { username: '2', uplink: 121907, downlink: 10088 },
      { username: '3', uplink: 562, downlink: 178 }
  ]}}

Транспорт: unix-abstract:///xtls-api-<random>
  НЕ обычный filesystem unix socket — abstract Unix domain socket
  Требует custom gRPC resolver:
    tX.experimental.registerResolver("unix-abstract", tJ)
    AbstractUdsResolver: "unix-abstract:///path" → "\0" + path

  Без зарегистрированного resolver — grpc-js падает:
    "Failed to parse DNS address dns:unix-abstract:///..."
```

**Отдельный, отличный от Reality/selfsteal unix-сокета механизм.** `/dev/shm/nginx.sock` (§5) — это TCP/TLS reverse-proxy транспорт для HTTPS-трафика. `unix-abstract:///xtls-api-*` — это gRPC-транспорт для stats API Remnawave Node. Оба используют unix-сокеты, но это два независимых пути с разным назначением — не объединять в документации или в коде.

**Куда в целевой архитектуре:** отдельный адаптер `lib/panel/xtls_stats.sh` (или Python-компонент, если интеграция требует Node.js SDK — уточнить при реализации), потребляемый через тот же контракт, что и остальные integration adapters (§2). Domain-логика panel/hy2 не должна знать про gRPC resolver или sdk-детали напрямую.

**Статус:** знание зафиксировано, реализации в коде нет. Не начинать реализацию сейчас — только резервируем архитектурное место.

---

## 7. Hysteria2 adapter

**Текущее состояние:** частично изолирован в `lib/hy2/`, но domain-модуль напрямую обращается к config.yaml, systemd, users.json без промежуточного adapter-слоя. Это приемлемо для текущего этапа — hy2 core.sh уже играет роль частичного adapter'а (`hy_is_installed`, `hy_is_running`, `hy_get_domain_port`).

**Целевой контракт (для будущего, не сейчас):**

```
Domain (hy2/users.sh, hy2/menu.sh)
        ↓
HysteriaAdapter (hy2/core.sh — уже частично играет эту роль)
        ↓
Hysteria2 config.yaml / systemd / API :9999 (trafficStats)
```

Должен позволять менять способ получения users/online/traffic/config/status без переписывания UI. Сейчас `users.json` (HTTP auth) читается напрямую через inline Python в `hy2/users.sh` и `hy2/install.sh` — при экстракции в `py/` эта точка станет местом, где adapter-контракт формализуется естественным образом.

---

## 8. Telemt adapter — статус: legacy, не трогать сейчас

Явно выведен из скоупа текущего этапа. Остаётся монолитным файлом `lib/telemt.sh` (1498 строк) с множественными inline `python3 -c` блоками.

**Целевая структура (для справки, реализация — отдельный этап):**

```
lib/telemt/
├── core.sh
├── install.sh
├── users.sh
├── manage.sh
├── menu.sh
└── py/
    ├── collect_stats.py
    ├── render_users.py
    └── ...
```

**Что НЕ делать сейчас:** не переносить telemt.sh код механически, не начинать SQLite/collector реализацию, не трогать `traffic-usage.json`. Ссылка на этот раздел — только резервирование места в архитектуре, чтобы будущий telemt-рефакторинг не создавал конфликт с web/tls-адаптерами, которые реализуются раньше.

---

## 9. System layer

**Текущее состояние:** SSH-хелперы (`ask_ssh_target`, `init_ssh_helpers`, `ensure_sshpass`, `check_ssh_connection`, `remote_install_deps`) живут в `lib/common.sh`, используются в 4 местах (`migrate.sh`, `panel.sh`, `telemt.sh`, `hy2/menu.sh`).

```
lib/system/
├── core.sh
├── services.sh      # systemctl wrapping
├── firewall.sh       # ufw wrapping
├── network.sh
└── migrate.sh         # текущий lib/migrate.sh + SSH-хелперы из common.sh
```

`remote_install_deps` уже принимает `web_server` параметр (nginx|caddy) — при переносе в `system/` этот параметр должен транслироваться через `lib/web/detect.sh`, не напрямую.

---

## 10. sub-injector

Изолирован корректно, отдельный жизненный цикл (Rust/Axum, свой Cargo.toml, отдельный hardening-коммит в git-истории). Взаимодействие с остальной системой — через `config.toml` и HTTP-вызов к `hy-webhook.py` (`GET /uri/:token`). Не переносить внутрь `lib/panel/` или `lib/hy2/` ради структуры — граница уже правильная.

---

## 11. Online path vs Subscription path

Разделены функционально уже сейчас в `hy-webhook.py`, но не формализованы как отдельные domain services.

```
Online path:
  Hysteria2 trafficStats :9999 → fetch_hy_online() → update_online_status()
  → online_poller() (daemon thread, ONLINE_POLL_INTERVAL)

Subscription path:
  GET /uri/:shortUuid → Remnawave API (username lookup) → users.json (password lookup)
  → build_hy2_uri() → hy2:// URI
  TTL-кэш (URI_CACHE_TTL, default 60s)
```

Не один и тот же API только потому, что оба про пользователя. При формализации — два разных метода adapter'а, не один "user info" метод.

---

## 12. Traffic/stats path

```
Hysteria2 trafficStats :9999 → fetch_hy_traffic() → write_traffic_to_db()
  → traffic_poller() (daemon thread, TRAFFIC_POLL_INTERVAL=60s)
  → PostgreSQL (Remnawave DB), pending-file для crash recovery

Telemt: telemt API :9091 → inline python3 -c в telemt.sh → traffic-usage.json
  (legacy, JSON-based, collector/SQLite — будущий этап, см. §8)
```

Два независимых traffic pipeline для двух разных VPN-технологий. Не объединять преждевременно — Hysteria2 traffic идёт в PostgreSQL (downstream Remnawave), Telemt traffic — в собственный JSON/будущий SQLite.

---

## 13. Unix sockets / gRPC / resolvers — сводка

| Механизм | Путь/адрес | Назначение | Статус в коде |
|---|---|---|---|
| Reality/selfsteal transport | `/dev/shm/nginx.sock` | Xray → web server, HTTPS reverse-proxy | ✅ Реализовано (nginx и caddy) |
| XTLS SDK gRPC stats | `unix-abstract:///xtls-api-<random>` | Remnawave Node stats (QueryStats RPC) | ⏳ Исследовано, не реализовано |

Не путать эти два механизма ни в коде, ни в документации — разное назначение, разный транспорт (TCP/TLS proxy vs gRPC), разный resolver.

---

## 14. Port inventory

**Правило:** не предполагать топологию заранее. Перед любым изменением network/TLS-части — проверить актуальный bind каждого компонента в текущем режиме (MODE=1 selfsteal vs MODE=2 direct) и текущем провайдере (nginx vs caddy).

```
Внешние:
  443    MODE=1 (selfsteal): Xray (rw-core), host process — веб-сервер НЕ слушает напрямую
         MODE=2 (direct):    nginx ИЛИ caddy — слушает напрямую
  80     certbot standalone HTTP-01 challenge (nginx, временно, если этот метод выбран)
         caddy ACME (авто, оба MODE, включая MODE=1 — нужен для challenge даже
                      когда :443 занят Xray)

Внутренние (127.0.0.1 если не указано иное):
  2222   Remnawave node registration address (внутри configProfile)
  3000   Remnawave Panel (Docker)
  3010   Remnawave Subscription backend (Docker)
  3020   sub-injector / hy-webhook встроенный proxy (PROXY_PORT)
  6767   PostgreSQL (Docker, → 5432 внутри контейнера)
  8443   Hysteria2 listener (config.yaml)
  8766   hy-webhook.py (0.0.0.0 — доступен из Docker gateway)
  9091   telemt API (127.0.0.1 в systemd-режиме, 0.0.0.0 в docker-режиме)
  9999   Hysteria2 trafficStats

Unix sockets:
  /dev/shm/nginx.sock                   Reality selfsteal transport (§5)
  unix-abstract:///xtls-api-<random>    XTLS SDK gRPC stats (§6, не реализовано)

Docker network:
  172.30.0.0/16   remnawave-network, gateway 172.30.0.1
  UFW rule: 172.16.0.0/12 (покрывает весь возможный диапазон Docker подсетей)
```

---

## 15. Что уже закрыто / что не закрыто (сводка после аудита `beta`)

### Закрыто
- `hy2/` частичный domain split (5 файлов + loader)
- `hy-webhook.py` threading (включено по умолчанию)
- `sub-injector` изоляция
- Module loader с SHA256-инфраструктурой (пока неактивной, пустые суммы)
- Online/subscription функциональное разделение внутри hy-webhook.py
- **Web server dual-provider поддержка (nginx + caddy)** — реализована функционально, не формализована архитектурно

### Не закрыто
- CLI boundary (`lib/cli/`) — не существует
- UI extraction (`lib/ui/`) — не существует
- `lib/core/` (config/versions/logging/errors/utils) — не существует
- `lib/web/` (web server + TLS adapter) — не существует, логика размазана по `panel.sh`
- Remnawave/XTLS SDK stats adapter — знание есть, реализации нет
- `lib/telemt/` domain split — не начат (намеренно, отдельный этап)
- Python extraction (`py/` директории) — не начата нигде
- SQLite/collector для telemt — не начат
- `lib/system/` (services/firewall/network/migrate) — не существует
- `docs/CONTRACTS.md`, `docs/INTEGRATIONS.md`, `docs/TLS.md` — не существуют

---

## 16. Известные несогласованности (не блокеры, зафиксировать)

- `get_hysteria_version()` определена дважды (`panel.sh:1715`, `hy2/core.sh:9`) с разным форматом (без/с `v`-префиксом). Функционального бага нет (см. investigation в рабочих заметках) — только косметическое расхождение между main_menu и hy2-подменю. Исправляется естественно при выносе в `lib/core/versions.sh`.
- `panel_api()` (`common.sh:294`) и `panel_api_request()` (`panel.sh:1728`) — два независимых HTTP-клиента к Remnawave API с разной сигнатурой, оба активно используются. Слияние в единый adapter требует явного решения по сигнатуре.
- Комментарий в `common.sh:324` содержит неверное утверждение об источнике `get_hysteria_version` (указывает на `panel.sh`, фактически последним грузится `hy2/core.sh`). Исправить при рефакторинге version-функций.
- `DATABASE_URL=postgresql://postgres:postgres@127.0.0.1:6767/postgres` захардкожен в `hy-sub-install.sh` и структурно повторяется в `panel.sh` (4 раза в разных compose-шаблонах). Кандидат на единую константу в `lib/core/config.sh`.
