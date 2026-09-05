# shellcheck shell=bash
# panel/api.sh — Panel API bootstrap (MODE=1): superadmin, Reality keys,
# config-profile, node, host, sub-token

# Variant F/J (docs/ARCHITECTURE.md §6.1): four MODE-aware decisions
# shared by every co-located topology (MODE=1, MODE=F, MODE=J — all
# three run Panel and Node on the same host; MODE=2 does not). Kept as
# four small pure functions rather than scattered `[ "$MODE" = ... ]`
# ternaries, so each reads as one named decision instead of an inline
# condition repeated at its call site, and each is unit-testable in
# isolation. $F_XRAY_VISION_PORT is defined in lib/panel/nginx/variant_f.sh;
# $J_XRAY_VISION_PORT/$J_XRAY_XHTTP_PORT are defined in
# lib/panel/nginx/variant_j.sh — all panel/*.sh files are always sourced
# together via lib/panel.sh before any of them is called, so the
# reference resolves at call time regardless of source order.
#
# FIXED 2026-08-31 (F/J port-wiring audit): panel_reality_inbound_port()'s
# MODE=F branch previously read $F_XRAY_VISION_PORT with a fallback
# default of 18443 — but F_XRAY_VISION_PORT was never actually defined
# anywhere in the tree (variant_f.sh still defined the old $F_XRAY_PORT
# name), so every MODE=F install silently fell through to that fallback
# and generated a Vision inbound listening on 18443 while variant_f.sh's
# nginx stream{} unconditionally forwards to 127.0.0.1:8443 — a total
# port mismatch, confirmed by grep (no other definition site existed).
# Fixed by renaming variant_f.sh's F_XRAY_PORT to F_XRAY_VISION_PORT
# (same value, 8443) so the two files agree, and removing the
# now-misleading 18443 fallback here.
panel_reality_needs_2222_ufw_rule() {
    local MODE="$1"
    [ "$MODE" = "1" ] || [ "$MODE" = "F" ] || [ "$MODE" = "J" ]
}

panel_reality_dest_val() {
    local MODE="$1" SELFSTEAL_DOMAIN="$2"
    if [ "$MODE" = "1" ] || [ "$MODE" = "F" ] || [ "$MODE" = "J" ]; then
        echo '/dev/shm/nginx.sock'
    else
        echo "${SELFSTEAL_DOMAIN}:443"
    fi
}

panel_reality_inbound_port() {
    local MODE="$1"
    case "$MODE" in
        F) echo "${F_XRAY_VISION_PORT:-8443}" ;;
        J) echo "${J_XRAY_VISION_PORT:-18443}" ;;
        *) echo 443 ;;
    esac
}

# panel_reality_accept_proxy_protocol — MODE=F's and MODE=J's nginx
# stream blocks both apply `proxy_protocol on;` to the server{} that
# routes their public :443 (confirmed by runtime byte capture for F,
# docs/MULTI_PROTOCOL_L4_INGRESS_REVIEW.md § Runtime Verification; J's
# :443 server{} in variant_j.sh applies it identically, same map-based
# single-server{} shape), so the Vision/REALITY inbound behind either
# variant always receives a PROXY v1 preamble ahead of the ClientHello
# and must set sockopt.acceptProxyProtocol to parse it. MODE=1's REALITY
# inbound listens directly on public 443 with no nginx in front of it —
# no client sends it a PROXY header, so adding this there would break
# real handshakes rather than fix anything. MODE=2's REALITY inbound is
# a remote node reachable over the internet on its own dest, also with
# no local nginx stream in front — same reasoning as MODE=1. Echoes
# "true"/"false" (not a shell boolean) so the caller can pass it
# straight through jq's --argjson.
#
# RESOLVED 2026-08-31 (was DECISION REQUIRED during the initial F/J
# port-wiring audit): variant_j.sh's :$J_XHTTP_PUBLIC_PORT server{} was
# found to also set `proxy_protocol on;`, contradicting this function's
# assumption that nothing sends XHTTP a PROXY preamble. Confirmed
# (Natalie): that was a bug in variant_j.sh, not a requirement — XHTTP's
# inbound is not meant to receive a PROXY preamble. Fixed by removing
# proxy_protocol from that server{} block rather than adding
# acceptProxyProtocol here; StealXHTTP correctly never receives an
# accept_pp value from this function (see j.json, which only wires
# $accept_pp onto the Steal/Vision inbound).
panel_reality_accept_proxy_protocol() {
    local MODE="$1"
    if [ "$MODE" = "F" ] || [ "$MODE" = "J" ]; then
        echo "true"
    else
        echo "false"
    fi
}

