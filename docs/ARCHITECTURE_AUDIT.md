# Server-manager architecture audit

This document records the pre-refactor audit of the current source-based shell architecture. `lib/panel.sh.bak` is treated as historical reference only and is intentionally excluded from active-source findings.

## A. Current architecture map

```text
server-manager.sh
  ├─ resolves SCRIPT_DIR / bootstrap clone-or-reexec path
  ├─ defines _load_module and _sm_source_file
  ├─ sources lib/core/config.sh        # shared immutable config, introduced by this refactor
  ├─ sources lib/common.sh             # UI primitives, shared helpers, ssh helpers, main menu
  ├─ sources lib/panel.sh              # Remnawave install/manage, .env generation, API helpers
  ├─ sources lib/telemt.sh             # Telemt install/manage, stats and traffic helpers
  ├─ sources lib/hysteria.sh           # facade loader for lib/hy2/*
  │    ├─ lib/hy2/core.sh              # Hysteria checks/config readers
  │    ├─ lib/hy2/install.sh           # Hysteria install/config generation
  │    ├─ lib/hy2/users.sh             # Hysteria user management
  │    ├─ lib/hy2/integration.sh       # Remnawave/sub-injector glue
  │    └─ lib/hy2/menu.sh              # Hysteria menus and subscription helpers
  ├─ sources lib/migrate.sh            # migration helpers
  └─ sources lib/cli/router.sh         # CLI dispatch

integrations/hy-sub-install.sh         # standalone installer for Hysteria2 ↔ Remnawave subscription sync
integrations/hy-webhook.py             # standalone webhook runtime service
sub-injector/                          # standalone Rust runtime component
```

Because the loader uses `source`, all modules share one shell namespace. Any top-level assignment in a loaded file is effectively global.

## B. Important globals table

