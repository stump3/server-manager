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
# UPDATED 2026-09-07 (Architecture Gap Discovery, Candidate 1): api.sh's
# own duplicated 19444/18444 fallback for the F/J arms has now been
# resolved -- panel_reality_xhttp_inbound_port()'s F/J arms call this
# file's core_port_allocation_internal() instead of re-typing the
# literal. This is the intended resolution of the migration debt named
# in docs/CORE_RUNTIME_CONTRACTS.md §13, not a regression of this
# section's original "nothing else changed" intent -- the F_*/J_*
# variable DEFINITIONS above are still byte-unchanged; only api.sh's
# OWN duplicate copy of one of those numbers is gone. Full behavioral
# proof (truth table, negative mutation, missing-accessor) lives in
# lib/sripts/tests/test_port_allocation_wiring.sh -- this assertion only
# confirms the literal fallback text is actually gone from api.sh now.
assert "api.sh's F-arm duplicated '\${F_XRAY_XHTTP_PORT:-19444}' literal fallback is gone (migrated to the Core accessor)" \
    "$(grep -c 'F_XRAY_XHTTP_PORT:-19444' lib/panel/api.sh)" "0"
assert "api.sh's F arm now calls core_port_allocation_internal \"F\" \"xhttp\" instead" \
    "$(grep -c 'F) core_port_allocation_internal "F" "xhttp"' lib/panel/api.sh)" "1"
# The MODE=1/2 catch-all's OWN separate literal (never part of this
# migration -- lib/core/port_allocation.sh has no topology-1/2 row at
# all, see that file's header) remains exactly as it always was.
assert "the untouched MODE=1/2 catch-all's \${J_XRAY_XHTTP_PORT:-18444} literal is still present (deliberately not migrated)" \
    "$(grep -c '\*) echo "\${J_XRAY_XHTTP_PORT:-18444}"' lib/panel/api.sh)" "1"

echo ""
echo "== 8. no substitution of 19444 (the named migration-debt regression case) =="
assert "F/xhttp internal_port is exactly 19444, not some other value" "$(core_port_allocation_internal F xhttp)" "19444"
assert "lib/core/port_allocation.sh's own F/xhttp DATA ROW literally contains 19444 (once -- comments elsewhere in the file also discuss 19444 as the named migration-debt case, which is expected and not counted here)" \
    "$(grep -c '"F:xhttp")     echo "9443|19444|reality/xhttp|no|Xray" ;;' lib/core/port_allocation.sh)" "1"

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
echo "== 10. UPDATED 2026-09-08 (Candidate 1 + Candidate 2 wiring landed): exactly two production consumers, both in Panel, never inside Core =="
# This section originally asserted "zero production consumers" (pre-
# Candidate 1), then "exactly one" (post-Candidate 1, api.sh only).
# Candidate 2 (lib/panel/install.sh's UFW XHTTP-port branch) added a
# second, real production consumer -- updating the count again is the
# same kind of "describes the new correct architecture" update as
# Candidate 1's own change to this section, not a weakening: the
# boundary invariant being checked (consumers are only ever in Panel,
# Core never calls back into Panel) is unchanged and still enforced
# below. Full production-behavior proof for each consumer lives in its
# own focused test (lib/sripts/tests/test_port_allocation_wiring.sh for
# api.sh, lib/sripts/tests/test_adapter_install_xhttp_ufw.sh for
# install.sh) -- this section only re-confirms the boundary shape from
# this file's own side.
CONSUMER_FILES="$(grep -rl 'core_port_allocation_' lib/ 2>/dev/null | grep -v 'lib/core/port_allocation.sh' | grep -v 'lib/sripts/tests/')"
assert "PortAllocation now has exactly two production consumer files" \
    "$(echo "$CONSUMER_FILES" | grep -c .)" "2"
assert "both production consumers are in lib/panel/ (Panel), never another lib/core/*.sh file" \
    "$(echo "$CONSUMER_FILES" | grep -vc '^lib/panel/')" "0"
assert "lib/panel/api.sh is one of the two consumers" \
    "$(echo "$CONSUMER_FILES" | grep -c '^lib/panel/api\.sh$')" "1"
assert "lib/panel/install.sh is the other of the two consumers" \
    "$(echo "$CONSUMER_FILES" | grep -c '^lib/panel/install\.sh$')" "1"
PRXIP_BODY="$(awk '/^panel_reality_xhttp_inbound_port\(\) \{$/{grab=1} grab{print} grab&&/^}$/{exit}' lib/panel/api.sh)"
PRXIP_CODE_ONLY="$(grep -vE '^\s*#' <<<"$PRXIP_BODY")"
assert "lib/panel/api.sh's function body actually extracted (non-empty)" \
    "$([ -n "$PRXIP_BODY" ] && echo present || echo MISSING)" "present"
