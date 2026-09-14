#!/bin/bash
set -uo pipefail
WORKDIR=/tmp/f1_proof/run3
rm -rf "$WORKDIR"; mkdir -p "$WORKDIR/fakebin"
REPO_ROOT="/home/claude/a2-impl/server-manager-a2-impl"
cd "$REPO_ROOT"

FAKEBIN="$WORKDIR/fakebin"
cat > "$FAKEBIN/sshpass" << 'EOF'
#!/usr/bin/env bash
shift 2
exec "$@"
EOF
cat > "$FAKEBIN/ssh" << 'EOF'
#!/usr/bin/env bash
sleep 999
EOF
cp "$FAKEBIN/ssh" "$FAKEBIN/scp"
chmod +x "$FAKEBIN"/*

EXTRACTED="$WORKDIR/extracted.sh"
awk '/^    local _selfsteal_staging=""/,/^    trap .*TERM$/' \
    "$REPO_ROOT/lib/panel/node/install.sh" > "$EXTRACTED"

RUN_LOG="$WORKDIR/run_calls.log"
: > "$RUN_LOG"

(
    set -euo pipefail
    export PATH="$FAKEBIN:$PATH"
    export _SSH_PASS="unused"
    _SSH_IP="127.0.0.1"; _SSH_USER="root"; _SSH_PORT="22"
    mkdir -p /opt/remnanode; echo stub > /opt/remnanode/docker-compose.yml

    source "$REPO_ROOT/lib/common/ssh.sh"
    init_ssh_helpers full
    _SSH_EXEC_TIMEOUT=600

    warn() { echo "WARN: $*" >> "$WORKDIR/warn.log"; }

    _driver() {
        source "$EXTRACTED"
        _selfsteal_staging="$(mktemp -d)"
        _node_remote_owned=1
        echo "before RUN" >> "$RUN_LOG"
        RUN "cd /opt/remnanode && docker compose up -d"
        echo "after RUN rc=$?" >> "$RUN_LOG"
    }
    _driver
) < /dev/null > "$WORKDIR/stdout.log" 2>&1 &
JOB=$!
echo "job pid = $JOB"

# wait for the fake ssh to actually appear (bounded)
for i in $(seq 1 50); do
    pgrep -f "$FAKEBIN/ssh" > /dev/null 2>&1 && break
    sleep 0.1
done
echo "fake ssh present now: $(pgrep -f "$FAKEBIN/ssh" | tr '\n' ' ')"

kill -TERM "$JOB" 2>/dev/null
echo "sent TERM to $JOB"

# bounded wait for job to die, don't block forever
for i in $(seq 1 50); do
    kill -0 "$JOB" 2>/dev/null || break
    sleep 0.1
done
if kill -0 "$JOB" 2>/dev/null; then
    echo "JOB STILL ALIVE after 5s -- killing -9"
    kill -9 "$JOB" 2>/dev/null
else
    echo "job exited"
fi

sleep 0.3
echo "fake ssh remaining: $(pgrep -f "$FAKEBIN/ssh" | tr '\n' ' ')"
echo "--- run log ---"; cat "$RUN_LOG"
echo "--- stdout log ---"; cat "$WORKDIR/stdout.log" 2>/dev/null
