#!/bin/bash
# lib/sripts/tests/test_telemt_migrate_colocate.sh
#
# Regression test for the TeleMT migration co-location defect:
# migrate_transfer_mtproxy() (lib/migrate.sh) used to reconstruct
# telemt.toml from a hardcoded template (ip=0.0.0.0, no proxy_protocol,
# hardcoded [censorship]/[general]), discarding any field it didn't
# explicitly re-extract. This test proves the fixed function instead
# copies the source config and substitutes only port/tls_domain.
#
# Mutation-safe: RUN/PUT are overridden to run locally against an
# isolated destination root inside $WORK (no real ssh/scp), and
# systemctl/ufw/useradd/chown/id/curl are mocked. No repo files are
# touched; no real network access.
#
# Run: bash lib/sripts/tests/test_telemt_migrate_colocate.sh
set -uo pipefail
# Give this script a closed default stdin: RUN() below inspects stdin to
# decide whether a caller piped a heredoc body into it. Calls that pipe
# explicitly (echo ... | RUN "...", RUN bash <<EOF) always override this
# per-command; this only prevents bare `RUN "some command"` calls (no
# pipe at all, e.g. telemt_migrate_docker_payload()'s docker-check line)
# from blocking forever reading an open-but-empty inherited stdin.
exec < /dev/null

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

MOCKBIN="$WORK/mockbin"
DEST="$WORK/dest_root"
mkdir -p "$MOCKBIN" "$DEST/etc/telemt" "$DEST/etc/systemd/system" "$DEST/opt/telemt" "$DEST/usr/local/bin"
CALLS_LOG="$WORK/mock_calls.log"
: > "$CALLS_LOG"

for cmd in systemctl ufw useradd chown id docker; do
    cat > "$MOCKBIN/$cmd" <<EOF
#!/bin/bash
echo "[MOCK $cmd] \$*" >> "$CALLS_LOG"
case "$cmd" in
    id) exit 1 ;;
    *) exit 0 ;;
esac
EOF
    chmod +x "$MOCKBIN/$cmd"
done

cat > "$MOCKBIN/curl" << CURLEOF
#!/bin/bash
echo "[MOCK curl] \$*" >> "$CALLS_LOG"
TMPD=\$(mktemp -d)
echo "FAKE_TELEMT_BINARY" > "\$TMPD/telemt"
tar -cz -C "\$TMPD" telemt
rm -rf "\$TMPD"
exit 0
CURLEOF
chmod +x "$MOCKBIN/curl"

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
# shellcheck disable=SC1091
source lib/migrate.sh

# RUN/PUT: no real ssh/scp -- execute the exact command text locally
# against a sandboxed destination root. Filesystem-location stubbing
# only; the command text itself is not altered.
RUN() {
    local cmd
    cmd=$(printf '%s' "$*" | sed \
        -e "s|/etc/telemt|$DEST/etc/telemt|g" \
        -e "s|/etc/systemd/system|$DEST/etc/systemd/system|g" \
        -e "s|/opt/telemt|$DEST/opt/telemt|g" \
        -e "s|/usr/local/bin|$DEST/usr/local/bin|g")
    if [ -t 0 ]; then
        bash -c "$cmd"
    else
        sed \
            -e "s|/etc/telemt|$DEST/etc/telemt|g" \
            -e "s|/etc/systemd/system|$DEST/etc/systemd/system|g" \
            -e "s|/opt/telemt|$DEST/opt/telemt|g" \
            -e "s|/usr/local/bin|$DEST/usr/local/bin|g" \
            | bash -c "$cmd"
    fi
}
PUT() { echo "[MOCK PUT] $*" >> "$CALLS_LOG"; }

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

reset_dest() {
    rm -rf "$DEST"
    mkdir -p "$DEST/etc/telemt" "$DEST/etc/systemd/system" "$DEST/opt/telemt" "$DEST/usr/local/bin"
    : > "$CALLS_LOG"
}

DEST_CFG="$DEST/etc/telemt/telemt.toml"

# ══════════════════════════════════════════════════════════════════
echo "=== 1. systemd STANDALONE source: preserved as-is ==="
reset_dest
SRC_DIR="$WORK/src_standalone"; mkdir -p "$SRC_DIR"
TELEMT_CONFIG_SYSTEMD="$SRC_DIR/telemt.toml"
cat > "$TELEMT_CONFIG_SYSTEMD" << 'EOF'
[general]
use_middle_proxy = true
log_level = "normal"

[general.modes]
classic = false
secure  = false
tls     = true

[general.links]
show = "*"

[server]
port = 8443

[server.api]
enabled   = true
listen    = "127.0.0.1:9091"
whitelist = ["127.0.0.1/32"]

[[server.listeners]]
ip = "0.0.0.0"

