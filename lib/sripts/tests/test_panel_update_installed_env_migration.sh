#!/bin/bash
# lib/sripts/tests/test_panel_update_installed_env_migration.sh
#
# CONFIRMED REGRESSION (migration-lifecycle audit): commit 9d6e12d
# ("Refactor migration script for improved service transfer")
# replaced lib/panel/migrate.sh's entire content -- at the time, that
# file's ONLY function -- with a copy of the unrelated host-to-host
# migration pipeline (panel_migrate/migrate_all/migrate_transfer_panel/
# etc., now byte-identical to lib/migrate.sh), and never carried
# panel_migrate_env_for_remnawave_v2() forward anywhere.
# lib/panel/management.sh:panel_update_installed() kept calling it
# unconditionally, so after that commit landed, EVERY update on an
# existing Remnawave <=2.8.1 install died with "command not found" at
# that line, before ever reaching `"$PANEL_MGMT_SCRIPT" update` --
# reproduced directly against the real module loader (see section 1).
#
# Fix: restored the function verbatim into lib/panel/management.sh,
# immediately before its sole caller (not back into
# lib/panel/migrate.sh -- see that commit's own analysis for why that
# placement is exactly the naming collision that caused this to go
# unnoticed). The standalone copy in lib/panel/mgmt_script.sh
# (_migrate_env_for_remnawave_v2, Contract 8) was never touched by the
# regression and needs no fix -- only its cross-reference comment was
# updated to point at the function's new home.
#
# Incidentally caught while writing this test (section 2b): the
# restored function's last statement was `[ "$removed" = "1" ] && ok
# ...` with no trailing `return 0` -- its own exit status (1, when no
# SWAGGER_PATH/SCALAR_PATH/IS_DOCS_ENABLED/JWT_API_TOKENS_SECRET needed
# removal) silently became the function's return value even on a
# fully successful secret-rename/dedup-only run, which made
# panel_update_installed() wrongly `return 1` and skip
# `"$PANEL_MGMT_SCRIPT" update` for that common case. Present verbatim
# in the pre-9d6e12d historical implementation this was restored from,
# so it predates and is independent of the missing-function
# regression -- fixed in both copies (management.sh and the
# mgmt_script.sh standalone one, Contract 8) with an explicit
# trailing `return 0`.
#
# Same convention as test_install_existing_state_guard.sh /
# test_panel_setup_api_create_rollback.sh: the REAL, unmodified
# functions are sourced via the actual module loader (same file list
# and order as server-manager.sh) and called directly against a real
# /opt/remnawave/.env in this sandbox; only $PANEL_MGMT_SCRIPT itself
# is mocked (no real Panel/Docker in this sandbox).
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
for f in lib/panel/management.sh lib/panel/mgmt_script.sh; do
    bash -n "$f" 2>/tmp/_synerr && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: bash -n $f"; cat /tmp/_synerr; }
done
rm -f /tmp/_synerr

echo ""
echo "== 1. runtime load order: panel_migrate_env_for_remnawave_v2 is actually defined after a full production-equivalent module load =="
LOAD_LOG=$(
    for m in core/config core/deployment core/runtime_component core/adapter_webserver core/adapter_reality core/port_allocation ui/output common panel telemt hysteria migrate; do
        # shellcheck disable=SC1090
        source "lib/${m}.sh" 2>/dev/null
    done
    declare -f panel_migrate_env_for_remnawave_v2 >/dev/null 2>&1 && echo DEFINED || echo UNDEFINED
    declare -f panel_update_installed >/dev/null 2>&1 && echo DEFINED || echo UNDEFINED
    declare -f migrate_transfer_panel >/dev/null 2>&1 && echo DEFINED || echo UNDEFINED
)
assert "panel_migrate_env_for_remnawave_v2 defined at runtime (this exact check catches the regression)" \
    "$(echo "$LOAD_LOG" | sed -n '1p')" "DEFINED"
assert "panel_update_installed defined at runtime" "$(echo "$LOAD_LOG" | sed -n '2p')" "DEFINED"
assert "migrate_transfer_panel (unrelated host-migration fn) still defined too" "$(echo "$LOAD_LOG" | sed -n '3p')" "DEFINED"

assert "defined exactly once in lib/panel/management.sh" \
    "$(grep -c '^panel_migrate_env_for_remnawave_v2()' lib/panel/management.sh)" "1"
assert "redundant lib/panel/migrate.sh is absent (would recreate the naming collision if reintroduced)" \
    "$(test ! -e lib/panel/migrate.sh && echo 0 || echo 1)" "0"
assert "restored before its sole caller, panel_update_installed" \
    "$([ "$(grep -n '^panel_migrate_env_for_remnawave_v2()' lib/panel/management.sh | cut -d: -f1)" -lt \
        "$(grep -n '^panel_update_installed()' lib/panel/management.sh | cut -d: -f1)" ] && echo yes || echo no)" "yes"

echo ""
echo "== 2. panel_update_installed() end-to-end (real function, mocked \$PANEL_MGMT_SCRIPT, real /opt/remnawave/.env) =="

MOCK_SCRIPT=$(mktemp)
cat > "$MOCK_SCRIPT" << 'EOF'
#!/bin/bash
echo "MGMT_SCRIPT_CALL:$1" >> "$CALL_LOG"
exit "${MOCK_MGMT_EXIT:-0}"
EOF
chmod +x "$MOCK_SCRIPT"

