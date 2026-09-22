#!/bin/bash
# lib/sripts/tests/test_migrate_all_mtproxy_failure_continuation.sh
#
# Integration-level regression test for migrate_all()'s own contract
# (lib/migrate.sh), not just migrate_transfer_mtproxy()'s internal
# behavior (already covered by test_telemt_migrate_colocate.sh):
#
#     migrate_transfer_mtproxy || warn "MTProxy не перенесён — продолжаю с Hysteria2"
#
# migrate_all()'s only production call site (migrate_menu() item 4,
# lib/migrate.sh) already wraps the whole call in `{ ...; } || true`,
# so a genuine MTProxy/TeleMT failure was never actually going to abort
# the shell via `set -e` either way -- what this line protects is
# whether the operator is TOLD MTProxy migration failed, and that the
# pipeline explicitly, deliberately continues to Hysteria2 rather than
# silently stopping short. Audit finding: a mutation dropping `|| warn`
# passed every existing test unchanged (test_telemt_migrate_colocate.sh,
# test_a2_migrate_delegation.sh, and the other migrate_* regression
# tests all only exercise migrate_transfer_mtproxy() in isolation, or
# check migrate_all()'s source text structurally -- none actually CALL
# migrate_all() end-to-end). This test closes that specific gap by
# invoking the real migrate_all() with a genuinely malformed TeleMT
# source (same malformed-config trigger as
# test_telemt_migrate_colocate.sh's own section 3) and confirming both
# the warning and Hysteria2's invocation actually happen.
#
# Mutation-safe: RUN/PUT are overridden to run locally (no real
# ssh/scp/network); the three pipeline steps this test does not concern
# itself with (migrate_prepare_target, migrate_transfer_panel,
# migrate_copy_script) and the final interactive migrate_summary are
# stubbed to thin logging no-ops -- migrate_transfer_mtproxy() and
# migrate_transfer_hysteria() run as their real, unmodified selves.
#
# Run: bash lib/sripts/tests/test_migrate_all_mtproxy_failure_continuation.sh
set -uo pipefail
exec < /dev/null

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

MOCKBIN="$WORK/mockbin"
mkdir -p "$MOCKBIN"
CALLS_LOG="$WORK/mock_calls.log"
ORDER_LOG="$WORK/order.log"
: > "$CALLS_LOG"
: > "$ORDER_LOG"

for cmd in systemctl ufw curl docker; do
    cat > "$MOCKBIN/$cmd" <<EOF
#!/bin/bash
echo "[MOCK $cmd] \$*" >> "$CALLS_LOG"
exit 0
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
# shellcheck disable=SC1091
source lib/migrate.sh
# shellcheck disable=SC1091
source lib/hysteria.sh

# RUN/PUT: no real ssh/scp -- run locally. Same convention as
# test_telemt_migrate_colocate.sh; the malformed-config failure path
# under test never reaches a RUN/PUT call in the first place (the
# guard in telemt_migrate_render_config() rejects it before any
# remote write), so these only need to exist, not do anything specific.
# Neither RUN nor PUT is actually reached by this test's scenario (the
# malformed-config guard in telemt_migrate_render_config() rejects the
# source before any remote write, and migrate_transfer_hysteria() takes
# its "not installed" branch since no real `hysteria` binary exists here)
# -- kept defined only as a safety net, unlike test_telemt_migrate_colocate.sh's
# RUN which needs real destination-path sandboxing for its config-write assertions.
RUN() { bash -c "$*" </dev/null; }
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

# ══════════════════════════════════════════════════════════════════
echo "=== 1. sanity: the malformed source genuinely fails migrate_transfer_mtproxy() in isolation ==="
SRC_DIR="$WORK/src_malformed"; mkdir -p "$SRC_DIR"
TELEMT_CONFIG_SYSTEMD="$SRC_DIR/telemt.toml"
TELEMT_CONFIG_DOCKER="$WORK/no_such_docker/telemt.toml"   # keep dispatch on systemd
cat > "$TELEMT_CONFIG_SYSTEMD" << 'EOF'
[general]
use_middle_proxy = true
EOF
# No [[server.listeners]] at all -- the same malformed-config shape
# test_telemt_migrate_colocate.sh's section 3 already uses.

