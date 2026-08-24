#!/bin/bash
# Isolated mock harness for panel_node_register() lookup/rollback logic.
# Does NOT source the real server-manager tree (avoids unrelated deps) —
# reimplements only what panel_node_register() needs: ok/warn/info + a
# stubbed panel_api that serves canned responses keyed by METHOD+URL,
# with call counters so DELETE calls (rollback) can be asserted.

set -uo pipefail  # no -e: we want to observe non-zero returns from the function under test

ok()   { echo "[OK] $*"; }
warn() { echo "[WARN] $*"; }
info() { echo "[INFO] $*"; }

# --- mock state, reset per test case ---
# panel_node_register() is invoked as `OUT=$(panel_node_register ...)`,
# which runs the whole function (and every panel_api call inside it) in a
# subshell. In-memory associative-array writes made inside that subshell
# do not survive past it, so the call log/counts must be a real
# filesystem side effect (a file) rather than a bash array.
declare -A MOCK_RESP
declare -A MOCK_EXIT   # optional: forced nonzero exit code per "METHOD URL" key,
                       # mirroring the real panel_api()'s contract — it
                       # returns curl's raw exit status, independent of
                       # the response body. Needed for Case L (rollback
                       # DELETE itself fails at the transport level, not
                       # just via an error body).
declare -A MOCK_STATUS # HTTP status code per "METHOD URL" key, for the
                       # panel_api_status() mock below. Defaults to "204"
                       # (success, empty body) when unset, matching every
                       # existing rollback-DELETE mock in this file that
                       # was written as MOCK_RESP[...]='' before this
                       # mock existed.
CALL_LOG_FILE="$(mktemp)"

panel_api() {
    local method="$1" url="$2" token="${3:-}" data="${4:-}"
    local key="${method} ${url}"
    echo "$key" >> "$CALL_LOG_FILE"
    echo "${MOCK_RESP[$key]:-}"
    return "${MOCK_EXIT[$key]:-0}"
}

# Mock for lib/common/network.sh's panel_api_status() — the rollback
# helpers (_panel_node_rollback_node/_panel_node_rollback_profile) call
# THIS, not panel_api(). Without this mock, every rollback DELETE call
# in this harness silently fell through to the real, unmocked
# panel_api_status() (this file deliberately never sources
# lib/common/network.sh) — meaning every rollback assertion below was
# not actually exercising panel_node_register()'s rollback code path at
# all. Confirmed via a real run: with jq installed and this mock
# missing, "rollback DELETE called" assertions failed (count 0) while
# "rollback failure is explicitly diagnosed" assertions passed — the
# rollback helpers were hitting a real `command not found` (panel_api_status
# undefined in this shell) and reporting that as a transport failure,
# never reaching the mocked panel_api() at all. Contract: same
# body+status-concatenated shape as the real function, so callers'
# `${raw: -3}` / `${raw:0:${#raw}-3}` parsing is exercised for real.
panel_api_status() {
    local method="$1" url="$2" token="${3:-}" data="${4:-}"
    local key="${method} ${url}"
    echo "$key" >> "$CALL_LOG_FILE"
    printf '%s%s' "${MOCK_RESP[$key]:-}" "${MOCK_STATUS[$key]:-204}"
    return "${MOCK_EXIT[$key]:-0}"
}

call_count() {
    local n
    n=$(grep -Fxc "$1" "$CALL_LOG_FILE" 2>/dev/null)
    echo "${n:-0}"
}

call_order_index() {
    # 1-based line number of the FIRST occurrence of "$1" in the call
    # log, or empty if never called. Used to assert rollback order
    # (Node DELETE must appear before Config Profile DELETE).
    grep -Fxn "$1" "$CALL_LOG_FILE" 2>/dev/null | head -1 | cut -d: -f1
}

reset_mocks() {
    MOCK_RESP=()
    MOCK_EXIT=()
    MOCK_STATUS=()
    : > "$CALL_LOG_FILE"
}

# Load the function under test from the real (patched) file, resolved
# relative to this script's own location so it runs from any checkout
# (was previously a hardcoded absolute path specific to one machine —
# every test case failed silently with "command not found" / exit 127
# under `set -uo pipefail` without `-e`, and every apparent PASS above
# that point was a vacuous false negative, not a real check).
_HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$_HARNESS_DIR/../../panel/node/api.sh"

