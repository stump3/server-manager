#!/bin/bash
# lib/sripts/tests/test_panel_setup_api_create_rollback.sh
#
# DEFECT #2 lifecycle contract for the colocated lib/panel/api.sh:
# panel_setup_api():
#
#   Config Profile -> Node -> Vision Host -> (XHTTP Host) -> Squad
#                  -> API Token -> docker compose restart
#
#   * a mandatory CREATE (Profile/Node/Vision Host/XHTTP Host) that fails
#     => function returns non-zero, NO downstream API call and NO restart;
#   * rollback deletes ONLY objects created by this invocation, in
#     reverse order of creation (Host -> Node -> Profile);
#   * an object found by lookup ("existing") is NEVER deleted;
#   * a failing rollback DELETE never masks the original failure;
#   * the all-existing / all-new success paths are unchanged;
#   * Squad PATCH and docker restart failures stay non-fatal, and never
#     trigger rollback (deliberate, pinned below).
#
# Unlike test_adapter_colocated_node_host_lookup.sh (which awk-extracts
# blocks), this drives the REAL panel_setup_api() end-to-end, mocking
# only the boundaries: panel_api()/panel_api_status() (same keyed-mock +
# call-log shape as harness.sh), docker/ufw/sed/curl/sleep/spinner, and
# the Core accessors (not under test here). It runs under production's
# `set -euo pipefail` (server-manager.sh:13) — that matters: a bare
# `X=$(... | jq ...)` on a non-JSON body or a curl transport failure
# aborts the whole script under errexit BEFORE any `-z` check, silently
# skipping the rollback. Cases 8/9 pin exactly that.
set -uo pipefail   # this driver itself: no -e (we observe return codes)

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$REPO_ROOT" || exit 2

PASS=0; FAIL=0
check() {
    local desc="$1" got="$2" expected="$3"
    if [ "$got" = "$expected" ]; then PASS=$((PASS+1))
    else FAIL=$((FAIL+1)); echo "  FAIL: $desc (expected [$expected], got [$got])"; fi
}
check_nz() {   # got must be a non-zero integer
    local desc="$1" got="$2"
    if [ "$got" != "0" ] && [ -n "$got" ]; then PASS=$((PASS+1))
    else FAIL=$((FAIL+1)); echo "  FAIL: $desc (expected non-zero, got [$got])"; fi
}

bash -n lib/panel/api.sh && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: bash -n lib/panel/api.sh"; }

API="127.0.0.1:3000"
U="http://$API/api"
SQUAD_UUID="11111111-1111-1111-1111-111111111111"
CALL_LOG="$(mktemp)"; OUT_LOG="$(mktemp)"; ERR_LOG="$(mktemp)"
trap 'rm -f "$CALL_LOG" "$OUT_LOG" "$ERR_LOG"' EXIT

declare -A MOCK_RESP MOCK_EXIT MOCK_STATUS
MOCK_DOCKER_FAIL=0

# ── call-log helpers ────────────────────────────────────────────────
n_calls()  { local n; n=$(grep -Fxc "$1" "$CALL_LOG" 2>/dev/null); echo "${n:-0}"; }
n_prefix() { local n; n=$(grep -c "^$1" "$CALL_LOG" 2>/dev/null); echo "${n:-0}"; }
idx()      { grep -Fxn "$1" "$CALL_LOG" 2>/dev/null | head -1 | cut -d: -f1; }
before()   {  # "yes" iff both calls happened and $1 came before $2
    local a b; a=$(idx "$1"); b=$(idx "$2")
    if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; then echo yes; else echo no; fi
}

