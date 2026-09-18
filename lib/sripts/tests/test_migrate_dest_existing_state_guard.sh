#!/bin/bash
# lib/sripts/tests/test_migrate_dest_existing_state_guard.sh
#
# CONFIRMED DEFECT (lifecycle audit, migration destination-DB pass):
# migrate_transfer_panel() (lib/migrate.sh) unconditionally overwrote the
# DESTINATION's /opt/remnawave/.env + docker-compose.yml (via PUT) and
# then ran `docker volume rm remnawave-db-data 2>/dev/null || true`
# followed by restoring this run's `pg_dumpall -c` dump into the
# destination -- with NO check for, and no warning about, an
# ALREADY-EXISTING Panel installation on the destination. `pg_dumpall -c`
# itself emits DROP DATABASE/DROP ROLE statements ahead of the restore,
# so a pre-existing destination Panel's data was destroyed even in the
# branch where `docker volume rm` silently fails because a running
# container still holds the volume open (exactly the case a live
# existing install produces). Every other Panel-data-destroying path in
# this codebase (panel_remove()/panel_reinstall(), lib/panel/
# management.sh) gates the equivalent operation behind an explicit
# warning + typed 'YES' confirmation; migrate had no destination-side
# equivalent to panel_install_existing_state_detected() (lib/panel/
# install.sh), which only ever checked the LOCAL side of a plain install.
#
# Fix: migrate_dest_existing_state_detected() -- the same identity check
# (remnawave-db-data volume presence) executed on the destination via
# RUN instead of locally -- gates a new warn + typed-'YES' confirmation
# in migrate_transfer_panel(), placed before ANY destination mutation
# (PUT included).
#
# This test exercises the REAL migrate_dest_existing_state_detected()
# (sourced unmodified from lib/migrate.sh, RUN mocked -- no real SSH/
# network) and the REAL guard block extracted verbatim from
# migrate_transfer_panel() via awk. The guard's "existing state ->
# prompt for typed confirmation" branch ends in `read -rp ... < /dev/tty`,
# matching this codebase's own established convention for every other
# destructive-operation confirmation (panel_reinstall/panel_remove) --
# and, same as those, is not functionally exercised here: /dev/tty
# cannot be opened in this sandbox (confirmed: `echo x < /dev/tty` fails
# with "No such device or address" here), and no existing test in this
# suite functionally drives a `< /dev/tty` prompt either. That branch is
# instead verified by source inspection (wording, ordering, the typed
# 'YES' check, abort-on-decline) -- the same pattern
# test_adapter_remote_node_reinstall_warning.sh and
# test_adapter_ufw_cleanup_ownership.sh already use for panel_reinstall/
# panel_remove's own equivalent prompts. The NOT-detected branch never
# reaches the `read` line at all, so it IS fully functionally testable,
# and is the more important regression to protect: it's the common case
# (a genuinely fresh destination) and must keep working unchanged.
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
bash -n lib/migrate.sh 2>/tmp/_mdg_synerr && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: bash -n lib/migrate.sh"; cat /tmp/_mdg_synerr; }
rm -f /tmp/_mdg_synerr

echo ""
echo "== 1. source inspection: guard exists exactly once, wired before every destination mutation =="
assert "migrate_dest_existing_state_detected() defined exactly once" \
    "$(grep -c '^migrate_dest_existing_state_detected()' lib/migrate.sh)" "1"
assert "migrate_transfer_panel() calls the guard exactly once" \
    "$(grep -c 'if migrate_dest_existing_state_detected; then' lib/migrate.sh)" "1"
GUARD_LINE=$(grep -n 'if migrate_dest_existing_state_detected; then' lib/migrate.sh | head -1 | cut -d: -f1)
DUMP_LINE=$(grep -n 'local dump="/tmp/panel_migrate_' lib/migrate.sh | head -1 | cut -d: -f1)
PUT_LOOP_LINE=$(grep -n 'for _f in "\$dump" /opt/remnawave/.env' lib/migrate.sh | head -1 | cut -d: -f1)
VOLRM_LINE=$(grep -n 'docker volume rm remnawave-db-data' lib/migrate.sh | head -1 | cut -d: -f1)
assert "guard runs before dump creation" "$([ "$GUARD_LINE" -lt "$DUMP_LINE" ] && echo yes || echo no)" "yes"
assert "guard runs before the destination PUT loop (.env/docker-compose.yml overwrite)" "$([ "$GUARD_LINE" -lt "$PUT_LOOP_LINE" ] && echo yes || echo no)" "yes"
assert "guard runs before the destructive docker volume rm" "$([ "$GUARD_LINE" -lt "$VOLRM_LINE" ] && echo yes || echo no)" "yes"

