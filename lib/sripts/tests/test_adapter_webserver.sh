#!/bin/bash
# lib/sripts/tests/test_adapter_webserver.sh
#
# Tests for the first Core/Runtime adapter seam that actually
# participates in the real execution flow:
#     legacy input -> core_resolve_deployment() -> Deployment
#         -> panel_core_generate_webserver_config() (lib/core/adapter_webserver.sh)
#         -> panel_generate_webserver_config() (UNCHANGED, lib/panel/nginx/config.sh)
#
# See docs/CORE_RUNTIME_CONTRACTS.md and lib/core/adapter_webserver.sh's
# own header for the contract this seam implements.
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
for f in lib/core/adapter_webserver.sh lib/core/deployment.sh lib/panel/install.sh server-manager.sh; do
    bash -n "$f" || { echo "  FAIL: bash -n $f"; FAIL=$((FAIL+1)); }
done

echo ""
echo "== real load chain: functions actually available together =="
LOAD_CHECK=$(bash -c '
    source lib/core/config.sh
    source lib/core/deployment.sh
    source lib/core/adapter_webserver.sh
    source lib/ui/output.sh
    source lib/common.sh
    source lib/panel.sh
    type core_resolve_deployment >/dev/null 2>&1 && echo -n "resolver:OK "
    type panel_core_generate_webserver_config >/dev/null 2>&1 && echo -n "adapter:OK "
    type panel_generate_webserver_config >/dev/null 2>&1 && echo -n "legacy:OK"
')
assert "all three functions available via the real module load order" \
    "$LOAD_CHECK" "resolver:OK adapter:OK legacy:OK"

echo ""
echo "== server-manager.sh module registry includes the new modules =="
assert "core/deployment registered" \
    "$(grep -c '"core/deployment"' server-manager.sh)" "1"
assert "core/adapter_webserver registered" \
    "$(grep -c '"core/adapter_webserver"' server-manager.sh)" "1"
assert "core/deployment loaded before panel module" \
    "$(awk '/_load_module core\/deployment/{d=NR} /^_load_module panel$/{p=NR} END{print (d>0 && p>0 && d<p) ? "yes" : "no"}' server-manager.sh)" \
    "yes"

echo ""
echo "== byte-identity: adapter output == direct legacy call output =="
IDENTITY_OUT=$(bash -c '
    source lib/core/config.sh
    source lib/core/deployment.sh
    source lib/core/adapter_webserver.sh
    source lib/ui/output.sh
    source lib/common.sh
    source lib/panel.sh

    compare() {
        local label="$1" MODE="$2" F_XHTTP="$3" WS="$4" PD="$5" SD="$6" SSD="$7" TD="$8" TP="$9"
        mkdir -p /opt/remnawave
        panel_generate_webserver_config "$WS" "$MODE" "$PD" "$SD" "$SSD" "$PD" "$SD" "$SSD" "CK" "CV" "$TD" "$TP" "$F_XHTTP" >/dev/null 2>/dev/null
        cp /opt/remnawave/nginx.conf /tmp/_adapter_test_legacy.conf 2>/dev/null || : > /tmp/_adapter_test_legacy.conf

        core_resolve_deployment "$MODE" "$F_XHTTP" "$WS" "$PD" "$SD" "$SSD" "$TD" "$TP"
        panel_core_generate_webserver_config "$PD" "$SD" "$SSD" "CK" "CV" >/dev/null 2>/dev/null
        cp /opt/remnawave/nginx.conf /tmp/_adapter_test_adapter.conf 2>/dev/null || : > /tmp/_adapter_test_adapter.conf

        if diff -q /tmp/_adapter_test_legacy.conf /tmp/_adapter_test_adapter.conf >/dev/null 2>&1; then
            echo "$label:IDENTICAL"
        else
            echo "$label:DIFFERS"
        fi
    }

    compare "mode1"       "1" "0" "1" "panel.example.com" "sub.example.com" "node.example.com" "" ""
    compare "mode1_caddy" "1" "0" "2" "panel.example.com" "sub.example.com" "node.example.com" "" ""
    compare "mode2"       "2" "0" "1" "panel.example.com" "sub.example.com" "node.example.com" "" ""
    compare "modeF"       "F" "0" "1" "panel.example.com" "sub.example.com" "node.example.com" "" ""
    compare "modeF_xhttp" "F" "1" "1" "panel.example.com" "sub.example.com" "node.example.com" "" ""
    compare "modeF_telemt" "F" "0" "1" "panel.example.com" "sub.example.com" "node.example.com" "mtproto.example.com" "9443"
    compare "modeF_xhttp_telemt" "F" "1" "1" "panel.example.com" "sub.example.com" "node.example.com" "mtproto.example.com" "9443"
    compare "modeJ"       "J" "0" "1" "panel.example.com" "sub.example.com" "node.example.com" "" ""
    compare "modeJ_telemt" "J" "0" "1" "panel.example.com" "sub.example.com" "node.example.com" "mtproto.example.com" "9443"
')
while IFS=: read -r label result; do
    [ -z "$label" ] && continue
    assert "byte-identical: $label" "$result" "IDENTICAL"
done <<< "$IDENTITY_OUT"

echo ""
echo "== behavioral proof: adapter follows Core state, not its own MODE check =="
# The strong version of this proof, per the task: bypass
# core_resolve_deployment() ENTIRELY -- no legacy MODE variable exists
# anywhere in this subshell at all -- and set DEPLOYMENT_* by hand. If
# the adapter still dispatches correctly purely from that hand-set Core
# state, it cannot possibly contain a hidden legacy-MODE-based decision
# of its own (there is no MODE to read). Flipping ONLY
# DEPLOYMENT_TOPOLOGY between two otherwise-identical calls and watching
# the generator identity actually change is a stronger proof than
# grepping the adapter's source for the string "MODE".
BEHAVIORAL_OUT=$(bash -c '
    source lib/core/config.sh
    source lib/core/deployment.sh
    source lib/core/adapter_webserver.sh
    source lib/ui/output.sh
    source lib/common.sh
    source lib/panel.sh
    mkdir -p /opt/remnawave

    # Hand-built Deployment for topology "F" -- core_resolve_deployment()
    # is never called in this block.
    DEPLOYMENT_TOPOLOGY="F"
    DEPLOYMENT_CAPABILITIES=()
    DEPLOYMENT_DOMAIN_PANEL="panel.example.com"
    DEPLOYMENT_DOMAIN_SUB="sub.example.com"
    DEPLOYMENT_DOMAIN_SELFSTEAL="node.example.com"
    DEPLOYMENT_TELEMT_PRESENT="0"
    DEPLOYMENT_TELEMT_DOMAIN=""
    DEPLOYMENT_TELEMT_PORT=""
    _RESOLVER_WEB_SERVER="1"
    panel_core_generate_webserver_config "panel.example.com" "sub.example.com" "node.example.com" "CK" "CV" >/dev/null
    grep -q "SERVER_MANAGER_TOPOLOGY=F" /opt/remnawave/nginx.conf && echo "hand_built_F:F"

    # Flip ONLY DEPLOYMENT_TOPOLOGY to "J" -- nothing else changes, no
    # resolver call, no MODE variable anywhere in this subshell.
    DEPLOYMENT_TOPOLOGY="J"
    panel_core_generate_webserver_config "panel.example.com" "sub.example.com" "node.example.com" "CK" "CV" >/dev/null
    grep -q "SERVER_MANAGER_TOPOLOGY=J" /opt/remnawave/nginx.conf && echo "hand_built_J:J"

    # DEPLOYMENT_CAPABILITIES containing XHTTP, still topology F, still
    # no resolver call -- the adapter must derive F_XHTTP_ENABLE=1 purely
    # from this array, producing the XHTTP-shaped upstream.
    DEPLOYMENT_TOPOLOGY="F"
    DEPLOYMENT_CAPABILITIES=("XHTTP")
    panel_core_generate_webserver_config "panel.example.com" "sub.example.com" "node.example.com" "CK" "CV" >/dev/null
    grep -q "xray_xhttp_f" /opt/remnawave/nginx.conf && echo "hand_built_F_xhttp:PRESENT"
')
assert "hand-built Deployment (topology=F, no resolver call) -> F marker" \
    "$(echo "$BEHAVIORAL_OUT" | grep -c "hand_built_F:F")" "1"
assert "flipping ONLY DEPLOYMENT_TOPOLOGY to J changes generator output to J" \
    "$(echo "$BEHAVIORAL_OUT" | grep -c "hand_built_J:J")" "1"
assert "DEPLOYMENT_CAPABILITIES=(XHTTP) alone (no resolver) enables F's XHTTP leg" \
    "$(echo "$BEHAVIORAL_OUT" | grep -c "hand_built_F_xhttp:PRESENT")" "1"

echo ""
echo "== adapter contains no F/J dispatch table of its own (code lines only; comments explaining the design are expected and excluded, same convention as test_deployment_resolver.sh's own MODE-blind audit) =="
_adapter_code_only() { grep -vE '^\s*#' lib/core/adapter_webserver.sh; }
assert "no literal MODE/topology string comparison in adapter_webserver.sh code" \
    "$(_adapter_code_only | grep -cE '"\$(MODE|DEPLOYMENT_TOPOLOGY)"\s*=\s*"[FJ12]"')" "0"
assert "adapter does not call variant_f.sh/variant_j.sh generators directly (code)" \
    "$(_adapter_code_only | grep -cE 'panel_generate_nginx_config_(f|j)\b')" "0"
assert "adapter does not source/reference runtime_component.sh (code)" \
    "$(_adapter_code_only | grep -c 'runtime_component')" "0"

echo ""
echo "== F/J generators receive unchanged arguments (spot-check via existing F+XHTTP suite) =="
# Not re-testing generator internals here -- test_f_xhttp_commit2.sh
# already covers that exhaustively and is unaffected by this seam (it
# calls the generators directly, never through the adapter).
if bash lib/sripts/tests/test_f_xhttp_commit2.sh >/tmp/_adapter_fxhttp_rerun.log 2>&1; then
    assert "test_f_xhttp_commit2.sh still fully passes after adapter wiring" "pass" "pass"
else
    assert "test_f_xhttp_commit2.sh still fully passes after adapter wiring" "fail" "pass"
    tail -20 /tmp/_adapter_fxhttp_rerun.log
fi

echo ""
echo "== SUMMARY: PASS=$PASS FAIL=$FAIL =="
[ "$FAIL" -eq 0 ]
exit $?
