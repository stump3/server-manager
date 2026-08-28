# shellcheck shell=bash
# panel/api.sh — Panel API bootstrap (MODE=1): superadmin, Reality keys,
# config-profile, node, host, sub-token

# Variant F (docs/ARCHITECTURE.md §6.1): three MODE-aware decisions
# shared by every co-located topology (MODE=1, MODE=F — both run Panel
# and Node on the same host; MODE=2 does not). Kept as three small pure
# functions rather than three more scattered `[ "$MODE" = ... ]`
# ternaries, so each reads as one named decision instead of an inline
# condition repeated at its call site, and each is unit-testable in
# isolation. $F_XRAY_PORT is defined in lib/panel/nginx/config.sh —
# both files are always sourced together via lib/panel.sh before either
# is called, so the reference resolves at call time regardless of
# source order.
panel_reality_needs_2222_ufw_rule() {
    local MODE="$1"
    [ "$MODE" = "1" ] || [ "$MODE" = "F" ]
}

panel_reality_dest_val() {
    local MODE="$1" SELFSTEAL_DOMAIN="$2"
    if [ "$MODE" = "1" ] || [ "$MODE" = "F" ]; then
        echo '/dev/shm/nginx.sock'
    else
        echo "${SELFSTEAL_DOMAIN}:443"
    fi
}

panel_reality_inbound_port() {
    local MODE="$1"
    if [ "$MODE" = "F" ]; then
        echo "${F_XRAY_PORT:-8443}"
    else
        echo 443
    fi
}

