#!/bin/bash
# lib/sripts/tests/test_adapter_node_addr.sh
#
# Adapter #5: panel_setup_api()'s NODE_ADDR decision (the `address` field
# of the POST /api/nodes payload it creates for its own, locally-created
# "Steal" Node) moves from a raw MODE comparison
# (`[ "$MODE" = "2" ] && NODE_ADDR="$SELFSTEAL_DOMAIN" || NODE_ADDR="172.30.0.1"`)
# to the same Core query lib/core/adapter_reality.sh's
# panel_core_reality_needs_2222_ufw_rule()/panel_core_reality_dest_val()
# already use in this same function:
# lib/core/runtime_component.sh:core_runtime_component_exists("xray").
#
# This is NOT the same NODE_ADDR as lib/panel/node/api.sh's
# panel_node_register() (separate, later, Remote Node onboarding flow,
# which takes an SSH-discovered IP as an explicit parameter and asserts
# "NODE_ADDR != SELFSTEAL_DOMAIN") -- section 6 below checks that flow's
# own file is untouched.
#
# Precondition (same as Adapter #2/#3/#4, see test_adapter_reality.sh's
# own header): core_resolve_deployment() runs earlier in the same
# panel_install() invocation, so DEPLOYMENT_TOPOLOGY/DEPLOYMENT_CAPABILITIES
# are already set by the time panel_setup_api() (and this decision inside
# it) runs. Checked explicitly (see "call order" section).
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
for f in lib/core/runtime_component.sh lib/panel/api.sh lib/panel/install.sh; do
    bash -n "$f" 2>/tmp/synerr && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: bash -n $f"; cat /tmp/synerr; }
done

