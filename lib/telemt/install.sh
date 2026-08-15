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
ip = "0.0.0.0"

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
      - "${port}:${port}/tcp"
      - "127.0.0.1:9091:9091/tcp"
    security_opt: [no-new-privileges:true]
    cap_drop: [ALL]
    cap_add: [NET_BIND_SERVICE]
    read_only: true
    ulimits: {nofile: {soft: 65536, hard: 65536}}
    logging: {driver: json-file, options: {max-size: "10m", max-file: "3"}}
EOF
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
    command -v ufw &>/dev/null && ufw allow "${port}/tcp" &>/dev/null && ok "ufw: порт $port открыт"
    sleep 3; header "Ссылки"
    echo -e "${BOLD}IP:${RESET} $(get_public_ip)"
    telemt_fetch_links
    echo ""
    read -rp "  Нажмите Enter для продолжения..." < /dev/tty
}
