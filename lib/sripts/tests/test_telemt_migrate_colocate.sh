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

MIG_RC=0
migrate_transfer_mtproxy >"$WORK/out3.log" 2>&1 || MIG_RC=$?
check "malformed source: does NOT silently write ip=0.0.0.0 default" \
    "$([ -f "$DEST_CFG" ] && grep -c '^ip = "0.0.0.0"' "$DEST_CFG" || echo 0)" "0"
check "malformed source: migrate_transfer_mtproxy propagates failure (non-zero), not silently 0" \
    "$MIG_RC" "1"

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
check "delegates config substitution to telemt_migrate_systemd_payload (no inline duplicate)" \
    "$(echo "$FN_BODY" | grep -c 'telemt_migrate_systemd_payload')" "1"
check "does not inline its own sed substitution (would drift from the shared renderer)" \
    "$(echo "$FN_BODY" | grep -c 'sed ')" "0"
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

# ══════════════════════════════════════════════════════════════════
echo ""
echo "=== 6. telemt_migrate_render_config() in isolation: exact-key boundary + port-format tolerance ==="
# Regression coverage for a real bug found this pass: both payloads'
# tls_domain substitution matched "tls_domain" as a bare prefix with
# no boundary check, so a same-line key that merely STARTS with that
# word (tls_domain_extra) had its value silently overwritten; the
# docker payload's copy was worse still, missing the ^ anchor
# entirely, so it also clobbered a value on any line containing
# "tls_domain" as a substring anywhere (my_tls_domain).
RENDER_SRC="$WORK/render_src.toml"
cat > "$RENDER_SRC" << 'EOF'
[server]
port=443
port_backup = 9999

[[server.listeners]]
ip = "127.0.0.1"
proxy_protocol = true

[censorship]
my_tls_domain = "should-not-change.example"
tls_domain    = "old.example.com"
tls_domain_extra = "also-should-not-change.example"
EOF
RENDERED=$(telemt_migrate_render_config "$RENDER_SRC" "9443" "new.example.com")
check "render: exact port substituted (no-space source variant port=443)" \
    "$(echo "$RENDERED" | grep -E '^port ' | grep -oE '[0-9]+')" "9443"
check "render: port_backup untouched (key AND value)" \
    "$(echo "$RENDERED" | grep -c '^port_backup = 9999$')" "1"
check "render: real tls_domain substituted" \
    "$(echo "$RENDERED" | grep -c '^tls_domain    = "new.example.com"$')" "1"
check "render: my_tls_domain untouched (THE bug -- docker payload had no ^ anchor at all)" \
    "$(echo "$RENDERED" | grep -c '^my_tls_domain = "should-not-change.example"$')" "1"
check "render: tls_domain_extra untouched (THE bug -- bare prefix match, present in BOTH payloads)" \
    "$(echo "$RENDERED" | grep -c '^tls_domain_extra = "also-should-not-change.example"$')" "1"

RENDERED2=$(telemt_migrate_render_config "$RENDER_SRC" "80" "x")
check "render: port with extra internal whitespace also substituted (port    = 80)" \
    "$(echo "$RENDERED2" | sed -n '2p' | tr -s ' ')" "port = 80"

check "render: rejects non-numeric port (validation)" \
    "$(telemt_migrate_render_config "$RENDER_SRC" "not-a-port" "x" >/dev/null 2>&1; echo $?)" "1"
check "render: rejects empty domain (validation)" \
    "$(telemt_migrate_render_config "$RENDER_SRC" "443" "" >/dev/null 2>&1; echo $?)" "1"
check "render: rejects missing source file" \
    "$(telemt_migrate_render_config "$WORK/does_not_exist.toml" "443" "x" >/dev/null 2>&1; echo $?)" "1"

echo ""
echo "=== 7. telemt_migrate_docker_payload() specifically no longer has the unanchored duplicate ==="
DOCKER_FN_BODY="$(declare -f telemt_migrate_docker_payload)"
check "docker payload delegates to the shared renderer" \
    "$(echo "$DOCKER_FN_BODY" | grep -c 'telemt_migrate_render_config')" "1"
check "docker payload no longer inlines its own sed" \
    "$(echo "$DOCKER_FN_BODY" | grep -c 'sed ')" "0"

# ══════════════════════════════════════════════════════════════════
echo ""
echo "=== 8. migrate_telemt_interactive(): routes to the wizard matching the ACTUAL installed mode ==="
# The bug this replaces: migrate_menu() item 2 defaulted TELEMT_MODE to
# "systemd" whenever it was unset (the ordinary case) and called only
# telemt_menu_migrate -- a Docker install got the systemd wizard. Stub
# out both wizards (their own interactive /dev/tty prompts are each
# already covered structurally in section 4 / by symmetry for docker)
# to isolate dispatch itself: which wizard gets called, based on which
# mode is ACTUALLY installed, overriding any stale $TELEMT_MODE.
telemt_menu_migrate() { echo "DISPATCHED:systemd" >> "$WORK/dispatch.log"; }
telemt_menu_migrate_docker() { echo "DISPATCHED:docker" >> "$WORK/dispatch.log"; }

DISPATCH_SRC="$WORK/dispatch_src"; mkdir -p "$DISPATCH_SRC"
TELEMT_WORK_DIR_SYSTEMD="$WORK/dispatch_workdir_systemd"
TELEMT_WORK_DIR_DOCKER="$WORK/dispatch_workdir_docker"

: > "$WORK/dispatch.log"
TELEMT_CONFIG_SYSTEMD="$DISPATCH_SRC/nonexistent_systemd.toml"
TELEMT_CONFIG_DOCKER="$DISPATCH_SRC/docker.toml"; touch "$TELEMT_CONFIG_DOCKER"
TELEMT_MODE="systemd"  # stale from an earlier, unrelated menu action
migrate_telemt_interactive
check "docker installed + stale TELEMT_MODE=systemd -> Docker wizard (THE bug)" \
    "$(cat "$WORK/dispatch.log")" "DISPATCHED:docker"
check "docker installed: TELEMT_MODE corrected to docker" "$TELEMT_MODE" "docker"

: > "$WORK/dispatch.log"
rm -f "$TELEMT_CONFIG_DOCKER"
TELEMT_CONFIG_SYSTEMD="$DISPATCH_SRC/systemd.toml"; touch "$TELEMT_CONFIG_SYSTEMD"
TELEMT_MODE="docker"  # stale from an earlier, unrelated menu action
migrate_telemt_interactive
check "systemd installed + stale TELEMT_MODE=docker -> systemd wizard" \
    "$(cat "$WORK/dispatch.log")" "DISPATCHED:systemd"
check "systemd installed: TELEMT_MODE corrected to systemd" "$TELEMT_MODE" "systemd"

: > "$WORK/dispatch.log"
rm -f "$TELEMT_CONFIG_SYSTEMD"
DISP_RC=0
migrate_telemt_interactive || DISP_RC=$?
check "neither installed: no wizard called" "$(cat "$WORK/dispatch.log")" ""
check "neither installed: returns non-zero" "$DISP_RC" "1"

echo ""
echo "=== SUMMARY: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
