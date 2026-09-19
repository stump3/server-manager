#!/bin/bash
# lib/sripts/tests/test_ufw_cleanup_real_ufw_stress.sh
#
# Step C (UFW ownership/lifecycle audit), item 3: the existing
# test_adapter_ufw_cleanup_ownership.sh proves panel_cleanup_xhttp_ufw_rules()
# and panel_cleanup_colocated_api_ufw_rule() are logically correct against a
# MOCKED `ufw` (a bash function returning canned `ufw status` text). That
# mock's fixtures (e.g. STATUS_J_PLUS_MGMT_ADMIN) model a commented 8443/tcp
# rule and a bare 8443/tcp rule coexisting as two separate numbered entries.
#
# THIS TEST FOUND, AGAINST THE REAL ufw BINARY, THAT THIS EXACT COEXISTENCE
# IS NOT REACHABLE VIA THE ACTUAL COMMANDS THIS CODEBASE ISSUES:
#
#   $ ufw allow 8443/tcp comment "Variant J XHTTP"   # Rule added
#   $ ufw allow 8443/tcp                             # Rule updated  <-- not a new rule!
#   $ ufw status numbered
#   [ 1] 8443/tcp  ALLOW IN  Anywhere                # comment is GONE
#
# Real ufw treats {port, proto, action, direction[, from]} as one identity;
# a second `ufw allow` on the same identity does not add a second rule, it
# overwrites the first rule's comment in place (last write wins, in EITHER
# order -- confirmed both ways). `ufw insert N` on an existing identity does
# the opposite: it always skips ("Skipping inserting existing rule"),
# leaving the original completely untouched. Only a genuinely different
# {port,...,from} tuple ever produces two separate, simultaneously-listed
# rules.
#
# Practical consequence for the real 8443 (XHTTP vs mgmt emergency-port)
# collision this audit already flagged: the risk isn't only "do_close_port()
# deletes the XHTTP rule" (already proven directly, separately, against a
# single rule -- delete-matching does ignore comments, unaffected by this
# finding). There's a second, previously undocumented mechanism this test
# proves directly: if do_open_port()'s bare `ufw allow 8443/tcp` ever runs
# while a commented "Variant J XHTTP" rule already occupies that exact
# port, it silently STRIPS the comment from the existing rule instead of
# adding anything -- permanently orphaning that rule from
# panel_cleanup_xhttp_ufw_rules()'s comment-based ownership check (the rule
# keeps ALLOWing traffic; the tool can just never recognize or remove it as
# its own again). Same narrow reachability caveat as already reported for
# the delete-side mechanism (requires the specific partial-reinstall-failure
# window) -- this doesn't change reachability, it documents a second real
# mechanism through the same narrow window.
#
# This test sources the REAL production functions (unmodified, from
# lib/panel/management.sh) and drives them against the REAL ufw binary
# (confirmed working in this sandbox), using fixtures that are actually
# reachable given the above -- different PORTS for "foreign" rules rather
# than an unreachable same-port-different-comment coexistence -- plus a
# dedicated test proving the comment-clobber finding itself.
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

command -v ufw >/dev/null 2>&1 || { echo "SKIP: ufw not installed in this environment"; echo "PASS=0 FAIL=0"; exit 0; }

echo "== 0. bash -n =="
bash -n lib/panel/management.sh && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: bash -n lib/panel/management.sh"; }

XHTTP_FN="$(awk '/^panel_cleanup_xhttp_ufw_rules\(\)/,/^}/' lib/panel/management.sh)"
COLOC_FN="$(awk '/^panel_cleanup_colocated_api_ufw_rule\(\)/,/^}/' lib/panel/management.sh)"
assert "extracted panel_cleanup_xhttp_ufw_rules() body (non-empty)" "$([ -n "$XHTTP_FN" ] && echo present || echo MISSING)" "present"
assert "extracted panel_cleanup_colocated_api_ufw_rule() body (non-empty)" "$([ -n "$COLOC_FN" ] && echo present || echo MISSING)" "present"

reset_real_ufw() {
    ufw --force reset >/dev/null 2>&1
    ufw --force enable >/dev/null 2>&1
}

run_xhttp_cleanup() {
    (
        core_port_allocation_public() {
            case "$1-$2" in
                J-xhttp) echo "8443" ;;
                F-xhttp) echo "9443" ;;
            esac
        }
        eval "$XHTTP_FN"
        panel_cleanup_xhttp_ufw_rules
    )
}

run_coloc_cleanup() {
    ( eval "$COLOC_FN"; panel_cleanup_colocated_api_ufw_rule )
}

