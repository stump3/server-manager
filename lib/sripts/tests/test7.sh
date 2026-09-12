#!/usr/bin/env bash
# Uses REAL sshpass (installed earlier), with our fake `ssh` (which itself
# spawns a further grandchild) still ahead on PATH, to close the gap the
# permanent test's own fake sshpass (a pure exec-replacement) doesn't
# cover: real sshpass forks an extra process layer before reaching the
# target command (confirmed earlier this session).
export PATH="/tmp/adv-review/fakebin-sshreal:$PATH"
timeout 5 sshpass -f <(printf 'x\n') ssh irrelevant &
JOB=$!
sleep 0.5
PGID=$(ps -o pgid= -p "$JOB" | tr -d ' ')
echo "job=$JOB pgid=$PGID"
echo "=== tree ==="
ps --forest -e -o pid,ppid,pgid,comm | grep -E "timeout|sshpass|ssh$|sleep 999|PID"
echo "=== explicit group kill (what _node_install_signal_cleanup actually does) ==="
kill -TERM -- "-$JOB" 2>/dev/null
wait "$JOB" 2>/dev/null
sleep 1
echo "=== survivors, checked by exact binary name (not text-matching pgrep -f) ==="
ps -eo pid,comm | grep -E "^\s*[0-9]+ (ssh|sleep|sshpass)$" || echo "confirmed: zero survivors"