assert "panel_reality_xhttp_inbound_port()'s CODE calls core_port_allocation_internal exactly twice (F arm, J arm -- not the untouched MODE=1/2 catch-all)" \
    "$(grep -c 'core_port_allocation_internal' <<<"$PRXIP_CODE_ONLY")" "2"
# Core still does not depend on Panel as a RESULT of gaining a consumer
# -- the dependency direction is Panel -> Core, never the reverse; this
# file's CODE (comments legitimately discuss lib/panel/*.sh paths by
# name throughout, as design documentation -- see section 6's own
# CODE_ONLY filtering for the same reasoning) must still contain zero
# references to any lib/panel/*.sh path or Panel's own F_*/J_* globals,
# exactly as section 6 above already established before this consumer
# existed.
assert "lib/core/port_allocation.sh's CODE (not its documentation comments) still does not source or reference any lib/panel path, even after gaining a Panel consumer" \
    "$(grep -c 'lib/panel' <<<"$CODE_ONLY")" "0"
# The table itself (the actual data, not who calls it) remains
# immutable -- still exactly 8 rows, still the same values verified in
# section 1 above.
assert "PortAllocation's own row table is still exactly 8 rows (immutable -- gaining a consumer did not add/remove/reshape rows)" \
    "$(grep -cE '^\s*"(F|J):(vision|panel_sub|xhttp|telemt)"\)' lib/core/port_allocation.sh)" "8"
# UPDATED 2026-09-08 (Candidate 2): lib/panel/install.sh's UFW
# XHTTP-port-per-topology branch, which was still untouched raw MODE
# after Candidate 1, is now itself migrated onto
# core_port_allocation_public("$MODE", "xhttp") -- full behavioral proof
# (truth table, negative mutation on this exact call site, call order)
# lives in lib/sripts/tests/test_adapter_install_xhttp_ufw.sh; this
# assertion only re-confirms, from this file's own side, that the old
# raw-literal branch is actually gone from install.sh now.
assert "lib/panel/install.sh no longer reads J_XHTTP_PUBLIC_PORT (migrated to core_port_allocation_public)" \
    "$(grep -c 'J_XHTTP_PUBLIC_PORT:-8443' lib/panel/install.sh)" "0"
assert "lib/panel/install.sh's XHTTP UFW gate now calls core_port_allocation_public \"\$MODE\" \"xhttp\"" \
    "$(grep -c 'core_port_allocation_public "\$MODE" "xhttp"' lib/panel/install.sh)" "1"
