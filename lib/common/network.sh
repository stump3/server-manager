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

# panel_api_status METHOD URL [TOKEN] [DATA]
#
# HTTP-status-aware variant of panel_api(), for callers that must tell
# transport failure apart from an actual HTTP response — including its
# status code (Contract 4: "curl exit 0, HTTP 2xx, and a semantically
# valid API response body are three independent checks"). panel_api()
# itself is untouched and keeps its exact legacy stdout/exit-code
# semantics for all of its existing callers; this is a separate,
# narrow-purpose helper, not a replacement.
#
# Deliberately NOT using `--fail`/`--fail-with-body`: this project's
# stated minimum OS (README.md: "Ubuntu 20.04+ / Debian 11+") ships
# curl 7.68.0 / 7.74.0 respectively — `--fail-with-body` needs curl
# 7.76+ and would silently be unavailable there. `-w '%{http_code}'` has
# no such version constraint.
#
# Return convention: stdout is BODY immediately followed by the 3-digit
# HTTP status code, with NO separator between them — exactly what
# `curl -w '%{http_code}'` already produces on its own, nothing added.
# This is deliberate: any inserted delimiter (newline, colon, custom
# marker) could in principle collide with body content on an unusual
# response (multiline, or a body that happens to contain the marker
# text); curl's own %{http_code} is documented to always be exactly 3
# ASCII digits, so callers can extract it via pure bash parameter
# expansion — no external parser, no pattern matching, safe with an
# empty body, a multiline body, or a body ending in a newline:
#
#   local raw; raw=$(panel_api_status "DELETE" "$url" "$token") || rc=$?
#   local http_status="${raw: -3}"
#   local body="${raw:0:${#raw}-3}"
#
# Exit code: curl's own exit code (0 = a request/response cycle
# completed, regardless of HTTP status; non-zero = transport/DNS/
# connection failure — curl never obtained an HTTP response at all).
# On transport failure curl's own %{http_code} write-out is documented
# to yield "000", but treat that as informational only — prefer this
# function's exit code for the transport-vs-HTTP distinction, since
# exit code is curl's authoritative signal, not a magic string.
panel_api_status() {
    local method="$1" url="$2" token="${3:-}" data="${4:-}"
    local headers=(
        -H "Content-Type: application/json"
        -H "X-Forwarded-For: 127.0.0.1"
        -H "X-Forwarded-Proto: https"
        -H "X-Remnawave-Client-Type: browser"
    )
    [ -n "$token" ] && headers+=(-H "Authorization: Bearer $token")
    if [ -n "$data" ]; then
        curl -s -w '%{http_code}' -X "$method" "$url" "${headers[@]}" -d "$data"
    else
        curl -s -w '%{http_code}' -X "$method" "$url" "${headers[@]}"
    fi
}
