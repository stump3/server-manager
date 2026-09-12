#!/usr/bin/env bash
export PATH="/tmp/adv-review/fakebin:$PATH"
export _SSH_PASS=x _SSH_USER=u _SSH_IP=127.0.0.1 _SSH_PORT=22
cd /tmp/smgr-audit
source lib/common/ssh.sh
init_ssh_helpers full
_SSH_EXEC_TIMEOUT=2

# Watcher: real production callers invoke `RUN "cmd"` directly (synchronous,
# no surrounding &) -- start a background watcher instead of backgrounding
# RUN itself, so RUN's own invocation pattern matches production exactly.
( for i in $(seq 1 40); do sleep 0.1; pgrep -f "sleep 999" > /tmp/adv-review/watch.out 2>/dev/null; done ) &
WATCHER=$!

RUN "irrelevant" </dev/null
echo "RUN returned RC=$?"
kill "$WATCHER" 2>/dev/null

for i in 1 2 3 4 5; do
    sleep 1
    N=$(pgrep -f "sleep 999" | grep -v "adv-review" | wc -l | tr -d ' ')
    echo "t+${i}s after RUN returned: real sleep-999 processes still alive = $N"
done
echo "=== final check via /proc cmdline (avoids pgrep -f matching our own script text) ==="
for p in $(pgrep sleep 2>/dev/null); do
    tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null; echo " (pid $p)"
done
