# shellcheck shell=bash
# panel/api.sh — Panel API bootstrap (MODE=1): superadmin, Reality keys,
# config-profile, node, host, sub-token

# Variant F (docs/ARCHITECTURE.md §6.1): three MODE-aware decisions
# shared by every co-located topology (MODE=1, MODE=F — both run Panel
# and Node on the same host; MODE=2 does not). Kept as three small pure
# functions rather than three more scattered `[ "$MODE" = ... ]`
# ternaries, so each reads as one named decision instead of an inline
# condition repeated at its call site, and each is unit-testable in
# isolation. $F_XRAY_VISION_PORT/$F_XRAY_XHTTP_PORT are defined in
# lib/panel/nginx/variant_f.sh — all panel/*.sh files are always sourced
# together via lib/panel.sh before any of them is called, so the
# reference resolves at call time regardless of source order (same
# precedent as the original $F_XRAY_PORT reference this replaces).
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
        echo "${F_XRAY_VISION_PORT:-18443}"
    else
        echo 443
    fi
}

# panel_reality_accept_proxy_protocol — MODE=F's nginx stream block
# applies `proxy_protocol on;` to its single server{} regardless of which
# map branch a connection resolves to (confirmed by runtime byte capture,
# docs/MULTI_PROTOCOL_L4_INGRESS_REVIEW.md § Runtime Verification), so
# the REALITY inbound behind it always receives a PROXY v1 preamble
# ahead of the ClientHello and must set sockopt.acceptProxyProtocol to
# parse it. MODE=1's REALITY inbound listens directly on public 443 with
# no nginx in front of it — no client sends it a PROXY header, so adding
# this there would break real handshakes rather than fix anything.
# MODE=2's REALITY inbound is a remote node reachable over the internet
# on its own dest, also with no local nginx stream in front — same
# reasoning as MODE=1. Echoes "true"/"false" (not a shell boolean) so
# the caller can pass it straight through jq's --argjson.
#
# Re-added 2026-08-31: this function and its JSON wiring were dropped a
# second time in 3d2d24c ("include new inbound ports"), bundled together
# with the legitimate Variant J INBOUNDS_JSON rewrite. It was not
# unused: variant_f.sh's stream{} server still unconditionally applies
# `proxy_protocol on;` to the xray_reality branch (see its own comment
# there), so the Steal (Vision/TCP) inbound must still declare
# acceptProxyProtocol for MODE=F or every REALITY handshake breaks.
# Deliberately NOT applied to StealXHTTP: variant_f.sh's :8443 stream
# server for XHTTP does not set proxy_protocol (documented there as
# intentional — Xray's XHTTP inbound JSON does not expect a PROXY
# preamble), so sending acceptProxyProtocol on that inbound would be
# wrong in the other direction.
panel_reality_accept_proxy_protocol() {
    local MODE="$1"
    if [ "$MODE" = "F" ]; then
        echo "true"
    else
        echo "false"
    fi
}

