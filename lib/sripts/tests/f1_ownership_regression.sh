#!/bin/bash
# Ownership regression test for the F1 pre-write destructive-cleanup fix.
#
# Mocks RUN/PUT completely (they only ever append to a log file) so the
# test is judged purely on whether the destructive remote command string
# was ever dispatched -- not on any real filesystem side effect, which
# would conflate the LOCAL panel-host staging cleanup (a separate,
# already-safe concern: _node_install_cleanup()'s own `rm -rf
# /opt/remnanode "$_selfsteal_staging"` on the panel host) with the
# REMOTE "docker compose down" cleanup this fix actually gates.
set -u
cd /home/claude/work/server-manager-f1

EXTRACTED="$(mktemp)"
awk '/^    local _selfsteal_staging=""/,/^    trap .*TERM$/' \
    lib/panel/node/install.sh > "$EXTRACTED"

run_case() {
    # $1 = "pre-existing" (SIGINT before ownership) or "owned" (SIGINT
    # after ownership acquired, i.e. after the PUT that writes remote
    # /opt/remnanode has "succeeded").
    local case_name="$1"
    local workdir
    workdir="$(mktemp -d)"
    local runlog="$workdir/run.log"
    : > "$runlog"

    (
        set -euo pipefail
        RUN() { echo "RUN: $1" >> "$runlog"; return 0; }
        PUT() { echo "PUT: $*" >> "$runlog"; return 0; }
        _SSH_IP="127.0.0.1"; _SSH_USER="root"

        _driver() {
            source "$EXTRACTED"
            _selfsteal_staging="$(mktemp -d)"
            if [ "$case_name" = "owned" ]; then
                # Reach the exact point the real code reaches ownership:
                # right after the PUT that writes remote /opt/remnanode
                # succeeds (mirrors lib/panel/node/install.sh's own
                # `if PUT ...; then _node_remote_owned=1; ...; fi`).
                if PUT /opt/remnanode/docker-compose.yml /opt/remnanode/Caddyfile \
                    "${_SSH_USER}@${_SSH_IP}:/opt/remnanode/"; then
                    _node_remote_owned=1
                fi
            fi
            # Simulate the SIGINT arriving here in both cases -- for
            # "pre-existing" this models it landing anywhere between
            # ask_ssh_target and that PUT (check_ssh_connection, the
            # SELFSTEAL_DOMAIN/PANEL_IP prompts, remote_install_deps,
            # the ufw RUN call); for "owned" it models it landing any
            # time after that PUT (the second PUT, the docker compose up
            # RUN, or the later health-check steps).
            sleep 3
        }
        _driver
    ) < /dev/null > "$workdir/stdout.log" 2>&1 &
    JOB=$!
    sleep 0.5
    kill -INT "$JOB" 2>/dev/null
    wait "$JOB" 2>/dev/null
    local rc=$?

    local destroyed
    destroyed=$(grep -c "docker compose down" "$runlog")
    echo "case=$case_name rc=$rc remote_destroy_attempts=$destroyed"
    cat "$workdir/stdout.log" | sed 's/^/  stdout: /'
    rm -rf "$workdir"
    echo "$destroyed"
}

echo "### TEST 1: pre-existing remote deployment, SIGINT BEFORE ownership ###"
D1=$(run_case "pre-existing" | tee /tmp/_t1.out | tail -1)
grep -v "^[0-9]*$" /tmp/_t1.out
if [ "$D1" = "0" ]; then
    echo "PASS: remote destructive cleanup was NOT attempted (ownership correctly withheld)"
else
    echo "FAIL: remote destructive cleanup WAS attempted with no ownership -- blocker still present"
fi

echo ""
echo "### TEST 2: installer-owned remote deployment, SIGINT AFTER ownership ###"
D2=$(run_case "owned" | tee /tmp/_t2.out | tail -1)
grep -v "^[0-9]*$" /tmp/_t2.out
if [ "$D2" = "1" ]; then
    echo "PASS: rollback WAS attempted for genuinely owned state"
else
    echo "FAIL: rollback was NOT attempted even though ownership was genuinely acquired"
fi

rm -f "$EXTRACTED" /tmp/_t1.out /tmp/_t2.out
echo "=== DONE ==="
