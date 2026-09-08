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
# GATE_BLOCK (extracted below, section-wide) is the real production
# block verbatim -- checked CODE-only (comments legitimately still
# discuss F_XHTTP_PUBLIC_PORT/J_XHTTP_PUBLIC_PORT by name as design
# documentation, e.g. explaining why they're no longer read here; that
# prose must not be misread as the variables still being live code).
_B_GATE_BLOCK_PREVIEW="$(awk '
    /if core_deployment_has_capability "XHTTP"; then/ { found=1 }
    found { print; if (/^    fi$/) exit }
' lib/panel/install.sh)"
_B_GATE_CODE_ONLY="$(grep -vE '^\s*#' <<<"$_B_GATE_BLOCK_PREVIEW")"
assert "install.sh's XHTTP UFW block preview actually extracted (non-empty)" \
    "$([ -n "$_B_GATE_BLOCK_PREVIEW" ] && echo present || echo MISSING)" "present"
# UPDATED 2026-09-08 (Candidate 2): the nested `if [ "$MODE" = "J" ]`
# port-selection branch is GONE -- port choice now comes from
# core_port_allocation_public("$MODE", "xhttp") instead, called once,
# unconditionally, inside the capability gate (no MODE branch of its own
# needed at all, since the gate itself already proves MODE is F or J --
# see the production comment on this block for the exhaustive proof).
assert "the old nested MODE=\"J\" port-selection branch is gone (no longer needed -- accessor takes \$MODE directly)" \
    "$(grep -cE '^\s*if \[ "\$MODE" = "J" \]; then$' <<<"$_B_GATE_CODE_ONLY")" "0"
assert "install.sh's XHTTP UFW block's CODE no longer reads F_XHTTP_PUBLIC_PORT at all" \
    "$(grep -c 'F_XHTTP_PUBLIC_PORT' <<<"$_B_GATE_CODE_ONLY")" "0"
assert "install.sh's XHTTP UFW block's CODE no longer reads J_XHTTP_PUBLIC_PORT at all" \
    "$(grep -c 'J_XHTTP_PUBLIC_PORT' <<<"$_B_GATE_CODE_ONLY")" "0"
assert "the gate now calls core_port_allocation_public \"\$MODE\" \"xhttp\" exactly once" \
    "$(grep -c 'core_port_allocation_public "\$MODE" "xhttp"' <<<"$_B_GATE_CODE_ONLY")" "1"
assert "the actual ufw allow line uses the intermediate variable, not an inline command substitution (set -e safety, per the design instruction)" \
    "$(grep -c 'ufw allow "\${_xhttp_ufw_port_desc}/tcp"' <<<"$_B_GATE_CODE_ONLY")" "1"

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
        # UPDATED 2026-09-08 (Candidate 2): the real GATE_BLOCK now calls
        # lib/core/port_allocation.sh's core_port_allocation_public() for
        # the F/J arms (it no longer reads F_XHTTP_PUBLIC_PORT/
        # J_XHTTP_PUBLIC_PORT at all) -- this subshell must source it too,
        # or the eval below hits "command not found" exactly the way
        # test_f_xhttp_commit2.sh did before Candidate 1 fixed its own
        # setup the same way.
        source lib/core/port_allocation.sh
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
echo "== E. UFW port choice comes directly from core_port_allocation_public (F_XHTTP_PUBLIC_PORT/J_XHTTP_PUBLIC_PORT injection no longer applicable) =="
# UPDATED 2026-09-08 (Candidate 2): sections E/F used to inject
# F_XHTTP_PUBLIC_PORT/J_XHTTP_PUBLIC_PORT as env vars into an isolated
# subshell to prove "F never gets J's port and vice versa" without
# needing two different real port values on disk. That technique tested
# a real-looking but not actually real production capability even
# before this migration: lib/panel/nginx/variant_f.sh/variant_j.sh
# assign these as unconditional literals (`F_XHTTP_PUBLIC_PORT=9443`,
# not `${F_XHTTP_PUBLIC_PORT:-9443}`), so any externally-set env var was
# already clobbered the moment those files were sourced in a real
# server-manager.sh run -- only this test's own isolated subshell (which
# never sources variant_f.sh/variant_j.sh at all) let the injection have
# any effect. After Candidate 2, install.sh's UFW block does not read
# either variable at all, so the injection technique no longer tests
# this call site's behavior in any way -- replaced with a negative
# mutation directly on lib/core/port_allocation.sh's own table, proving
# install.sh's real GATE_BLOCK is actually load-bearing on that table's
# public_port values, not coincidentally matching a hardcoded number.
cp lib/core/port_allocation.sh "$WORKDIR/port_allocation_backup.sh"
awk '
    BEGIN{n=0}
    /"F:xhttp"\)     echo "9443\|19444\|reality\/xhttp\|no\|Xray" ;;/{
        n++
        if (n==1) { gsub(/9443/, "55501"); }
    }
    {print}
