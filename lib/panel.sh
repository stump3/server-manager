# ███████████████████  PANEL SECTION  ██████████████████████████████
# ═══════════════════════════════════════════════════════════════════

PANEL_DIR="/opt/remnawave"
PANEL_NGINX_DIR="/opt/nginx"           # используется только если nginx отдельно
# PANEL_MGMT_SCRIPT объявлен глобально

panel_get_base_domain() {
    echo "$1" | awk -F'.' '{if (NF>2) print $(NF-1)"."$NF; else print $0}'
}

panel_is_wildcard_cert() {
    local domain="$1" cert="/etc/letsencrypt/live/$1/fullchain.pem"
    [ -f "$cert" ] && openssl x509 -noout -text -in "$cert" 2>/dev/null | grep -q "\*\.$domain"
}

panel_cert_exists() {
    local domain="$1" base
    [ -s "/etc/letsencrypt/live/$domain/fullchain.pem" ] && return 0
    base=$(panel_get_base_domain "$domain")
    [ "$base" != "$domain" ] && panel_is_wildcard_cert "$base" && return 0
    return 1
}

panel_issue_cert() {
    local domain="$1" base cert_method="$2"
    base=$(panel_get_base_domain "$domain")

    panel_cert_exists "$domain" && { ok "Сертификат для $domain уже есть"; return 0; }
    info "Выпуск сертификата для $domain..."

    case $cert_method in
        1)
            certbot certonly --dns-cloudflare \
                --dns-cloudflare-credentials ~/.secrets/certbot/cloudflare.ini \
                --dns-cloudflare-propagation-seconds 60 \
                -d "$base" -d "*.$base" \
                --email "${PANEL_CF_EMAIL:-admin@$base}" \
                --agree-tos --non-interactive \
                --key-type ecdsa --elliptic-curve secp384r1 >/dev/null 2>&1 \
                && ok "Сертификат wildcard для $base выпущен" \
                || { warn "Ошибка certbot для $base"; return 1; }
            ;;
        2)
            ufw allow 80/tcp >/dev/null 2>&1
            certbot certonly --standalone -d "$domain" \
                --email "$PANEL_LE_EMAIL" \
                --agree-tos --non-interactive \
                --http-01-port 80 \
                --key-type ecdsa --elliptic-curve secp384r1 >/dev/null 2>&1 \
                && ok "Сертификат для $domain выпущен" \
                || { warn "Ошибка certbot для $domain"; ufw delete allow 80/tcp >/dev/null 2>&1; return 1; }
            ufw delete allow 80/tcp >/dev/null 2>&1
            ;;
        3)
            certbot certonly --authenticator dns-gcore \
                --dns-gcore-credentials ~/.secrets/certbot/gcore.ini \
                --dns-gcore-propagation-seconds 80 \
                -d "$base" -d "*.$base" \
                --email "$PANEL_LE_EMAIL" \
                --agree-tos --non-interactive \
                --key-type ecdsa --elliptic-curve secp384r1 >/dev/null 2>&1 \
                && ok "Сертификат wildcard для $base выпущен" \
                || { warn "Ошибка certbot для $base"; return 1; }
            ;;
    esac
}

panel_get_cert_domain() {
    local domain="$1" cert_method="$2"
    [ "$cert_method" = "1" ] || [ "$cert_method" = "3" ] \
        && panel_get_base_domain "$domain" \
        || echo "$domain"
}

panel_install() {
    STEP_NUM=0; TOTAL_STEPS=5
    step "Установка Remnawave Panel"
    STEP_NUM=1
    check_root

    # ── Сбор данных ──────────────────────────────────────────────
    section "Режим"
    echo "  1) Панель + Нода (Reality selfsteal, всё на одном сервере)"
    echo "  2) Только панель (нода на отдельном сервере)"
    echo ""
    local MODE=""
    while [[ ! "$MODE" =~ ^[12]$ ]]; do
        read -p "  Выбор (1/2): " MODE < /dev/tty
    done

    echo ""
    section "Домены"
    local PANEL_DOMAIN SUB_DOMAIN SELFSTEAL_DOMAIN
    while true; do ask PANEL_DOMAIN "Домен панели (panel.example.com)"; validate_domain "$PANEL_DOMAIN" && break || warn "Неверный формат"; done
    while true; do ask SUB_DOMAIN   "Домен подписок (sub.example.com)";  validate_domain "$SUB_DOMAIN"   && break || warn "Неверный формат"; done
    while true; do ask SELFSTEAL_DOMAIN "Домен selfsteal (node.example.com)"; validate_domain "$SELFSTEAL_DOMAIN" && break || warn "Неверный формат"; done

    if [ "$PANEL_DOMAIN" = "$SUB_DOMAIN" ] || \
       [ "$PANEL_DOMAIN" = "$SELFSTEAL_DOMAIN" ] || \
       [ "$SUB_DOMAIN" = "$SELFSTEAL_DOMAIN" ]; then
        err "Все три домена должны быть уникальными"
    fi

    echo ""
    section "Веб-сервер"
    echo "  1) Nginx   (SSL через certbot — Cloudflare / Let's Encrypt / Gcore)"
    echo "  2) Caddy   (SSL автоматически — встроенный ACME, certbot не нужен)"
    echo ""
    local WEB_SERVER=""
    while [[ ! "$WEB_SERVER" =~ ^[12]$ ]]; do
        read -p "  Выбор (1/2): " WEB_SERVER < /dev/tty
    done

    local CERT_METHOD="" PANEL_CF_EMAIL="" PANEL_CF_KEY="" PANEL_LE_EMAIL="" GCORE_TOKEN=""
    if [ "$WEB_SERVER" = "1" ]; then
        echo ""
        section "SSL сертификаты"
        echo "  1) Cloudflare DNS-01 (wildcard, рекомендуется)"
        echo "  2) ACME HTTP-01 (Let's Encrypt)"
        echo "  3) Gcore DNS-01 (wildcard)"
        while [[ ! "$CERT_METHOD" =~ ^[123]$ ]]; do
            read -p "  Метод (1/2/3): " CERT_METHOD < /dev/tty
        done
        case $CERT_METHOD in
            1) ask PANEL_CF_KEY   "  Cloudflare API Token"
               ask PANEL_CF_EMAIL "  Email Cloudflare" ;;
            2) ask PANEL_LE_EMAIL "  Email для Let's Encrypt" ;;
            3) ask GCORE_TOKEN    "  Gcore API Token"
               ask PANEL_LE_EMAIL "  Email для Let's Encrypt" ;;
        esac
    else
        info "Caddy: SSL будет получен автоматически через ACME при первом запуске"
        [ "$MODE" = "2" ] && info "Для ACME нужны порты 80 и 443 — откроются автоматически"
    fi

    echo ""
    info "Проверка DNS..."
    check_dns "$PANEL_DOMAIN"     || warn "Проверьте DNS для $PANEL_DOMAIN"
    check_dns "$SUB_DOMAIN"       || warn "Проверьте DNS для $SUB_DOMAIN"
    check_dns "$SELFSTEAL_DOMAIN" || warn "Проверьте DNS для $SELFSTEAL_DOMAIN"

    # ── Зависимости ──────────────────────────────────────────────
    STEP_NUM=$(( STEP_NUM + 1 ))
    step "Зависимости"
    [ ! -f /swapfile ] && {
        fallocate -l 2G /swapfile && chmod 600 /swapfile
        mkswap /swapfile && swapon /swapfile
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
        ok "Swap 2G"
    }
    grep -q "net.ipv4.tcp_congestion_control = bbr" /etc/sysctl.conf || {
        echo "net.core.default_qdisc = fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf
        sysctl -p >/dev/null 2>&1
    }
    apt-get update -y -q
    PKGS=(curl wget git nano htop socat jq openssl ca-certificates gnupg \
          lsb-release dnsutils unzip cron)
    if [ "$WEB_SERVER" = "1" ]; then
        PKGS+=(certbot python3-certbot-dns-cloudflare)
        [ "$CERT_METHOD" = "3" ] && PKGS+=(python3-pip)
    fi
    MISSING=(); for p in "${PKGS[@]}"; do dpkg -l "$p" &>/dev/null || MISSING+=("$p"); done
    [ ${#MISSING[@]} -gt 0 ] && apt-get install -y -q "${MISSING[@]}"
    if [ "$WEB_SERVER" = "1" ] && [ "$CERT_METHOD" = "3" ]; then
        certbot plugins 2>/dev/null | grep -q "dns-gcore" || \
            python3 -m pip install --break-system-packages certbot-dns-gcore >/dev/null 2>&1 || true
    fi
    systemctl is-active --quiet cron || systemctl start cron
    systemctl is-enabled --quiet cron || systemctl enable cron
    ok "Системные пакеты"
    ! command -v docker &>/dev/null && {
        curl -fsSL https://get.docker.com | sh >/dev/null 2>&1 # intentional: official Docker installer
        systemctl enable docker >/dev/null 2>&1
        ok "Docker установлен"
    } || ok "Docker: $(docker --version | cut -d' ' -f3 | tr -d ',')"
    ufw allow 22/tcp  comment 'SSH'   >/dev/null 2>&1
    ufw allow 443/tcp comment 'HTTPS' >/dev/null 2>&1
    ufw --force enable >/dev/null 2>&1
    ok "UFW настроен"

    local PC="" SC="" STC=""
    if [ "$WEB_SERVER" = "1" ]; then
        # ── SSL (только Nginx) ──────────────────────────────────────
        STEP_NUM=$(( STEP_NUM + 1 ))
        step "SSL сертификаты"
        case $CERT_METHOD in
            1)
                mkdir -p ~/.secrets/certbot
                if echo "$PANEL_CF_KEY" | grep -qE '[A-Z]'; then
                    cat > ~/.secrets/certbot/cloudflare.ini <<EOF
dns_cloudflare_api_token = $PANEL_CF_KEY
EOF
                else
                    cat > ~/.secrets/certbot/cloudflare.ini <<EOF
dns_cloudflare_email = $PANEL_CF_EMAIL
dns_cloudflare_api_key = $PANEL_CF_KEY
EOF
                fi
                chmod 600 ~/.secrets/certbot/cloudflare.ini ;;
            3)
                mkdir -p ~/.secrets/certbot
                cat > ~/.secrets/certbot/gcore.ini <<EOF
dns_gcore_apitoken = $GCORE_TOKEN
EOF
                chmod 600 ~/.secrets/certbot/gcore.ini ;;
        esac

        declare -A PANEL_CERT_MAP
        local domains_arr=("$PANEL_DOMAIN" "$SUB_DOMAIN" "$SELFSTEAL_DOMAIN")
        if [ "$CERT_METHOD" = "1" ] || [ "$CERT_METHOD" = "3" ]; then
            declare -A UNIQUE_BASES
            for d in "${domains_arr[@]}"; do
                b=$(panel_get_base_domain "$d"); UNIQUE_BASES["$b"]=1
            done
            for base in "${!UNIQUE_BASES[@]}"; do panel_issue_cert "$base" "$CERT_METHOD"; done
        else
            for d in "${domains_arr[@]}"; do panel_issue_cert "$d" "$CERT_METHOD"; done
        fi

        PC=$(panel_get_cert_domain "$PANEL_DOMAIN"     "$CERT_METHOD")
        SC=$(panel_get_cert_domain "$SUB_DOMAIN"       "$CERT_METHOD")
        STC=$(panel_get_cert_domain "$SELFSTEAL_DOMAIN" "$CERT_METHOD")

        # Cron автообновление
        local CRON_CMD
        [ "$CERT_METHOD" = "2" ] \
            && CRON_CMD="ufw allow 80 && /usr/bin/certbot renew --quiet && ufw delete allow 80 && ufw reload" \
            || CRON_CMD="/usr/bin/certbot renew --quiet"
        crontab -u root -l 2>/dev/null | grep -q "certbot renew" || \
            (crontab -u root -l 2>/dev/null; echo "0 5 * * 0 $CRON_CMD") | crontab -u root -

        for cd in "$PC" "$SC" "$STC"; do
            local renewal="/etc/letsencrypt/renewal/$cd.conf"
            [ -f "$renewal" ] || continue
            local hook="renew_hook = sh -c 'cd /opt/remnawave && docker compose down remnawave-nginx && docker compose up -d remnawave-nginx'"
            grep -q "renew_hook" "$renewal" \
                && sed -i "/renew_hook/c\\$hook" "$renewal" \
                || echo "$hook" >> "$renewal"
        done
        ok "Сертификаты и автообновление настроены"
    else
        # Caddy: порт 80 нужен для ACME в MODE=2
        [ "$MODE" = "2" ] && ufw allow 80/tcp comment 'HTTP (Caddy ACME)' >/dev/null 2>&1
        ok "SSL — Caddy получит сертификаты автоматически при первом запуске"
    fi

    # ── Генерация конфигурации ───────────────────────────────────
    STEP_NUM=$(( STEP_NUM + 1 ))
    step "Генерация конфигурации"
    mkdir -p /opt/remnawave && cd /opt/remnawave

    local SUPERADMIN_USER SUPERADMIN_PASS COOKIE_KEY COOKIE_VAL
    local JWT_AUTH JWT_API METRICS_USER METRICS_PASS
    SUPERADMIN_USER=$(gen_user)
    SUPERADMIN_PASS=$(gen_password)
    COOKIE_KEY=$(gen_user)
    COOKIE_VAL=$(gen_user)
    JWT_AUTH=$(gen_hex64)
    JWT_API=$(gen_hex64)
    METRICS_USER=$(gen_user)
    METRICS_PASS=$(gen_user)

    cat > /opt/remnawave/.env << EOF
