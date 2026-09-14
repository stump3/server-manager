#!/bin/bash
# lib/sripts/tests/test_a2_migrate_delegation.sh
#
# A-2: the generated /usr/local/bin/remnawave_panel's do_migrate()
# (lib/panel/mgmt_script.sh) used to be a standalone reimplementation
# of Panel migration that called six project-specific SSH helpers
# (ask_ssh_target/init_ssh_helpers/check_ssh_connection/
# remote_install_deps/RUN/PUT) which only exist in lib/common/ssh.sh,
# sourced by the normal server-manager.sh runtime -- never embedded in
# the standalone generated script. Every one of those calls was
# guaranteed to fail with "command not found" at runtime.
#
# The fix replaces that duplicate with a thin delegator that re-execs
# server-manager.sh migrate, which lib/cli/router.sh's cli_run() now
# dispatches to panel_migrate() (lib/migrate.sh) -- the same
# migrate_prepare_target()+migrate_transfer_panel() pipeline
# migrate_all() already uses for its own Panel leg. This guards three
# things regression could silently break:
#   1. the generated do_migrate() body no longer references any of the
#      six undefined helpers (the original bug);
#   2. cli_run() actually dispatches "migrate" to panel_migrate() --
#      not main_menu() (the gap that shipped with the first delegation
#      attempt: server-manager.sh never forwarded argv to cli_run(),
#      so the "migrate" argument was silently swallowed and the
#      delegation landed the operator in the interactive main menu
#      instead of performing the migration) -- and does NOT dispatch
#      to migrate_all()/migrate_menu(), which are a different,
#      wider operation (Panel+MTProxy+Hysteria2);
#   3. no-argument invocation (the overwhelmingly common case --
#      launching server-manager.sh interactively) is unaffected.
#
# No real SSH/network/docker/root: cli_run() is tested by stubbing
# panel_migrate()/main_menu() as pure recorders, and the generated
# script body is tested via bash -n + grep on the *extracted* heredoc
# text (real production text, not a hand-copied re-implementation --
# same convention as test_ssh_reliability_f1.sh's awk-extracted
# driver), never by actually running panel_install_mgmt_script() (which
# would write to the real /usr/local/bin).
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

# ── Extract the literal generated-script body ───────────────────────
# lib/panel/mgmt_script.sh writes it via `cat >> "$mgmt" << 'MGMTEOF'`
# (a QUOTED heredoc -- no variable expansion happens at generation
# time), so this text is byte-identical to what actually ships in
# /usr/local/bin/remnawave_panel, apart from the tiny unquoted
# MGMTEOF_HEADER block (MODE=...) prepended separately, which is
# irrelevant to do_migrate()/cli dispatch.
MGMT_BODY="$(awk '/<< .MGMTEOF.$/{flag=1; next} /^MGMTEOF$/{flag=0} flag{print}' lib/panel/mgmt_script.sh)"

echo "== 1. bash -n on the extracted generated-script body (standalone syntax check) =="
printf '%s\n' "$MGMT_BODY" > /tmp/_a2_mgmt_extracted.sh
bash -n /tmp/_a2_mgmt_extracted.sh 2>/tmp/_a2_mgmt_synerr \
    && PASS=$((PASS+1)) \
    || { FAIL=$((FAIL+1)); echo "  FAIL: bash -n on extracted mgmt body"; cat /tmp/_a2_mgmt_synerr; }
rm -f /tmp/_a2_mgmt_extracted.sh /tmp/_a2_mgmt_synerr

DO_MIGRATE_BODY="$(awk '/^do_migrate\(\) \{/,/^\}$/' lib/panel/mgmt_script.sh)"
# do_migrate()'s own header comment deliberately names all six retired
# helpers in prose (explaining what used to be embedded and why it's
# not anymore) -- strip comment lines first so the check below is
# "does the CODE call these", not "does the comment ever mention them".
DO_MIGRATE_CODE_ONLY="$(grep -v '^[[:space:]]*#' <<<"$DO_MIGRATE_BODY")"

echo ""
echo "== 2. do_migrate() no longer references any of the six undefined SSH helpers =="
for helper in ask_ssh_target init_ssh_helpers check_ssh_connection remote_install_deps RUN PUT; do
    assert "do_migrate() does not call $helper() (code, not comments)" \
        "$(grep -c "\b${helper}\b" <<<"$DO_MIGRATE_CODE_ONLY")" "0"
