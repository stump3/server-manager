# shellcheck shell=bash
#
# lib/panel/node/api.sh — регистрация Remote Node в Panel API + health-check.
#
# Источник паттернов (endpoint'ы, jq-структуры) — panel_setup_api() в
# lib/panel/install.sh, MODE=1-ветка. Ничего не придумано заново: та же
# последовательность config-profile → node → host → squad, тот же формат
# JSON, тот же способ вызова panel_api() (lib/common/network.sh).
#
# Отличия от panel_setup_api(), обоснованные тем, что этот код выполняется
# ПОЗЖЕ, отдельной операцией, когда Panel уже установлена и суперадмин уже
# существует:
#   - НЕ вызывает /api/auth/register (создал бы дубликат суперадмина/ошибку)
#   - вызывает /api/auth/login с уже существующими credentials
#     ⚠ ПРЕДПОЛОЖЕНИЕ: этот endpoint не встречается больше нигде в текущем
#       коде server-manager, поэтому его точная сигнатура НЕ подтверждена
#       прямым чтением исходников Remnawave Panel в рамках этой сессии —
#       строится по аналогии с /api/auth/register (тот же request/response
#       shape: {username,password} → response.accessToken). Если endpoint
#       окажется иным — это первое место для проверки при реальном тесте.
#   - НЕ пересоздаёт /api/tokens (subscription-page) и НЕ трогает
#     REMNAWAVE_API_TOKEN — это Panel-стек-специфичная операция, к Remote
#     Node отношения не имеет
#   - DEST_VAL всегда '/dev/shm/nginx.sock' (Remote Node всегда в
#     unix-socket-топологии — см. предыдущие раунды исследования,
#     self-reference ${SELFSTEAL_DOMAIN}:443 семантически некорректен)
#   - NODE_ADDR передаётся явным параметром (IP ноды, не домен — см.
#     инвариант "NODE_ADDR ≠ SELFSTEAL_DOMAIN" из задания)