APP_PORT=3000
METRICS_PORT=3001
API_INSTANCES=1
DATABASE_URL="postgresql://postgres:postgres@remnawave-db:5432/postgres"
REDIS_SOCKET=/var/run/valkey/valkey.sock
JWT_AUTH_SECRET=$JWT_AUTH
JWT_API_TOKENS_SECRET=$JWT_API
JWT_AUTH_LIFETIME=168
FRONT_END_DOMAIN=$PANEL_DOMAIN
SUB_PUBLIC_DOMAIN=$SUB_DOMAIN
SWAGGER_PATH=/docs
SCALAR_PATH=/scalar
IS_DOCS_ENABLED=false
METRICS_USER=$METRICS_USER
METRICS_PASS=$METRICS_PASS
WEBHOOK_ENABLED=false
WEBHOOK_URL=https://your-webhook-url.com/endpoint
WEBHOOK_SECRET_HEADER=$(gen_hex64)
IS_TELEGRAM_NOTIFICATIONS_ENABLED=false
TELEGRAM_BOT_TOKEN=change_me
# TELEGRAM_BOT_PROXY=socks5://user:password@host:port
TELEGRAM_NOTIFY_SERVICE=change_me
# Thread ID указывается через двоеточие в chat_id: "-100123:80"
TELEGRAM_NOTIFY_USERS_CHAT_ID=change_me
TELEGRAM_NOTIFY_NODES_CHAT_ID=change_me
TELEGRAM_NOTIFY_CRM_CHAT_ID=change_me
NOT_CONNECTED_USERS_NOTIFICATIONS_ENABLED=false
NOT_CONNECTED_USERS_NOTIFICATIONS_AFTER_HOURS=[6, 24, 48]
BANDWIDTH_USAGE_NOTIFICATIONS_ENABLED=false
BANDWIDTH_USAGE_NOTIFICATIONS_THRESHOLD=[60, 80]
POSTGRES_USER=postgres
POSTGRES_PASSWORD=postgres
POSTGRES_DB=postgres
EOF

    # Монтирование сертификатов — только для Nginx
    # Монтируем весь /etc/letsencrypt чтобы симлинки из live/ → archive/ работали внутри контейнера
    local CERT_VOLUMES=""
    [ "$WEB_SERVER" = "1" ] && CERT_VOLUMES="      - /etc/letsencrypt:/etc/letsencrypt:ro
"

    # docker-compose
    if [ "$WEB_SERVER" = "1" ] && [ "$MODE" = "1" ]; then
        cat > /opt/remnawave/docker-compose.yml << EOFYML
services:
  remnawave-db:
    image: postgres:18.3
    container_name: remnawave-db
    hostname: remnawave-db
    restart: always
    ulimits: {nofile: {soft: 1048576, hard: 1048576}}
    env_file: .env
    environment:
      - POSTGRES_USER=\${POSTGRES_USER}
      - POSTGRES_PASSWORD=\${POSTGRES_PASSWORD}
      - POSTGRES_DB=\${POSTGRES_DB}
      - TZ=UTC
    ports: ['127.0.0.1:6767:5432']
    volumes: [remnawave-db-data:/var/lib/postgresql]
    networks: [remnawave-network]
    healthcheck:
      test: ['CMD-SHELL', 'pg_isready -U \${POSTGRES_USER} -d \${POSTGRES_DB}']
      interval: 3s
      timeout: 10s
      retries: 3
    logging: {driver: json-file, options: {max-size: 100m, max-file: '5'}}

  remnawave:
    image: remnawave/backend:2
    container_name: remnawave
    hostname: remnawave
    restart: always
    ulimits: {nofile: {soft: 1048576, hard: 1048576}}
    env_file: .env
    ports:
      - '127.0.0.1:3000:\${APP_PORT:-3000}'
      - '127.0.0.1:3001:\${METRICS_PORT:-3001}'
    volumes:
      - valkey-socket:/var/run/valkey
    networks: [remnawave-network]
    healthcheck:
      test: ['CMD-SHELL', 'curl -f http://localhost:\${METRICS_PORT:-3001}/health']
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s
    depends_on:
      remnawave-db: {condition: service_healthy}
      remnawave-redis: {condition: service_healthy}
    logging: {driver: json-file, options: {max-size: 100m, max-file: '5'}}

  remnawave-redis:
    image: valkey/valkey:9.0.3-alpine
    container_name: remnawave-redis
    hostname: remnawave-redis
    restart: always
    ulimits: {nofile: {soft: 1048576, hard: 1048576}}
    volumes:
      - valkey-socket:/var/run/valkey
    networks: [remnawave-network]
    command: >
      valkey-server --save "" --appendonly no
      --maxmemory-policy noeviction --loglevel warning
      --unixsocket /var/run/valkey/valkey.sock
      --unixsocketperm 777
    healthcheck:
      test: ['CMD', 'valkey-cli', '-s', '/var/run/valkey/valkey.sock', 'ping']
      interval: 3s
      timeout: 10s
      retries: 3
    logging: {driver: json-file, options: {max-size: 100m, max-file: '5'}}

  remnawave-nginx:
    image: nginx:1.28
    container_name: remnawave-nginx
    hostname: remnawave-nginx
    network_mode: host
    restart: always
    ulimits: {nofile: {soft: 1048576, hard: 1048576}}
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - /dev/shm:/dev/shm:rw
      - /var/www/html:/var/www/html:ro
${CERT_VOLUMES}    command: sh -c 'rm -f /dev/shm/nginx.sock && exec nginx -g "daemon off;"'
    depends_on: [remnawave, remnawave-subscription-page]
    logging: {driver: json-file, options: {max-size: 100m, max-file: '5'}}

  remnawave-subscription-page:
    image: remnawave/subscription-page:latest
    container_name: remnawave-subscription-page
    hostname: remnawave-subscription-page
    restart: always
    ulimits: {nofile: {soft: 1048576, hard: 1048576}}
    depends_on:
      remnawave: {condition: service_healthy}
    environment:
      - REMNAWAVE_PANEL_URL=http://remnawave:3000
      - APP_PORT=3010
      - REMNAWAVE_API_TOKEN=PLACEHOLDER
    ports: ['127.0.0.1:3010:3010']
    networks: [remnawave-network]
    logging: {driver: json-file, options: {max-size: 100m, max-file: '5'}}

  remnanode:
    image: remnawave/node:latest
    container_name: remnanode
    hostname: remnanode
    restart: always
    ulimits: {nofile: {soft: 1048576, hard: 1048576}}
    cap_add:
      - NET_ADMIN
    network_mode: host
    environment:
      - NODE_PORT=2222
      - SECRET_KEY="PUBLIC KEY FROM REMNAWAVE-PANEL"
    volumes: [/dev/shm:/dev/shm:rw]
    logging: {driver: json-file, options: {max-size: 100m, max-file: '5'}}

networks:
  remnawave-network:
    name: remnawave-network
    driver: bridge
    ipam:
      config: [{subnet: 172.30.0.0/16}]
    external: false

volumes:
  remnawave-db-data:
    driver: local
    name: remnawave-db-data
  valkey-socket:
    name: valkey-socket
EOFYML
    elif [ "$WEB_SERVER" = "1" ] && [ "$MODE" = "2" ]; then
        # ── Nginx, только панель ──────────────────────────────────
        cat > /opt/remnawave/docker-compose.yml << EOFYML
services:
  remnawave-db:
    image: postgres:18.3
    container_name: remnawave-db
    hostname: remnawave-db
    restart: always
    ulimits: {nofile: {soft: 1048576, hard: 1048576}}
    env_file: .env
    environment:
      - POSTGRES_USER=\${POSTGRES_USER}
      - POSTGRES_PASSWORD=\${POSTGRES_PASSWORD}
      - POSTGRES_DB=\${POSTGRES_DB}
      - TZ=UTC
    ports: ['127.0.0.1:6767:5432']
    volumes: [remnawave-db-data:/var/lib/postgresql]
    networks: [remnawave-network]
    healthcheck:
      test: ['CMD-SHELL', 'pg_isready -U \${POSTGRES_USER} -d \${POSTGRES_DB}']
      interval: 3s
      timeout: 10s
      retries: 3
    logging: {driver: json-file, options: {max-size: 100m, max-file: '5'}}

  remnawave:
    image: remnawave/backend:2
    container_name: remnawave
    hostname: remnawave
    restart: always
    ulimits: {nofile: {soft: 1048576, hard: 1048576}}
    env_file: .env
    ports:
      - '127.0.0.1:3000:\${APP_PORT:-3000}'
      - '127.0.0.1:3001:\${METRICS_PORT:-3001}'
    volumes:
      - valkey-socket:/var/run/valkey
    networks: [remnawave-network]
    healthcheck:
      test: ['CMD-SHELL', 'curl -f http://localhost:\${METRICS_PORT:-3001}/health']
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s
    depends_on:
      remnawave-db: {condition: service_healthy}
      remnawave-redis: {condition: service_healthy}
    logging: {driver: json-file, options: {max-size: 100m, max-file: '5'}}

  remnawave-redis:
    image: valkey/valkey:9.0.3-alpine
    container_name: remnawave-redis
    hostname: remnawave-redis
    restart: always
    ulimits: {nofile: {soft: 1048576, hard: 1048576}}
    volumes:
      - valkey-socket:/var/run/valkey
    networks: [remnawave-network]
    command: >
      valkey-server --save "" --appendonly no
      --maxmemory-policy noeviction --loglevel warning
      --unixsocket /var/run/valkey/valkey.sock
      --unixsocketperm 777
    healthcheck:
      test: ['CMD', 'valkey-cli', '-s', '/var/run/valkey/valkey.sock', 'ping']
      interval: 3s
      timeout: 10s
      retries: 3
    logging: {driver: json-file, options: {max-size: 100m, max-file: '5'}}

  remnawave-nginx:
    image: nginx:1.28
    container_name: remnawave-nginx
    hostname: remnawave-nginx
    network_mode: host
    restart: always
    ulimits: {nofile: {soft: 1048576, hard: 1048576}}
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
${CERT_VOLUMES}    depends_on: [remnawave, remnawave-subscription-page]
    logging: {driver: json-file, options: {max-size: 100m, max-file: '5'}}

  remnawave-subscription-page:
    image: remnawave/subscription-page:latest
    container_name: remnawave-subscription-page
    hostname: remnawave-subscription-page
    restart: always
    ulimits: {nofile: {soft: 1048576, hard: 1048576}}
    depends_on:
      remnawave: {condition: service_healthy}
    environment:
      - REMNAWAVE_PANEL_URL=http://remnawave:3000
      - APP_PORT=3010
      - REMNAWAVE_API_TOKEN=PLACEHOLDER
    ports: ['127.0.0.1:3010:3010']
    networks: [remnawave-network]
    logging: {driver: json-file, options: {max-size: 100m, max-file: '5'}}

networks:
  remnawave-network:
    name: remnawave-network
    driver: bridge
    external: false

volumes:
  remnawave-db-data:
    driver: local
    name: remnawave-db-data
  valkey-socket:
    name: valkey-socket
EOFYML
    elif [ "$WEB_SERVER" = "2" ] && [ "$MODE" = "1" ]; then
        # ── Caddy, панель + нода (selfsteal) ─────────────────────
        cat > /opt/remnawave/docker-compose.yml << EOFYML
services:
  remnawave-db:
    image: postgres:18.3
    container_name: remnawave-db
    hostname: remnawave-db
    restart: always
    ulimits: {nofile: {soft: 1048576, hard: 1048576}}
    env_file: .env
    environment:
      - POSTGRES_USER=\${POSTGRES_USER}
      - POSTGRES_PASSWORD=\${POSTGRES_PASSWORD}
      - POSTGRES_DB=\${POSTGRES_DB}
      - TZ=UTC
    ports: ['127.0.0.1:6767:5432']
    volumes: [remnawave-db-data:/var/lib/postgresql]
    networks: [remnawave-network]
    healthcheck:
      test: ['CMD-SHELL', 'pg_isready -U \${POSTGRES_USER} -d \${POSTGRES_DB}']
      interval: 3s
      timeout: 10s
      retries: 3
    logging: {driver: json-file, options: {max-size: 100m, max-file: '5'}}

  remnawave:
    image: remnawave/backend:2
    container_name: remnawave
    hostname: remnawave
    restart: always
    ulimits: {nofile: {soft: 1048576, hard: 1048576}}
    env_file: .env
    ports:
      - '127.0.0.1:3000:\${APP_PORT:-3000}'
      - '127.0.0.1:3001:\${METRICS_PORT:-3001}'
    volumes:
      - valkey-socket:/var/run/valkey
    networks: [remnawave-network]
    healthcheck:
      test: ['CMD-SHELL', 'curl -f http://localhost:\${METRICS_PORT:-3001}/health']
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s
    depends_on:
      remnawave-db: {condition: service_healthy}
      remnawave-redis: {condition: service_healthy}
    logging: {driver: json-file, options: {max-size: 100m, max-file: '5'}}

  remnawave-redis:
    image: valkey/valkey:9.0.3-alpine
    container_name: remnawave-redis
    hostname: remnawave-redis
    restart: always
    ulimits: {nofile: {soft: 1048576, hard: 1048576}}
    volumes:
      - valkey-socket:/var/run/valkey
    networks: [remnawave-network]
    command: >
      valkey-server --save "" --appendonly no
      --maxmemory-policy noeviction --loglevel warning
      --unixsocket /var/run/valkey/valkey.sock
      --unixsocketperm 777
    healthcheck:
      test: ['CMD', 'valkey-cli', '-s', '/var/run/valkey/valkey.sock', 'ping']
      interval: 3s
      timeout: 10s
      retries: 3
    logging: {driver: json-file, options: {max-size: 100m, max-file: '5'}}

  remnawave-caddy:
    image: caddy:2.11.2
    container_name: remnawave-caddy
    hostname: remnawave-caddy
    network_mode: host
    restart: always
    ulimits: {nofile: {soft: 1048576, hard: 1048576}}
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile
      - /var/www/html:/var/www/html:ro
      - /dev/shm:/dev/shm:rw
      - caddy_data:/data
    command: sh -c 'rm -f /dev/shm/nginx.sock && caddy run --config /etc/caddy/Caddyfile --adapter caddyfile'
    environment:
      - PANEL_DOMAIN=${PANEL_DOMAIN}
      - SUB_DOMAIN=${SUB_DOMAIN}
      - SELF_STEAL_DOMAIN=${SELFSTEAL_DOMAIN}
      - BACKEND_URL=127.0.0.1:3000
      - SUB_BACKEND_URL=127.0.0.1:3010
    healthcheck:
      test: ["CMD", "test", "-S", "/dev/shm/nginx.sock"]
      interval: 2s
      timeout: 5s
      retries: 15
      start_period: 5s
    depends_on: [remnawave, remnawave-subscription-page]
    logging: {driver: json-file, options: {max-size: 100m, max-file: '5'}}

  remnawave-subscription-page:
    image: remnawave/subscription-page:latest
    container_name: remnawave-subscription-page
    hostname: remnawave-subscription-page
    restart: always
    ulimits: {nofile: {soft: 1048576, hard: 1048576}}
    depends_on:
      remnawave: {condition: service_healthy}
    environment:
      - REMNAWAVE_PANEL_URL=http://remnawave:3000
      - APP_PORT=3010
      - REMNAWAVE_API_TOKEN=PLACEHOLDER
    ports: ['127.0.0.1:3010:3010']
    networks: [remnawave-network]
    logging: {driver: json-file, options: {max-size: 100m, max-file: '5'}}

  remnanode:
    image: remnawave/node:latest
    container_name: remnanode
    hostname: remnanode
    restart: always
    ulimits: {nofile: {soft: 1048576, hard: 1048576}}
    cap_add:
      - NET_ADMIN
    network_mode: host
    environment:
      - NODE_PORT=2222
      - SECRET_KEY="PUBLIC KEY FROM REMNAWAVE-PANEL"
    volumes: [/dev/shm:/dev/shm:rw]
    logging: {driver: json-file, options: {max-size: 100m, max-file: '5'}}

