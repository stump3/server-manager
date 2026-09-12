#!/bin/bash
# lib/sripts/tests/test_ssh_reliability_f1.sh
#
# F1 (SSH reliability): execution timeout for RUN/PUT (lib/common/ssh.sh)
# and signal-safe local+remote cleanup for panel_install_remote_node()
# (lib/panel/node/install.sh).
#
# Section 1 exercises the REAL RUN()/PUT() function bodies from the real
# (patched) lib/common/ssh.sh, with `ssh`/`scp`/`sshpass` replaced by
# deterministic fake executables placed earlier on PATH -- no real network,
# no real remote host, matching the project's own "extract and exercise
# the real code" convention (see harness.sh) rather than a hand-copied
# reimplementation of RUN/PUT's logic.
#
# Section 2 exercises the REAL panel_install_remote_node() from the real
# (patched) lib/panel/node/install.sh, with every external dependency
# (Panel API, ask/confirm prompts, ssh target collection, config/site
# generation) mocked, and RUN/PUT themselves replaced with a small
# deterministic mock that can be told to block (to simulate "a RUN/PUT is
# in flight" for the signal tests) or return immediately. This is
# necessarily a mock, not the real RUN, because Section 1 already covers
# RUN/PUT's own timeout mechanism in isolation -- Section 2 is testing
# the *caller's* signal/cleanup contract, which must not depend on
# Section 1's mechanism also being exercised at the same time.
#
# Uses the real, literal /opt/remnanode path (the production code hardcodes
# it, so a faithful test of the real cleanup logic must operate on it) --
# safe in this disposable, non-deployed sandbox. A top-level EXIT trap in
# THIS test script guarantees it is removed at the end regardless of any
# individual test's outcome.

set -uo pipefail
# NOTE: deliberately NOT `set -e` for the *test script itself* (its own
# `assert` calls returning nonzero on a FAIL must not abort the run) --
# but Section 2 below explicitly exercises the sourced production code
# UNDER `set -e` in an inner scope, because server-manager.sh:13 runs the
# whole real tool under `set -euo pipefail`, and that interaction already
# caught two real bugs in the first draft of the trap functions (see
# lib/panel/node/install.sh's own comments on _node_install_cleanup /
# _node_install_signal_cleanup).

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
cleanup_all() {
    rm -rf "$WORKDIR" /opt/remnanode 2>/dev/null
}
trap cleanup_all EXIT

# ============================================================
# Section 1 -- RUN/PUT execution timeout + exit-code semantics
# ============================================================

FAKEBIN="$WORKDIR/fakebin"
mkdir -p "$FAKEBIN"

# sshpass stand-in: real sshpass reads the password from `-f FILE`, then
# execs the real ssh/scp. This fake just discards `-f FILE` and execs
# whatever follows -- which resolves to the fake ssh/scp below, because
# FAKEBIN is placed ahead of the real PATH.
cat > "$FAKEBIN/sshpass" << 'EOF'
#!/usr/bin/env bash
shift 2  # drop "-f <file>"
exec "$@"
EOF

# ssh stand-in: behavior selected by $FAKE_SSH_BEHAVIOR so one binary
# covers all of hang / success / ordinary-failure.
cat > "$FAKEBIN/ssh" << 'EOF'
#!/usr/bin/env bash
case "${FAKE_SSH_BEHAVIOR:-success}" in
    hang)    sleep 999 ;;
    success) exit 0 ;;
    fail)    exit 7 ;;
esac
EOF