# panel_node_register SUPERADMIN_USER SUPERADMIN_PASS SELFSTEAL_DOMAIN NODE_ADDR
# Печатает "TOKEN NODE_UUID" одной строкой в stdout при успехе, ничего — при ошибке.
panel_node_register() {
    local SUPERADMIN_USER="$1"
    local SUPERADMIN_PASS="$2"
    local SELFSTEAL_DOMAIN="$3"
    local NODE_ADDR="$4"
    local API="127.0.0.1:3000"

    local LOGIN_R TOKEN
    LOGIN_R=$(panel_api "POST" "http://$API/api/auth/login" "" \
        "$(jq -n --arg u "$SUPERADMIN_USER" --arg p "$SUPERADMIN_PASS" '{username:$u,password:$p}' 2>/dev/null)")
    TOKEN=$(echo "$LOGIN_R" | jq -r '.response.accessToken // empty' 2>/dev/null)
    if [ -z "$TOKEN" ]; then
        warn "Не удалось авторизоваться в Panel API: $LOGIN_R"
        return 1
    fi

    local KEYS_R PRIV_KEY
    KEYS_R=$(panel_api "GET" "http://$API/api/system/tools/x25519/generate" "$TOKEN")
    PRIV_KEY=$(echo "$KEYS_R" | jq -r '.response.keypairs[0].privateKey // empty' 2>/dev/null)
    [ -z "$PRIV_KEY" ] && { warn "Ошибка генерации Reality-ключей"; return 1; }

    local SHORT_ID DEST_VAL
    SHORT_ID=$(openssl rand -hex 8)
    DEST_VAL='/dev/shm/nginx.sock'

    local PROFILE_R CFG_UUID IBD_UUID
    PROFILE_R=$(panel_api "POST" "http://$API/api/config-profiles" "$TOKEN" "$(jq -n \
        --arg name "RemoteNode-${SELFSTEAL_DOMAIN}" --arg domain "$SELFSTEAL_DOMAIN" \
        --arg pk "$PRIV_KEY"     --arg sid "$SHORT_ID" --arg dest "$DEST_VAL" \
        '{name:$name,config:{log:{loglevel:"warning"},dns:{queryStrategy:"UseIPv4",servers:[{address:"https://dns.google/dns-query",skipFallback:false}]},inbounds:[{tag:"Steal",port:443,protocol:"vless",settings:{clients:[],decryption:"none"},sniffing:{enabled:true,destOverride:["http","tls","quic"]},streamSettings:{network:"tcp",security:"reality",realitySettings:{show:false,xver:1,dest:$dest,spiderX:"",shortIds:[$sid],privateKey:$pk,serverNames:[$domain]}}}],outbounds:[{tag:"DIRECT",protocol:"freedom"},{tag:"BLOCK",protocol:"blackhole"}],routing:{rules:[{ip:["geoip:private"],type:"field",outboundTag:"BLOCK"},{type:"field",protocol:["bittorrent"],outboundTag:"BLOCK"}]}}}' 2>/dev/null)")
    CFG_UUID=$(echo "$PROFILE_R" | jq -r '.response.uuid // empty' 2>/dev/null)
    IBD_UUID=$(echo "$PROFILE_R" | jq -r '.response.inbounds[0].uuid // empty' 2>/dev/null)
    if [ -z "$CFG_UUID" ] || [ -z "$IBD_UUID" ]; then
        warn "Ошибка создания конфиг-профиля: $PROFILE_R"
        return 1
    fi

    local NODE_R NODE_UUID
    NODE_R=$(panel_api "POST" "http://$API/api/nodes" "$TOKEN" "$(jq -n \
        --arg name "RemoteNode-${SELFSTEAL_DOMAIN}" --arg na "$NODE_ADDR" \
        --arg cu "$CFG_UUID" --arg iu "$IBD_UUID" \
        '{name:$name,address:$na,port:2222,configProfile:{activeConfigProfileUuid:$cu,activeInbounds:[$iu]},isTrafficTrackingActive:false,trafficLimitBytes:0,notifyPercent:0,trafficResetDay:31,excludedInbounds:[],countryCode:"XX",consumptionMultiplier:1.0}' 2>/dev/null)")
    NODE_UUID=$(echo "$NODE_R" | jq -r '.response.uuid // empty' 2>/dev/null)
    if [ -z "$NODE_UUID" ]; then
        warn "Ошибка создания ноды: $NODE_R"
        return 1
    fi
    ok "Нода зарегистрирована в Panel (uuid: $NODE_UUID)"

    panel_api "POST" "http://$API/api/hosts" "$TOKEN" "$(jq -n \
        --arg cu "$CFG_UUID" --arg iu "$IBD_UUID" --arg addr "$SELFSTEAL_DOMAIN" \
        '{inbound:{configProfileUuid:$cu,configProfileInboundUuid:$iu},remark:"RemoteNode",address:$addr,port:443,path:"",sni:$addr,host:"",alpn:null,fingerprint:"chrome",allowInsecure:false,isDisabled:false,securityLayer:"DEFAULT"}' 2>/dev/null)" >/dev/null 2>&1 \
        && ok "Хост создан" || warn "Ошибка создания хоста"

    local SQUAD_UUIDS su
    SQUAD_UUIDS=$(panel_api "GET" "http://$API/api/internal-squads" "$TOKEN" | \
        jq -r '.response.internalSquads[].uuid' 2>/dev/null || echo "")
    for su in $SQUAD_UUIDS; do
        [[ "$su" =~ ^[0-9a-f-]{36}$ ]] || continue
        panel_api "PATCH" "http://$API/api/internal-squads" "$TOKEN" \
            "$(jq -n --arg su "$su" --arg iu "$IBD_UUID" '{uuid:$su,inbounds:[$iu]}' 2>/dev/null)" >/dev/null 2>&1 || true
    done
    ok "Squad обновлён"

    echo "${TOKEN} ${NODE_UUID}"
}

# panel_node_wait_connected TOKEN NODE_UUID [max_attempts]
# Опрашивает GET /api/nodes/{uuid} до isConnected=true либо истечения попыток.
panel_node_wait_connected() {
    local TOKEN="$1"
    local NODE_UUID="$2"
    local MAX_ATTEMPTS="${3:-10}"
    local API="127.0.0.1:3000"
    local attempt=0 connected="false" msg=""

    info "Ожидание подключения ноды к панели..."
    while [ "$attempt" -lt "$MAX_ATTEMPTS" ]; do
        local R
        R=$(panel_api "GET" "http://$API/api/nodes/$NODE_UUID" "$TOKEN" 2>/dev/null)
        connected=$(echo "$R" | jq -r '.response.isConnected // false' 2>/dev/null)
        msg=$(echo "$R" | jq -r '.response.lastStatusMessage // empty' 2>/dev/null)
        [ "$connected" = "true" ] && { ok "Нода подключена (isConnected=true)"; return 0; }
        attempt=$((attempt+1))
        [ "$attempt" -lt "$MAX_ATTEMPTS" ] && sleep 6
    done
    warn "Нода не подтвердила подключение за отведённое время${msg:+ (последнее сообщение: $msg)}"
    warn "Проверьте вручную: docker compose logs remnanode на удалённом сервере"
    return 1
}

# panel_node_fetch_secret SUPERADMIN_USER SUPERADMIN_PASS
# Логинится и возвращает Node authentication secret (GET /api/keygen,
# response.secretKey — НЕ Reality X25519-ключ, см. заголовок файла) через
# stdout. Пусто при ошибке.
panel_node_fetch_secret() {
    local SUPERADMIN_USER="$1"
    local SUPERADMIN_PASS="$2"
    local API="127.0.0.1:3000"

    local LOGIN_R TOKEN
    LOGIN_R=$(panel_api "POST" "http://$API/api/auth/login" "" \
        "$(jq -n --arg u "$SUPERADMIN_USER" --arg p "$SUPERADMIN_PASS" '{username:$u,password:$p}' 2>/dev/null)")
    TOKEN=$(echo "$LOGIN_R" | jq -r '.response.accessToken // empty' 2>/dev/null)
    [ -z "$TOKEN" ] && return 1

    local PUB_R
    PUB_R=$(panel_api "GET" "http://$API/api/keygen" "$TOKEN")
    echo "$PUB_R" | jq -r '.response.secretKey // empty' 2>/dev/null
}