networks:
  remnawave-network:
    name: remnawave-network
    driver: bridge
    ipam:
      config: [{subnet: 172.30.0.0/16}]
    external: false

volumes:
  remnawave-db-data:
    driver: local
    name: remnawave-db-data
  valkey-socket:
    name: valkey-socket
  caddy_data:
    name: caddy_data
EOFYML
    else
        # ── Caddy, только панель ──────────────────────────────────
        cat > /opt/remnawave/docker-compose.yml << EOFYML
services:
  remnawave-db:
    image: postgres:18.3
    container_name: remnawave-db
    hostname: remnawave-db
    restart: always
    ulimits: {nofile: {soft: 1048576, hard: 1048576}}
    env_file: .env
    environment:
      - POSTGRES_USER=\${POSTGRES_USER}
      - POSTGRES_PASSWORD=\${POSTGRES_PASSWORD}
      - POSTGRES_DB=\${POSTGRES_DB}
      - TZ=UTC
    ports: ['127.0.0.1:6767:5432']
    volumes: [remnawave-db-data:/var/lib/postgresql]
    networks: [remnawave-network]
    healthcheck:
      test: ['CMD-SHELL', 'pg_isready -U \${POSTGRES_USER} -d \${POSTGRES_DB}']
      interval: 3s
      timeout: 10s
      retries: 3
    logging: {driver: json-file, options: {max-size: 100m, max-file: '5'}}

  remnawave:
    image: remnawave/backend:2
    container_name: remnawave
    hostname: remnawave
    restart: always
    ulimits: {nofile: {soft: 1048576, hard: 1048576}}
    env_file: .env
    ports:
      - '127.0.0.1:3000:\${APP_PORT:-3000}'
      - '127.0.0.1:3001:\${METRICS_PORT:-3001}'
    volumes:
      - valkey-socket:/var/run/valkey
    networks: [remnawave-network]
    healthcheck:
      test: ['CMD-SHELL', 'curl -f http://localhost:\${METRICS_PORT:-3001}/health']
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s
    depends_on:
      remnawave-db: {condition: service_healthy}
      remnawave-redis: {condition: service_healthy}
    logging: {driver: json-file, options: {max-size: 100m, max-file: '5'}}

  remnawave-redis:
    image: valkey/valkey:9.0.3-alpine
    container_name: remnawave-redis
    hostname: remnawave-redis
    restart: always
    ulimits: {nofile: {soft: 1048576, hard: 1048576}}
    volumes:
      - valkey-socket:/var/run/valkey
    networks: [remnawave-network]
    command: >
      valkey-server --save "" --appendonly no
      --maxmemory-policy noeviction --loglevel warning
      --unixsocket /var/run/valkey/valkey.sock
      --unixsocketperm 777
    healthcheck:
      test: ['CMD', 'valkey-cli', '-s', '/var/run/valkey/valkey.sock', 'ping']
      interval: 3s
      timeout: 10s
      retries: 3
    logging: {driver: json-file, options: {max-size: 100m, max-file: '5'}}

  remnawave-caddy:
    image: caddy:2.11.2
    container_name: remnawave-caddy
    hostname: remnawave-caddy
    network_mode: host
    restart: always
    ulimits: {nofile: {soft: 1048576, hard: 1048576}}
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile
      - /var/www/html:/var/www/html:ro
      - caddy_data:/data
    command: caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
    environment:
      - PANEL_DOMAIN=${PANEL_DOMAIN}
      - SUB_DOMAIN=${SUB_DOMAIN}
      - SELF_STEAL_DOMAIN=${SELFSTEAL_DOMAIN}
      - BACKEND_URL=127.0.0.1:3000
      - SUB_BACKEND_URL=127.0.0.1:3010
    depends_on: [remnawave, remnawave-subscription-page]
    logging: {driver: json-file, options: {max-size: 100m, max-file: '5'}}

  remnawave-subscription-page:
    image: remnawave/subscription-page:latest
    container_name: remnawave-subscription-page
    hostname: remnawave-subscription-page
    restart: always
    ulimits: {nofile: {soft: 1048576, hard: 1048576}}
    depends_on:
      remnawave: {condition: service_healthy}
    environment:
      - REMNAWAVE_PANEL_URL=http://remnawave:3000
      - APP_PORT=3010
      - REMNAWAVE_API_TOKEN=PLACEHOLDER
    ports: ['127.0.0.1:3010:3010']
    networks: [remnawave-network]
    logging: {driver: json-file, options: {max-size: 100m, max-file: '5'}}

networks:
  remnawave-network:
    name: remnawave-network
    driver: bridge
    external: false

volumes:
  remnawave-db-data:
    driver: local
    name: remnawave-db-data
  valkey-socket:
    name: valkey-socket
  caddy_data:
    name: caddy_data
EOFYML
    fi

    # Конфиг веб-сервера
    if [ "$WEB_SERVER" = "1" ]; then
        # ── nginx.conf ────────────────────────────────────────────
        local LISTEN_DIR REAL_IP_P REAL_IP_S
        if [ "$MODE" = "1" ]; then
            LISTEN_DIR="listen unix:/dev/shm/nginx.sock ssl proxy_protocol;"
            REAL_IP_P="\$proxy_protocol_addr"
            REAL_IP_S="\$proxy_protocol_addr"
        else
            LISTEN_DIR="listen 443 ssl;"
            REAL_IP_P="\$remote_addr"
            REAL_IP_S="\$remote_addr"
        fi

    cat > /opt/remnawave/nginx.conf << NGINX_CONF_EOF
server_names_hash_bucket_size 64;

upstream remnawave { server 127.0.0.1:3000; }
upstream remnawave-sub { server 127.0.0.1:3010; }

map \$http_upgrade \$connection_upgrade {
    default upgrade; "" close;
}

# Cookie-защита панели: доступ только с ?${COOKIE_KEY}=${COOKIE_VAL}
map \$http_cookie \$auth_cookie {
    default 0; "~*${COOKIE_KEY}=${COOKIE_VAL}" 1;
}
map \$arg_${COOKIE_KEY} \$auth_query {
    default 0; "${COOKIE_VAL}" 1;
}
map "\$auth_cookie\$auth_query" \$authorized {
    "~1" 1; default 0;
}
map \$arg_${COOKIE_KEY} \$set_cookie_header {
    "${COOKIE_VAL}" "${COOKIE_KEY}=${COOKIE_VAL}; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=31536000";
    default "";
}

ssl_protocols TLSv1.2 TLSv1.3;
ssl_ecdh_curve X25519:prime256v1:secp384r1;
ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
ssl_prefer_server_ciphers on;
ssl_session_timeout 1d;
ssl_session_cache shared:MozSSL:10m;
ssl_session_tickets off;

server {
    server_name ${PANEL_DOMAIN};
    ${LISTEN_DIR}
    http2 on;
    ssl_certificate "/etc/letsencrypt/live/${PC}/fullchain.pem";
    ssl_certificate_key "/etc/letsencrypt/live/${PC}/privkey.pem";
    ssl_trusted_certificate "/etc/letsencrypt/live/${PC}/fullchain.pem";
    add_header Set-Cookie \$set_cookie_header;

    location ^~ /oauth2/ {
        if (\$http_referer !~ "^https://oauth\\.telegram\\.org/") {
            return 444;
        }
        proxy_http_version 1.1;
        proxy_pass http://remnawave;
        proxy_set_header Host \$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header X-Real-IP ${REAL_IP_P};
        proxy_set_header X-Forwarded-For ${REAL_IP_P};
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port \$server_port;
        proxy_send_timeout 60s; proxy_read_timeout 60s;
    }
    location / {
        error_page 418 = @unauthorized;
        recursive_error_pages on;
        if (\$authorized = 0) { return 418; }
        proxy_http_version 1.1;
        proxy_pass http://remnawave;
        proxy_set_header Host \$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header X-Real-IP ${REAL_IP_P};
        proxy_set_header X-Forwarded-For ${REAL_IP_P};
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port \$server_port;
        proxy_send_timeout 60s; proxy_read_timeout 60s;
    }
    location @unauthorized {
        root /var/www/html; index index.html; try_files /index.html =444;
    }
}

server {
    server_name ${SUB_DOMAIN};
    ${LISTEN_DIR}
    http2 on;
    ssl_certificate "/etc/letsencrypt/live/${SC}/fullchain.pem";
    ssl_certificate_key "/etc/letsencrypt/live/${SC}/privkey.pem";
    ssl_trusted_certificate "/etc/letsencrypt/live/${SC}/fullchain.pem";

    location / {
        proxy_http_version 1.1;
        proxy_pass http://remnawave-sub;
        proxy_set_header Host \$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header X-Real-IP ${REAL_IP_S};
        proxy_set_header X-Forwarded-For ${REAL_IP_S};
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port \$server_port;
        proxy_send_timeout 60s; proxy_read_timeout 60s;
        proxy_intercept_errors on;
        error_page 400 404 500 502 @sub_error;
    }
    location @sub_error { return 444; }
}

server {
    server_name ${SELFSTEAL_DOMAIN};
    ${LISTEN_DIR}
    http2 on;
    ssl_certificate "/etc/letsencrypt/live/${STC}/fullchain.pem";
    ssl_certificate_key "/etc/letsencrypt/live/${STC}/privkey.pem";
    ssl_trusted_certificate "/etc/letsencrypt/live/${STC}/fullchain.pem";
    root /var/www/html; index index.html;
    add_header X-Robots-Tag "noindex, nofollow, noarchive, nosnippet, noimageindex" always;
}

server {
    ${LISTEN_DIR}
    server_name _;
    ssl_certificate "/etc/letsencrypt/live/${PC}/fullchain.pem";
    ssl_certificate_key "/etc/letsencrypt/live/${PC}/privkey.pem";
    ssl_reject_handshake on;
    return 444;
}
NGINX_CONF_EOF
    else
        # ── Caddyfile ─────────────────────────────────────────────
        if [ "$MODE" = "1" ]; then
            # MODE=1: Caddy слушает unix-сокет (Xray→Caddy, selfsteal)
            cat > /opt/remnawave/Caddyfile << CADDYEOF
{
    admin off
    servers {
        listener_wrappers {
            proxy_protocol
            tls
        }
    }
    auto_https disable_redirects
}

