#!/bin/bash
# lib/sripts/tests/test_adapter_install_xhttp_ufw.sh
#
# Adapter #9: lib/panel/install.sh's panel_install() F+XHTTP/J public XHTTP
# firewall gate moves from a raw
# `[ "$MODE" = "J" ] || { [ "$MODE" = "F" ] && [ "$F_XHTTP_ENABLE" = "1" ]; }`
# to the existing, already-in-production-use Core query
# lib/core/deployment.sh:core_deployment_has_capability("XHTTP") -- the same
# accessor this same function already calls a few lines below (Adapter #4,
# _api_xhttp_enable). WHICH port to open (J_XHTTP_PUBLIC_PORT vs
# F_XHTTP_PUBLIC_PORT) is untouched -- still a raw MODE branch, deliberately
# (PortAllocation is not yet a Core concept).
#
# Precondition (not assumed -- verified below in section 7): core_resolve_
# deployment() (lib/panel/install.sh) runs strictly before this gate, so
# DEPLOYMENT_* is already resolved and core_deployment_has_capability() is
# safe to call directly, with no MODE/F_XHTTP_ENABLE argument of its own.
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

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

echo "== A. bash -n lib/panel/install.sh =="
bash -n lib/panel/install.sh 2>/tmp/_a9_synerr && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: bash -n lib/panel/install.sh"; cat /tmp/_a9_synerr; }
rm -f /tmp/_a9_synerr

echo ""
echo "== B. production source inspection: target gate calls the Core accessor =="
assert "install.sh's XHTTP UFW gate calls core_deployment_has_capability \"XHTTP\" (exactly once)" \
    "$(grep -c 'if core_deployment_has_capability "XHTTP"; then' lib/panel/install.sh)" "1"
assert "old combined raw gate (MODE=F && F_XHTTP_ENABLE=1) no longer exists as the top-level condition" \
    "$(grep -cE '^\s*elif \[ "\$MODE" = "F" \] && \[ "\$F_XHTTP_ENABLE" = "1" \]; then$' lib/panel/install.sh)" "0"
assert "MODE=\"J\" comparison still present, but only nested inside the capability gate (port selection, untouched)" \
    "$(grep -cE '^\s*if \[ "\$MODE" = "J" \]; then$' lib/panel/install.sh)" "1"
assert "J_XHTTP_PUBLIC_PORT still referenced in the actual ufw allow line (port choice untouched)" \
    "$(grep -c 'ufw allow \"\${J_XHTTP_PUBLIC_PORT:-8443}/tcp\"' lib/panel/install.sh)" "1"
assert "F_XHTTP_PUBLIC_PORT still referenced in the actual ufw allow line (port choice untouched)" \
    "$(grep -c 'ufw allow \"\${F_XHTTP_PUBLIC_PORT:-9443}/tcp\"' lib/panel/install.sh)" "1"

# ---------------------------------------------------------------------
# Extract the ACTUAL production block verbatim (lines between the gate's
# own `if core_deployment_has_capability "XHTTP"; then` and its matching
# `fi`) so sections D/E/F execute the real code, not a hand-copied
# reimplementation of it.
# ---------------------------------------------------------------------
extract_gate() {
    local src="$1"
    awk '
        /if core_deployment_has_capability "XHTTP"; then/ { found=1 }
        found { print; if (/^    fi$/) exit }
    ' "$src"
}

GATE_BLOCK="$(extract_gate lib/panel/install.sh)"

echo ""
echo "== C. negative mutation: neutralize core_deployment_has_capability, confirm the REAL extracted gate is load-bearing on it =="
run_gate_with_capability_stub() {
    # $1 MODE  $2 F_XHTTP_ENABLE  $3 stub behavior: "real" | "always_false"
    local _mode="$1" _f_xhttp_enable="$2" _stub="$3"
    local _capture="$WORKDIR/ufw_capture_$$_$RANDOM"
    : > "$_capture"
    (
        source lib/core/config.sh
        source lib/core/topology.sh
        source lib/core/deployment.sh
        # Real production code redirects ufw's own stdout/stderr to
        # /dev/null (`>/dev/null 2>&1`, unchanged by Adapter #9) -- so the
        # mock records the call it received to a file instead of stdout,
        # which the redirect would otherwise swallow exactly as it swallows
        # real ufw's own output.
        ufw() { echo "UFW_CALL:$*" >> "$_capture"; }
        MODE="$_mode"
        F_XHTTP_ENABLE="$_f_xhttp_enable"
        core_resolve_deployment "$MODE" "$F_XHTTP_ENABLE" "1" \
            "panel.example.com" "sub.example.com" "node.example.com" "" ""
        if [ "$_stub" = "always_false" ]; then
            core_deployment_has_capability() { return 1; }
        fi
        eval "$GATE_BLOCK"
    )
    cat "$_capture"
    rm -f "$_capture"
}

