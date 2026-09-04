# shellcheck shell=bash
# telemt/install.sh — скачивание бинарника, генерация конфигов/сервисов, установка


telemt_download_binary() {
    local ver="${1:-latest}" arch libc url
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64)
            # Проверяем поддержку AVX2+BMI2 для оптимизированной сборки
            if [ -r /proc/cpuinfo ] && grep -q "avx2" /proc/cpuinfo 2>/dev/null && grep -q "bmi2" /proc/cpuinfo 2>/dev/null; then
                arch="x86_64-v3"
            else
                arch="x86_64"
            fi ;;
        aarch64|arm64) arch="aarch64" ;;
        *) die "Архитектура не поддерживается: $arch" ;;
    esac
    ldd --version 2>&1 | grep -iq musl && libc="musl" || libc="gnu"
    [ "$ver" = "latest" ] \
        && url="https://github.com/${TELEMT_GITHUB_REPO}/releases/latest/download/telemt-${arch}-linux-${libc}.tar.gz" \
        || url="https://github.com/${TELEMT_GITHUB_REPO}/releases/download/${ver}/telemt-${arch}-linux-${libc}.tar.gz"
    info "Скачиваю telemt $ver (${arch}-linux-${libc})..."
    local tmp; tmp=$(mktemp -d)
    if ! curl -fsSL "$url" | tar -xz -C "$tmp" 2>/dev/null; then
        # Откат к стандартному x86_64 если v3 не найден
        if [ "$arch" = "x86_64-v3" ]; then
            warn "Сборка x86_64-v3 не найдена, откат к стандартной x86_64..."
            arch="x86_64"
            [ "$ver" = "latest" ] \
                && url="https://github.com/${TELEMT_GITHUB_REPO}/releases/latest/download/telemt-${arch}-linux-${libc}.tar.gz" \
                || url="https://github.com/${TELEMT_GITHUB_REPO}/releases/download/${ver}/telemt-${arch}-linux-${libc}.tar.gz"
            curl -fsSL "$url" | tar -xz -C "$tmp" 2>/dev/null || { rm -rf "$tmp"; die "Не удалось скачать бинарник."; }
        else
            rm -rf "$tmp"; die "Не удалось скачать бинарник."
        fi
    fi
    local extracted; extracted=$(find "$tmp" -type f -name "telemt" | head -1)
    [ -n "$extracted" ] || { rm -rf "$tmp"; die "Бинарник не найден в архиве."; }
    install -m 0755 "$extracted" "$TELEMT_BIN" && rm -rf "$tmp" \
        && ok "Установлен: $TELEMT_BIN" || { rm -rf "$tmp"; die "Не удалось установить бинарник."; }
}