ISO_RC=0
migrate_transfer_mtproxy >"$WORK/out_isolated.log" 2>&1 || ISO_RC=$?
check "isolated: migrate_transfer_mtproxy returns non-zero on malformed source" "$ISO_RC" "1"
check "isolated: real failure, not a 'nothing installed' skip" \
    "$(grep -c 'конфиг не содержит' "$WORK/out_isolated.log")" "1"

# ══════════════════════════════════════════════════════════════════
echo ""
echo "=== 2. migrate_all(): MTProxy failure must not abort the pipeline before Hysteria2 ==="
_SSH_IP="127.0.0.1"; _SSH_PORT="22"; _SSH_USER="root"

migrate_prepare_target() { echo "PREPARE" >> "$ORDER_LOG"; return 0; }
migrate_transfer_panel()  { echo "PANEL"   >> "$ORDER_LOG"; return 0; }
migrate_copy_script()     { echo "COPY_SCRIPT" >> "$ORDER_LOG"; return 0; }
migrate_summary()         { echo "SUMMARY" >> "$ORDER_LOG"; return 0; }
# migrate_transfer_mtproxy() and migrate_transfer_hysteria() are left
# as their real, unmodified selves -- this is the actual contract
# under test, not a simulated stand-in for it.

ALL_RC=0
migrate_all >"$WORK/out_all.log" 2>&1 || ALL_RC=$?
check "migrate_all() itself returns success (reached migrate_summary, full pipeline ran)" "$ALL_RC" "0"
check "migrate_all(): full pipeline order preserved despite MTProxy failure" \
    "$(cat "$ORDER_LOG" | tr '\n' ',')" "PREPARE,PANEL,COPY_SCRIPT,SUMMARY,"
check "migrate_all(): MTProxy step genuinely ran (not skipped)" \
    "$(grep -c 'Переносим MTProxy' "$WORK/out_all.log")" "1"
check "migrate_all(): MTProxy failure was caught with the expected warning" \
    "$(grep -c 'MTProxy не перенесён' "$WORK/out_all.log")" "1"
# "Hysteria2" alone also matches migrate_all()'s own opening header
# ("Перенос всего стека (Panel + MTProxy + Hysteria2)") and is echoed
# inside the "MTProxy не перенесён — продолжаю с Hysteria2" warning
# itself, so use the real Hysteria2 step's own distinctive message
# (hy_is_installed is false in this sandbox -- no real `hysteria`
# binary -- so this is the branch it actually takes) rather than a
# bare substring match.
check "migrate_all(): Hysteria2 step still ran after the MTProxy failure" \
    "$(grep -c 'Hysteria2 не найдена' "$WORK/out_all.log")" "1"
# Protected with `|| true`: under a mutation where one of these markers
# never appears, the pipeline's failing exit status (propagated through
# a bare assignment) would otherwise abort this whole test script under
# the inherited `set -e` from lib/common/core.sh, rather than letting
# the check below report a clean FAIL.
MTPROXY_LINE=$(grep -n 'MTProxy не перенесён' "$WORK/out_all.log" | head -1 | cut -d: -f1) || true
HYSTERIA_LINE=$(grep -n 'Hysteria2 не найдена' "$WORK/out_all.log" | head -1 | cut -d: -f1) || true
check "migrate_all(): Hysteria2 step runs AFTER the MTProxy failure, not before/instead" \
    "$([ -n "$MTPROXY_LINE" ] && [ -n "$HYSTERIA_LINE" ] && [ "$HYSTERIA_LINE" -gt "$MTPROXY_LINE" ] && echo yes || echo no)" "yes"

echo ""
echo "=== SUMMARY: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