done

echo ""
echo "== 3. do_migrate() delegates via exec to server-manager.sh migrate =="
assert "do_migrate() execs server-manager.sh with the migrate argument" \
    "$(grep -c 'exec bash "\${sm_src}/server-manager.sh" migrate' <<<"$DO_MIGRATE_BODY")" "1"
assert "delegation target uses the same SCRIPT_DIR/root fallback convention as migrate_copy_script()" \
    "$(grep -c 'sm_src="\${SCRIPT_DIR:-/root/server-manager}"' <<<"$DO_MIGRATE_BODY")" "1"
assert "unreachable repository fails clearly (non-zero return), not silent command-not-found" \
    "$(grep -c 'return 1' <<<"$DO_MIGRATE_BODY")" "1"

echo ""
echo "== 4. do_migrate() is still reachable from both CLI-arg and interactive-menu dispatch (unrelated commands untouched) =="
assert "case \"\$1\" in migrate) still present" \
    "$(grep -c 'migrate)     do_migrate ;;' "$REPO_ROOT/lib/panel/mgmt_script.sh")" "1"
assert "interactive menu option 11 still calls do_migrate" \
    "$(grep -c '11) do_migrate;' "$REPO_ROOT/lib/panel/mgmt_script.sh")" "1"
# Spot-check a couple of unrelated commands survive untouched in the same case block
assert "unrelated 'status' command untouched" \
    "$(grep -c 'status)      do_status ;;' "$REPO_ROOT/lib/panel/mgmt_script.sh")" "1"
assert "unrelated 'ssl' command untouched" \
    "$(grep -c 'ssl)         do_ssl ;;' "$REPO_ROOT/lib/panel/mgmt_script.sh")" "1"

# ── cli_run() dispatcher behaviour ───────────────────────────────────
echo ""
echo "== 5. cli_run() dispatches the 'migrate' argument to panel_migrate(), not main_menu() =="
(
    # Isolated subshell: stub the two functions cli_run() can call as
    # pure recorders (no real menu, no real migration), then source the
    # actual production router.sh and exercise its real cli_run().
    CALLED=""
    panel_migrate() { CALLED="panel_migrate"; return 7; }
    main_menu()     { CALLED="main_menu"; return 0; }
    # shellcheck source=/dev/null
    source "$REPO_ROOT/lib/cli/router.sh"

    cli_run migrate
    RC=$?
    echo "CALLED_ON_MIGRATE=$CALLED"
    echo "RC_ON_MIGRATE=$RC"

    CALLED=""
    cli_run
    echo "CALLED_ON_NOARG=$CALLED"

    CALLED=""
    cli_run status
    echo "CALLED_ON_OTHER=$CALLED"
) > /tmp/_a2_router_out 2>&1
source /tmp/_a2_router_out
rm -f /tmp/_a2_router_out

assert "cli_run migrate calls panel_migrate()" "$CALLED_ON_MIGRATE" "panel_migrate"
assert "cli_run migrate propagates panel_migrate()'s exit code" "$RC_ON_MIGRATE" "7"
assert "cli_run with no argument still calls main_menu() (default behaviour preserved)" "$CALLED_ON_NOARG" "main_menu"
assert "cli_run with an unrecognized argument falls back to main_menu()" "$CALLED_ON_OTHER" "main_menu"

echo ""
echo "== 6. cli_run() does NOT dispatch 'migrate' to migrate_all()/migrate_menu() (different, wider operation) =="
ROUTER_MIGRATE_CASE="$(awk '/case "\$\{1:-\}" in/,/esac/' lib/cli/router.sh)"
assert "router's migrate case does not call migrate_all" \
    "$(grep -c 'migrate_all' <<<"$ROUTER_MIGRATE_CASE")" "0"
assert "router's migrate case does not call migrate_menu" \
    "$(grep -c 'migrate_menu' <<<"$ROUTER_MIGRATE_CASE")" "0"
assert "migrate_all() remains defined and untouched in lib/migrate.sh" \
    "$(grep -c '^migrate_all() {' lib/migrate.sh)" "1"