' lib/core/port_allocation.sh > "$WORKDIR/port_allocation_mutated.sh"
MUTATION_HIT_COUNT="$(grep -c '"F:xhttp")     echo "55501|19444|reality/xhttp|no|Xray" ;;' "$WORKDIR/port_allocation_mutated.sh")"
assert "negative-mutation precondition: F/xhttp's public_port row was actually found and mutated exactly once" \
    "$MUTATION_HIT_COUNT" "1"

run_gate_against_mutated_table() {
    local _mode="$1" _f_xhttp_enable="$2"
    local _capture="$WORKDIR/ufw_capture_mut_$$_$RANDOM"
    : > "$_capture"
    cp "$WORKDIR/port_allocation_mutated.sh" lib/core/port_allocation.sh
    (
        source lib/core/config.sh
        source lib/core/topology.sh
        source lib/core/deployment.sh
        source lib/core/port_allocation.sh
        ufw() { echo "UFW_CALL:$*" >> "$_capture"; }
        MODE="$_mode"
        F_XHTTP_ENABLE="$_f_xhttp_enable"
        core_resolve_deployment "$MODE" "$F_XHTTP_ENABLE" "1" \
            "panel.example.com" "sub.example.com" "node.example.com" "" ""
        eval "$GATE_BLOCK"
    )
    cp "$WORKDIR/port_allocation_backup.sh" lib/core/port_allocation.sh
    cat "$_capture"
    rm -f "$_capture"
}
if [ "$MUTATION_HIT_COUNT" = "1" ]; then
    MUT_RESULT="$(run_gate_against_mutated_table F 1)"
else
    MUT_RESULT="MUTATION_NOT_APPLIED"
fi
assert "install.sh's real GATE_BLOCK reflects the mutated table's port (55501), not a hardcoded 9443 (proves it genuinely reads core_port_allocation_public, not a coincidental literal)" \
    "$MUT_RESULT" "UFW_CALL:allow 55501/tcp comment Variant F XHTTP"
assert "self-repair: lib/core/port_allocation.sh restored byte-identical after the mutation" \
    "$(diff -q "$WORKDIR/port_allocation_backup.sh" lib/core/port_allocation.sh >/dev/null 2>&1 && echo identical || echo DIFFERS)" "identical"
assert "self-repair: F still resolves to the real 9443 again after restore" \
    "$(run_gate F 1)" "UFW_CALL:allow 9443/tcp comment Variant F XHTTP"

echo ""
echo "== F. direct accessor proof: F -> 9443, J -> 8443 (via the real production GATE_BLOCK, not env-var injection) =="
# Section D above already proves this through the full truth table --
# these two assertions exist as a focused, explicit statement of exactly
# the two numbers this migration's contract cares about, independent of
# section D's broader 5-case sweep.
assert "F+XHTTP -> exactly 9443 (core_port_allocation_public \"F\" \"xhttp\")" \
    "$(run_gate F 1)" "UFW_CALL:allow 9443/tcp comment Variant F XHTTP"
assert "J -> exactly 8443 (core_port_allocation_public \"J\" \"xhttp\")" \
    "$(run_gate J 0)" "UFW_CALL:allow 8443/tcp comment Variant J XHTTP"

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
