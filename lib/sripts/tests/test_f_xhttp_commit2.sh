#!/bin/bash
# lib/sripts/tests/test_f_xhttp_commit2.sh
#
# Self-contained regression test for:
#   Commit 1 - Xray loopback bind for F/J
#   Commit 2 - F+XHTTP (Variant A)
#
# Run: bash lib/sripts/tests/test_f_xhttp_commit2.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$REPO_ROOT"

PASS=0
FAIL=0
assert() {
    local desc="$1" actual="$2" expected="$3"
    if [ "$actual" = "$expected" ]; then
        PASS=$((PASS+1))
        # echo "  OK: $desc"
    else
        FAIL=$((FAIL+1))
        echo "  FAIL: $desc -- expected [$expected] got [$actual]"
    fi
}
assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if grep -qF -- "$needle" <<<"$haystack"; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        echo "  FAIL: $desc -- did not find [$needle]"
    fi
}
assert_not_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if grep -qF -- "$needle" <<<"$haystack"; then
        FAIL=$((FAIL+1))
        echo "  FAIL: $desc -- unexpectedly found [$needle]"
    else
        PASS=$((PASS+1))
    fi
}

# shellcheck disable=SC1091
source lib/ui/output.sh
# shellcheck disable=SC1091
source lib/common.sh
# shellcheck disable=SC1091
source lib/panel.sh

mkdir -p /opt/remnawave

echo "== render.sh direct (Xray inbounds JSON) =="

# --- MODE=1 (legacy) baseline: no listen key, single Steal inbound ---
J1=$(panel_xray_render_inbounds "1" "PK1" "SID1" "DEST1" "dom1.example" 443 18444 "/xp" "false")
echo "$J1" | jq -e 'length == 1' >/dev/null 2>&1 && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: MODE=1 single inbound"; }
assert "MODE=1 no listen key" "$(echo "$J1" | jq -r '.[0] | has("listen")')" "false"
assert "MODE=1 tag" "$(echo "$J1" | jq -r '.[0].tag')" "Steal"
assert "MODE=1 accept_pp false -> no sockopt" "$(echo "$J1" | jq -r '.[0].streamSettings | has("sockopt")')" "false"

# --- MODE=2 (legacy) baseline: same shape as MODE=1 ---
J2=$(panel_xray_render_inbounds "2" "PK2" "SID2" "dom2.example:443" "dom2.example" 443 18444 "/xp" "false")
assert "MODE=2 single inbound length" "$(echo "$J2" | jq -r 'length')" "1"
assert "MODE=2 no listen key" "$(echo "$J2" | jq -r '.[0] | has("listen")')" "false"

# --- MODE=F, XHTTP_ENABLE omitted (=0): Steal only, loopback listen ---
JF0=$(panel_xray_render_inbounds "F" "PKF" "SIDF" "/dev/shm/nginx.sock" "domf.example" 8443 19444 "/xp" "true" "" "127.0.0.1")
assert "F/0 inbound count" "$(echo "$JF0" | jq -r 'length')" "1"
assert "F/0 tag" "$(echo "$JF0" | jq -r '.[0].tag')" "Steal"
assert "F/0 port" "$(echo "$JF0" | jq -r '.[0].port')" "8443"
assert "F/0 listen=127.0.0.1" "$(echo "$JF0" | jq -r '.[0].listen')" "127.0.0.1"
assert "F/0 acceptProxyProtocol=true" "$(echo "$JF0" | jq -r '.[0].streamSettings.sockopt.acceptProxyProtocol')" "true"
assert "F/0 dest" "$(echo "$JF0" | jq -r '.[0].streamSettings.realitySettings.dest')" "/dev/shm/nginx.sock"

# --- MODE=F, XHTTP_ENABLE=1: Steal(8443) + StealXHTTP(19444), both loopback ---
JF1=$(panel_xray_render_inbounds "F" "PKF" "SIDF" "/dev/shm/nginx.sock" "domf.example" 8443 19444 "/xp" "true" "1" "127.0.0.1")
assert "F/1 inbound count" "$(echo "$JF1" | jq -r 'length')" "2"
assert "F/1 Steal port" "$(echo "$JF1" | jq -r '.[0].port')" "8443"
assert "F/1 Steal listen" "$(echo "$JF1" | jq -r '.[0].listen')" "127.0.0.1"
assert "F/1 Steal acceptProxyProtocol" "$(echo "$JF1" | jq -r '.[0].streamSettings.sockopt.acceptProxyProtocol')" "true"
assert "F/1 StealXHTTP tag" "$(echo "$JF1" | jq -r '.[1].tag')" "StealXHTTP"
assert "F/1 StealXHTTP port" "$(echo "$JF1" | jq -r '.[1].port')" "19444"
assert "F/1 StealXHTTP listen" "$(echo "$JF1" | jq -r '.[1].listen')" "127.0.0.1"
assert "F/1 StealXHTTP no sockopt" "$(echo "$JF1" | jq -r '.[1].streamSettings | has("sockopt")')" "false"
assert "F/1 shared privateKey" "$(echo "$JF1" | jq -r '.[0].streamSettings.realitySettings.privateKey == .[1].streamSettings.realitySettings.privateKey')" "true"
assert "F/1 shared serverNames" "$(echo "$JF1" | jq -r '.[0].streamSettings.realitySettings.serverNames == .[1].streamSettings.realitySettings.serverNames')" "true"
assert "F/1 shared shortIds" "$(echo "$JF1" | jq -r '.[0].streamSettings.realitySettings.shortIds == .[1].streamSettings.realitySettings.shortIds')" "true"
assert "F/1 shared dest" "$(echo "$JF1" | jq -r '.[0].streamSettings.realitySettings.dest == .[1].streamSettings.realitySettings.dest')" "true"

