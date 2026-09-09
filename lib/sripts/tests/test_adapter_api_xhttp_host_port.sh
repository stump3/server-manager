#!/bin/bash
# lib/sripts/tests/test_adapter_api_xhttp_host_port.sh
#
# Candidate 3 (Architecture Gap Discovery / PortAllocation wiring,
# following Candidate 1 -- panel_reality_xhttp_inbound_port(), and
# Candidate 2 -- install.sh's XHTTP UFW gate): lib/panel/api.sh's
# panel_setup_api() XHTTP Host-registration block used to compute
# XHTTP_PUBLIC_PORT_VAL UNCONDITIONALLY (raw `[ "$MODE" = "F" ]` branch
# over $F_XHTTP_PUBLIC_PORT/$J_XHTTP_PUBLIC_PORT literal fallbacks),
# ABOVE the `[ "$XHTTP_ENABLE" = "1" ] && [ -n "$XHTTP_IBD_UUID" ]` gate
# that is its only actual consumer. panel_setup_api() runs for every
# MODE (1/2/F/J) -- lib/core/port_allocation.sh deliberately has no row
# for topology "1"/"2" x role "xhttp" (see lib/core/port_allocation.sh's
# own header). Naively replacing the old unconditional raw branch with
# `core_port_allocation_public("$MODE","xhttp")` IN PLACE (i.e. still
# above the gate) would have made every MODE=1/2 install call a
# guaranteed-failing accessor and abort under this project's
# `set -euo pipefail` (server-manager.sh) BEFORE ever reaching the gate
# that would otherwise have skipped it harmlessly.
#
# The actual fix instead MOVES the accessor call INSIDE the gate, where
# XHTTP_ENABLE="1" is only ever true for MODE=F(F_XHTTP_ENABLE=1)/J (the
# only production caller, lib/panel/install.sh, derives it via
# core_deployment_has_capability("XHTTP"), Adapter #4) -- so the one
# reachable failure mode of the accessor (no row for 1/2) can never
# actually be hit at this call site.
#
# This test extracts the REAL, unmodified production block (the `if
# [ "$XHTTP_ENABLE" = "1" ] ...` gate and everything inside it) from
# lib/panel/api.sh via awk and executes it in an isolated subshell under
# the project's own `set -euo pipefail` convention, with panel_api/jq
# mocked (jq is not installed in this sandbox at all -- see lib/sripts/
# tests/test_f_xhttp_commit2.sh's own documented jq dependency for an
# unrelated, pre-existing example of the same environment gap) and a
# spy wrapped around the real core_port_allocation_public() so calls
# are provably counted, not inferred from absence of a crash alone.
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

echo "== A. bash -n =="
for f in lib/core/port_allocation.sh lib/panel/api.sh server-manager.sh; do
    bash -n "$f" 2>/tmp/_a3_synerr && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: bash -n $f"; cat /tmp/_a3_synerr; }
done
rm -f /tmp/_a3_synerr

echo ""
echo "== B. production source inspection =="
assert "the gate now calls core_port_allocation_public exactly once" \
    "$(grep -c 'XHTTP_PUBLIC_PORT_VAL="\$(core_port_allocation_public "\$MODE" "xhttp")"' lib/panel/api.sh)" "1"
assert "the accessor call is textually INSIDE the XHTTP_ENABLE gate (appears after the gate's own if-line, not before)" \
    "$(awk '/if \[ "\$XHTTP_ENABLE" = "1" \]/{g=NR} /core_port_allocation_public "\$MODE" "xhttp"/{c=NR} END{print (g>0 && c>g) ? "inside" : "NOT-INSIDE"}' lib/panel/api.sh)" "inside"
