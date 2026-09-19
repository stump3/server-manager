#!/bin/bash
# lib/sripts/tests/test_hy2_migrate_port_hopping_ufw.sh
#
# Lifecycle audit (HY2 migration / Port Hopping UFW): hysteria_migrate()
# (lib/hy2/menu.sh) copies the source's $HYSTERIA_CONFIG verbatim to the
# destination (PUT, before the UFW block runs), then used to open the
# destination firewall with `hy_get_port()`'s value for BOTH udp and tcp.
# For a Port Hopping config (`listen: ADDR:START-END`) hy_get_port()
# intentionally returns only START (the same value hysteria_install()
# itself treats as "the" port for URIs/user-add -- not a firewall-range
# source), so migration only ever opened START/udp+START/tcp on the new
# server -- leaving START+1..END closed and silently defeating Port
# Hopping post-migration. install.sh's own Port Hopping branch is the
# existing, authoritative precedent for what the firewall should look
# like: `ufw allow "${port_hop_start}:${port_hop_end}/udp"`, UDP-only,
# no TCP. Fixed by parsing the same local $HYSTERIA_CONFIG (still valid
# at that point -- PUT doesn't touch the local file, and nothing else
# modifies it before the UFW block runs) with the same regex shape
# hy_ufw_cleanup_service_port() (lib/hy2/install.sh) already uses, kept
# local to hysteria_migrate() rather than factored into a shared helper
# (one prior consumer doesn't justify a new cross-file abstraction for
# a minimal fix). hy_get_port() itself is untouched by this fix.
#
# Same conventions as this session's other new tests: bash -n, real
# source lines extracted verbatim (never hand-duplicated), and a mocked
# `ufw` so no real firewall state is touched.
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
for f in lib/hy2/menu.sh lib/hy2/install.sh lib/hy2/core.sh; do
    bash -n "$f" 2>/tmp/_hy2mig_synerr && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: bash -n $f"; cat /tmp/_hy2mig_synerr; }
done
rm -f /tmp/_hy2mig_synerr

echo ""
echo "== 1. hy_get_port() untouched by this fix (still the single/public-port accessor) =="
assert "hy_get_port() still returns START for Port Hopping (unchanged)" \
    "$( (HYSTERIA_CONFIG=$(mktemp); echo 'listen: 0.0.0.0:20000-29999' > "$HYSTERIA_CONFIG"; source lib/hy2/core.sh; hy_get_port; rm -f "$HYSTERIA_CONFIG") )" \
    "20000"

echo ""
echo "== 2. source inspection: migration's firewall block no longer references hy_get_port() =="
MIGRATE_BODY="$(awk '/^hysteria_migrate\(\) \{/,/^}$/' lib/hy2/menu.sh)"
assert "hysteria_migrate() body extracted (non-empty)" "$([ -n "$MIGRATE_BODY" ] && echo present || echo MISSING)" "present"
assert "hy_get_port is no longer CALLED in hysteria_migrate() (comments may still name it)" \
    "$(grep -Fc '$(hy_get_port)' <<<"$MIGRATE_BODY")" "0"

echo ""
echo "== 3. real fix logic (real source lines, extracted verbatim) in isolation, mocked ufw =="
FW_BLOCK="$(awk '/local _hy_listen _hy_rest hy_fw_rules/{f=1} f{print} f&&/^    fi$/{exit}' lib/hy2/menu.sh)"
assert "firewall-decision block actually extracted (non-empty)" "$([ -n "$FW_BLOCK" ] && echo present || echo MISSING)" "present"

run_migrate_fw() {
    # $1 = listen: line content (or empty for "no config" / malformed)
    (
        HYSTERIA_CONFIG="$(mktemp)"
        [ -n "$1" ] && printf '%s\n' "$1" > "$HYSTERIA_CONFIG" || : > "$HYSTERIA_CONFIG"
        eval "$FW_BLOCK"
        echo "$hy_fw_rules"
        rm -f "$HYSTERIA_CONFIG"
    )
}

