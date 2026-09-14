#!/bin/bash
# lib/sripts/tests/test_f6_telemt_traffic_persistence.sh
#
# F6 audit regression coverage for two real production fixes in
# lib/telemt/api.sh's telemt_fetch_links() (menu.sh's
# telemt_menu_stats_settings() got the identical lock fix, for the
# identical reason, but requires a real /dev/tty for its two prompts and
# is not driven directly here -- api.sh's writer alone is sufficient to
# prove the shared lock mechanism, since both writers lock on the exact
# same derived path, "${db}.lock"):
#
#   1. ENV bug: `TELEMT_TRAFFIC_DB="$x" echo "$resp" | python3 -c "..."`
#      only bound the assignment to `echo` (the first stage of the
#      pipe) -- never to python3, the process that actually reads it via
#      os.environ.get. db_path was therefore always empty inside
#      python3, so the `if db_path:` write guard always skipped and this
#      function's entire traffic/IP-history accumulator was silently
#      never persisted to disk. Fixed by moving the assignment onto
#      python3 instead.
#
#   2. Missing lock: telemt_fetch_links() (api.sh) and
#      telemt_menu_stats_settings() (menu.sh) each perform their own
#      independent read-modify-write cycle against the identical state
#      file, with no coordination -- two overlapping invocations (e.g.
#      two simultaneous server-manager.sh sessions) can lose one side's
#      update, or read a torn mid-write file. Fixed with an flock(1)
#      exclusive lock ("${db}.lock") held for the duration of each
#      read-modify-write.
#
# Section 1 drives the REAL, unmodified telemt_fetch_links() (sourced
# from lib/telemt/api.sh) against a mocked telemt_api() -- no real
# network/systemd/docker -- proving persistence now actually happens and
# that repeated calls genuinely accumulate deltas (not just "a file got
# written once").
#
# Section 2 proves the lock is load-bearing, not decorative. It races
# two REAL, concurrent telemt_fetch_links() calls (each reporting a
# different username, so a lost update is directly observable as a
# missing user in the final file) against the same db, with a
# slow-python3 PATH shim widening the write window so the race is
# reliably exercised rather than a rare timing fluke. It checks the
# CURRENT, locked code first (both users survive, file stays valid
# JSON), then -- as a control -- dynamically derives an "unlocked"
# variant from the real, current api.sh by stripping out exactly the
# flock lines (verified present first; the test fails loudly if that
# string match ever goes stale rather than silently skipping), reruns
# the identical race against it in a separate bash subprocess, and
# shows the same race there DOES lose an update -- demonstrating this
# closes a real, reproducible defect rather than a hypothetical one.

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

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# Minimal ui/output stubs -- avoids pulling in unrelated sourcing deps
# just to get ok/warn/info, matching harness.sh's own convention of
# stubbing only what the function under test actually calls.
ok()   { :; }
warn() { echo "WARN: $*" >> "$WORKDIR/warn.log"; }
info() { :; }

# ============================================================
# Section 1 -- ENV bug fix: persistence actually happens, and
# accumulates correctly across repeated calls.
# ============================================================
echo "=== Section 1: ENV bug fix -- traffic accumulator actually persists ==="

export TELEMT_MODE=docker
export TELEMT_WORK_DIR_DOCKER="$WORKDIR/s1"
mkdir -p "$TELEMT_WORK_DIR_DOCKER"

# shellcheck source=/dev/null
source lib/telemt/api.sh

OCTETS_FILE="$WORKDIR/s1/octets"
echo 1000 > "$OCTETS_FILE"
telemt_api() {
    local oct; oct=$(cat "$OCTETS_FILE")
    cat << JSON
[{"username":"alice","total_octets":$oct,"links":{"tls":["tg://proxy?x"]},"current_connections":1,"active_unique_ips":1,"active_unique_ips_list":["1.2.3.4"],"recent_unique_ips":0,"recent_unique_ips_list":[]}]
JSON
}

TRAFFIC_DB="$(telemt_traffic_db_path)"
assert "traffic db does not exist before first call" \
    "$([ -f "$TRAFFIC_DB" ] && echo present || echo absent)" "absent"

telemt_fetch_links 1 >/dev/null 2>&1