assert "the old unconditional MODE=F/J branch over raw \$F_XHTTP_PUBLIC_PORT/\$J_XHTTP_PUBLIC_PORT is gone from this call site" \
    "$(grep -cE 'XHTTP_PUBLIC_PORT_VAL="\$\{[FJ]_XHTTP_PUBLIC_PORT' lib/panel/api.sh)" "0"
assert "raw \$F_XHTTP_PUBLIC_PORT is not read in api.sh's CODE anymore (comments may still discuss it historically)" \
    "$(grep -vE '^\s*#' lib/panel/api.sh | grep -c 'F_XHTTP_PUBLIC_PORT')" "0"
assert "raw \$J_XHTTP_PUBLIC_PORT is not read in api.sh's CODE anymore (comments may still discuss it historically)" \
    "$(grep -vE '^\s*#' lib/panel/api.sh | grep -c 'J_XHTTP_PUBLIC_PORT')" "0"

# ---------------------------------------------------------------------
# Extract the ACTUAL production block verbatim.
# ---------------------------------------------------------------------
extract_gate() {
    awk '
        /^    if \[ "\$XHTTP_ENABLE" = "1" \] && \[ -n "\$XHTTP_IBD_UUID" \]; then$/ { found=1 }
        found { print; if (/^    fi$/) exit }
    ' lib/panel/api.sh
}
GATE_BLOCK="$(extract_gate)"
assert "target block was actually extracted from lib/panel/api.sh (non-empty)" \
    "$([ -n "$GATE_BLOCK" ] && echo present || echo MISSING)" "present"
assert "extracted block really is the XHTTP Host-registration block (contains the POST /api/hosts call)" \
    "$(grep -c 'POST" "http://\$API/api/hosts"' <<<"$GATE_BLOCK")" "1"

# $RESULT_EXIT / $RESULT_JQ / $RESULT_API / $RESULT_SPY are set by run_block().
run_block() {
    # $1 MODE  $2 XHTTP_ENABLE  $3 XHTTP_IBD_UUID  $4 existing-host-uuid-from-GET (default: none)
    local _mode="$1" _enable="$2" _uuid="$3" _existing="${4:-}"
    local _jq_cap="$WORKDIR/jq_$$_$RANDOM"
    local _api_cap="$WORKDIR/api_$$_$RANDOM"
    local _spy_cap="$WORKDIR/spy_$$_$RANDOM"
    : > "$_jq_cap"; : > "$_api_cap"; : > "$_spy_cap"
    (
        set -euo pipefail   # mirrors server-manager.sh's real invariant exactly
        source lib/core/port_allocation.sh
        source lib/ui/output.sh

        # Spy on the REAL accessor: rename the sourced definition, then
        # redefine the public name to log-and-delegate. Proves the
        # extracted block actually calls the real core_port_allocation_
        # public() (not a coincidence / not a stale hardcoded value).
        eval "$(declare -f core_port_allocation_public | sed '1s/core_port_allocation_public/_real_core_port_allocation_public/')"
        core_port_allocation_public() {
            echo "SPY_CALL:$*" >> "$_spy_cap"
            _real_core_port_allocation_public "$@"
        }

        panel_api() { echo "API_CALL:$*" >> "$_api_cap"; echo "{}"; }
        jq() {
            case "$*" in
                *'-r --arg iu'*)
                    # This IS the piped call (panel_api ... | jq ... |
                    # head -1) -- drain stdin like real jq does, avoiding
                    # a SIGPIPE race against the upstream panel_api mock.
                    cat >/dev/null
                    echo "JQ_CALL:$*" >> "$_jq_cap"
                    echo "$_existing"
                    ;;
                *)
                    # `jq -n` (null input) never reads stdin in real jq --
                    # must NOT drain here, this call site is a command
                    # substitution with no pipe, and stdin is whatever
                    # this test process inherited (draining would hang).
                    echo "JQ_CALL:$*" >> "$_jq_cap"
                    echo "{}"
                    ;;
            esac
        }

        MODE="$_mode"
        XHTTP_ENABLE="$_enable"
        XHTTP_IBD_UUID="$_uuid"
        API="panel.local"
        TOKEN="test-token"
        CFG_UUID="cfg-uuid-1234"
        SELFSTEAL_DOMAIN="steal.example.com"
        XHTTP_PATH="/xhttp-secret"

        eval "$GATE_BLOCK"
    )
    RESULT_EXIT=$?
    RESULT_JQ="$(cat "$_jq_cap")"
    RESULT_API="$(cat "$_api_cap")"
    RESULT_SPY="$(cat "$_spy_cap")"
    rm -f "$_jq_cap" "$_api_cap" "$_spy_cap"
}

