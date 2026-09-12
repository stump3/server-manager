#!/usr/bin/env bash
set -uo pipefail
export PATH="/tmp/adv-review/fakebin:$PATH"
export _SSH_PASS=x _SSH_USER=u _SSH_IP=127.0.0.1 _SSH_PORT=22
cd /tmp/smgr-audit

EXTRACTED="/tmp/adv-review/extracted.sh"
awk '/^    local _selfsteal_staging=""/,/^    trap .*TERM$/' lib/panel/node/install.sh > "$EXTRACTED"

warn() { echo "WARN: $*"; }
RUN_CALLS="/tmp/adv-review/run_calls.log"
: > "$RUN_CALLS"
source lib/common/ssh.sh
init_ssh_helpers full
_SSH_EXEC_TIMEOUT=600   # the REAL production value -- must not be what saves us

(
    set -euo pipefail
    _SSH_IP="127.0.0.1"; _SSH_USER="root"
    _node_remnanode_touched=1
    mkdir -p /opt/remnanode
    echo stub > /opt/remnanode/docker-compose.yml
    _driver() {
        source "$EXTRACTED"
        _selfsteal_staging="$(mktemp -d)"
        echo "$$ / $BASHPID starting RUN (should block ~600s unless interrupted)"
        RUN "cd /opt/remnanode && docker compose up -d"
        echo "RUN returned $? -- SHOULD NOT REACH HERE if signal worked"
    }
    _driver
) < /dev/null > /tmp/adv-review/stdout.log 2>&1 &
JOB=$!

# wait until RUN's fake ssh has actually started blocking
for i in $(seq 1 50); do
    pgrep -f "adv-review/fakebin/ssh" > /dev/null 2>&1 && break
    sleep 0.1
done
sleep 0.3
echo "=== process tree just before SIGINT (job=$JOB) ==="
ps --forest -e -o pid,ppid,pgid,comm | grep -E "timeout|sshpass|adv-review/fakebin/ssh|sleep 999|PID"

kill -INT "$JOB"
wait "$JOB" 2>/dev/null
RC=$?
echo "backgrounded driver exit status: $RC"

echo "=== waiting up to 10s, checking for ANY surviving fake-ssh/sleep-999 processes ==="
for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 1
    N=$(pgrep -f "adv-review/fakebin/ssh|sleep 999" 2>/dev/null | wc -l | tr -d ' ')
    echo "t+${i}s: surviving processes = $N"
    [ "$N" -eq 0 ] && break
done
echo "=== final process check ==="
pgrep -af "adv-review/fakebin/ssh" || echo "no fake ssh survivors"
pgrep -af "sleep 999" || echo "no sleep-999 survivors"
echo "=== stdout log from the driver ==="
cat /tmp/adv-review/stdout.log
echo "=== did remote cleanup RUN call happen? ==="
echo "(N/A -- RUN itself is real here, not logged separately; see stdout.log 'Прервано' line)"
