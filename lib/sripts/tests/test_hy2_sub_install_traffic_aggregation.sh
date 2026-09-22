#!/bin/bash
# lib/sripts/tests/test_hy2_sub_install_traffic_aggregation.sh
#
# CONFIRMED PRODUCTION BUG: integrations/hy-sub-install.sh's traffic-
# aggregation section ("Агрегация трафика Hysteria2 → Remnawave", step
# 3/6 "Настройка вебхуков Remnawave") ran as sequential top-level
# script code -- not inside a function -- while declaring
# `local _HY_NODE_ROW`. `local` outside a function is a hard bash
# error ("local: can only be used in a function"), which aborted every
# real install at this exact point the moment a user answered "y" to
# "Включить агрегацию трафика с панелью?" (the ERR trap fired,
# cleanup() printed "Строка 462: local _HY_NODE_ROW", install exited).
#
# Root cause chain (traced, not assumed): lib/hy2/integration.sh's
# _hy_integration_install() runs this file with a plain
# `bash "$install_script"` -- either the checked-out repo copy, or (if
# missing locally) a straight `curl` download to a mktemp file
# matching exactly the /tmp/hy-sub-install.XXXXXX.sh pattern from the
# bug report. Either way the content is byte-identical to this repo
# file -- no templating/generation step is involved, so the bug (and
# this fix) live entirely in integrations/hy-sub-install.sh itself.
#
# Fix: wrapped the whole self-contained section in
# hy_setup_traffic_aggregation() (confirmed self-contained -- none of
# its variables are read anywhere later in the file) rather than just
# dropping `local`, which would have silently turned _HY_NODE_ROW (and
# _TRAFFIC_SECRET, enable_agg, _HY_NODE_ADDRESS, _HY_NODE_ID,
# _HY_NODE_UUID) into real globals leaking into the rest of a 778-line
# sequential script.
#
# This test extracts and executes the REAL function body via `sed`
# (not a hand-copied reimplementation), same convention as this
# suite's NODE_BLOCK/HOST_BLOCK-style extraction tests. The real
# `read ... < /dev/tty` prompt is driven through an actual PTY
# (python3 pty), same technique and reasoning as
# migrate_panel_flow_harness.sh: overriding `read` as a shell function
# does not help here because the `< /dev/tty` redirection itself fails
# before any override would run in a sandbox with no controlling
# terminal. External commands (docker, systemctl, python3, pip3,
# apt-get) are mocked; /etc/hysteria/config.yaml and
# /etc/hy-webhook.env are real absolute paths, same convention as this
# suite's /opt/remnawave/.env-writing tests, restored on exit.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SRC="$REPO_ROOT/integrations/hy-sub-install.sh"
command -v python3 >/dev/null || { echo "python3 required"; exit 2; }

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

echo "== 0. bash -n on the real file =="
if bash -n "$SRC" 2>/tmp/_synerr; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1)); echo "  FAIL: bash -n $SRC"; cat /tmp/_synerr
fi
rm -f /tmp/_synerr

echo ""
echo "== 1. structural: the fix is a real function wrapper, not a dropped 'local' =="
assert "hy_setup_traffic_aggregation() defined exactly once" \
    "$(grep -c '^hy_setup_traffic_aggregation()' "$SRC")" "1"
assert "it is actually called (not just defined)" \
    "$(grep -c '^hy_setup_traffic_aggregation$' "$SRC")" "1"
assert "'local _HY_NODE_ROW' still present as a real declaration (scope restored, not deleted)" \
    "$(grep -cE '^[[:space:]]*local .*_HY_NODE_ROW' "$SRC")" "1"

echo ""
echo "== 2. real execution via PTY: extract and run the ACTUAL function body =="
FN_SRC=$(sed -n '/^hy_setup_traffic_aggregation()/,/^}/p' "$SRC")
if [ -z "$FN_SRC" ]; then
    echo "  FAIL: could not extract function body -- aborting section 2"
    FAIL=$((FAIL+1))
