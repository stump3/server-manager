# shellcheck shell=bash

panel_install_prerequisites() {
    local web_server="$1"
    local cert_method="$2"

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
    if [ "$web_server" = "1" ]; then
        PKGS+=(certbot python3-certbot-dns-cloudflare)
        [ "$cert_method" = "3" ] && PKGS+=(python3-pip)
    fi
    MISSING=(); for p in "${PKGS[@]}"; do dpkg -l "$p" &>/dev/null || MISSING+=("$p"); done
    [ ${#MISSING[@]} -gt 0 ] && apt-get install -y -q "${MISSING[@]}"
    if [ "$web_server" = "1" ] && [ "$cert_method" = "3" ]; then
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
}

panel_install_ssl() {
    local WEB_SERVER="$1"
    local CERT_METHOD="$2"
    local PANEL_DOMAIN="$3"
    local SUB_DOMAIN="$4"
    local SELFSTEAL_DOMAIN="$5"
    local PANEL_CF_KEY="$6"
    local PANEL_CF_EMAIL="$7"
    local GCORE_TOKEN="$8"
    local PANEL_LE_EMAIL="$9"

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
        # Caddy: порт 80 нужен для HTTP-01 ACME и редиректов в обоих режимах.
        # В selfsteal MODE=1 порт 443 остаётся за Xray, Caddy принимает HTTPS через unix-сокет.
        ufw allow 80/tcp comment 'HTTP (Caddy ACME)' >/dev/null 2>&1
        ok "SSL — Caddy получит сертификаты автоматически при первом запуске"
    fi
}

panel_generate_selfsteal_site() {
    local TARGET_DIR="${1:-/var/www/html}"
    # Маскировочный сайт
    mkdir -p "$TARGET_DIR"
    if curl -s --max-time 10 -L \
            "https://github.com/eGamesAPI/simple-web-templates/archive/refs/heads/main.zip" \
            -o /tmp/tmpl.zip 2>/dev/null && \
       unzip -q /tmp/tmpl.zip -d /tmp/tmpl 2>/dev/null; then
        TDIRS=(/tmp/tmpl/simple-web-templates-main/*/)
        if [ ${#TDIRS[@]} -gt 0 ]; then
            local _ridx; _ridx=$(python3 -c "import random,sys; print(random.randrange(int(sys.argv[1])))" "${#TDIRS[@]}" 2>/dev/null || echo "0")
            cp -a "${TDIRS[$_ridx]}/." "$TARGET_DIR/" 2>/dev/null || true
        fi
        rm -rf /tmp/tmpl /tmp/tmpl.zip
        ok "Маскировочный сайт установлен"
    else
        cat > "$TARGET_DIR/index.html" <<'HTMLEOF'
<!DOCTYPE html><html><head><meta charset="UTF-8"><title>Welcome</title>
<style>body{font-family:sans-serif;text-align:center;padding:100px;background:#f5f5f5}h1{color:#333}</style>
</head><body><h1>Welcome</h1><p>Service is running.</p></body></html>
HTMLEOF
        ok "Базовая страница /var/www/html"
    fi
}

panel_generate_env() {
    local PANEL_DOMAIN="$1"
    local SUB_DOMAIN="$2"
    local WEB_SERVER="$3"

    SUPERADMIN_USER=$(gen_user)
    SUPERADMIN_PASS=$(gen_password)
    COOKIE_KEY=$(gen_user)
    COOKIE_VAL=$(gen_user)
    APP_SECRET=$(gen_hex64)
    METRICS_USER=$(gen_user)
    METRICS_PASS=$(gen_user)

    cat > /opt/remnawave/.env << EOF
APP_PORT=3000
METRICS_PORT=3001
API_INSTANCES=1
DATABASE_URL="postgresql://postgres:postgres@remnawave-db:5432/postgres"
REDIS_SOCKET=/var/run/valkey/valkey.sock
APP_SECRET=$APP_SECRET
JWT_AUTH_LIFETIME=168
FRONT_END_DOMAIN=$PANEL_DOMAIN
SUB_PUBLIC_DOMAIN=$SUB_DOMAIN
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
    CERT_VOLUMES=""
    [ "$WEB_SERVER" = "1" ] && CERT_VOLUMES="      - /etc/letsencrypt:/etc/letsencrypt:ro
"
}

panel_pause_before_launch() {
    local WEB_SERVER="$1"

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
}

panel_install_summary() {
    local PANEL_DOMAIN="$1"
    local SUB_DOMAIN="$2"
    local SELFSTEAL_DOMAIN="$3"
    local SUPERADMIN_USER="$4"
    local SUPERADMIN_PASS="$5"
    local COOKIE_KEY="$6"
    local COOKIE_VAL="$7"

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
    panel_install_prerequisites "$WEB_SERVER" "$CERT_METHOD"

    local PC="" SC="" STC=""
    panel_install_ssl "$WEB_SERVER" "$CERT_METHOD" \
                       "$PANEL_DOMAIN" "$SUB_DOMAIN" "$SELFSTEAL_DOMAIN" \
                       "$PANEL_CF_KEY" "$PANEL_CF_EMAIL" "$GCORE_TOKEN" \
                       "$PANEL_LE_EMAIL"

    # ── Генерация конфигурации ───────────────────────────────────
    STEP_NUM=$(( STEP_NUM + 1 ))
    step "Генерация конфигурации"
    mkdir -p /opt/remnawave && cd /opt/remnawave

    local SUPERADMIN_USER SUPERADMIN_PASS COOKIE_KEY COOKIE_VAL
    local APP_SECRET METRICS_USER METRICS_PASS
    local CERT_VOLUMES=""
    panel_generate_env "$PANEL_DOMAIN" "$SUB_DOMAIN" "$WEB_SERVER"

    panel_generate_compose "$WEB_SERVER" "$MODE" "$CERT_VOLUMES" "$PANEL_DOMAIN" "$SUB_DOMAIN" "$SELFSTEAL_DOMAIN"

    panel_generate_webserver_config \
        "$WEB_SERVER" \
        "$MODE" \
        "$PANEL_DOMAIN" \
        "$SUB_DOMAIN" \
        "$SELFSTEAL_DOMAIN" \
        "$PC" \
        "$SC" \
        "$STC" \
        "$COOKIE_KEY" \
        "$COOKIE_VAL"

    ok "Конфигурация сгенерирована"

    # Маскировочный сайт
    panel_generate_selfsteal_site

    panel_pause_before_launch "$WEB_SERVER"

    # ── Запуск и автоконфигурация ────────────────────────────────
    STEP_NUM=$(( STEP_NUM + 1 ))
    step "Запуск и автоконфигурация"
    panel_setup_api "$SUPERADMIN_USER" "$SUPERADMIN_PASS" "$SELFSTEAL_DOMAIN" "$MODE"

    # ── Команда управления ───────────────────────────────────────
    panel_install_mgmt_script "$PANEL_DOMAIN" "$COOKIE_KEY" "$COOKIE_VAL" "$MODE" "$WEB_SERVER"

    panel_install_summary "$PANEL_DOMAIN" "$SUB_DOMAIN" "$SELFSTEAL_DOMAIN" "$SUPERADMIN_USER" "$SUPERADMIN_PASS" "$COOKIE_KEY" "$COOKIE_VAL"
}
