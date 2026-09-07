#!/bin/bash
# lib/sripts/tests/test_port_allocation_wiring.sh
#
# Candidate 1 (Architecture Gap Discovery, first PortAllocation
# production consumer): lib/panel/api.sh's panel_reality_xhttp_inbound_port()
# F/J branches move from their own literal fallback defaults
# (${F_XRAY_XHTTP_PORT:-19444} / ${J_XRAY_XHTTP_PORT:-18444}) to
# lib/core/port_allocation.sh's existing, already-tested (53/53)
# core_port_allocation_internal("<F|J>", "xhttp").
#
# NOT a general PortAllocation migration: the `*` arm (MODE=1/2, and
# this function's own historical "anything that isn't F" catch-all) is
# DELIBERATELY left as the literal ${J_XRAY_XHTTP_PORT:-18444} default,
# unmigrated -- lib/core/port_allocation.sh has no row for topology 1/2
# at all, and this call site (api.sh's panel_setup_api(), unconditional,
# every MODE) feeds the result straight into
# lib/panel/xray/templates/render.sh's `jq --argjson xport "$XHTTP_PORT"`,
# which requires a syntactically valid JSON value even for the MODE=1/2
# template (f.json) that never actually renders $xport. An empty result
# there would break jq for every non-F/J install -- section 6 below
# proves this arm is unchanged, independently corroborated by
# lib/sripts/tests/test_f_xhttp_commit2.sh's own pre-existing
# `panel_reality_xhttp_inbound_port 1 == "18444"` assertion.
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
for f in lib/core/port_allocation.sh lib/panel/api.sh server-manager.sh; do
    bash -n "$f" 2>/tmp/synerrpa && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: bash -n $f"; cat /tmp/synerrpa; }
done

echo ""
echo "== 1. truth table: real production function, all reachable MODE values =="
(
    source lib/core/port_allocation.sh
    source lib/panel/api.sh
    for MODE in F J 1 2; do
        echo "$MODE:$(panel_reality_xhttp_inbound_port "$MODE")"
    done
) > /tmp/_paw_truth.txt
declare -A EXPECTED=( [F]="19444" [J]="18444" [1]="18444" [2]="18444" )
while IFS=: read -r MODE VAL; do
    assert "MODE=$MODE -> ${EXPECTED[$MODE]}" "$VAL" "${EXPECTED[$MODE]}"
done < /tmp/_paw_truth.txt
rm -f /tmp/_paw_truth.txt

echo ""
echo "== 2. matches PortAllocation's own table directly (not just the wrapper) =="
(
    source lib/core/port_allocation.sh
    assert() { :; }  # no-op inside subshell, real assert below
    echo "F:$(core_port_allocation_internal F xhttp)"
    echo "J:$(core_port_allocation_internal J xhttp)"
) > /tmp/_paw_table.txt
while IFS=: read -r TOPO VAL; do
    assert "core_port_allocation_internal $TOPO xhttp" "$VAL" "${EXPECTED[$TOPO]}"
done < /tmp/_paw_table.txt
rm -f /tmp/_paw_table.txt

echo ""
echo "== 3. production code: F/J arms call the Core accessor, literal 19444/18444 gone from those two arms =="
FUNC_BODY="$(awk '/^panel_reality_xhttp_inbound_port\(\) \{$/{grab=1} grab{print} grab&&/^}$/{exit}' lib/panel/api.sh)"
FUNC_CODE_ONLY="$(grep -vE '^\s*#' <<<"$FUNC_BODY")"
assert "function body was actually extracted (non-empty)" \
    "$([ -n "$FUNC_BODY" ] && echo present || echo MISSING)" "present"
assert "F) arm calls core_port_allocation_internal \"F\" \"xhttp\"" \
    "$(grep -c 'F) core_port_allocation_internal "F" "xhttp"' <<<"$FUNC_CODE_ONLY")" "1"
assert "J) arm calls core_port_allocation_internal \"J\" \"xhttp\"" \
    "$(grep -c 'J) core_port_allocation_internal "J" "xhttp"' <<<"$FUNC_CODE_ONLY")" "1"