REAL_J="$(run_gate_with_capability_stub J "" real)"
MUT_J="$(run_gate_with_capability_stub J "" always_false)"
assert "real accessor: MODE=J opens the XHTTP port" "$REAL_J" "UFW_CALL:allow 8443/tcp comment Variant J XHTTP"
assert "mutated (accessor forced false): MODE=J now opens NOTHING (proves the gate is load-bearing on the accessor, not a coincidental pass)" \
    "$MUT_J" ""

echo ""
echo "== D. truth table: core_deployment_has_capability(\"XHTTP\") gate, all 5 reachable combinations =="
run_gate() { run_gate_with_capability_stub "$1" "$2" real; }

T1="$(run_gate 1 "0")"
T2="$(run_gate 2 "0")"
TF0="$(run_gate F "0")"
TF1="$(run_gate F "1")"
TJ="$(run_gate J "0")"

assert "MODE=1: no UFW XHTTP rule" "$T1" ""
assert "MODE=2: no UFW XHTTP rule" "$T2" ""
assert "MODE=F, F_XHTTP_ENABLE=0: no UFW XHTTP rule" "$TF0" ""
assert "MODE=F, F_XHTTP_ENABLE=1: allow F_XHTTP_PUBLIC_PORT" "$TF1" "UFW_CALL:allow 9443/tcp comment Variant F XHTTP"
assert "MODE=J: allow J_XHTTP_PUBLIC_PORT" "$TJ" "UFW_CALL:allow 8443/tcp comment Variant J XHTTP"

echo ""
echo "== E. UFW command selection (explicit port values, not defaults) =="
run_gate_with_ports() {
    local _mode="$1" _f_xhttp_enable="$2" _j_port="$3" _f_port="$4"
    local _capture="$WORKDIR/ufw_capture_ports_$$_$RANDOM"
    : > "$_capture"
    (
        source lib/core/config.sh
        source lib/core/topology.sh
        source lib/core/deployment.sh
        ufw() { echo "UFW_CALL:$*" >> "$_capture"; }
        MODE="$_mode"
        F_XHTTP_ENABLE="$_f_xhttp_enable"
        J_XHTTP_PUBLIC_PORT="$_j_port"
        F_XHTTP_PUBLIC_PORT="$_f_port"
        core_resolve_deployment "$MODE" "$F_XHTTP_ENABLE" "1" \
            "panel.example.com" "sub.example.com" "node.example.com" "" ""
        eval "$GATE_BLOCK"
    )
    cat "$_capture"
    rm -f "$_capture"
}
assert "F+XHTTP uses F_XHTTP_PUBLIC_PORT (12345), not J's" \
    "$(run_gate_with_ports F 1 55555 12345)" "UFW_CALL:allow 12345/tcp comment Variant F XHTTP"
assert "J uses J_XHTTP_PUBLIC_PORT (55555), not F's" \
    "$(run_gate_with_ports J 0 55555 12345)" "UFW_CALL:allow 55555/tcp comment Variant J XHTTP"

echo ""
echo "== F. regression against accidental port swap =="
assert "J never gets F_XHTTP_PUBLIC_PORT's value" \
    "$([ "$(run_gate_with_ports J 0 55555 12345)" = "UFW_CALL:allow 12345/tcp comment Variant J XHTTP" ] && echo swapped || echo ok)" "ok"
assert "F never gets J_XHTTP_PUBLIC_PORT's value" \
    "$([ "$(run_gate_with_ports F 1 55555 12345)" = "UFW_CALL:allow 55555/tcp comment Variant F XHTTP" ] && echo swapped || echo ok)" "ok"

echo ""
echo "== G. call order: core_resolve_deployment() runs before the XHTTP UFW gate in install.sh =="
RESOLVE_LINE=$(grep -n 'core_resolve_deployment "\$MODE"' lib/panel/install.sh | head -1 | cut -d: -f1)
GATE_LINE=$(grep -n 'if core_deployment_has_capability "XHTTP"; then' lib/panel/install.sh | head -1 | cut -d: -f1)
assert "both call sites found (single occurrence each)" \
    "$(grep -c 'core_resolve_deployment "\$MODE"' lib/panel/install.sh):$(grep -c 'if core_deployment_has_capability "XHTTP"; then' lib/panel/install.sh)" \
    "1:1"
[ -n "$RESOLVE_LINE" ] && [ -n "$GATE_LINE" ] && [ "$RESOLVE_LINE" -lt "$GATE_LINE" ] \
    && PASS=$((PASS+1)) \
    || { FAIL=$((FAIL+1)); echo "  FAIL: core_resolve_deployment (line $RESOLVE_LINE) is not before the XHTTP UFW gate (line $GATE_LINE)"; }

echo ""
echo "==================================="
echo "PASS=$PASS FAIL=$FAIL"
echo "==================================="
[ "$FAIL" -eq 0 ]