API="127.0.0.1:3000"
DOMAIN="example.com"
NODE_NAME="RemoteNode-${DOMAIN}"

common_mocks() {
    MOCK_RESP["POST http://$API/api/auth/login"]='{"response":{"accessToken":"tok123"}}'
    MOCK_RESP["GET http://$API/api/system/tools/x25519/generate"]='{"response":{"keypairs":[{"privateKey":"PRIVKEY"}]}}'
    MOCK_RESP["GET http://$API/api/internal-squads"]='{"response":{"internalSquads":[]}}'
}

pass=0; fail=0
check() {
    local desc="$1" got="$2" expected="$3"
    if [ "$got" = "$expected" ]; then
        echo "  PASS: $desc"
        pass=$((pass+1))
    else
        echo "  FAIL: $desc (expected [$expected], got [$got])"
        fail=$((fail+1))
    fi
}

echo "=== Case A: nothing exists -> profile POST, node POST, host POST ==="
reset_mocks; common_mocks
MOCK_RESP["GET http://$API/api/config-profiles"]='{"response":{"configProfiles":[]}}'
MOCK_RESP["POST http://$API/api/config-profiles"]='{"response":{"uuid":"CFG-NEW","inbounds":[{"uuid":"IBD-NEW"}]}}'
MOCK_RESP["GET http://$API/api/nodes"]='{"response":[]}'
MOCK_RESP["POST http://$API/api/nodes"]='{"response":{"uuid":"NODE-NEW"}}'
MOCK_RESP["GET http://$API/api/hosts"]='{"response":[]}'
MOCK_RESP["POST http://$API/api/hosts"]='{"response":{"uuid":"HOST-NEW"}}'
OUT=$(panel_node_register "admin" "pass" "$DOMAIN" "10.0.0.5")
RC=$?
check "exit code" "$RC" "0"
check "profile POST called" "$(call_count "POST http://$API/api/config-profiles")" "1"
check "node POST called" "$(call_count "POST http://$API/api/nodes")" "1"
check "host POST called" "$(call_count "POST http://$API/api/hosts")" "1"
check "stdout token+uuid (last line)" "$(echo "$OUT" | tail -1)" "tok123 NODE-NEW"

echo "=== Case B: profile exists -> no profile POST ==="
reset_mocks; common_mocks
MOCK_RESP["GET http://$API/api/config-profiles"]="{\"response\":{\"configProfiles\":[{\"uuid\":\"CFG-EXIST\",\"name\":\"$NODE_NAME\",\"inbounds\":[{\"uuid\":\"IBD-EXIST\"}]}]}}"
MOCK_RESP["GET http://$API/api/nodes"]='{"response":[]}'
MOCK_RESP["POST http://$API/api/nodes"]='{"response":{"uuid":"NODE-NEW"}}'
MOCK_RESP["GET http://$API/api/hosts"]='{"response":[]}'
MOCK_RESP["POST http://$API/api/hosts"]='{"response":{"uuid":"HOST-NEW"}}'
OUT=$(panel_node_register "admin" "pass" "$DOMAIN" "10.0.0.5")
RC=$?
check "exit code" "$RC" "0"
check "profile POST NOT called" "$(call_count "POST http://$API/api/config-profiles")" "0"

echo "=== Case C: node exists -> no node POST ==="
reset_mocks; common_mocks
MOCK_RESP["GET http://$API/api/config-profiles"]='{"response":{"configProfiles":[]}}'
MOCK_RESP["POST http://$API/api/config-profiles"]='{"response":{"uuid":"CFG-NEW","inbounds":[{"uuid":"IBD-NEW"}]}}'
MOCK_RESP["GET http://$API/api/nodes"]="{\"response\":[{\"uuid\":\"NODE-EXIST\",\"name\":\"$NODE_NAME\",\"address\":\"10.0.0.5\"}]}"
MOCK_RESP["GET http://$API/api/hosts"]='{"response":[]}'
MOCK_RESP["POST http://$API/api/hosts"]='{"response":{"uuid":"HOST-NEW"}}'
OUT=$(panel_node_register "admin" "pass" "$DOMAIN" "10.0.0.5")
RC=$?
check "exit code" "$RC" "0"
check "node POST NOT called" "$(call_count "POST http://$API/api/nodes")" "0"
check "reused NODE-EXIST uuid in stdout (last line)" "$(echo "$OUT" | tail -1)" "tok123 NODE-EXIST"

