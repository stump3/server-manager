#!/bin/bash
# lib/sripts/tests/test_hy2_ufw_lifecycle.sh
#
# Lifecycle audit (Step H, TeleMT/HY2), two related findings in
# lib/hy2/:
#
# 1. hy_get_port() (lib/hy2/core.sh) — hysteria_install() writes Port
#    Hopping's listen line as `listen: 0.0.0.0:START-END` (a bare
#    hyphen right after the start port; confirmed by reading its own
#    `listen_addr=` assignment, and confirmed no other producer in this
#    codebase ever writes a different form). hy_get_port()'s old regex
#    only recognized a COMMA-delimited suffix that no producer ever
#    emits, so on a real Port Hopping config the pattern failed to
#    match at all (confirmed directly with sed) and the function
#    returned empty -- silently breaking every real caller that needs
#    an actual port number from it: share-URI generation
#    (lib/hy2/users.sh), subscription publishing and the migration
#    UFW-reopen step (lib/hy2/menu.sh), lib/hy2/integration.sh. Fixed
#    to match the hyphen form; the captured port is the range's START,
#    the same value install.sh's own `port="$port_hop_start"` (its own
#    comment: "Основной порт — первый в диапазоне") already treats as
#    *the* port for Port Hopping elsewhere in this same file.
#
# 2. hysteria_uninstall() (lib/hy2/install.sh) removed the binary,
#    config and systemd unit but never the UFW rule(s) opened for
#    Hysteria's own port by hysteria_install()/hysteria_menu.sh --
#    confirmed by grepping this file and lib/hy2/menu.sh for every
#    `ufw allow`/`ufw delete`: zero deletes existed for either the
#    single-port or Port-Hopping-range form, anywhere. The firewall
#    stayed permanently open after a "complete" removal, contrary to
#    this function's own promise (only certs/URI files are disclosed
#    as being kept). Fixed by reading the listen: line directly before
#    the config is deleted, and deleting the exact rule(s)
#    hysteria_install() would have opened for either form. SSH(22)/
#    HTTP(80), opened by that same install step, are deliberately left
#    alone (shared/OS-owned, not Hysteria's own) -- this test asserts
#    that too.
#
# Same conventions as this session's other new tests: bash -n, source
# inspection, and the real UFW-cleanup block from hysteria_uninstall()
# extracted verbatim via awk (same technique as
# test_adapter_colocated_node_host_lookup.sh /
# test_adapter_xhttp_host_lookup_shape.sh) and exercised in isolation
# against a mocked `ufw` -- hysteria_uninstall() itself starts with an
# interactive `read ... < /dev/tty` confirmation gate that this sandbox
# has no usable controlling terminal for (confirmed before writing this
# test), so the real, unmodified block is tested directly rather than
# routed through that prompt.
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
for f in lib/hy2/core.sh lib/hy2/install.sh; do
    bash -n "$f" 2>/tmp/_hy2_synerr && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: bash -n $f"; cat /tmp/_hy2_synerr; }
done
rm -f /tmp/_hy2_synerr

echo ""
echo "== 1. hy_get_port(): real function, real regex, every real listen: form this codebase produces =="
run_get_port() {
    (
        HYSTERIA_CONFIG="$(mktemp)"
        printf '%s\n' "$1" > "$HYSTERIA_CONFIG"
        # shellcheck source=/dev/null
        source lib/hy2/core.sh
        hy_get_port
        rm -f "$HYSTERIA_CONFIG"
    )
}
assert "single-port IPv4 (listen: 0.0.0.0:8443)" "$(run_get_port 'listen: 0.0.0.0:8443')" "8443"
assert "single-port IPv6 (listen: [::]:8443)" "$(run_get_port 'listen: [::]:8443')" "8443"
assert "Port Hopping IPv4 range (listen: 0.0.0.0:20000-29999) -- THE BUG THIS FIX CLOSES" \
    "$(run_get_port 'listen: 0.0.0.0:20000-29999')" "20000"
assert "Port Hopping IPv6 range (listen: [::]:20000-29999)" \
    "$(run_get_port 'listen: [::]:20000-29999')" "20000"
assert "no config file at all -> empty, non-fatal" \
    "$(HYSTERIA_CONFIG=/nonexistent/path/config.yaml bash -c 'source lib/hy2/core.sh; hy_get_port')" ""