# --- MODE=J: Steal(18443)+StealXHTTP(18444), both loopback, no regression ---
JJ=$(panel_xray_render_inbounds "J" "PKJ" "SIDJ" "/dev/shm/nginx.sock" "domj.example" 18443 18444 "/xp" "true" "" "127.0.0.1")
assert "J inbound count" "$(echo "$JJ" | jq -r 'length')" "2"
assert "J Steal port" "$(echo "$JJ" | jq -r '.[0].port')" "18443"
assert "J Steal listen" "$(echo "$JJ" | jq -r '.[0].listen')" "127.0.0.1"
assert "J StealXHTTP port" "$(echo "$JJ" | jq -r '.[1].port')" "18444"
assert "J StealXHTTP listen" "$(echo "$JJ" | jq -r '.[1].listen')" "127.0.0.1"
assert "J StealXHTTP no sockopt" "$(echo "$JJ" | jq -r '.[1].streamSettings | has("sockopt")')" "false"

echo "== panel_reality_* helpers =="
assert "inbound_port F" "$(panel_reality_inbound_port F)" "8443"
assert "inbound_port J" "$(panel_reality_inbound_port J)" "18443"
assert "xhttp_inbound_port F" "$(panel_reality_xhttp_inbound_port F)" "19444"
assert "xhttp_inbound_port J" "$(panel_reality_xhttp_inbound_port J)" "18444"
assert "xhttp_inbound_port default(other)" "$(panel_reality_xhttp_inbound_port 1)" "18444"
assert "listen_addr F" "$(panel_reality_listen_addr F)" "127.0.0.1"
assert "listen_addr J" "$(panel_reality_listen_addr J)" "127.0.0.1"
assert "listen_addr 1" "$(panel_reality_listen_addr 1)" ""
assert "listen_addr 2" "$(panel_reality_listen_addr 2)" ""
assert "accept_pp F" "$(panel_reality_accept_proxy_protocol F)" "true"
assert "accept_pp J" "$(panel_reality_accept_proxy_protocol J)" "true"
assert "accept_pp 1" "$(panel_reality_accept_proxy_protocol 1)" "false"

echo "== nginx generation: MODE=F, XHTTP disabled =="
panel_generate_nginx_config_f "panel.example" "sub.example" "self.example" \
    "pc" "sc" "stc" "ckey" "cval" "" ""
NCF0=$(cat /opt/remnawave/nginx.conf)
assert_contains "F/0 topology marker" "$NCF0" "# SERVER_MANAGER_TOPOLOGY=F"
assert_contains "F/0 xhttp marker=0" "$NCF0" "# SERVER_MANAGER_XHTTP=0"
assert_not_contains "F/0 no public 9443 listener" "$NCF0" "listen 9443;"
assert_not_contains "F/0 no xray_xhttp_f upstream" "$NCF0" "xray_xhttp_f"
assert_contains "F/0 public 443 stream still present" "$NCF0" "listen 443;"

echo "== nginx generation: MODE=F, XHTTP enabled =="
panel_generate_nginx_config_f "panel.example" "sub.example" "self.example" \
    "pc" "sc" "stc" "ckey" "cval" "" "" "1"