echo "=== Case D: host exists -> no host POST ==="
reset_mocks; common_mocks
MOCK_RESP["GET http://$API/api/config-profiles"]='{"response":{"configProfiles":[]}}'
MOCK_RESP["POST http://$API/api/config-profiles"]='{"response":{"uuid":"CFG-NEW","inbounds":[{"uuid":"IBD-NEW"}]}}'
MOCK_RESP["GET http://$API/api/nodes"]='{"response":[]}'
MOCK_RESP["POST http://$API/api/nodes"]='{"response":{"uuid":"NODE-NEW"}}'
MOCK_RESP["GET http://$API/api/hosts"]='{"response":[{"uuid":"HOST-EXIST","inbound":{"configProfileInboundUuid":"IBD-NEW"}}]}'
OUT=$(panel_node_register "admin" "pass" "$DOMAIN" "10.0.0.5")
RC=$?
check "exit code" "$RC" "0"
check "host POST NOT called" "$(call_count "POST http://$API/api/hosts")" "0"

echo "=== Case E: partial create - profile+node created, host fails -> rollback the node AND the profile created this run ==="
echo "    (NOTE: this assertion is intentionally UPDATED from the previous round. Before this"
echo "     round, Config Profile rollback did not exist, so the profile was correctly never"
echo "     deleted. This round closes exactly that gap per ARCHITECTURE.md §4.4, so a profile"
echo "     created by this run is now compensated too. See Case J for the fuller version of"
echo "     this same scenario including rollback ORDER verification.)"
reset_mocks; common_mocks
MOCK_RESP["GET http://$API/api/config-profiles"]='{"response":{"configProfiles":[]}}'
MOCK_RESP["POST http://$API/api/config-profiles"]='{"response":{"uuid":"CFG-NEW","inbounds":[{"uuid":"IBD-NEW"}]}}'
MOCK_RESP["GET http://$API/api/nodes"]='{"response":[]}'
MOCK_RESP["POST http://$API/api/nodes"]='{"response":{"uuid":"NODE-NEW"}}'
MOCK_RESP["GET http://$API/api/hosts"]='{"response":[]}'
MOCK_RESP["POST http://$API/api/hosts"]='{"message":"Internal error","errorCode":"A099"}'  # no .response.uuid -> failure
MOCK_RESP["DELETE http://$API/api/nodes/NODE-NEW"]=''
MOCK_RESP["DELETE http://$API/api/config-profiles/CFG-NEW"]=''
OUT=$(panel_node_register "admin" "pass" "$DOMAIN" "10.0.0.5")
RC=$?
check "exit code (failure)" "$RC" "1"
check "rollback DELETE called on the node created this run" "$(call_count "DELETE http://$API/api/nodes/NODE-NEW")" "1"
check "rollback DELETE called on the profile created this run" "$(call_count "DELETE http://$API/api/config-profiles/CFG-NEW")" "1"

echo "=== Case F: existing resources + later failure -> NOTHING existing is deleted ==="
reset_mocks; common_mocks
MOCK_RESP["GET http://$API/api/config-profiles"]="{\"response\":{\"configProfiles\":[{\"uuid\":\"CFG-EXIST\",\"name\":\"$NODE_NAME\",\"inbounds\":[{\"uuid\":\"IBD-EXIST\"}]}]}}"
MOCK_RESP["GET http://$API/api/nodes"]="{\"response\":[{\"uuid\":\"NODE-EXIST\",\"name\":\"$NODE_NAME\",\"address\":\"10.0.0.5\"}]}"
MOCK_RESP["GET http://$API/api/hosts"]='{"response":[]}'
MOCK_RESP["POST http://$API/api/hosts"]='{"message":"Internal error"}'  # fails
MOCK_RESP["DELETE http://$API/api/nodes/NODE-EXIST"]=''
OUT=$(panel_node_register "admin" "pass" "$DOMAIN" "10.0.0.5")
RC=$?
check "exit code (failure)" "$RC" "1"
check "pre-existing node is NEVER deleted" "$(call_count "DELETE http://$API/api/nodes/NODE-EXIST")" "0"

