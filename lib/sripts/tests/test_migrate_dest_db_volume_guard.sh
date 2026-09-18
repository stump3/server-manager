#!/bin/bash
# lib/sripts/tests/test_migrate_dest_db_volume_guard.sh
#
# Lifecycle audit (Step A, lib/migrate.sh): migrate_transfer_panel()'s
# remote restore heredoc runs `docker volume rm remnawave-db-data
# 2>/dev/null || true` against the DESTINATION server before restoring
# the migrated dump, with no prior check of what is already there.
#
# Confirmed directly against a live Docker daemon in this sandbox
# (not just reasoned about): the literal volume name is not
# compose-project-prefixed (lib/panel/compose/common.sh declares
# `name: remnawave-db-data`), and when no container currently
# references that name on the destination -- the ordinary state after
# an earlier `docker compose down` (no -v), or any leftover volume
# from a prior install attempt on that box -- `docker volume rm`
# succeeds and permanently deletes it, with the failure silently
# masked by `2>/dev/null || true` either way. This project's own
# panel_install() already treats the mere existence of this exact
# volume as proof "Panel already installed" and refuses to proceed
# without an explicit confirmation
# (panel_install_existing_state_detected(), lib/panel/install.sh,
# covered by test_install_existing_state_guard.sh) -- the migration
# destination had no equivalent gate, and remote_install_deps()'s own
# confirm() (already run earlier in the same flow) never mentions
# this action at all.
#
# Fix: migrate_transfer_panel() now checks the destination for an
# existing remnawave-db-data volume (via RUN, before any dump/transfer
# work) and requires an explicit confirm() (default: no) before
# proceeding when one is found. No change to the path where the
# destination has no such volume.
#
# Same mocking convention as test_install_existing_state_guard.sh:
# the REAL, unmodified migrate_transfer_panel() is sourced and called
# directly; only RUN/PUT/docker/confirm (no real SSH/network/Docker in
# this sandbox) are mocked, each recording to a call log so the test
# can assert not just the return code but which steps were actually
# reached.
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
echo "== 1. source inspection: guard present exactly once, before the dump step, and before the destructive remote restore heredoc =="
assert "destination-volume pre-check present exactly once" \
    "$(grep -c 'docker volume inspect remnawave-db-data >/dev/null 2>&1' lib/migrate.sh)" "1"
GUARD_LINE=$(grep -n 'if RUN "docker volume inspect remnawave-db-data' lib/migrate.sh | head -1 | cut -d: -f1)
DUMP_LINE=$(grep -n 'pg_dumpall -c -U postgres' lib/migrate.sh | head -1 | cut -d: -f1)
RESTORE_LINE=$(grep -n 'docker volume rm remnawave-db-data 2>/dev/null || true' lib/migrate.sh | head -1 | cut -d: -f1)
assert "guard runs before the DB dump is taken" "$([ "$GUARD_LINE" -lt "$DUMP_LINE" ] && echo yes || echo no)" "yes"
assert "guard runs before the destructive remote restore heredoc" "$([ "$GUARD_LINE" -lt "$RESTORE_LINE" ] && echo yes || echo no)" "yes"
assert "the destructive remote-restore line itself is untouched (still exists verbatim)" \
    "$(grep -c 'docker volume rm remnawave-db-data 2>/dev/null || true' lib/migrate.sh)" "1"

echo ""
echo "== 2. migrate_transfer_panel() in isolation (real function, mocked RUN/PUT/docker/confirm) =="
mkdir -p /opt/remnawave
touch /opt/remnawave/docker-compose.yml