[censorship]
tls_domain    = "standalone.example.com"
mask          = true
tls_emulation = true
tls_front_dir = "/opt/telemt/tlsfront"

[access.users]
alice = "5f3d9c1a2b4e6f708192a3b4c5d6e7f8"
EOF

migrate_transfer_mtproxy >"$WORK/out1.log" 2>&1
check "destination config written" "$([ -f "$DEST_CFG" ] && echo yes || echo no)" "yes"
check "ip preserved (0.0.0.0)" "$(telemt_detect_listener_ip "$DEST_CFG")" "0.0.0.0"
check "proxy_protocol still absent" "$(telemt_detect_listener_proxy_protocol "$DEST_CFG")" ""
check "port preserved" "$(grep -E '^port' "$DEST_CFG" | grep -oE '[0-9]+')" "8443"
check "domain preserved" "$(telemt_get_tls_domain "$DEST_CFG")" "standalone.example.com"
check "users preserved" "$(grep -c '^alice' "$DEST_CFG")" "1"

# ══════════════════════════════════════════════════════════════════
echo ""
echo "=== 2. systemd CO-LOCATED source (F/J): ip+proxy_protocol MUST survive ==="
reset_dest
SRC_DIR="$WORK/src_colocate"; mkdir -p "$SRC_DIR"
TELEMT_CONFIG_SYSTEMD="$SRC_DIR/telemt.toml"
cat > "$TELEMT_CONFIG_SYSTEMD" << 'EOF'
[general]
use_middle_proxy = true
log_level = "normal"

[general.modes]
classic = false
secure  = false
tls     = true

[general.links]
show = "*"

[server]
port = 28443

[server.api]
enabled   = true
listen    = "127.0.0.1:9091"
whitelist = ["127.0.0.1/32"]

[[server.listeners]]
ip = "127.0.0.1"
proxy_protocol = true

[censorship]
tls_domain    = "mtproto.colocate.example"
mask          = true
tls_emulation = true
tls_front_dir = "/opt/telemt/tlsfront"
sni_override  = "unknown-future-field.example"

[access.users]
alice = "5f3d9c1a2b4e6f708192a3b4c5d6e7f8"
bob   = "1a2b3c4d5e6f708192a3b4c5d6e7f809"

[access.user_max_tcp_conns]
alice = 50

[access.user_expirations]
bob = "2027-01-01T00:00:00Z"
EOF

migrate_transfer_mtproxy >"$WORK/out2.log" 2>&1
check "ip = 127.0.0.1 preserved (THE bug)" "$(telemt_detect_listener_ip "$DEST_CFG")" "127.0.0.1"
check "proxy_protocol = true preserved (THE bug)" "$(telemt_detect_listener_proxy_protocol "$DEST_CFG")" "true"
check "port preserved" "$(grep -E '^port' "$DEST_CFG" | grep -oE '[0-9]+')" "28443"
check "domain preserved" "$(telemt_get_tls_domain "$DEST_CFG")" "mtproto.colocate.example"
check "users preserved (both)" "$(awk '/^\[access\.users\]/{f=1;next} f&&/^\[/{exit} f&&/=/' "$DEST_CFG" | grep -cE '^(alice|bob) *=')" "2"
check "known limits block preserved (user_max_tcp_conns)" "$(grep -c 'user_max_tcp_conns' "$DEST_CFG")" "1"
check "known limits block preserved (user_expirations)" "$(grep -c 'user_expirations' "$DEST_CFG")" "1"
check "UNKNOWN future field survives (sni_override)" "$(grep -c 'sni_override' "$DEST_CFG")" "1"
check "ufw allow called with correct port" "$(grep -c 'MOCK ufw\] allow 28443/tcp' "$CALLS_LOG")" "1"
check "systemctl restart telemt called" "$(grep -c 'MOCK systemctl\] restart telemt' "$CALLS_LOG")" "1"

# ══════════════════════════════════════════════════════════════════
echo ""
echo "=== 3. malformed source config: must not silently fall back to hardcoded defaults ==="
reset_dest
SRC_DIR="$WORK/src_malformed"; mkdir -p "$SRC_DIR"
TELEMT_CONFIG_SYSTEMD="$SRC_DIR/telemt.toml"
cat > "$TELEMT_CONFIG_SYSTEMD" << 'EOF'
[general]
use_middle_proxy = true

[access.users]
alice = "5f3d9c1a2b4e6f708192a3b4c5d6e7f8"
EOF
# No [[server.listeners]] section at all -- structurally malformed for
# migration purposes (telemt_detect_listener_ip returns empty for it).

