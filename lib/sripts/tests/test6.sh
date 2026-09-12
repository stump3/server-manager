#!/usr/bin/env bash
set -uo pipefail
export PATH="/tmp/adv-review/fakebin:$PATH"
export _SSH_PASS=x _SSH_USER=u _SSH_IP=127.0.0.1 _SSH_PORT=22
cd /tmp/smgr-audit

EXTRACTED="/tmp/adv-review/extracted.sh"
awk '/^    local _selfsteal_staging=""/,/^    trap .*TERM$/' lib/panel/node/install.sh > "$EXTRACTED"

warn() { echo "$(date +%s.%N) WARN: $*"; }
source lib/common/ssh.sh
init_ssh_helpers full
_SSH_EXEC_TIMEOUT=600

(
    set -euo pipefail
    _SSH_IP="127.0.0.1"; _SSH_USER="root"
    _node_remnanode_touched=1
    mkdir -p /opt/remnanode
    echo stub > /opt/remnanode/docker-compose.yml
    _driver() {
        source "$EXTRACTED"
        _selfsteal_staging="$(mktemp -d)"
        echo "$(date +%s.%N) driver pid=$$ bashpid=$BASHPID starting RUN"
        RUN "cd /opt/remnanode && docker compose up -d"
        echo "$(date +%s.%N) RUN returned $? -- should not print"
    }
    _driver
) < /dev/null > /tmp/adv-review/stdout6.log 2>&1 &
JOB=$!

for i in $(seq 1 50); do
    pgrep -f "adv-review/fakebin/ssh" > /dev/null 2>&1 && break
    sleep 0.1
done
sleep 0.3

echo "$(date +%s.%N) sending FIRST SIGINT"
kill -INT "$JOB"
sleep 0.3
echo "$(date +%s.%N) sending SECOND SIGINT (while cleanup should still be mid-flight,"
echo "  since the remote-cleanup RUN call now ALSO blocks on our fake ssh's hang)"
kill -INT "$JOB" 2>/dev/null
sleep 0.3
echo "$(date +%s.%N) sending SIGTERM too, for good measure"
kill -TERM "$JOB" 2>/dev/null

wait "$JOB" 2>/dev/null
RC=$?
echo "$(date +%s.%N) final exit status: $RC"
echo "=== full timestamped log ==="
cat /tmp/adv-review/stdout6.log
echo "=== how many times did the cleanup/warn message fire? ==="
grep -c "Прервано" /tmp/adv-review/stdout6.log