echo "=== Case G: malformed lookup response -> must NOT be treated as ABSENT ==="
reset_mocks; common_mocks
MOCK_RESP["GET http://$API/api/config-profiles"]='{"response":{"configProfiles":[]}}'
MOCK_RESP["POST http://$API/api/config-profiles"]='{"response":{"uuid":"CFG-NEW","inbounds":[{"uuid":"IBD-NEW"}]}}'
MOCK_RESP["GET http://$API/api/nodes"]='{"message":"Unauthorized","statusCode":401}'  # NOT an array under .response
MOCK_RESP["POST http://$API/api/nodes"]='{"response":{"uuid":"NODE-SHOULD-NOT-BE-CREATED"}}'
OUT=$(panel_node_register "admin" "pass" "$DOMAIN" "10.0.0.5")
RC=$?
check "exit code (failure, not silently proceeding)" "$RC" "1"
check "node POST NOT called after malformed lookup" "$(call_count "POST http://$API/api/nodes")" "0"

echo "=== Case H: profile created, Node creation fails -> rollback the profile; nothing else to roll back ==="
reset_mocks; common_mocks
MOCK_RESP["GET http://$API/api/config-profiles"]='{"response":{"configProfiles":[]}}'
MOCK_RESP["POST http://$API/api/config-profiles"]='{"response":{"uuid":"CFG-NEW","inbounds":[{"uuid":"IBD-NEW"}]}}'
MOCK_RESP["GET http://$API/api/nodes"]='{"response":[]}'
MOCK_RESP["POST http://$API/api/nodes"]='{"message":"Internal error"}'  # no .response.uuid -> node creation fails
MOCK_RESP["DELETE http://$API/api/config-profiles/CFG-NEW"]=''
OUT=$(panel_node_register "admin" "pass" "$DOMAIN" "10.0.0.5")
RC=$?
check "exit code (failure)" "$RC" "1"
check "profile DELETE called exactly once" "$(call_count "DELETE http://$API/api/config-profiles/CFG-NEW")" "1"
check "Node DELETE NOT called (no node was ever created)" "$(call_count "DELETE http://$API/api/nodes/NODE-NEW")" "0"
check "Host POST NOT called (never reached that step)" "$(call_count "POST http://$API/api/hosts")" "0"

echo "=== Case I: profile pre-existing, Node creation fails -> profile is NEVER deleted ==="
reset_mocks; common_mocks
MOCK_RESP["GET http://$API/api/config-profiles"]="{\"response\":{\"configProfiles\":[{\"uuid\":\"CFG-EXIST\",\"name\":\"$NODE_NAME\",\"inbounds\":[{\"uuid\":\"IBD-EXIST\"}]}]}}"
MOCK_RESP["GET http://$API/api/nodes"]='{"response":[]}'
MOCK_RESP["POST http://$API/api/nodes"]='{"message":"Internal error"}'  # node creation fails
MOCK_RESP["DELETE http://$API/api/config-profiles/CFG-EXIST"]=''
OUT=$(panel_node_register "admin" "pass" "$DOMAIN" "10.0.0.5")
RC=$?
check "exit code (failure)" "$RC" "1"
check "pre-existing profile DELETE NOT called" "$(call_count "DELETE http://$API/api/config-profiles/CFG-EXIST")" "0"

