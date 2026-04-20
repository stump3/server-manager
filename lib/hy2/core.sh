# shellcheck shell=bash
# Hysteria2: утилиты, проверки и чтение конфига

hy_is_installed() { command -v hysteria &>/dev/null; }


hy_is_running() { systemctl is-active --quiet hysteria-server 2>/dev/null; }

get_hysteria_version() {
    hysteria version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 \
        || hysteria version 2>/dev/null | awk 'NR==1{print $NF}' | head -1
}



hy_port_is_free() {
    local p="$1"
    ss -tulpn 2>/dev/null | awk '{print $5}' | grep -qE ":${p}$" && return 1 || return 0
}

hy_port_label() {
    local p="$1"
    if hy_port_is_free "$p"; then
        echo "свободен ✓"
    else
        local proc
        proc=$(ss -tulpn 2>/dev/null | awk '{print $5,$7}' | grep ":${p} " \
            | grep -oP 'users:\(\("\K[^"]+' | head -1 || true)
        [ -n "$proc" ] && echo "занят ($proc) ✗" || echo "занят ✗"
    fi
}

hy_is_valid_fqdn() {
    local d="$1"
    [[ "$d" == *.* ]] || return 1
    [[ "${#d}" -le 253 ]] || return 1
    [[ "$d" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

hy_get_public_ip() {
    local ip=""
    for url in "https://api.ipify.org" "https://ifconfig.me/ip" \
               "https://icanhazip.com" "https://checkip.amazonaws.com"; do
        ip="$(curl -4fsS --max-time 6 "$url" 2>/dev/null | tr -d ' \r\n' || true)"
        [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && { echo "$ip"; return 0; }
    done
    return 1
}

hy_resolve_a() {
    local domain="$1"
    if command -v dig &>/dev/null; then
        dig +short A "$domain" 2>/dev/null | tr -d '\r' | grep -E '^[0-9]+\.' || true
    else
        getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | grep -E '^[0-9]+\.' || true
    fi
}

hy_resolve_aaaa() {
    local domain="$1"
    if command -v dig &>/dev/null; then
        dig +short AAAA "$domain" 2>/dev/null | tr -d '\r' | grep ':' || true
    else
        getent ahostsv6 "$domain" 2>/dev/null | awk '{print $1}' | grep ':' || true
    fi
}

hy_resolve_a_via_resolver() {
    local domain="$1" resolver="$2"
    command -v dig &>/dev/null || return 0
    dig +short A "$domain" "@$resolver" 2>/dev/null | tr -d '\r' | grep -E '^[0-9]+\.' || true
}

hy_get_domain() {
    local _d=""
    [ -f "$HYSTERIA_CONFIG" ] && _d=$(
        awk '
            /^[[:space:]]*domains:[[:space:]]*$/ { f=1; next }
            f {
                if ($0 ~ /^[[:space:]]*-[[:space:]]*/) {
                    line=$0
                    sub(/^[[:space:]]*-[[:space:]]*/, "", line)
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
                    gsub(/^["'\''"]|["'\''"]$/, "", line)
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
                    print line
                    exit
                }
                if ($0 !~ /^[[:space:]]*$/ && $0 !~ /^[[:space:]]/) { exit }
            }
        ' "$HYSTERIA_CONFIG" 2>/dev/null
    )
    if [ -z "$_d" ]; then
        _d=$(grep "^HY_DOMAIN=" /etc/hy-webhook.env 2>/dev/null | cut -d= -f2 | tr -d '"')
    fi
    echo "$_d"
}

hy_get_port() {
    [ -f "$HYSTERIA_CONFIG" ] || { echo ""; return 1; }
    local _listen_line _port
    _listen_line=$(grep -m1 -E '^[[:space:]]*listen:[[:space:]]*' "$HYSTERIA_CONFIG" 2>/dev/null || true)
    _port=$(
        printf '%s\n' "$_listen_line" \
            | sed -nE 's/^[[:space:]]*listen:[[:space:]]*["'"'"']?.*:([0-9]+)(,[0-9]+-[0-9]+)?["'"'"']?([[:space:]]*#.*)?[[:space:]]*$/\1/p' \
            | head -1
    )
    echo "${_port}"
}

hy_get_domain_port() {
    local _dom _port
    _dom=$(hy_get_domain)
    _port=$(hy_get_port)
    echo "${_dom}:${_port}"
}