https://{\$PANEL_DOMAIN} {
    bind unix//dev/shm/nginx.sock

    @has_token_param {
        query ${COOKIE_KEY}=${COOKIE_VAL}
    }
    handle @has_token_param {
        header +Set-Cookie "${COOKIE_KEY}=${COOKIE_VAL}; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=31536000"
    }

    @unauthorized {
        not path /oauth2/*
        not header Cookie *${COOKIE_KEY}=${COOKIE_VAL}*
        not query ${COOKIE_KEY}=${COOKIE_VAL}
    }
    handle @unauthorized {
        root * /var/www/html
        try_files {path} /index.html
        file_server
    }

    @oauth2_bad {
        path /oauth2/*
        not header Referer https://oauth.telegram.org/*
    }
    handle @oauth2_bad {
        abort
    }

    @oauth2 {
        path /oauth2/*
        header Referer https://oauth.telegram.org/*
    }
    handle @oauth2 {
        reverse_proxy {\$BACKEND_URL} {
            header_up Host {host}
        }
    }

    reverse_proxy {\$BACKEND_URL} {
        header_up X-Real-IP {http.request.header.X-Forwarded-For}
        header_up Host {host}
    }
}

https://{\$SUB_DOMAIN} {
    bind unix//dev/shm/nginx.sock
    reverse_proxy {\$SUB_BACKEND_URL} {
        header_up X-Real-IP {http.request.header.X-Forwarded-For}
        header_up Host {host}
    }
}

https://{\$SELF_STEAL_DOMAIN} {
    bind unix//dev/shm/nginx.sock
    root * /var/www/html
    try_files {path} /index.html
    file_server
}
CADDYEOF
        else
            # MODE=2: Caddy слушает напрямую, ACME автоматически
            cat > /opt/remnawave/Caddyfile << CADDYEOF
{
    admin off
}

http://{\$PANEL_DOMAIN} {
    bind 0.0.0.0
    redir https://{\$PANEL_DOMAIN}{uri} permanent
}

https://{\$PANEL_DOMAIN} {
    @has_token_param {
        query ${COOKIE_KEY}=${COOKIE_VAL}
    }
    handle @has_token_param {
        header +Set-Cookie "${COOKIE_KEY}=${COOKIE_VAL}; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=31536000"
    }

    @unauthorized {
        not path /oauth2/*
        not header Cookie *${COOKIE_KEY}=${COOKIE_VAL}*
        not query ${COOKIE_KEY}=${COOKIE_VAL}
    }
    handle @unauthorized {
        abort
    }

    @oauth2_bad {
        path /oauth2/*
        not header Referer https://oauth.telegram.org/*
    }
    handle @oauth2_bad {
        abort
    }

    @oauth2 {
        path /oauth2/*
        header Referer https://oauth.telegram.org/*
    }
    handle @oauth2 {
        reverse_proxy {\$BACKEND_URL} {
            header_up Host {host}
        }
    }

    reverse_proxy {\$BACKEND_URL} {
        header_up X-Real-IP {remote_host}
        header_up Host {host}
    }
}

http://{\$SUB_DOMAIN} {
    bind 0.0.0.0
    redir https://{\$SUB_DOMAIN}{uri} permanent
}

https://{\$SUB_DOMAIN} {
    reverse_proxy {\$SUB_BACKEND_URL} {
        header_up X-Real-IP {remote_host}
        header_up Host {host}
    }
}

https://{\$SELF_STEAL_DOMAIN} {
    root * /var/www/html
    try_files {path} /index.html
    file_server
    header X-Robots-Tag "noindex, nofollow, noarchive, nosnippet"
}

:80 {
    bind 0.0.0.0
    respond 204
}
CADDYEOF
        fi
    fi  # end WEB_SERVER branch

    ok "Конфигурация сгенерирована"

    # Маскировочный сайт
    mkdir -p /var/www/html
    if curl -s --max-time 10 -L \
            "https://github.com/eGamesAPI/simple-web-templates/archive/refs/heads/main.zip" \
            -o /tmp/tmpl.zip 2>/dev/null && \
       unzip -q /tmp/tmpl.zip -d /tmp/tmpl 2>/dev/null; then
        TDIRS=(/tmp/tmpl/simple-web-templates-main/*/)
        if [ ${#TDIRS[@]} -gt 0 ]; then
            local _ridx; _ridx=$(python3 -c "import random,sys; print(random.randrange(int(sys.argv[1])))" "${#TDIRS[@]}" 2>/dev/null || echo "0")
            cp -a "${TDIRS[$_ridx]}/." /var/www/html/ 2>/dev/null || true
        fi
        rm -rf /tmp/tmpl /tmp/tmpl.zip
        ok "Маскировочный сайт установлен"
    else
        cat > /var/www/html/index.html <<'HTMLEOF'
<!DOCTYPE html><html><head><meta charset="UTF-8"><title>Welcome</title>
<style>body{font-family:sans-serif;text-align:center;padding:100px;background:#f5f5f5}h1{color:#333}</style>
</head><body><h1>Welcome</h1><p>Service is running.</p></body></html>
HTMLEOF
        ok "Базовая страница /var/www/html"
    fi

    # ── Пауза — просмотр конфигурации ───────────────────────────
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}  📝 Конфигурационные файлы сгенерированы${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${WHITE}  Перед запуском можно открыть новый SSH-сеанс и проверить${NC}"
    echo -e "${WHITE}  или изменить любой из файлов через nano:${NC}"
    echo ""
    echo -e "  ${CYAN}nano /opt/remnawave/.env${NC}             ${GRAY}# секреты, JWT, домены${NC}"
    echo -e "  ${CYAN}nano /opt/remnawave/docker-compose.yml${NC}  ${GRAY}# образы, порты${NC}"
    if [ "$WEB_SERVER" = "1" ]; then
        echo -e "  ${CYAN}nano /opt/remnawave/nginx.conf${NC}       ${GRAY}# SSL, cookie-защита${NC}"
    else
        echo -e "  ${CYAN}nano /opt/remnawave/Caddyfile${NC}        ${GRAY}# маршруты, cookie-защита${NC}"
    fi
    echo ""
    echo -e "  ${GRAY}Ctrl+O → Enter — сохранить | Ctrl+X — выйти из nano${NC}"
    echo ""
    read -p "  Нажмите Enter когда готовы к запуску..." < /dev/tty
    ok "Продолжаем установку"

    # ── Запуск и автоконфигурация ────────────────────────────────
    STEP_NUM=$(( STEP_NUM + 1 ))
    step "Запуск и автоконфигурация"
    cd /opt/remnawave
    [ "$MODE" = "1" ] && ufw allow from 172.30.0.0/16 to any port 2222 proto tcp >/dev/null 2>&1

    docker compose up -d >/dev/null 2>&1 & spinner $! "Запуск контейнеров..."
    ok "Контейнеры запущены"

    info "Ожидание готовности панели (до 2 минут)..."
    sleep 20
    local ATTEMPTS=0
    until curl -s -f --max-time 30 "http://127.0.0.1:3000/api/auth/status" \
            -H 'X-Forwarded-For: 127.0.0.1' -H 'X-Forwarded-Proto: https' >/dev/null 2>&1; do
        ATTEMPTS=$((ATTEMPTS+1))
        [ "$ATTEMPTS" -ge 5 ] && err "Панель не стартовала. Проверьте: cd /opt/remnawave && docker compose logs remnawave"
        info "Попытка $ATTEMPTS/5, ждём 60с..."; sleep 60
    done
    ok "Панель готова"

    local API="127.0.0.1:3000"
    local REG
    REG=$(panel_api "POST" "http://$API/api/auth/register" "" \
        "{\"username\":\"$SUPERADMIN_USER\",\"password\":\"$SUPERADMIN_PASS\"}")
    local TOKEN
    TOKEN=$(echo "$REG" | jq -r '.response.accessToken // empty' 2>/dev/null)
    [ -z "$TOKEN" ] && err "Ошибка регистрации: $REG"
    ok "Суперадмин: $SUPERADMIN_USER"

    local KEYS_R PRIV_KEY
    KEYS_R=$(panel_api "GET" "http://$API/api/system/tools/x25519/generate" "$TOKEN")
    PRIV_KEY=$(echo "$KEYS_R" | jq -r '.response.keypairs[0].privateKey // empty' 2>/dev/null)
    [ -z "$PRIV_KEY" ] && err "Ошибка генерации ключей"

    local PUB_R PUB_KEY
    PUB_R=$(panel_api "GET" "http://$API/api/keygen" "$TOKEN")
    PUB_KEY=$(echo "$PUB_R" | jq -r '.response.pubKey // empty' 2>/dev/null)
    [ -z "$PUB_KEY" ] && err "Ошибка получения публичного ключа"
    sed -i "s|SECRET_KEY=\"PUBLIC KEY FROM REMNAWAVE-PANEL\"|SECRET_KEY=\"$PUB_KEY\"|g" \
        /opt/remnawave/docker-compose.yml
    ok "Ключи Reality готовы"

    local OLD_P
    OLD_P=$(panel_api "GET" "http://$API/api/config-profiles" "$TOKEN" | \
        jq -r '.response.configProfiles[] | select(.name=="Default-Profile") | .uuid' 2>/dev/null || echo "")
    [ -n "$OLD_P" ] && panel_api "DELETE" "http://$API/api/config-profiles/$OLD_P" "$TOKEN" >/dev/null

    local SHORT_ID DEST_VAL
    SHORT_ID=$(openssl rand -hex 8)
    [ "$MODE" = "1" ] && DEST_VAL='/dev/shm/nginx.sock' || DEST_VAL="${SELFSTEAL_DOMAIN}:443"

    local PROFILE_R
    PROFILE_R=$(panel_api "POST" "http://$API/api/config-profiles" "$TOKEN" "$(jq -n \
        --arg name "StealConfig" --arg domain "$SELFSTEAL_DOMAIN" \
        --arg pk "$PRIV_KEY"     --arg sid "$SHORT_ID" --arg dest "$DEST_VAL" \
        '{name:$name,config:{log:{loglevel:"warning"},dns:{queryStrategy:"UseIPv4",servers:[{address:"https://dns.google/dns-query",skipFallback:false}]},inbounds:[{tag:"Steal",port:443,protocol:"vless",settings:{clients:[],decryption:"none"},sniffing:{enabled:true,destOverride:["http","tls","quic"]},streamSettings:{network:"tcp",security:"reality",realitySettings:{show:false,xver:1,dest:$dest,spiderX:"",shortIds:[$sid],privateKey:$pk,serverNames:[$domain]}}}],outbounds:[{tag:"DIRECT",protocol:"freedom"},{tag:"BLOCK",protocol:"blackhole"}],routing:{rules:[{ip:["geoip:private"],type:"field",outboundTag:"BLOCK"},{type:"field",protocol:["bittorrent"],outboundTag:"BLOCK"}]}}}' 2>/dev/null)")

    local CFG_UUID IBD_UUID
    CFG_UUID=$(echo "$PROFILE_R" | jq -r '.response.uuid // empty' 2>/dev/null)
    IBD_UUID=$(echo "$PROFILE_R" | jq -r '.response.inbounds[0].uuid // empty' 2>/dev/null)
    [ -z "$CFG_UUID" ] && err "Ошибка создания конфиг-профиля"
    ok "Конфиг-профиль создан"

    local NODE_ADDR
    [ "$MODE" = "2" ] && NODE_ADDR="$SELFSTEAL_DOMAIN" || NODE_ADDR="172.30.0.1"
    panel_api "POST" "http://$API/api/nodes" "$TOKEN" "$(jq -n \
        --arg na "$NODE_ADDR" --arg cu "$CFG_UUID" --arg iu "$IBD_UUID" \
        '{name:"Steal",address:$na,port:2222,configProfile:{activeConfigProfileUuid:$cu,activeInbounds:[$iu]},isTrafficTrackingActive:false,trafficLimitBytes:0,notifyPercent:0,trafficResetDay:31,excludedInbounds:[],countryCode:"XX",consumptionMultiplier:1.0}' 2>/dev/null)" >/dev/null 2>&1 \
        && ok "Нода создана" || warn "Ошибка создания ноды"

    panel_api "POST" "http://$API/api/hosts" "$TOKEN" "$(jq -n \
        --arg cu "$CFG_UUID" --arg iu "$IBD_UUID" --arg addr "$SELFSTEAL_DOMAIN" \
        '{inbound:{configProfileUuid:$cu,configProfileInboundUuid:$iu},remark:"Steal",address:$addr,port:443,path:"",sni:$addr,host:"",alpn:null,fingerprint:"chrome",allowInsecure:false,isDisabled:false,securityLayer:"DEFAULT"}' 2>/dev/null)" >/dev/null 2>&1 \
        && ok "Хост создан" || warn "Ошибка создания хоста"

    local SQUAD_UUIDS
    SQUAD_UUIDS=$(panel_api "GET" "http://$API/api/internal-squads" "$TOKEN" | \
        jq -r '.response.internalSquads[].uuid' 2>/dev/null || echo "")
    for su in $SQUAD_UUIDS; do
        [[ "$su" =~ ^[0-9a-f-]{36}$ ]] || continue
        panel_api "PATCH" "http://$API/api/internal-squads" "$TOKEN" \
            "{\"uuid\":\"$su\",\"inbounds\":[\"$IBD_UUID\"]}" >/dev/null 2>&1 || true
    done
    ok "Squad обновлён"

    local SUB_TOKEN_R SUB_TOKEN
    SUB_TOKEN_R=$(panel_api "POST" "http://$API/api/tokens" "$TOKEN" '{"tokenName":"subscription-page"}')
    SUB_TOKEN=$(echo "$SUB_TOKEN_R" | jq -r '.response.token // empty' 2>/dev/null)
    [ -n "$SUB_TOKEN" ] && {
        sed -i "s|REMNAWAVE_API_TOKEN=PLACEHOLDER|REMNAWAVE_API_TOKEN=$SUB_TOKEN|g" \
            /opt/remnawave/docker-compose.yml
        ok "API-токен для Subscription Page"
    } || warn "Не удалось создать API-токен автоматически"

    docker compose down remnawave-subscription-page >/dev/null 2>&1 & spinner $! "Перезапуск Sub..."
    docker compose up -d remnawave-subscription-page >/dev/null 2>&1 & spinner $! "Запуск Sub..."
    docker compose down >/dev/null 2>&1 & spinner $! "Финальный рестарт..."
    docker compose up -d >/dev/null 2>&1 & spinner $! "Запуск..."
    ok "Стек перезапущен"

    # ── Команда управления ───────────────────────────────────────
    panel_install_mgmt_script "$PANEL_DOMAIN" "$COOKIE_KEY" "$COOKIE_VAL" "$MODE" "$WEB_SERVER"

    # ── Итог ─────────────────────────────────────────────────────
    echo ""
    echo -e "${BOLD}${GREEN}  ✓ Remnawave Panel установлена${NC}"
    echo ""
    echo -e "${BOLD}${WHITE}  Доступ${NC}"
    echo -e "${GRAY}  ──────────────────────────────${NC}"
    echo -e "  ${GRAY}Панель    ${NC}https://${PANEL_DOMAIN}"
    echo -e "  ${GRAY}Подписки  ${NC}https://${SUB_DOMAIN}"
    echo -e "  ${GRAY}Selfsteal ${NC}https://${SELFSTEAL_DOMAIN}"
    echo ""
    echo -e "${BOLD}${WHITE}  Учётные данные${NC}"
    echo -e "${GRAY}  ──────────────────────────────${NC}"
    echo -e "  ${GRAY}Логин   ${NC}${SUPERADMIN_USER}"
    echo -e "  ${GRAY}Пароль  ${NC}${SUPERADMIN_PASS}"
    echo ""
    echo -e "${BOLD}${YELLOW}  ⚠  Сохраните — показывается один раз${NC}"
    echo -e "${GRAY}  ──────────────────────────────${NC}"
    echo -e "  ${CYAN}https://${PANEL_DOMAIN}/auth/login?${COOKIE_KEY}=${COOKIE_VAL}${NC}"
    echo ""
    echo -e "${BOLD}${WHITE}  Управление${NC}"
    echo -e "${GRAY}  ──────────────────────────────${NC}"
    echo -e "  ${GRAY}Команда   ${NC}remnawave_panel  ${GRAY}или${NC}  rp"
    echo ""
    read -rp "  Нажмите Enter чтобы продолжить (данные выше сохраните сейчас)..." < /dev/tty
    echo ""
}

panel_install_mgmt_script() {
    local panel_domain="$1" cookie_key="$2" cookie_val="$3" mode="$4"
    local mgmt="/usr/local/bin/remnawave_panel"
    cat > "$mgmt" << 'MGMTEOF'
#!/bin/bash
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; WHITE='\033[1;37m'; PURPLE='\033[0;35m'; NC='\033[0m'
DIR="/opt/remnawave"
_ok()   { echo -e "${GREEN}✅ $*${NC}"; }
_info() { echo -e "${CYAN}ℹ  $*${NC}"; }
_warn() { echo -e "${YELLOW}⚠  $*${NC}"; }
_spinner() {
    local pid=$1 text="${2:-Подождите...}" spinstr='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' delay=0.1
    while kill -0 "$pid" 2>/dev/null; do
        for((i=0;i<${#spinstr};i++)); do
            printf "\r${YELLOW}[%s] %s${NC}" "${spinstr:$i:1}" "$text">/dev/tty; sleep $delay
        done
    done; printf "\r\033[K">/dev/tty
}
_detect_ws() { grep -q "remnawave-caddy" /opt/remnawave/docker-compose.yml 2>/dev/null && echo "caddy" || echo "nginx"; }
do_status() {
    local ws; ws=$(_detect_ws)
    local ws_svc; [ "$ws" = "caddy" ] && ws_svc="remnawave-caddy" || ws_svc="remnawave-nginx"
    echo -e "${WHITE}📊 Статус:${NC}"
    for c in remnawave remnawave-db remnawave-redis $ws_svc remnawave-subscription-page remnanode; do
        s=$(docker ps --format '{{.Status}}' -f "name=$c" 2>/dev/null | head -1)
        [ -n "$s" ] && echo "$s" | grep -qE "^Up|healthy" \
            && echo -e "  ${GREEN}●${NC} $c — $s" || echo -e "  ${YELLOW}◐${NC} $c — $s" \
            || echo -e "  ${RED}○${NC} $c"
    done
    echo ""
    docker stats --no-stream --format "{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}" 2>/dev/null \
        | grep -E "remnawave|remnanode" | sort \
        | awk -F"\t" '{printf "  %-36s %6s   %s\n", $1, $2, $3}'
}
do_logs() {
    local s="${1:-panel}"; cd "$DIR"
    local ws; ws=$(_detect_ws)
    case $s in
        nginx|caddy) docker logs "remnawave-${ws}" --tail=50 -f ;;
        sub)   docker logs remnawave-subscription-page --tail=50 -f ;;
        node)  docker logs remnanode --tail=50 -f ;;
        *)     docker compose logs --tail=50 -f remnawave ;;
    esac
}
do_restart() {
    local s="${1:-all}"; cd "$DIR"
    local ws; ws=$(_detect_ws)
    local ws_svc="remnawave-${ws}"
    case $s in
        nginx|caddy) docker compose restart "$ws_svc"; _ok "${ws^} перезапущен" ;;
        panel)  docker compose restart remnawave; _ok "Панель перезапущена" ;;
        sub)    docker compose restart remnawave-subscription-page; _ok "Sub перезапущена" ;;
        node)   docker compose restart remnanode; _ok "Нода перезапущена" ;;
        all)
            docker compose down>/dev/null 2>&1 & _spinner $! "Остановка..."
            docker compose up -d>/dev/null 2>&1 & _spinner $! "Запуск..."
            _ok "Всё перезапущено" ;;
        *) echo "Укажите: all|nginx|caddy|panel|sub|node" ;;
    esac
}
do_update() {
    cd "$DIR"
    docker compose pull>/dev/null 2>&1 & _spinner $! "Загрузка..."
    docker compose down>/dev/null 2>&1 & _spinner $! "Остановка..."
    docker compose up -d>/dev/null 2>&1 & _spinner $! "Запуск..."
    docker image prune -f>/dev/null 2>&1; _ok "Обновлено"
}
do_ssl() {
    local ws; ws=$(_detect_ws); cd "$DIR"
    if [ "$ws" = "caddy" ]; then
        _info "Caddy управляет SSL автоматически через ACME"
        docker exec remnawave-caddy caddy reload --config /etc/caddy/Caddyfile 2>/dev/null \
            && _ok "Caddy конфиг перезагружен" \
            || _warn "Не удалось перезагрузить Caddy"
    else
        certbot renew --quiet
        docker compose restart remnawave-nginx
        _ok "SSL обновлён"
    fi
}
do_backup() {
    local ts b ws_cfg
    ts=$(date +%Y%m%d_%H%M%S); b="$DIR/backups"; mkdir -p "$b"; cd "$DIR"
    [ -f "$DIR/Caddyfile" ] && ws_cfg="$DIR/Caddyfile" || ws_cfg="$DIR/nginx.conf"
    docker compose exec -T remnawave-db pg_dump -U postgres postgres>"$b/db_$ts.sql" 2>/dev/null \
        && _ok "БД → $b/db_$ts.sql" || _warn "Ошибка бэкапа БД"
    tar -czf "$b/configs_$ts.tar.gz" "$DIR/.env" "$DIR/docker-compose.yml" "$ws_cfg" 2>/dev/null
    _ok "Конфиги → $b/configs_$ts.tar.gz"
    find "$b" -mtime +7 -delete 2>/dev/null||true
}
do_health() {
    local ws; ws=$(_detect_ws)
    do_status; echo ""
    if [ "$ws" = "nginx" ]; then
        echo -e "${WHITE}🔒 SSL:${NC}"
        for d in /etc/letsencrypt/live/*/; do
            dom=$(basename "$d")
            exp=$(openssl x509 -in "$d/fullchain.pem" -noout -enddate 2>/dev/null|sed 's/notAfter=//')
            [ -n "$exp" ] && echo -e "  ${GREEN}✓${NC} $dom — $exp"
        done; echo ""
        echo -e "${WHITE}Nginx:${NC}"
        docker exec remnawave-nginx nginx -t 2>&1|sed 's/^/  /'||true; echo ""
    else
        echo -e "${WHITE}🔒 Caddy SSL (ACME):${NC}"
        docker exec remnawave-caddy caddy validate --config /etc/caddy/Caddyfile 2>&1|sed 's/^/  /'||true; echo ""
    fi
    echo -e "${WHITE}API:${NC}"
    curl -s --max-time 5 "http://127.0.0.1:3000/api/auth/status" \
        -H 'X-Forwarded-For: 127.0.0.1' -H 'X-Forwarded-Proto: https' 2>/dev/null | \
        jq -e '.response'>/dev/null 2>&1 \
        && echo -e "  ${GREEN}✓${NC} API доступен" || echo -e "  ${RED}✗${NC} API недоступен"
}
do_open_port() {
    local ws; ws=$(_detect_ws)
    if [ "$ws" = "caddy" ]; then
        _warn "Открытие дополнительного порта не поддерживается для Caddy"
        _info "Для экстренного доступа: rp restart && rp logs caddy"
        return 0
    fi
    local nc="/opt/remnawave/nginx.conf"
    local pd; pd=$(grep -m1 "server_name " "$nc"|awk '{print $2}'|tr -d ';')
    ss -tuln|grep -q ":8443" && { _warn "Порт 8443 занят"; return 1; }
    sed -i "/server_name $pd;/a \\    listen 8443 ssl;" "$nc"
    cd /opt/remnawave && docker compose restart remnawave-nginx>/dev/null 2>&1
    ufw allow 8443/tcp>/dev/null 2>&1; ufw reload>/dev/null 2>&1
    local ck cv
    ck=$(grep "map \$http_cookie" "$nc" -A2|grep -oP '~\*\K\w+(?==)')
    cv=$(grep "map \$http_cookie" "$nc" -A2|grep -oP '=\K\w+(?= 1)')
    _ok "Порт 8443 открыт."
    echo -e "  ${WHITE}https://${pd}:8443/auth/login?${ck}=${cv}${NC}"
    _warn "Закройте после работы: remnawave_panel close_port"
}
do_close_port() {
    local ws; ws=$(_detect_ws)
    if [ "$ws" = "caddy" ]; then _warn "Не применимо для Caddy"; return 0; fi
    local nc="/opt/remnawave/nginx.conf"
    local pd; pd=$(grep -m1 "server_name " "$nc"|awk '{print $2}'|tr -d ';')
    sed -i "/server_name $pd;/,/}/{s/    listen 8443 ssl;//}" "$nc"
    cd /opt/remnawave && docker compose restart remnawave-nginx>/dev/null 2>&1
    ufw delete allow 8443/tcp>/dev/null 2>&1; ufw reload>/dev/null 2>&1
    _ok "Порт 8443 закрыт"
}
do_migrate() {
    header "📦 Перенос Panel на другой сервер"

    # ── Проверки ───────────────────────────────────────────────────
    [ -d /opt/remnawave ] || { err "Панель не установлена"; return 1; }
    [ -f /opt/remnawave/docker-compose.yml ] || { err "docker-compose.yml не найден"; return 1; }
    command -v sshpass &>/dev/null || apt-get install -y -q sshpass 2>/dev/null

    # ── Данные нового сервера ──────────────────────────────────────
    ask_ssh_target
    init_ssh_helpers panel
    check_ssh_connection || return 1
    local rip="$_SSH_IP" rport="$_SSH_PORT" ruser="$_SSH_USER"

    # ── Проверка свободного места ──────────────────────────────────
    _info "Проверяем свободное место на новом сервере..."
    local remote_free local_used
    remote_free=$(RUN "df -BM /opt --output=avail | tail -1 | tr -d 'M'" 2>/dev/null || echo "0")
    local_used=$(du -sm /opt/remnawave 2>/dev/null | awk '{print $1}' || echo "0")
    if [ "$remote_free" -lt "$((local_used * 2))" ] 2>/dev/null; then
        _warn "Мало места на новом сервере: ${remote_free}MB свободно, нужно ~$((local_used * 2))MB"
        read -rp "  Продолжить всё равно? (y/n): " fc < /dev/tty
        [[ "$fc" =~ ^[yY]$ ]] || return 1
    fi

    # ── Установка зависимостей на новом сервере ────────────────────
    remote_install_deps panel

    # ── Дамп БД ────────────────────────────────────────────────────
    _info "Создаём дамп базы данных..."
    local dump="/tmp/panel_migrate_$(date +%Y%m%d_%H%M%S).sql.gz"
    cd /opt/remnawave
    docker compose exec -T remnawave-db pg_dumpall -c -U postgres 2>/dev/null | gzip -9 > "$dump"

    # Проверяем размер дампа
    local dump_size; dump_size=$(stat -c%s "$dump" 2>/dev/null || echo "0")
    if [ "$dump_size" -lt 1000 ]; then
        err "Дамп БД подозрительно мал (${dump_size} байт) — возможна ошибка"
        rm -f "$dump"
        return 1
    fi
    _ok "Дамп БД создан ($(du -sh "$dump" | cut -f1))"

    # ── Передача файлов ────────────────────────────────────────────
    _info "Передаём файлы панели..."
    local ws_cfg_src
    [ -f /opt/remnawave/Caddyfile ] && ws_cfg_src=/opt/remnawave/Caddyfile || ws_cfg_src=/opt/remnawave/nginx.conf
    PUT "$dump" \
        /opt/remnawave/.env \
        /opt/remnawave/docker-compose.yml \
        "$ws_cfg_src" \
        "${ruser}@${rip}:/opt/remnawave/" 2>/dev/null \
        && _ok "Файлы панели переданы" || { err "Ошибка передачи файлов панели"; return 1; }

    # SSL сертификаты
    _info "Передаём SSL сертификаты..."
    if [ -d /etc/letsencrypt/live ] && [ -d /etc/letsencrypt/archive ]; then
        PUT /etc/letsencrypt/live \
            /etc/letsencrypt/archive \
            /etc/letsencrypt/renewal \
            "${ruser}@${rip}:/etc/letsencrypt/" 2>/dev/null \
            && _ok "SSL сертификаты переданы" || _warn "Ошибка передачи SSL — перевыпустите вручную"
    else
        _warn "SSL сертификаты не найдены в /etc/letsencrypt"
    fi

    # Hysteria сертификаты (если есть)
    if [ -d /etc/ssl/certs/hysteria ]; then
        _info "Передаём сертификаты Hysteria2..."
        PUT /etc/ssl/certs/hysteria \
            "${ruser}@${rip}:/etc/ssl/certs/" 2>/dev/null \
            && _ok "Сертификаты Hysteria2 переданы" || _warn "Ошибка передачи сертификатов Hysteria2"
    fi

    # Selfsteal сайт
    if [ -d /var/www/html ] && [ "$(ls -A /var/www/html 2>/dev/null)" ]; then
        _info "Передаём selfsteal сайт..."
        PUT /var/www/html/. "${ruser}@${rip}:/var/www/html/" 2>/dev/null \
            && _ok "Selfsteal сайт передан" || _warn "Ошибка передачи сайта"
    fi

    _ok "Все файлы переданы"

    # ── Запуск на новом сервере ────────────────────────────────────
    _info "Запускаем стек на новом сервере..."
    local dumpb; dumpb=$(basename "$dump")
    RUN bash -s << RSTART
set -e
cd /opt/remnawave

# Удаляем старый volume БД если есть
docker volume rm remnawave-db-data 2>/dev/null || true

# Запускаем только БД и Redis
docker compose up -d remnawave-db remnawave-redis >/dev/null 2>&1
echo "Ждём запуска БД..."
_pw=0
until docker compose exec -T remnawave-db pg_isready -U postgres -q 2>/dev/null; do
    sleep 2; _pw=$((_pw+1))
    [ "$_pw" -ge 30 ] && { echo "PostgreSQL не поднялся за 60 сек" >&2; exit 1; }
done

# Восстанавливаем дамп
echo "Восстанавливаем базу данных..."
zcat /opt/remnawave/$dumpb | docker compose exec -T remnawave-db psql -U postgres postgres >/dev/null 2>&1 || true

# Запускаем весь стек
docker compose up -d >/dev/null 2>&1
echo "Стек запущен"
RSTART
    _ok "Стек запущен на новом сервере"

    # ── Копируем скрипты управления ────────────────────────────────
    PUT /usr/local/bin/remnawave_panel \
        "${ruser}@${rip}:/usr/local/bin/remnawave_panel" 2>/dev/null && \
    RUN "chmod +x /usr/local/bin/remnawave_panel" 2>/dev/null && \
    RUN "grep -q 'alias rp=' /etc/bash.bashrc || echo \"alias rp='remnawave_panel'\" >> /etc/bash.bashrc" 2>/dev/null
    _ok "Скрипт управления установлен"

    # ── Копируем репозиторий server-manager ───────────────────────
    local _sm_dir="${SCRIPT_DIR:-$(dirname "$(realpath "$0" 2>/dev/null || echo "$0")")}"
    if [ -d "$_sm_dir" ] && [ -f "$_sm_dir/server-manager.sh" ]; then
        RUN "mkdir -p /root/server-manager" 2>/dev/null || true
        PUT "$_sm_dir/." "${ruser}@${rip}:/root/server-manager/" 2>/dev/null || true
        RUN "chmod +x /root/server-manager/server-manager.sh &&             ln -sf /root/server-manager/server-manager.sh /usr/local/bin/server-manager" 2>/dev/null || true
        _ok "server-manager скопирован на новый сервер"
    else
        warn "Не удалось определить каталог server-manager — скопируйте вручную"
    fi

    # ── Очистка ────────────────────────────────────────────────────
    rm -f "$dump"
    RUN "rm -f /opt/remnawave/$dumpb" 2>/dev/null || true

    # ── Итог ───────────────────────────────────────────────────────
    echo ""
    _ok "Перенос панели завершён!"
    echo ""
    echo -e "  ${WHITE}Следующие шаги:${NC}"
    echo -e "  ${CYAN}1.${NC} Обновите DNS-записи на новый IP: ${CYAN}${rip}${NC}"
    echo -e "  ${CYAN}2.${NC} После обновления DNS перевыпустите SSL:"
    echo -e "     ${CYAN}ssh ${ruser}@${rip} remnawave_panel ssl${NC}"
    echo -e "  ${CYAN}3.${NC} Проверьте работу панели"
    echo -e "  ${CYAN}4.${NC} Остановите старый сервер когда всё ОК"
    echo ""

    read -rp "  Остановить панель на ЭТОМ сервере? (y/n): " stop_old < /dev/tty
    if [[ "$stop_old" =~ ^[yY]$ ]]; then
        cd /opt/remnawave && docker compose stop >/dev/null 2>&1
        _ok "Панель на старом сервере остановлена"
    else
        _info "Панель на старом сервере продолжает работать"
    fi
}
show_menu() {
    clear
    echo ""
    echo -e "${BOLD}${PURPLE}  REMNAWAVE PANEL${NC}"
    echo -e "${GRAY}  ────────────────────────────────────────────${NC}"
    local ws_svc; ws_svc="remnawave-$(_detect_ws)"
    for c in remnawave $ws_svc remnawave-subscription-page remnanode; do
        s=$(docker ps --format '{{.Status}}' -f "name=$c" 2>/dev/null|head -1)
        if [ -n "$s" ] && echo "$s"|grep -qE "^Up|healthy"; then
            echo -e "  ${GREEN}●${NC} $c"
        elif [ -n "$s" ]; then
            echo -e "  ${YELLOW}◐${NC} $c — $s"
        else
            echo -e "  ${RED}○${NC} $c"
        fi
    done
    echo ""
    echo -e "${GRAY}  ────────────────────────────────────────────${NC}"
    echo ""
    echo -e "  ${BOLD}1)${NC}  📋 Логи        ${BOLD}2)${NC}  📊 Статус    ${BOLD}3)${NC}  🔄 Перезапуск"
    echo -e "  ${BOLD}4)${NC}  ▶️  Старт       ${BOLD}5)${NC}  📦 Обновить  ${BOLD}6)${NC}  🔒 SSL"
    echo -e "  ${BOLD}7)${NC}  💾 Бэкап       ${BOLD}8)${NC}  🏥 Диагноз   ${BOLD}9)${NC}  🔓 Порт 8443"
    echo -e " ${BOLD}10)${NC}  🔐 Закрыть    ${BOLD}11)${NC}  📦 Перенос"
    echo ""
    echo -e "  ${BOLD}q)${NC}  Выход"
    echo ""
}
case "$1" in
    status)      do_status ;;
    logs)        do_logs "${2:-panel}" ;;
    restart)     do_restart "${2:-all}" ;;
    start)       cd /opt/remnawave && docker compose up -d; _ok "Запущено" ;;
    stop)        cd /opt/remnawave && docker compose down; _ok "Остановлено" ;;
    update)      do_update ;;
    ssl)         do_ssl ;;
    backup)      do_backup ;;
    health)      do_health ;;
    open_port)   do_open_port ;;
    close_port)  do_close_port ;;
    migrate)     do_migrate ;;
    help|--help)
        echo "remnawave_panel (rp) — управление Remnawave Panel"
        echo "Команды: status logs restart start stop update ssl backup health open_port close_port migrate"
        ;;
    "")
        while true; do
            show_menu
            read -p "  Выбор: " ch < /dev/tty
            case $ch in
                1) read -p "  Логи (panel/nginx/caddy/sub/node) [panel]: " s < /dev/tty; do_logs "${s:-panel}" ;;
                2) do_status; read -t 0.1 -n 1000 _flush < /dev/tty 2>/dev/null || true; read -p "  Нажмите Enter для продолжения..." < /dev/tty ;;
                3) read -p "  Что перезапустить? [all]: " s < /dev/tty; do_restart "${s:-all}"; read -p "  Нажмите Enter для продолжения..." < /dev/tty ;;
                4) cd /opt/remnawave && docker compose up -d; _ok "Запущено"; read -p "  Нажмите Enter для продолжения..." < /dev/tty ;;
                5) do_update; read -p "  Нажмите Enter для продолжения..." < /dev/tty ;;
                6) do_ssl; read -p "  Нажмите Enter для продолжения..." < /dev/tty ;;
                7) do_backup; read -p "  Нажмите Enter для продолжения..." < /dev/tty ;;
                8) do_health; read -p "  Нажмите Enter для продолжения..." < /dev/tty ;;
                9) do_open_port; read -p "  Нажмите Enter для продолжения..." < /dev/tty ;;
               10) do_close_port; read -p "  Нажмите Enter для продолжения..." < /dev/tty ;;
               11) do_migrate; read -p "  Нажмите Enter для продолжения..." < /dev/tty ;;
                q|Q) exit 0 ;;
                *) sleep 0.3 ;;
            esac
        done ;;
    *) echo "Неизвестная команда. rp help"; exit 1 ;;
esac
MGMTEOF
    chmod +x "$mgmt"
    grep -q "alias rp=" /etc/bash.bashrc 2>/dev/null || \
        echo "alias rp='remnawave_panel'" >> /etc/bash.bashrc
    ok "Команда 'remnawave_panel' (rp) создана"
}


get_remnawave_version() {
    local v
    # 1. Пробуем label (быстро, но часто не задан)
    v=$(docker inspect --format='{{index .Config.Labels "org.opencontainers.image.version"}}' remnawave 2>/dev/null || true)
    # 2. Точный фильтр по имени контейнера — исключает remnawave-redis/db/nginx
    [ -z "$v" ] && v=$(docker inspect --format='{{.Config.Image}}' remnawave 2>/dev/null         | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
    # 3. Fallback: первые 50 строк логов — версия пишется при старте
    [ -z "$v" ] && v=$(docker logs --tail=50 remnawave 2>/dev/null         | grep -o "Remnawave Backend v[0-9.]*" | tail -1         | grep -oE "[0-9]+\.[0-9]+\.[0-9]+" || true)
    echo "${v:-}"
}

get_telemt_version() {
    "$TELEMT_BIN" --version 2>/dev/null | awk '{print $2}' | head -1 || echo ""
}

get_hysteria_version() {
    /usr/local/bin/hysteria version 2>/dev/null | awk '/^Version:/{v=$2; sub(/^v/,"",v); print v; exit}' || true
}


# ═══════════════════════════════════════════════════════════════════
# ████████████████████  PANEL EXTENSIONS  ██████████████████████████
# ═══════════════════════════════════════════════════════════════════

PANEL_TOKEN_FILE="/opt/remnawave/.panel_token"
PANEL_API="http://127.0.0.1:3000"

# ── API утилиты ───────────────────────────────────────────────────
panel_api_request() {
    local method="$1" url="$2" token="$3" data="$4"
    local args=(-s -X "$method" "${PANEL_API}${url}"
        -H "Authorization: Bearer $token"
        -H "Content-Type: application/json"
        -H "X-Forwarded-For: 127.0.0.1"
        -H "X-Forwarded-Proto: https"
        -H "X-Remnawave-Client-Type: browser")
    [ -n "$data" ] && args+=(-d "$data")
    curl "${args[@]}"
}

panel_get_token() {
    # Проверяем сохранённый токен
    if [ -f "$PANEL_TOKEN_FILE" ]; then
        local token; token=$(cat "$PANEL_TOKEN_FILE")
        local test; test=$(panel_api_request "GET" "/api/config-profiles" "$token")
        if echo "$test" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if 'configProfiles' in str(d) else 1)" 2>/dev/null; then
            echo "$token"
            return 0
        fi
        rm -f "$PANEL_TOKEN_FILE"
    fi
    # Логин
    local username password
    read -rp "  Логин панели: " username < /dev/tty
    read -rsp "  Пароль панели: " password < /dev/tty; echo ""
        local resp; resp=$(panel_api_request "POST" "/api/auth/login" "" \
        "$(printf '{"username":"%s","password":"%s"}' "$username" "$password")")
    local token; token=$(echo "$resp" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('response',{}).get('accessToken',''))" 2>/dev/null)
    if [ -z "$token" ] || [ "$token" = "null" ]; then
        err "Не удалось получить токен: $resp"
        return 1
    fi
    echo "$token" > "$PANEL_TOKEN_FILE"
    ok "Авторизация успешна"
    echo "$token"
}

# ── Автообновление скрипта ────────────────────────────────────────
panel_update_script() {
    header "Обновление скрипта"
    local repo_url="https://raw.githubusercontent.com/stump3/server-manager/main"
    local archive_url="https://github.com/stump3/server-manager/archive/refs/heads/main.tar.gz"
    info "Проверяем обновления..."

    # Получаем версию с GitHub (только loader для проверки версии)
    local tmp_ver; tmp_ver=$(mktemp)
    if ! curl -fsSL "${repo_url}/lib/common.sh" -o "$tmp_ver" 2>/dev/null || [ ! -s "$tmp_ver" ]; then
        rm -f "$tmp_ver"
        warn "Не удалось получить версию с GitHub"
        return 1
    fi

    local remote_ver; remote_ver=$(grep "^SCRIPT_VERSION_STATIC=" "$tmp_ver" | head -1         | sed 's/SCRIPT_VERSION_STATIC=//;s/[^a-zA-Z0-9._-]//g' | tr -d " ")
    rm -f "$tmp_ver"
    local local_ver; local_ver="$SCRIPT_VERSION"

    info "Локальная версия: $local_ver"
    info "Версия на GitHub: ${remote_ver:-неизвестна}"
    echo ""

    if [ -n "$remote_ver" ] && [ "$remote_ver" = "$local_ver" ]; then
        ok "Установлена актуальная версия."
        echo ""
        if ! confirm "Переустановить всё равно?" n; then return; fi
    elif [ -n "$remote_ver" ] && [[ "$local_ver" > "$remote_ver" ]]; then
        warn "Локальная версия новее GitHub."
        echo ""
        if ! confirm "Перезаписать локальную версию версией с GitHub?" n; then return; fi
    else
        if ! confirm "Обновить до ${remote_ver:-последней версии}?" y; then return; fi
    fi

    # SCRIPT_DIR экспортируется из server-manager.sh и всегда указывает на корень репо.
    # Не используем BASH_SOURCE[0] — внутри sourced модуля он указывает на panel.sh.
    local script_path script_dir
    if [ -n "${SCRIPT_DIR:-}" ] && [ -d "$SCRIPT_DIR" ]; then
        script_dir="$SCRIPT_DIR"
    else
        # Fallback: идём на два уровня вверх от panel.sh (/lib/../)
        script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
    fi
    script_path="${script_dir}/server-manager.sh"

    info "Скачиваем обновление..."
    local tmp_dir; tmp_dir=$(mktemp -d)

    # Скачиваем полный архив репозитория
    if curl -fsSL "$archive_url" -o "${tmp_dir}/archive.tar.gz" 2>/dev/null; then
        tar -xzf "${tmp_dir}/archive.tar.gz" -C "$tmp_dir" 2>/dev/null
        local extracted; extracted=$(find "$tmp_dir" -maxdepth 1 -type d -name "server-manager-*" | head -1)
        if [ -n "$extracted" ]; then
            # Обновляем loader
            cp "${extracted}/server-manager.sh" "$script_path" && chmod +x "$script_path"

            # Синхронизируем все папки из репозитория кроме служебных
            # Пропускаем: .git, docs (документация не нужна на сервере)
            # Данные и конфиги пользователя (*.toml, *.env, *.json) не трогаем
            local updated_dirs=()
            local dir_name dst_dir src_file rel_path dst_file
            for src_dir in "${extracted}"/*/; do
                dir_name=$(basename "$src_dir")
                # Пропускаем служебные директории
                case "$dir_name" in
                    .git|docs) continue ;;
                esac
                dst_dir="${script_dir}/${dir_name}"
                mkdir -p "$dst_dir"
                # Используем process substitution вместо pipe чтобы избежать subshell
                # find ... | while создаёт subshell — updated_dirs не обновляется
                while IFS= read -r src_file; do
                    rel_path="${src_file#${src_dir}}"
                    dst_file="${dst_dir}/${rel_path}"
                    mkdir -p "$(dirname "$dst_file")"
                    cp "$src_file" "$dst_file"
                done < <(find "$src_dir" -type f)
                updated_dirs+=("$dir_name/")
            done

            [ ${#updated_dirs[@]} -gt 0 ] && ok "Обновлены: ${updated_dirs[*]}"

            # Применяем обновлённые интеграции к установленным сервисам
            local hy_webhook_src="${script_dir}/integrations/hy-webhook.py"
            if [ -f "$hy_webhook_src" ] && [ -f "/opt/hy-webhook/hy-webhook.py" ]; then
                cp "$hy_webhook_src" /opt/hy-webhook/hy-webhook.py
                systemctl restart hy-webhook 2>/dev/null || true
                ok "hy-webhook обновлён и перезапущен"
            fi

            rm -rf "$tmp_dir"

            # Синхронизируем git чтобы версия обновилась
            if [ -d "${script_dir}/.git" ]; then
                git -C "$script_dir" fetch origin --quiet 2>/dev/null || true
                git -C "$script_dir" reset --hard origin/main --quiet 2>/dev/null || true
            fi

            ok "Скрипт обновлён → $script_path"
            warn "Перезапустите: bash $script_path"
            return 0
        fi
    fi

    rm -rf "$tmp_dir"
    warn "Не удалось скачать архив. Попробуйте вручную:"
    info "curl -fsSL $archive_url | tar -xz"
    return 1
}

# ── Переустановка скрипта управления ─────────────────────────────
panel_reinstall_mgmt() {
    header "Переустановить скрипт управления (rp)"

    local pd ck cv mode web_server
    local nc="/opt/remnawave/nginx.conf"
    local cf="/opt/remnawave/Caddyfile"

    if [ -f "$cf" ]; then
        # ── Caddy: извлекаем домен и cookie из Caddyfile ──────────
        web_server="2"
        pd=$(grep -m1 "^https://" "$cf" | sed 's|https://||;s|{.*||;s|{||' | tr -d ' ' | head -1)
        ck=$(grep -oP 'query \K\w+(?==)' "$cf" | head -1)
        cv=$(grep -oP 'query [^=]+=\K\w+' "$cf" | head -1)
    elif [ -f "$nc" ]; then
        # ── Nginx: извлекаем домен и cookie из nginx.conf ─────────
        web_server="1"
        pd=$(grep "server_name " "$nc" | grep -v "hash_bucket\|server_name _" \
            | head -1 | awk '{print $2}' | tr -d ';')
        ck=$(grep "map \$http_cookie" "$nc" -A2 | grep -oP '~\*\K\w+(?==)' | head -1)
        cv=$(grep "map \$http_cookie" "$nc" -A2 | grep -oP '=\K\w+(?= 1)' | head -1)
    else
        warn "Ни nginx.conf ни Caddyfile не найдены — панель не установлена?"
        return 1
    fi

    mode=$([ -f /opt/remnawave/docker-compose.yml ] \
        && grep -q "remnanode" /opt/remnawave/docker-compose.yml \
        && echo "1" || echo "2")

    if [ -z "$pd" ] || [ -z "$ck" ] || [ -z "$cv" ]; then
        warn "Не удалось извлечь параметры из конфига веб-сервера"
        info "Домен: '${pd:-не найден}'  Ключ: '${ck:-не найден}'  Значение: '${cv:-не найдено}'"
        return 1
    fi

    info "Домен: $pd  |  Cookie: $ck=$cv  |  Режим: $mode  |  Веб-сервер: $([ "$web_server" = "2" ] && echo Caddy || echo Nginx)"
    echo ""
    if ! confirm "Переустановить /usr/local/bin/remnawave_panel?" y; then
        return
    fi

    panel_install_mgmt_script "$pd" "$ck" "$cv" "$mode" "$web_server"
    ok "Скрипт управления переустановлен. Изменения применены."
    info "Перезапустите терминал или выполните: source /etc/bash.bashrc"
}

# ── Удаление панели ───────────────────────────────────────────────
panel_remove() {
    header "Удалить панель"
    echo -e "  ${BOLD}1)${RESET} 🗑️   Только скрипт (setup.sh)"
    echo -e "  ${BOLD}2)${RESET} 💣  Скрипт + все данные панели (необратимо!)"
    echo -e "  ${BOLD}0)${RESET} ◀️  Назад"
    echo ""
    local ch; read -rp "  Выбор: " ch < /dev/tty
    case "$ch" in
        1)
            read -rp "  Удалить setup.sh? (y/n): " c < /dev/tty
            [[ "$c" =~ ^[yY]$ ]] || return
            rm -f "$0"
            ok "Скрипт удалён"
            exit 0
            ;;
        2)
            echo ""
            warn "ЭТО УДАЛИТ ВСЕ ДАННЫЕ ПАНЕЛИ, БД, КОНФИГИ!"
            warn "Действие необратимо!"
            echo ""
            read -rp "  Введите 'DELETE' для подтверждения: " c < /dev/tty
            [ "$c" != "DELETE" ] && { info "Отменено"; return; }
            info "Останавливаем контейнеры..."
            cd /opt/remnawave 2>/dev/null && docker compose down -v --rmi all --remove-orphans 2>/dev/null || true
            docker system prune -a --volumes -f >/dev/null 2>&1 || true
            rm -rf /opt/remnawave
            rm -f "$0"
            ok "Панель и скрипт удалены"
            exit 0
            ;;
        0) return ;;
    esac
}