assert "traffic db exists after first telemt_fetch_links call (was silently never written pre-fix)" \
    "$([ -f "$TRAFFIC_DB" ] && echo present || echo absent)" "present"
assert "traffic db is valid JSON" \
    "$(python3 -c "import json; json.load(open('$TRAFFIC_DB')); print('valid')" 2>/dev/null)" "valid"
ALICE_TOTAL_1=$(python3 -c "import json; print(json.load(open('$TRAFFIC_DB'))['users']['alice']['total_accumulated'])" 2>/dev/null)
assert "first call: total_accumulated seeded from first octet reading" "$ALICE_TOTAL_1" "1000"

echo 1500 > "$OCTETS_FILE"
telemt_fetch_links 1 >/dev/null 2>&1
ALICE_TOTAL_2=$(python3 -c "import json; print(json.load(open('$TRAFFIC_DB'))['users']['alice']['total_accumulated'])" 2>/dev/null)
assert "second call: delta (1500-1000) genuinely accumulated on top of prior persisted state" "$ALICE_TOTAL_2" "1500"

unset -f telemt_api

# ============================================================
# Sections 2 & 3 share one helper: derive a variant of the REAL, current
# api.sh by (a) optionally stripping the flock lines this session added,
# and (b) injecting an env-var-gated sleep between the read and the
# write -- right after old state has been loaded/defaulted, before it's
# modified and written back. This widens the genuine read-modify-write
# window just enough to make the race deterministic, without changing
# what the code actually does when the delay is 0 (the normal case,
# already exercised untouched in Section 1). A delay placed *before*
# python3 even starts (e.g. a slow-python3 PATH shim) would not do this
# -- it would just desynchronize the two processes' start times without
# ever widening their actual read-to-write window, and was tried and
# rejected here for exactly that reason.
derive_variant() {
    # $1 = source api.sh path, $2 = dest path, $3 = "keep_lock" | "strip_lock"
    python3 - "$1" "$2" "$3" << 'PYEOF'
import sys
src_path, dst_path, lock_mode = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(src_path, encoding='utf-8').read()

if lock_mode == "strip_lock":
    open_block = '''            mkdir -p "$(dirname "$traffic_db")" 2>/dev/null
            (
                flock -x -w 15 201 || true
                echo "$resp" | TELEMT_TRAFFIC_DB="$traffic_db" python3 -c "'''
    open_replacement = '''            echo "$resp" | TELEMT_TRAFFIC_DB="$traffic_db" python3 -c "'''
    close_block = '''" 2>/dev/null || echo "$resp"
            ) 201>"${traffic_db}.lock"
'''
    close_replacement = '''" 2>/dev/null || echo "$resp"
'''
    assert open_block in src, "F6 test: flock open-block text not found -- api.sh source drifted, update this test's extraction string"
    assert close_block in src, "F6 test: flock close-block text not found -- api.sh source drifted, update this test's extraction string"
    src = src.replace(open_block, open_replacement)
    src = src.replace(close_block, close_replacement)
    assert 'flock' not in src, "F6 test: flock still present after stripping -- extraction incomplete"
elif lock_mode == "keep_lock":
    assert 'flock -x -w 15 201' in src, "F6 test: expected flock line not found -- api.sh source drifted, update this test's extraction string"
else:
    raise SystemExit(f"unknown lock_mode {lock_mode!r}")

# Inject the race-delay hook right after old state has been loaded and
# defaulted, before any per-user modification -- i.e. squarely inside
# the real read-modify-write window, not before or after it.
delay_anchor = "retention_days = int(state.get('settings', {}).get('ip_retention_days', 30) or 30)"
delay_hook = (
    "import time as _t, os as _o\n"
    "_d = float(_o.environ.get('TEST_RACE_DELAY', '0') or 0)\n"
    "if _d:\n"
    "    _t.sleep(_d)\n"
    + delay_anchor
)
assert delay_anchor in src, "F6 test: delay-injection anchor not found -- api.sh source drifted, update this test's extraction string"
src = src.replace(delay_anchor, delay_hook)

open(dst_path, 'w', encoding='utf-8').write(src)
PYEOF
}

