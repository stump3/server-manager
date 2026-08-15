# shellcheck shell=bash
# common/network.sh — public IP, domain validation, DNS check, panel API client


get_public_ip() {
    curl -s --max-time 5 https://api.ipify.org 2>/dev/null \
        || curl -s --max-time 5 https://ifconfig.me 2>/dev/null \
        || echo "YOUR_SERVER_IP"
}

validate_domain() {
    [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]
}

check_dns() {
    local domain="$1" server_ip domain_ip
    server_ip=$(curl -4 -s --max-time 5 ifconfig.me 2>/dev/null || echo "")
    domain_ip=$(dig +short -t A "$domain" 2>/dev/null | grep -E '^[0-9]+\.' | head -1)
    [ -z "$server_ip" ] && { warn "Не удалось определить IP сервера"; return 1; }
    [ -z "$domain_ip" ] && { warn "A-запись для $domain не найдена"; return 1; }
    [ "$server_ip" != "$domain_ip" ] && { warn "$domain → $domain_ip, сервер → $server_ip"; return 1; }
    ok "DNS $domain → $domain_ip ✓"
    return 0
}

# API-запросы к Remnawave
panel_api() {
    local method="$1" url="$2" token="${3:-}" data="${4:-}"
    local headers=(
        -H "Content-Type: application/json"
        -H "X-Forwarded-For: 127.0.0.1"
        -H "X-Forwarded-Proto: https"
        -H "X-Remnawave-Client-Type: browser"
    )
    [ -n "$token" ] && headers+=(-H "Authorization: Bearer $token")
    if [ -n "$data" ]; then
        curl -s -X "$method" "$url" "${headers[@]}" -d "$data"
    else
        curl -s -X "$method" "$url" "${headers[@]}"
    fi
}