# ── Переустановка панели ──────────────────────────────────────────
panel_reinstall() {
    header "Переустановить панель"
    echo ""
    warn "ВСЕ ДАННЫЕ БУДУТ УДАЛЕНЫ: БД, пользователи, конфиги!"
    warn "После переустановки потребуется заново настроить панель."
    echo ""
    read -rp "  Продолжить? Введите 'YES': " c < /dev/tty
    [ "$c" != "YES" ] && { info "Отменено"; return; }
    info "Удаляем старую установку..."
    cd /opt/remnawave 2>/dev/null && docker compose down -v --rmi all --remove-orphans >/dev/null 2>&1 || true
    docker system prune -a --volumes -f >/dev/null 2>&1 || true
    rm -rf /opt/remnawave
    # server-manager хранится в /root/server-manager — он НЕ в /opt/remnawave,
    # поэтому удалять его не нужно. Симлинк /usr/local/bin/server-manager
    # и alias 'rp' восстанавливаются вызовом panel_install.
    ok "Старая установка удалена"
    info "Запускаем установку заново..."
    panel_install
}

# ── WARP Native ───────────────────────────────────────────────────
panel_warp_menu() {
    while true; do
        clear
        header "WARP Native"
        echo -e "  ${BOLD}1)${RESET} ⬇️   Установить WARP"
        echo -e "  ${BOLD}2)${RESET} ➕  Добавить в профиль Xray"
        echo -e "  ${BOLD}3)${RESET} ➖  Удалить из профиля Xray"
        echo -e "  ${BOLD}4)${RESET} 🗑️   Удалить WARP с системы"
        echo -e "  ${BOLD}0)${RESET} ◀️  Назад"
        echo ""
        local ch; read -rp "  Выбор: " ch < /dev/tty
        case "$ch" in
            1) bash <(curl -fsSL https://raw.githubusercontent.com/distillium/warp-native/main/install.sh) || true
               read -rp "  Нажмите Enter для продолжения..." < /dev/tty ;;
            2) panel_warp_add_config || true ;;
            3) panel_warp_remove_config || true ;;
            4) bash <(curl -fsSL https://raw.githubusercontent.com/distillium/warp-native/main/uninstall.sh) || true
               read -rp "  Нажмите Enter для продолжения..." < /dev/tty ;;
            0) return ;;
            *) warn "Неверный выбор" ;;
        esac
    done
}

