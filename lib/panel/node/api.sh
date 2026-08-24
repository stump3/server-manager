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
#
# Node/Host lookup-before-create + rollback (закрытие UNKNOWN этого раунда).
# Источники (реальный код, не README):
#   - github.com/eGamesAPI/remnawave-reverse-proxy,
#     src/api/remnawave_api.sh: check_node_domain() читает
#     `GET /api/nodes` → `.response[] | select(.address==...)` — response
#     это ГОЛЫЙ массив, не {response:{nodes:[...]}}. add_node_to_panel()
#     в src/modules/add_node.sh — CONFIRMED execution order:
#     config-profile → node → host → squad (тот же порядок что и здесь).
#     В этом репозитории НЕТ delete_node/delete_host — eGames тоже не
#     делает rollback ноды/хоста, только delete_config_profile().
#   - github.com/remnawave/backend (primary source, NestJS + Prisma):
#     · libs/contract/api/controllers/nodes.ts — NODES_ROUTES: GET '',
#       GET_BY_UUID(uuid), DELETE(uuid) — все три подтверждены.
#     · libs/contract/models/nodes.schema.ts — Nodes: uuid, name, address,
#       isConnected, isConnecting, lastStatusChange, lastStatusMessage.
#     · prisma/schema.prisma, model Nodes — `name` и `address` оба
#       @unique. Т.е. lookup по name — безопасная, DB-enforced identity.
#     · src/modules/nodes/nodes.service.ts createNode(): P2002 на
#       name/address → NODE_NAME_ALREADY_EXISTS / NODE_ADDRESS_ALREADY_EXISTS
#       (HTTP 400, errorCode), НЕ silent success и НЕ 500-без-объяснения —
#       значит unconditional POST retry уже был "безопасен" в смысле
#       "не создаёт дубликат", просто возвращал явную ошибку вместо reuse.
#     · nodes.service.ts deleteNode(): просто stopNode + emit event,
#       НЕ удаляет связанные Hosts. prisma schema: HostsToNodes
#       (join-таблица host_uuid/node_uuid) имеет onDelete:Cascade НА
#       ОБЕИХ сторонах join-таблицы — но это удаляет только строки
#       join-таблицы, не сам Host (Hosts.uuid — самостоятельный PK).
#       Итог: DELETE Node НЕ каскадирует на Host.
#     · libs/contract/api/controllers/hosts.ts — HOSTS_ROUTES: GET '',
#       GET_BY_UUID(uuid), DELETE(uuid) — все три подтверждены.
#     · libs/contract/models/hosts.schema.ts — Hosts: uuid, remark,
#       address, inbound:{configProfileUuid,configProfileInboundUuid},
#       nodes:[uuid] (опциональное поле в CreateHostCommand — наш POST
#       его не передаёт, поэтому HostsToNodes join у нас пустой; связь
#       Host↔Node проходит только через shared inbound).
#       ⚠ prisma schema.prisma, model Hosts: НИ `remark`, НИ `address`
#       НЕ @unique. В отличие от Node, у Host нет DB-enforced identity.
#       Поэтому lookup по remark ("RemoteNode" — статичная строка, даже
#       не включает домен) был бы ненадёжен. Используем
#       inbound.configProfileInboundUuid==IBD_UUID: IBD_UUID уже
#       установлен как identity выше (per-domain config-profile), так
#       что совпадение по нему настолько же надёжно, насколько надёжен
#       сам профиль — но это convention-level, не DB constraint.
#     · hosts.service.ts deleteHost(): простой delete-by-uuid, 404 если
#       не найден, не трогает Node/Profile. Безопасен для compensation.
#   - Rollback реализован ТОЛЬКО для Node/Host, ТОЛЬКО для ресурсов,
#     созданных именно этим запуском (EXISTING vs CREATED_BY_THIS_RUN,
#     см. PROFILE_EXISTING/NODE_EXISTING/HOST_EXISTING ниже). Rollback
#     config-profile — вне scope этого раунда (см. отчёт).
#
# Config Profile rollback (закрытие оставшегося §4.4 gap).
# Precedent: DELETE /api/config-profiles/{uuid} уже реально используется
# в этом репозитории — lib/panel/api.sh:53 (panel_setup_api(), удаление
# чужого "Default-Profile" перед пересозданием). Тот же endpoint, тот же
# способ вызова (panel_api DELETE, best-effort, >/dev/null). Ничего не
# придумано — только применено к новому случаю (compensation, а не
# "удалить чужой профиль перед созданием своего").
# PROFILE_EXISTING отслеживается так же, как NODE_EXISTING/HOST_EXISTING:
# true — профиль был найден lookup'ом ДО этого запуска → никогда не
# удаляется; false — профиль создан именно в этом запуске → подлежит
# компенсации при любом провале ПОСЛЕ его создания (node lookup
# malformed, node create fails, host lookup malformed, host create
# fails). Порядок компенсации — обратный порядку создания: Node
# (если создан этим запуском) → затем Profile (если создан этим
# запуском). Rollback — best-effort и никогда не маскирует исходную
# ошибку: возвращаемое значение функции всегда 1 на этих путях
# независимо от того, удалось ли откатить ресурсы.