assert "no more \${F_XRAY_XHTTP_PORT:-19444} literal fallback in this function's CODE" \
    "$(grep -c 'F_XRAY_XHTTP_PORT' <<<"$FUNC_CODE_ONLY")" "0"
assert "literal 19444 is gone from this function's CODE entirely (only PortAllocation's table has it now)" \
    "$(grep -c '19444' <<<"$FUNC_CODE_ONLY")" "0"

echo ""
echo "== 4. the *' catch-all arm (MODE=1/2) is UNCHANGED -- still the literal 18444 default, not migrated =="
assert "'*' arm still reads \${J_XRAY_XHTTP_PORT:-18444} literally (this is the deliberately-NOT-migrated arm)" \
    "$(grep -c '\*) echo "\${J_XRAY_XHTTP_PORT:-18444}"' <<<"$FUNC_CODE_ONLY")" "1"

echo ""
echo "== 5. negative mutation: corrupt PortAllocation's F:xhttp row, confirm the REAL api.sh function actually flips (proves load-bearing, not coincidence) =="
cp lib/core/port_allocation.sh /tmp/_paw_topology_backup.sh
sed 's/"F:xhttp")     echo "9443|19444|reality\/xhttp|no|Xray" ;;/"F:xhttp")     echo "9443|99999|reality\/xhttp|no|Xray" ;;/' \
    lib/core/port_allocation.sh > /tmp/_paw_mutated.sh
MUTATION_HIT="$(grep -c '"F:xhttp")     echo "9443|99999|reality/xhttp|no|Xray" ;;' /tmp/_paw_mutated.sh)"
assert "negative-mutation precondition: F:xhttp row was actually found and mutated exactly once" \
    "$MUTATION_HIT" "1"

if [ "$MUTATION_HIT" = "1" ]; then
    MUT_F="$(bash -c 'source /tmp/_paw_mutated.sh; source lib/panel/api.sh; panel_reality_xhttp_inbound_port F')"
    MUT_J="$(bash -c 'source /tmp/_paw_mutated.sh; source lib/panel/api.sh; panel_reality_xhttp_inbound_port J')"
else
    MUT_F="MUTATION_NOT_APPLIED"
    MUT_J="MUTATION_NOT_APPLIED"
fi
DIFF_CHECK="$(diff -q /tmp/_paw_topology_backup.sh lib/core/port_allocation.sh >/dev/null 2>&1 && echo identical || echo DIFFERS)"
rm -f /tmp/_paw_topology_backup.sh /tmp/_paw_mutated.sh

assert "mutated PortAllocation table flips api.sh's F result from 19444 to 99999 (proves it's load-bearing, not a coincidental match)" \
    "$MUT_F" "99999"
assert "J's result is unaffected by the F-only mutation (mutation is scoped, not a blanket effect)" \
    "$MUT_J" "18444"
assert "real lib/core/port_allocation.sh on disk untouched by the mutation exercise (mutated /tmp copy only)" \
    "$DIFF_CHECK" "identical"

echo ""
echo "== 6. missing accessor: neutralize core_port_allocation_internal, confirm F/J now fail loudly (empty output) instead of silently returning a wrong-but-plausible port =="
cp lib/core/port_allocation.sh /tmp/_paw_topology_backup2.sh
sed 's/^core_port_allocation_internal() {/core_port_allocation_internal_DISABLED() {/' \
    lib/core/port_allocation.sh > /tmp/_paw_disabled.sh
DISABLE_HIT="$(grep -c '^core_port_allocation_internal() {' /tmp/_paw_disabled.sh)"
assert "missing-accessor precondition: the function definition was actually renamed away (0 remaining)" \
    "$DISABLE_HIT" "0"

if [ "$DISABLE_HIT" = "0" ]; then
    MISSING_F="$(bash -c 'source /tmp/_paw_disabled.sh; source lib/panel/api.sh; panel_reality_xhttp_inbound_port F' 2>/dev/null)"
    MISSING_1="$(bash -c 'source /tmp/_paw_disabled.sh; source lib/panel/api.sh; panel_reality_xhttp_inbound_port 1' 2>/dev/null)"