echo ""
echo "== 1. accessor truth table (core_runtime_component_exists \"xray\") for NODE_ADDR's 4 topologies =="
TABLE_OUT=$(bash -c '
    source lib/core/config.sh
    source lib/core/deployment.sh
    source lib/core/runtime_component.sh
    for mode in 1 2 F J; do
        core_resolve_deployment "$mode" "0" "1" "p.example.com" "s.example.com" "n.example.com" "" ""
        if core_runtime_component_exists "xray"; then
            echo "$mode:172.30.0.1"
        else
            echo "$mode:SELFSTEAL_DOMAIN"
        fi
    done
')
assert "MODE=1 -> 172.30.0.1 (co-located)"        "$(echo "$TABLE_OUT" | grep '^1:')" "1:172.30.0.1"
assert "MODE=2 -> SELFSTEAL_DOMAIN (no local xray)" "$(echo "$TABLE_OUT" | grep '^2:')" "2:SELFSTEAL_DOMAIN"
assert "MODE=F -> 172.30.0.1 (co-located)"        "$(echo "$TABLE_OUT" | grep '^F:')" "F:172.30.0.1"
assert "MODE=J -> 172.30.0.1 (co-located)"        "$(echo "$TABLE_OUT" | grep '^J:')" "J:172.30.0.1"

echo ""
echo "== 2. api.sh NODE_ADDR decision region: no raw MODE comparison, calls the Core accessor =="
# Scope the check to the NODE_ADDR decision itself, not the whole file --
# lib/panel/api.sh legitimately contains other MODE checks (reality
# inbound ports, XHTTP host port, F/J dispatch) explicitly out of scope
# for Adapter #5.
NODE_ADDR_REGION=$(awk '/local NODE_ADDR/,/^    panel_api "POST" "http:\/\/\$API\/api\/nodes"/' lib/panel/api.sh)
# Code-only view (strips comment lines) -- the region legitimately
# contains a doc comment that MENTIONS the old raw MODE check for
# historical/audit context (see the diff itself); that mention must not
# be misread as live decision code still being present.
NODE_ADDR_REGION_CODE=$(grep -vE '^\s*#' <<<"$NODE_ADDR_REGION")
assert "NODE_ADDR decision region is non-empty (region actually matched)" \
    "$([ -n "$NODE_ADDR_REGION" ] && echo present || echo MISSING)" "present"
assert "NODE_ADDR decision region's CODE (not comments) contains no raw MODE comparison" \
    "$(grep -cE '\[ *"\$MODE" *=' <<<"$NODE_ADDR_REGION_CODE")" "0"
assert "NODE_ADDR decision region calls the Core accessor" \
    "$(grep -c 'core_runtime_component_exists "xray"' <<<"$NODE_ADDR_REGION_CODE")" "1"
assert "NODE_ADDR decision region's CODE still assigns both branches (172.30.0.1 / SELFSTEAL_DOMAIN)" \
    "$(grep -c '172\.30\.0\.1' <<<"$NODE_ADDR_REGION_CODE"):$(grep -c 'SELFSTEAL_DOMAIN' <<<"$NODE_ADDR_REGION_CODE")" "1:1"

echo ""
echo "== 3. production-path equivalence: NODE_ADDR matches old raw-MODE behavior for all 4 topologies =="
PROD_PATH_OUT=$(bash -c '
    source lib/core/config.sh
    source lib/core/deployment.sh
    source lib/core/runtime_component.sh
    for MODE in 1 2 F J; do
        SELFSTEAL_DOMAIN="s.example.com"
        core_resolve_deployment "$MODE" "0" "1" "p.example.com" "s.example.com" "n.example.com" "" ""
        if core_runtime_component_exists "xray"; then
            NODE_ADDR="172.30.0.1"
        else
            NODE_ADDR="$SELFSTEAL_DOMAIN"
        fi
        # old behavior, computed independently in the same run for direct comparison
        OLD_NODE_ADDR=""
        [ "$MODE" = "2" ] && OLD_NODE_ADDR="$SELFSTEAL_DOMAIN" || OLD_NODE_ADDR="172.30.0.1"
        [ "$NODE_ADDR" = "$OLD_NODE_ADDR" ] && echo "$MODE:MATCH:$NODE_ADDR" || echo "$MODE:MISMATCH:new=$NODE_ADDR:old=$OLD_NODE_ADDR"
    done
')
assert "MODE=1 new==old" "$(echo "$PROD_PATH_OUT" | grep '^1:')" "1:MATCH:172.30.0.1"
assert "MODE=2 new==old" "$(echo "$PROD_PATH_OUT" | grep '^2:')" "2:MATCH:s.example.com"
assert "MODE=F new==old" "$(echo "$PROD_PATH_OUT" | grep '^F:')" "F:MATCH:172.30.0.1"
assert "MODE=J new==old" "$(echo "$PROD_PATH_OUT" | grep '^J:')" "J:MATCH:172.30.0.1"

echo ""
echo "== 4. negative test: intentionally break the xray-presence fact, confirm NODE_ADDR is actually load-bearing on it =="
cp lib/core/runtime_component.sh /tmp/_rtc_backup.sh
# Break the ONE line that makes required-capability "Vision" (MODE=1/F/J's
# case) count as "xray present" -- targets the exact, unique case arm, not
# a broad pattern that could silently match something else.
awk '
    BEGIN{n=0}
    /case "\$_cap" in Vision\|XHTTP\) _has_xray_capability=0 ;; esac/{
        n++
        if (n==1) { sub(/Vision\|XHTTP/, "__UNMATCHABLE__"); }
    }
    {print}
' lib/core/runtime_component.sh > /tmp/_rtc_mutated.sh

# Mandatory precondition (lesson from the Adapter #4 audit): the mutation
# must have actually landed. If the targeted line was never found (e.g.
# runtime_component.sh's xray-detection was refactored to a different
# shape, or core_runtime_component_exists itself went missing), the awk
# above is a silent no-op and a "false" result below would be
# indistinguishable from "the fact was never wired in" rather than "the
# fact was broken". Must fail loudly here instead of proceeding.
MUTATION_HIT_COUNT="$(grep -c '__UNMATCHABLE__' /tmp/_rtc_mutated.sh)"
assert "negative-mutation precondition: the targeted case arm was actually found and replaced exactly once" \
    "$MUTATION_HIT_COUNT" "1"

if [ "$MUTATION_HIT_COUNT" = "1" ]; then
    cp /tmp/_rtc_mutated.sh lib/core/runtime_component.sh
    NEG_OUT=$(bash -c '
        source lib/core/config.sh
        source lib/core/deployment.sh
        source lib/core/runtime_component.sh
        SELFSTEAL_DOMAIN="s.example.com"
        core_resolve_deployment "1" "0" "1" "p.example.com" "s.example.com" "n.example.com" "" ""
        if core_runtime_component_exists "xray"; then
            echo "172.30.0.1"
        else
            echo "$SELFSTEAL_DOMAIN"
        fi
    ' 2>/dev/null)
    cp /tmp/_rtc_backup.sh lib/core/runtime_component.sh
else
    NEG_OUT="MUTATION_NOT_APPLIED"
fi
DIFF_AFTER_RESTORE="$(diff -q /tmp/_rtc_backup.sh lib/core/runtime_component.sh >/dev/null 2>&1 && echo identical || echo DIFFERS)"
rm -f /tmp/_rtc_backup.sh /tmp/_rtc_mutated.sh

assert "artificially broken xray-presence fact flips MODE=1's NODE_ADDR from 172.30.0.1 to SELFSTEAL_DOMAIN (proves it's load-bearing, not a no-op)" \
    "$NEG_OUT" "s.example.com"
assert "self-repair: runtime_component.sh restored byte-identical to its pre-mutation content" \
    "$DIFF_AFTER_RESTORE" "identical"
assert "self-repair: bash -n runtime_component.sh still passes after restore" \
    "$(bash -n lib/core/runtime_component.sh; echo $?)" "0"

echo ""
echo "== 5. call order precondition (same shape as Adapter #2/#3/#4's own check) =="
RESOLVE_LINE=$(grep -n 'core_resolve_deployment "\$MODE"' lib/panel/install.sh | head -1 | cut -d: -f1)
CALL_SITE_LINE=$(grep -n 'panel_setup_api "\$SUPERADMIN_USER"' lib/panel/install.sh | head -1 | cut -d: -f1)
assert "core_resolve_deployment() and panel_setup_api() call site both found (single occurrence each)" \
    "$(grep -c 'core_resolve_deployment "\$MODE"' lib/panel/install.sh):$(grep -c 'panel_setup_api "\$SUPERADMIN_USER"' lib/panel/install.sh)" \
    "1:1"
[ -n "$RESOLVE_LINE" ] && [ -n "$CALL_SITE_LINE" ] && [ "$RESOLVE_LINE" -lt "$CALL_SITE_LINE" ] \
    && PASS=$((PASS+1)) \
    || { FAIL=$((FAIL+1)); echo "  FAIL: core_resolve_deployment (line $RESOLVE_LINE) does not precede panel_setup_api() call (line $CALL_SITE_LINE)"; }
assert "panel_setup_api() has exactly one production call site (lib/panel/install.sh)" \
    "$(grep -rn 'panel_setup_api "\$SUPERADMIN_USER"' lib/panel/*.sh lib/panel/*/*.sh 2>/dev/null | grep -c 'lib/panel/install.sh')" "1"

echo ""
echo "== 6. other NODE_ADDR consumers are untouched (panel_node_register()'s own, unrelated NODE_ADDR) =="
# lib/panel/node/api.sh's panel_node_register() has its OWN, unrelated
# NODE_ADDR (an explicit SSH-discovered IP parameter for the separate
# Remote Node onboarding flow, with its own documented invariant
# "NODE_ADDR != SELFSTEAL_DOMAIN") -- Adapter #5 must not touch it.
assert "lib/panel/node/api.sh's panel_node_register() still takes NODE_ADDR as its own 4th positional param" \
    "$(grep -c 'local NODE_ADDR="\$4"' lib/panel/node/api.sh)" "1"
assert "lib/panel/node/api.sh's own NODE_ADDR invariant comment is untouched" \
    "$(grep -c 'NODE_ADDR ≠ SELFSTEAL_DOMAIN' lib/panel/node/api.sh)" "1"

echo ""
echo "==================================="
echo "PASS=$PASS FAIL=$FAIL"
echo "==================================="
[ "$FAIL" -eq 0 ]