echo ""
echo "== C. CRITICAL: MODE=1/2 do not abort under set -e (the exact regression hazard this migration had to avoid) =="
run_block 1 "0" ""
assert "MODE=1, XHTTP disabled: block exits 0 (no set -e abort)" "$RESULT_EXIT" "0"
assert "MODE=1: the XHTTP gate is not entered -- no jq activity" "$RESULT_JQ" ""
assert "MODE=1: the XHTTP gate is not entered -- no panel_api activity" "$RESULT_API" ""
assert "MODE=1: core_port_allocation_public is never called (proven by the spy, not inferred from the absence of a crash)" "$RESULT_SPY" ""

run_block 2 "0" ""
assert "MODE=2, XHTTP disabled: block exits 0 (no set -e abort)" "$RESULT_EXIT" "0"
assert "MODE=2: no jq activity" "$RESULT_JQ" ""
assert "MODE=2: no panel_api activity (Host registration not performed)" "$RESULT_API" ""
assert "MODE=2: core_port_allocation_public is never called" "$RESULT_SPY" ""

echo ""
echo "== D. full truth table (F disabled / F enabled / J), Host registration path (no pre-existing host) =="
run_block F "0" ""
assert "MODE=F, XHTTP_ENABLE=0: block exits 0" "$RESULT_EXIT" "0"
assert "MODE=F, XHTTP_ENABLE=0: gate not entered -- accessor not called" "$RESULT_SPY" ""
assert "MODE=F, XHTTP_ENABLE=0: no Host registration attempted" "$RESULT_API" ""

run_block F "1" "ibd-uuid-f-1" ""
assert "MODE=F, XHTTP_ENABLE=1: block exits 0" "$RESULT_EXIT" "0"
assert "MODE=F, XHTTP_ENABLE=1: accessor called exactly once, with topology F" "$RESULT_SPY" "SPY_CALL:F xhttp"
assert "MODE=F, XHTTP_ENABLE=1: public port resolved to 9443 and reaches the POST body (--argjson port 9443)" \
    "$(grep -c -- '--argjson port 9443' <<<"$RESULT_JQ")" "1"
assert "MODE=F, XHTTP_ENABLE=1: Host registration POST was actually attempted (no pre-existing host)" \
    "$(grep -c 'API_CALL:POST' <<<"$RESULT_API")" "1"

run_block J "1" "ibd-uuid-j-1" ""
assert "MODE=J: block exits 0" "$RESULT_EXIT" "0"
assert "MODE=J: accessor called exactly once, with topology J" "$RESULT_SPY" "SPY_CALL:J xhttp"
assert "MODE=J: public port resolved to 8443 and reaches the POST body (--argjson port 8443)" \
    "$(grep -c -- '--argjson port 8443' <<<"$RESULT_JQ")" "1"
assert "MODE=J: Host registration POST was actually attempted" \
    "$(grep -c 'API_CALL:POST' <<<"$RESULT_API")" "1"

echo ""
echo "== E. bonus: pre-existing Host short-circuits registration (block still functions end-to-end) =="
run_block F "1" "ibd-uuid-f-2" "existing-host-uuid-xyz"
assert "MODE=F with an existing Host found: block exits 0" "$RESULT_EXIT" "0"
assert "MODE=F with an existing Host found: accessor is STILL called (port is computed regardless of the existing-host branch)" \
    "$RESULT_SPY" "SPY_CALL:F xhttp"