# ── canned Panel state ──────────────────────────────────────────────
fresh_mocks() {
    MOCK_RESP=(); MOCK_EXIT=(); MOCK_STATUS=(); MOCK_DOCKER_FAIL=0
    MOCK_RESP["POST $U/auth/register"]='{"response":{"accessToken":"TOK"}}'
    MOCK_STATUS["POST $U/auth/register"]=200
    MOCK_RESP["GET $U/system/tools/x25519/generate"]='{"response":{"keypairs":[{"privateKey":"PRIV"}]}}'
    MOCK_RESP["GET $U/keygen"]='{"response":{"secretKey":"PUB"}}'
    MOCK_RESP["GET $U/config-profiles"]='{"response":{"configProfiles":[]}}'
    MOCK_RESP["POST $U/config-profiles"]='{"response":{"uuid":"CFG-NEW","inbounds":[{"tag":"Steal","uuid":"IBD-NEW"},{"tag":"StealXHTTP","uuid":"XIBD-NEW"}]}}'
    MOCK_RESP["GET $U/nodes"]='{"response":[]}'
    MOCK_RESP["POST $U/nodes"]='{"response":{"uuid":"NODE-NEW"}}'
    MOCK_RESP["GET $U/hosts"]='{"response":[]}'
    MOCK_RESP["POST $U/hosts#Steal"]='{"response":{"uuid":"VHOST-NEW"}}'
    MOCK_RESP["POST $U/hosts#StealXHTTP"]='{"response":{"uuid":"XHOST-NEW"}}'
    MOCK_RESP["GET $U/internal-squads"]="{\"response\":{\"internalSquads\":[{\"uuid\":\"$SQUAD_UUID\"}]}}"
    MOCK_RESP["PATCH $U/internal-squads"]='{"response":{}}'
    MOCK_RESP["POST $U/tokens"]='{"response":{"token":"SUBTOK"}}'
    MOCK_STATUS["POST $U/tokens"]=201
}
existing_profile() {
    MOCK_RESP["GET $U/config-profiles"]='{"response":{"configProfiles":[{"uuid":"CFG-EXIST","name":"StealConfig","inbounds":[{"tag":"Steal","uuid":"IBD-EXIST"},{"tag":"StealXHTTP","uuid":"XIBD-EXIST"}]}]}}'
}
existing_node() { MOCK_RESP["GET $U/nodes"]='{"response":[{"uuid":"NODE-EXIST","name":"Steal"}]}'; }
existing_vision_host() {   # $1 = inbound uuid the existing Host is bound to
    MOCK_RESP["GET $U/hosts"]="{\"response\":[{\"uuid\":\"VHOST-EXIST\",\"inbound\":{\"configProfileInboundUuid\":\"$1\"}}]}"
}
existing_xhttp_host() {
    MOCK_RESP["GET $U/hosts"]="{\"response\":[{\"uuid\":\"VHOST-EXIST\",\"inbound\":{\"configProfileInboundUuid\":\"$1\"}},{\"uuid\":\"XHOST-EXIST\",\"inbound\":{\"configProfileInboundUuid\":\"$2\"}}]}"
}
fail_post()   { MOCK_RESP["$1"]='{"message":"Internal server error","statusCode":500}'; }
fail_delete() { MOCK_STATUS["DELETE $1"]=500; MOCK_RESP["DELETE $1"]='{"message":"boom"}'; }

# ── run the REAL panel_setup_api() under production shell options ──
# $1 = XHTTP_ENABLE (0/1). Sets RC. Call log in $CALL_LOG.
run_setup() {
    : > "$CALL_LOG"; : > "$OUT_LOG"; : > "$ERR_LOG"
    (
        source lib/ui/output.sh
        source lib/panel/api.sh
        # ---- boundary mocks (defined AFTER sourcing so they win) ----
        panel_api() {
            local m="$1" u="$2" d="${4:-}" key
            key="$m $u"
            [ "$m $u" = "POST $U/hosts" ] && key="$key#$(jq -r '.remark // empty' <<<"$d" 2>/dev/null)"
            echo "$key" >> "$CALL_LOG"
            printf '%s' "${MOCK_RESP[$key]:-}"
            return "${MOCK_EXIT[$key]:-0}"
        }
        panel_api_status() {
            local key="$1 $2"
            echo "$key" >> "$CALL_LOG"
            printf '%s%s' "${MOCK_RESP[$key]:-}" "${MOCK_STATUS[$key]:-204}"
            return "${MOCK_EXIT[$key]:-0}"
        }
        cd()      { :; }
        sleep()   { :; }
        curl()    { return 0; }
        ufw()     { :; }
        sed()     { :; }
        spinner() { :; }
        docker()  { echo "docker $*" >> "$CALL_LOG"; [ "$MOCK_DOCKER_FAIL" = 1 ] && return 1; return 0; }
        # Core accessors: not under test here
        core_deployment_has_capability()       { return 0; }
        core_runtime_component_exists()        { return 0; }
        core_port_allocation_public()          { echo 8443; }
        panel_core_reality_needs_2222_ufw_rule() { return 1; }
        panel_core_reality_dest_val()          { echo /dev/shm/nginx.sock; }
        panel_core_reality_accept_proxy_protocol() { echo true; }
        panel_core_reality_listen_addr()       { echo 127.0.0.1; }
        panel_reality_inbound_port()           { echo 8443; }
        panel_reality_xhttp_inbound_port()     { echo 9443; }
        panel_xray_render_inbounds()           { echo '[{"tag":"Steal"},{"tag":"StealXHTTP"}]'; }

        set -euo pipefail          # == server-manager.sh:13 (errexit ACTIVE)
        trap 'wait' EXIT           # flush backgrounded docker stubs into the log
        panel_setup_api admin pass sni.example.com J "$1"
    ) >"$OUT_LOG" 2>"$ERR_LOG"
    RC=$?
}

