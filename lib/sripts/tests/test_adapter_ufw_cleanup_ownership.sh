#!/bin/bash
# lib/sripts/tests/test_adapter_ufw_cleanup_ownership.sh
#
# UFW lifecycle audit (follow-up to commit 89a2aa1, "Implement
# panel_cleanup_xhttp_ufw_rules function"): that commit added a helper,
# called from panel_remove() and panel_reinstall(), that tears down the
# F/J public XHTTP UFW rules lib/panel/install.sh may have opened for a
# previous install. Its first version issued a bare
# `ufw delete allow "${_p}/tcp"` for each of the two known candidate
# ports (F=9443, J=8443) -- a plain port/proto specification with no
# comment filter, so against a real ufw it matches (and removes) *any*
# existing `ALLOW IN <port>/tcp Anywhere` rule on that port, not only a
# rule this tool itself created.
#
# CONFIRMED COLLISION: J's own public XHTTP port (8443) is the exact
# literal port lib/panel/mgmt_script.sh's do_open_port()/do_close_port()
# open and close for MODE=1/2 emergency admin access
# (`ufw allow 8443/tcp` / `ufw delete allow 8443/tcp`, no comment at
# all). do_open_port() refuses to run while the *currently installed*
# management script's baked-in $MODE is F or J, but a rule an admin
# opened under an earlier MODE=1/2 install is still just
# "ALLOW IN 8443/tcp Anywhere" at the ufw level by the time a later
# panel_reinstall()/panel_remove() call runs this cleanup -- and a bare
# port-spec delete cannot distinguish it from this tool's own XHTTP
# rule (nor from any other co-located, unrelated service's own
# `allow 8443/tcp`).
#
# This test proves (not just documents) the fix: the production
# function now identifies its own rule via `ufw status numbered`
# (read-only) filtered on BOTH the exact port AND the exact comment
# install.sh already stamps its own rule with ("Variant F XHTTP" /
# "Variant J XHTTP"), and deletes by rule number -- never a bare
# port-only spec.
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

echo "== A. bash -n lib/panel/management.sh =="
bash -n lib/panel/management.sh 2>/tmp/_ufwclean_synerr && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: bash -n lib/panel/management.sh"; cat /tmp/_ufwclean_synerr; }
rm -f /tmp/_ufwclean_synerr

echo ""
echo "== B. production source inspection =="
assert "panel_cleanup_xhttp_ufw_rules() defined exactly once" \
    "$(grep -c '^panel_cleanup_xhttp_ufw_rules() {' lib/panel/management.sh)" "1"
assert "called from panel_remove() exactly once" \
    "$(awk '/^panel_remove\(\)/,/^}/' lib/panel/management.sh | grep -c 'panel_cleanup_xhttp_ufw_rules$')" "1"
assert "called from panel_reinstall() exactly once" \
    "$(awk '/^panel_reinstall\(\)/,/^}/' lib/panel/management.sh | grep -c 'panel_cleanup_xhttp_ufw_rules$')" "1"

extract_fn() {
    local src="$1" fn="$2"
    awk -v fn="$fn" '
        $0 == fn"() {" { found=1 }
        found { print; if (/^}$/) exit }
    ' "$src"
}
FN_BLOCK="$(extract_fn lib/panel/management.sh panel_cleanup_xhttp_ufw_rules)"
assert "function body actually extracted (non-empty)" \
    "$([ -n "$FN_BLOCK" ] && echo present || echo MISSING)" "present"
assert "delete side reads ufw status numbered (read-only listing, not a raw port-only delete)" \
    "$(grep -c 'ufw status numbered' <<<"$FN_BLOCK")" "1"
assert "delete side filters by the F XHTTP comment install.sh stamps its own rule with" \
    "$(grep -c 'Variant \${_mode} XHTTP' <<<"$FN_BLOCK")" "1"
assert "no bare 'ufw delete allow \${_p}/tcp' (the old ownership-blind form) remains" \
    "$(grep -c 'ufw delete allow "\${_p}/tcp"' <<<"$FN_BLOCK")" "0"
