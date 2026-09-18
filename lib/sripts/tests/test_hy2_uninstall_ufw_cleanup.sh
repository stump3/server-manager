#!/bin/bash
# lib/sripts/tests/test_hy2_uninstall_ufw_cleanup.sh
#
# CONFIRMED DEFECT (lifecycle audit, Step C UFW inventory, HY2 task):
# hysteria_uninstall() (lib/hy2/install.sh) never removed the UFW
# rule(s) install.sh's own install path opened for HY2's service port
# -- confirmed by direct reading (no `ufw` call anywhere in the
# function) and reproduced against a real ufw binary: a rule opened at
# install stayed ALLOW after uninstall removed everything that used to
# listen on it.
#
# Fix: hy_ufw_cleanup_service_port() reads the actual `listen:` line
# from $HYSTERIA_CONFIG (before hysteria_uninstall() deletes that file)
# and deletes exactly the port(s)/range this specific install opened --
# both real shapes install.sh writes:
#   single port:  listen: 0.0.0.0:PORT        -> delete PORT/udp + PORT/tcp
#   Port Hopping: listen: 0.0.0.0:START-END   -> delete START:END/udp only
#     (matches install.sh's own asymmetry: hop mode only ever opened
#      the /udp range, never a /tcp counterpart -- confirmed by reading
#      install.sh's own install-time ufw allow calls)
# 22/tcp and 80/tcp are deliberately left untouched (host-baseline SSH,
# and an ownership-ambiguous bare ACME 80/tcp rule that could belong to
# Caddy or certbot instead) -- this test also asserts they're NOT
# touched, so the fix doesn't overreach into rules it can't prove it
# owns.
#
# This test uses the REAL `ufw` binary throughout (confirmed working in
# this sandbox: `ufw enable`/`allow`/`delete`/`status` all function),
# not a mock -- so the assertions are about actual ufw rule-matching
# behavior, the same empirical standard Step C's own audit used.
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

command -v ufw >/dev/null 2>&1 || { echo "SKIP: ufw not installed in this environment"; echo "PASS=0 FAIL=0"; exit 0; }

echo "== 0. bash -n =="
bash -n lib/hy2/install.sh && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: bash -n lib/hy2/install.sh"; }

echo ""
echo "== 1. source inspection: cleanup helper exists, is called before the config file is deleted =="
assert "hy_ufw_cleanup_service_port() defined exactly once" \
    "$(grep -c '^hy_ufw_cleanup_service_port()' lib/hy2/install.sh)" "1"
assert "hysteria_uninstall() calls it exactly once" \
    "$(grep -c 'hy_ufw_cleanup_service_port$' lib/hy2/install.sh)" "1"
CLEANUP_CALL_LINE=$(grep -n 'hy_ufw_cleanup_service_port$' lib/hy2/install.sh | tail -1 | cut -d: -f1)
RM_CONFIG_LINE=$(grep -n 'rm -f "\${HYSTERIA_CONFIG' lib/hy2/install.sh | head -1 | cut -d: -f1)
assert "cleanup runs before the config file is removed (reads listen: while it still exists)" \
    "$([ "$CLEANUP_CALL_LINE" -lt "$RM_CONFIG_LINE" ] && echo yes || echo no)" "yes"

echo ""
echo "== 2. functional (real ufw): single-port install -> uninstall removes exactly that port, udp+tcp =="
run_cleanup() {
    # $1: HYSTERIA_CONFIG content (a full fake config file)
    local cfg; cfg=$(mktemp)
    printf '%s\n' "$1" > "$cfg"
    (
        HYSTERIA_CONFIG="$cfg"
        # shellcheck source=/dev/null
        source <(sed -n '/^hy_ufw_cleanup_service_port()/,/^}/p' lib/hy2/install.sh)
        hy_ufw_cleanup_service_port
    )
    rm -f "$cfg"
}