migrate_transfer_mtproxy >"$WORK/out3.log" 2>&1
MIG_RC=$?
check "malformed source: does NOT silently write ip=0.0.0.0 default" \
    "$([ -f "$DEST_CFG" ] && grep -c '^ip = "0.0.0.0"' "$DEST_CFG" || echo 0)" "0"

# ══════════════════════════════════════════════════════════════════
echo ""
echo "=== 4. telemt_menu_migrate() (interactive systemd path): structural check ==="
# /dev/tty is not reliably available in this sandbox (same documented
# limitation as test_telemt_noninteractive.sh), so the interactive read
# loop cannot be driven end-to-end here. Instead this inspects the REAL,
# just-sourced function body via declare -f (production text, not a
# hand-copied reimplementation -- same convention as
# test_a2_migrate_delegation.sh) to prove the preserve-semantics change
# actually landed in telemt_menu_migrate() itself, not just in
# migrate_transfer_mtproxy().
FN_BODY="$(declare -f telemt_menu_migrate)"
check "no hardcoded ip=0.0.0.0 reconstruction left" \
    "$(echo "$FN_BODY" | grep -c 'ip = "0.0.0.0"')" "0"
check "no hardcoded tls_front_dir template left" \
    "$(echo "$FN_BODY" | grep -c 'tls_front_dir.*=.*TELEMT_TLSFRONT_DIR')" "0"
check "uses sed preserve-substitution pattern (port)" \
    "$(echo "$FN_BODY" | grep -c 'sed .*s/\^port = ')" "1"
check "uses sed preserve-substitution pattern (tls_domain)" \
    "$(echo "$FN_BODY" | grep -c 's/\^tls_domain')" "1"
check "no longer calls telemt_extract_limits_block (whole file already carries it)" \
    "$(echo "$FN_BODY" | grep -c 'telemt_extract_limits_block')" "0"
check "interactive port/domain prompts unchanged (still 2 read -rp calls)" \
    "$(echo "$FN_BODY" | grep -c 'read -rp')" "2"
check "SSH target collection (ask_ssh_target) still present, unchanged" \
    "$(echo "$FN_BODY" | grep -c 'ask_ssh_target')" "1"

# ══════════════════════════════════════════════════════════════════
echo ""
echo "=== 5. telemt_migrate_docker_payload() (non-interactive core): docker co-located preservation ==="
reset_dest
DOCKER_SRC_DIR="$WORK/docker_src"; mkdir -p "$DOCKER_SRC_DIR"
TELEMT_CONFIG_FILE="$DOCKER_SRC_DIR/telemt.toml"
TELEMT_COMPOSE_FILE="$DOCKER_SRC_DIR/docker-compose.yml"
cat > "$TELEMT_CONFIG_FILE" << 'EOF'
[general]
use_middle_proxy = true
log_level = "normal"

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
tls_domain    = "mtproto.docker-colocate.example"
mask          = true
tls_emulation = true
tls_front_dir = "tlsfront"

[access.users]
carol = "abc123def456abc123def456abc123d"
EOF
cat > "$TELEMT_COMPOSE_FILE" << 'EOF'
services:
  telemt:
    image: ghcr.io/telemt/telemt:latest
    ports:
      - "127.0.0.1:9443:9443"
EOF

# Minimal fake SSH target globals -- telemt_migrate_docker_payload()
# uses these (already set by ask_ssh_target/init_ssh_helpers in the
# interactive case, or by migrate_prepare_target() in migrate_all())
# only for the PUT compose-file transfer; RUN/PUT below are already
# overridden to run locally, so these values just need to be non-empty.
_SSH_USER="root"; _SSH_IP="127.0.0.1"

telemt_migrate_docker_payload "9443" "mtproto.docker-colocate.example" >"$WORK/out5.log" 2>&1
PAYLOAD_RC=$?
check "payload returns success" "$PAYLOAD_RC" "0"
check "docker config written at TELEMT_CONFIG_FILE" "$([ -f "$TELEMT_CONFIG_FILE" ] && echo yes || echo no)" "yes"
check "docker ip=127.0.0.1 preserved" "$(telemt_detect_listener_ip "$TELEMT_CONFIG_FILE")" "127.0.0.1"
check "docker proxy_protocol=true preserved" "$(telemt_detect_listener_proxy_protocol "$TELEMT_CONFIG_FILE")" "true"
check "docker port substituted correctly" "$(grep -E '^port' "$TELEMT_CONFIG_FILE" | grep -oE '[0-9]+')" "9443"
check "docker users preserved" "$(grep -c '^carol' "$TELEMT_CONFIG_FILE")" "1"
check "docker compose pull called" "$(grep -c 'MOCK docker\] compose pull' "$CALLS_LOG")" "1"
check "docker compose up called" "$(grep -c 'MOCK docker\] compose up' "$CALLS_LOG")" "1"

echo ""
echo "=== SUMMARY: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