fi

BACKUP_CFG=/tmp/_hy_test_cfg_backup.yaml
BACKUP_ENV=/tmp/_hy_test_env_backup
[ -f /etc/hysteria/config.yaml ] && cp /etc/hysteria/config.yaml "$BACKUP_CFG"
[ -f /etc/hy-webhook.env ] && cp /etc/hy-webhook.env "$BACKUP_ENV"
mkdir -p /etc/hysteria
W=$(mktemp -d)
restore_and_cleanup() {
    if [ -f "$BACKUP_CFG" ]; then cp "$BACKUP_CFG" /etc/hysteria/config.yaml; rm -f "$BACKUP_CFG"; else rm -f /etc/hysteria/config.yaml; fi
    if [ -f "$BACKUP_ENV" ]; then cp "$BACKUP_ENV" /etc/hy-webhook.env; rm -f "$BACKUP_ENV"; else rm -f /etc/hy-webhook.env; fi
    rm -rf "$W"
}
trap restore_and_cleanup EXIT

echo "$FN_SRC" > "$W/fn.sh"

cat > "$W/child.sh" << 'EOF'
#!/bin/bash
set -uo pipefail
fn_file="$1"; mock_db="$2"; log="$3"; : > "$log"
BOLD=""; GRAY=""; GREEN=""; YELLOW=""; NC=""
ok()   { echo "OK:$*" >> "$log"; }
info() { echo "INFO:$*" >> "$log"; }
warn() { echo "WARN:$*" >> "$log"; }
docker() {
    case "$*" in
        "ps --format {{.Names}}") [ "$mock_db" = "up" ] && echo "remnawave-db" ;;
        exec\ remnawave-db\ psql*) [ "$mock_db" = "up" ] && echo "42|11111111-1111-1111-1111-111111111111" ;;
        *) return 1 ;;
    esac
    return 0
}
systemctl() { echo "SYSTEMCTL:$*" >> "$log"; return 0; }
python3() { return 0; }
pip3() { return 0; }
apt-get() { return 0; }
sleep() { :; }
source "$fn_file"
HY_DOMAIN="test.example.com"; MAIN_PORT="8443"
hy_setup_traffic_aggregation
echo "RC=$?" >> "$log"
declare -p _HY_NODE_ROW >> "$log" 2>&1 || echo "_HY_NODE_ROW: not set (correct)" >> "$log"
EOF

cat > "$W/driver.py" << 'EOF'
import os, pty, sys, select, time
fn, mock_db, log, child, ans = sys.argv[1:6]
if ans == "EMPTY": ans = ""
pid, fd = pty.fork()
if pid == 0:
    os.execvp("bash", ["bash", child, fn, mock_db, log])
out = b""; sent = False; end = time.time() + 30
prompt = "Включить агрегацию".encode()
while time.time() < end:
    r, _, _ = select.select([fd], [], [], 0.5)
    if r:
        try:
            d = os.read(fd, 4096)
        except OSError:
            break
        if not d:
            break
        out += d
        if not sent and prompt in out:
            os.write(fd, (ans + "\n").encode())
            sent = True
    else:
        try:
            p, _ = os.waitpid(pid, os.WNOHANG)
            if p:
                break
        except ChildProcessError:
            break
try:
    _, st = os.waitpid(pid, 0)
except ChildProcessError:
    st = 0
print(os.waitstatus_to_exitcode(st) if st >= 0 else -1)
EOF

run_scenario() {
    # $1 = mock_db (up/down), $2 = answer to send (y/n/EMPTY), $3 = cfg body (or "" for no trafficStats), $4 = log suffix
    local mock_db="$1" ans="$2" cfg_body="$3" log="$W/log_$4"
    if [ -n "$cfg_body" ]; then
        printf '%s\n' "$cfg_body" > /etc/hysteria/config.yaml
    else
        printf 'listen: :443\n' > /etc/hysteria/config.yaml
    fi
    printf 'UNRELATED_KEY=keep-me\n' > /etc/hy-webhook.env
    python3 "$W/driver.py" "$W/fn.sh" "$mock_db" "$log" "$W/child.sh" "$ans"
}

