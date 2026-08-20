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

panel_setup_api() {
    local SUPERADMIN_USER="$1"
    local SUPERADMIN_PASS="$2"
    local SELFSTEAL_DOMAIN="$3"
    local MODE="$4"

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
    PUB_KEY=$(echo "$PUB_R" | jq -r '.response.secretKey // empty' 2>/dev/null)
    [ -z "$PUB_KEY" ] && err "Ошибка получения SECRET_KEY ноды"
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
_migrate_env_for_remnawave_v2() {
    local env_file="$DIR/.env"
    [ -f "$env_file" ] || { _warn ".env не найден: $env_file"; return 1; }

    if grep -q '^JWT_AUTH_SECRET=' "$env_file" && ! grep -q '^APP_SECRET=' "$env_file"; then
        sed -i 's/^JWT_AUTH_SECRET=/APP_SECRET=/' "$env_file"
        _ok ".env: JWT_AUTH_SECRET переименован в APP_SECRET"
    elif grep -q '^JWT_AUTH_SECRET=' "$env_file" && grep -q '^APP_SECRET=' "$env_file"; then
        sed -i '/^JWT_AUTH_SECRET=/d' "$env_file"
        _ok ".env: удалён дублирующий JWT_AUTH_SECRET"
    fi

    local removed=0
    for key in JWT_API_TOKENS_SECRET SWAGGER_PATH SCALAR_PATH IS_DOCS_ENABLED; do
        if grep -q "^${key}=" "$env_file"; then
            sed -i "/^${key}=/d" "$env_file"
            removed=1
        fi
    done
    [ "$removed" = "1" ] && _ok ".env: удалены устаревшие переменные Remnawave"
}
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
    _warn "Перед обновлением будет создан бэкап БД и конфигов."
    do_backup
    _migrate_env_for_remnawave_v2 || return 1
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
    remote_install_deps panel "$(_detect_ws)"

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