| variable | current_file | current_scope | used_by | category | proposed_owner | proposed_action | risk |
|---|---|---|---|---|---|---|---|
| `SCRIPT_DIR` | `server-manager.sh`, `integrations/hy-sub-install.sh` | bootstrap global / standalone local global | loader, panel update paths, migrate; standalone integration only | shared-config / integration-config | bootstrap for main process; integration-local for standalone script | keep main `SCRIPT_DIR`; later rename integration's `SCRIPT_DIR` to local lowercase to avoid collisions if ever sourced | medium |
| `REPO_RAW`, `REPO_URL`, `INSTALL_DIR` | `server-manager.sh` | bootstrap global | loader/bootstrap only | shared-config | future `lib/core/bootstrap.sh` | keep until bootstrap split | low |
| `PANEL_DIR` | `lib/panel.sh` → `lib/core/config.sh` | global constant | panel filesystem operations | shared-config | `lib/core/config.sh` | centralized as immutable shared config | low |
| `PANEL_NGINX_DIR` | `lib/panel.sh` → `lib/core/config.sh` | global constant | panel nginx operations | shared-config | `lib/core/config.sh` | centralized as immutable shared config | low |
| `PANEL_TOKEN_FILE` | `lib/panel.sh` → `lib/core/config.sh` | global constant | panel API token helpers | shared-config / secret path | `lib/core/config.sh` | centralized path only; token contents remain secret file data | low |
| `PANEL_API` | `lib/panel.sh` → `lib/core/config.sh` | global constant | panel API calls | shared-config | `lib/core/config.sh` | centralized | low |
| `PANEL_MGMT_SCRIPT` | `lib/common.sh` → `lib/core/config.sh` | global constant | panel management install/update | shared-config | `lib/core/config.sh` | centralized | low |
| `HYSTERIA_CONFIG` | `lib/common.sh`, `integrations/hy-sub-install.sh` → `lib/core/config.sh` + generated env fallback | global constant / generated env key | `lib/hy2/*`, migrate, hy-webhook env | shared-config / generated-config | `lib/core/config.sh` for manager; env builder in integration for service env | manager definition centralized; integration writes `${HYSTERIA_CONFIG:-...}` to generated env | medium |
| `HYSTERIA_DIR` | `lib/common.sh` → `lib/core/config.sh` | global constant | Hysteria domain | shared-config | `lib/core/config.sh` | centralized | low |
| `HYSTERIA_SVC` | `lib/common.sh`, `integrations/hy-sub-install.sh` → `lib/core/config.sh` + generated env fallback | global constant / generated env key | `lib/hy2/*`, generated hy-webhook env | shared-config / generated-config | `lib/core/config.sh`; integration env builder | manager definition centralized; integration writes `${HYSTERIA_SVC:-...}` | medium |
| `TELEMT_BIN`, `TELEMT_CONFIG_*`, `TELEMT_WORK_DIR_*`, `TELEMT_SERVICE_FILE`, `TELEMT_API_URL` | `lib/common.sh` → `lib/core/config.sh` | global constants | telemt/migrate | shared-config | `lib/core/config.sh` | centralized | low |
| `TELEMT_MODE`, `TELEMT_CONFIG_FILE`, `TELEMT_WORK_DIR` | `lib/common.sh`, runtime setters in telemt | runtime globals | telemt functions after mode detection | domain-config | `lib/telemt.sh` domain runtime state | keep for now; later make explicit return/arguments where feasible | medium |
| `TELEMT_CHOSEN_VERSION` | `lib/common.sh`, `lib/telemt.sh` | runtime global | telemt install/update | domain-config | `lib/telemt.sh` | remove duplicate default later; keep single domain owner | low |
| `RED`, `GREEN`, `YELLOW`, `BLUE`, `CYAN`, `WHITE`, `PURPLE`, `GRAY`, `BOLD`, `DIM`, `NC`, `RESET` | `lib/common.sh`, repeated in panel/telemt/integration snippets | top-level globals and heredoc snippets | UI output across modules and generated snippets | ui | future `lib/ui/output.sh`; standalone scripts may keep private copies | separate UI from common in a later step | medium |
| `STEP_NUM`, `TOTAL_STEPS` | `integrations/hy-sub-install.sh`; implicit in `lib/common.sh:step` | global mutable progress state | step functions | function-local / ui | caller-local or UI progress object | do not centralize; later lowercase/localize inside installer functions or pass total to step helper | medium |
| `APP_PORT`, `METRICS_PORT`, `API_INSTANCES`, `DATABASE_URL`, `REDIS_SOCKET`, `JWT_AUTH_LIFETIME`, `FRONT_END_DOMAIN`, `SUB_PUBLIC_DOMAIN`, `WEBHOOK_*`, `TELEGRAM_*`, `POSTGRES_*` | `lib/panel.sh` heredoc for `.env`; `integrations/hy-sub-install.sh` generated env | generated config text | generated files, not shell readers | generated-config / secret | panel env builder / integration env builder | keep as heredoc content; do not promote to globals | high if altered |
| `SUPERADMIN_USER`, `SUPERADMIN_PASS`, `COOKIE_KEY`, `COOKIE_VAL`, `APP_SECRET`, `METRICS_USER`, `METRICS_PASS` | `lib/panel.sh` install flow | function runtime, credentials | panel install and generated `.env` | secret / generated-config | panel install config builder | localize carefully after mapping reads/writes | high |
| `PANEL_DOMAIN`, `SUB_DOMAIN`, `SELFSTEAL_DOMAIN`, `CERT_METHOD` | `lib/panel.sh` install flow | function runtime | panel install/config generation | domain-config | panel install workflow | localize within install workflow if no cross-function dependency | high |
| `ATTEMPTS`, `REG`, `TOKEN`, `KEYS_R`, `PRIV_KEY`, `PUB_R`, `PUB_KEY`, `OLD_P`, `SHORT_ID`, `PROFILE_R`, `CFG_UUID`, `IBD_UUID`, `SQUAD_UUIDS`, `SUB_TOKEN_R`, `SUB_TOKEN` | `lib/panel.sh` API/provisioning flows | mutable command state | usually same function or adjacent API flow | function-local / secret | panel API/provisioning functions | convert to lowercase locals in small tested batches | high |
| `ARCH`, `LIBC`, `URL`, `TMP` | `lib/migrate.sh`, `lib/telemt.sh` remote heredocs | shell snippets for remote install | child/remote shell only | temporary / subprocess-env | function-local snippets | leave as snippet-local; don't centralize | low |
| `TELEMT_TRAFFIC_DB`, `TELEMT_IP_RETENTION_DAYS`, `TELEMT_TRAFFIC_RETENTION_DAYS`, `TELEMT_SELECTED_USER`, `TELEMT_USER_PAIRS` | `lib/telemt.sh` inline env to Python | process environment | Python subprocesses only | subprocess-env | telemt stats functions | keep scoped `VAR=value python3 ...` | low |
| `DO_WEBHOOK`, `DO_SUBPAGE`, `HY_DOMAIN`, `HY_PORT`, `HY_NAME`, `MAIN_PORT`, `HOP_RANGE`, `START_PORT`, `END_PORT` | `integrations/hy-sub-install.sh` | standalone installer state | same script | integration-config / function-local / temporary | integration installer workflow | only localize when script is functionized; avoid mixing with manager globals | medium |
| `WEBHOOK_SECRET`, `REMNAWAVE_API_TOKEN`, `REMNAWAVE_TOKEN`, `HY_TRAFFIC_SECRET` | `integrations/hy-sub-install.sh` | installer/runtime secrets | generated env and service config | secret / generated-config | integration env builders | keep scoped and protect generated files; avoid logging secrets | high |
| `INJECTOR_DIR`, `INJECTOR_BIN`, `INJECTOR_CFG`, `INJECTOR_URL`, `INJECTOR_SRC` | `integrations/hy-sub-install.sh`, `lib/hy2/integration.sh` | integration install constants | sub-injector install/status | integration-config | sub-injector installer adapter | preserve standalone component boundary | medium |