panel_setup_api() {
    local SUPERADMIN_USER="$1"
    local SUPERADMIN_PASS="$2"
    local SELFSTEAL_DOMAIN="$3"
    local MODE="$4"

    cd /opt/remnawave
    panel_reality_needs_2222_ufw_rule "$MODE" && \
        ufw allow from 172.30.0.0/16 to any port 2222 proto tcp >/dev/null 2>&1

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

    # panel_setup_api() runs on every install AND on any re-run against
    # an already-provisioned Panel (reinstall/repair). POST
    # /api/auth/register only ever succeeds once — the superadmin
    # already existing is an expected re-run condition, not a failure.
    # Confirmed against a real Remnawave backend: a repeat
    # /api/auth/register call returns HTTP 403 with body
    # {"message":"Forbidden","errorCode":"E000"} — a generic guard-level
    # rejection (an "admin already provisioned" guard throwing a bare
    # ForbiddenException), distinct from the ERRORS registry's own
    # FORBIDDEN/A068 business-logic error code. panel_api() itself
    # doesn't expose the HTTP status (Contract 4's own reasoning — see
    # panel_api_status()'s doc comment in lib/common/network.sh), so
    # this one call uses panel_api_status() instead, same precedent
    # already used by lib/panel/node/api.sh's rollback helpers. Every
    # other call in this function is untouched and keeps using
    # panel_api() exactly as before.
    local REG_RAW REG_RC=0
    REG_RAW=$(panel_api_status "POST" "http://$API/api/auth/register" "" \
        "{\"username\":\"$SUPERADMIN_USER\",\"password\":\"$SUPERADMIN_PASS\"}") || REG_RC=$?
    [ "$REG_RC" -ne 0 ] && err "Ошибка регистрации: сетевая ошибка (transport failure)"
    local REG_STATUS="${REG_RAW: -3}"
    local REG="${REG_RAW:0:${#REG_RAW}-3}"

    local TOKEN
    TOKEN=$(echo "$REG" | jq -r '.response.accessToken // empty' 2>/dev/null)

    if [ -z "$TOKEN" ]; then
        # Only the specific, confirmed "already registered" signature
        # (HTTP 403 + errorCode E000) falls through to login. Any other
        # failure (network hiccup already handled above, validation
        # error, unrelated 403/500, malformed body) still aborts via
        # err() exactly as before — never silently proceeds through
        # login on an error we haven't confirmed the meaning of.
        local REG_ERR_CODE
        REG_ERR_CODE=$(echo "$REG" | jq -r '.errorCode // empty' 2>/dev/null)
        if [ "$REG_STATUS" = "403" ] && [ "$REG_ERR_CODE" = "E000" ]; then
            info "Суперадмин уже зарегистрирован — выполняется вход вместо повторной регистрации"
            local LOGIN_R
            LOGIN_R=$(panel_api "POST" "http://$API/api/auth/login" "" \
                "{\"username\":\"$SUPERADMIN_USER\",\"password\":\"$SUPERADMIN_PASS\"}")
            TOKEN=$(echo "$LOGIN_R" | jq -r '.response.accessToken // empty' 2>/dev/null)
            [ -z "$TOKEN" ] && err "Ошибка входа существующим суперадмином: $LOGIN_R"
            ok "Вход выполнен: $SUPERADMIN_USER"
        else
            err "Ошибка регистрации: $REG"
        fi
    else
        ok "Суперадмин: $SUPERADMIN_USER"
    fi

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
    DEST_VAL=$(panel_reality_dest_val "$MODE" "$SELFSTEAL_DOMAIN")

    # Contract 13 (lookup-before-create, not always-create): reuse an
    # already-existing "StealConfig" profile by name if one is already
    # present, instead of always POSTing a new one. Existence alone is
    # the check — no content-diff/repair against an existing profile
    # that might not match what we'd generate fresh; that reconciliation
    # behaviour isn't defined anywhere and isn't invented here.
    # CFG_UUID/IBD_UUID инициализированы пустой строкой явно: под
    # server-manager.sh's `set -euo pipefail` (nounset) `local x` без `=`
    # трактуется как unbound до первого присваивания. Без explicit-init
    # обычный первый запуск (StealConfig ещё не существует,
    # EXISTING_PROFILE пуст, ветка присвоения ниже не выполняется)
    # приводил к `CFG_UUID: unbound variable` на строке с `[ -n "$CFG_UUID" ]`.
    local CFG_UUID="" IBD_UUID=""
    local EXISTING_PROFILE
    EXISTING_PROFILE=$(panel_api "GET" "http://$API/api/config-profiles" "$TOKEN" | \
        jq -c '.response.configProfiles[]? | select(.name=="StealConfig")' 2>/dev/null | head -1)
    if [ -n "$EXISTING_PROFILE" ]; then
        CFG_UUID=$(echo "$EXISTING_PROFILE" | jq -r '.uuid // empty' 2>/dev/null)
        IBD_UUID=$(echo "$EXISTING_PROFILE" | jq -r '.inbounds[0].uuid // empty' 2>/dev/null)
    fi

    if [ -n "$CFG_UUID" ] && [ -n "$IBD_UUID" ]; then
        ok "Конфиг-профиль StealConfig уже существует, используется существующий"
    else
        local PROFILE_R
        PROFILE_R=$(panel_api "POST" "http://$API/api/config-profiles" "$TOKEN" "$(jq -n \
            --arg name "StealConfig" --arg domain "$SELFSTEAL_DOMAIN" \
            --arg pk "$PRIV_KEY"     --arg sid "$SHORT_ID" --arg dest "$DEST_VAL" \
            --argjson port "$(panel_reality_inbound_port "$MODE")" \
            '{name:$name,config:{log:{loglevel:"warning"},dns:{queryStrategy:"UseIPv4",servers:[{address:"https://dns.google/dns-query",skipFallback:false}]},inbounds:[{tag:"Steal",port:$port,protocol:"vless",settings:{clients:[],decryption:"none"},sniffing:{enabled:true,destOverride:["http","tls","quic"]},streamSettings:{network:"tcp",security:"reality",realitySettings:{show:false,xver:1,dest:$dest,spiderX:"",shortIds:[$sid],privateKey:$pk,serverNames:[$domain]}}}],outbounds:[{tag:"DIRECT",protocol:"freedom"},{tag:"BLOCK",protocol:"blackhole"}],routing:{rules:[{ip:["geoip:private"],type:"field",outboundTag:"BLOCK"},{type:"field",protocol:["bittorrent"],outboundTag:"BLOCK"}]}}}' 2>/dev/null)")

        CFG_UUID=$(echo "$PROFILE_R" | jq -r '.response.uuid // empty' 2>/dev/null)
        IBD_UUID=$(echo "$PROFILE_R" | jq -r '.response.inbounds[0].uuid // empty' 2>/dev/null)
        [ -z "$CFG_UUID" ] && err "Ошибка создания конфиг-профиля"
        ok "Конфиг-профиль создан"
    fi

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
