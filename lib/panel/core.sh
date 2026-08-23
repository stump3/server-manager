# shellcheck shell=bash
# ═══════════════════════════════════════════════════════════════════
# ████████████████████  PANEL EXTENSIONS  ██████████████████████████
# ═══════════════════════════════════════════════════════════════════


# ── API утилиты ───────────────────────────────────────────────────

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
    # Атомарная запись с owner-only правами (contract 7: secrets never left
    # world-readable) — тот же temp-file+mv+chmod паттерн, что и для
    # $HYSTERIA_CONFIG (lib/hy2/users.sh).
    local _tok_tmp; _tok_tmp=$(mktemp)
    echo "$token" > "$_tok_tmp" \
        && mv "$_tok_tmp" "$PANEL_TOKEN_FILE" && chmod 600 "$PANEL_TOKEN_FILE" \
        || rm -f "$_tok_tmp"
    ok "Авторизация успешна"
    echo "$token"
}
