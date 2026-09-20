#!/bin/bash
# Mutation-safe harness for migrate_transfer_mtproxy() (lib/migrate.sh)
# Investigates: co-located F/J systemd TeleMT source -> migration -> destination
#
# Stubbed: ssh/scp (RUN/PUT overridden below, no real network),
#          systemctl, ufw, docker, useradd, chown, id, curl/tar/install (mock bins)
#          filesystem locations (TELEMT_CONFIG_SYSTEMD points at a sandbox path)
# NOT stubbed: migrate_transfer_mtproxy() itself - real function, real code path.

set -uo pipefail
REPO_ROOT="/home/claude/investigation/repo"
WORK="/home/claude/investigation/harness/work"
rm -rf "$WORK"
mkdir -p "$WORK"

MOCKBIN="$WORK/mockbin"
DEST="$WORK/dest_root"      # simulated DESTINATION filesystem
mkdir -p "$MOCKBIN" "$DEST/etc/telemt" "$DEST/etc/systemd/system" "$DEST/opt/telemt" "$DEST/usr/local/bin"
CALLS_LOG="$WORK/mock_calls.log"
: > "$CALLS_LOG"

# ---- Stub external mutating binaries (explicitly permitted to stub) ----
for cmd in systemctl ufw useradd chown id docker; do
    cat > "$MOCKBIN/$cmd" <<EOF
#!/bin/bash
echo "[MOCK $cmd] \$*" >> "$CALLS_LOG"
case "$cmd" in
    id) exit 1 ;;   # simulate: 'telemt' system user does not yet exist on destination
    *) exit 0 ;;
esac
EOF
    chmod +x "$MOCKBIN/$cmd"
done

# curl stub: emits a minimal valid tar.gz containing a dummy 'telemt' binary
# so the real install-binary logic in migrate_transfer_mtproxy() completes
# without reaching the real internet.
cat > "$MOCKBIN/curl" << 'EOF'
#!/bin/bash
echo "[MOCK curl] $*" >> "/home/claude/investigation/harness/work/mock_calls.log"
TMPD=$(mktemp -d)
echo "FAKE_TELEMT_BINARY" > "$TMPD/telemt"
tar -cz -C "$TMPD" telemt
rm -rf "$TMPD"
exit 0
EOF
chmod +x "$MOCKBIN/curl"

export PATH="$MOCKBIN:$PATH"
cd "$REPO_ROOT"

# ---- Source the real production code, in production load order ----
source lib/ui/output.sh
source lib/core/config.sh
source lib/common/core.sh
source lib/common/generators.sh
source lib/common/network.sh
source lib/common/ssh.sh
source lib/common/menu.sh
source lib/panel.sh
source lib/telemt.sh
source lib/migrate.sh

# ---- Stub RUN/PUT: no real ssh/scp, execute the exact same command text
#      locally against a sandboxed DESTINATION root (filesystem-location
#      stubbing only -- the command text built by migrate_transfer_mtproxy()
#      is NOT altered, only the absolute paths it touches are redirected). ----
RUN() {
    echo "===== RUN =====" >> "$CALLS_LOG"
    echo "$*" >> "$WORK/run_commands_raw.log"
    local cmd
    cmd=$(printf '%s' "$*" | sed \
        -e "s|/etc/telemt|$DEST/etc/telemt|g" \
        -e "s|/etc/systemd/system|$DEST/etc/systemd/system|g" \
        -e "s|/opt/telemt|$DEST/opt/telemt|g" \
        -e "s|/usr/local/bin|$DEST/usr/local/bin|g")
    # Some call sites do `RUN bash << HEREDOC`: the heredoc body arrives on
    # RUN's stdin, not in "$@". Redirect those same absolute paths there
    # too (filesystem-location stubbing only -- text/logic untouched) so
    # nothing this function does can touch this container's real /etc or
    # /usr/local/bin, matching the "mutation-safe" requirement.
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
PUT() {
    echo "[MOCK PUT] $*" >> "$CALLS_LOG"
}
export -f RUN PUT

# ---- SOURCE (local) config: simulate a genuine co-located F/J systemd
#      TeleMT install, exactly as telemt_write_config()/TELEMT_COLOCATE=1
#      would have produced it (ip=127.0.0.1 + proxy_protocol=true on the
#      same listener, per lib/telemt/install.sh + telemt_detect_state()'s
#      own "integrated" contract). This is the LOCAL/SOURCE side; migrate_
#      transfer_mtproxy() reads this file via $TELEMT_CONFIG_SYSTEMD. ----
SRC_CFG_DIR="$WORK/src_etc_telemt"
mkdir -p "$SRC_CFG_DIR"
cat > "$SRC_CFG_DIR/telemt.toml" << 'SRCCFG'
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
tls_domain    = "mtproto.investigation-test.example"
mask          = true
tls_emulation = true
tls_front_dir = "/opt/telemt/tlsfront"

[access.users]
alice = "5f3d9c1a2b4e6f708192a3b4c5d6e7f8"
bob   = "1a2b3c4d5e6f708192a3b4c5d6e7f809"

[access.user_max_tcp_conns]
alice = 50
SRCCFG

# Override the canonical config-path variable (filesystem-location stub
# only) so migrate_transfer_mtproxy() reads OUR synthetic source instead
# of the real host's /etc/telemt/telemt.toml.
TELEMT_CONFIG_SYSTEMD="$SRC_CFG_DIR/telemt.toml"

echo ""
echo "############################################################"
echo "# STEP 1: baseline (source config, before migration)"
echo "############################################################"
echo "--- SOURCE \$TELEMT_CONFIG_SYSTEMD = $TELEMT_CONFIG_SYSTEMD ---"
cat "$TELEMT_CONFIG_SYSTEMD"
echo ""
echo "Source listener ip:             $(telemt_detect_listener_ip "$TELEMT_CONFIG_SYSTEMD")"
echo "Source listener proxy_protocol: $(telemt_detect_listener_proxy_protocol "$TELEMT_CONFIG_SYSTEMD")"

echo ""
echo "############################################################"
echo "# STEP 2: run the REAL, unmodified migrate_transfer_mtproxy()"
echo "############################################################"
migrate_transfer_mtproxy
MIG_RC=$?
echo "migrate_transfer_mtproxy() exit code: $MIG_RC"

echo ""
echo "############################################################"
echo "# STEP 3: DESTINATION generated config"
echo "############################################################"
DEST_CFG="$DEST/etc/telemt/telemt.toml"
if [ -f "$DEST_CFG" ]; then
    cat "$DEST_CFG"
    echo ""
    echo "Destination listener ip:             $(telemt_detect_listener_ip "$DEST_CFG")"
    echo "Destination listener proxy_protocol: $(telemt_detect_listener_proxy_protocol "$DEST_CFG")"
else
    echo "!! NO CONFIG WRITTEN AT $DEST_CFG"
fi

echo ""
echo "############################################################"
echo "# STEP 4: all commands the function attempted to run remotely"
echo "############################################################"
cat "$CALLS_LOG"

echo ""
echo "############################################################"
echo "# STEP 5: destination filesystem tree actually produced"
echo "############################################################"
find "$DEST" -type f | sort