# panel_reality_xhttp_inbound_port — meaningful only when XHTTP is
# enabled for this profile (MODE=J always; MODE=F when F_XHTTP_ENABLE=1;
# see XHTTP_ENABLE normalization in panel_setup_api()). Callers must
# still gate on the caller's own XHTTP_ENABLE decision themselves before
# using this — this function is a single source of truth for the port
# NUMBER, not for the enable decision itself, mirroring how
# panel_reality_inbound_port() already separates "which port" from
# "should we even be here".
#
# FIXED 2026-09-05 (F+XHTTP): made MODE-aware. Previously always
# returned $J_XRAY_XHTTP_PORT (18444) unconditionally — correct for
# MODE=J, but wrong for MODE=F+XHTTP_ENABLE=1, which needs its own,
# independent port (F_XRAY_XHTTP_PORT=19444, lib/panel/nginx/
# variant_f.sh) — silently reusing 18444 there would have made F+XHTTP's
# Xray inbound listen on a port nginx's own F+XHTTP upstream
# (xray_xhttp_f -> 127.0.0.1:19444) never forwards to, a total port
# mismatch of exactly the kind panel_reality_inbound_port()'s own FIXED
# comment above already warns about for Vision.
panel_reality_xhttp_inbound_port() {
    local MODE="$1"
    case "$MODE" in
        F) echo "${F_XRAY_XHTTP_PORT:-19444}" ;;
        *) echo "${J_XRAY_XHTTP_PORT:-18444}" ;;
    esac
}

# panel_reality_listen_addr — PRE-EXISTING BUG FIX (bind-correctness pass,
# separate from and prior to any XHTTP_ENABLE/MODE decoupling work): the
# Steal/StealXHTTP inbound JSON templates (f.json/j.json) never set a
# "listen" key at all, so Xray binds the wildcard address (0.0.0.0/::) —
# confirmed against Xray-core's own docs ("::" is equivalent to "0.0.0.0";
# both listen on IPv4 and IPv6 simultaneously when no listen address is
# given). variant_f.sh's and variant_j.sh's own header comments both
# describe these inbounds as "loopback-only, reached only via nginx's
# stream{} proxy_pass" — that description was aspirational, not enforced:
# nginx's upstream blocks only ever *connect* to 127.0.0.1, but nothing
# stopped Xray from also accepting a direct connection from the public
# internet on the same port, bypassing nginx (and its proxy_protocol
# wrapping) entirely. A raw external connection there still can't
# complete a REALITY handshake without the PROXY v1 preamble Xray expects
# first, so this was not an exploitable bypass, but the port was
# genuinely reachable at the OS/socket level, which is a real
# fingerprinting exposure the "loopback-only" comment didn't actually
# deliver on.
#
# Scope: MODE=1/2's Steal inbound is deliberately DIFFERENT — it listens
# directly on public :443 with no nginx in front of it at all (see
# panel_reality_dest_val()'s own doc comment), so it must keep binding
# the wildcard address; giving it "127.0.0.1" would break every MODE=1/2
# REALITY handshake, not fix anything. Only MODE=F/J's Steal/StealXHTTP
# inbounds sit behind nginx's stream{} router and are meant to be
# loopback-only, so only those get an explicit "listen" value here.
# Echoes an empty string for MODE=1/2 (meaning render.sh emits no
# "listen" key at all — exact current behavior, unchanged) and
# "127.0.0.1" for MODE=F/J.
panel_reality_listen_addr() {
    local MODE="$1"
    if [ "$MODE" = "F" ] || [ "$MODE" = "J" ]; then
        echo "127.0.0.1"
    else
        echo ""
    fi
}