panel_warp_select_profile() {
    local resp="$1"
    echo "$resp" | python3 - << 'PY'
import sys, json
d = json.load(sys.stdin)
ps = d.get('response', {}).get('configProfiles', [])
for i, p in enumerate(ps, 1):
    print(str(i) + ') ' + p['name'] + ' [' + p['uuid'] + ']')
PY
}

panel_warp_get_uuid() {
    local resp="$1"
    local num="$2"
    echo "$resp" | python3 - "$num" << 'PY'
import sys, json
d = json.load(sys.stdin)
num = int(sys.argv[1]) if len(sys.argv) > 1 else 0
ps = d.get('response', {}).get('configProfiles', [])
try:
    print(ps[num - 1]['uuid'])
except Exception:
    pass
PY
}

panel_warp_add_config() {
    header "WARP — Добавить в профиль"
    [ -d /opt/remnawave ] || { warn "Панель не установлена"; return 1; }
    local token; token=$(panel_get_token) || return 1
    local resp; resp=$(panel_api_request "GET" "/api/config-profiles" "$token")
    echo ""
    panel_warp_select_profile "$resp"
    echo ""
    read -rp "  Номер профиля: " num < /dev/tty
    local uuid; uuid=$(panel_warp_get_uuid "$resp" "$num")
    [ -z "$uuid" ] && { warn "Неверный выбор"; return 1; }
    local cfg_resp; cfg_resp=$(panel_api_request "GET" "/api/config-profiles/$uuid" "$token")
    local cfg_json
    cfg_json=$(echo "$cfg_resp" | python3 - << 'PY'
import sys, json
d = json.load(sys.stdin)
cfg = d.get('response', {}).get('config', {})
ob = cfg.get('outbounds', [])
if not any(o.get('tag') == 'warp-out' for o in ob):
    ob.append({'tag': 'warp-out', 'protocol': 'freedom',
        'settings': {'domainStrategy': 'UseIP'},
        'streamSettings': {'sockopt': {'interface': 'warp', 'tcpFastOpen': True}}})
    cfg['outbounds'] = ob
rules = cfg.get('routing', {}).get('rules', [])
if not any(r.get('outboundTag') == 'warp-out' for r in rules):
    rules.append({'type': 'field',
        'domain': ['whoer.net', 'browserleaks.com', '2ip.io', '2ip.ru'],
        'outboundTag': 'warp-out'})
    cfg['routing']['rules'] = rules
print(json.dumps(cfg))
PY
)
    [ -z "$cfg_json" ] && { err "Ошибка обработки конфига"; return 1; }
    local upd; upd=$(panel_api_request "PATCH" "/api/config-profiles" "$token" "{\"uuid\":\"$uuid\",\"config\":$cfg_json}")
    echo "$upd" | python3 -c 'import sys,json; d=json.load(sys.stdin); exit(0 if d.get("response") else 1)' 2>/dev/null \
        && ok "WARP добавлен в профиль!" || warn "Ошибка обновления: $upd"
    read -rp "Enter..." < /dev/tty
}