run_update() {
    # $1: contents to write to /opt/remnawave/.env ("" = do not create the file)
    local env_body="$1"
    local log; log=$(mktemp)
    mkdir -p /opt/remnawave
    rm -f /opt/remnawave/.env
    [ -n "$env_body" ] && printf '%s\n' "$env_body" > /opt/remnawave/.env
    (
        # shellcheck disable=SC1091
        source lib/ui/output.sh
        # shellcheck disable=SC1091
        source lib/panel/management.sh
        PANEL_MGMT_SCRIPT="$MOCK_SCRIPT"
        CALL_LOG="$log"
        export CALL_LOG MOCK_MGMT_EXIT="${MOCK_MGMT_EXIT:-0}"
        panel_update_installed
        echo "RC=$?" >> "$log"
    ) >/tmp/_pui_stdout 2>/tmp/_pui_stderr
    cat "$log"
    rm -f "$log"
}

echo "--- 2a. full input->output transformation, both secret-rename and legacy-key removal ---"
OUT=$(run_update $'JWT_AUTH_SECRET=abc\nSWAGGER_PATH=/x\nSCALAR_PATH=/y\nIS_DOCS_ENABLED=true\nJWT_API_TOKENS_SECRET=old')
assert "2a: RC=0" "$(grep -c '^RC=0$' <<<"$OUT")" "1"
assert "2a: APP_SECRET=abc present after migration" "$(grep -c '^APP_SECRET=abc$' /opt/remnawave/.env)" "1"
assert "2a: JWT_AUTH_SECRET gone" "$(grep -c '^JWT_AUTH_SECRET=' /opt/remnawave/.env)" "0"
assert "2a: JWT_API_TOKENS_SECRET gone" "$(grep -c '^JWT_API_TOKENS_SECRET=' /opt/remnawave/.env)" "0"
assert "2a: SWAGGER_PATH gone" "$(grep -c '^SWAGGER_PATH=' /opt/remnawave/.env)" "0"
assert "2a: SCALAR_PATH gone" "$(grep -c '^SCALAR_PATH=' /opt/remnawave/.env)" "0"
assert "2a: IS_DOCS_ENABLED gone" "$(grep -c '^IS_DOCS_ENABLED=' /opt/remnawave/.env)" "0"
assert "2a: backup called before update (order preserved)" \
    "$(grep -n 'MGMT_SCRIPT_CALL:' <<<"$OUT" | head -1 | grep -c 'backup$')" "1"
assert "2a: update called exactly once" "$(grep -c '^MGMT_SCRIPT_CALL:update$' <<<"$OUT")" "1"

echo ""
echo "--- 2b. JWT_AUTH_SECRET + APP_SECRET both already present -- dedup, not overwrite ---"
OUT=$(run_update $'JWT_AUTH_SECRET=old-dup\nAPP_SECRET=keep-me')
assert "2b: RC=0" "$(grep -c '^RC=0$' <<<"$OUT")" "1"
assert "2b: APP_SECRET keeps its existing value (not clobbered by the dup)" \
    "$(grep -c '^APP_SECRET=keep-me$' /opt/remnawave/.env)" "1"
assert "2b: duplicate JWT_AUTH_SECRET line removed" "$(grep -c '^JWT_AUTH_SECRET=' /opt/remnawave/.env)" "0"

echo ""
echo "--- 2c. already-migrated .env (no legacy keys at all) -- no-op, update still proceeds ---"
OUT=$(run_update $'APP_SECRET=already-current\nSOME_OTHER_VAR=1')
assert "2c: RC=0" "$(grep -c '^RC=0$' <<<"$OUT")" "1"
assert "2c: .env left byte-for-byte unchanged" \
    "$(printf 'APP_SECRET=already-current\nSOME_OTHER_VAR=1\n' | diff -q - /opt/remnawave/.env >/dev/null 2>&1 && echo same || echo different)" "same"
assert "2c: update still called" "$(grep -c '^MGMT_SCRIPT_CALL:update$' <<<"$OUT")" "1"

echo ""
echo "--- 2d. failure path: no .env at all -- migration fails, update MUST NOT run, RC non-zero ---"
OUT=$(run_update "")
assert "2d: RC=1 (propagated, not masked)" "$(grep -c '^RC=1$' <<<"$OUT")" "1"
assert "2d: backup was still attempted (runs before the migration gate)" \
    "$(grep -c '^MGMT_SCRIPT_CALL:backup$' <<<"$OUT")" "1"
assert "2d: update NEVER called (failure must block it)" "$(grep -c '^MGMT_SCRIPT_CALL:update$' <<<"$OUT")" "0"

rm -f /tmp/_pui_stdout /tmp/_pui_stderr "$MOCK_SCRIPT"
rm -rf /opt/remnawave

echo ""
echo "== 3. Contract 8: standalone mgmt_script.sh copy still handles the same legacy-key set =="
for key in JWT_AUTH_SECRET APP_SECRET JWT_API_TOKENS_SECRET SWAGGER_PATH SCALAR_PATH IS_DOCS_ENABLED; do
    assert "management.sh's copy references $key" \
        "$(awk '/^panel_migrate_env_for_remnawave_v2\(\)/,/^}/' lib/panel/management.sh | grep -c "$key")" \
        "$(awk '/^panel_migrate_env_for_remnawave_v2\(\)/,/^}/' lib/panel/management.sh | grep -c "$key")"
    A=$(awk '/^panel_migrate_env_for_remnawave_v2\(\)/,/^}/' lib/panel/management.sh | grep -c "$key")
    B=$(awk '/^_migrate_env_for_remnawave_v2\(\)/,/^}/' lib/panel/mgmt_script.sh | grep -c "$key")
    assert "$key handled the same number of times in both copies" "$A" "$B"
done

echo ""
echo "==================================="
echo "PASS=$PASS FAIL=$FAIL"
echo "==================================="
[ "$FAIL" -eq 0 ]
