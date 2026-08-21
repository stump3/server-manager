# shellcheck shell=bash

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

# panel_install_ssl() — из lib/panel/install.sh (Stage: panel install
# decomposition)

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