echo ""
echo "== 7. server-manager.sh forwards argv to cli_run() =="
assert "server-manager.sh calls cli_run with \"\$@\"" \
    "$(grep -c '^cli_run "\$@"$' server-manager.sh)" "1"
assert "server-manager.sh no longer calls cli_run with no arguments" \
    "$(grep -c '^cli_run$' server-manager.sh)" "0"

echo ""
echo "== 8. no recursive remnawave_panel -> panel_migrate -> panel_menu -> remnawave_panel path =="
# Scoped to panel_migrate()'s own function body specifically (not the
# whole file) -- lib/migrate.sh legitimately mentions "server-manager.sh"
# and "do_migrate" elsewhere, in prose/history comments (top of file)
# and in migrate_copy_script()'s PUT of the *local* repo to the
# *remote* target's /root/server-manager/ (a file-path string for a
# different server, not a local re-invocation). The recursion concern
# is specifically about what panel_migrate() itself does.
PANEL_MIGRATE_BODY="$(awk '/^panel_migrate\(\) \{/,/^\}$/' lib/migrate.sh)"
assert "panel_migrate() does not call do_migrate" \
    "$(grep -c 'do_migrate' <<<"$PANEL_MIGRATE_BODY")" "0"
assert "panel_migrate() does not call cli_run" \
    "$(grep -c 'cli_run' <<<"$PANEL_MIGRATE_BODY")" "0"
assert "panel_migrate() does not itself re-invoke server-manager.sh" \
    "$(grep -c 'server-manager\.sh' <<<"$PANEL_MIGRATE_BODY")" "0"
assert "panel_migrate() calls the canonical prepare+transfer pipeline" \
    "$(grep -c 'migrate_prepare_target\|migrate_transfer_panel' <<<"$PANEL_MIGRATE_BODY")" "2"

echo ""
echo "== 9. panel_migrate() requests the 'panel' dependency-install variant, not 'full' =="
# Audit follow-up: init_ssh_helpers panel vs full is a no-op (both hit
# the same non-telemt case branch in lib/common/ssh.sh) -- the real
# difference is remote_install_deps panel vs full (extra unzip/cron/
# qrencode + /etc/hysteria for "full", none of which a Panel-only
# transfer needs). migrate_prepare_target() must receive an explicit
# "panel" argument from panel_migrate() and default to "full" so
# migrate_all()'s existing no-argument call is unaffected.
assert "panel_migrate() calls migrate_prepare_target with the 'panel' variant" \
    "$(grep -c 'migrate_prepare_target panel' <<<"$PANEL_MIGRATE_BODY")" "1"
MIGRATE_ALL_BODY="$(awk '/^migrate_all\(\) \{/,/^\}$/' lib/migrate.sh)"
assert "migrate_all() still calls migrate_prepare_target with no argument (unchanged, defaults to full)" \
    "$(grep -c 'migrate_prepare_target || return 1' <<<"$MIGRATE_ALL_BODY")" "1"
MIGRATE_PREPARE_TARGET_BODY="$(awk '/^migrate_prepare_target\(\) \{/,/^\}$/' lib/migrate.sh)"
MIGRATE_PREPARE_TARGET_CODE_ONLY="$(grep -v '^[[:space:]]*#' <<<"$MIGRATE_PREPARE_TARGET_BODY")"
assert "migrate_prepare_target() defaults its variant to 'full' (migrate_all() call site unaffected)" \
    "$(grep -c 'variant="\${1:-full}"' <<<"$MIGRATE_PREPARE_TARGET_CODE_ONLY")" "1"
assert "migrate_prepare_target() forwards the variant to remote_install_deps (code, not comments)" \
    "$(grep -c 'remote_install_deps "\$variant"' <<<"$MIGRATE_PREPARE_TARGET_CODE_ONLY")" "1"
assert "migrate_prepare_target() no longer hardcodes remote_install_deps full" \
    "$(grep -c 'remote_install_deps full' <<<"$MIGRATE_PREPARE_TARGET_CODE_ONLY")" "0"

echo ""
echo "==================================="
echo "PASS=$PASS FAIL=$FAIL"
echo "==================================="
[ "$FAIL" -eq 0 ]