echo ""
echo "--- 2a. happy path: trafficStats configured, user answers Y, db up ---"
RC=$(run_scenario up y 'trafficStats:
  secret: mysecret123' 2a)
assert "2a: driver exit code 0" "$RC" "0"
assert "2a: no 'local: can only be used in a function' error (THE bug)" \
    "$(grep -c 'local: can only be used in a function' "$W/log_2a")" "0"
assert "2a: function returns 0" "$(grep -c '^RC=0$' "$W/log_2a")" "1"
assert "2a: HY_TRAFFIC_SECRET written" "$(grep -c '^HY_TRAFFIC_SECRET=mysecret123$' /etc/hy-webhook.env)" "1"
assert "2a: HY_NODE_ID written (docker+db available)" "$(grep -c '^HY_NODE_ID=42$' /etc/hy-webhook.env)" "1"
assert "2a: HY_NODE_UUID written" "$(grep -c '^HY_NODE_UUID=11111111-1111-1111-1111-111111111111$' /etc/hy-webhook.env)" "1"
assert "2a: _HY_NODE_ROW does not leak to caller's global scope" \
    "$(grep -c '_HY_NODE_ROW: not set (correct)' "$W/log_2a")" "1"

echo ""
echo "--- 2b. docker/remnawave-db unavailable: warns, no HY_NODE_ID, still completes ---"
RC=$(run_scenario down y 'trafficStats:
  secret: mysecret123' 2b)
assert "2b: driver exit code 0 (no crash)" "$RC" "0"
assert "2b: function returns 0" "$(grep -c '^RC=0$' "$W/log_2b")" "1"
assert "2b: HY_NODE_ID NOT written" "$(grep -c '^HY_NODE_ID=' /etc/hy-webhook.env)" "0"
assert "2b: HY_TRAFFIC_SECRET still written" "$(grep -c '^HY_TRAFFIC_SECRET=' /etc/hy-webhook.env)" "1"

echo ""
echo "--- 2c. user declines aggregation (answers n): nothing written, no crash ---"
RC=$(run_scenario up n 'trafficStats:
  secret: mysecret123' 2c)
assert "2c: driver exit code 0" "$RC" "0"
assert "2c: function returns 0" "$(grep -c '^RC=0$' "$W/log_2c")" "1"
assert "2c: HY_TRAFFIC_SECRET NOT written" "$(grep -c '^HY_TRAFFIC_SECRET=' /etc/hy-webhook.env)" "0"
assert "2c: pre-existing unrelated config untouched" "$(grep -c '^UNRELATED_KEY=keep-me$' /etc/hy-webhook.env)" "1"

echo ""
echo "--- 2d. empty Enter (default Y per \${enable_agg:-Y}): same as accepting ---"
RC=$(run_scenario up EMPTY 'trafficStats:
  secret: mysecret123' 2d)
assert "2d: driver exit code 0" "$RC" "0"
assert "2d: empty input defaults to accept -- HY_TRAFFIC_SECRET written" \
    "$(grep -c '^HY_TRAFFIC_SECRET=' /etc/hy-webhook.env)" "1"

echo ""
echo "--- 2e. trafficStats not configured at all: skipped cleanly before any prompt ---"
printf 'listen: :443\n' > /etc/hysteria/config.yaml
printf 'UNRELATED_KEY=keep-me\n' > /etc/hy-webhook.env
: > "$W/log_2e"
bash "$W/child.sh" "$W/fn.sh" up "$W/log_2e" < /dev/null > "$W/log_2e.out" 2>&1
assert "2e: completes without crashing (no tty prompt ever reached)" "$(grep -c '^RC=0$' "$W/log_2e")" "1"
assert "2e: hy-webhook.env untouched" "$(grep -c '^HY_TRAFFIC_SECRET=' /etc/hy-webhook.env)" "0"

echo ""
echo "--- 2f. idempotent re-run: stale values removed before new ones written, no dupes ---"
printf 'trafficStats:\n  secret: rotated-secret-456\n' > /etc/hysteria/config.yaml
cat > /etc/hy-webhook.env << 'EOF'
HY_TRAFFIC_SECRET=old-secret
HY_NODE_ID=999
UNRELATED_KEY=keep-me
EOF
python3 "$W/driver.py" "$W/fn.sh" up "$W/log_2f" "$W/child.sh" y > /dev/null
assert "2f: exactly one HY_TRAFFIC_SECRET line (stale one removed first)" \
    "$(grep -c '^HY_TRAFFIC_SECRET=' /etc/hy-webhook.env)" "1"
assert "2f: secret actually rotated, not stale" \
    "$(grep -c '^HY_TRAFFIC_SECRET=rotated-secret-456$' /etc/hy-webhook.env)" "1"
assert "2f: pre-existing unrelated config still untouched" \
    "$(grep -c '^UNRELATED_KEY=keep-me$' /etc/hy-webhook.env)" "1"

echo ""
echo "== 3. mutation test: proves this suite WOULD catch the original (pre-fix) bug =="
# Reconstruct the exact pre-fix shape: same body, but as bare top-level
# code (no enclosing function) with the original bare "local" line.
{
    echo '#!/bin/bash'
    echo 'set -uo pipefail'
    echo 'BOLD=""; GRAY=""; GREEN=""; YELLOW=""; NC=""'
    echo 'ok()   { echo "OK:$*"; }'
    echo 'info() { echo "INFO:$*"; }'
    echo 'warn() { echo "WARN:$*"; }'
    echo 'docker() { case "$*" in "ps --format {{.Names}}") echo "remnawave-db" ;; exec\ remnawave-db\ psql*) echo "42|11111111-1111-1111-1111-111111111111" ;; esac; return 0; }'
    echo 'systemctl() { return 0; }'
    echo 'HY_DOMAIN="test.example.com"; MAIN_PORT="8443"'
    echo "$FN_SRC" | sed '1d;$d'
} > "$W/mutated.sh"
printf 'trafficStats:\n  secret: mysecret123\n' > /etc/hysteria/config.yaml
: > /etc/hy-webhook.env
cat > "$W/mut_driver.py" << 'EOF'
import os, pty, sys, select, time
mut, log = sys.argv[1:3]
pid, fd = pty.fork()
if pid == 0:
    os.execvp("bash", ["bash", mut])
out = b""; sent = False; end = time.time() + 15
prompt = "Включить агрегацию".encode()
while time.time() < end:
    r, _, _ = select.select([fd], [], [], 0.5)
    if r:
        try:
            d = os.read(fd, 4096)
        except OSError:
            break
        if not d:
            break
        out += d
        if not sent and prompt in out:
            os.write(fd, b"y\n")
            sent = True
    else:
        try:
            p, _ = os.waitpid(pid, os.WNOHANG)
            if p:
                break
        except ChildProcessError:
            break
try:
    _, st = os.waitpid(pid, 0)
except ChildProcessError:
    st = 0
open(log, "wb").write(out)
rc = os.waitstatus_to_exitcode(st) if st >= 0 else -1
print(rc)
EOF
MUT_RC=$(python3 "$W/mut_driver.py" "$W/mutated.sh" "$W/log_mut")
assert "mutation: the pre-fix shape (bare top-level 'local') actually fails" \
    "$([ "$MUT_RC" != "0" ] && echo yes || echo no)" "yes"
assert "mutation: fails with the EXACT original production error" \
    "$(grep -c 'local: can only be used in a function' "$W/log_mut")" "1"

echo ""
echo "==================================="
echo "PASS=$PASS FAIL=$FAIL"
echo "==================================="
[ "$FAIL" -eq 0 ]
