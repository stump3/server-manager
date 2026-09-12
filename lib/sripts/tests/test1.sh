#!/usr/bin/env bash
export PATH="/tmp/adv-review/fakebin:$PATH"
export _SSH_PASS=x _SSH_USER=u _SSH_IP=127.0.0.1 _SSH_PORT=22
cd /tmp/smgr-audit
source lib/common/ssh.sh
init_ssh_helpers full
_SSH_EXEC_TIMEOUT=2
echo "=== process tree right after backgrounding RUN ==="
RUN "irrelevant" </dev/null &
JOB=$!
sleep 0.5
PGID=$(ps -o pgid= -p "$JOB" 2>/dev/null | tr -d ' ')
echo "job(subshell running RUN)=$JOB reported-pgid-of-that=$PGID"
ps --forest -e -o pid,ppid,pgid,comm | grep -E "timeout|sshpass|ssh$|sleep|PID"
echo "=== waiting for timeout (2s) to expire and reap ==="
wait "$JOB" 2>/dev/null
echo "RC=$?"
sleep 0.3
echo "=== process tree AFTER timeout fired -- any orphans? ==="
ps --forest -e -o pid,ppid,pgid,comm | grep -E "timeout|sshpass|ssh$|sleep" || echo "(none found -- clean)"
