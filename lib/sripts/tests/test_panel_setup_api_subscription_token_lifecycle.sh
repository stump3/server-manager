#!/bin/bash
# lib/sripts/tests/test_panel_setup_api_subscription_token_lifecycle.sh
#
# DEFECT #1 lifecycle analysis (subscription-page API token) — this is a
# CHARACTERIZATION test of the invariants the analysis rests on, not a
# test of a behavior change (lib/panel/api.sh is deliberately untouched
# for DEFECT #1; see the analysis report for why no safe fix exists).
#
# Facts pinned here (all mechanically checked against the REAL
# panel_setup_api(), mocked only at the panel_api()/panel_api_status()
# boundary and the OS-command boundary, run under production's
# `set -euo pipefail`):
#
#   1. First install: exactly one POST /api/tokens {name:"subscription-page",
#      expiresInDays:365, scopes:["*"]}; the returned secret is injected
#      into /opt/remnawave/docker-compose.yml (sed on the PLACEHOLDER)
#      BEFORE the subscription-page restart; no other /api/tokens call
#      (no GET, no DELETE) is ever made — unrelated tokens are untouched.
#   2. Re-run against an already-provisioned Panel (superadmin exists) with
#      credentials that do not match (the only situation panel_install()
#      can produce: panel_generate_env() mints fresh random creds every
#      call and persists them nowhere) dies at login, BEFORE any
#      /api/tokens call. This is why a second token is not minted today.
#   3. Token CREATE failure (HTTP error body / transport failure) stays
#      non-fatal: rc=0, secret NOT injected (PLACEHOLDER kept), a manual-
#      creation warning is printed, exactly one attempt, no DELETE.
#   4. Structural preconditions of (2) and of "no reusable secret exists":
#      panel_setup_api() has exactly one production caller; that caller
#      is preceded by the existing-state guard AND by compose regeneration;
#      the compose template's placeholder is exactly what the sed targets.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$REPO_ROOT" || exit 2

PASS=0; FAIL=0
check() {
    local desc="$1" got="$2" expected="$3"
    if [ "$got" = "$expected" ]; then PASS=$((PASS+1))
    else FAIL=$((FAIL+1)); echo "  FAIL: $desc (expected [$expected], got [$got])"; fi
}
check_nz() {
    if [ "$2" != "0" ] && [ -n "$2" ]; then PASS=$((PASS+1))
    else FAIL=$((FAIL+1)); echo "  FAIL: $1 (expected non-zero, got [$2])"; fi
}

bash -n lib/panel/api.sh && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: bash -n lib/panel/api.sh"; }

API="127.0.0.1:3000"; U="http://$API/api"
CALL_LOG="$(mktemp)"; BODY_LOG="$(mktemp)"; SED_LOG="$(mktemp)"; ERR_LOG="$(mktemp)"
trap 'rm -f "$CALL_LOG" "$BODY_LOG" "$SED_LOG" "$ERR_LOG"' EXIT

declare -A MOCK_RESP MOCK_EXIT MOCK_STATUS
n_calls()  { local n; n=$(grep -Fxc "$1" "$CALL_LOG" 2>/dev/null); echo "${n:-0}"; }
n_prefix() { local n; n=$(grep -c "^$1" "$CALL_LOG" 2>/dev/null); echo "${n:-0}"; }
idx()      { grep -Fxn "$1" "$CALL_LOG" 2>/dev/null | head -1 | cut -d: -f1; }

fresh_mocks() {
    MOCK_RESP=(); MOCK_EXIT=(); MOCK_STATUS=()
    MOCK_RESP["POST $U/auth/register"]='{"response":{"accessToken":"TOK"}}'; MOCK_STATUS["POST $U/auth/register"]=200
    MOCK_RESP["GET $U/system/tools/x25519/generate"]='{"response":{"keypairs":[{"privateKey":"PRIV"}]}}'
    MOCK_RESP["GET $U/keygen"]='{"response":{"secretKey":"PUB"}}'
    MOCK_RESP["GET $U/config-profiles"]='{"response":{"configProfiles":[]}}'
    MOCK_RESP["POST $U/config-profiles"]='{"response":{"uuid":"CFG-NEW","inbounds":[{"tag":"Steal","uuid":"IBD-NEW"}]}}'
    MOCK_RESP["GET $U/nodes"]='{"response":[]}'
    MOCK_RESP["POST $U/nodes"]='{"response":{"uuid":"NODE-NEW"}}'
    MOCK_RESP["GET $U/hosts"]='{"response":[]}'
    MOCK_RESP["POST $U/hosts"]='{"response":{"uuid":"HOST-NEW"}}'
    MOCK_RESP["GET $U/internal-squads"]='{"response":{"internalSquads":[]}}'
    MOCK_RESP["POST $U/tokens"]='{"response":{"uuid":"TKN-UUID","name":"subscription-page","token":"SUBTOK"}}'
    MOCK_STATUS["POST $U/tokens"]=201
}