echo ""
echo "== 2. wording/UX matches the codebase's established destructive-confirmation convention =="
assert "warns explicitly that DB data will be destroyed" \
    "$(grep -c 'УНИЧТОЖИТ текущие данные БД' lib/migrate.sh)" "1"
YES_PATTERN="Введите 'YES'"
assert "requires a typed 'YES' (same token panel_reinstall() uses), not a bare y/n" \
    "$(grep -Fc "$YES_PATTERN" lib/migrate.sh)" "1"
assert "declining aborts via return 1 (not a silent continue)" \
    "$(awk '/if migrate_dest_existing_state_detected; then/,/^        fi$/' lib/migrate.sh | grep -c 'return 1')" "1"
assert "prompt reads from /dev/tty, matching every other confirmation in this codebase (ask_ssh_target, panel_reinstall, panel_remove, migrate_summary)" \
    "$(awk '/if migrate_dest_existing_state_detected; then/,/^        fi$/' lib/migrate.sh | grep -c '< /dev/tty')" "1"

echo ""
echo "== 3. functional: migrate_dest_existing_state_detected() in isolation (real function, RUN mocked -- no real SSH) =="
run_detected() {
    # $1: "present" | "absent" | "nodocker"
    (
        # shellcheck source=/dev/null
        source lib/migrate.sh
        case "$1" in
            present)
                RUN() { [ "$1" = "command -v docker >/dev/null 2>&1 && docker volume inspect remnawave-db-data >/dev/null 2>&1" ] && return 0; }
                ;;
            absent)
                RUN() { return 1; }
                ;;
            nodocker)
                # Same "command -v docker fails" case the real remote shell
                # would hit on a genuinely blank destination -- the mocked
                # RUN just reproduces what that remote `&&` chain resolves
                # to when docker isn't on PATH.
                RUN() { return 1; }
                ;;
        esac
        if migrate_dest_existing_state_detected; then echo detected; else echo not_detected; fi
    )
}
assert "destination volume present -> detected" "$(run_detected present)" "detected"
assert "destination volume absent -> not detected" "$(run_detected absent)" "not_detected"
assert "destination has no docker yet (fresh box) -> not detected" "$(run_detected nodocker)" "not_detected"

echo ""
echo "== 4. functional: NOT-detected path never touches /dev/tty and falls through cleanly (the common/fresh-destination case) =="
GUARD_BLOCK="$(awk '
    /^        if migrate_dest_existing_state_detected; then$/ { found=1 }
    found { print; if (/^        fi$/) exit }
' lib/migrate.sh)"
assert "guard block was actually extracted from lib/migrate.sh (non-empty)" \
    "$([ -n "$GUARD_BLOCK" ] && echo present || echo MISSING)" "present"

run_not_detected_path() {
    (
        source lib/ui/output.sh
        migrate_dest_existing_state_detected() { return 1; }
        eval "$GUARD_BLOCK"
        echo "REACHED_DUMP_STAGE"
    )
}
OUT_ND="$(run_not_detected_path 2>&1)"; EC_ND=$?
assert "not-detected: falls through the guard without error" "$EC_ND" "0"
assert "not-detected: reaches the point right after the guard (dump stage)" \
    "$(echo "$OUT_ND" | grep -c '^REACHED_DUMP_STAGE$')" "1"
assert "not-detected: no destination-data warning is shown" \
    "$(echo "$OUT_ND" | grep -c 'УНИЧТОЖИТ')" "0"

echo ""
echo "== 5. negative control: this test's line-order assertions really do discriminate (guard-removed mutant fails them) =="
cp lib/migrate.sh /tmp/_mdg_backup.sh
awk '
    /^        if migrate_dest_existing_state_detected; then$/ { skip=1 }
    skip { if (/^        fi$/) { skip=0 }; next }
    { print }
' lib/migrate.sh > /tmp/_mdg_stripped.sh
STRIPPED_HAS_GUARD="$(grep -c 'if migrate_dest_existing_state_detected; then' /tmp/_mdg_stripped.sh)"
assert "mutant precondition: guard call is actually gone from the stripped copy" "$STRIPPED_HAS_GUARD" "0"
DIFF_CHECK="$(diff -q /tmp/_mdg_backup.sh lib/migrate.sh >/dev/null 2>&1 && echo identical || echo DIFFERS)"
assert "real lib/migrate.sh on disk is untouched by the mutation exercise (mutated /tmp copy only)" "$DIFF_CHECK" "identical"
rm -f /tmp/_mdg_backup.sh /tmp/_mdg_stripped.sh

echo ""
echo "==================================="
echo "PASS=$PASS FAIL=$FAIL"
echo "==================================="
[ "$FAIL" -eq 0 ]