assert "deletes by explicit rule number (--force delete \$_num), not by re-specifying the rule" \
    "$(grep -c 'ufw --force delete "\$_num"' <<<"$FN_BLOCK")" "1"

# ---------------------------------------------------------------------
# Behavioral scenarios against the REAL extracted function body (not a
# hand-copied reimplementation), each in its own isolated subshell under
# this project's own set -euo pipefail convention (server-manager.sh:13).
# ---------------------------------------------------------------------
run_cleanup() {
    # $1 = canned `ufw status numbered` output: $2 = "status_fail" to
    # make the `ufw status` call itself fail; $3 = "delete_fail" to make
    # every `ufw --force delete` call fail; $4 = "no_ufw" to simulate
    # ufw not being installed at all.
    local _status_output="$1" _status_mode="${2:-ok}" _delete_mode="${3:-ok}" _ufw_present="${4:-yes}"
    local _capture="$WORKDIR/ufw_capture_$$_$RANDOM"
    : > "$_capture"
    (
        set -euo pipefail
        source lib/core/config.sh
        source lib/core/topology.sh
        source lib/core/deployment.sh
        source lib/core/port_allocation.sh
        eval "$FN_BLOCK"
        if [ "$_ufw_present" = "no" ]; then
            command() { [ "$1" = "-v" ] && [ "$2" = "ufw" ] && return 1; builtin command "$@"; }
        else
            ufw() {
                if [ "$1" = "status" ]; then
                    [ "$_status_mode" = "status_fail" ] && return 1
                    printf '%s\n' "$_status_output"
                elif [ "$1" = "--force" ] && [ "$2" = "delete" ]; then
                    echo "DELETE_CALL:$3" >> "$_capture"
                    [ "$_delete_mode" = "delete_fail" ] && return 1 || return 0
                fi
            }
        fi
        panel_cleanup_xhttp_ufw_rules
        echo "FUNCTION_RC:$?" >> "$_capture"
    )
    echo "SUBSHELL_RC:$?" >> "$_capture"
    cat "$_capture"
    rm -f "$_capture"
}

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

STATUS_J_ONLY='[ 1] 22/tcp                     ALLOW IN    Anywhere
[ 2] 443/tcp                    ALLOW IN    Anywhere
[ 3] 8443/tcp                   ALLOW IN    Anywhere                   # Variant J XHTTP'

STATUS_F_ONLY='[ 1] 22/tcp                     ALLOW IN    Anywhere
[ 2] 9443/tcp                   ALLOW IN    Anywhere                   # Variant F XHTTP'

STATUS_J_PLUS_MGMT_ADMIN='[ 1] 22/tcp                     ALLOW IN    Anywhere
[ 2] 443/tcp                    ALLOW IN    Anywhere
[ 3] 8443/tcp                   ALLOW IN    Anywhere                   # Variant J XHTTP
[ 4] 8443/tcp                   ALLOW IN    Anywhere'

STATUS_MGMT_ADMIN_ONLY='[ 1] 22/tcp                     ALLOW IN    Anywhere
[ 2] 8443/tcp                   ALLOW IN    Anywhere'

STATUS_NOTHING='[ 1] 22/tcp                     ALLOW IN    Anywhere'

echo ""
echo "== D1. F+XHTTP rule present alone -> deleted (rule [2]) =="
R="$(run_cleanup "$STATUS_F_ONLY")"
assert "D1: deletes exactly rule [2]" "$(grep '^DELETE_CALL:' <<<"$R")" "DELETE_CALL:2"

echo ""
echo "== D2. J XHTTP rule present alone -> deleted (rule [3]) =="
R="$(run_cleanup "$STATUS_J_ONLY")"
assert "D2: deletes exactly rule [3]" "$(grep '^DELETE_CALL:' <<<"$R")" "DELETE_CALL:3"