panel_setup_api() {
    local SUPERADMIN_USER="$1"
    local SUPERADMIN_PASS="$2"
    local SELFSTEAL_DOMAIN="$3"
    local MODE="$4"
    # XHTTP_ENABLE — OPTIONAL 5th arg, "0"/"1". Backward compatible: any
    # existing 4-arg call site keeps the original MODE=J-implies-1
    # normalization below unchanged.
    #
    # FIXED 2026-09-05 (F+XHTTP): previously always self-derived purely
    # from `[ "$MODE" = "J" ]`, which made MODE=F + "XHTTP wanted" from
    # lib/panel/cli.sh's new F+XHTTP prompt unreachable here — the caller
    # (panel_install()) could set F_XHTTP_ENABLE=1 all it wanted, this
    # function would still only ever produce a single-inbound (Steal-only)
    # profile for MODE=F, since it never looked at anything but MODE.
    # Explicit arg takes precedence when the caller supplies one; when
    # omitted, the exact original MODE=J->1 normalization applies, so
    # every pre-existing 4-arg caller sees byte-identical behavior.
    local XHTTP_ENABLE="${5:-}"
    if [ -z "$XHTTP_ENABLE" ]; then
        XHTTP_ENABLE="0"
        [ "$MODE" = "J" ] && XHTTP_ENABLE="1"
    fi

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

    # XHTTP_ENABLE=1 gets a second inbound (StealXHTTP, network:xhttp) in
    # the SAME config-profile as Vision — confirmed against official
    # Remnawave docs (docs.rw, Config Profiles page) that multiple
    # inbounds per profile is the standard, documented way to do this,
    # not an unusual composition. Both inbounds intentionally share
    # privateKey/serverNames/shortIds (same REALITY identity — this is
    # what makes both reachable under the same domain on two different
    # public ports); only tag/port/network/xhttpSettings differ.
    #
    # FIXED 2026-08-31 (F/J port-wiring audit): this used to be two
    # inline `jq -n '[...]'` blocks here, gated on `[ "$MODE" = "F" ]` —
    # i.e. choosing Variant F (meant to stay a single-inbound topology,
    # see variant_f.sh) was what actually produced the dual-inbound
    # Vision+XHTTP profile, while Variant J (the variant whose nginx
    # topology, variant_j.sh, actually has the second public port and
    # loopback wiring for XHTTP) got F's plain single-inbound shape
    # instead — the two variants' API and nginx layers disagreed with
    # each other. Replaced with a single call to
    # panel_xray_render_inbounds() (lib/panel/xray/templates/render.sh,
    # now wired into lib/panel.sh's loader — it previously wasn't
    # sourced anywhere and did not exist at runtime), whose own dispatch
    # (XHTTP_ENABLE=1 -> j.json dual-inbound, XHTTP_ENABLE=0 -> f.json
    # single-inbound) is the corrected gating. XHTTP_ENABLE=1 is
    # currently only reachable via MODE=J (normalized once above, in
    # panel_setup_api()) — see render.sh's own header comment for the
    # full XHTTP_ENABLE/TELEMT_COLOCATE architecture this is Phase A of.
    # f.json/j.json were confirmed semantically identical to the old
    # inline blocks for their respective shapes before this switch (see
    # xray/templates/ header comments for the $-variable contract).
    local XHTTP_PATH="/$(openssl rand -hex 8)"
    local INBOUNDS_JSON
    INBOUNDS_JSON=$(panel_xray_render_inbounds "$MODE" "$PRIV_KEY" "$SHORT_ID" "$DEST_VAL" "$SELFSTEAL_DOMAIN" \
        "$(panel_reality_inbound_port "$MODE")" \
        "$(panel_reality_xhttp_inbound_port "$MODE")" \
        "$XHTTP_PATH" \
        "$(panel_reality_accept_proxy_protocol "$MODE")" \
        "$XHTTP_ENABLE" \
        "$(panel_reality_listen_addr "$MODE")")
    [ -z "$INBOUNDS_JSON" ] && err "Ошибка генерации Xray inbounds JSON (panel_xray_render_inbounds)"

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
        [ "$XHTTP_ENABLE" = "1" ] && XHTTP_IBD_UUID=$(echo "$EXISTING_PROFILE" | jq -r '.inbounds[]? | select(.tag=="StealXHTTP") | .uuid' 2>/dev/null | head -1)
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
        if [ "$XHTTP_ENABLE" = "1" ] && [ -z "$XHTTP_IBD_UUID" ]; then
            warn "StealConfig существует без StealXHTTP inbound (профиль создан до включения XHTTP) — XHTTP не будет доступен, пока профиль не пересоздан вручную"
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
        [ "$XHTTP_ENABLE" = "1" ] && XHTTP_IBD_UUID=$(echo "$PROFILE_R" | jq -r '.response.inbounds[]? | select(.tag=="StealXHTTP") | .uuid' 2>/dev/null | head -1)
        [ -z "$CFG_UUID" ] && err "Ошибка создания конфиг-профиля"
        ok "Конфиг-профиль создан"
    fi

    # Variant J / XHTTP_ENABLE=1: activeInbounds/Squad must carry BOTH
    # uuids when XHTTP_ENABLE=1 has a real XHTTP_IBD_UUID, or the new inbound exists in the
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

    # Variant J / XHTTP_ENABLE=1: second Host for XHTTP, only when
    # XHTTP_ENABLE=1 actually produced an XHTTP inbound. Unlike the Vision Host above (unchanged,
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
    # for it to get wrong. `port` is now MODE-aware (FIXED 2026-09-05,
    # F+XHTTP): previously always read $J_XHTTP_PUBLIC_PORT — correct
    # for MODE=J, but would have advertised the wrong public port (8443)
    # for a MODE=F+XHTTP install, whose actual public XHTTP port is
    # $F_XHTTP_PUBLIC_PORT (9443, lib/panel/nginx/variant_f.sh) — clients
    # would have been handed a Host pointing at a port nginx never listens
    # on for F+XHTTP at all.
    local XHTTP_PUBLIC_PORT_VAL
    if [ "$MODE" = "F" ]; then
        XHTTP_PUBLIC_PORT_VAL="${F_XHTTP_PUBLIC_PORT:-9443}"
    else
        XHTTP_PUBLIC_PORT_VAL="${J_XHTTP_PUBLIC_PORT:-8443}"
    fi
    if [ "$XHTTP_ENABLE" = "1" ] && [ -n "$XHTTP_IBD_UUID" ]; then
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
                --argjson port "$XHTTP_PUBLIC_PORT_VAL" \
                '{inbound:{configProfileUuid:$cu,configProfileInboundUuid:$iu},remark:"StealXHTTP",address:$addr,port:$port,path:$xpath,sni:$addr,host:"",alpn:null,fingerprint:"chrome",allowInsecure:false,isDisabled:false,securityLayer:"DEFAULT"}' 2>/dev/null)" >/dev/null 2>&1 \
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