DEL_CFG="DELETE $U/config-profiles/CFG-NEW"
DEL_NODE="DELETE $U/nodes/NODE-NEW"
DEL_VHOST="DELETE $U/hosts/VHOST-NEW"
DEL_XHOST="DELETE $U/hosts/XHOST-NEW"
n_deletes()   { n_prefix "DELETE"; }
downstream()  {  # count of Squad/Token/restart activity (must be 0 after a fatal CREATE failure)
    echo $(( $(n_calls "PATCH $U/internal-squads") + $(n_calls "POST $U/tokens") + $(n_prefix "docker compose down") ))
}

# ════════════════════════════════════════════════════════════════════
echo "== 1. Node CREATE fails (profile created this run) =="
fresh_mocks; fail_post "POST $U/nodes"
run_setup 1
check_nz "function returns non-zero" "$RC"
check "Profile DELETE called once"            "$(n_calls "$DEL_CFG")" 1
check "no Node DELETE (Node never created)"   "$(n_prefix "DELETE $U/nodes/")" 0
check "no Host DELETE"                        "$(n_prefix "DELETE $U/hosts/")" 0
check "Vision Host CREATE NOT called"         "$(n_calls "POST $U/hosts#Steal")" 0
check "XHTTP Host CREATE NOT called"          "$(n_calls "POST $U/hosts#StealXHTTP")" 0
check "Squad PATCH NOT called"                "$(n_calls "PATCH $U/internal-squads")" 0
check "Token CREATE NOT called"               "$(n_calls "POST $U/tokens")" 0
check "docker restart NOT called"             "$(n_prefix "docker compose down")" 0
check "failure is reported on stderr"         "$(grep -c 'Ошибка создания ноды' "$ERR_LOG")" 1

echo "== 2. Existing Profile + Node CREATE fails =="
fresh_mocks; existing_profile; fail_post "POST $U/nodes"
run_setup 1
check_nz "function returns non-zero" "$RC"
check "existing Profile survives: zero DELETEs" "$(n_deletes)" 0
check "no downstream calls" "$(downstream)" 0

echo "== 3. Host CREATE fails (profile + node created this run) =="
fresh_mocks; fail_post "POST $U/hosts#Steal"
run_setup 1
check_nz "function returns non-zero" "$RC"
check "Node DELETE called once"    "$(n_calls "$DEL_NODE")" 1
check "Profile DELETE called once" "$(n_calls "$DEL_CFG")" 1
check "reverse order: Node before Profile" "$(before "$DEL_NODE" "$DEL_CFG")" yes
check "no Host DELETE (Host never created)" "$(n_prefix "DELETE $U/hosts/")" 0
check "XHTTP Host CREATE NOT called" "$(n_calls "POST $U/hosts#StealXHTTP")" 0
check "no downstream calls" "$(downstream)" 0

echo "== 4. Existing Profile + existing Node + Host CREATE fails =="
fresh_mocks; existing_profile; existing_node; fail_post "POST $U/hosts#Steal"
run_setup 1
check_nz "function returns non-zero" "$RC"
check "Profile and Node survive: zero DELETEs" "$(n_deletes)" 0
check "no downstream calls" "$(downstream)" 0