# _panel_node_rollback_node API TOKEN NODE_UUID
# Best-effort DELETE /api/nodes/{uuid}. Вызывается только когда нода
# была создана именно этим запуском (NODE_EXISTING=false на момент
# вызова) — см. вызывающий код.
_panel_node_rollback_node() {
    local _api="$1" _token="$2" _uuid="$3"
    warn "Откат: удаляется нода, созданная в этом запуске (uuid: $_uuid)"
    # Contract 4: transport failure, HTTP status, and body are three
    # independent checks — panel_api_status() lets rollback tell them
    # apart, instead of panel_api()'s legacy "curl exit 0 for any HTTP
    # response including 4xx/5xx" masking a real DELETE failure as
    # success (the false-success this round closes). `|| _rc=$?` keeps
    # this safe under set -e (bare `X=$(cmd)` on a failing cmd would
    # otherwise abort the script here).
    local _raw _rc=0
    _raw=$(panel_api_status "DELETE" "http://$_api/api/nodes/$_uuid" "$_token" 2>/dev/null) || _rc=$?
    if [ "$_rc" -ne 0 ]; then
        warn "Не удалось откатить создание ноды (uuid: $_uuid): сетевая ошибка (transport failure) — требуется ручная проверка"
        return
    fi
    local _status="${_raw: -3}"
    case "$_status" in
        2??)
            ok "Нода удалена (rollback)"
            ;;
        *)
            # 404 намеренно НЕ трактуется как success здесь: DELETE
            # /api/nodes/{uuid} не документирует 404 вообще (только 200
            # и 500 — remnawave/backend OpenAPI spec v2.1.13), поэтому
            # нет источника, подтверждающего "already gone" semantics
            # для этого конкретного endpoint'а. Общее правило "4xx/5xx =
            # HTTP failure" применяется без исключения.
            warn "Не удалось откатить создание ноды (uuid: $_uuid): HTTP $_status — требуется ручная проверка"
            ;;
    esac
}