echo ""
echo "== 1. NEW FINDING (real ufw): a bare re-add on an already-commented rule's exact port CLOBBERS its comment instead of adding a second rule =="
reset_real_ufw
ufw allow 8443/tcp comment "Variant J XHTTP" >/dev/null 2>&1
ADD_OUTPUT="$(ufw allow 8443/tcp 2>&1)"
STATUS_AFTER_CLOBBER="$(ufw status numbered 2>&1)"
assert "ufw itself reports this as an UPDATE, not a new rule" "$(echo "$ADD_OUTPUT" | grep -c 'Rule updated')" "1"
assert "exactly one 8443/tcp row exists afterward (no second row was created)" "$(echo "$STATUS_AFTER_CLOBBER" | grep -c '8443/tcp')" "1"
assert "the comment is gone from that one remaining row" "$(echo "$STATUS_AFTER_CLOBBER" | grep -c 'Variant J XHTTP')" "0"
assert "consequence: cleanup can no longer find/remove this now-uncommented rule at all" \
    "$(run_xhttp_cleanup >/dev/null 2>&1; ufw status | grep -c '8443/tcp')" "1"

echo ""
echo "== 2. REAL UFW: own commented rule + a genuinely separate foreign rule on a DIFFERENT port -> only own port's rule touched =="
reset_real_ufw
ufw allow 8443/tcp comment "Variant J XHTTP" >/dev/null 2>&1
ufw allow 22/tcp >/dev/null 2>&1
ufw allow 443/tcp >/dev/null 2>&1
run_xhttp_cleanup >/dev/null
STATUS2="$(ufw status 2>&1)"
assert "own 8443/tcp rule removed" "$(echo "$STATUS2" | grep -cF 'Variant J XHTTP')" "0"
assert "unrelated 22/tcp survives" "$(echo "$STATUS2" | grep -c '22/tcp')" "1"
assert "unrelated 443/tcp survives" "$(echo "$STATUS2" | grep -c '443/tcp')" "1"

echo ""
echo "== 3. REAL UFW: F and J rules BOTH present simultaneously (genuinely different ports, 9443 vs 8443) -> both removed in one pass, re-querying status between modes handles the shift correctly =="
reset_real_ufw
ufw allow 9443/tcp comment "Variant F XHTTP" >/dev/null 2>&1
ufw allow 22/tcp >/dev/null 2>&1
ufw allow 8443/tcp comment "Variant J XHTTP" >/dev/null 2>&1
run_xhttp_cleanup >/dev/null
STATUS3="$(ufw status 2>&1)"
assert "F's 9443/tcp rule removed" "$(echo "$STATUS3" | grep -cF 'Variant F XHTTP')" "0"
assert "J's 8443/tcp rule removed" "$(echo "$STATUS3" | grep -cF 'Variant J XHTTP')" "0"
assert "unrelated 22/tcp survives" "$(echo "$STATUS3" | grep -c '22/tcp')" "1"

echo ""
echo "== 4. REAL UFW: target rule absent entirely -> no-op, no error, nothing touched =="
reset_real_ufw
ufw allow 22/tcp >/dev/null 2>&1
ufw allow 8443/tcp >/dev/null 2>&1
run_xhttp_cleanup >/dev/null 2>&1
XHTTP_RC=$?
STATUS4="$(ufw status 2>&1)"
assert "function returns success even with nothing to clean" "$XHTTP_RC" "0"
assert "unrelated 22/tcp untouched" "$(echo "$STATUS4" | grep -c '22/tcp')" "1"
assert "unrelated bare 8443/tcp untouched" "$(echo "$STATUS4" | grep -c '8443/tcp')" "1"

echo ""
echo "== 5. REAL UFW: colocated API 2222 -- source address IS part of ufw's rule identity, so two DIFFERENT sources on the same port genuinely coexist =="
reset_real_ufw
ufw allow from 172.30.0.0/16 to any port 2222 proto tcp comment "Colocated Node API" >/dev/null 2>&1
ufw allow from 203.0.113.5 to any port 2222 proto tcp >/dev/null 2>&1
STATUS_PRE5="$(ufw status numbered 2>&1)"
assert "setup produced two genuinely separate 2222/tcp rows (different source is a different identity)" "$(echo "$STATUS_PRE5" | grep -c '2222/tcp')" "2"
run_coloc_cleanup >/dev/null
STATUS5="$(ufw status 2>&1)"
assert "own Colocated Node API rule removed" "$(echo "$STATUS5" | grep -cF 'Colocated Node API')" "0"
assert "unrelated foreign 2222 rule (different source) survives" "$(echo "$STATUS5" | grep -c '203.0.113.5')" "1"

reset_real_ufw
ufw --force disable >/dev/null 2>&1

echo ""
echo "==================================="
echo "PASS=$PASS FAIL=$FAIL"
echo "==================================="
[ "$FAIL" -eq 0 ]