telemt_write_config() {
    local port="$1" domain="$2"; shift 2
    local tls_front_dir api_listen api_wl
    if [ "$TELEMT_MODE" = "systemd" ]; then
        mkdir -p "$TELEMT_CONFIG_DIR" "$TELEMT_TLSFRONT_DIR"
        tls_front_dir="$TELEMT_TLSFRONT_DIR"; api_listen="127.0.0.1:9091"; api_wl='["127.0.0.1/32"]'
    else
        mkdir -p "$TELEMT_WORK_DIR_DOCKER"; tls_front_dir="tlsfront"; api_listen="0.0.0.0:9091"; api_wl='["127.0.0.0/8"]'
    fi
    # Co-located bind + PROXY protocol (2026-09-04): gated on TELEMT_COLOCATE,
    # an environment variable read here — not a new positional argument,
    # since no caller anywhere in lib/panel/ currently invokes any function
    # in this file at all (confirmed: telemt_write_config/telemt_write_compose/
    # telemt_menu_install are reachable only from this file's own
    # menu.sh-driven interactive flow, never from lib/panel/install.sh or
    # any MODE=F/J code path). Reading an env var here makes the capability
    # available to a future orchestration layer (export TELEMT_COLOCATE=1
    # before calling these functions non-interactively) without inventing
    # that orchestration layer or its CLI prompts myself — see this
    # session's report for that specific, still-open gap.
    #
    # Default ("${TELEMT_COLOCATE:-0}" unset or "0"): unchanged standalone
    # behavior — ip = "0.0.0.0", no proxy_protocol line at all, reproducing
    # today's config byte-for-byte (verified this session).
    #
    # TELEMT_COLOCATE=1: ip = "127.0.0.1" (Nginx becomes the only public
    # ingress for this port — matches lib/panel/nginx/variant_j.sh's own
    # existing TeleMT upstream, which already targets 127.0.0.1:$TELEMT_PORT)
    # plus proxy_protocol = true on this SAME listener entry — using the
    # per-listener override (docs/TELEMT_CONFIG.md's `[[server.listeners]]
    # .proxy_protocol` field) rather than the global `[server].proxy_protocol`
    # switch, per instruction to prefer the narrower, already-documented
    # override when it can fully express the requirement (it can: there is
    # only ever one listener here either way).
    #
    # NOT PERSISTED: this flag is read fresh every time telemt_write_config()
    # runs and is not written to any state file. telemt_menu_update() (see
    # menu.sh) never calls telemt_write_config() again, so an update alone
    # cannot silently flip a co-located install back to standalone — but a
    # future *reinstall* through telemt_menu_install() would need
    # TELEMT_COLOCATE=1 re-exported, or it silently regenerates the
    # standalone config. Flagging this as a real, open architectural gap
    # (no persistent state mechanism exists for this install's mode) rather
    # than inventing a new state file to close it without being asked.
    local listener_ip="0.0.0.0" listener_pp_line=""
    if [ "${TELEMT_COLOCATE:-0}" = "1" ]; then
        listener_ip="127.0.0.1"
        listener_pp_line=$'\nproxy_protocol = true'
    fi
    { cat <<EOF
[general]
use_middle_proxy = ${TELEMT_USE_ME:-true}
log_level = "normal"

[general.modes]
classic = false
secure  = false
tls     = true

[general.links]
show = "*"

[server]
port = $port

[server.api]
enabled   = true
listen    = "$api_listen"
whitelist = $api_wl

[[server.listeners]]
ip = "$listener_ip"${listener_pp_line}

[censorship]
tls_domain    = "$domain"
mask          = true
tls_emulation = true
tls_front_dir = "$tls_front_dir"

[access.users]
EOF
      for pair in "$@"; do echo "${pair%% *} = \"${pair#* }\""; done
      # upstream-секция — только если задан SOCKS5
      if [ -n "${TELEMT_SOCKS5_ADDR:-}" ]; then
          echo ""
          echo "[[upstreams]]"
          echo "type    = \"socks5\""
          echo "address = \"${TELEMT_SOCKS5_ADDR}\""
          [ -n "${TELEMT_SOCKS5_USER:-}" ] && echo "username = \"${TELEMT_SOCKS5_USER}\""
          [ -n "${TELEMT_SOCKS5_PASS:-}" ] && echo "password = \"${TELEMT_SOCKS5_PASS}\""
      fi
    } > "$TELEMT_CONFIG_FILE"
    [ "$TELEMT_MODE" = "systemd" ] && chmod 640 "$TELEMT_CONFIG_FILE"
}

telemt_write_service() {
    cat > "$TELEMT_SERVICE_FILE" <<'EOF'
[Unit]
Description=Telemt MTProto Proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=telemt
Group=telemt
WorkingDirectory=/opt/telemt
ExecStart=/usr/local/bin/telemt /etc/telemt/telemt.toml
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_ADMIN
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_NET_ADMIN
NoNewPrivileges=true
ExecReload=/bin/kill -HUP $MAINPID

[Install]
WantedBy=multi-user.target
EOF
}

telemt_write_compose() {
    local port="$1"
    # Same TELEMT_COLOCATE contract as telemt_write_config() above — default
    # (unset/"0") publishes on all interfaces exactly as before; "1" binds
    # the host-side publish to loopback only, so Docker's own userland-proxy
    # never listens on 0.0.0.0:$port regardless of what the TOML says (the
    # TOML and this compose file are two independent places the public bind
    # would otherwise leak from — the API port (9091) already got this right
    # in this file's untouched line below, this only extends the same
    # pattern to the proxy port itself).
    local port_bind="$port"
    [ "${TELEMT_COLOCATE:-0}" = "1" ] && port_bind="127.0.0.1:${port}"
    cat > "$TELEMT_COMPOSE_FILE" <<EOF
services:
  telemt:
    image: ghcr.io/telemt/telemt:latest
    container_name: telemt
    restart: unless-stopped
    working_dir: /run/telemt
    environment:
      RUST_LOG: "info"
    volumes:
      - ./telemt.toml:/run/telemt/config.toml:ro
    tmpfs:
      - /run/telemt:rw,mode=1777,size=1m
    ports:
      - "${port_bind}:${port}/tcp"
      - "127.0.0.1:9091:9091/tcp"
    security_opt: [no-new-privileges:true]
    cap_drop: [ALL]
    cap_add: [NET_BIND_SERVICE]
    read_only: true
    ulimits: {nofile: {soft: 65536, hard: 65536}}
    logging: {driver: json-file, options: {max-size: "10m", max-file: "3"}}
EOF
}

