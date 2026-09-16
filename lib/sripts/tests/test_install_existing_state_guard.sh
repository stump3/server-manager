#!/bin/bash
# lib/sripts/tests/test_install_existing_state_guard.sh
#
# CONFIRMED DEFECT (this session, independently investigated from
# scratch and mechanically reproduced against the real extracted
# lib/panel/api.sh register/login block): panel_generate_env()
# (lib/panel/install.sh) unconditionally mints a fresh
# SUPERADMIN_USER/SUPERADMIN_PASS on every panel_install() run and
# never persists or re-reads them (not in .env, not anywhere else).
# remnawave-db-data is a named, non-external Docker volume
# (lib/panel/compose/common.sh) that a plain `docker compose up -d`
# (panel_setup_api(), lib/panel/api.sh) neither creates fresh nor
# wipes, so it survives a second panel_install() run untouched. If it
# already holds a superadmin from an earlier run, panel_setup_api()'s
# register-then-login fallback (POST /api/auth/register -> confirmed
# 403/E000 "already registered" -> POST /api/auth/login) logs in with
# the NEW run's credentials, which do not match the DB's, and dies.
#
# Fix: panel_install_existing_state_detected() (lib/panel/install.sh)
# checks for the remnawave-db-data volume and panel_install() calls it
# immediately after check_root, before any mutation (CLI collection,
# panel_install_prerequisites()'s package/Docker/UFW changes, SSL,
# env/compose generation, containers). This test exercises the REAL
# panel_install_existing_state_detected() and the REAL panel_install()
# (both sourced unmodified from lib/panel/install.sh) — the only
# things mocked are `docker` itself (no real Docker daemon in this
# sandbox) and panel_install()'s own downstream collaborators, so a
# real end-to-end call can be made without touching the real
# filesystem/network/packages.
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
bash -n lib/panel/install.sh 2>/tmp/_guard_synerr && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: bash -n lib/panel/install.sh"; cat /tmp/_guard_synerr; }
rm -f /tmp/_guard_synerr

echo ""
echo "== 1. source inspection: guard exists exactly once, runs before every mutation call =="
assert "panel_install_existing_state_detected() defined exactly once" \
    "$(grep -c '^panel_install_existing_state_detected()' lib/panel/install.sh)" "1"
assert "panel_install() calls the guard exactly once" \
    "$(grep -c 'if panel_install_existing_state_detected; then' lib/panel/install.sh)" "1"
GUARD_LINE=$(grep -n 'if panel_install_existing_state_detected; then' lib/panel/install.sh | head -1 | cut -d: -f1)
CHECK_ROOT_LINE=$(grep -n '^    check_root$' lib/panel/install.sh | head -1 | cut -d: -f1)
GEN_ENV_CALL_LINE=$(grep -n 'panel_generate_env "\$PANEL_DOMAIN"' lib/panel/install.sh | head -1 | cut -d: -f1)
PREREQ_CALL_LINE=$(grep -n 'panel_install_prerequisites "\$WEB_SERVER"' lib/panel/install.sh | head -1 | cut -d: -f1)
CLI_MODE_CALL_LINE=$(grep -n '^    panel_cli_select_mode$' lib/panel/install.sh | head -1 | cut -d: -f1)
assert "guard runs after check_root" "$([ "$GUARD_LINE" -gt "$CHECK_ROOT_LINE" ] && echo yes || echo no)" "yes"
assert "guard runs before CLI collection (panel_cli_select_mode)" "$([ "$GUARD_LINE" -lt "$CLI_MODE_CALL_LINE" ] && echo yes || echo no)" "yes"
assert "guard runs before panel_install_prerequisites (packages/Docker/UFW)" "$([ "$GUARD_LINE" -lt "$PREREQ_CALL_LINE" ] && echo yes || echo no)" "yes"
assert "guard runs before panel_generate_env (credential generation)" "$([ "$GUARD_LINE" -lt "$GEN_ENV_CALL_LINE" ] && echo yes || echo no)" "yes"

echo ""
echo "== 2. panel_install_existing_state_detected() in isolation (real function, mocked docker) =="
run_detected() {
    # $1: "present" | "absent" | "nodocker"
    (
        # shellcheck source=/dev/null
        source lib/panel/install.sh
        case "$1" in
            present)
                docker() { [ "$1" = "volume" ] && [ "$2" = "inspect" ] && [ "$3" = "remnawave-db-data" ]; }
                ;;
            absent)
                docker() { [ "$1" = "volume" ] && [ "$2" = "inspect" ] && return 1; }
                ;;
            nodocker)
                # No docker function defined, and this sandbox has no real
                # docker binary on PATH either (verified before writing
                # this test) -- command -v docker genuinely fails here.
                :
                ;;
        esac
        if panel_install_existing_state_detected; then echo detected; else echo not_detected; fi
    )
}
assert "volume present -> detected" "$(run_detected present)" "detected"
assert "volume absent -> not detected" "$(run_detected absent)" "not_detected"
assert "docker not installed -> not detected (fresh machine)" "$(run_detected nodocker)" "not_detected"