# panel_reality_xhttp_inbound_port — Variant J. XHTTP is MODE=F-only
# (public :8443 is only meaningful in Variant F's dual-public-port
# topology; MODE=1/2 have no :8443 story and are not asked to grow one
# here). Callers must still gate on `[ "$MODE" = "F" ]` themselves
# before using this — this function is a single source of truth for the
# port NUMBER, not for the MODE decision itself, mirroring how
# panel_reality_inbound_port() already separates "which port" from
# "should we even be here".
panel_reality_xhttp_inbound_port() {
    echo "${F_XRAY_XHTTP_PORT:-18444}"
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

    # Variant J: MODE=F gets a second inbound (StealXHTTP, network:xhttp)
    # in the SAME config-profile as Vision — confirmed against official
    # Remnawave docs (docs.rw, Config Profiles page) that multiple
    # inbounds per profile is the standard, documented way to do this,
    # not an unusual composition. Both inbounds intentionally share
    # privateKey/serverNames/shortIds (same REALITY identity — this is
    # what makes both reachable under the same domain on two different
    # public ports); only tag/port/network/xhttpSettings differ. Built
    # as a standalone JSON array (INBOUNDS_JSON) rather than inlined
    # into the profile template below, so MODE!=F's template is
    # untouched byte-for-byte aside from this substitution.
    local XHTTP_PATH="/$(openssl rand -hex 8)"
    local INBOUNDS_JSON
    if [ "$MODE" = "F" ]; then
        INBOUNDS_JSON=$(jq -n \
            --arg pk "$PRIV_KEY" --arg sid "$SHORT_ID" --arg dest "$DEST_VAL" --arg domain "$SELFSTEAL_DOMAIN" \
            --argjson vport "$(panel_reality_inbound_port "$MODE")" \
            --argjson xport "$(panel_reality_xhttp_inbound_port)" \
            --arg xpath "$XHTTP_PATH" \
            --argjson accept_pp "$(panel_reality_accept_proxy_protocol "$MODE")" \
            '[
                {tag:"Steal",port:$vport,protocol:"vless",settings:{clients:[],decryption:"none"},sniffing:{enabled:true,destOverride:["http","tls","quic"]},streamSettings:({network:"tcp",security:"reality",realitySettings:{show:false,xver:1,dest:$dest,spiderX:"",shortIds:[$sid],privateKey:$pk,serverNames:[$domain]}} + (if $accept_pp then {sockopt:{acceptProxyProtocol:true}} else {} end))},
                {tag:"StealXHTTP",port:$xport,protocol:"vless",settings:{clients:[],decryption:"none"},sniffing:{enabled:true,destOverride:["http","tls","quic"]},streamSettings:{network:"xhttp",security:"reality",realitySettings:{show:false,xver:1,dest:$dest,spiderX:"",shortIds:[$sid],privateKey:$pk,serverNames:[$domain]},xhttpSettings:{path:$xpath}}}
            ]' 2>/dev/null)
    else
        INBOUNDS_JSON=$(jq -n \
            --arg pk "$PRIV_KEY" --arg sid "$SHORT_ID" --arg dest "$DEST_VAL" --arg domain "$SELFSTEAL_DOMAIN" \
            --argjson vport "$(panel_reality_inbound_port "$MODE")" \
            --argjson accept_pp "$(panel_reality_accept_proxy_protocol "$MODE")" \
            '[{tag:"Steal",port:$vport,protocol:"vless",settings:{clients:[],decryption:"none"},sniffing:{enabled:true,destOverride:["http","tls","quic"]},streamSettings:({network:"tcp",security:"reality",realitySettings:{show:false,xver:1,dest:$dest,spiderX:"",shortIds:[$sid],privateKey:$pk,serverNames:[$domain]}} + (if $accept_pp then {sockopt:{acceptProxyProtocol:true}} else {} end))}]' 2>/dev/null)
    fi

    # Contract 13 (lookup-before-create, not always-create): reuse an
    # already-existing "StealConfig" profile by name if one is already
    # present, instead of always POSTing a new one. Existence alone is
    # the check — no content-diff/repair against an existing profile
    # that might not match what we'd generate fresh; that reconciliation
    # behaviour isn't defined anywhere and isn't invented here.
    # CFG_UUID/IBD_UUID/XHTTP_IBD_UUID инициализированы пустой строкой
    # явно: под server-manager.sh's `set -euo pipefail` (nounset) `local
    # x` без `=` трактуется как unbound до первого присваивания. Без
    # explicit-init обычный первый запуск (StealConfig ещё не
    # существует, EXISTING_PROFILE пуст, ветка присвоения ниже не
    # выполняется) приводил к `CFG_UUID: unbound variable` на строке с
    # `[ -n "$CFG_UUID" ]`.
    #
    # UUID lookup — по tag, не по индексу (`.inbounds[0]`/`.inbounds[1]`):
    # индекс хрупок при повторных запусках/будущих inbound'ах, tag
    # устойчив и однозначен. Одинаковый паттерн применяется что для уже
    # существующего профиля (EXISTING_PROFILE), что для только что
    # созданного (PROFILE_R) — единственное различие между этими двумя
    # веток ниже.
    local CFG_UUID="" IBD_UUID="" XHTTP_IBD_UUID=""
    local EXISTING_PROFILE
    EXISTING_PROFILE=$(panel_api "GET" "http://$API/api/config-profiles" "$TOKEN" | \
        jq -c '.response.configProfiles[]? | select(.name=="StealConfig")' 2>/dev/null | head -1)
    if [ -n "$EXISTING_PROFILE" ]; then
        CFG_UUID=$(echo "$EXISTING_PROFILE" | jq -r '.uuid // empty' 2>/dev/null)
        IBD_UUID=$(echo "$EXISTING_PROFILE" | jq -r '.inbounds[]? | select(.tag=="Steal") | .uuid' 2>/dev/null | head -1)
        [ "$MODE" = "F" ] && XHTTP_IBD_UUID=$(echo "$EXISTING_PROFILE" | jq -r '.inbounds[]? | select(.tag=="StealXHTTP") | .uuid' 2>/dev/null | head -1)
        # Известный, намеренно не автоматизируемый пробел: если профиль
        # StealConfig существует ЕЩЁ ДО Variant J (т.е. был создан до
        # появления StealXHTTP), IBD_UUID найдётся, а XHTTP_IBD_UUID —
        # нет. Автоматически PATCH-ить существующий профиль, добавляя
        # второй inbound, здесь НЕ реализовано — не подтверждено, что
        # Remnawave API поддерживает частичное добавление inbound'а к
        # уже существующему profile без побочных эффектов; такая
        # миграция требует отдельного явного решения, а не
        # предположения. Пользователь увидит warn ниже и должен будет
        # пересоздать профиль вручную (удалить старый StealConfig и
        # перезапустить установку), если хочет получить XHTTP.
        if [ "$MODE" = "F" ] && [ -z "$XHTTP_IBD_UUID" ]; then
            warn "StealConfig существует без StealXHTTP inbound (профиль создан до Variant J) — XHTTP не будет доступен, пока профиль не пересоздан вручную"
        fi
    fi

    if [ -n "$CFG_UUID" ] && [ -n "$IBD_UUID" ]; then
        ok "Конфиг-профиль StealConfig уже существует, используется существующий"
    else
        local PROFILE_R
        PROFILE_R=$(panel_api "POST" "http://$API/api/config-profiles" "$TOKEN" "$(jq -n \
            --arg name "StealConfig" --argjson inbounds "$INBOUNDS_JSON" \
            '{name:$name,config:{log:{loglevel:"warning"},dns:{queryStrategy:"UseIPv4",servers:[{address:"https://dns.google/dns-query",skipFallback:false}]},inbounds:$inbounds,outbounds:[{tag:"DIRECT",protocol:"freedom"},{tag:"BLOCK",protocol:"blackhole"}],routing:{rules:[{ip:["geoip:private"],type:"field",outboundTag:"BLOCK"},{type:"field",protocol:["bittorrent"],outboundTag:"BLOCK"}]}}}' 2>/dev/null)")

        CFG_UUID=$(echo "$PROFILE_R" | jq -r '.response.uuid // empty' 2>/dev/null)
        IBD_UUID=$(echo "$PROFILE_R" | jq -r '.response.inbounds[]? | select(.tag=="Steal") | .uuid' 2>/dev/null | head -1)
        [ "$MODE" = "F" ] && XHTTP_IBD_UUID=$(echo "$PROFILE_R" | jq -r '.response.inbounds[]? | select(.tag=="StealXHTTP") | .uuid' 2>/dev/null | head -1)
        [ -z "$CFG_UUID" ] && err "Ошибка создания конфиг-профиля"
        ok "Конфиг-профиль создан"
    fi

    # Variant J: activeInbounds/Squad must carry BOTH uuids when MODE=F
    # has a real XHTTP_IBD_UUID, or the new inbound exists in the
    # profile but stays unreachable by users (confirmed against
    # official Remnawave docs — a new inbound must be added to both the
    # Node's activeInbounds and the Internal Squad to actually be
    # usable, not just exist in the config-profile). Built once here and
    # reused by both the Node POST and the Squad PATCH loop below, so
    # there's exactly one place that decides "which inbounds are active"
    # instead of two copies of the same conditional.
    local ACTIVE_INBOUNDS_JSON
    if [ -n "$XHTTP_IBD_UUID" ]; then
        ACTIVE_INBOUNDS_JSON=$(jq -n --arg a "$IBD_UUID" --arg b "$XHTTP_IBD_UUID" '[$a,$b]')
    else
        ACTIVE_INBOUNDS_JSON=$(jq -n --arg a "$IBD_UUID" '[$a]')
    fi

    local NODE_ADDR
    [ "$MODE" = "2" ] && NODE_ADDR="$SELFSTEAL_DOMAIN" || NODE_ADDR="172.30.0.1"
    panel_api "POST" "http://$API/api/nodes" "$TOKEN" "$(jq -n \
        --arg na "$NODE_ADDR" --arg cu "$CFG_UUID" --argjson ai "$ACTIVE_INBOUNDS_JSON" \
        '{name:"Steal",address:$na,port:2222,configProfile:{activeConfigProfileUuid:$cu,activeInbounds:$ai},isTrafficTrackingActive:false,trafficLimitBytes:0,notifyPercent:0,trafficResetDay:31,excludedInbounds:[],countryCode:"XX",consumptionMultiplier:1.0}' 2>/dev/null)" >/dev/null 2>&1 \
        && ok "Нода создана" || warn "Ошибка создания ноды"

    panel_api "POST" "http://$API/api/hosts" "$TOKEN" "$(jq -n \
        --arg cu "$CFG_UUID" --arg iu "$IBD_UUID" --arg addr "$SELFSTEAL_DOMAIN" \
        '{inbound:{configProfileUuid:$cu,configProfileInboundUuid:$iu},remark:"Steal",address:$addr,port:443,path:"",sni:$addr,host:"",alpn:null,fingerprint:"chrome",allowInsecure:false,isDisabled:false,securityLayer:"DEFAULT"}' 2>/dev/null)" >/dev/null 2>&1 \
        && ok "Хост создан" || warn "Ошибка создания хоста"

    # Variant J: second Host for XHTTP, only when MODE=F actually
    # produced an XHTTP inbound. Unlike the Vision Host above (unchanged,
    # pre-existing, no lookup-before-create — out of scope to retrofit
    # here), this new path DOES look up an existing Host first: this is
    # new code being added under an explicit idempotency requirement, so
    # it follows the config-profile's own established lookup-before-
    # create pattern rather than the older, always-POST Vision pattern.
    # Match key: configProfileInboundUuid, the one field that uniquely
    # identifies "the Host for this specific inbound" regardless of
    # remark/address, which an operator could change later.
    # Host field shape follows the same pattern as the Vision Host
    # above (remark/fingerprint/allowInsecure/securityLayer field names
    # confirmed already correct from that existing, working call);
    # `path` is new here (XHTTP requires it, Vision leaves it empty) and
    # network/transport is deliberately NOT set as a separate field —
    # confirmed against official Remnawave docs (docs.rw, Hosts page):
    # "the Host inherits its configuration from the selected Inbound,
    # including... transport" — transport comes entirely from
    # configProfileInboundUuid, there is no separate Host-level field
    # for it to get wrong.
    if [ "$MODE" = "F" ] && [ -n "$XHTTP_IBD_UUID" ]; then
        local EXISTING_XHTTP_HOST
        EXISTING_XHTTP_HOST=$(panel_api "GET" "http://$API/api/hosts" "$TOKEN" | \
            jq -r --arg iu "$XHTTP_IBD_UUID" \
            '(.response.hosts // .response // [])[]? | select(.inbound.configProfileInboundUuid==$iu) | .uuid' 2>/dev/null | head -1)
        # NOTE: точное имя поля в ответе GET /api/hosts (`.response.hosts`
        # vs `.response` как плоский массив) не подтверждено напрямую —
        # jq-выражение выше пробует оба варианта через `//`, по аналогии
        # с уже существующим defensive-паттерном в этом файле
        # (`.response.configProfiles[]?`). Смотри итоговый отчёт,
        # раздел OPEN QUESTIONS.
        if [ -n "$EXISTING_XHTTP_HOST" ]; then
            ok "Хост для XHTTP уже существует, используется существующий"
        else
            panel_api "POST" "http://$API/api/hosts" "$TOKEN" "$(jq -n \
                --arg cu "$CFG_UUID" --arg iu "$XHTTP_IBD_UUID" --arg addr "$SELFSTEAL_DOMAIN" --arg xpath "$XHTTP_PATH" \
                '{inbound:{configProfileUuid:$cu,configProfileInboundUuid:$iu},remark:"StealXHTTP",address:$addr,port:8443,path:$xpath,sni:$addr,host:"",alpn:null,fingerprint:"chrome",allowInsecure:false,isDisabled:false,securityLayer:"DEFAULT"}' 2>/dev/null)" >/dev/null 2>&1 \
                && ok "Хост для XHTTP создан" || warn "Ошибка создания хоста для XHTTP"
        fi
    fi

    local SQUAD_UUIDS
    SQUAD_UUIDS=$(panel_api "GET" "http://$API/api/internal-squads" "$TOKEN" | \
        jq -r '.response.internalSquads[].uuid' 2>/dev/null || echo "")
    for su in $SQUAD_UUIDS; do
        [[ "$su" =~ ^[0-9a-f-]{36}$ ]] || continue
        panel_api "PATCH" "http://$API/api/internal-squads" "$TOKEN" \
            "$(jq -n --arg su "$su" --argjson ai "$ACTIVE_INBOUNDS_JSON" '{uuid:$su,inbounds:$ai}' 2>/dev/null)" >/dev/null 2>&1 || true
    done
    ok "Squad обновлён"

    # POST /api/tokens (confirmed against Remnawave's own OpenAPI schema
    # — Remnawave API v3.3.2 exactly, the version this project targets,
    # via CreateApiTokenBodyDto: {name: string(2-30), expiresInDays:
    # number(>=1) [both required], scopes: string[] [optional, defaults
    # to ["*"]]}. The prior payload here, {"tokenName":"..."},  used the
    # wrong field name entirely (no "tokenName" property exists in this
    # schema) and omitted the required "expiresInDays" — a NestJS/
    # class-validator 400 on both counts, which is the actual, now-
    # confirmed root cause of the empty .response.token. Response shape
    # is CreateApiTokenResponseDto: {response:{...,token:string}} — the
    # existing `.response.token` extraction below was already correct
    # and is unchanged. Endpoint still requires an admin JWT, which
    # $TOKEN already is (this project's payload bug, unrelated to auth).
    #
    # Re-restored 2026-08-31: this fix (originally 46d2e0c) was silently
    # reverted by 3d2d24c while that commit was adding the unrelated
    # Variant J inbound/host/squad wiring above. See provenance report.
    local SUB_TOKEN_RAW SUB_TOKEN_RC=0
    SUB_TOKEN_RAW=$(panel_api_status "POST" "http://$API/api/tokens" "$TOKEN" '{"name":"subscription-page","expiresInDays":365,"scopes":["*"]}') || SUB_TOKEN_RC=$?
    local SUB_TOKEN=""
    if [ "$SUB_TOKEN_RC" -ne 0 ]; then
        warn "Не удалось создать API-токен: сетевая ошибка при обращении к $API (transport failure)"
    else
        local SUB_TOKEN_STATUS="${SUB_TOKEN_RAW: -3}"
        local SUB_TOKEN_BODY="${SUB_TOKEN_RAW:0:${#SUB_TOKEN_RAW}-3}"
        SUB_TOKEN=$(echo "$SUB_TOKEN_BODY" | jq -r '.response.token // empty' 2>/dev/null)
        if [ -z "$SUB_TOKEN" ]; then
            local SUB_TOKEN_ERR_CODE SUB_TOKEN_ERR_MSG
            SUB_TOKEN_ERR_CODE=$(echo "$SUB_TOKEN_BODY" | jq -r '.errorCode // empty' 2>/dev/null)
            SUB_TOKEN_ERR_MSG=$(echo "$SUB_TOKEN_BODY" | jq -r '.message // empty' 2>/dev/null)
            warn "Не удалось создать API-токен автоматически: HTTP $SUB_TOKEN_STATUS${SUB_TOKEN_ERR_CODE:+ ($SUB_TOKEN_ERR_CODE)}${SUB_TOKEN_ERR_MSG:+ — $SUB_TOKEN_ERR_MSG}"
        fi
    fi
    [ -n "$SUB_TOKEN" ] && {
        sed -i "s|REMNAWAVE_API_TOKEN=PLACEHOLDER|REMNAWAVE_API_TOKEN=$SUB_TOKEN|g" \
            /opt/remnawave/docker-compose.yml
        ok "API-токен для Subscription Page"
    } || warn "Subscription Page останется без токена (REMNAWAVE_API_TOKEN=PLACEHOLDER) — создайте токен вручную в панели (Settings → API Tokens), подставьте его в /opt/remnawave/docker-compose.yml и перезапустите remnawave-subscription-page"

    docker compose down remnawave-subscription-page >/dev/null 2>&1 & spinner $! "Перезапуск Sub..."
    docker compose up -d remnawave-subscription-page >/dev/null 2>&1 & spinner $! "Запуск Sub..."
    docker compose down >/dev/null 2>&1 & spinner $! "Финальный рестарт..."
    docker compose up -d >/dev/null 2>&1 & spinner $! "Запуск..."
    ok "Стек перезапущен"
}
