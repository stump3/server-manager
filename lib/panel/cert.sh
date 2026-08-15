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
