#!/bin/bash
# lib/sripts/tests/test_core_stdout_stderr_contract.sh
#
# F7 hardening: header() and section() (lib/common/core.sh) used to write
# their UI banner text to stdout, unlike every other UI helper in
# lib/ui/output.sh (ok/info/warn/err/die/detail/step), all of which write
# to stderr per the documented contract:
#   "Contract 1 (docs/CONTRACTS.md): stdout carries machine-readable
#    return data only; stderr carries all UI text, diagnostics,
#    warnings, and errors."
# A repo-wide call-graph audit found zero live command-substitution
# captures of header()/section() output, so this was a latent, not a
# functional, violation -- this test guards against it becoming live
# again by regression.
#
# No existing test file covered this contract (checked: only incidental
# uses of the English word "section" in unrelated comments matched).
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

echo "== A. bash -n lib/common/core.sh =="
bash -n lib/common/core.sh 2>/tmp/_core_synerr && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: bash -n lib/common/core.sh"; cat /tmp/_core_synerr; }
rm -f /tmp/_core_synerr

echo ""
echo "== B. header(): stdout is empty, stderr carries the UI text =="
_OUT="$(source lib/ui/output.sh; source lib/common/core.sh; header "Probe Header" 2>/tmp/_hdr_err)"
assert "header() stdout is empty" "$_OUT" ""
assert "header() stderr contains the banner text" \
    "$(grep -c 'Probe Header' /tmp/_hdr_err)" "1"
rm -f /tmp/_hdr_err

echo ""
echo "== C. section(): stdout is empty, stderr carries the UI text =="
_OUT="$(source lib/ui/output.sh; source lib/common/core.sh; section "Probe Section" 2>/tmp/_sec_err)"
assert "section() stdout is empty" "$_OUT" ""
assert "section() stderr contains the banner text" \
    "$(grep -c 'Probe Section' /tmp/_sec_err)" "1"
rm -f /tmp/_sec_err

echo ""
echo "== D. production source inspection: no bare (stdout) echo/clear remains in header()/section() =="
FUNC_REGION="$(awk '/^header\(\) \{/,/^section\(\) \{/' lib/common/core.sh | sed '$d')"
FUNC_REGION2="$(awk '/^section\(\) \{/,/^\}$/' lib/common/core.sh)"
FULL_REGION="${FUNC_REGION}
${FUNC_REGION2}"
# Every echo/clear line inside these two functions must end in >&2.
BARE_LINES="$(grep -E '^\s*(echo|clear)\b' <<<"$FULL_REGION" | grep -cv '>&2')"
assert "zero echo/clear lines in header()/section() missing >&2" "$BARE_LINES" "0"

echo ""
echo "== E. regression: other UI helpers (lib/ui/output.sh) unaffected -- still stderr-only =="
for fn in ok info warn detail; do
    _OUT="$(source lib/ui/output.sh; "$fn" "x" 2>/dev/null)"
    assert "$fn() stdout is still empty (unaffected by this change)" "$_OUT" ""
done
_STEP_OUT="$(source lib/ui/output.sh; STEP_NUM=1; TOTAL_STEPS=3; step "x" 2>/dev/null)"
assert "step() stdout is still empty (unaffected by this change)" "$_STEP_OUT" ""
# err()/die() exit 1 -- run each in its own subshell so their exit
# doesn't abort this script (lib/common/core.sh sets -e when sourced).
( source lib/ui/output.sh; err "x" >/tmp/_err_o 2>/tmp/_err_e )
assert "err() still exits 1" "$?" "1"
assert "err() stdout still empty" "$(wc -c </tmp/_err_o)" "0"
( source lib/ui/output.sh; die "x" >/tmp/_die_o 2>/tmp/_die_e )
assert "die() still exits 1" "$?" "1"
assert "die() stdout still empty" "$(wc -c </tmp/_die_o)" "0"
rm -f /tmp/_err_o /tmp/_err_e /tmp/_die_o /tmp/_die_e

echo ""
echo "==================================="
echo "PASS=$PASS FAIL=$FAIL"
echo "==================================="
[ "$FAIL" -eq 0 ]
