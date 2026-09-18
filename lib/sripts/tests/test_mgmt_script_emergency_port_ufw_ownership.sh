#!/bin/bash
# lib/sripts/tests/test_mgmt_script_emergency_port_ufw_ownership.sh
#
# UFW lifecycle audit (Step C, this session): lib/panel/mgmt_script.sh
# generates a standalone /usr/local/bin/remnawave_panel script whose
# do_open_port()/do_close_port() (MODE=1/2 emergency admin access)
# used a bare `ufw allow 8443/tcp` / `ufw delete allow 8443/tcp` pair
# -- no comment, no ownership check.
#
# Confirmed live against a real ufw (built in this sandbox):
#   1. `ufw delete allow 8443/tcp` removes ANY existing rule on that
#      port, comment or no comment -- delete-by-spec does not consider
#      the comment at all.
#   2. 8443 is not exclusive to this function: it is Hysteria2's own
#      documented recommended default port (lib/hy2/install.sh: "1)
#      8443 — рекомендуется", opened bare/uncommented), and it is
#      Variant J's default public XHTTP port (opened with comment
#      "Variant J XHTTP").
#   3. panel_remove() never deletes the generated
#      /usr/local/bin/remnawave_panel script, so a script generated
#      under an earlier MODE=1/2 install can still exist -- with its
#      MODE=1/2 baked in, bypassing the "not supported for Variant
#      F/J" guard -- after a later reinstall to F/J.
#   4. Naively tagging just the *delete* side with an ownership
#      comment is not sufficient by itself: `ufw allow PORT/PROTO
#      comment "X"` does not add a second rule when a rule with that
#      exact spec already exists under a different comment (or none)
#      -- it silently *relabels* the existing rule ("Rule updated"),
#      confirmed live. So do_open_port() itself needed a pre-check,
#      not just do_close_port().
#
# Together these give two real, reachable collisions (verified live,
# not just reasoned about): (a) do_open_port()/do_close_port() used
# for their intended MODE=1/2 purpose on a box that also runs
# Hysteria2 on its own recommended default port, and (b) a stale
# MODE=1/2 generated script surviving a reinstall to Variant J,
# whose do_close_port() could delete a live "Variant J XHTTP" rule.
#
# Fix: do_open_port() now checks (read-only `ufw status numbered`)
# for any existing 8443/tcp rule not already tagged as its own before
# doing anything (no nginx.conf edit, no `ufw allow`) -- refusing
# instead of relabeling. Its own rule is tagged "Panel emergency
# admin"; do_close_port() deletes only rules matching that exact
# comment on 8443/tcp, via the same `ufw status numbered` + delete-
# by-number technique already proven for
# panel_cleanup_xhttp_ufw_rules()/panel_cleanup_colocated_api_ufw_rule()
# in lib/panel/management.sh (inlined here, not called, since this is
# a standalone generated script with no access to that sourced
# helper -- confirmed by reading how lib/panel/mgmt_script.sh's
# heredoc is quoted).
#
# Both full scenarios (foreign rule present -> refuse; no collision ->
# open+close round-trips cleanly; stale rule present -> close leaves
# it alone) were verified directly against a real, live ufw daemon in
# this sandbox before this test was written. This test itself uses a
# mocked `ufw` (matching this suite's established convention) so it
# runs anywhere without needing a real firewall.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$REPO_ROOT"

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

echo "== 0. bash -n =="
bash -n lib/panel/mgmt_script.sh 2>/tmp/_mgmt_synerr && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: bash -n lib/panel/mgmt_script.sh"; cat /tmp/_mgmt_synerr; }
rm -f /tmp/_mgmt_synerr

echo ""
echo "== 1. source inspection =="
assert "do_open_port() checks for a foreign 8443/tcp rule before any mutation" \
    "$(awk '/^do_open_port\(\) \{/,/^\}$/' lib/panel/mgmt_script.sh | grep -c "grep -F '8443/tcp'")" "1"
OPEN_CHECK_LINE=$(grep -n "_existing_8443=" lib/panel/mgmt_script.sh | head -1 | cut -d: -f1)
OPEN_SED_LINE=$(grep -n 'sed -i "/server_name \$pd;/a' lib/panel/mgmt_script.sh | head -1 | cut -d: -f1)
OPEN_ALLOW_LINE=$(grep -n 'ufw allow 8443/tcp comment "Panel emergency admin"' lib/panel/mgmt_script.sh | head -1 | cut -d: -f1)
assert "the pre-check runs before nginx.conf is ever touched" \
    "$([ "$OPEN_CHECK_LINE" -lt "$OPEN_SED_LINE" ] && echo yes || echo no)" "yes"