assert "MODE=F with an existing Host found: no POST is attempted (short-circuited)" \
    "$(grep -c 'API_CALL:POST' <<<"$RESULT_API")" "0"

echo ""
echo "== F. regression against accidental port swap =="
assert "F never produces J's port (8443) in the POST body" \
    "$([ "$(run_block F "1" "ibd-x" ""; grep -c -- '--argjson port 8443' <<<"$RESULT_JQ")" = "0" ] && echo ok || echo swapped)" "ok"
assert "J never produces F's port (9443) in the POST body" \
    "$([ "$(run_block J "1" "ibd-y" ""; grep -c -- '--argjson port 9443' <<<"$RESULT_JQ")" = "0" ] && echo ok || echo swapped)" "ok"

echo ""
echo "== G. negative mutation: corrupt PortAllocation's F:xhttp public_port, confirm the REAL extracted block actually flips =="
cp lib/core/port_allocation.sh /tmp/_a3_pa_backup.sh
sed 's/"F:xhttp")     echo "9443|19444|reality\/xhttp|no|Xray" ;;/"F:xhttp")     echo "9199|19444|reality\/xhttp|no|Xray" ;;/' \
    lib/core/port_allocation.sh > /tmp/_a3_pa_mutated.sh
MUTATION_HIT="$(grep -c '"F:xhttp")     echo "9199|19444|reality/xhttp|no|Xray" ;;' /tmp/_a3_pa_mutated.sh)"
assert "negative-mutation precondition: F:xhttp public_port was actually found and mutated exactly once" \
    "$MUTATION_HIT" "1"

if [ "$MUTATION_HIT" = "1" ]; then
    _mutation_probe() {
        local _jq_cap="$1"
        (
            set -euo pipefail
            source /tmp/_a3_pa_mutated.sh
            source lib/ui/output.sh
            panel_api() { echo "{}"; }
            jq() {
                case "$*" in
                    *'-r --arg iu'*)
                        cat >/dev/null   # drain stdin (see run_block's jq mock for rationale)
                        echo "JQ_CALL:$*" >> "$_jq_cap"
                        echo ""
                        ;;
                    *)
                        echo "JQ_CALL:$*" >> "$_jq_cap"
                        echo "{}"
                        ;;
                esac
            }
            MODE="F"; XHTTP_ENABLE="1"; XHTTP_IBD_UUID="ibd-mut"
            API="panel.local"; TOKEN="tok"; CFG_UUID="cfg"; SELFSTEAL_DOMAIN="steal.example.com"; XHTTP_PATH="/x"
            eval "$GATE_BLOCK"
        )
    }
    MUT_JQ_CAP="$WORKDIR/mut_jq_$$"
    : > "$MUT_JQ_CAP"
    _mutation_probe "$MUT_JQ_CAP"
    MUT_OUT="$(cat "$MUT_JQ_CAP")"
    rm -f "$MUT_JQ_CAP"
else
    MUT_OUT="MUTATION_NOT_APPLIED"
fi
DIFF_CHECK="$(diff -q /tmp/_a3_pa_backup.sh lib/core/port_allocation.sh >/dev/null 2>&1 && echo identical || echo DIFFERS)"
rm -f /tmp/_a3_pa_backup.sh /tmp/_a3_pa_mutated.sh

assert "mutated PortAllocation table flips the real block's POST body from 9443 to 9199 (proves load-bearing, not coincidence)" \
    "$(grep -c -- '--argjson port 9199' <<<"$MUT_OUT")" "1"
assert "real lib/core/port_allocation.sh on disk is untouched after the mutation exercise (mutated /tmp copy only)" \
    "$DIFF_CHECK" "identical"
assert "bash -n lib/core/port_allocation.sh still passes after the mutation exercise" \
    "$(bash -n lib/core/port_allocation.sh; echo $?)" "0"

echo ""
echo "==================================="
echo "PASS=$PASS FAIL=$FAIL"
echo "==================================="
[ "$FAIL" -eq 0 ]