run_setup() {
    : > "$CALL_LOG"; : > "$BODY_LOG"; : > "$SED_LOG"; : > "$ERR_LOG"
    (
        source lib/ui/output.sh
        source lib/panel/api.sh
        panel_api() { echo "$1 $2" >> "$CALL_LOG"; printf '%s' "${MOCK_RESP["$1 $2"]:-}"; return "${MOCK_EXIT["$1 $2"]:-0}"; }
        panel_api_status() {
            echo "$1 $2" >> "$CALL_LOG"
            [ "$1 $2" = "POST $U/tokens" ] && printf '%s\n' "${4:-}" >> "$BODY_LOG"
            printf '%s%s' "${MOCK_RESP["$1 $2"]:-}" "${MOCK_STATUS["$1 $2"]:-204}"
            return "${MOCK_EXIT["$1 $2"]:-0}"
        }
        cd() { :; }; sleep() { :; }; curl() { return 0; }; ufw() { :; }; spinner() { :; }
        sed()    { echo "sed $*" >> "$SED_LOG"; echo "sed" >> "$CALL_LOG"; }
        docker() { echo "docker $*" >> "$CALL_LOG"; return 0; }
        core_deployment_has_capability() { return 1; }
        core_runtime_component_exists()  { return 0; }
        core_port_allocation_public()    { echo 8443; }
        panel_core_reality_needs_2222_ufw_rule() { return 1; }
        panel_core_reality_dest_val() { echo /dev/shm/nginx.sock; }
        panel_core_reality_accept_proxy_protocol() { echo true; }
        panel_core_reality_listen_addr() { echo 127.0.0.1; }
        panel_reality_inbound_port() { echo 8443; }
        panel_reality_xhttp_inbound_port() { echo 9443; }
        panel_xray_render_inbounds() { echo '[{"tag":"Steal"}]'; }
        set -euo pipefail
        trap 'wait' EXIT
        panel_setup_api admin pass sni.example.com 1 0
    ) >/dev/null 2>"$ERR_LOG"
    RC=$?
}
token_sed_lines() { grep -c 'REMNAWAVE_API_TOKEN=PLACEHOLDER|REMNAWAVE_API_TOKEN=' "$SED_LOG"; }

echo "== 1. First install: one token, secret reaches compose before the restart =="
fresh_mocks; run_setup
check "rc=0" "$RC" 0
check "exactly one POST /api/tokens" "$(n_calls "POST $U/tokens")" 1
check "request name=subscription-page" "$(jq -r .name "$BODY_LOG")" subscription-page
check "request expiresInDays=365"      "$(jq -r .expiresInDays "$BODY_LOG")" 365
check "request scopes=[*]"             "$(jq -c .scopes "$BODY_LOG")" '["*"]'
check "secret injected into compose (sed PLACEHOLDER -> SUBTOK, docker-compose.yml)" \
    "$(grep -c 'REMNAWAVE_API_TOKEN=PLACEHOLDER|REMNAWAVE_API_TOKEN=SUBTOK|g /opt/remnawave/docker-compose.yml' "$SED_LOG")" 1
first_down=$(idx "docker compose down remnawave-subscription-page")
[ -n "$first_down" ] && [ "$(grep -n '^sed$' "$CALL_LOG" | tail -1 | cut -d: -f1)" -lt "$first_down" ] && ord=yes || ord=no
check "secret injected BEFORE subscription-page restart" "$ord" yes
check "no other /api/tokens call (no GET/DELETE): unrelated tokens untouched" \
    "$(( $(n_prefix "GET $U/tokens") + $(n_prefix "DELETE $U/tokens") + $(n_prefix "PATCH $U/tokens") ))" 0