echo ""
echo "== 3. real panel_install(), existing state -> dies at the guard, before any mutation =="
run_install() {
    # $1: "present" | "absent" -- controls the docker mock (see above)
    # Stubs every downstream collaborator panel_install() calls after
    # the guard; each records itself to CALL_LOG so we can assert
    # exactly how far execution got. The very first post-guard call
    # (panel_cli_select_mode) exits with a distinct sentinel code once
    # logged, so the "absent" case never has to run the real
    # prerequisites/SSL/env-generation/container machinery at all.
    (
        # shellcheck source=/dev/null
        source lib/ui/output.sh
        # shellcheck source=/dev/null
        source lib/common/core.sh
        # shellcheck source=/dev/null
        source lib/panel/install.sh

        case "$1" in
            present) docker() { [ "$1" = "volume" ] && [ "$2" = "inspect" ] && [ "$3" = "remnawave-db-data" ]; } ;;
            absent)  docker() { [ "$1" = "volume" ] && [ "$2" = "inspect" ] && return 1; } ;;
        esac

        panel_cli_select_mode() { echo "panel_cli_select_mode"; exit 42; }
        panel_install_prerequisites() { echo "panel_install_prerequisites"; }
        panel_generate_env() { echo "panel_generate_env"; }

        panel_install
        echo "RC=$?"
    ) 2>&1
}

OUT_EXISTING=$(run_install present); EC_EXISTING=$?
assert "existing state: process exits 1 (die())" "$EC_EXISTING" "1"
assert "existing state: die() message present" "$(echo "$OUT_EXISTING" | grep -c 'уже установлен')" "1"
assert "existing state: panel_cli_select_mode NEVER called" "$(echo "$OUT_EXISTING" | grep -c '^panel_cli_select_mode$')" "0"
assert "existing state: panel_install_prerequisites NEVER called" "$(echo "$OUT_EXISTING" | grep -c '^panel_install_prerequisites$')" "0"
assert "existing state: panel_generate_env NEVER called (no credential generation)" "$(echo "$OUT_EXISTING" | grep -c '^panel_generate_env$')" "0"

echo ""
echo "== 4. real panel_install(), fresh machine -> passes the guard, reaches CLI collection =="
OUT_FRESH=$(run_install absent); EC_FRESH=$?
assert "fresh: reaches panel_cli_select_mode (sentinel exit 42)" "$EC_FRESH" "42"
assert "fresh: panel_cli_select_mode WAS called" "$(echo "$OUT_FRESH" | grep -c '^panel_cli_select_mode$')" "1"
assert "fresh: panel_install_prerequisites never reached (stopped at sentinel, as designed)" "$(echo "$OUT_FRESH" | grep -c '^panel_install_prerequisites$')" "0"

echo ""
echo "== 5. negative control: without the guard, the same 'existing' scenario proceeds into mutation =="
# Proves the test is load-bearing: strip the guard's death (leave
# detection itself untouched) and confirm execution now reaches past
# it, i.e. the assertions above are actually exercising the guard and
# not vacuously passing for an unrelated reason.
run_install_no_guard() {
    (
        # shellcheck source=/dev/null
        source lib/ui/output.sh
        # shellcheck source=/dev/null
        source lib/common/core.sh
        # shellcheck source=/dev/null
        source lib/panel/install.sh
        docker() { [ "$1" = "volume" ] && [ "$2" = "inspect" ] && [ "$3" = "remnawave-db-data" ]; }
        # Simulate "guard removed": force the detector to always say
        # not-detected, regardless of the (still present) volume.
        panel_install_existing_state_detected() { return 1; }
        panel_cli_select_mode() { echo "panel_cli_select_mode"; exit 42; }
        panel_install
        echo "RC=$?"
    ) 2>&1
}
OUT_NOGUARD=$(run_install_no_guard); EC_NOGUARD=$?
assert "negative control: with guard disabled, existing state now proceeds into mutation" "$EC_NOGUARD" "42"
assert "negative control: panel_cli_select_mode now reached despite existing DB state" "$(echo "$OUT_NOGUARD" | grep -c '^panel_cli_select_mode$')" "1"

echo ""
echo "== 6. panel_reinstall() call-site safety: guard does not block reinstall's own re-entry into panel_install() =="
# panel_reinstall() (lib/panel/management.sh) removes remnawave-db-data
# (docker compose down -v + docker system prune -a --volumes -f) BEFORE
# its own call to panel_install() -- by the time panel_install() runs
# there, the volume is already gone, so the guard must see "absent"
# and proceed, exactly like a fresh machine. This does not re-run
# panel_reinstall() itself (destructive, interactive, out of scope) --
# it confirms the ordering the safety argument depends on: the removal
# commands appear before the panel_install call in the real source.
REINSTALL_CALL_LINE=$(grep -n '^    panel_install$' lib/panel/management.sh | head -1 | cut -d: -f1)
REINSTALL_DOWN_LINE=$(grep -n 'docker compose down -v --rmi all --remove-orphans >/dev/null 2>&1 || true' lib/panel/management.sh | head -1 | cut -d: -f1)
assert "panel_reinstall(): volume removal happens before its panel_install() call" \
    "$([ "$REINSTALL_DOWN_LINE" -lt "$REINSTALL_CALL_LINE" ] && echo yes || echo no)" "yes"
# And functionally: after that removal, the guard (real function) must
# report not-detected, same as test 2's "absent" case already proved.
assert "post-reinstall-wipe state is indistinguishable from fresh to the guard" "$(run_detected absent)" "not_detected"

echo ""
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