echo ""
echo "== 2. source inspection: UFW cleanup present in hysteria_uninstall(), before the config file is deleted =="
UFW_LINE=$(grep -n "_hy_listen=\$(grep -m1" lib/hy2/install.sh | head -1 | cut -d: -f1)
RM_CONFIG_LINE=$(grep -n 'rm -f "\${HYSTERIA_CONFIG:-/etc/hysteria/config.yaml}"' lib/hy2/install.sh | head -1 | cut -d: -f1)
assert "UFW cleanup reads listen: line before config removal" \
    "$([ "$UFW_LINE" -lt "$RM_CONFIG_LINE" ] && echo yes || echo no)" "yes"
assert "UFW cleanup block appears exactly once" \
    "$(grep -c '_hy_listen=\$(grep -m1' lib/hy2/install.sh)" "1"

echo ""
echo "== 3. UFW cleanup block (real code, extracted verbatim) in isolation, mocked ufw =="
UNINSTALL_BODY_RAW="$(awk '/^hysteria_uninstall\(\) \{/,/^\}$/' lib/hy2/install.sh)"
UFW_BLOCK="$(awk '/if command -v ufw &>\/dev\/null; then/{f=1} f{print} f&&/^    fi$/{exit}' <<<"$UNINSTALL_BODY_RAW")"
assert "UFW cleanup block actually extracted (non-empty)" "$([ -n "$UFW_BLOCK" ] && echo present || echo MISSING)" "present"

run_ufw_cleanup() {
    # $1 = listen: line content (or empty for "no config")
    local log; log=$(mktemp)
    (
        ufw() { echo "ufw:$*" >> "$log"; return 0; }
        HYSTERIA_CONFIG="$(mktemp)"
        [ -n "$1" ] && printf '%s\n' "$1" > "$HYSTERIA_CONFIG" || rm -f "$HYSTERIA_CONFIG"
        eval "$UFW_BLOCK"
        rm -f "$HYSTERIA_CONFIG"
    )
    cat "$log"; rm -f "$log"
}

echo "--- 3a. single-port config ---"
OUT=$(run_ufw_cleanup 'listen: 0.0.0.0:8443')
assert "single-port: udp rule deleted" "$(grep -c '^ufw:delete allow 8443/udp$' <<<"$OUT")" "1"
assert "single-port: tcp rule deleted" "$(grep -c '^ufw:delete allow 8443/tcp$' <<<"$OUT")" "1"
assert "single-port: SSH(22) never touched" "$(grep -c '22' <<<"$OUT")" "0"
assert "single-port: HTTP(80) never touched" "$(grep -c '80/tcp' <<<"$OUT")" "0"

echo "--- 3b. Port Hopping range config -- THE BUG THIS FIX CLOSES ---"
OUT=$(run_ufw_cleanup 'listen: 0.0.0.0:20000-29999')
assert "range: exactly one ufw call" "$(grep -c '^ufw:' <<<"$OUT")" "1"
assert "range: full range deleted as a single UDP rule" \
    "$(grep -c '^ufw:delete allow 20000:29999/udp$' <<<"$OUT")" "1"

echo "--- 3c. IPv6 Port Hopping range ---"
OUT=$(run_ufw_cleanup 'listen: [::]:20000-29999')
assert "IPv6 range: full range deleted" "$(grep -c '^ufw:delete allow 20000:29999/udp$' <<<"$OUT")" "1"

echo "--- 3d. config already gone (e.g. re-run of uninstall) -- no crash, no bogus ufw calls ---"
OUT=$(run_ufw_cleanup '')
assert "missing config: no ufw calls at all" "$(grep -c '^ufw:' <<<"$OUT")" "0"

echo ""
echo "== 4. hysteria_uninstall()'s own disclosure stays accurate: still names only certs/URI files as kept =="
UNINSTALL_BODY="$(awk '/^hysteria_uninstall\(\) \{/,/^\}$/' lib/hy2/install.sh)"
assert "hysteria_uninstall() defined exactly once" \
    "$(grep -c '^hysteria_uninstall() {' lib/hy2/install.sh)" "1"
assert "disclosure text unchanged (certs/URI files kept)" \
    "$(grep -c 'Сертификаты .*URI-файлы сохранятся' <<<"$UNINSTALL_BODY")" "1"

echo ""
echo "== 5. call-site precondition: hysteria_uninstall() still reachable from exactly its known menu entry =="
assert "hysteria_submenu_manage() still calls hysteria_uninstall" \
    "$(grep -c 'hysteria_uninstall ||' lib/hy2/menu.sh)" "1"

echo ""
echo "==================================="
echo "PASS=$PASS FAIL=$FAIL"
echo "==================================="
[ "$FAIL" -eq 0 ]