echo "== 4b. Existing Profile, new Node, Host CREATE fails: only the new Node is rolled back =="
fresh_mocks; existing_profile; fail_post "POST $U/hosts#Steal"
run_setup 1
check_nz "function returns non-zero" "$RC"
check "new Node deleted"                "$(n_calls "$DEL_NODE")" 1
check "existing Profile NOT deleted"    "$(n_prefix "DELETE $U/config-profiles/")" 0

echo "== 5. XHTTP Host CREATE fails after Vision Host was created =="
fresh_mocks; fail_post "POST $U/hosts#StealXHTTP"
run_setup 1
check_nz "function returns non-zero" "$RC"
check "Vision Host DELETE called once" "$(n_calls "$DEL_VHOST")" 1
check "Node DELETE called once"        "$(n_calls "$DEL_NODE")" 1
check "Profile DELETE called once"     "$(n_calls "$DEL_CFG")" 1
check "reverse order: Vision Host before Node" "$(before "$DEL_VHOST" "$DEL_NODE")" yes
check "reverse order: Node before Profile"     "$(before "$DEL_NODE" "$DEL_CFG")" yes
check "XHTTP Host itself never deleted (never created)" "$(n_calls "$DEL_XHOST")" 0
check "no downstream calls" "$(downstream)" 0

echo "== 5b. XHTTP Host fails, Vision Host pre-existing: Host survives, Node+Profile rolled back =="
fresh_mocks; existing_vision_host IBD-NEW; fail_post "POST $U/hosts#StealXHTTP"
run_setup 1
check_nz "function returns non-zero" "$RC"
check "existing Vision Host NOT deleted" "$(n_prefix "DELETE $U/hosts/")" 0
check "Node deleted"    "$(n_calls "$DEL_NODE")" 1
check "Profile deleted" "$(n_calls "$DEL_CFG")" 1

echo "== 5c. Everything pre-existing, XHTTP Host CREATE fails: nothing is deleted =="
fresh_mocks; existing_profile; existing_node; existing_vision_host IBD-EXIST; fail_post "POST $U/hosts#StealXHTTP"
run_setup 1
check_nz "function returns non-zero" "$RC"
check "zero DELETEs" "$(n_deletes)" 0
check "no downstream calls" "$(downstream)" 0

echo "== 5d. Existing XHTTP Host is reused (type-aware lookup, flat array): no POST, no DELETE, success =="
fresh_mocks; existing_profile; existing_node; existing_xhttp_host IBD-EXIST XIBD-EXIST
run_setup 1
check "function returns 0" "$RC" 0
check "no Host CREATE at all" "$(n_prefix "POST $U/hosts#")" 0
check "zero DELETEs" "$(n_deletes)" 0

echo "== 6. Successful fresh installation (XHTTP on): normal sequence, no rollback =="
fresh_mocks
run_setup 1
check "function returns 0" "$RC" 0
check "zero DELETEs" "$(n_deletes)" 0
check "order: Profile < Node"        "$(before "POST $U/config-profiles" "POST $U/nodes")" yes
check "order: Node < Vision Host"    "$(before "POST $U/nodes" "POST $U/hosts#Steal")" yes
check "order: Vision < XHTTP Host"   "$(before "POST $U/hosts#Steal" "POST $U/hosts#StealXHTTP")" yes
check "order: XHTTP Host < Squad"    "$(before "POST $U/hosts#StealXHTTP" "PATCH $U/internal-squads")" yes
check "order: Squad < Token"         "$(before "PATCH $U/internal-squads" "POST $U/tokens")" yes
check "order: Token < restart"       "$(before "POST $U/tokens" "docker compose down remnawave-subscription-page")" yes
check "restart ran (down x2)"        "$(n_prefix "docker compose down")" 2
check "Stack restarted message"      "$(grep -c 'Стек перезапущен' "$ERR_LOG")" 1

echo "== 6b. Successful fresh installation (XHTTP off): single Host =="
fresh_mocks
run_setup 0
check "function returns 0" "$RC" 0
check "exactly one Host CREATE (Vision)" "$(n_prefix "POST $U/hosts#")" 1
check "zero DELETEs" "$(n_deletes)" 0