echo "=== Case J: profile created, Node created, Host fails -> rollback order is Node THEN Profile ==="
reset_mocks; common_mocks
MOCK_RESP["GET http://$API/api/config-profiles"]='{"response":{"configProfiles":[]}}'
MOCK_RESP["POST http://$API/api/config-profiles"]='{"response":{"uuid":"CFG-NEW","inbounds":[{"uuid":"IBD-NEW"}]}}'
MOCK_RESP["GET http://$API/api/nodes"]='{"response":[]}'
MOCK_RESP["POST http://$API/api/nodes"]='{"response":{"uuid":"NODE-NEW"}}'
MOCK_RESP["GET http://$API/api/hosts"]='{"response":[]}'
MOCK_RESP["POST http://$API/api/hosts"]='{"message":"Internal error"}'  # host creation fails
MOCK_RESP["DELETE http://$API/api/nodes/NODE-NEW"]=''
MOCK_RESP["DELETE http://$API/api/config-profiles/CFG-NEW"]=''
OUT=$(panel_node_register "admin" "pass" "$DOMAIN" "10.0.0.5")
RC=$?
check "exit code (failure)" "$RC" "1"
check "Node DELETE called" "$(call_count "DELETE http://$API/api/nodes/NODE-NEW")" "1"
check "Config Profile DELETE called" "$(call_count "DELETE http://$API/api/config-profiles/CFG-NEW")" "1"
NODE_DEL_IDX="$(call_order_index "DELETE http://$API/api/nodes/NODE-NEW")"
PROFILE_DEL_IDX="$(call_order_index "DELETE http://$API/api/config-profiles/CFG-NEW")"
check "rollback order is Node before Profile" "$([ "$NODE_DEL_IDX" -lt "$PROFILE_DEL_IDX" ] && echo yes || echo no)" "yes"
check "Host was never created, so no Host DELETE call exists at all" "$(call_count "DELETE http://$API/api/hosts/HOST-NEW")" "0"

echo "=== Case K: all resources pre-existing, later failure -> NOTHING pre-existing is deleted ==="
reset_mocks; common_mocks
MOCK_RESP["GET http://$API/api/config-profiles"]="{\"response\":{\"configProfiles\":[{\"uuid\":\"CFG-EXIST\",\"name\":\"$NODE_NAME\",\"inbounds\":[{\"uuid\":\"IBD-EXIST\"}]}]}}"
MOCK_RESP["GET http://$API/api/nodes"]="{\"response\":[{\"uuid\":\"NODE-EXIST\",\"name\":\"$NODE_NAME\",\"address\":\"10.0.0.5\"}]}"
MOCK_RESP["GET http://$API/api/hosts"]='{"response":[]}'
MOCK_RESP["POST http://$API/api/hosts"]='{"message":"Internal error"}'  # host creation fails
MOCK_RESP["DELETE http://$API/api/nodes/NODE-EXIST"]=''
MOCK_RESP["DELETE http://$API/api/config-profiles/CFG-EXIST"]=''
OUT=$(panel_node_register "admin" "pass" "$DOMAIN" "10.0.0.5")
RC=$?
check "exit code (failure)" "$RC" "1"
check "pre-existing Node is NEVER deleted" "$(call_count "DELETE http://$API/api/nodes/NODE-EXIST")" "0"
check "pre-existing Config Profile is NEVER deleted" "$(call_count "DELETE http://$API/api/config-profiles/CFG-EXIST")" "0"

echo "=== Case L: rollback DELETE itself fails -> original failure still returned, no false success, failure is diagnosed ==="
echo "    (Scoping note: the ONLY signal panel_api()/curl gives for a transport-level failure"
echo "     is curl's own nonzero exit code -- HTTP 4xx/5xx bodies still yield exit 0, since"
echo "     panel_api() never passes -f to curl. This is an existing, pre-this-round contract"
echo "     (lib/common/network.sh), not something invented for this test. So 'rollback DELETE"
echo "     fails' is simulated the only way the current architecture can actually distinguish"
echo "     it: a nonzero curl-level exit code on the DELETE call.)"
reset_mocks; common_mocks
MOCK_RESP["GET http://$API/api/config-profiles"]='{"response":{"configProfiles":[]}}'
MOCK_RESP["POST http://$API/api/config-profiles"]='{"response":{"uuid":"CFG-NEW","inbounds":[{"uuid":"IBD-NEW"}]}}'
MOCK_RESP["GET http://$API/api/nodes"]='{"response":[]}'
MOCK_RESP["POST http://$API/api/nodes"]='{"response":{"uuid":"NODE-NEW"}}'
MOCK_RESP["GET http://$API/api/hosts"]='{"response":[]}'
MOCK_RESP["POST http://$API/api/hosts"]='{"message":"Internal error"}'  # host creation fails -> triggers rollback
MOCK_EXIT["DELETE http://$API/api/nodes/NODE-NEW"]=7          # simulate curl transport failure on rollback
MOCK_EXIT["DELETE http://$API/api/config-profiles/CFG-NEW"]=7  # same, for the profile rollback
OUT=$(panel_node_register "admin" "pass" "$DOMAIN" "10.0.0.5" 2>&1)
RC=$?
check "original failure is STILL returned (rollback failure does not mask it)" "$RC" "1"
check "rollback attempted on Node despite eventual failure" "$(call_count "DELETE http://$API/api/nodes/NODE-NEW")" "1"
check "rollback attempted on Profile despite eventual failure" "$(call_count "DELETE http://$API/api/config-profiles/CFG-NEW")" "1"
check "Node rollback failure is explicitly diagnosed" \
    "$(echo "$OUT" | grep -Fc "Не удалось откатить создание ноды")" "1"