echo ""
echo "== D3. LOAD-BEARING: J XHTTP (commented, [3]) + mgmt admin 8443 (uncommented, [4]) coexist =="
R="$(run_cleanup "$STATUS_J_PLUS_MGMT_ADMIN")"
assert "D3: deletes ONLY the XHTTP-commented rule [3]" "$(grep '^DELETE_CALL:' <<<"$R")" "DELETE_CALL:3"

echo ""
echo "== D4. Only an unrelated, uncommented 8443 rule exists (no XHTTP rule at all) -> untouched =="
R="$(run_cleanup "$STATUS_MGMT_ADMIN_ONLY")"
assert "D4: issues no delete call at all" "$(grep -c '^DELETE_CALL:' <<<"$R")" "0"

echo ""
echo "== D5. Nothing to clean up (idempotent no-op) =="
R="$(run_cleanup "$STATUS_NOTHING")"
assert "D5: issues no delete call, function still returns 0" \
    "$(grep -c '^DELETE_CALL:' <<<"$R"):$(grep '^FUNCTION_RC:' <<<"$R")" "0:FUNCTION_RC:0"

echo ""
echo "== D6. ufw not installed at all -> no crash, no calls =="
R="$(run_cleanup "" "ok" "ok" "no")"
assert "D6: function returns 0, no ufw calls" \
    "$(grep -c '^DELETE_CALL:' <<<"$R"):$(grep '^FUNCTION_RC:' <<<"$R")" "0:FUNCTION_RC:0"

echo ""
echo "== D7. set -e safety: 'ufw status' itself fails -> caller (subshell under set -euo pipefail) survives =="
R="$(run_cleanup "" "status_fail" "ok" "yes")"
assert "D7: subshell survives (does not abort under set -e)" "$(grep '^SUBSHELL_RC:' <<<"$R")" "SUBSHELL_RC:0"
assert "D7: function itself returns 0" "$(grep '^FUNCTION_RC:' <<<"$R")" "FUNCTION_RC:0"

echo ""
echo "== D8. set -e safety: 'ufw --force delete' itself fails -> lifecycle not aborted =="
R="$(run_cleanup "$STATUS_J_ONLY" "ok" "delete_fail" "yes")"
assert "D8: delete was attempted" "$(grep '^DELETE_CALL:' <<<"$R")" "DELETE_CALL:3"
assert "D8: subshell survives the failed delete" "$(grep '^SUBSHELL_RC:' <<<"$R")" "SUBSHELL_RC:0"
assert "D8: function itself still returns 0" "$(grep '^FUNCTION_RC:' <<<"$R")" "FUNCTION_RC:0"

echo ""
echo "== D8b. ADVERSARIAL COMMENT: substring-only matches must NOT be treated as this tool's own rule =="
STATUS_ADVERSARIAL='[ 1] 8443/tcp                   ALLOW IN    Anywhere                   # Not Variant J XHTTP
[ 2] 8443/tcp                   ALLOW IN    Anywhere                   # Variant J XHTTP something
[ 3] 8443/tcp                   ALLOW IN    Anywhere                   # SSH
[ 4] 8443/tcp                   ALLOW IN    Anywhere'
R="$(run_cleanup "$STATUS_ADVERSARIAL")"
assert "D8b: none of [1]-[4] (foreign/lookalike comments, unrelated comment, no comment) is ever deleted" \
    "$(grep -c '^DELETE_CALL:' <<<"$R")" "0"