echo "== 2. Existing DB + non-matching creds: dies at login, never reaches /api/tokens =="
fresh_mocks
MOCK_RESP["POST $U/auth/register"]='{"message":"Forbidden","errorCode":"E000"}'; MOCK_STATUS["POST $U/auth/register"]=403
MOCK_RESP["POST $U/auth/login"]='{"message":"Invalid credentials","statusCode":401}'
run_setup
check_nz "rc non-zero (die)" "$RC"
check "login was attempted" "$(n_calls "POST $U/auth/login")" 1
check "zero calls to /api/tokens" "$(n_prefix ".* $U/tokens")" 0
check "no Profile/Node/Host CREATE either" "$(( $(n_calls "POST $U/config-profiles") + $(n_calls "POST $U/nodes") + $(n_calls "POST $U/hosts") ))" 0
check "compose token sed never ran" "$(token_sed_lines)" 0

echo "== 3. Token CREATE failure stays non-fatal, secret not injected, no retry/DELETE =="
fresh_mocks; MOCK_RESP["POST $U/tokens"]='{"message":"Bad Request","statusCode":400}'; MOCK_STATUS["POST $U/tokens"]=400
run_setup
check "3a HTTP 400: rc=0 (existing semantics)" "$RC" 0
check "3a exactly one attempt" "$(n_calls "POST $U/tokens")" 1
check "3a placeholder kept: no token sed" "$(token_sed_lines)" 0
check "3a manual-creation warning printed" "$(grep -c 'останется без токена' "$ERR_LOG")" 1
check "3a no DELETE anywhere" "$(n_prefix DELETE)" 0
fresh_mocks; MOCK_RESP["POST $U/tokens"]=''; MOCK_EXIT["POST $U/tokens"]=7
run_setup
check "3b transport failure: rc=0" "$RC" 0
check "3b transport failure reported" "$(grep -c 'transport failure' "$ERR_LOG")" 1
check "3b placeholder kept" "$(token_sed_lines)" 0

echo "== 4. Structural preconditions =="
CALLERS=$(grep -rnI 'panel_setup_api ' lib --include=*.sh | grep -v '/tests/' | grep -vE '^[^:]+:[0-9]+:\s*#' | grep -v 'panel_setup_api()' | wc -l)
check "panel_setup_api has exactly one production caller" "$CALLERS" 1
check "that caller is lib/panel/install.sh" "$(grep -rnI 'panel_setup_api "' lib --include=*.sh | grep -v '/tests/' | cut -d: -f1 | sort -u)" lib/panel/install.sh
INST=$(awk '/^panel_install\(\) \{/,/^}/' lib/panel/install.sh | grep -vE '^\s*#')
g=$(grep -n 'panel_install_existing_state_detected' <<<"$INST" | head -1 | cut -d: -f1)
c=$(grep -n 'panel_generate_compose ' <<<"$INST" | head -1 | cut -d: -f1)
s=$(grep -n 'panel_setup_api ' <<<"$INST" | head -1 | cut -d: -f1)
check "install: existing-state guard precedes panel_setup_api" "$([ -n "$g" ] && [ -n "$s" ] && [ "$g" -lt "$s" ] && echo yes || echo no)" yes
check "install: compose regeneration precedes panel_setup_api" "$([ -n "$c" ] && [ -n "$s" ] && [ "$c" -lt "$s" ] && echo yes || echo no)" yes
check "compose generation is invoked only from panel_install (single production call site)" \
    "$(grep -rnI 'panel_generate_compose ' lib --include=*.sh | grep -v '/tests/' | grep -vE '^[^:]+:[0-9]+:\s*#' | grep -v 'panel_generate_compose()' | wc -l)" 1
( source lib/ui/output.sh; source lib/panel/compose/common.sh; panel_compose_subpage_block ) > /tmp/_subblock.$$ 2>/dev/null
check "compose template carries exactly one REMNAWAVE_API_TOKEN=PLACEHOLDER (the sed target)" \
    "$(grep -c '^      - REMNAWAVE_API_TOKEN=PLACEHOLDER$' /tmp/_subblock.$$)" 1
rm -f /tmp/_subblock.$$

echo ""
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