echo "== 6c. Everything pre-existing: success path unchanged (no CREATE, no DELETE) =="
fresh_mocks; existing_profile; existing_node; existing_vision_host IBD-EXIST
run_setup 0
check "function returns 0" "$RC" 0
check "no Profile/Node/Host CREATE" "$(( $(n_calls "POST $U/config-profiles") + $(n_calls "POST $U/nodes") + $(n_prefix "POST $U/hosts#") ))" 0
check "zero DELETEs" "$(n_deletes)" 0
check "Squad/Token/restart still ran" "$(( $(n_calls "PATCH $U/internal-squads") + $(n_calls "POST $U/tokens") ))" 2

echo "== 7. Rollback failure never masks the original CREATE failure =="
fresh_mocks; fail_post "POST $U/nodes"; fail_delete "$U/config-profiles/CFG-NEW"
run_setup 1
check_nz "7a Node CREATE fails + Profile DELETE fails (HTTP 500): non-zero" "$RC"
check "7a rollback was actually attempted" "$(n_calls "$DEL_CFG")" 1
check "7a rollback failure is diagnosed" "$(grep -c 'Не удалось откатить' "$ERR_LOG")" 1

fresh_mocks; fail_post "POST $U/nodes"; MOCK_EXIT["DELETE $U/config-profiles/CFG-NEW"]=7
run_setup 1
check_nz "7b Node CREATE fails + Profile DELETE transport failure: non-zero" "$RC"
check "7b rollback failure is diagnosed" "$(grep -c 'transport failure' "$ERR_LOG")" 1

fresh_mocks; fail_post "POST $U/hosts#StealXHTTP"; fail_delete "$U/nodes/NODE-NEW"
run_setup 1
check_nz "7c chained: Node DELETE fails -> still non-zero" "$RC"
check "7c a failed Node rollback does not stop the Profile rollback" "$(n_calls "$DEL_CFG")" 1
check "7c order preserved (Host, Node, Profile)" "$(before "$DEL_VHOST" "$DEL_NODE"):$(before "$DEL_NODE" "$DEL_CFG")" yes:yes

echo "== 8. errexit regression: non-JSON body / transport failure on CREATE still rolls back =="
fresh_mocks; MOCK_RESP["POST $U/nodes"]='<html>502 Bad Gateway</html>'
run_setup 1
check_nz "8a Node POST returns non-JSON: non-zero" "$RC"
check "8a Profile rolled back (not skipped by errexit)" "$(n_calls "$DEL_CFG")" 1
check "8a no downstream calls" "$(downstream)" 0

fresh_mocks; MOCK_RESP["POST $U/nodes"]=''; MOCK_EXIT["POST $U/nodes"]=7
run_setup 1
check_nz "8b Node POST transport failure (curl 7): non-zero" "$RC"
check "8b Profile rolled back" "$(n_calls "$DEL_CFG")" 1

fresh_mocks; MOCK_RESP["POST $U/hosts#Steal"]='<html>502</html>'
run_setup 1
check_nz "8c Vision Host POST non-JSON: non-zero" "$RC"
check "8c Node then Profile rolled back" "$(before "$DEL_NODE" "$DEL_CFG")" yes

fresh_mocks; MOCK_RESP["POST $U/hosts#StealXHTTP"]='<html>502</html>'; MOCK_EXIT["POST $U/hosts#StealXHTTP"]=7
run_setup 1
check_nz "8d XHTTP Host POST garbled + transport failure: non-zero" "$RC"
check "8d Host, Node, Profile rolled back in order" "$(before "$DEL_VHOST" "$DEL_NODE"):$(before "$DEL_NODE" "$DEL_CFG")" yes:yes

echo "== 9. Deliberately NON-fatal steps stay non-fatal and never trigger rollback =="
fresh_mocks; MOCK_EXIT["PATCH $U/internal-squads"]=1; MOCK_RESP["PATCH $U/internal-squads"]='{"message":"nope"}'
run_setup 1
check "9a Squad PATCH failure: function still returns 0 (existing semantics)" "$RC" 0
check "9a no rollback"                         "$(n_deletes)" 0
check "9a Token CREATE still attempted"        "$(n_calls "POST $U/tokens")" 1

fresh_mocks; MOCK_DOCKER_FAIL=1
run_setup 1
check "9b docker compose failure: not observed, returns 0 (existing semantics)" "$RC" 0
check "9b no rollback" "$(n_deletes)" 0

echo ""
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