check "Profile rollback failure is explicitly diagnosed" \
    "$(echo "$OUT" | grep -Fc "Не удалось откатить создание конфиг-профиля")" "1"
check "no FALSE 'node rollback succeeded' message" \
    "$(echo "$OUT" | grep -Fc "Нода удалена (rollback)")" "0"
check "no FALSE 'profile rollback succeeded' message" \
    "$(echo "$OUT" | grep -Fc "Конфиг-профиль удалён (rollback)")" "0"

echo "=== Case L2: same scenario, but with 'set -euo pipefail' enabled around the call ==="
echo "    (This directly tests the stated concern: does the rollback's && / || construct"
echo "     survive under -e, or does a failing DELETE inside it abort the function before"
echo "     it reaches its own 'return 1'? panel_api itself is never the LAST command in a"
echo "     && / || chain in the rollback helpers -- ok/warn always follow and always exit 0"
echo "     -- so the compound statement's own exit status is always 0 regardless of the"
echo "     DELETE outcome, and -e should never fire on it.)"
reset_mocks; common_mocks
MOCK_RESP["GET http://$API/api/config-profiles"]='{"response":{"configProfiles":[]}}'
MOCK_RESP["POST http://$API/api/config-profiles"]='{"response":{"uuid":"CFG-NEW","inbounds":[{"uuid":"IBD-NEW"}]}}'
MOCK_RESP["GET http://$API/api/nodes"]='{"response":[]}'
MOCK_RESP["POST http://$API/api/nodes"]='{"response":{"uuid":"NODE-NEW"}}'
MOCK_RESP["GET http://$API/api/hosts"]='{"response":[]}'
MOCK_RESP["POST http://$API/api/hosts"]='{"message":"Internal error"}'
MOCK_EXIT["DELETE http://$API/api/nodes/NODE-NEW"]=7
MOCK_EXIT["DELETE http://$API/api/config-profiles/CFG-NEW"]=7
OUT=$(set -euo pipefail; panel_node_register "admin" "pass" "$DOMAIN" "10.0.0.5" 2>&1)
RC=$?
check "under set -e: function still returns 1, not aborted early / not silently 0" "$RC" "1"
check "under set -e: both rollback DELETEs still attempted" \
    "$(call_count "DELETE http://$API/api/config-profiles/CFG-NEW")" "1"