# _panel_node_rollback_profile API TOKEN CFG_UUID
# Best-effort DELETE /api/config-profiles/{uuid}. Вызывается только
# когда конфиг-профиль был создан именно этим запуском
# (PROFILE_EXISTING=false на момент вызова) — см. вызывающий код.
_panel_node_rollback_profile() {
    local _api="$1" _token="$2" _uuid="$3"
    warn "Откат: удаляется конфиг-профиль, созданный в этом запуске (uuid: $_uuid)"
    local _raw _rc=0
    _raw=$(panel_api_status "DELETE" "http://$_api/api/config-profiles/$_uuid" "$_token" 2>/dev/null) || _rc=$?
    if [ "$_rc" -ne 0 ]; then
        warn "Не удалось откатить создание конфиг-профиля (uuid: $_uuid): сетевая ошибка (transport failure) — требуется ручная проверка"
        return
    fi
    local _status="${_raw: -3}"
    case "$_status" in
        2??)
            ok "Конфиг-профиль удалён (rollback)"
            ;;
        *)
            # DELETE /api/config-profiles/{uuid} ЗАДОКУМЕНТИРОВАН с 404
            # ("Config profile not found" — remnawave/backend OpenAPI
            # spec v2.1.13), в отличие от Node DELETE выше. Но сам факт
            # существования 404-ответа не говорит, должна ли ЭТА
            # rollback-логика трактовать его как "уже отсутствует,
            # компенсация не нужна" (success) или как настоящий провал
            # компенсации — источник подтверждает только форму API, не
            # policy вызывающего кода. DECISION REQUIRED (см. отчёт) —
            # общее правило "4xx/5xx = HTTP failure" применяется без
            # исключения до отдельного решения.
            warn "Не удалось откатить создание конфиг-профиля (uuid: $_uuid): HTTP $_status — требуется ручная проверка"
            ;;
    esac
}

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

    # Contract 13 (lookup-before-create): reuse an already-existing
    # config-profile named "RemoteNode-${SELFSTEAL_DOMAIN}" (identity per
    # ARCHITECTURE.md §4.2) instead of always POSTing a new one on every
    # invocation. Same GET+jq-filter shape as the confirmed StealConfig
    # precedent in lib/panel/api.sh (IDEM-02) — response.configProfiles[]
    # is a confirmed response shape (used identically in 4 call sites
    # across this codebase). Existence alone is the check — no
    # content-diff/repair against a mismatched existing profile; that
    # reconciliation behaviour is RECONCILE's job (§4.3), not defined
    # here and not invented here.
    # CFG_UUID/IBD_UUID инициализированы пустой строкой явно: под
    # server-manager.sh's `set -euo pipefail` (nounset) `local x` без `=`
    # трактуется как unbound до первого присваивания — без explicit-init
    # `[ -n "$CFG_UUID" ]` ниже крашит скрипт именно в самом обычном
    # случае (профиль ещё не существует, EXISTING_PROFILE пуст, ветка
    # присвоения не выполняется). Поймано mock-тестом (Case A).
    local PROFILE_R CFG_UUID="" IBD_UUID="" PROFILE_EXISTING=false
    local EXISTING_PROFILE
    EXISTING_PROFILE=$(panel_api "GET" "http://$API/api/config-profiles" "$TOKEN" | \
        jq -c --arg name "RemoteNode-${SELFSTEAL_DOMAIN}" \
            '.response.configProfiles[]? | select(.name==$name)' 2>/dev/null | head -1)
    if [ -n "$EXISTING_PROFILE" ]; then
        CFG_UUID=$(echo "$EXISTING_PROFILE" | jq -r '.uuid // empty' 2>/dev/null)
        IBD_UUID=$(echo "$EXISTING_PROFILE" | jq -r '.inbounds[0].uuid // empty' 2>/dev/null)
        [ -n "$CFG_UUID" ] && [ -n "$IBD_UUID" ] && PROFILE_EXISTING=true
    fi

    if [ -n "$CFG_UUID" ] && [ -n "$IBD_UUID" ]; then
        ok "Конфиг-профиль RemoteNode-${SELFSTEAL_DOMAIN} уже существует, используется существующий"
    else
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
    fi

    # Node lookup-before-create (Contract 13). Identity = Nodes.name,
    # confirmed @unique in remnawave/backend prisma/schema.prisma.
    # GET /api/nodes → {"response":[...]} — bare array (confirmed by both
    # remnawave/backend get-nodes.command.ts ResponseSchema and eGames'
    # check_node_domain() usage of `.response[]`). A response that isn't
    # an array is a lookup FAILURE, not an empty list — must not be
    # silently treated as "node absent" (that would mask an auth/network
    # error as a false ABSENT and lead to an unwanted duplicate-create
    # attempt right after).
    local NODES_LIST_R NODE_UUID="" NODE_EXISTING=false
    NODES_LIST_R=$(panel_api "GET" "http://$API/api/nodes" "$TOKEN")
    if ! echo "$NODES_LIST_R" | jq -e '.response | type == "array"' >/dev/null 2>&1; then
        warn "Не удалось получить список нод (некорректный ответ API): $NODES_LIST_R"
        [ "$PROFILE_EXISTING" = false ] && _panel_node_rollback_profile "$API" "$TOKEN" "$CFG_UUID"
        return 1
    fi
    local EXISTING_NODE
    EXISTING_NODE=$(echo "$NODES_LIST_R" | jq -c --arg name "RemoteNode-${SELFSTEAL_DOMAIN}" \
        '.response[] | select(.name==$name)' 2>/dev/null | head -1)
    if [ -n "$EXISTING_NODE" ]; then
        NODE_UUID=$(echo "$EXISTING_NODE" | jq -r '.uuid // empty' 2>/dev/null)
        NODE_EXISTING=true
        ok "Нода RemoteNode-${SELFSTEAL_DOMAIN} уже существует, используется существующая (uuid: $NODE_UUID)"
    else
        local NODE_R
        NODE_R=$(panel_api "POST" "http://$API/api/nodes" "$TOKEN" "$(jq -n \
            --arg name "RemoteNode-${SELFSTEAL_DOMAIN}" --arg na "$NODE_ADDR" \
            --arg cu "$CFG_UUID" --arg iu "$IBD_UUID" \
            '{name:$name,address:$na,port:2222,configProfile:{activeConfigProfileUuid:$cu,activeInbounds:[$iu]},isTrafficTrackingActive:false,trafficLimitBytes:0,notifyPercent:0,trafficResetDay:31,excludedInbounds:[],countryCode:"XX",consumptionMultiplier:1.0}' 2>/dev/null)")
        NODE_UUID=$(echo "$NODE_R" | jq -r '.response.uuid // empty' 2>/dev/null)
        if [ -z "$NODE_UUID" ]; then
            warn "Ошибка создания ноды: $NODE_R"
            [ "$PROFILE_EXISTING" = false ] && _panel_node_rollback_profile "$API" "$TOKEN" "$CFG_UUID"
            return 1
        fi
        ok "Нода зарегистрирована в Panel (uuid: $NODE_UUID)"
    fi

    # Host lookup-before-create.
    # ⚠ Identity caveat: unlike Nodes.name, Hosts has NO unique constraint
    # on any field (prisma/schema.prisma, model Hosts — neither `remark`
    # nor `address` is @unique). We match on
    # inbound.configProfileInboundUuid==IBD_UUID instead — IBD_UUID is
    # already our per-domain identity from the config-profile step above.
    # This is convention-level (nothing in the DB stops two Hosts
    # pointing at the same inbound), weaker than the Node lookup — stated
    # explicitly, not silently assumed safe.
    local HOSTS_LIST_R HOST_EXISTING=false
    HOSTS_LIST_R=$(panel_api "GET" "http://$API/api/hosts" "$TOKEN")
    if ! echo "$HOSTS_LIST_R" | jq -e '.response | type == "array"' >/dev/null 2>&1; then
        warn "Не удалось получить список хостов (некорректный ответ API): $HOSTS_LIST_R"
        [ "$NODE_EXISTING" = false ] && _panel_node_rollback_node "$API" "$TOKEN" "$NODE_UUID"
        [ "$PROFILE_EXISTING" = false ] && _panel_node_rollback_profile "$API" "$TOKEN" "$CFG_UUID"
        return 1
    fi
    local EXISTING_HOST
    EXISTING_HOST=$(echo "$HOSTS_LIST_R" | jq -c --arg iu "$IBD_UUID" \
        '.response[] | select(.inbound.configProfileInboundUuid==$iu)' 2>/dev/null | head -1)
    if [ -n "$EXISTING_HOST" ]; then
        HOST_EXISTING=true
        ok "Хост для этого inbound уже существует, используется существующий"
    else
        local HOST_R
        HOST_R=$(panel_api "POST" "http://$API/api/hosts" "$TOKEN" "$(jq -n \
            --arg cu "$CFG_UUID" --arg iu "$IBD_UUID" --arg addr "$SELFSTEAL_DOMAIN" \
            '{inbound:{configProfileUuid:$cu,configProfileInboundUuid:$iu},remark:"RemoteNode",address:$addr,port:443,path:"",sni:$addr,host:"",alpn:null,fingerprint:"chrome",allowInsecure:false,isDisabled:false,securityLayer:"DEFAULT"}' 2>/dev/null)")
        if echo "$HOST_R" | jq -e '.response.uuid' >/dev/null 2>&1; then
            ok "Хост создан"
        else
            warn "Ошибка создания хоста: $HOST_R"
            # Contract 13 / ARCHITECTURE.md §4: compensate only what THIS
            # run created. A pre-existing node (NODE_EXISTING=true) must
            # survive a host-creation failure — it predates this run and
            # is not ours to remove. Confirmed safe: deleteNode() does not
            # cascade to Hosts (prisma schema — Host has no required FK to
            # Node; HostsToNodes join rows would cascade-delete, but our
            # create call never populates that join, and no Host exists
            # here yet regardless).
            # Rollback order is the reverse of creation: Node was created
            # after Profile, so Node is compensated first, then Profile —
            # each gated independently on having been created by THIS run.
            [ "$NODE_EXISTING" = false ] && _panel_node_rollback_node "$API" "$TOKEN" "$NODE_UUID"
            [ "$PROFILE_EXISTING" = false ] && _panel_node_rollback_profile "$API" "$TOKEN" "$CFG_UUID"
            return 1
        fi
    fi

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