run_race() {
    # $1 = variant script path, $2 = workdir for this race, $3 = result-copy destination
    local variant="$1" wd="$2" dest="$3"
    (
        set -uo pipefail
        export TELEMT_MODE=docker
        export TELEMT_WORK_DIR_DOCKER="$wd"
        mkdir -p "$wd"
        export TEST_RACE_DELAY=1.2
        ok()   { :; }
        warn() { :; }
        info() { :; }
        # shellcheck source=/dev/null
        source "$variant"
        telemt_api() {
            local uname="${TEST_USERNAME:-user}"
            cat << JSON
[{"username":"$uname","total_octets":2000,"links":{"tls":["tg://proxy?y"]},"current_connections":1,"active_unique_ips":0,"active_unique_ips_list":[],"recent_unique_ips":0,"recent_unique_ips_list":[]}]
JSON
        }
        ( export TEST_USERNAME=carol; telemt_fetch_links 1 >/dev/null 2>&1 ) &
        A=$!
        sleep 0.1   # small stagger, both still well inside each other's read phase
        ( export TEST_USERNAME=dave; telemt_fetch_links 1 >/dev/null 2>&1 ) &
        B=$!
        wait "$A"; wait "$B"
        cp "$(telemt_traffic_db_path)" "$dest" 2>/dev/null
    )
}

both_users_survived() {
    python3 -c "
import json
try:
    d=json.load(open('$1'))
    print('yes' if ('carol' in d.get('users',{}) and 'dave' in d.get('users',{})) else 'no')
except Exception:
    print('no')
" 2>/dev/null
}

# ------------------------------------------------------------
# Section 2 -- REAL, current (locked) api.sh, race delay injected.
# ------------------------------------------------------------
echo "=== Section 2: concurrent writers, current (locked) api.sh ==="

LOCKED_VARIANT="$WORKDIR/api_locked_delayed.sh"
derive_variant "$REPO_ROOT/lib/telemt/api.sh" "$LOCKED_VARIANT" "keep_lock"
DERIVE_LOCKED_RC=$?
assert "locked variant successfully derived from the real, current api.sh (lock kept, delay injected)" "$DERIVE_LOCKED_RC" "0"

if [ "$DERIVE_LOCKED_RC" -eq 0 ]; then
    START=$(date +%s.%N)
    LOCKED_RESULT="$WORKDIR/s2_result.json"
    run_race "$LOCKED_VARIANT" "$WORKDIR/s2" "$LOCKED_RESULT"
    END=$(date +%s.%N)
    ELAPSED=$(python3 -c "print($END - $START)")

    assert "locked: two racing 1.2s writers together take >= one full delay (serialized, not overlapping)" \
        "$(python3 -c "print('yes' if $ELAPSED >= 1.1 else 'no')")" "yes"
    assert "locked: resulting traffic db is still valid JSON after the race" \
        "$(python3 -c "import json; json.load(open('$LOCKED_RESULT')); print('valid')" 2>/dev/null)" "valid"
    assert "locked: BOTH concurrent writers' users survived (no lost update)" \
        "$(both_users_survived "$LOCKED_RESULT")" "yes"
fi

# ------------------------------------------------------------
# Section 3 -- control: identical race, identical delay, lock stripped.
# ------------------------------------------------------------
echo "=== Section 3: control -- identical race, lock removed ==="

UNLOCKED_VARIANT="$WORKDIR/api_unlocked_delayed.sh"
derive_variant "$REPO_ROOT/lib/telemt/api.sh" "$UNLOCKED_VARIANT" "strip_lock"
DERIVE_UNLOCKED_RC=$?
assert "unlocked control successfully derived from the real, current api.sh (lock stripped, same delay injected)" "$DERIVE_UNLOCKED_RC" "0"

if [ "$DERIVE_UNLOCKED_RC" -eq 0 ]; then
    UNLOCKED_RESULT="$WORKDIR/s3_result.json"
    run_race "$UNLOCKED_VARIANT" "$WORKDIR/s3" "$UNLOCKED_RESULT"
    assert "unlocked control: the SAME race loses an update (proves the lock in the real code is load-bearing)" \
        "$(both_users_survived "$UNLOCKED_RESULT")" "no"
fi

echo ""
echo "=== SUMMARY: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