# ---------------------------------------------------------------------
# D9/D10 -- NUMBER-SHIFT, the load-bearing question this follow-up audit
# was specifically asked to settle: is it safe to delete matched rules
# by number when deleting one rule renumbers every rule above it? None
# of D1-D8 above ever has more than one matching rule in the same
# mode-pass, so the `sort -rn` + delete-loop in the production function
# (the part of the code that exists *specifically* to handle this) was,
# until now, never actually exercised by more than a single candidate.
# ---------------------------------------------------------------------
echo ""
echo "== D9. NUMBER-SHIFT: J XHTTP has TWO matching rules (v4 + v6-style duplicate at [3]/[4]) below which sits an unrelated admin 8443 rule at [2] =="
STATUS_J_TWO_PLUS_ADMIN='[ 1] 22/tcp                     ALLOW IN    Anywhere
[ 2] 8443/tcp                   ALLOW IN    Anywhere
[ 3] 8443/tcp                   ALLOW IN    Anywhere                   # Variant J XHTTP
[ 4] 8443/tcp (v6)              ALLOW IN    Anywhere (v6)               # Variant J XHTTP
[ 5] 443/tcp                    ALLOW IN    Anywhere'
R="$(run_cleanup "$STATUS_J_TWO_PLUS_ADMIN")"
assert "D9: deletes [4] then [3], strictly in that descending order -- proves the higher-numbered match is removed before the lower one is referenced, so the lower one's number can never have shifted out from under it" \
    "$(grep '^DELETE_CALL:' <<<"$R")" "$(printf 'DELETE_CALL:4\nDELETE_CALL:3')"
assert "D9: the unrelated admin rule [2] (uncommented, same port, LOWER number than both matches) is never referenced" \
    "$(grep -c '^DELETE_CALL:2$' <<<"$R")" "0"

echo ""
echo "== D10. NUMBER-SHIFT (non-adjacent): three J XHTTP matches interspersed with foreign/admin rules on the SAME port at every intervening position -- if descending order were NOT used (or matches were re-numbered after each delete), an earlier deletion could shift a still-pending match's number onto a foreign row, deleting it by mistake =="
STATUS_J_INTERSPERSED='[ 1] 8443/tcp                   ALLOW IN    Anywhere
[ 2] 8443/tcp                   ALLOW IN    Anywhere                   # Variant J XHTTP
[ 3] 8443/tcp                   ALLOW IN    Anywhere
[ 4] 8443/tcp                   ALLOW IN    Anywhere                   # Variant J XHTTP
[ 5] 8443/tcp                   ALLOW IN    Anywhere
[ 6] 8443/tcp                   ALLOW IN    Anywhere                   # Variant J XHTTP'
R="$(run_cleanup "$STATUS_J_INTERSPERSED")"
assert "D10: deletes exactly [6], [4], [2] in strictly descending order" \
    "$(grep '^DELETE_CALL:' <<<"$R")" "$(printf 'DELETE_CALL:6\nDELETE_CALL:4\nDELETE_CALL:2')"
assert "D10: none of the interspersed foreign rules [1]/[3]/[5] (same port, no/other comment) is ever referenced" \
    "$(grep -cE '^DELETE_CALL:(1|3|5)$' <<<"$R")" "0"

# ---------------------------------------------------------------------
# E. LOAD-BEARING NEGATIVE CONTROL
#
# Re-run scenario D3 (the ownership-critical one) against a MUTATED,
# in-memory-only reimplementation matching 89a2aa1's *original* bare
# port-only delete -- never written to any file on disk -- to prove this
# test suite actually fails when the ownership fix is absent, i.e. it is
# not vacuously true. No repository file is touched by this section.
# ---------------------------------------------------------------------
echo ""
echo "== E. NEGATIVE CONTROL: original (pre-fix) bare port-delete logic against scenario D3 =="
MUTATED_FN='panel_cleanup_xhttp_ufw_rules() {
    command -v ufw &>/dev/null || return 0
    local _p
    _p="$(core_port_allocation_public "F" "xhttp" 2>/dev/null)" || _p=""
    if [ -n "$_p" ]; then
        ufw delete allow "${_p}/tcp" >/dev/null 2>&1 || true
    fi
    _p="$(core_port_allocation_public "J" "xhttp" 2>/dev/null)" || _p=""
    if [ -n "$_p" ]; then
        ufw delete allow "${_p}/tcp" >/dev/null 2>&1 || true
    fi
    return 0
}'
run_mutated_cleanup() {
    local _capture="$WORKDIR/ufw_capture_mut_$$_$RANDOM"
    : > "$_capture"
    (
        set -euo pipefail
        source lib/core/config.sh
        source lib/core/topology.sh
        source lib/core/deployment.sh
        source lib/core/port_allocation.sh
        eval "$MUTATED_FN"
        ufw() {
            if [ "$1" = "delete" ]; then
                echo "OLD_DELETE_SPEC:$*" >> "$_capture"
            fi
        }
        panel_cleanup_xhttp_ufw_rules
    )
    cat "$_capture"
    rm -f "$_capture"
}
MUT_R="$(run_mutated_cleanup)"
echo "  original code's calls against the D3 fixture (J XHTTP + mgmt admin both on 8443): $MUT_R"
# The original code issues one indiscriminate `ufw delete allow 8443/tcp`
# call -- against a real ufw that single spec-based delete matches
# whichever "ALLOW IN 8443/tcp Anywhere" rule ufw finds (the XHTTP rule
# or the admin's), so it CANNOT be asserted to have preserved rule [4]
# the way the fixed function in D3 is proven to (D3 above passed by
# checking the *fixed* code never even issues a delete referencing
# anything but the numbered, comment-matched rule [3]). The original
# code's own delete call, by construction, carries no rule-number or
# comment at all -- proving it structurally cannot make D3's guarantee.
assert "negative control: original code's delete call is a bare port spec, not a numbered/comment-scoped one (proves D3 exercises real, fixable behavior)" \
    "$(grep -c '^OLD_DELETE_SPEC:delete allow 8443/tcp$' <<<"$MUT_R")" "1"