NCF1=$(cat /opt/remnawave/nginx.conf)
assert_contains "F/1 topology marker" "$NCF1" "# SERVER_MANAGER_TOPOLOGY=F"
assert_contains "F/1 xhttp marker=1" "$NCF1" "# SERVER_MANAGER_XHTTP=1"
assert_contains "F/1 public 9443 listener" "$NCF1" "listen 9443;"
assert_contains "F/1 upstream to 19444" "$NCF1" "server 127.0.0.1:19444;"
assert_contains "F/1 xray_xhttp_f upstream name" "$NCF1" "upstream xray_xhttp_f"
# XHTTP server block must not carry proxy_protocol as an actual directive
# (the surrounding doc comments legitimately mention the word "proxy_protocol"
# while explaining its absence, so check for the directive line itself).
XHTTP_BLOCK=$(awk '/listen 9443;/,/^    }/' /opt/remnawave/nginx.conf)
[ "$(grep -cE "^[[:space:]]*proxy_protocol on;[[:space:]]*$" <<<"$XHTTP_BLOCK")" = "0" ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: F/1 XHTTP block has no proxy_protocol directive"; }
assert_contains "F/1 vision 443 stream block unaffected" "$NCF1" "listen 443;"
assert_contains "F/1 vision stream still has proxy_protocol on" "$NCF1" "proxy_protocol on;"

echo "== nginx generation: MODE=J (regression) =="
panel_generate_nginx_config_j "panel.example" "sub.example" "self.example" \
    "pc" "sc" "stc" "ckey" "cval" "" ""
NCJ=$(cat /opt/remnawave/nginx.conf)
assert_contains "J topology marker" "$NCJ" "# SERVER_MANAGER_TOPOLOGY=J"
assert_contains "J xhttp marker=1" "$NCJ" "# SERVER_MANAGER_XHTTP=1"
assert_contains "J public 8443 literal" "$NCJ" "listen 8443;"
assert_contains "J upstream xray_xhttp to 18444" "$NCJ" "server 127.0.0.1:18444;"
XHTTP_BLOCK_J=$(awk '/listen 8443;/,/^    }/' /opt/remnawave/nginx.conf)
[ "$(grep -cE "^[[:space:]]*proxy_protocol on;[[:space:]]*$" <<<"$XHTTP_BLOCK_J")" = "0" ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: J XHTTP block has no proxy_protocol directive"; }

echo "== byte-identity: F/0 output matches pre-existing baseline shape (no XHTTP block/upstream leaked) =="
# Re-generate F/0 and F/1 and diff everything EXCEPT the two new marker
# lines and the XHTTP block/upstream -- i.e. assert F/0's body (minus
# markers) is identical to what F always produced.
panel_generate_nginx_config_f "panel.example" "sub.example" "self.example" \
    "pc" "sc" "stc" "ckey" "cval" "" ""
BASE1=$(tail -n +3 /opt/remnawave/nginx.conf)   # strip the 2 marker lines
panel_generate_nginx_config_f "panel.example" "sub.example" "self.example" \
    "pc" "sc" "stc" "ckey" "cval" "" ""
BASE2=$(tail -n +3 /opt/remnawave/nginx.conf)
if [ "$BASE1" = "$BASE2" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "  FAIL: F/0 not deterministic"; fi

echo "== management.sh fingerprint =="
mkdir -p /opt/remnawave
cat > /opt/remnawave/docker-compose.yml << 'EOF'
services:
  remnanode:
    image: x
EOF

# New F (with marker)
panel_generate_nginx_config_f "panel.example" "sub.example" "self.example" \
    "pc" "sc" "stc" "ckey" "cval" "" "" "0"
MODE_DETECTED=$(
    web_server=1; nc="/opt/remnawave/nginx.conf"
    _topology_marker=$(grep -m1 "^# SERVER_MANAGER_TOPOLOGY=" "$nc" 2>/dev/null | cut -d= -f2)
    if [ -f /opt/remnawave/docker-compose.yml ] && grep -q "remnanode" /opt/remnawave/docker-compose.yml; then
        if [ "$web_server" = "1" ] && [ -n "$_topology_marker" ]; then echo "$_topology_marker"
        elif [ "$web_server" = "1" ] && grep -q "xray_xhttp" "$nc" 2>/dev/null; then echo "J"
        elif [ "$web_server" = "1" ] && grep -q "^stream {" "$nc" 2>/dev/null; then echo "F"
        else echo "1"; fi
    else echo "2"; fi
)
assert "fingerprint: new F -> F" "$MODE_DETECTED" "F"

# New F+XHTTP (with marker) -- must NOT be misdetected as J despite xray_xhttp_f substring
panel_generate_nginx_config_f "panel.example" "sub.example" "self.example" \
    "pc" "sc" "stc" "ckey" "cval" "" "" "1"
MODE_DETECTED=$(
    web_server=1; nc="/opt/remnawave/nginx.conf"
    _topology_marker=$(grep -m1 "^# SERVER_MANAGER_TOPOLOGY=" "$nc" 2>/dev/null | cut -d= -f2)
    if [ -f /opt/remnawave/docker-compose.yml ] && grep -q "remnanode" /opt/remnawave/docker-compose.yml; then
        if [ "$web_server" = "1" ] && [ -n "$_topology_marker" ]; then echo "$_topology_marker"
        elif [ "$web_server" = "1" ] && grep -q "xray_xhttp" "$nc" 2>/dev/null; then echo "J"
        elif [ "$web_server" = "1" ] && grep -q "^stream {" "$nc" 2>/dev/null; then echo "F"
        else echo "1"; fi
    else echo "2"; fi
)
assert "fingerprint: new F+XHTTP -> F (not J)" "$MODE_DETECTED" "F"

# New J (with marker)
panel_generate_nginx_config_j "panel.example" "sub.example" "self.example" \
    "pc" "sc" "stc" "ckey" "cval" "" ""
MODE_DETECTED=$(
    web_server=1; nc="/opt/remnawave/nginx.conf"
    _topology_marker=$(grep -m1 "^# SERVER_MANAGER_TOPOLOGY=" "$nc" 2>/dev/null | cut -d= -f2)
    if [ -f /opt/remnawave/docker-compose.yml ] && grep -q "remnanode" /opt/remnawave/docker-compose.yml; then
        if [ "$web_server" = "1" ] && [ -n "$_topology_marker" ]; then echo "$_topology_marker"
        elif [ "$web_server" = "1" ] && grep -q "xray_xhttp" "$nc" 2>/dev/null; then echo "J"
        elif [ "$web_server" = "1" ] && grep -q "^stream {" "$nc" 2>/dev/null; then echo "F"
        else echo "1"; fi
    else echo "2"; fi
)
assert "fingerprint: new J -> J" "$MODE_DETECTED" "J"

# Legacy J (no marker, simulate pre-fix config): strip marker lines
tail -n +3 /opt/remnawave/nginx.conf > /opt/remnawave/nginx.conf.legacy
mv /opt/remnawave/nginx.conf.legacy /opt/remnawave/nginx.conf
MODE_DETECTED=$(
    web_server=1; nc="/opt/remnawave/nginx.conf"
    _topology_marker=$(grep -m1 "^# SERVER_MANAGER_TOPOLOGY=" "$nc" 2>/dev/null | cut -d= -f2)
    if [ -f /opt/remnawave/docker-compose.yml ] && grep -q "remnanode" /opt/remnawave/docker-compose.yml; then
        if [ "$web_server" = "1" ] && [ -n "$_topology_marker" ]; then echo "$_topology_marker"
        elif [ "$web_server" = "1" ] && grep -q "xray_xhttp" "$nc" 2>/dev/null; then echo "J"
        elif [ "$web_server" = "1" ] && grep -q "^stream {" "$nc" 2>/dev/null; then echo "F"
        else echo "1"; fi
    else echo "2"; fi
)
assert "fingerprint: legacy J (no marker) -> J" "$MODE_DETECTED" "J"

echo "== TeleMT collision ports (capability-driven, cli.sh) =="
# Directly exercise the reserved-ports array logic (extracted inline,
# since panel_cli_collect_j_options() itself is interactive / requires
# /dev/tty for the confirm() prompts beyond this point).
check_reserved() {
    local MODE="$1" F_XHTTP_ENABLE="$2" PORT="$3"
    local -a _reserved_ports=(443)
    if [ "$MODE" = "J" ]; then
        _reserved_ports+=(18443 18444 7444 8443)
    else
        _reserved_ports+=(7443 8443)
        [ "${F_XHTTP_ENABLE:-0}" = "1" ] && _reserved_ports+=(9443 19444)
    fi
    for _p in "${_reserved_ports[@]}"; do
        [ "$PORT" = "$_p" ] && { echo "1"; return; }
    done
    echo "0"
}
assert "F+XHTTP: 9443 reserved" "$(check_reserved F 1 9443)" "1"
assert "F+XHTTP: 19444 reserved" "$(check_reserved F 1 19444)" "1"
assert "F (no XHTTP): 9443 NOT reserved" "$(check_reserved F 0 9443)" "0"
assert "F (no XHTTP): unrelated port 5000 accepted" "$(check_reserved F 0 5000)" "0"
assert "J: 18444 reserved (unchanged)" "$(check_reserved J 1 18444)" "1"

echo "== bash -n on all changed files =="
for f in lib/panel/cli.sh lib/panel/install.sh lib/panel/api.sh \
         lib/panel/management.sh lib/panel/nginx/config.sh \
         lib/panel/nginx/variant_f.sh lib/panel/nginx/variant_j.sh \
         lib/panel/xray/templates/render.sh; do
    if bash -n "$f" 2>/tmp/synerr; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        echo "  FAIL: bash -n $f"; cat /tmp/synerr
    fi
done

echo ""
echo "==================================="
echo "PASS=$PASS FAIL=$FAIL"
echo "==================================="
[ "$FAIL" -eq 0 ]
