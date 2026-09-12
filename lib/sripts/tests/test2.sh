#!/usr/bin/env bash
export PATH="/tmp/adv-review/fakebin:$PATH"
export _SSH_PASS=x _SSH_USER=u _SSH_IP=127.0.0.1 _SSH_PORT=22
cd /tmp/smgr-audit
source lib/common/ssh.sh
init_ssh_helpers full
_SSH_EXEC_TIMEOUT=2
RUN "irrelevant" </dev/null &
JOB=$!
sleep 0.5
echo "=== tree right after start ==="
ps --forest -e -o pid,ppid,pgid,comm | grep -E "timeout|sshpass|ssh$|sleep 999|PID"
wait "$JOB" 2>/dev/null
echo "RC=$?"
for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 1
    N=$(pgrep -f "sleep 999" | wc -l | tr -d ' ')
    echo "t+${i}s after timeout fired: sleep-999 processes still alive = $N"
    if [ "$N" -eq 0 ]; then break; fi
done
echo "=== final tree ==="
ps --forest -e -o pid,ppid,pgid,stat,comm | grep -E "sleep 999|PID"