cp "$FAKEBIN/ssh" "$FAKEBIN/scp"
chmod +x "$FAKEBIN"/*

export PATH="$FAKEBIN:$PATH"
export _SSH_PASS="unused"
export _SSH_USER="user"
export _SSH_IP="127.0.0.1"
export _SSH_PORT="22"

# shellcheck source=/dev/null
source lib/common/ssh.sh
init_ssh_helpers full
# Real value is 600s -- override to a fast value for the test. Exercises
# the exact same RUN/PUT bodies with a much shorter deadline, which is
# the standard way to make a timeout mechanism testable without a
# multi-minute test run.
_SSH_EXEC_TIMEOUT=1

echo "=== RUN timeout ==="
export FAKE_SSH_BEHAVIOR=hang
START=$(date +%s)
RUN "irrelevant, ssh is faked" </dev/null
RC=$?
ELAPSED=$(( $(date +%s) - START ))
assert "RUN with a hanging remote command returns 124 (GNU timeout convention)" "$RC" "124"
assert "RUN did not hang past the configured timeout (elapsed <= 5s)" "$([ "$ELAPSED" -le 5 ] && echo yes || echo no)" "yes"
assert "no leftover fake ssh process after RUN timeout" "$(pgrep -f "$FAKEBIN/ssh" | wc -l | tr -d ' ')" "0"

echo "=== PUT timeout ==="
export FAKE_SSH_BEHAVIOR=hang
START=$(date +%s)
PUT "irrelevant" "irrelevant" </dev/null
RC=$?
ELAPSED=$(( $(date +%s) - START ))
assert "PUT with a hanging remote command returns 124" "$RC" "124"
assert "PUT did not hang past the configured timeout (elapsed <= 5s)" "$([ "$ELAPSED" -le 5 ] && echo yes || echo no)" "yes"

echo "=== Normal RUN success ==="
export FAKE_SSH_BEHAVIOR=success
RUN "irrelevant" </dev/null
assert "RUN returns 0 on ordinary success, unaffected by the timeout wrapper" "$?" "0"

echo "=== Normal RUN failure, distinguishable from timeout ==="
export FAKE_SSH_BEHAVIOR=fail
RUN "irrelevant" </dev/null
RC=$?
assert "RUN preserves the remote command's own exit code (7)" "$RC" "7"
assert "an ordinary remote failure (7) is not confused with a timeout (124)" "$([ "$RC" != "124" ] && echo yes || echo no)" "yes"

echo "=== \$_LAST_SSH_PID is populated by an ordinary RUN call ==="
# (The stronger claim -- that this PID also equals its own process
# group's PGID, which is what makes `kill -TERM -- "-$_LAST_SSH_PID"`
# able to reach the whole sshpass/ssh subtree in one signal -- was
# verified directly against plain `timeout N cmd &` this session
# (confirmed: PID printed by $! matches `ps -o pgid=` for that same PID)
# and is a structural guarantee of GNU timeout's own default,
# non---foreground mode, not something RUN's wrapping changes. Re-probing
# it through RUN's own internal backgrounding here would require a
# second layer of backgrounding whose variable assignment cannot cross
# back out to this shell -- not evidence against the claim, just not a
# reliable place to re-observe it a second time.)
export FAKE_SSH_BEHAVIOR=success
RUN "irrelevant" </dev/null
assert "\$_LAST_SSH_PID is set to a non-empty PID after an ordinary RUN call" \
    "$([ -n "${_LAST_SSH_PID:-}" ] && echo yes || echo no)" "yes"

unset -f RUN PUT
unset _SSH_EXEC_TIMEOUT

# ============================================================
# Section 2 -- signal-safe cleanup for panel_install_remote_node()
# ============================================================
#
# Drives the exact, real trap-registration + cleanup-function code
# verbatim-extracted (awk) from lib/panel/node/install.sh -- not a
# hand-copied reimplementation -- in an isolated driver, rather than
# running the full panel_install_remote_node() end to end. Deliberately
# NOT full-function testing: panel_install_remote_node() also contains
# an unrelated, pre-existing, out-of-scope-for-F1 `read ... < /dev/tty`
# password prompt partway through, which requires a real controlling
# terminal to exercise at all and has nothing to do with the trap/
# cleanup logic this stage actually changes. Isolating the extracted
# block (same principle as harness.sh isolating panel_node_register()
# rather than driving the whole CLI) tests the real, shipped code for
# the thing this stage is actually responsible for, without dragging in
# unrelated, unchanged code's own environment requirements.

EXTRACTED="$WORKDIR/extracted_trap_block.sh"
awk '/^    local _selfsteal_staging=""/,/^    trap .*TERM$/' \
    lib/panel/node/install.sh > "$EXTRACTED"

assert "extraction actually found both function definitions (sanity check on the awk range)" \
    "$(grep -c '^    _node_install_cleanup()\|^    _node_install_signal_cleanup()' "$EXTRACTED")" "2"
assert "extraction actually found all three trap registrations" \
    "$(grep -c "^    trap " "$EXTRACTED")" "3"

RUN_CALL_LOG="$WORKDIR/run_calls.log"
warn() { echo "WARN: $*" >> "$WORKDIR/warn.log"; }
RUN() {
    echo "$1" >> "$RUN_CALL_LOG"
    case "$1" in
        *"docker compose up -d"*)
            sleep 999 &
            _LAST_SSH_PID=$!
            wait "$_LAST_SSH_PID" 2>/dev/null
            return $?
            ;;
        *) return 0 ;;
    esac
}

run_and_signal() {
    # Runs the extracted block in a driver that: creates the same local
    # artifacts the real function creates at this point (/opt/remnanode,
    # a staging dir), starts an in-flight "docker compose up -d" RUN call
    # (simulating "interrupted mid-deploy" -- the scenario an INT/TERM
    # actually needs to handle), then delivers the given signal and
    # returns the exit status. `set -euo pipefail` matches
    # server-manager.sh:13's real, whole-tool setting.
    local sig="$1"
    rm -rf /opt/remnanode
    : > "$RUN_CALL_LOG"
    : > "$WORKDIR/warn.log"

    (
        set -euo pipefail
        _SSH_IP="127.0.0.1"
        _SSH_USER="root"
        mkdir -p /opt/remnanode
        echo stub > /opt/remnanode/docker-compose.yml
        # $EXTRACTED's own first line is `local _selfsteal_staging=""` --
        # `local` is only valid inside a function, and in the real file
        # this whole block lives inside panel_install_remote_node(), so
        # the driver needs its own enclosing function for a faithful
        # `source`.
        _driver() {
            # shellcheck source=/dev/null
            source "$EXTRACTED"
            _selfsteal_staging="$(mktemp -d)"
            RUN "cd /opt/remnanode && docker compose up -d"
        }
        _driver
    ) < /dev/null > "$WORKDIR/stdout.log" 2>&1 &
    local job=$!

    local waited=0
    while ! grep -q "docker compose up -d" "$RUN_CALL_LOG" 2>/dev/null; do
        sleep 0.1
        waited=$((waited+1))
        [ "$waited" -gt 50 ] && break  # 5s safety cap
    done
    sleep 0.2  # let RUN actually reach `wait "$_LAST_SSH_PID"`

    kill -s "$sig" "$job" 2>/dev/null
    wait "$job" 2>/dev/null
    echo $?
}

echo "=== SIGINT cleanup ==="
RC=$(run_and_signal INT)
assert "SIGINT: process exits via signal death (128+2=130), not success" "$RC" "130"
assert "SIGINT: local /opt/remnanode removed" "$([ -d /opt/remnanode ] && echo present || echo removed)" "removed"
assert "SIGINT: remote best-effort cleanup (docker compose down) was attempted" \
    "$(grep -c "docker compose down" "$RUN_CALL_LOG")" "1"
assert "SIGINT: interruption message logged" "$(grep -c "Прервано" "$WORKDIR/warn.log")" "1"

echo "=== SIGTERM cleanup ==="
RC=$(run_and_signal TERM)
assert "SIGTERM: process exits via signal death (128+15=143), not success" "$RC" "143"
assert "SIGTERM: local /opt/remnanode removed" "$([ -d /opt/remnanode ] && echo present || echo removed)" "removed"
assert "SIGTERM: remote best-effort cleanup (docker compose down) was attempted" \
    "$(grep -c "docker compose down" "$RUN_CALL_LOG")" "1"

echo "=== Cleanup is idempotent / safe when nothing exists yet, and safe called twice ==="
rm -rf /opt/remnanode
(
    set -euo pipefail
    _driver() {
        # shellcheck source=/dev/null
        source "$EXTRACTED"
        _selfsteal_staging=""  # never created -- the "return 1 before mktemp" case
        _node_install_cleanup
        _node_install_cleanup  # called twice -- must not error, must not double-remove
    }
    _driver
) 2>"$WORKDIR/idempotent.err"
assert "cleanup against non-existent paths, called twice, produces no error" \
    "$([ -s "$WORKDIR/idempotent.err" ] && echo has-stderr || echo clean)" "clean"

echo "=== Remote cleanup is narrowly scoped (only the flow's own compose project) ==="
assert "remote cleanup command references only /opt/remnanode, not a broad path" \
    "$(grep "docker compose down" "$RUN_CALL_LOG" | grep -cv "/opt/remnanode")" "0"
assert "remote cleanup does not touch UFW / broad system state" \
    "$(grep -c "ufw reset\|docker system prune" "$RUN_CALL_LOG")" "0"

echo ""
echo "=== SUMMARY: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
