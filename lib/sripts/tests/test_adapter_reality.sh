#!/bin/bash
# lib/sripts/tests/test_adapter_reality.sh
#
# Tests for the second Core/Runtime adapter seam:
#     DEPLOYMENT_TOPOLOGY -> core_topology_requires_nginx_stream()
#         -> panel_core_reality_accept_proxy_protocol() / panel_core_reality_listen_addr()
#         -> panel_setup_api()'s panel_xray_render_inbounds() call (UNCHANGED arguments otherwise)
#
# See lib/core/adapter_reality.sh's own header for the precondition
# proof (panel_setup_api()'s single call site, core_resolve_deployment()
# already run earlier in the same panel_install() invocation).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$REPO_ROOT"

PASS=0
FAIL=0
assert() {
    local desc="$1" actual="$2" expected="$3"
    if [ "$actual" = "$expected" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        echo "  FAIL: $desc -- expected [$expected] got [$actual]"
    fi
}

echo "== bash -n =="
for f in lib/core/adapter_reality.sh lib/panel/api.sh server-manager.sh; do
    bash -n "$f" || { echo "  FAIL: bash -n $f"; FAIL=$((FAIL+1)); }
done

echo ""
echo "== module loading includes adapter_reality =="
assert "core/adapter_reality registered in _MODULE_SHA256" \
    "$(grep -c '"core/adapter_reality"' server-manager.sh)" "1"
assert "core/adapter_reality loaded" \
    "$(grep -c '^_load_module core/adapter_reality$' server-manager.sh)" "1"
LOAD_CHECK=$(bash -c '
    source lib/core/config.sh
    source lib/core/deployment.sh
    source lib/core/adapter_webserver.sh
    source lib/core/adapter_reality.sh
    source lib/ui/output.sh
    source lib/common.sh
    source lib/panel.sh
    type panel_core_reality_accept_proxy_protocol >/dev/null 2>&1 && echo -n "accept_pp:OK "
    type panel_core_reality_listen_addr >/dev/null 2>&1 && echo -n "listen_addr:OK "
    type panel_setup_api >/dev/null 2>&1 && echo -n "panel_setup_api:OK"
')
assert "all three functions available via the real module load order" \
    "$LOAD_CHECK" "accept_pp:OK listen_addr:OK panel_setup_api:OK"

echo ""
echo "== truth table: all four topologies, via resolved Deployment =="
TABLE_OUT=$(bash -c '
    source lib/core/config.sh
    source lib/core/deployment.sh
    source lib/core/adapter_webserver.sh
    source lib/core/adapter_reality.sh
    source lib/ui/output.sh
    source lib/common.sh
    source lib/panel.sh
    for t in 1 2 F J; do
        core_resolve_deployment "$t" "0" "1" "panel.example.com" "sub.example.com" "node.example.com" "" ""
        echo "$t:$(panel_core_reality_accept_proxy_protocol):$(panel_core_reality_listen_addr)"
    done
')
assert "topology 1 -> false / empty" "$(echo "$TABLE_OUT" | grep '^1:')" "1:false:"
assert "topology 2 -> false / empty" "$(echo "$TABLE_OUT" | grep '^2:')" "2:false:"
assert "topology F -> true / 127.0.0.1" "$(echo "$TABLE_OUT" | grep '^F:')" "F:true:127.0.0.1"
assert "topology J -> true / 127.0.0.1" "$(echo "$TABLE_OUT" | grep '^J:')" "J:true:127.0.0.1"

echo ""
echo "== adapter matches legacy MODE-based functions for every topology =="
MATCH_OUT=$(bash -c '
    source lib/core/config.sh
    source lib/core/deployment.sh
    source lib/core/adapter_webserver.sh
    source lib/core/adapter_reality.sh
    source lib/ui/output.sh
    source lib/common.sh
    source lib/panel.sh
    for t in 1 2 F J; do
        core_resolve_deployment "$t" "0" "1" "panel.example.com" "sub.example.com" "node.example.com" "" ""
        a_pp=$(panel_core_reality_accept_proxy_protocol); l_pp=$(panel_reality_accept_proxy_protocol "$t")
        a_la=$(panel_core_reality_listen_addr);            l_la=$(panel_reality_listen_addr "$t")
        [ "$a_pp" = "$l_pp" ] && [ "$a_la" = "$l_la" ] && echo "$t:MATCH" || echo "$t:MISMATCH"
    done
')
for t in 1 2 F J; do
    assert "adapter == legacy for topology $t" "$(echo "$MATCH_OUT" | grep "^$t:")" "$t:MATCH"
done

echo ""
echo "== panel_setup_api()'s actual render call: byte-identical INBOUNDS_JSON, old vs new call pattern =="
IDENTITY_OUT=$(bash -c '
    source lib/core/config.sh
    source lib/core/deployment.sh
    source lib/core/adapter_webserver.sh
    source lib/core/adapter_reality.sh
    source lib/ui/output.sh
    source lib/common.sh
    source lib/panel.sh

    for MODE in 1 2 F J; do
        for XHTTP in 0 1; do
            [ "$MODE" != "F" ] && [ "$XHTTP" = "1" ] && continue
            OLD=$(panel_xray_render_inbounds "$MODE" "PRIVK" "shortid" "/dev/shm/nginx.sock" "example.com" 8443 19444 "/xhttp" \
                "$(panel_reality_accept_proxy_protocol "$MODE")" "$XHTTP" "$(panel_reality_listen_addr "$MODE")")

            core_resolve_deployment "$MODE" "$XHTTP" "1" "panel.example.com" "sub.example.com" "example.com" "" ""
            NEW=$(panel_xray_render_inbounds "$MODE" "PRIVK" "shortid" "/dev/shm/nginx.sock" "example.com" 8443 19444 "/xhttp" \
                "$(panel_core_reality_accept_proxy_protocol)" "$XHTTP" "$(panel_core_reality_listen_addr)")

            [ "$OLD" = "$NEW" ] && echo "MODE${MODE}_XHTTP${XHTTP}:IDENTICAL" || echo "MODE${MODE}_XHTTP${XHTTP}:DIFFERS"
        done
    done
')
while IFS=: read -r label result; do
    [ -z "$label" ] && continue
    assert "render output byte-identical: $label" "$result" "IDENTICAL"
done <<< "$IDENTITY_OUT"

echo ""
echo "== behavioral proof: adapter follows Core state, no MODE variable in scope at all =="
BEHAVIORAL_OUT=$(bash -c '
    source lib/core/config.sh
    source lib/core/deployment.sh
    source lib/core/adapter_webserver.sh
    source lib/core/adapter_reality.sh
    source lib/ui/output.sh
    source lib/common.sh
    source lib/panel.sh

    # No core_resolve_deployment() call at all -- hand-set Core state,
    # no MODE variable exists anywhere in this subshell.
    DEPLOYMENT_TOPOLOGY="F"
    echo "hand_built_F:$(panel_core_reality_accept_proxy_protocol):$(panel_core_reality_listen_addr)"

    DEPLOYMENT_TOPOLOGY="1"
    echo "hand_built_1:$(panel_core_reality_accept_proxy_protocol):$(panel_core_reality_listen_addr)"

    # Flip ONLY DEPLOYMENT_TOPOLOGY again -- output must flip with it.
    DEPLOYMENT_TOPOLOGY="J"
    echo "hand_built_J:$(panel_core_reality_accept_proxy_protocol):$(panel_core_reality_listen_addr)"
')
assert "hand-built topology=F (no resolver, no MODE) -> true/127.0.0.1" \
    "$(echo "$BEHAVIORAL_OUT" | grep '^hand_built_F:')" "hand_built_F:true:127.0.0.1"
assert "hand-built topology=1 (no resolver, no MODE) -> false/empty" \
    "$(echo "$BEHAVIORAL_OUT" | grep '^hand_built_1:')" "hand_built_1:false:"
assert "flipping ONLY DEPLOYMENT_TOPOLOGY to J changes output back to true/127.0.0.1" \
    "$(echo "$BEHAVIORAL_OUT" | grep '^hand_built_J:')" "hand_built_J:true:127.0.0.1"

echo ""
echo "== adapter contains no MODE/topology literal dispatch of its own (code lines only) =="
_adapter_code_only() { grep -vE '^\s*#' lib/core/adapter_reality.sh; }
assert "no literal MODE comparison in adapter_reality.sh code" \
    "$(_adapter_code_only | grep -cE '"\$(MODE|DEPLOYMENT_TOPOLOGY)"\s*=\s*"[FJ12]"')" "0"
assert "adapter does not reference port variables" \
    "$(_adapter_code_only | grep -ciE 'PORT')" "0"
assert "adapter does not reference TeleMT" \
    "$(_adapter_code_only | grep -ci 'telemt')" "0"
assert "adapter does not reference RuntimeComponent" \
    "$(_adapter_code_only | grep -ci 'runtime_component')" "0"
assert "adapter calls core_topology_requires_nginx_stream exactly twice (once per function)" \
    "$(_adapter_code_only | grep -c 'core_topology_requires_nginx_stream')" "2"

echo ""
echo "== legacy functions preserved (not deleted), still directly callable =="
assert "panel_reality_accept_proxy_protocol still defined" \
    "$(grep -c '^panel_reality_accept_proxy_protocol()' lib/panel/api.sh)" "1"
assert "panel_reality_listen_addr still defined" \
    "$(grep -c '^panel_reality_listen_addr()' lib/panel/api.sh)" "1"
assert "panel_reality_needs_2222_ufw_rule + panel_reality_dest_val untouched (still MODE-based, 2 matches)" \
    "$(grep -c 'MODE.*=.*"1".*||.*MODE.*=.*"F".*||.*MODE.*=.*"J"' lib/panel/api.sh)" "2"

echo ""
echo "== port-related decisions remain untouched (not migrated) =="
assert "panel_reality_inbound_port still called with \$MODE at the call site" \
    "$(grep -c 'panel_reality_inbound_port \"\$MODE\"' lib/panel/api.sh)" "1"
assert "panel_reality_xhttp_inbound_port still called with \$MODE at the call site" \
    "$(grep -c 'panel_reality_xhttp_inbound_port \"\$MODE\"' lib/panel/api.sh)" "1"

echo ""
echo "== full existing F+XHTTP suite still passes (covers panel_reality_* legacy unit tests directly) =="
if bash lib/sripts/tests/test_f_xhttp_commit2.sh >/tmp/_adapter_reality_fxhttp_rerun.log 2>&1; then
    assert "test_f_xhttp_commit2.sh still fully passes" "pass" "pass"
else
    assert "test_f_xhttp_commit2.sh still fully passes" "fail" "pass"
    tail -20 /tmp/_adapter_reality_fxhttp_rerun.log
fi

echo ""
echo "== SUMMARY: PASS=$PASS FAIL=$FAIL =="
[ "$FAIL" -eq 0 ]
exit $?
