#!/bin/bash
# lib/sripts/tests/test_port_allocation.sh
#
# PortAllocation: the first, read-only Core layer for
# lib/core/port_allocation.sh, a code-side mirror of
# docs/edge_contracts.md's "Port allocation model" table. NOT wired into
# any production call site yet (lib/panel/api.sh keeps its own,
# separately-duplicated fallback defaults; lib/panel/install.sh's UFW
# port-open logic is untouched) -- this test exercises the new file in
# isolation, the same way every other Core adapter test in this repo
# does (source lib/core/<file>.sh directly by path).
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
assert_fail() {
    # Asserts a command FAILS (non-zero exit) and prints nothing on
    # stdout -- used for invalid topology/role and telemt's internal_port.
    local desc="$1"; shift
    local out rc
    out="$("$@" 2>/dev/null)"; rc=$?
    if [ "$rc" -ne 0 ] && [ -z "$out" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        echo "  FAIL: $desc -- expected failure with empty output, got rc=$rc output=[$out]"
    fi
}

echo "== syntax =="
bash -n lib/core/port_allocation.sh 2>/tmp/synerr && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: bash -n lib/core/port_allocation.sh"; cat /tmp/synerr; }

echo ""
echo "== 1. full truth table: F/J x {vision,xhttp,panel_sub,telemt}, all 5 fields =="
# Sourced in isolation -- deliberately NOT sourcing variant_f.sh/
# variant_j.sh, core/deployment.sh, or core/topology.sh first, to prove
# this file has no load-order dependency on any of them (see section 3).
TABLE_OUT=$(bash -c '
    source lib/core/port_allocation.sh
    for T in F J; do
        for R in vision panel_sub xhttp telemt; do
            pub=$(core_port_allocation_public "$T" "$R" 2>/dev/null) && pub_rc=0 || pub_rc=1
            int=$(core_port_allocation_internal "$T" "$R" 2>/dev/null) && int_rc=0 || int_rc=1
            proto=$(core_port_allocation_protocol "$T" "$R" 2>/dev/null)
            pp=$(core_port_allocation_proxy_protocol "$T" "$R" 2>/dev/null)
            own=$(core_port_allocation_owner "$T" "$R" 2>/dev/null)
            echo "$T/$R:pub=$pub:pub_rc=$pub_rc:int=$int:int_rc=$int_rc:proto=$proto:pp=$pp:own=$own"
        done
    done
')
# docs/edge_contracts.md's table, transcribed as the expected values --
# re-verified line-by-line against lib/panel/nginx/variant_f.sh and
# variant_j.sh's actual listen/upstream/proxy_protocol directives before
# this test was written (see design-phase notes), not just copied from
# the doc blindly.
assert "F/vision"    "$(echo "$TABLE_OUT" | grep '^F/vision:')"    "F/vision:pub=443:pub_rc=0:int=8443:int_rc=0:proto=reality/tcp:pp=yes:own=Xray"
assert "F/panel_sub" "$(echo "$TABLE_OUT" | grep '^F/panel_sub:')" "F/panel_sub:pub=443:pub_rc=0:int=7443:int_rc=0:proto=http/tls:pp=yes (in):own=nginx"
assert "F/xhttp"      "$(echo "$TABLE_OUT" | grep '^F/xhttp:')"      "F/xhttp:pub=9443:pub_rc=0:int=19444:int_rc=0:proto=reality/xhttp:pp=no:own=Xray"
assert "F/telemt"     "$(echo "$TABLE_OUT" | grep '^F/telemt:')"     "F/telemt:pub=443:pub_rc=0:int=:int_rc=1:proto=mtproto/tls:pp=yes:own=TeleMT"
assert "J/vision"    "$(echo "$TABLE_OUT" | grep '^J/vision:')"    "J/vision:pub=443:pub_rc=0:int=18443:int_rc=0:proto=reality/tcp:pp=yes:own=Xray"
assert "J/panel_sub" "$(echo "$TABLE_OUT" | grep '^J/panel_sub:')" "J/panel_sub:pub=443:pub_rc=0:int=7444:int_rc=0:proto=http/tls:pp=yes (in):own=nginx"
assert "J/xhttp"      "$(echo "$TABLE_OUT" | grep '^J/xhttp:')"      "J/xhttp:pub=8443:pub_rc=0:int=18444:int_rc=0:proto=reality/xhttp:pp=no:own=Xray"
assert "J/telemt"     "$(echo "$TABLE_OUT" | grep '^J/telemt:')"     "J/telemt:pub=443:pub_rc=0:int=:int_rc=1:proto=mtproto/tls:pp=yes:own=TeleMT"

echo ""
echo "== 2. telemt's internal_port fails ON PURPOSE (dynamic, per-Deployment fact -- see DEPLOYMENT_TELEMT_PORT), not a missing-row bug =="
( source lib/core/port_allocation.sh
  assert_fail "core_port_allocation_internal F telemt fails" core_port_allocation_internal "F" "telemt"
  assert_fail "core_port_allocation_internal J telemt fails" core_port_allocation_internal "J" "telemt"
  # But telemt's OTHER four fields must still succeed -- this is a
  # deliberate, single-field exception, not "telemt has no row at all".
  assert "telemt public_port still resolves (F)" "$(core_port_allocation_public F telemt)" "443"
  assert "telemt owner still resolves (F)" "$(core_port_allocation_owner F telemt)" "TeleMT"
  echo "PASS=$PASS FAIL=$FAIL" > /tmp/_pa_sub1
)
# shellcheck disable=SC1091
source /tmp/_pa_sub1 2>/dev/null || true
eval "$(cat /tmp/_pa_sub1 2>/dev/null | sed -n '1p')" 2>/dev/null || true
# (subshell PASS/FAIL counters don't propagate to the parent shell --
# re-run the same assertions directly in this shell for the real count.)
source lib/core/port_allocation.sh
assert_fail "core_port_allocation_internal F telemt fails" core_port_allocation_internal "F" "telemt"
assert_fail "core_port_allocation_internal J telemt fails" core_port_allocation_internal "J" "telemt"
assert "telemt public_port still resolves (F)" "$(core_port_allocation_public F telemt)" "443"
assert "telemt owner still resolves (F)" "$(core_port_allocation_owner F telemt)" "TeleMT"
rm -f /tmp/_pa_sub1

echo ""
echo "== 3. order independence =="
# (a) sourced with no other Core file present at all.
R1=$(bash -c 'source lib/core/port_allocation.sh; core_port_allocation_internal F xhttp')
# (b) sourced AFTER deployment.sh/topology.sh (reverse of what a
# production loader would eventually do).
R2=$(bash -c 'source lib/core/deployment.sh; source lib/core/port_allocation.sh; core_port_allocation_internal F xhttp')
# (c) sourced WITHOUT lib/panel/nginx/variant_f.sh or variant_j.sh ever
# being sourced in this shell at all -- proves this file has zero
# dependency on either of them being loaded first.
R3=$(bash -c '
    unset -v F_XRAY_XHTTP_PORT J_XRAY_XHTTP_PORT 2>/dev/null
    source lib/core/port_allocation.sh
    core_port_allocation_internal F xhttp
')
# (d) sourced twice (idempotency -- a second `source` must not change
# the answer or fail).
R4=$(bash -c 'source lib/core/port_allocation.sh; source lib/core/port_allocation.sh; core_port_allocation_internal F xhttp')
assert "order-independent (a) isolated"                 "$R1" "19444"
assert "order-independent (b) after deployment.sh"      "$R2" "19444"
assert "order-independent (c) without variant_f/j.sh"   "$R3" "19444"
assert "order-independent (d) sourced twice"            "$R4" "19444"

echo ""
echo "== 4. deterministic (repeated calls, same process, agree) =="
DET_OUT=$(bash -c '
    source lib/core/port_allocation.sh
    a=$(core_port_allocation_internal F xhttp)
    b=$(core_port_allocation_internal F xhttp)
    c=$(core_port_allocation_public J vision)
    d=$(core_port_allocation_public J vision)
    [ "$a" = "$b" ] && [ "$c" = "$d" ] && echo "stable" || echo "UNSTABLE"
')
assert "repeated calls in the same process return identical results" "$DET_OUT" "stable"

echo ""
echo "== 5. invalid topology/role behavior =="
source lib/core/port_allocation.sh
assert_fail "topology=1 has no row (valid topology, no port-split scheme)" core_port_allocation_public "1" "vision"
assert_fail "topology=2 has no row (valid topology, no port-split scheme)" core_port_allocation_public "2" "xhttp"
assert_fail "unknown role fails"                                            core_port_allocation_public "F" "bogus"
assert_fail "unknown topology fails"                                        core_port_allocation_public "X" "vision"
assert_fail "empty topology and role fail"                                  core_port_allocation_public "" ""
assert "core_port_allocation_role_is_valid accepts all 4 real roles" \
    "$(for r in vision xhttp panel_sub telemt; do core_port_allocation_role_is_valid "$r" && echo -n "1" || echo -n "0"; done)" "1111"
assert "core_port_allocation_role_is_valid rejects unknown role" \
    "$(core_port_allocation_role_is_valid bogus; echo $?)" "1"

echo ""
echo "== 6. no new MODE-based branching inside Core (this file never reads MODE/F_XHTTP_ENABLE/WEB_SERVER) =="
CODE_ONLY=$(grep -vE '^\s*#' lib/core/port_allocation.sh)
assert "port_allocation.sh's code contains zero MODE/F_XHTTP_ENABLE/WEB_SERVER references" \
    "$(grep -cE '\b(MODE|F_XHTTP_ENABLE|WEB_SERVER)\b' <<<"$CODE_ONLY")" "0"
assert "port_allocation.sh's code never references \$F_XRAY_VISION_PORT-style Panel globals directly" \
    "$(grep -cE '\$\{?[FJ]_(NGINX_HTTPS|XRAY_VISION|XHTTP_PUBLIC|XRAY_XHTTP)_PORT' <<<"$CODE_ONLY")" "0"
assert "port_allocation.sh does not source any lib/panel/*.sh file" \
    "$(grep -c 'lib/panel' <<<"$CODE_ONLY")" "0"

echo ""
echo "== 7. existing F_*/J_* variables in variant_f.sh/variant_j.sh are byte-unchanged =="
assert "F_NGINX_HTTPS_PORT=7443 still present, unchanged" "$(grep -c '^F_NGINX_HTTPS_PORT=7443$' lib/panel/nginx/variant_f.sh)" "1"
assert "F_XRAY_VISION_PORT=8443 still present, unchanged" "$(grep -c '^F_XRAY_VISION_PORT=8443$' lib/panel/nginx/variant_f.sh)" "1"
assert "F_XHTTP_PUBLIC_PORT=9443 still present, unchanged" "$(grep -c '^F_XHTTP_PUBLIC_PORT=9443$' lib/panel/nginx/variant_f.sh)" "1"
assert "F_XRAY_XHTTP_PORT=19444 still present, unchanged" "$(grep -c '^F_XRAY_XHTTP_PORT=19444$' lib/panel/nginx/variant_f.sh)" "1"
assert "J_XRAY_VISION_PORT=18443 still present, unchanged" "$(grep -c '^J_XRAY_VISION_PORT=18443$' lib/panel/nginx/variant_j.sh)" "1"
assert "J_XRAY_XHTTP_PORT=18444 still present, unchanged" "$(grep -c '^J_XRAY_XHTTP_PORT=18444$' lib/panel/nginx/variant_j.sh)" "1"
assert "J_NGINX_HTTPS_PORT=7444 still present, unchanged" "$(grep -c '^J_NGINX_HTTPS_PORT=7444$' lib/panel/nginx/variant_j.sh)" "1"
assert "J_XHTTP_PUBLIC_PORT=8443 still present, unchanged" "$(grep -c '^J_XHTTP_PUBLIC_PORT=8443$' lib/panel/nginx/variant_j.sh)" "1"
# api.sh's own pre-existing duplicated fallback (the officially-named
# migration debt) is likewise untouched by this step -- still there,
# still a duplicate, not yet resolved (that is a LATER, separate step).
assert "api.sh's own duplicated 19444 fallback is untouched (not migrated yet, by design)" \
    "$(grep -c 'F_XRAY_XHTTP_PORT:-19444' lib/panel/api.sh)" "1"

echo ""
echo "== 8. no substitution of 19444 (the named migration-debt regression case) =="
assert "F/xhttp internal_port is exactly 19444, not some other value" "$(core_port_allocation_internal F xhttp)" "19444"
assert "lib/core/port_allocation.sh's own F/xhttp row literally contains 19444" \
    "$(grep -c '19444' lib/core/port_allocation.sh)" "1"

echo ""
echo "== 9. negative mutation: corrupt the F/xhttp internal_port, confirm the accessor is actually load-bearing on the table (not a hardcoded pass-through) =="
cp lib/core/port_allocation.sh /tmp/_pa_backup.sh
awk '
    BEGIN{n=0}
    /"F:xhttp"\)     echo "9443\|19444\|reality\/xhttp\|no\|Xray" ;;/{
        n++
        if (n==1) { gsub(/19444/, "99999"); }
    }
    {print}
' lib/core/port_allocation.sh > /tmp/_pa_mutated.sh

MUTATION_HIT_COUNT="$(grep -c '"F:xhttp")     echo "9443|99999|reality/xhttp|no|Xray" ;;' /tmp/_pa_mutated.sh)"
assert "negative-mutation precondition: the F/xhttp row was actually found and mutated exactly once" \
    "$MUTATION_HIT_COUNT" "1"

if [ "$MUTATION_HIT_COUNT" = "1" ]; then
    cp /tmp/_pa_mutated.sh lib/core/port_allocation.sh
    NEG_OUT=$(bash -c 'source lib/core/port_allocation.sh; core_port_allocation_internal F xhttp' 2>/dev/null)
    cp /tmp/_pa_backup.sh lib/core/port_allocation.sh
else
    NEG_OUT="MUTATION_NOT_APPLIED"
fi
DIFF_AFTER_RESTORE="$(diff -q /tmp/_pa_backup.sh lib/core/port_allocation.sh >/dev/null 2>&1 && echo identical || echo DIFFERS)"
rm -f /tmp/_pa_backup.sh /tmp/_pa_mutated.sh

assert "mutated table returns the corrupted value, not a hardcoded 19444 (accessor genuinely reads the table)" \
    "$NEG_OUT" "99999"
assert "self-repair: port_allocation.sh restored byte-identical to its pre-mutation content" \
    "$DIFF_AFTER_RESTORE" "identical"
assert "self-repair: bash -n port_allocation.sh still passes after restore" \
    "$(bash -n lib/core/port_allocation.sh; echo $?)" "0"
assert "self-repair: F/xhttp internal_port is back to 19444 after restore" \
    "$(bash -c 'source lib/core/port_allocation.sh; core_port_allocation_internal F xhttp')" "19444"

echo ""
echo "== 10. no production call site exists yet (read-only layer, not wired in) =="
assert "no production file (outside lib/core/port_allocation.sh itself and this test) calls any core_port_allocation_* function" \
    "$(grep -rl 'core_port_allocation_' lib/ 2>/dev/null | grep -v 'lib/core/port_allocation.sh' | grep -v 'lib/sripts/tests/test_port_allocation.sh' | wc -l)" "0"
assert "lib/panel/api.sh's XHTTP port fallback logic is unchanged (not migrated in this step)" \
    "$(grep -c 'echo \"\${F_XRAY_XHTTP_PORT:-19444}\" ;;' lib/panel/api.sh)" "1"
assert "lib/panel/install.sh's UFW XHTTP-port-per-topology branch is unchanged (not migrated in this step)" \
    "$(grep -c 'J_XHTTP_PUBLIC_PORT:-8443' lib/panel/install.sh)" "1"

echo ""
echo "==================================="
echo "PASS=$PASS FAIL=$FAIL"
echo "==================================="
[ "$FAIL" -eq 0 ]