assert "negative control: original code has no mechanism to reference a specific rule number at all" \
    "$(grep -c -- '--force' <<<"$MUTATED_FN")" "0"

# ---------------------------------------------------------------------
# E2. LOAD-BEARING NEGATIVE CONTROL for the NUMBER-SHIFT property itself
# (D9/D10 above): mutate the REAL extracted function body -- not a
# hand-copied reimplementation -- by flipping its one `sort -rn`
# (descending) to `sort -n` (ascending), the exact property D9/D10 exist
# to prove. Never written to any file on disk.
# ---------------------------------------------------------------------
echo ""
echo "== E2. NEGATIVE CONTROL: ascending-order deletion (sort -n instead of sort -rn) against the D10 interspersed fixture =="
ASCENDING_MUTANT_FN="${FN_BLOCK//sort -rn/sort -n}"
assert "sanity: the mutation actually changed something (mutant differs from the real function body)" \
    "$([ "$ASCENDING_MUTANT_FN" != "$FN_BLOCK" ] && echo mutated || echo UNCHANGED)" "mutated"
run_ascending_mutant() {
    local _status_output="$1"
    local _capture="$WORKDIR/ufw_capture_asc_$$_$RANDOM"
    : > "$_capture"
    (
        set -euo pipefail
        source lib/core/config.sh
        source lib/core/topology.sh
        source lib/core/deployment.sh
        source lib/core/port_allocation.sh
        eval "$ASCENDING_MUTANT_FN"
        ufw() {
            if [ "$1" = "status" ]; then printf '%s\n' "$_status_output"
            elif [ "$1" = "--force" ] && [ "$2" = "delete" ]; then echo "DELETE_CALL:$3" >> "$_capture"; fi
        }
        panel_cleanup_xhttp_ufw_rules
    )
    cat "$_capture"
    rm -f "$_capture"
}
MUT_R2="$(run_ascending_mutant "$STATUS_J_INTERSPERSED")"
assert "negative control: ascending-order mutant requests deletes in [2],[4],[6] order (NOT descending) -- diverges from D10's proven-correct [6],[4],[2] sequence, proving D10 actually exercises and would fail against this real, plausible-looking regression" \
    "$MUT_R2" "$(printf 'DELETE_CALL:2\nDELETE_CALL:4\nDELETE_CALL:6')"
# (Note: this mock does not itself simulate ufw's real renumbering-on-
# delete side effect, so it cannot show the mutant deleting a wrong ROW
# the way a real ufw would -- it proves the mutant issues a different,
# unproven *sequence* of numbers than the one D9/D10 assert is correct.
# That divergence is exactly what would make D9/D10 fail against this
# mutant if it were the production code.)