## C. Conflicting definitions

Active-source conflicting or duplicated definitions found during audit:

- `HYSTERIA_CONFIG`: was defined in `lib/common.sh` and as a literal generated env value in `integrations/hy-sub-install.sh`; manager owner is now `lib/core/config.sh`, while integration writes a generated env value with fallback.
- `HYSTERIA_SVC`: same pattern as `HYSTERIA_CONFIG`; manager owner is now `lib/core/config.sh`.
- `PANEL_DIR`, `PANEL_NGINX_DIR`, `PANEL_TOKEN_FILE`, `PANEL_API`: panel-owned constants were top-level in `lib/panel.sh`; now centralized in `lib/core/config.sh`.
- `TELEMT_CHOSEN_VERSION`: default exists in `lib/common.sh` and `lib/telemt.sh`; should become telemt-domain runtime state only.
- UI colors (`RED`, `GREEN`, `YELLOW`, `CYAN`, `WHITE`, `PURPLE`, `GRAY`, `BOLD`, `DIM`, `NC`, `RESET`): repeated across common, panel compatibility blocks, telemt snippets and standalone integration. Manager UI should move to `lib/ui/output.sh`; standalone scripts may keep private copies.
- `SCRIPT_DIR`: bootstrap global in `server-manager.sh` and standalone-local global in `integrations/hy-sub-install.sh`; harmless while standalone, risky if sourced.
- `DATABASE_URL`: appears in Remnawave `.env` generation and hy-traffic generated env with different meanings; this is not a shared config conflict and must remain builder-local/generated.
- `ARCH`, `LIBC`, `URL`, `TMP`: appear in generated/remote snippets; temporary state, not shared config.

## D. Proposed target tree

Moderate target structure, migrated gradually:

```text
server-manager.sh                 # minimal bootstrap entrypoint
lib/
  core/
    config.sh                     # immutable shared paths/service names/API endpoints only
    bootstrap.sh                  # SCRIPT_DIR/reexec/module loading later
    versions.sh                   # script version and update metadata
    utils.sh                      # pure non-UI shell helpers
  ui/
    output.sh                     # colors, ok/info/warn/err/detail/header/section/step
    prompts.sh                    # ask/confirm/menu prompt helpers
  cli/
    router.sh                     # command dispatch only
    commands/                     # thin CLI command handlers when router grows
  panel/
    index.sh                      # compatibility facade for panel domain
    install.sh                    # Remnawave install workflow
    env_builder.sh                # Remnawave .env generation; generated-config locals
    api.sh                        # Remnawave API/token adapter boundary
    branding.sh                   # panel branding edits
  hysteria/
    index.sh                      # compatibility facade replacing lib/hysteria.sh later
    core.sh                       # domain checks/readers
    install.sh                    # install/config workflow
    users.sh                      # user operations
    subscription.sh               # subscription-domain logic, distinct from online runtime
  telemt/
    index.sh
    install.sh
    runtime.sh                    # systemd/docker mode detection and runtime config
    traffic.sh                    # stats/traffic collectors and subprocess env
  integrations/
    remnawave.sh                  # HTTP/auth details hidden behind functions
    hysteria.sh                   # config/systemd/API adapter
    telemt.sh                     # stats API/systemd/docker adapter
    systemd.sh
    nginx.sh
    tls.sh
services/                         # generated runtime helpers if they are shipped as files
integrations/                     # standalone installers/runtime scripts remain valid entrypoints
sub-injector/                     # standalone Rust component; not sourced as shell library
```