panel_warp_remove_config() {
    header "WARP — Удалить из профиля"
    [ -d /opt/remnawave ] || { warn "Панель не установлена"; return 1; }
    local token; token=$(panel_get_token) || return 1
    local resp; resp=$(panel_api_request "GET" "/api/config-profiles" "$token")
    echo ""
    panel_warp_select_profile "$resp"
    echo ""
    read -rp "  Номер профиля: " num < /dev/tty
    local uuid; uuid=$(panel_warp_get_uuid "$resp" "$num")
    [ -z "$uuid" ] && { warn "Неверный выбор"; return 1; }
    local cfg_resp; cfg_resp=$(panel_api_request "GET" "/api/config-profiles/$uuid" "$token")
    local cfg_json
    cfg_json=$(echo "$cfg_resp" | python3 - << 'PY'
import sys, json
d = json.load(sys.stdin)
cfg = d.get('response', {}).get('config', {})
ob = cfg.get('outbounds', [])
cfg['outbounds'] = [o for o in ob if o.get('tag') != 'warp-out']
rules = cfg.get('routing', {}).get('rules', [])
cfg['routing']['rules'] = [r for r in rules if r.get('outboundTag') != 'warp-out']
print(json.dumps(cfg))
PY
)
    [ -z "$cfg_json" ] && { err "Ошибка обработки конфига"; return 1; }
    local upd; upd=$(panel_api_request "PATCH" "/api/config-profiles" "$token" "{\"uuid\":\"$uuid\",\"config\":$cfg_json}")
    echo "$upd" | python3 -c 'import sys,json; d=json.load(sys.stdin); exit(0 if d.get("response") else 1)' 2>/dev/null \
        && ok "WARP удалён из профиля!" || warn "Ошибка обновления: $upd"
    read -rp "Enter..." < /dev/tty
}

# ── Selfsteal шаблоны ─────────────────────────────────────────────
panel_template_menu() {
    while true; do
        clear
        header "Selfsteal — шаблон сайта"
        echo -e "  ${BOLD}1)${RESET} 🎲  Случайный шаблон"
        echo -e "  ${BOLD}2)${RESET} 🌐  Simple web templates"
        echo -e "  ${BOLD}3)${RESET} 🔷  SNI templates"
        echo -e "  ${BOLD}4)${RESET} ⬜  Nothing SNI"
        echo -e "  ${BOLD}0)${RESET} ◀️  Назад"
        echo ""
        local ch; read -rp "  Выбор: " ch < /dev/tty
        case "$ch" in
            1) panel_install_template "" || true ;;
            2) panel_install_template "simple" || true ;;
            3) panel_install_template "sni" || true ;;
            4) panel_install_template "nothing" || true ;;
            0) return ;;
            *) warn "Неверный выбор" ;;
        esac
    done
}