telemt_install_noninteractive() {
    # ── Неинтерактивная установка/переконфигурация TeleMT ────────
    # Единственный вызывающий — Panel (lib/panel/install.sh, MODE=F/J,
    # integrated-сценарий, через lib/panel/cli.sh:panel_cli_collect_j_options()
    # для сбора параметров и обнаружения существующего состояния).
    # НИКОГДА не вызывается для standalone-установки — тот путь
    # (telemt_menu_install(), меню TeleMT) полностью независим и не
    # трогается этой функцией и вызывающей её стороной.
    #
    # Не переиспользует telemt_menu_install() напрямую: та функция
    # читает /dev/tty на каждом шаге (порт, домен, пользователи,
    # upstream, выбор версии) — условно отключать эти read() пришлось
    # бы протаскивать флаг через каждый из них, то есть трогать рабочий
    # standalone-путь ради Panel. Вместо этого здесь используются ТЕ ЖЕ
    # низкоуровневые примитивы (telemt_download_binary/
    # telemt_write_config/telemt_write_service/telemt_write_compose) —
    # они не менялись и остаются единственным местом, которое реально
    # пишет конфиг/сервис/compose и запускает процесс. Второго
    # TeleMT-lifecycle здесь не создаётся.
    #
    # Аргументы: port domain mode use_me socks_addr socks_user socks_pass [user_pairs...]
    #   - port/domain: co-located loopback-порт и tls_domain (одни и те
    #     же значения одновременно идут и в Nginx routing, и сюда —
    #     см. panel_cli_collect_j_options()).
    #   - mode: "systemd" или "docker". Для НОВОЙ integrated-установки
    #     Panel всегда передаёт "docker" (без интерактивного выбора —
    #     не предусмотрено требованиями задачи). Для RECONFIGURE уже
    #     существующей integrated-установки Panel передаёт её
    #     фактический обнаруженный режим (telemt_detect_installed_mode),
    #     чтобы не переключать рантайм без причины.
    #   - use_me/socks_*: сохраняются как есть при reconfigure
    #     (telemt_detect_use_me/telemt_detect_socks5_*), либо "true"/""
    #     по умолчанию для новой установки — Panel не имеет собственного
    #     мнения об upstream-настройках TeleMT.
    #   - user_pairs: при reconfigure — существующие пользователи
    #     (telemt_detect_user_pairs), чтобы не удалить их. При новой
    #     установке, если не передано ни одного, генерируется один
    #     пользователь по умолчанию (иначе TeleMT остался бы без единого
    #     клиента — управление пользователями остаётся за отдельным
    #     меню TeleMT, Panel лишь обеспечивает нерабочий процесс не
    #     стартует с пустым access.users).
    local port="$1" domain="$2" mode="$3"
    local use_me="${4:-true}" socks_addr="${5:-}" socks_user="${6:-}" socks_pass="${7:-}"
    shift 7
    local -a pairs=("$@")
    [ ${#pairs[@]} -eq 0 ] && pairs=("panel-$(openssl rand -hex 4) $(gen_secret)")

    # TELEMT_COLOCATE читается telemt_write_config()/telemt_write_compose()
    # как обычная переменная окружения/контекста (см. их собственные
    # комментарии) — здесь она объявлена `local`, что в bash видно
    # дочерним функциям, вызванным из этой же функции (динамическая
    # область видимости), но не «протекает» наружу в остальной процесс
    # Panel после возврата. То же самое для TELEMT_USE_ME/TELEMT_SOCKS5_*
    # ниже — они используются telemt_write_config() точно так же, как в
    # интерактивном пути (telemt_ask_upstream), просто не через
    # интерактивный запрос, а установлены явно вызывающей стороной.
    local TELEMT_COLOCATE="1"
    local TELEMT_USE_ME="$use_me"
    local TELEMT_SOCKS5_ADDR="$socks_addr"
    local TELEMT_SOCKS5_USER="$socks_user"
    local TELEMT_SOCKS5_PASS="$socks_pass"

    TELEMT_MODE="$mode"
    if [ "$TELEMT_MODE" = "systemd" ]; then
        TELEMT_CONFIG_FILE="$TELEMT_CONFIG_SYSTEMD"; TELEMT_WORK_DIR="$TELEMT_WORK_DIR_SYSTEMD"
    else
        TELEMT_MODE="docker"
        TELEMT_CONFIG_FILE="$TELEMT_CONFIG_DOCKER"; TELEMT_WORK_DIR="$TELEMT_WORK_DIR_DOCKER"
    fi
    telemt_check_deps

    if [ "$TELEMT_MODE" = "systemd" ]; then
        need_root
        TELEMT_CHOSEN_VERSION="latest"
        telemt_download_binary "$TELEMT_CHOSEN_VERSION"
        id telemt &>/dev/null || useradd -d "$TELEMT_WORK_DIR" -m -r -U telemt
        # `|| true`: see the docker branch's comment below for why this
        # is required (harmless no-op here since the condition is true
        # for systemd, kept for symmetry / in case that ever changes).
        telemt_write_config "$port" "$domain" "${pairs[@]}" || true
        mkdir -p "$TELEMT_TLSFRONT_DIR"
        chown -R telemt:telemt "$TELEMT_CONFIG_DIR" "$TELEMT_WORK_DIR"
        telemt_write_service
        systemctl daemon-reload; systemctl enable telemt; systemctl restart telemt
    else
        # `|| true` REQUIRED (pre-existing behavior of
        # telemt_write_config(), not introduced by this function): its
        # own last statement is `[ "$TELEMT_MODE" = "systemd" ] && chmod
        # ...`, which is FALSE for docker mode, so the function's return
        # code is 1 even though nothing went wrong. Every existing
        # interactive call site tolerates this via an outer `|| true`
        # (menu.sh: `1) telemt_menu_install || true ;;`). This function
        # has no such outer guard — it runs under panel_install()'s
        # `set -euo pipefail` — so without `|| true` here, every
        # docker-mode integrated install would silently abort
        # panel_install() right after writing a perfectly valid config
        # (confirmed by reproduction this session). Not fixing
        # telemt_write_config() itself — shared with the untouched
        # standalone path.
        telemt_write_config "$port" "$domain" "${pairs[@]}" || true
        telemt_write_compose "$port"
        ( cd "$TELEMT_WORK_DIR_DOCKER" && docker compose pull -q && docker compose up -d )
    fi
    # Публичный порт/ufw НЕ трогается — TELEMT_COLOCATE=1 всегда здесь,
    # единственный public ingress для этого порта — Nginx (см.
    # telemt_write_config()/telemt_write_compose() для симметричной
    # логики в интерактивном telemt_menu_install()).
}

telemt_menu_install() {
    header "Установка MTProxy (${TELEMT_MODE})"
    [ "$TELEMT_MODE" = "systemd" ] && need_root
    local port; read -rp "Порт прокси [8443]: " port </dev/tty; port="${port:-8443}"
    ss -tlnp 2>/dev/null | grep -q ":${port} " && { warn "Порт $port занят!"; read -rp "Другой порт: " port </dev/tty; }
    local domain; read -rp "Домен-маскировка [petrovich.ru]: " domain </dev/tty; domain="${domain:-petrovich.ru}"
    echo ""; telemt_ask_users
    telemt_ask_upstream

    if [ "$TELEMT_MODE" = "systemd" ]; then
        telemt_pick_version
        telemt_download_binary "$TELEMT_CHOSEN_VERSION"
        id telemt &>/dev/null || useradd -d "$TELEMT_WORK_DIR" -m -r -U telemt
        telemt_write_config "$port" "$domain" "${TELEMT_USER_PAIRS[@]}"
        mkdir -p "$TELEMT_TLSFRONT_DIR"
        chown -R telemt:telemt "$TELEMT_CONFIG_DIR" "$TELEMT_WORK_DIR"
        telemt_write_service
        systemctl daemon-reload; systemctl enable telemt; systemctl start telemt
        ok "Сервис запущен"
    else
        telemt_write_config "$port" "$domain" "${TELEMT_USER_PAIRS[@]}"
        telemt_write_compose "$port"
        cd "$TELEMT_WORK_DIR_DOCKER"
        docker compose pull -q; docker compose up -d
        ok "Контейнер запущен"
    fi
    if [ "${TELEMT_COLOCATE:-0}" = "1" ]; then
        info "TELEMT_COLOCATE=1: порт $port не публикуется через ufw — единственным public ingress является Nginx"
    else
        command -v ufw &>/dev/null && ufw allow "${port}/tcp" &>/dev/null && ok "ufw: порт $port открыт"
    fi
    sleep 3; header "Ссылки"
    echo -e "${BOLD}IP:${RESET} $(get_public_ip)"
    telemt_fetch_links
    echo ""
    read -rp "  Нажмите Enter для продолжения..." < /dev/tty
}
