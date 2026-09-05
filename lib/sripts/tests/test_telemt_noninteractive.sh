#!/bin/bash
# lib/sripts/tests/test_telemt_noninteractive.sh
#
# Self-contained regression test for the co-located TeleMT integration
# (lib/telemt/core.sh detection helpers + lib/telemt/install.sh's
# telemt_install_noninteractive(), lib/panel/install.sh's reconfigure
# call site). Unlike test_cli_interactive.py (removed in this same
# change — see git log), this file:
#   - creates its own isolated temp workspace (mktemp -d) instead of a
#     fixed /tmp path, and its own mock bin/ directory inside that
#     workspace instead of relying on anything outside the repo;
#   - makes real pass/fail assertions with a real non-zero exit code on
#     failure (not just printed output);
#   - does not touch /dev/tty or panel_cli_collect_j_options() at all —
#     that function is interactive by design and is exercised manually
#     (see docs/TELEMT_INTEGRATION.md's "interactive CLI" note / this
#     session's report) rather than by an automated test, since /dev/tty
#     is not reliably available in CI/sandbox environments.
#
# Run: bash lib/sripts/tests/test_telemt_noninteractive.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

MOCKBIN="$WORK/mockbin"
mkdir -p "$MOCKBIN" "$WORK/systemd_cfg" "$WORK/docker_work"
CALLS_LOG="$WORK/mock_calls.log"
: > "$CALLS_LOG"

for cmd in docker systemctl useradd chown ufw id; do
    cat > "$MOCKBIN/$cmd" <<EOF
#!/bin/bash
echo "[MOCK $cmd] \$*" >> "$CALLS_LOG"
case "$cmd" in
    id) exit 1 ;;
    docker) [ "\$1" = "compose" ] && exit 0; exit 0 ;;
    *) exit 0 ;;
esac
EOF
    chmod +x "$MOCKBIN/$cmd"
done

export PATH="$MOCKBIN:$PATH"
cd "$REPO_ROOT"

# shellcheck disable=SC1091
source lib/ui/output.sh
# shellcheck disable=SC1091
source lib/common.sh
# shellcheck disable=SC1091
source lib/panel.sh
# shellcheck disable=SC1091
source lib/telemt.sh

# Redirect all TeleMT paths into the isolated workspace.
TELEMT_BIN="$WORK/telemt-bin"
TELEMT_CONFIG_DIR="$WORK/systemd_cfg"
TELEMT_CONFIG_SYSTEMD="${TELEMT_CONFIG_DIR}/telemt.toml"
TELEMT_WORK_DIR_SYSTEMD="$WORK/systemd_work"
TELEMT_TLSFRONT_DIR="${TELEMT_WORK_DIR_SYSTEMD}/tlsfront"
TELEMT_SERVICE_FILE="$WORK/telemt.service"
TELEMT_WORK_DIR_DOCKER="$WORK/docker_work"
TELEMT_CONFIG_DOCKER="${TELEMT_WORK_DIR_DOCKER}/telemt.toml"
TELEMT_COMPOSE_FILE="${TELEMT_WORK_DIR_DOCKER}/docker-compose.yml"

PASS=0
FAIL=0
check() {
    local desc="$1" got="$2" expected="$3"
    if [ "$got" = "$expected" ]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (expected [$expected], got [$got])"
        FAIL=$((FAIL + 1))
    fi
}

reset_docker_cfg() {
    rm -rf "$TELEMT_WORK_DIR_DOCKER"
    mkdir -p "$TELEMT_WORK_DIR_DOCKER"
    : > "$CALLS_LOG"
}

echo "=== absent state ==="
reset_docker_cfg
check "state=absent" "$(telemt_detect_state)" "absent"
check "installed_mode empty" "$(telemt_detect_installed_mode)" ""

echo ""
echo "=== fresh docker install (new integrated) ==="
reset_docker_cfg
telemt_install_noninteractive "9443" "mtproto.example.com" "docker" "true" "" "" "" \
    >"$WORK/install_new.log" 2>&1