panel_install_template() {
    local src="$1"
    local urls=(
        "https://github.com/eGamesAPI/simple-web-templates/archive/refs/heads/main.zip"
        "https://github.com/distillium/sni-templates/archive/refs/heads/main.zip"
        "https://github.com/prettyleaf/nothing-sni/archive/refs/heads/main.zip"
    )
    local selected_url
    case "$src" in
        "simple")  selected_url="${urls[0]}" ;;
        "sni")     selected_url="${urls[1]}" ;;
        "nothing") selected_url="${urls[2]}" ;;
        *)
            local idx; idx=$(python3 -c "import random; print(random.randrange(3))" 2>/dev/null || echo "$((RANDOM % 3))")
            selected_url="${urls[$idx]}"
            ;;
    esac
    info "Скачиваем шаблон..."
    cd /opt/ || return 1
    rm -f main.zip
    rm -rf simple-web-templates-main sni-templates-main nothing-sni-main
    wget -q --timeout=30 "$selected_url" -O main.zip || { err "Ошибка загрузки"; return 1; }
    unzip -o main.zip &>/dev/null || { err "Ошибка распаковки"; return 1; }
    rm -f main.zip
    local dir template
    if [[ "$selected_url" == *"eGamesAPI"* ]]; then
        dir="simple-web-templates-main"
        cd "$dir" && rm -rf assets .gitattributes README.md _config.yml 2>/dev/null
        mapfile -t templates < <(find . -maxdepth 1 -type d -not -path .)
        local _tidx; _tidx=$(python3 -c "import random,sys; print(random.randrange(int(sys.argv[1])))" "${#templates[@]}" 2>/dev/null || echo "0")
        template="${templates[$_tidx]}"
    elif [[ "$selected_url" == *"nothing-sni"* ]]; then
        dir="nothing-sni-main"
        cd "$dir" && rm -rf .github README.md 2>/dev/null
        template="$((RANDOM % 8 + 1)).html"
    else
        dir="sni-templates-main"
        cd "$dir" && rm -rf assets README.md index.html 2>/dev/null
        mapfile -t templates < <(find . -maxdepth 1 -type d -not -path .)
        local _tidx; _tidx=$(python3 -c "import random,sys; print(random.randrange(int(sys.argv[1])))" "${#templates[@]}" 2>/dev/null || echo "0")
        template="${templates[$_tidx]}"
    fi
    # Рандомизация HTML
    local rand_id; rand_id=$(openssl rand -hex 8)
    local rand_title="Page_$(openssl rand -hex 4)"
    find "./$template" -type f -name "*.html" -exec sed -i         -e "s|<title>.*</title>|<title>${rand_title}</title>|"         -e "s/<\/head>/<meta name="page-id" content="${rand_id}">
<\/head>/"         {} \; 2>/dev/null || true
    # Копируем в /var/www/html
    mkdir -p /var/www/html
    rm -rf /var/www/html/*
    if [ -d "./$template" ]; then
        cp -a "./$template"/. /var/www/html/
    elif [ -f "./$template" ]; then
        cp "./$template" /var/www/html/index.html
    fi
    cd /opt/
    rm -rf simple-web-templates-main sni-templates-main nothing-sni-main
    ok "Шаблон установлен: $template"
    read -rp "Enter..." < /dev/tty
}

# ── Страница подписки ─────────────────────────────────────────────
panel_subpage_menu() {
    while true; do
        clear
        header "Страница подписки"
        echo -e "  ${BOLD}1)${RESET} 🎨  Установить Orion шаблон"
        echo -e "  ${BOLD}2)${RESET} 🏷️   Настроить брендинг"
        echo -e "  ${BOLD}3)${RESET} ♻️   Восстановить оригинал"
        echo -e "  ${BOLD}0)${RESET} ◀️  Назад"
        echo ""
        local ch; read -rp "  Выбор: " ch < /dev/tty
        case "$ch" in
            1) panel_subpage_install_orion || true ;;
            2) panel_subpage_branding || true ;;
            3) panel_subpage_restore || true ;;
            0) return ;;
            *) warn "Неверный выбор" ;;
        esac
    done
}

panel_subpage_install_orion() {
    header "Установка Orion шаблона"
    [ -f /opt/remnawave/docker-compose.yml ] || { warn "Панель не установлена"; return 1; }
    local index="/opt/remnawave/index.html"
    local compose="/opt/remnawave/docker-compose.yml"
    local primary="https://raw.githubusercontent.com/legiz-ru/Orion/refs/heads/main/index.html"
    local fallback="https://cdn.jsdelivr.net/gh/legiz-ru/Orion@main/index.html"
    info "Скачиваем Orion..."
    rm -f "$index"
    if ! curl -fsSL "$primary" -o "$index" 2>/dev/null; then
        curl -fsSL "$fallback" -o "$index" || { err "Ошибка загрузки"; return 1; }
    fi
    # Монтируем в docker-compose
    if command -v yq &>/dev/null; then
        yq eval 'del(.services."remnawave-subscription-page".volumes)' -i "$compose"
        yq eval '.services."remnawave-subscription-page".volumes += ["./index.html:/opt/app/frontend/index.html"]' -i "$compose"
    else
        # Простая замена если нет yq
        warn "yq не установлен — монтирование не добавлено автоматически"
        warn "Добавьте вручную в docker-compose.yml:"
        echo "  volumes:"
        echo "    - ./index.html:/opt/app/frontend/index.html"
    fi
    cd /opt/remnawave
    docker compose restart remnawave-subscription-page >/dev/null 2>&1
    ok "Orion установлен!"
    read -rp "Enter..." < /dev/tty
}

panel_subpage_branding() {
    header "Брендинг подписки"
    local config="/opt/remnawave/app-config.json"
    if [ -f "$config" ]; then
        local name logo support
        name=$(python3 -c "import json; d=json.load(open('$config')); print(d.get('config',{}).get('branding',{}).get('name','—'))" 2>/dev/null)
        logo=$(python3 -c "import json; d=json.load(open('$config')); print(d.get('config',{}).get('branding',{}).get('logoUrl','—'))" 2>/dev/null)
        support=$(python3 -c "import json; d=json.load(open('$config')); print(d.get('config',{}).get('branding',{}).get('supportUrl','—'))" 2>/dev/null)
        echo ""
        echo -e "  ${GRAY}Текущие значения:${NC}"
        echo -e "  Название:  ${CYAN}${name}${NC}"
        echo -e "  Логотип:   ${CYAN}${logo}${NC}"
        echo -e "  Поддержка: ${CYAN}${support}${NC}"
        echo ""
    fi
    local new_name new_logo new_support
    read -rp "  Название (Enter — пропустить): " new_name < /dev/tty
    read -rp "  URL логотипа (Enter — пропустить): " new_logo < /dev/tty
    read -rp "  URL поддержки (Enter — пропустить): " new_support < /dev/tty
    # Обновляем конфиг
    NEW_NAME="$new_name" NEW_LOGO="$new_logo" NEW_SUPPORT="$new_support"     CONFIG_FILE="$config" python3 << 'PYEOF'
import json, os
config_file = os.environ["CONFIG_FILE"]
try:
    with open(config_file) as f:
        d = json.load(f)
except Exception:
    d = {"config": {}}
d.setdefault("config", {}).setdefault("branding", {})
n = os.environ.get("NEW_NAME")
l = os.environ.get("NEW_LOGO")
s = os.environ.get("NEW_SUPPORT")
if n: d["config"]["branding"]["name"]       = n
if l: d["config"]["branding"]["logoUrl"]    = l
if s: d["config"]["branding"]["supportUrl"] = s
with open(config_file, "w") as f:
    json.dump(d, f, indent=2, ensure_ascii=False)
print("OK")
PYEOF
    cd /opt/remnawave && docker compose restart remnawave-subscription-page >/dev/null 2>&1
    ok "Брендинг обновлён!"
    read -rp "Enter..." < /dev/tty
}

panel_subpage_restore() {
    header "Восстановить оригинал"
    read -rp "  Восстановить оригинальную страницу подписки? (y/n): " c < /dev/tty
    [[ "$c" =~ ^[yY]$ ]] || return
    rm -f /opt/remnawave/index.html /opt/remnawave/app-config.json
    if command -v yq &>/dev/null; then
        yq eval 'del(.services."remnawave-subscription-page".volumes)' -i /opt/remnawave/docker-compose.yml
    fi
    cd /opt/remnawave && docker compose restart remnawave-subscription-page >/dev/null 2>&1
    ok "Оригинал восстановлен!"
    read -rp "Enter..." < /dev/tty
}

# ── Remnawave CLI ─────────────────────────────────────────────────
panel_cli() {
    header "Remnawave CLI"
    info "Запуск интерактивного CLI панели..."
    docker exec -it remnawave remnawave || warn "Не удалось запустить CLI. Панель запущена?"
    read -rp "Enter..." < /dev/tty
}

panel_menu() {
    local ver panel_domain
    ver=$(get_remnawave_version 2>/dev/null || true)
    panel_domain=""
    [ -f /opt/remnawave/.env ] && panel_domain=$(awk -F= '/^FRONT_END_DOMAIN=/{gsub(/"/, "", $2); print $2; exit}' /opt/remnawave/.env 2>/dev/null || true)
    while true; do
        clear
        echo ""
        echo -e "${BOLD}${WHITE}  🛡️  Remnawave Panel${NC}"
        echo -e "${GRAY}  ────────────────────────────────────────────${NC}"
        if [ -n "$ver" ] || [ -n "$panel_domain" ]; then
            [ -n "$ver" ]          && echo -e "  ${GRAY}Версия  ${NC}${ver}"
            [ -n "$panel_domain" ] && echo -e "  ${GRAY}Домен   ${NC}${panel_domain}"
            echo ""
        fi
        echo -e "  ${BOLD}1)${RESET}  🔧  Установка"
        echo -e "  ${BOLD}2)${RESET}  ⚙️  Управление"
        echo -e "  ${BOLD}3)${RESET}  🌐  WARP Native"
        echo -e "  ${BOLD}4)${RESET}  🎨  Страница подписки"
        echo -e "  ${BOLD}5)${RESET}  🖼️  Selfsteal шаблон"
        echo -e "  ${BOLD}6)${RESET}  📦  Миграция на другой сервер"
        echo -e "  ${BOLD}7)${RESET}  🗑️  Удалить панель"
        echo ""
        echo -e "  ${BOLD}0)${RESET}  ◀️  Назад"
        echo ""
        local ch; read -rp "  Выбор: " ch < /dev/tty
        case "$ch" in
            1) panel_submenu_install || true ;;
            2) panel_submenu_manage || true ;;
            3) panel_warp_menu || true ;;
            4) panel_subpage_menu || true ;;
            5) panel_template_menu || true ;;
            6) { [ -x "$PANEL_MGMT_SCRIPT" ] && "$PANEL_MGMT_SCRIPT" migrate || warn "Панель не установлена."; } || true
               read -rp "  Нажмите Enter для продолжения..." < /dev/tty ;;
            7) panel_remove || true ;;
            0) return ;;
            *) warn "Неверный выбор" ;;
        esac
        ver=$(get_remnawave_version 2>/dev/null || true)
    done
}

panel_submenu_install() {
    clear
    header "Remnawave Panel — Установка"
    echo -e "  ${BOLD}1)${RESET} 🆕  Установить"
    echo -e "  ${BOLD}2)${RESET} 💣  Переустановить (сброс всех данных!)"
    echo -e "  ${BOLD}0)${RESET} ◀️  Назад"
    echo ""
    local ch; read -rp "  Выбор: " ch < /dev/tty
    case "$ch" in
        1) panel_install ;;
        2) panel_reinstall ;;
        0) return ;;
        *) warn "Неверный выбор" ;;
    esac
}

panel_submenu_manage() {
    while true; do
        clear
        header "Remnawave Panel — Управление"
        echo -e "  ${BOLD}1)${RESET} 📋  Логи"
        echo -e "  ${BOLD}2)${RESET} 📊  Статус"
        echo -e "  ${BOLD}3)${RESET} 🔄  Перезапустить"
        echo -e "  ${BOLD}4)${RESET}  ▶️  Старт"
        echo -e "  ${BOLD}5)${RESET} 📦  Обновить"
        echo -e "  ${BOLD}6)${RESET} 🔒  SSL"
        echo -e "  ${BOLD}7)${RESET} 💾  Бэкап"
        echo -e "  ${BOLD}8)${RESET} 🏥  Диагноз"
        echo -e "  ${BOLD}9)${RESET} 🔓  Открыть порт 8443"
        echo -e " ${BOLD}10)${RESET} 🔐  Закрыть порт 8443"
        echo -e " ${BOLD}11)${RESET} 💻  Remnawave CLI"
        echo -e " ${BOLD}12)${RESET} 🔧  Переустановить скрипт (rp)"
        echo -e "  ${BOLD}0)${RESET} ◀️  Назад"
        echo ""
        local ch; read -rp "  Выбор: " ch < /dev/tty
        [ -x "$PANEL_MGMT_SCRIPT" ] || { warn "Панель не установлена."; return; }
        case "$ch" in
        1)  "$PANEL_MGMT_SCRIPT" logs ;;
        2)  "$PANEL_MGMT_SCRIPT" status; read -rp "  Нажмите Enter для продолжения..." < /dev/tty ;;
        3)  "$PANEL_MGMT_SCRIPT" restart; read -rp "  Нажмите Enter для продолжения..." < /dev/tty ;;
        4)  "$PANEL_MGMT_SCRIPT" start; read -rp "  Нажмите Enter для продолжения..." < /dev/tty ;;
        5)  "$PANEL_MGMT_SCRIPT" update; read -rp "  Нажмите Enter для продолжения..." < /dev/tty ;;
        6)  "$PANEL_MGMT_SCRIPT" ssl; read -rp "  Нажмите Enter для продолжения..." < /dev/tty ;;
        7)  "$PANEL_MGMT_SCRIPT" backup; read -rp "  Нажмите Enter для продолжения..." < /dev/tty ;;
        8)  "$PANEL_MGMT_SCRIPT" health; read -rp "  Нажмите Enter для продолжения..." < /dev/tty ;;
        9)  "$PANEL_MGMT_SCRIPT" open_port; read -rp "  Нажмите Enter для продолжения..." < /dev/tty ;;
        10) "$PANEL_MGMT_SCRIPT" close_port; read -rp "  Нажмите Enter для продолжения..." < /dev/tty ;;
        11) panel_cli ;;
        12) panel_reinstall_mgmt || true; read -rp "  Нажмите Enter для продолжения..." < /dev/tty ;;
        0)  return ;;
        *)  warn "Неверный выбор" ;;
        esac
        done
}