echo "=== Case M: rollback DELETE returns HTTP 404 (Node) -> treated as failure, not silent success ==="
echo "    (Closes a real coverage gap: this exact scenario was never exercised — every prior"
echo "     rollback-DELETE mock used an empty MOCK_RESP body, which (before panel_api_status()"
echo "     was mocked above) never distinguished HTTP status at all. Confirms the current,"
echo "     documented policy — no 404-as-success special-casing until a decision is made,"
echo "     see lib/panel/node/api.sh's own DECISION REQUIRED comment for Config Profile.)"
reset_mocks; common_mocks
MOCK_RESP["GET http://$API/api/config-profiles"]='{"response":{"configProfiles":[]}}'
MOCK_RESP["POST http://$API/api/config-profiles"]='{"response":{"uuid":"CFG-NEW","inbounds":[{"uuid":"IBD-NEW"}]}}'
MOCK_RESP["GET http://$API/api/nodes"]='{"response":[]}'
MOCK_RESP["POST http://$API/api/nodes"]='{"response":{"uuid":"NODE-NEW"}}'
MOCK_RESP["GET http://$API/api/hosts"]='{"response":[]}'
MOCK_RESP["POST http://$API/api/hosts"]='{"message":"Internal error"}'  # host creation fails -> triggers rollback
MOCK_STATUS["DELETE http://$API/api/nodes/NODE-NEW"]="404"
MOCK_STATUS["DELETE http://$API/api/config-profiles/CFG-NEW"]="404"
OUT=$(panel_node_register "admin" "pass" "$DOMAIN" "10.0.0.5" 2>&1)
RC=$?
check "original failure is STILL returned" "$RC" "1"
check "Node rollback DELETE was actually attempted" "$(call_count "DELETE http://$API/api/nodes/NODE-NEW")" "1"
check "404 on Node rollback DELETE is NOT reported as success" \
    "$(echo "$OUT" | grep -Fc "Нода удалена (rollback)")" "0"
check "404 on Node rollback DELETE is reported as a failure needing manual check" \
    "$(echo "$OUT" | grep -Fc "Не удалось откатить создание ноды")" "1"

echo "=== Case N: rollback DELETE returns HTTP 500 (Config Profile) -> treated as failure, not silent success ==="
reset_mocks; common_mocks
MOCK_RESP["GET http://$API/api/config-profiles"]='{"response":{"configProfiles":[]}}'
MOCK_RESP["POST http://$API/api/config-profiles"]='{"response":{"uuid":"CFG-NEW","inbounds":[{"uuid":"IBD-NEW"}]}}'
MOCK_RESP["GET http://$API/api/nodes"]='{"response":[]}'
MOCK_RESP["POST http://$API/api/nodes"]='{"message":"Internal error"}'  # node creation fails -> triggers profile rollback only
MOCK_STATUS["DELETE http://$API/api/config-profiles/CFG-NEW"]="500"
OUT=$(panel_node_register "admin" "pass" "$DOMAIN" "10.0.0.5" 2>&1)
RC=$?
check "original failure is STILL returned" "$RC" "1"
check "Profile rollback DELETE was actually attempted" "$(call_count "DELETE http://$API/api/config-profiles/CFG-NEW")" "1"
check "500 on Profile rollback DELETE is NOT reported as success" \
    "$(echo "$OUT" | grep -Fc "Конфиг-профиль удалён (rollback)")" "0"
check "500 on Profile rollback DELETE is reported as a failure needing manual check" \
    "$(echo "$OUT" | grep -Fc "Не удалось откатить создание конфиг-профиля")" "1"

echo "=== Case O: rollback DELETE returns HTTP 204 (both) -> reported as success, not failure ==="
reset_mocks; common_mocks
MOCK_RESP["GET http://$API/api/config-profiles"]='{"response":{"configProfiles":[]}}'
MOCK_RESP["POST http://$API/api/config-profiles"]='{"response":{"uuid":"CFG-NEW","inbounds":[{"uuid":"IBD-NEW"}]}}'
MOCK_RESP["GET http://$API/api/nodes"]='{"response":[]}'
MOCK_RESP["POST http://$API/api/nodes"]='{"response":{"uuid":"NODE-NEW"}}'
MOCK_RESP["GET http://$API/api/hosts"]='{"response":[]}'
MOCK_RESP["POST http://$API/api/hosts"]='{"message":"Internal error"}'
MOCK_STATUS["DELETE http://$API/api/nodes/NODE-NEW"]="204"
MOCK_STATUS["DELETE http://$API/api/config-profiles/CFG-NEW"]="204"
OUT=$(panel_node_register "admin" "pass" "$DOMAIN" "10.0.0.5" 2>&1)
RC=$?
check "original failure is STILL returned (rollback success doesn't flip overall result)" "$RC" "1"
check "204 on Node rollback IS reported as success" \
    "$(echo "$OUT" | grep -Fc "Нода удалена (rollback)")" "1"
check "204 on Profile rollback IS reported as success" \
    "$(echo "$OUT" | grep -Fc "Конфиг-профиль удалён (rollback)")" "1"

echo ""
echo "=== SUMMARY: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