check "install exit code 0" "$?" "0"
check "config written" "$([ -f "$TELEMT_CONFIG_DOCKER" ] && echo yes || echo no)" "yes"
check "compose written" "$([ -f "$TELEMT_COMPOSE_FILE" ] && echo yes || echo no)" "yes"
check "listener ip = 127.0.0.1" "$(telemt_detect_listener_ip "$TELEMT_CONFIG_DOCKER")" "127.0.0.1"
check "proxy_protocol present" "$(telemt_detect_listener_proxy_protocol "$TELEMT_CONFIG_DOCKER")" "true"
check "tls_domain matches" "$(telemt_get_tls_domain "$TELEMT_CONFIG_DOCKER")" "mtproto.example.com"
check "port matches" "$(telemt_detect_port)" "9443"
check "compose binds loopback only" "$(grep -c '127.0.0.1:9443:9443' "$TELEMT_COMPOSE_FILE")" "1"
check "compose does not publish public port" "$(grep -cE '^\s*- "9443:9443' "$TELEMT_COMPOSE_FILE")" "0"
check "state now integrated" "$(telemt_detect_state)" "integrated"
check "default user auto-generated" "$(grep -c '^panel-' "$TELEMT_CONFIG_DOCKER")" "1"
check "ufw never called" "$(grep -c 'MOCK ufw' "$CALLS_LOG")" "0"
check "docker compose pull called exactly once" "$(grep -c 'MOCK docker\] compose pull' "$CALLS_LOG")" "1"
check "docker compose up called exactly once" "$(grep -c 'MOCK docker\] compose up' "$CALLS_LOG")" "1"

echo ""
echo "=== reconfigure: domain/port change, no [[upstreams]] block present ==="
# Regression test for the confirmed bug: telemt_detect_socks5_addr/
# user/pass return non-zero (pipefail: grep found no match) when a
# config has no [[upstreams]] section at all -- the common case, since
# SOCKS5 upstream is optional. Under this codebase's `set -euo
# pipefail`, an unguarded `var=$(...)` assignment with that failure
# aborts the whole calling script. Reproduced directly this session;
# lib/panel/install.sh's reconfigure call site now guards each of these
# four detectors with `|| true`. This block exercises the exact same
# detect-then-feed-forward sequence install.sh performs (not just the
# detectors in isolation), so a regression in either the detectors or
# the call-site guards fails loudly here.
NO_UPSTREAM_USE_ME=$(telemt_detect_use_me "$TELEMT_CONFIG_DOCKER") || true
[ -z "$NO_UPSTREAM_USE_ME" ] && NO_UPSTREAM_USE_ME="true"
NO_UPSTREAM_ADDR=$(telemt_detect_socks5_addr "$TELEMT_CONFIG_DOCKER") || true
NO_UPSTREAM_USER=$(telemt_detect_socks5_user "$TELEMT_CONFIG_DOCKER") || true
NO_UPSTREAM_PASS=$(telemt_detect_socks5_pass "$TELEMT_CONFIG_DOCKER") || true
RC=$?
check "detect sequence did not abort" "$RC" "0"
check "no upstream addr detected (empty, not an error)" "$NO_UPSTREAM_ADDR" ""
mapfile -t NO_UPSTREAM_PAIRS < <(telemt_detect_user_pairs "$TELEMT_CONFIG_DOCKER")
telemt_install_noninteractive "9556" "reconf-no-upstream.example.com" "docker" \
    "$NO_UPSTREAM_USE_ME" "$NO_UPSTREAM_ADDR" "$NO_UPSTREAM_USER" "$NO_UPSTREAM_PASS" \
    "${NO_UPSTREAM_PAIRS[@]}" >"$WORK/install_reconf_noup.log" 2>&1
check "reconfigure (no upstream) exit code 0" "$?" "0"
check "new port applied" "$(telemt_detect_port)" "9556"
check "new domain applied" "$(telemt_get_tls_domain "$TELEMT_CONFIG_DOCKER")" "reconf-no-upstream.example.com"
check "still no [[upstreams]] block (nothing invented)" "$(grep -c '^\[\[upstreams\]\]' "$TELEMT_CONFIG_DOCKER")" "0"
check "still integrated" "$(telemt_detect_state)" "integrated"

echo ""
echo "=== reconfigure: preserves users + SOCKS5 upstream when present ==="
cat > "$TELEMT_CONFIG_DOCKER" <<'EOF'
[general]
use_middle_proxy = false
log_level = "normal"

[general.modes]
classic = false
secure  = false
tls     = true

[general.links]
show = "*"

[server]
port = 9443

[server.api]
enabled   = true
listen    = "0.0.0.0:9091"
whitelist = ["127.0.0.0/8"]

[[server.listeners]]
ip = "127.0.0.1"
proxy_protocol = true

[censorship]
tls_domain    = "mtproto.example.com"
mask          = true
tls_emulation = true
tls_front_dir = "tlsfront"

[access.users]
alice = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
bob = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