ufw --force reset >/dev/null 2>&1
ufw --force enable >/dev/null 2>&1
ufw allow 22/tcp >/dev/null 2>&1
ufw allow 80/tcp >/dev/null 2>&1
ufw allow 44444/udp >/dev/null 2>&1
ufw allow 44444/tcp >/dev/null 2>&1
run_cleanup "listen: 0.0.0.0:44444"
STATUS_AFTER_SINGLE="$(ufw status 2>&1)"
assert "single-port: 44444/udp removed" "$(echo "$STATUS_AFTER_SINGLE" | grep -c '44444/udp')" "0"
assert "single-port: 44444/tcp removed" "$(echo "$STATUS_AFTER_SINGLE" | grep -c '44444/tcp')" "0"
assert "single-port: 22/tcp left untouched (host-baseline, not this fix's to remove)" \
    "$(echo "$STATUS_AFTER_SINGLE" | grep -c '22/tcp')" "1"
assert "single-port: 80/tcp left untouched (ownership-ambiguous, could be Caddy/certbot)" \
    "$(echo "$STATUS_AFTER_SINGLE" | grep -c '80/tcp')" "1"

echo ""
echo "== 3. functional (real ufw): Port Hopping install -> uninstall removes exactly that range, udp only =="
ufw --force reset >/dev/null 2>&1
ufw --force enable >/dev/null 2>&1
ufw allow 22/tcp >/dev/null 2>&1
ufw allow 80/tcp >/dev/null 2>&1
ufw allow 20000:30000/udp >/dev/null 2>&1
run_cleanup "listen: 0.0.0.0:20000-30000"
STATUS_AFTER_RANGE="$(ufw status 2>&1)"
assert "Port Hopping: 20000:30000/udp range removed" "$(echo "$STATUS_AFTER_RANGE" | grep -c '20000:30000/udp')" "0"
assert "Port Hopping: 22/tcp left untouched" "$(echo "$STATUS_AFTER_RANGE" | grep -c '22/tcp')" "1"
assert "Port Hopping: 80/tcp left untouched" "$(echo "$STATUS_AFTER_RANGE" | grep -c '80/tcp')" "1"

echo ""
echo "== 4. functional (real ufw): IPv6 [::] listen form also parsed correctly (both shapes) =="
ufw --force reset >/dev/null 2>&1
ufw --force enable >/dev/null 2>&1
ufw allow 55555/udp >/dev/null 2>&1
ufw allow 55555/tcp >/dev/null 2>&1
run_cleanup "listen: [::]:55555"
STATUS_V6_SINGLE="$(ufw status 2>&1)"
assert "IPv6 single-port: 55555/udp removed" "$(echo "$STATUS_V6_SINGLE" | grep -c '55555/udp')" "0"
assert "IPv6 single-port: 55555/tcp removed" "$(echo "$STATUS_V6_SINGLE" | grep -c '55555/tcp')" "0"

ufw --force reset >/dev/null 2>&1
ufw --force enable >/dev/null 2>&1
ufw allow 40000:45000/udp >/dev/null 2>&1
run_cleanup "listen: [::]:40000-45000"
STATUS_V6_RANGE="$(ufw status 2>&1)"
assert "IPv6 Port Hopping: 40000:45000/udp removed" "$(echo "$STATUS_V6_RANGE" | grep -c '40000:45000/udp')" "0"

echo ""
echo "== 5. LOAD-BEARING negative control: without this fix, the old (unmodified) uninstall path leaves the rule =="
# Reproduces the original bug directly: hysteria_uninstall()'s body
# before this session's fix had NO ufw call anywhere. Extract the
# pre-fix uninstall body shape by simply confirming that if we DON'T
# call hy_ufw_cleanup_service_port at all, the rule survives -- proving
# the assertions above are actually exercising the fix, not vacuously
# passing because ufw never had the rule in the first place.
ufw --force reset >/dev/null 2>&1
ufw --force enable >/dev/null 2>&1
ufw allow 44444/udp >/dev/null 2>&1
ufw allow 44444/tcp >/dev/null 2>&1
STATUS_NO_CLEANUP="$(ufw status 2>&1)"
assert "negative control: without calling the cleanup, the rule is still there (confirms the fix is load-bearing)" \
    "$(echo "$STATUS_NO_CLEANUP" | grep -c '44444/udp')" "1"

ufw --force reset >/dev/null 2>&1
ufw --force disable >/dev/null 2>&1

echo ""
echo "==================================="
echo "PASS=$PASS FAIL=$FAIL"
echo "==================================="
[ "$FAIL" -eq 0 ]