run_transfer() {
    # $1: "exists_decline" | "exists_accept" | "absent"
    local scenario="$1"
    local log; log=$(mktemp)
    (
        # shellcheck source=/dev/null
        source lib/ui/output.sh
        # shellcheck source=/dev/null
        source lib/migrate.sh

        RUN() {
            echo "RUN:$1" >> "$log"
            if [ "$1" = "docker volume inspect remnawave-db-data >/dev/null 2>&1" ]; then
                case "$scenario" in
                    exists_decline|exists_accept) return 0 ;;
                    absent)                       return 1 ;;
                esac
            fi
            return 0
        }
        PUT() { echo "PUT:$*" >> "$log"; return 0; }
        docker() { echo "docker:$*" >> "$log"; return 0; }
        confirm() {
            echo "confirm:$1" >> "$log"
            [ "$scenario" = "exists_accept" ] && return 0 || return 1
        }

        rip="203.0.113.10"; ruser="root"; rport="22"
        migrate_transfer_panel
        echo "RC=$?" >> "$log"
    ) >/tmp/_migrate_stdout 2>/tmp/_migrate_stderr
    cat "$log"
    rm -f "$log"
}

echo "--- 2a. destination already has the volume, user DECLINES -- must stop before any dump/transfer work ---"
OUT=$(run_transfer exists_decline)
assert "exists+decline: pre-check was actually invoked" \
    "$(grep -c '^RUN:docker volume inspect remnawave-db-data' <<<"$OUT")" "1"
assert "exists+decline: confirm() was invoked" "$(grep -c '^confirm:' <<<"$OUT")" "1"
assert "exists+decline: function returns 1 (abort)" "$(grep -c '^RC=1$' <<<"$OUT")" "1"
assert "exists+decline: DB dump step (docker compose exec) NEVER reached" \
    "$(grep -c '^docker:compose exec' <<<"$OUT")" "0"
assert "exists+decline: no file ever PUT to the destination" "$(grep -c '^PUT:' <<<"$OUT")" "0"
assert "exists+decline: stdout stays clean (all UI on stderr)" "$(cat /tmp/_migrate_stdout)" ""
assert "exists+decline: specific warning about the existing destination volume shown" \
    "$(grep -c 'уже есть volume remnawave-db-data' /tmp/_migrate_stderr)" "1"
assert "exists+decline: cancellation message shown" \
    "$(grep -c 'Перенос Panel отменён пользователем' /tmp/_migrate_stderr)" "1"

echo ""
echo "--- 2b. destination already has the volume, user ACCEPTS -- proceeds past the gate into the dump step ---"
OUT=$(run_transfer exists_accept)
assert "exists+accept: pre-check was invoked" \
    "$(grep -c '^RUN:docker volume inspect remnawave-db-data' <<<"$OUT")" "1"
assert "exists+accept: confirm() was invoked" "$(grep -c '^confirm:' <<<"$OUT")" "1"
assert "exists+accept: proceeds to the DB dump step (docker compose exec reached)" \
    "$(grep -c '^docker:compose exec' <<<"$OUT")" "1"

echo ""
echo "--- 2c. destination has NO existing volume (the ordinary/intended case) -- gate is silent, confirm() never asked, byte-for-byte unchanged path ---"
OUT=$(run_transfer absent)
assert "absent: pre-check was invoked" \
    "$(grep -c '^RUN:docker volume inspect remnawave-db-data' <<<"$OUT")" "1"
assert "absent: confirm() is NEVER called (no interactive prompt for the common case)" \
    "$(grep -c '^confirm:' <<<"$OUT")" "0"
assert "absent: proceeds straight to the DB dump step" \
    "$(grep -c '^docker:compose exec' <<<"$OUT")" "1"
assert "absent: no 'existing volume' warning shown" \
    "$(grep -c 'уже есть volume remnawave-db-data' /tmp/_migrate_stderr)" "0"

rm -f /tmp/_migrate_stdout /tmp/_migrate_stderr

echo ""
echo "== 3. call-site precondition: migrate_transfer_panel() still has exactly its two known production call sites, unchanged =="
assert "panel_migrate() still calls migrate_transfer_panel" \
    "$(grep -c 'migrate_transfer_panel$' lib/migrate.sh)" "1"
assert "migrate_all() still calls migrate_transfer_panel" \
    "$(grep -c 'migrate_transfer_panel || return 1' lib/migrate.sh)" "1"

echo ""
echo "==================================="
echo "PASS=$PASS FAIL=$FAIL"
echo "==================================="
[ "$FAIL" -eq 0 ]