assert "the pre-check runs before ufw allow" \
    "$([ "$OPEN_CHECK_LINE" -lt "$OPEN_ALLOW_LINE" ] && echo yes || echo no)" "yes"
assert "do_close_port() deletes by comment-scoped rule number, not a bare port spec" \
    "$(awk '/^do_close_port\(\) \{/,/^\}$/' lib/panel/mgmt_script.sh | grep -c 'Panel emergency admin')" "1"
assert "do_close_port() no longer contains the old bare delete" \
    "$(awk '/^do_close_port\(\) \{/,/^\}$/' lib/panel/mgmt_script.sh | grep -c '^    ufw delete allow 8443/tcp>')" "0"

echo ""
echo "== 2. do_open_port(): mocked ufw, foreign rule present -> must refuse without touching nginx.conf or calling ufw allow =="
OPEN_BLOCK="$(awk '/^do_open_port\(\) \{/,/^\}$/' lib/panel/mgmt_script.sh)"
CLOSE_BLOCK="$(awk '/^do_close_port\(\) \{/,/^\}$/' lib/panel/mgmt_script.sh)"

run_open_port_direct() {
    # $1 = ufw status numbered output to simulate; $2 = scratch dir for nginx.conf
    local log; log=$(mktemp)
    (
        _warn() { echo "WARN:$*" >> "$log"; }
        _info() { echo "INFO:$*" >> "$log"; }
        _ok() { echo "OK:$*" >> "$log"; }
        _detect_ws() { echo "nginx"; }
        docker() { echo "docker:$*" >> "$log"; }
        cd() { command cd "$@" 2>/dev/null || true; }
        ufw() {
            echo "ufw:$*" >> "$log"
            if [ "$1" = "status" ]; then printf '%s\n' "$UFW_STATUS"; fi
            return 0
        }
        ss() { echo ""; }
        sed() {
            echo "sed_called:$*" >> "$log"
            command sed "$@"
        }
        MODE="1"
        UFW_STATUS="$1"
        WHITE=""; NC=""
        mkdir -p "$2"
        printf 'server {\n    server_name test.example.com;\n}\n' > "$2/nginx.conf"
        eval "$(printf '%s' "$OPEN_BLOCK" | command sed "s#/opt/remnawave#$2#g")"
        do_open_port
        echo "RC=$?" >> "$log"
    )
    cat "$log"; rm -f "$log"
}

SCRATCH1=$(mktemp -d)
echo "--- 2a. foreign, uncommented rule already on 8443/tcp (Hysteria2's own default) ---"
OUT=$(run_open_port_direct '[ 1] 8443/tcp                   ALLOW IN    Anywhere' "$SCRATCH1")
assert "foreign rule: refuses (RC=1)" "$(grep -c '^RC=1$' <<<"$OUT")" "1"
assert "foreign rule: ufw allow is NEVER called" "$(grep -c '^ufw:allow' <<<"$OUT")" "0"
assert "foreign rule: nginx.conf is never touched (no sed -i call)" "$(grep -c '^sed_called:-i ' <<<"$OUT")" "0"
assert "foreign rule: warning shown" "$(grep -c '^WARN:Порт 8443/tcp уже используется' <<<"$OUT")" "1"
rm -rf "$SCRATCH1"

SCRATCH2=$(mktemp -d)
echo "--- 2b. foreign, comment-tagged rule already on 8443/tcp (a live Variant J XHTTP rule) ---"
OUT=$(run_open_port_direct '[ 1] 8443/tcp                   ALLOW IN    Anywhere                   # Variant J XHTTP' "$SCRATCH2")
assert "XHTTP-J collision: refuses (RC=1)" "$(grep -c '^RC=1$' <<<"$OUT")" "1"
assert "XHTTP-J collision: ufw allow is NEVER called (no relabeling)" "$(grep -c '^ufw:allow' <<<"$OUT")" "0"
rm -rf "$SCRATCH2"