Directory rules:

- `lib/core`: no dependency on UI, CLI or domains. Allowed globals: immutable constants and version metadata only. Secrets, generated env keys and mutable runtime state are forbidden.
- `lib/ui`: may depend on `core/config` only for display metadata. Allowed globals: UI primitives/colors while source-based architecture remains. Domain paths/secrets forbidden.
- `lib/cli`: depends on core, UI and domain public functions. No service implementation details and no generated config variables.
- `lib/panel`, `lib/hysteria`, `lib/telemt`: domain workflows. May call integration adapters. Mutable state should be local to workflow functions or returned explicitly.
- `lib/integrations`: hides external implementation details: HTTP APIs, `systemctl`, nginx/Caddy, TLS/acme, file formats and sockets. Accept values as arguments when operation-specific; read shared constants only for default paths/service names.
- `services`: contains installable helper assets/scripts, not sourced shell modules.
- `sub-injector`: remains standalone Rust runtime. Server-manager may install/update/configure/status-check it, but must not turn it into a sourced library.

Dependency direction:

```text
core → ui/cli → domains → integrations/adapters → external services
```

In shell terms, higher layers may call functions loaded from lower layers through the bootstrap order, but domain modules should not source CLI or menu modules, and integrations should not depend on panel menus.

## E. Small-step migration plan

1. Centralize immutable shared constants in `lib/core/config.sh` and load it before existing modules.
2. Remove duplicate top-level path/service definitions from domain files when a safe single source of truth exists.
3. Mark generated config sections as builders and keep their uppercase keys inside heredocs or local builder functions.
4. Convert obvious temporary/function-local state in small batches (`STEP_NUM`, `ATTEMPTS`, API response variables), starting with functions that have no cross-function reads.
5. Extract UI colors/output helpers from `lib/common.sh` to `lib/ui/output.sh`; keep compatibility aliases during transition.
6. Split panel into a compatibility facade plus `install`, `env_builder`, `api`, and `branding` modules without changing public CLI commands.
7. Split Telemt runtime detection from stats/traffic subprocess helpers; keep subprocess environment scoped inline.
8. Split Hysteria online/runtime operations from subscription operations; keep adapters shared but responsibilities distinct.
9. Move bootstrap/module loading out of `server-manager.sh` only after module boundaries are stable.
10. Add narrow smoke checks around loader/source order and generated config rendering; avoid a large new test framework.

## F. Potentially dangerous places

- Source-based namespace: top-level assignments in any loaded file can silently overwrite another module.
- `set -euo pipefail`: localizing variables can expose unset-variable exits if a function relied on an implicit global.
- Generated `.env` heredocs: uppercase names in heredocs are target config keys, not manager globals; changing them changes installed services.
- Secrets (`SUPERADMIN_PASS`, `APP_SECRET`, tokens, webhook secrets): avoid logging and preserve file permissions.
- Hysteria subscription vs online runtime paths: both touch Hysteria and Remnawave but serve different responsibilities.
- `integrations/hy-sub-install.sh`: currently standalone; do not source it into the main process without first localizing/renaming globals.
- Remote heredocs in migration/telemt install: `ARCH`, `LIBC`, `URL`, `TMP` may look global in static scans but execute in child/remote shells.
- Systemd unit heredocs contain keys like `Type=`, `Restart=`, `Environment=` that are not shell assignments.
- `sub-injector/Cargo.lock` is currently untracked in this checkout; avoid accidentally committing unrelated generated dependency state unless intentionally requested.