# ---------------------------------------------------------------------
# E3. LOAD-BEARING NEGATIVE CONTROL for D8b: mutate the REAL extracted
# function body by reverting its anchored comment match back to a bare
# substring test (grep -F, no anchor) -- the exact pre-hardening shape
# -- and confirm it mis-fires on D8b's adversarial fixture. Never
# written to any file on disk.
# ---------------------------------------------------------------------
echo ""
echo "== E3. NEGATIVE CONTROL: unanchored substring comment match against D8b's adversarial fixture =="
# sed (not bash's ${var/pat/rep}, whose glob-pattern escaping for this
# much punctuation is error-prone) replaces the one line doing the
# anchored comment match with the pre-hardening bare substring form.
UNANCHORED_MUTANT_FN="$(printf '%s\n' "$FN_BLOCK" | sed -E 's/\| grep -E "# Variant \$\{_mode\} XHTTP.*/| grep -F "Variant ${_mode} XHTTP" \\/')"
assert "sanity: the mutation actually changed something" \
    "$([ "$UNANCHORED_MUTANT_FN" != "$FN_BLOCK" ] && echo mutated || echo UNCHANGED)" "mutated"
assert "sanity: the mutant is still syntactically valid bash" \
    "$(bash -n <(echo "$UNANCHORED_MUTANT_FN") 2>&1; echo $?)" "0"
run_unanchored_mutant() {
    local _status_output="$1"
    local _capture="$WORKDIR/ufw_capture_unanch_$$_$RANDOM"
    : > "$_capture"
    (
        set -euo pipefail
        source lib/core/config.sh
        source lib/core/topology.sh
        source lib/core/deployment.sh
        source lib/core/port_allocation.sh
        eval "$UNANCHORED_MUTANT_FN"
        ufw() {
            if [ "$1" = "status" ]; then printf '%s\n' "$_status_output"
            elif [ "$1" = "--force" ] && [ "$2" = "delete" ]; then echo "DELETE_CALL:$3" >> "$_capture"; fi
        }
        panel_cleanup_xhttp_ufw_rules
    )
    cat "$_capture"
    rm -f "$_capture"
}
MUT_R3="$(run_unanchored_mutant "$STATUS_ADVERSARIAL")"
assert "negative control: unanchored mutant wrongly deletes the two lookalike-comment rules [1] and [2] that D8b proves the real (anchored) code leaves alone" \
    "$MUT_R3" "$(printf 'DELETE_CALL:2\nDELETE_CALL:1')"

echo ""
echo "== F. no residual mutation: lib/panel/management.sh unchanged by running this test =="
# Re-extracted fresh from disk (not the $FN_BLOCK captured earlier in
# this process) and CODE-only (comment lines stripped) -- this file's
# own docstring convention legitimately discusses the old buggy pattern
# in prose (as design history, same as install.sh's own header
# comments), so a whole-file/comment-inclusive grep would false-positive
# on that prose. Section E's negative control never wrote to any file,
# so this is a sanity check on disk state, not a meaningful diff.
FN_BLOCK_AFTER="$(extract_fn lib/panel/management.sh panel_cleanup_xhttp_ufw_rules)"
FN_CODE_AFTER="$(grep -vE '^\s*#' <<<"$FN_BLOCK_AFTER")"
assert "management.sh's function body still readable from disk after this test run" \
    "$([ -n "$FN_BLOCK_AFTER" ] && echo present || echo MISSING)" "present"
assert "management.sh's CODE still calls ufw status numbered" \
    "$(grep -c 'ufw status numbered' <<<"$FN_CODE_AFTER")" "1"
assert "management.sh's CODE still has no bare ownership-blind delete line" \
    "$(grep -c 'ufw delete allow "\${_p}/tcp"' <<<"$FN_CODE_AFTER")" "0"

echo ""
echo "==================================="
echo "PASS=$PASS FAIL=$FAIL"
echo "==================================="
[ "$FAIL" -eq 0 ]