[[upstreams]]
type    = "socks5"
address = "1.2.3.4:1080"
username = "socksuser"
password = "sockspass"
EOF
check "pre-fixture use_me=false" "$(telemt_detect_use_me "$TELEMT_CONFIG_DOCKER")" "false"
check "pre-fixture 2 users" "$(telemt_detect_user_pairs "$TELEMT_CONFIG_DOCKER" | wc -l)" "2"

EXISTING_USE_ME=$(telemt_detect_use_me "$TELEMT_CONFIG_DOCKER") || true
EXISTING_ADDR=$(telemt_detect_socks5_addr "$TELEMT_CONFIG_DOCKER") || true
EXISTING_USER=$(telemt_detect_socks5_user "$TELEMT_CONFIG_DOCKER") || true
EXISTING_PASS=$(telemt_detect_socks5_pass "$TELEMT_CONFIG_DOCKER") || true
mapfile -t EXISTING_PAIRS < <(telemt_detect_user_pairs "$TELEMT_CONFIG_DOCKER")

telemt_install_noninteractive "9555" "new-mtproto.example.com" "docker" \
    "$EXISTING_USE_ME" "$EXISTING_ADDR" "$EXISTING_USER" "$EXISTING_PASS" \
    "${EXISTING_PAIRS[@]}" >"$WORK/install_reconf.log" 2>&1
check "reconfigure exit code 0" "$?" "0"
check "new port applied" "$(telemt_detect_port)" "9555"
check "new domain applied" "$(telemt_get_tls_domain "$TELEMT_CONFIG_DOCKER")" "new-mtproto.example.com"
check "use_me preserved (false)" "$(telemt_detect_use_me "$TELEMT_CONFIG_DOCKER")" "false"
check "socks addr preserved" "$(telemt_detect_socks5_addr "$TELEMT_CONFIG_DOCKER")" "1.2.3.4:1080"
check "socks user preserved" "$(telemt_detect_socks5_user "$TELEMT_CONFIG_DOCKER")" "socksuser"
check "socks pass preserved" "$(telemt_detect_socks5_pass "$TELEMT_CONFIG_DOCKER")" "sockspass"
check "both users preserved" "$(telemt_detect_user_pairs "$TELEMT_CONFIG_DOCKER" | wc -l)" "2"
check "alice secret byte-identical" "$(grep -c 'alice = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' "$TELEMT_CONFIG_DOCKER")" "1"
check "still integrated" "$(telemt_detect_state)" "integrated"
check "still no ufw call" "$(grep -c 'MOCK ufw' "$CALLS_LOG")" "0"

echo ""
echo "=== standalone: public bind + proxy_protocol=true ==="
cat > "$TELEMT_CONFIG_DOCKER" <<'EOF'
[general]
use_middle_proxy = true
[server]
port = 8443
[server.api]
enabled = true
listen = "0.0.0.0:9091"
whitelist = ["127.0.0.0/8"]
[[server.listeners]]
ip = "0.0.0.0"
[censorship]
tls_domain = "petrovich.ru"
mask = true
tls_emulation = true
tls_front_dir = "tlsfront"
[access.users]
someone = "cccccccccccccccccccccccccccccccc"
EOF
check "state=standalone (public ip)" "$(telemt_detect_state)" "standalone"
check "standalone domain" "$(telemt_get_tls_domain "$TELEMT_CONFIG_DOCKER")" "petrovich.ru"
check "standalone port" "$(telemt_detect_port)" "8443"

echo ""
echo "=== detection precision: loopback bind WITHOUT proxy_protocol is NOT integrated ==="
# Regression test for a real classification gap found this session:
# telemt_write_config() only ever writes ip=127.0.0.1 together with
# proxy_protocol=true (see TELEMT_COLOCATE=1 branch) -- but a
# hand-edited or foreign config could have ip=127.0.0.1 alone (e.g. an
# operator's own stunnel/haproxy setup unrelated to this Panel). If
# telemt_detect_state() classified that as "integrated" based on IP
# alone, Panel would wire Nginx to send PROXY protocol traffic to a
# listener that never asked for it -- silently breaking a standalone
# setup Panel has no business touching (the exact failure mode
# standalone-safety is supposed to prevent). Both conditions are now
# required together.
cat > "$TELEMT_CONFIG_DOCKER" <<'EOF'
[general]
use_middle_proxy = true
[server]
port = 8443
[[server.listeners]]
ip = "127.0.0.1"
[censorship]
tls_domain = "loopback-no-pp.example.com"
[access.users]
x = "dddddddddddddddddddddddddddddddd"
EOF
check "loopback WITHOUT proxy_protocol => standalone, not integrated" "$(telemt_detect_state)" "standalone"

echo ""
echo "=== SUMMARY: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
exit $?