else
    MISSING_F="ACCESSOR_STILL_PRESENT"
    MISSING_1="ACCESSOR_STILL_PRESENT"
fi
DIFF_CHECK2="$(diff -q /tmp/_paw_topology_backup2.sh lib/core/port_allocation.sh >/dev/null 2>&1 && echo identical || echo DIFFERS)"
rm -f /tmp/_paw_topology_backup2.sh /tmp/_paw_disabled.sh

# With the accessor undefined, the F)/J) arms hit "command not found"
# (exit 127) and echo produces empty output -- this is the LOUD failure
# this migration deliberately prefers over a silent stale-literal
# fallback: an empty $xport would break jq's --argjson at the real
# render.sh call site rather than quietly generating a plausible-looking
# but possibly-wrong config.
assert "with the accessor missing, MODE=F now produces EMPTY output (loud failure, not a silently-wrong port)" \
    "$MISSING_F" ""
assert "the untouched '*' arm (MODE=1) is NOT affected by the F/J accessor being missing -- still 18444" \
    "$MISSING_1" "18444"
assert "real lib/core/port_allocation.sh on disk untouched by the missing-accessor exercise" \
    "$DIFF_CHECK2" "identical"
assert "bash -n lib/core/port_allocation.sh still passes after both mutation exercises" \
    "$(bash -n lib/core/port_allocation.sh; echo $?)" "0"

echo ""
echo "== 7. module load order: core/port_allocation is registered and loaded before panel =="
assert "core/port_allocation is present in _MODULE_SHA256" \
    "$(grep -c '\["core/port_allocation"\]=' server-manager.sh)" "1"
LOAD_PA_LINE=$(grep -n '^_load_module core/port_allocation$' server-manager.sh | head -1 | cut -d: -f1)
LOAD_PANEL_LINE=$(grep -n '^_load_module panel$' server-manager.sh | head -1 | cut -d: -f1)
assert "both _load_module lines found (single occurrence each)" \
    "$(grep -c '^_load_module core/port_allocation$' server-manager.sh):$(grep -c '^_load_module panel$' server-manager.sh)" \
    "1:1"
[ -n "$LOAD_PA_LINE" ] && [ -n "$LOAD_PANEL_LINE" ] && [ "$LOAD_PA_LINE" -lt "$LOAD_PANEL_LINE" ] \
    && PASS=$((PASS+1)) \
    || { FAIL=$((FAIL+1)); echo "  FAIL: core/port_allocation (line $LOAD_PA_LINE) is not loaded before panel (line $LOAD_PANEL_LINE)"; }

echo ""
echo "== 8. architecture boundary: PortAllocation was NOT changed to read Panel globals =="
assert "lib/core/port_allocation.sh's CODE (not comments) does not read \$F_XRAY_XHTTP_PORT" \
    "$(grep -vE '^\s*#' lib/core/port_allocation.sh | grep -c 'F_XRAY_XHTTP_PORT')" "0"
assert "lib/core/port_allocation.sh's CODE (not comments) does not read \$J_XRAY_XHTTP_PORT" \
    "$(grep -vE '^\s*#' lib/core/port_allocation.sh | grep -c 'J_XRAY_XHTTP_PORT')" "0"
assert "lib/core/port_allocation.sh's own port table (_core_port_allocation_row) is unchanged (still has exactly 8 rows)" \
    "$(grep -cE '^\s*"(F|J):(vision|panel_sub|xhttp|telemt)"\)' lib/core/port_allocation.sh)" "8"
assert "lib/panel/nginx/variant_f.sh was not touched" \
    "$(git diff --name-only -- lib/panel/nginx/variant_f.sh | wc -l)" "0"
assert "lib/panel/nginx/variant_j.sh was not touched" \
    "$(git diff --name-only -- lib/panel/nginx/variant_j.sh | wc -l)" "0"

echo ""
echo "==================================="
echo "PASS=$PASS FAIL=$FAIL"
echo "==================================="
[ "$FAIL" -eq 0 ]