echo "--- 3a. single-port IPv4 ---"
OUT=$(run_migrate_fw 'listen: 0.0.0.0:8443')
assert "single-port: udp rule present" "$(grep -c '^ufw allow 8443/udp ' <<<"$OUT")" "1"
assert "single-port: tcp rule present" "$(grep -c '^ufw allow 8443/tcp ' <<<"$OUT")" "1"
assert "single-port: exactly two rules" "$(grep -c '^ufw allow' <<<"$OUT")" "2"

echo "--- 3b. single-port IPv6 ---"
OUT=$(run_migrate_fw 'listen: [::]:8443')
assert "single-port IPv6: udp rule present" "$(grep -c '^ufw allow 8443/udp ' <<<"$OUT")" "1"
assert "single-port IPv6: tcp rule present" "$(grep -c '^ufw allow 8443/tcp ' <<<"$OUT")" "1"

echo "--- 3c. Port Hopping IPv4 range -- THE BUG THIS FIX CLOSES ---"
OUT=$(run_migrate_fw 'listen: 0.0.0.0:20000-29999')
assert "range: full range opened as a single UDP rule" \
    "$(grep -c '^ufw allow 20000:29999/udp ' <<<"$OUT")" "1"
assert "range: exactly one rule (no separate start-port rule)" "$(grep -c '^ufw allow' <<<"$OUT")" "1"
assert "range: no lone START/udp rule" "$(grep -c '^ufw allow 20000/udp' <<<"$OUT")" "0"
assert "range: no TCP rule at all" "$(grep -c '/tcp' <<<"$OUT")" "0"

echo "--- 3d. Port Hopping IPv6 range ---"
OUT=$(run_migrate_fw 'listen: [::]:20000-29999')
assert "IPv6 range: full range opened as a single UDP rule" \
    "$(grep -c '^ufw allow 20000:29999/udp ' <<<"$OUT")" "1"
assert "IPv6 range: no TCP rule" "$(grep -c '/tcp' <<<"$OUT")" "0"

echo "--- 3e. malformed/unsupported listen: syntax -> no rule at all, not a broad/wrong one ---"
OUT=$(run_migrate_fw 'listen: not-a-real-address')
assert "malformed: no ufw rule produced" "$([ -z "$OUT" ] && echo empty || echo "$OUT")" "empty"

echo "--- 3f. no listen: line / empty config -> no rule, no crash ---"
OUT=$(run_migrate_fw '')
assert "no config line: no ufw rule produced" "$([ -z "$OUT" ] && echo empty || echo "$OUT")" "empty"

echo ""
echo "== 4. negative control: OLD implementation (hy_get_port()-based) would have failed these =="
run_migrate_fw_OLD() {
    (
        HYSTERIA_CONFIG="$(mktemp)"
        [ -n "$1" ] && printf '%s\n' "$1" > "$HYSTERIA_CONFIG"
        source lib/hy2/core.sh
        hy_port=$(hy_get_port)
        echo "ufw allow ${hy_port}/udp"
        echo "ufw allow ${hy_port}/tcp"
        rm -f "$HYSTERIA_CONFIG"
    )
}
OLD_OUT=$(run_migrate_fw_OLD 'listen: 0.0.0.0:20000-29999')
assert "OLD behavior on range: only START opened (proves the bug was real)" \
    "$(grep -c '^ufw allow 20000/udp$' <<<"$OLD_OUT")" "1"
assert "OLD behavior on range: full range NEVER appears (this is what made it a bug)" \
    "$(grep -c '20000:29999' <<<"$OLD_OUT")" "0"
assert "OLD behavior on range: TCP wrongly opened too" \
    "$(grep -c '^ufw allow 20000/tcp$' <<<"$OLD_OUT")" "1"

echo ""
echo "==================================="
echo "PASS=$PASS FAIL=$FAIL"
echo "==================================="
[ "$FAIL" -eq 0 ]
