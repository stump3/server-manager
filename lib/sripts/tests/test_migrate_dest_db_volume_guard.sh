#!/bin/bash
# lib/sripts/tests/test_migrate_dest_db_volume_guard.sh
#
# ORIGINAL FINDING (lifecycle audit, Step A, lib/migrate.sh):
# migrate_transfer_panel()'s remote restore heredoc ran `docker volume rm
# remnawave-db-data 2>/dev/null || true` against the DESTINATION server
# before restoring the migrated dump, with no prior check of what was
# already there -- silently destroying any pre-existing destination
# Panel install. This test originally exercised that fix directly
# against a bare mocked `confirm()` function with a default-no branch.
#
# SUPERSEDED (post-hardening): the fix was reworked from that bare
# confirm() into migrate_dest_existing_state_detected() gating an
# explicit warn + typed-'YES' `read -rp ... < /dev/tty` confirmation --
# the same convention panel_reinstall()/panel_remove() already use for
# equivalent destructive operations (lib/panel/management.sh). confirm()
# is no longer called anywhere in this path, so every assertion this
# file used to make against it (pre-check invocation, confirm() call
# count, accept/decline branching) tests a shape that no longer exists.
#
# That current contract -- detection semantics, wiring/ordering,
# wording, the typed-'YES' requirement, and the NOT-detected functional
# path -- is now covered, more precisely than this file ever did, by:
#   test_migrate_dest_existing_state_guard.sh (source inspection +
#     migrate_dest_existing_state_detected() in isolation + the
#     NOT-detected path extracted and run functionally + its own
#     negative control)
#   migrate_panel_flow_harness.sh (full end-to-end migrate_transfer_panel()
#     run through a real PTY: destination-absent, destination-exists
#     declined via several wrong answers incl. case-sensitivity, and
#     destination-exists accepted through to the actual remote restore
#     script, including that script's own pg_isready retry logic)
# Rather than delete this file outright, it is trimmed to the two
# things that investigation showed are NOT covered by either of those:
#
#   1. migrate_all()'s own call site -- neither sibling test's coverage
#      happens to touch migrate_all() itself (both drive
#      migrate_transfer_panel() directly), and test_a2_migrate_delegation.sh
#      (the file that does cover migrate_all()'s delegation) only checks
#      its migrate_prepare_target call, not migrate_transfer_panel.
#   2. the guard's own text output stays on stderr -- ok/info/warn/die/
#      detail all hard-code `>&2` (lib/ui/output.sh's own documented
#      Contract 1), so this is a source-level check that the guard block
#      routes its messages through those helpers rather than a bare
#      echo/printf that would leak onto stdout, not a runtime capture
#      (the DETECTED branch ends in the same un-drivable `< /dev/tty`
#      read as test_migrate_dest_existing_state_guard.sh's own
#      not-functionally-tested branch, for the same sandbox reason).
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

echo "== 0. bash -n =="
bash -n lib/migrate.sh 2>/tmp/_migrate_synerr && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: bash -n lib/migrate.sh"; cat /tmp/_migrate_synerr; }
rm -f /tmp/_migrate_synerr

echo ""
echo "== 1. call-site precondition: migrate_transfer_panel() still has exactly its two known production call sites, unchanged =="
assert "panel_migrate() still calls migrate_transfer_panel" \
    "$(grep -c 'migrate_transfer_panel$' lib/migrate.sh)" "1"
assert "migrate_all() still calls migrate_transfer_panel" \
    "$(grep -c 'migrate_transfer_panel || return 1' lib/migrate.sh)" "1"

echo ""
echo "== 2. guard block's own text output stays on stderr (no bare echo/printf that would leak onto stdout) =="
GUARD_BLOCK="$(awk '
    /^        if migrate_dest_existing_state_detected; then$/ { found=1 }
    found { print; if (/^        fi$/) exit }
' lib/migrate.sh)"
assert "guard block extracted from lib/migrate.sh (non-empty)" \
    "$([ -n "$GUARD_BLOCK" ] && echo present || echo MISSING)" "present"
assert "guard block has no bare echo/printf (only warn/info, which are >&2 in lib/ui/output.sh)" \
    "$(grep -cE '^[[:space:]]*(echo|printf)\b' <<<"$GUARD_BLOCK")" "0"

echo ""
echo "==================================="
echo "PASS=$PASS FAIL=$FAIL"
echo "==================================="
[ "$FAIL" -eq 0 ]