SCRATCH3=$(mktemp -d)
echo "--- 2c. no existing 8443/tcp rule -- normal path proceeds ---"
OUT=$(run_open_port_direct '' "$SCRATCH3")
assert "no collision: proceeds (RC=0)" "$(grep -c '^RC=0$' <<<"$OUT")" "1"
assert "no collision: ufw allow called with the ownership comment" \
    "$(grep -c '^ufw:allow 8443/tcp comment Panel emergency admin$' <<<"$OUT")" "1"
rm -rf "$SCRATCH3"

SCRATCH4=$(mktemp -d)
echo "--- 2d. already our own rule (idempotent re-run of open_port) -- proceeds, does not treat itself as foreign ---"
OUT=$(run_open_port_direct '[ 1] 8443/tcp                   ALLOW IN    Anywhere                   # Panel emergency admin' "$SCRATCH4")
assert "already-ours: proceeds rather than refusing" "$(grep -c '^RC=0$' <<<"$OUT")" "1"
rm -rf "$SCRATCH4"

echo ""
echo "== 3. do_close_port(): mocked ufw, comment-scoped delete-by-number =="
run_close_port() {
    # $1 = ufw status numbered output to simulate
    local log; log=$(mktemp)
    local scratch; scratch=$(mktemp -d)
    printf 'server {\n    server_name test.example.com;\n}\n' > "$scratch/nginx.conf"
    (
        _warn() { echo "WARN:$*" >> "$log"; }
        _ok() { echo "OK:$*" >> "$log"; }
        _detect_ws() { echo "nginx"; }
        docker() { echo "docker:$*" >> "$log"; }
        cd() { command cd "$@" 2>/dev/null || true; }
        ufw() {
            echo "ufw:$*" >> "$log"
            if [ "$1" = "status" ]; then printf '%s\n' "$UFW_STATUS"; fi
            return 0
        }
        MODE="1"
        UFW_STATUS="$1"
        WHITE=""; NC=""
        eval "$(printf '%s' "$CLOSE_BLOCK" | command sed "s#/opt/remnawave#$scratch#g")"
        do_close_port
        echo "RC=$?" >> "$log"
    )
    cat "$log"; rm -f "$log"; rm -rf "$scratch"
}

echo "--- 3a. only our own rule present -> deleted ---"
OUT=$(run_close_port '[ 1] 8443/tcp                   ALLOW IN    Anywhere                   # Panel emergency admin')
assert "own rule: deleted by number" "$(grep -c '^ufw:--force delete 1$' <<<"$OUT")" "1"
assert "own rule: RC=0" "$(grep -c '^RC=0$' <<<"$OUT")" "1"

echo "--- 3b. a live Variant J XHTTP rule present, nothing of ours -> survives untouched (THE COLLISION THIS FIX CLOSES) ---"
OUT=$(run_close_port '[ 1] 8443/tcp                   ALLOW IN    Anywhere                   # Variant J XHTTP')
assert "XHTTP-J rule: never deleted" "$(grep -c '^ufw:--force delete' <<<"$OUT")" "0"

echo "--- 3c. HY2's bare, uncommented rule present, nothing of ours -> survives untouched ---"
OUT=$(run_close_port '[ 1] 8443/tcp                   ALLOW IN    Anywhere')
assert "HY2 bare rule: never deleted" "$(grep -c '^ufw:--force delete' <<<"$OUT")" "0"

echo "--- 3d. our own rule AND an unrelated rule both present -- only ours is deleted ---"
OUT=$(run_close_port '[ 1] 8443/udp                   ALLOW IN    Anywhere                   # unrelated
[ 2] 8443/tcp                   ALLOW IN    Anywhere                   # Panel emergency admin')
assert "mixed: exactly one delete, rule 2 (ours)" "$(grep -c '^ufw:--force delete 2$' <<<"$OUT")" "1"
assert "mixed: rule 1 (unrelated) never referenced in a delete" "$(grep -c '^ufw:--force delete 1$' <<<"$OUT")" "0"

echo ""
echo "== 4. call-site precondition: do_open_port/do_close_port still reachable from the same known dispatcher =="
assert "do_open_port dispatched exactly once" "$(grep -c 'open_port)   do_open_port' lib/panel/mgmt_script.sh)" "1"
assert "do_close_port dispatched exactly once" "$(grep -c 'close_port)  do_close_port' lib/panel/mgmt_script.sh)" "1"

echo ""
echo "==================================="
echo "PASS=$PASS FAIL=$FAIL"
echo "==================================="
[ "$FAIL" -eq 0 ]