# lib/panel/api.sh:483-497's own, separate, structurally similar
# XHTTP_PUBLIC_PORT_VAL computation (for the Remnawave Host registration,
# not the UFW rule) was Candidate 3 (2026-09-08) -- migrated after
# Candidate 2, and unlike Candidate 2's site, the accessor call had to
# MOVE inside the pre-existing `[ "$XHTTP_ENABLE" = "1" ] && [ -n
# "$XHTTP_IBD_UUID" ]` gate, not just replace a literal in place:
# panel_setup_api() runs for every MODE (1/2/F/J) and PortAllocation has
# no row for topology 1/2 x role xhttp, so calling the accessor
# unconditionally (where the old raw MODE=F/J branch used to sit, ABOVE
# the gate) would abort every MODE=1/2 install under `set -euo pipefail`.
# See lib/sripts/tests/test_adapter_api_xhttp_host_port.sh for the full
# focused test (truth table, the MODE=1/2 no-abort proof, and negative
# mutation) -- this assertion only re-confirms, from this file's own
# side, that the old raw-literal branch is actually gone from api.sh now.
assert "lib/panel/api.sh no longer has the old unconditional MODE=F/J branch over raw \${F,J}_XHTTP_PUBLIC_PORT" \
    "$(grep -cE 'XHTTP_PUBLIC_PORT_VAL="\$\{[FJ]_XHTTP_PUBLIC_PORT' lib/panel/api.sh)" "0"
assert "lib/panel/api.sh's Host-registration block now calls core_port_allocation_public \"\$MODE\" \"xhttp\", INSIDE the XHTTP_ENABLE gate" \
    "$(awk '/if \[ "\$XHTTP_ENABLE" = "1" \]/{g=NR} /core_port_allocation_public "\$MODE" "xhttp"/{c=NR} END{print (g>0 && c>g) ? "inside" : "NOT-INSIDE"}' lib/panel/api.sh)" "inside"

echo ""
echo "== 11. no mutation of F_*/J_* port environment variables (accessor is read-only) =="
# Snapshot every F_*/J_* port variable BEFORE sourcing port_allocation.sh
# and calling its accessors, then again AFTER, in the SAME shell (not a
# subshell) so a real `export`/assignment from inside the sourced file
# would actually be visible here. Deliberately pre-seeds them (rather
# than leaving them unset) so the test can also prove the accessor
# doesn't CHANGE a pre-existing value it has no business touching -- an
# unset-before/unset-after comparison alone wouldn't catch a mutation
# that both sets and unsets the same variable inside one call.
ENV_MUTATION_RESULT=$(bash -c '
    F_NGINX_HTTPS_PORT=7443
    F_XRAY_VISION_PORT=8443
    F_XHTTP_PUBLIC_PORT=9443
    F_XRAY_XHTTP_PORT=19444
    J_NGINX_HTTPS_PORT=7444
    J_XRAY_VISION_PORT=18443
    J_XRAY_XHTTP_PORT=18444
    J_XHTTP_PUBLIC_PORT=8443
    BEFORE="$F_NGINX_HTTPS_PORT|$F_XRAY_VISION_PORT|$F_XHTTP_PUBLIC_PORT|$F_XRAY_XHTTP_PORT|$J_NGINX_HTTPS_PORT|$J_XRAY_VISION_PORT|$J_XRAY_XHTTP_PORT|$J_XHTTP_PUBLIC_PORT"
    BEFORE_VARS="$(compgen -v | grep -E "^[FJ]_(NGINX_HTTPS|XRAY_VISION|XHTTP_PUBLIC|XRAY_XHTTP)_PORT$" | sort)"

    source lib/core/port_allocation.sh
    for T in F J; do
        for R in vision xhttp panel_sub telemt; do
            core_port_allocation_public "$T" "$R" >/dev/null 2>&1
            core_port_allocation_internal "$T" "$R" >/dev/null 2>&1
            core_port_allocation_protocol "$T" "$R" >/dev/null 2>&1
            core_port_allocation_proxy_protocol "$T" "$R" >/dev/null 2>&1
            core_port_allocation_owner "$T" "$R" >/dev/null 2>&1
        done
    done

    AFTER="$F_NGINX_HTTPS_PORT|$F_XRAY_VISION_PORT|$F_XHTTP_PUBLIC_PORT|$F_XRAY_XHTTP_PORT|$J_NGINX_HTTPS_PORT|$J_XRAY_VISION_PORT|$J_XRAY_XHTTP_PORT|$J_XHTTP_PUBLIC_PORT"
    AFTER_VARS="$(compgen -v | grep -E "^[FJ]_(NGINX_HTTPS|XRAY_VISION|XHTTP_PUBLIC|XRAY_XHTTP)_PORT$" | sort)"

    if [ "$BEFORE" = "$AFTER" ] && [ "$BEFORE_VARS" = "$AFTER_VARS" ]; then
        echo "unchanged"
    else
        echo "MUTATED before=[$BEFORE] after=[$AFTER] before_vars=[$BEFORE_VARS] after_vars=[$AFTER_VARS]"
    fi
')
assert "pre-seeded F_*/J_* port variables are byte-identical before and after sourcing port_allocation.sh and calling every accessor for all 8 rows" \
    "$ENV_MUTATION_RESULT" "unchanged"

# Separately: same check but starting from completely UNSET F_*/J_*
# variables -- proves the accessor doesn't CREATE them either.
ENV_CREATION_RESULT=$(bash -c '
    unset -v F_NGINX_HTTPS_PORT F_XRAY_VISION_PORT F_XHTTP_PUBLIC_PORT F_XRAY_XHTTP_PORT \
             J_NGINX_HTTPS_PORT J_XRAY_VISION_PORT J_XRAY_XHTTP_PORT J_XHTTP_PUBLIC_PORT 2>/dev/null
    source lib/core/port_allocation.sh
    core_port_allocation_internal F xhttp >/dev/null 2>&1
    core_port_allocation_public J vision >/dev/null 2>&1
    CREATED="$(compgen -v | grep -E "^[FJ]_(NGINX_HTTPS|XRAY_VISION|XHTTP_PUBLIC|XRAY_XHTTP)_PORT$" | sort)"
    [ -z "$CREATED" ] && echo "none-created" || echo "CREATED: $CREATED"
')
assert "accessor does not CREATE any F_*/J_* port variable when none existed beforehand" \
    "$ENV_CREATION_RESULT" "none-created"

echo ""
echo "== 11. no mutation of F_*/J_* port environment variables (accessor is read-only) =="
# Snapshot every F_*/J_* port variable BEFORE sourcing port_allocation.sh
# and calling its accessors, then again AFTER, in the SAME shell (not a
# subshell) so a real `export`/assignment from inside the sourced file
# would actually be visible here. Deliberately pre-seeds them (rather
# than leaving them unset) so the test can also prove the accessor
# doesn't CHANGE a pre-existing value it has no business touching -- an
# unset-before/unset-after comparison alone wouldn't catch a mutation
# that both sets and unsets the same variable inside one call.
ENV_MUTATION_RESULT=$(bash -c '
    F_NGINX_HTTPS_PORT=7443
    F_XRAY_VISION_PORT=8443
    F_XHTTP_PUBLIC_PORT=9443
    F_XRAY_XHTTP_PORT=19444
    J_NGINX_HTTPS_PORT=7444
    J_XRAY_VISION_PORT=18443
    J_XRAY_XHTTP_PORT=18444
    J_XHTTP_PUBLIC_PORT=8443
    BEFORE="$F_NGINX_HTTPS_PORT|$F_XRAY_VISION_PORT|$F_XHTTP_PUBLIC_PORT|$F_XRAY_XHTTP_PORT|$J_NGINX_HTTPS_PORT|$J_XRAY_VISION_PORT|$J_XRAY_XHTTP_PORT|$J_XHTTP_PUBLIC_PORT"
    BEFORE_VARS="$(compgen -v | grep -E "^[FJ]_(NGINX_HTTPS|XRAY_VISION|XHTTP_PUBLIC|XRAY_XHTTP)_PORT$" | sort)"

    source lib/core/port_allocation.sh
    for T in F J; do
        for R in vision xhttp panel_sub telemt; do
            core_port_allocation_public "$T" "$R" >/dev/null 2>&1
            core_port_allocation_internal "$T" "$R" >/dev/null 2>&1
            core_port_allocation_protocol "$T" "$R" >/dev/null 2>&1
            core_port_allocation_proxy_protocol "$T" "$R" >/dev/null 2>&1
            core_port_allocation_owner "$T" "$R" >/dev/null 2>&1
        done
    done

    AFTER="$F_NGINX_HTTPS_PORT|$F_XRAY_VISION_PORT|$F_XHTTP_PUBLIC_PORT|$F_XRAY_XHTTP_PORT|$J_NGINX_HTTPS_PORT|$J_XRAY_VISION_PORT|$J_XRAY_XHTTP_PORT|$J_XHTTP_PUBLIC_PORT"
    AFTER_VARS="$(compgen -v | grep -E "^[FJ]_(NGINX_HTTPS|XRAY_VISION|XHTTP_PUBLIC|XRAY_XHTTP)_PORT$" | sort)"

    if [ "$BEFORE" = "$AFTER" ] && [ "$BEFORE_VARS" = "$AFTER_VARS" ]; then
        echo "unchanged"
    else
        echo "MUTATED before=[$BEFORE] after=[$AFTER] before_vars=[$BEFORE_VARS] after_vars=[$AFTER_VARS]"
    fi
')
assert "pre-seeded F_*/J_* port variables are byte-identical before and after sourcing port_allocation.sh and calling every accessor for all 8 rows" \
    "$ENV_MUTATION_RESULT" "unchanged"

# Separately: same check but starting from completely UNSET F_*/J_*
# variables -- proves the accessor doesn't CREATE them either.
ENV_CREATION_RESULT=$(bash -c '
    unset -v F_NGINX_HTTPS_PORT F_XRAY_VISION_PORT F_XHTTP_PUBLIC_PORT F_XRAY_XHTTP_PORT \
             J_NGINX_HTTPS_PORT J_XRAY_VISION_PORT J_XRAY_XHTTP_PORT J_XHTTP_PUBLIC_PORT 2>/dev/null
    source lib/core/port_allocation.sh
    core_port_allocation_internal F xhttp >/dev/null 2>&1
    core_port_allocation_public J vision >/dev/null 2>&1
    CREATED="$(compgen -v | grep -E "^[FJ]_(NGINX_HTTPS|XRAY_VISION|XHTTP_PUBLIC|XRAY_XHTTP)_PORT$" | sort)"
    [ -z "$CREATED" ] && echo "none-created" || echo "CREATED: $CREATED"
')
assert "accessor does not CREATE any F_*/J_* port variable when none existed beforehand" \
    "$ENV_CREATION_RESULT" "none-created"

echo ""
echo "==================================="
echo "PASS=$PASS FAIL=$FAIL"
echo "==================================="
[ "$FAIL" -eq 0 ]
