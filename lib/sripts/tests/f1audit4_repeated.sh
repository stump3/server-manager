#!/bin/bash
set -u
WORKDIR="$(mktemp -d)"
cd /home/claude/work/server-manager-f1

EXTRACTED="$WORKDIR/extracted.sh"
awk '/^    local _selfsteal_staging=""/,/^    trap .*TERM$/' \
    lib/panel/node/install.sh > "$EXTRACTED"

FAKEBIN="$WORKDIR/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/ssh" << 'EOF'
#!/usr/bin/env bash
sleep 999 &
wait
EOF
cat > "$FAKEBIN/sshpass" << 'EOF'
#!/usr/bin/env bash
shift 2
exec "$@"
EOF
chmod +x "$FAKEBIN"/*
cp "$FAKEBIN/ssh" "$FAKEBIN/scp"

LOG="$WORKDIR/log.txt"
: > "$LOG"
ts() { date +%s.%N; }

(
    set -euo pipefail
    export PATH="$FAKEBIN:$PATH"
    export _SSH_PASS=x _SSH_USER=root _SSH_IP=127.0.0.1 _SSH_PORT=22
    source /home/claude/work/server-manager-f1/lib/common/ssh.sh
    init_ssh_helpers full
    _SSH_EXEC_TIMEOUT=600

    _driver() {
        source "$EXTRACTED"
        _selfsteal_staging="$(mktemp -d)"
        echo "$(date +%s.%N) starting MAIN RUN (tag MAINRUNTAG)" >> "$LOG"
        RUN "MAINRUNTAG cd /opt/remnanode && docker compose up -d"
        echo "$(date +%s.%N) RUN returned $? -- SHOULD NOT REACH HERE" >> "$LOG"
    }
    mkdir -p /opt/remnanode
    echo stub > /opt/remnanode/docker-compose.yml
    _driver
) < /dev/null > "$WORKDIR/stdout.log" 2>&1 &
JOB=$!

for i in $(seq 1 50); do
    pgrep -f "MAINRUNTAG" > /dev/null 2>&1 && break
    sleep 0.1
done
sleep 0.3
echo "$(ts) T+0.0 sending FIRST SIGINT (job=$JOB)" >> "$LOG"
kill -INT "$JOB" 2>/dev/null

FOUND_CLEANUP=0
for i in $(seq 1 30); do
    if pgrep -f "compose down" > /dev/null 2>&1; then
        FOUND_CLEANUP=1
        break
    fi
    sleep 0.1
done
echo "$(ts) cleanup RUN detected: $FOUND_CLEANUP" >> "$LOG"
sleep 0.3
echo "$(ts) sending SECOND SIGINT" >> "$LOG"
kill -INT "$JOB" 2>/dev/null
sleep 0.5
echo "$(ts) sending SIGTERM" >> "$LOG"
kill -TERM "$JOB" 2>/dev/null

# Hard bound: 8 seconds max past SIGTERM before we give up and declare a hang.
WAITED=0
while kill -0 "$JOB" 2>/dev/null; do
    sleep 0.5
    WAITED=$((WAITED+1))
    [ "$WAITED" -gt 16 ] && { echo "$(ts) HANG: JOB still alive 8s after SIGTERM" >> "$LOG"; break; }
done
if kill -0 "$JOB" 2>/dev/null; then
    RC="HANGING"
else
    wait "$JOB" 2>/dev/null
    RC=$?
fi
echo "$(ts) final exit status: $RC" >> "$LOG"

echo "=== LOG ==="; cat "$LOG"
echo "=== DRIVER STDOUT ==="; cat "$WORKDIR/stdout.log"
echo "=== warn count ==="; grep -c "Прервано" "$WORKDIR/stdout.log"
echo "=== ALL descendant processes still under this workdir's fakebin ==="
pgrep -af "$FAKEBIN" || echo "none"

# Hard, targeted cleanup by exact path/JOB, not broad pkill.
kill -9 "$JOB" 2>/dev/null
pgrep -f "$FAKEBIN" | xargs -r kill -9 2>/dev/null
rm -rf /opt/remnanode "$WORKDIR"
echo "=== DONE rc=$RC ==="
