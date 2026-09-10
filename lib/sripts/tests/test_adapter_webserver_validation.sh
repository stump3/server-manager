#!/bin/bash
# lib/sripts/tests/test_adapter_webserver_validation.sh
#
# Adapter #6: lib/panel/compose/colocated.sh's panel_generate_compose_colocated()
# WEB_SERVER=2+MODE=F/J compose-generation guard moves from a raw
# `[ "$WEB_SERVER" = "2" ] && { [ "$MODE" = "F" ] || [ "$MODE" = "J" ]; }`
# to the existing, previously-unwired Core query
# lib/core/deployment.sh:core_deployment_web_server_ok().
#
# lib/panel/cli.sh:panel_cli_select_webserver()'s own former
# `[ "$MODE" = "F" ] && [ "$WEB_SERVER" = "2" ]` / J equivalent raw guard
# was a separate, independent duplicate of the same fact -- migrated in a
# later bounded stage (CLI WEB_SERVER×MODE guard -- wire to
# core_deployment_web_server_ok()), same pattern as this adapter's own
# colocated.sh migration. Section 6 below now confirms CLI's guard calls
# the accessor and no longer contains its own raw MODE comparison for
# this decision, mirroring sections 1-5's coverage of colocated.sh.
#
# Precondition note (found during Step 0, NOT a raw-MODE regression):
# panel_generate_compose() (lib/panel/install.sh:208) runs BEFORE
# core_resolve_deployment() (lib/panel/install.sh:222), so
# DEPLOYMENT_TOPOLOGY does not exist yet at this call site.
# core_deployment_web_server_ok() is a pure function of its two
# arguments (never reads a Deployment global) -- $MODE, already this
# function's own local parameter, is exactly the value
# core_resolve_deployment() would later assign to DEPLOYMENT_TOPOLOGY
# verbatim (DEPLOYMENT_TOPOLOGY="$_mode", no transformation), so passing
# $MODE directly is the accessor's real contract, not a workaround.
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

echo "== bash -n =="
for f in lib/core/deployment.sh lib/core/topology.sh lib/panel/compose/colocated.sh lib/panel/install.sh; do
    bash -n "$f" 2>/tmp/synerr && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: bash -n $f"; cat /tmp/synerr; }
done

echo ""
echo "== 1. accessor truth table: core_deployment_web_server_ok(MODE, WEB_SERVER) for all 8 combinations =="
TABLE_OUT=$(bash -c '
    source lib/core/config.sh
    source lib/core/topology.sh
    source lib/core/deployment.sh
    for MODE in 1 2 F J; do
        for WS in 1 2; do
            core_deployment_web_server_ok "$MODE" "$WS" && r="ok" || r="reject"
            echo "$MODE/$WS:$r"
        done
    done
')
assert "MODE=1,WS=1 -> ok"     "$(echo "$TABLE_OUT" | grep '^1/1:')" "1/1:ok"
assert "MODE=1,WS=2 -> ok"     "$(echo "$TABLE_OUT" | grep '^1/2:')" "1/2:ok"
assert "MODE=2,WS=1 -> ok"     "$(echo "$TABLE_OUT" | grep '^2/1:')" "2/1:ok"
assert "MODE=2,WS=2 -> ok"     "$(echo "$TABLE_OUT" | grep '^2/2:')" "2/2:ok"
assert "MODE=F,WS=1 -> ok"     "$(echo "$TABLE_OUT" | grep '^F/1:')" "F/1:ok"
assert "MODE=F,WS=2 -> reject" "$(echo "$TABLE_OUT" | grep '^F/2:')" "F/2:reject"
assert "MODE=J,WS=1 -> ok"     "$(echo "$TABLE_OUT" | grep '^J/1:')" "J/1:ok"
assert "MODE=J,WS=2 -> reject" "$(echo "$TABLE_OUT" | grep '^J/2:')" "J/2:reject"

echo ""
echo "== 2. legacy equivalence: old raw formula vs new accessor, for all 8 combinations (reject cases included) =="
EQUIV_OUT=$(bash -c '
    source lib/core/config.sh
    source lib/core/topology.sh
    source lib/core/deployment.sh
    for MODE in 1 2 F J; do
        for WS in 1 2; do
            if [ "$WS" = "2" ] && { [ "$MODE" = "F" ] || [ "$MODE" = "J" ]; }; then old="FIRES"; else old="ok"; fi
            if core_deployment_web_server_ok "$MODE" "$WS"; then new="ok"; else new="FIRES"; fi
            [ "$old" = "$new" ] && echo "$MODE/$WS:MATCH" || echo "$MODE/$WS:MISMATCH:old=$old:new=$new"
        done
    done
')
MISMATCH_COUNT=$(echo "$EQUIV_OUT" | grep -c MISMATCH)
assert "zero mismatches between old raw guard and new accessor across all 8 combinations" "$MISMATCH_COUNT" "0"
for combo in 1/1 1/2 2/1 2/2 F/1 F/2 J/1 J/2; do
    assert "legacy equivalence $combo" "$(echo "$EQUIV_OUT" | grep "^$combo:")" "$combo:MATCH"
done

echo ""
echo "== 3. production validation block: no raw MODE/WEB_SERVER leak, calls the Core accessor =="
# Scope to the migrated guard specifically, not the whole file --
# panel_compose_nginx_frontend_colocated()'s MOUNT_TARGET dispatch (its
# own, separate, legitimate [ "$MODE" = "F" ] || [ "$MODE" = "J" ] check)
# and panel_generate_compose_colocated()'s own WEB_SERVER=1-vs-caddy
# frontend dispatch are explicitly OUT OF SCOPE for Adapter #6 and must
# not be flagged here.
GUARD_REGION=$(awk '/^    # GUARD \(2026-08-31/,/^    fi$/' lib/panel/compose/colocated.sh | head -40)
GUARD_REGION_CODE=$(grep -vE '^\s*#' <<<"$GUARD_REGION")
assert "guard region is non-empty (region actually matched)" \
    "$([ -n "$GUARD_REGION" ] && echo present || echo MISSING)" "present"
assert "migrated guard's CODE (not comments) contains no raw [ \"\$MODE\" = ... ] comparison" \
    "$(grep -cE '\[ *"\$MODE" *=' <<<"$GUARD_REGION_CODE")" "0"
assert "migrated guard's CODE contains no raw [ \"\$WEB_SERVER\" = ... ] comparison" \
    "$(grep -cE '\[ *"\$WEB_SERVER" *=' <<<"$GUARD_REGION_CODE")" "0"
assert "migrated guard calls the Core accessor with (MODE, WEB_SERVER)" \
    "$(grep -c 'core_deployment_web_server_ok "\$MODE" "\$WEB_SERVER"' <<<"$GUARD_REGION_CODE")" "1"
assert "migrated guard still calls err() on rejection (exit behavior/error text preserved)" \
    "$(grep -c 'err "Variant \$MODE требует nginx' <<<"$GUARD_REGION_CODE")" "1"
# Other, non-migrated MODE checks in this same file must still exist
# (this test must not accidentally demand the whole file be MODE-blind --
# only the migrated responsibility).
assert "panel_compose_nginx_frontend_colocated()'s own, separate MODE dispatch is untouched (out of scope)" \
    "$(grep -c '\[ "\$MODE" = "F" \] || \[ "\$MODE" = "J" \]' lib/panel/compose/colocated.sh)" "2"
# (one occurrence remains in panel_compose_nginx_frontend_colocated()'s
# MOUNT_TARGET dispatch; one in this test file's own EQUIV_OUT reference
# formula above matches the *doc comment* wording, not code -- verified
# directly against the file, not this test's own heredoc.)

echo ""
echo "== 4. false-positive guards: missing accessor / deleted guard / wrong-argument call must all FAIL =="
# 4a. Accessor missing entirely -> the table/equivalence checks above
# would already fail (command not found -> false for every row), but
# confirm explicitly that this test doesn't silently pass on an absent
# accessor by checking its presence directly.
assert "core_deployment_web_server_ok() actually exists in lib/core/deployment.sh" \
    "$(grep -c '^core_deployment_web_server_ok()' lib/core/deployment.sh)" "1"
# 4b. Guard block removed entirely from colocated.sh -> must not silently
# pass as "no raw MODE/WEB_SERVER found".
assert "the guard's err() call is still present at all (guard not silently deleted)" \
    "$(grep -c 'Caddy не поддерживает nginx stream{}-маршрутизацию' lib/panel/compose/colocated.sh)" "1"
# 4c. Call must pass exactly two arguments in the right order (MODE then
# WEB_SERVER) -- a call with swapped or missing arguments would silently
# change the truth table without tripping the "raw MODE/WEB_SERVER" leak
# check above.
assert "accessor call has exactly two arguments, in the order (MODE, WEB_SERVER)" \
    "$(grep -c 'core_deployment_web_server_ok "\$MODE" "\$WEB_SERVER"' lib/panel/compose/colocated.sh)" "1"
assert "accessor is NOT called with arguments swapped (WEB_SERVER, MODE)" \
    "$(grep -c 'core_deployment_web_server_ok "\$WEB_SERVER" "\$MODE"' lib/panel/compose/colocated.sh)" "0"

echo ""
echo "== 5. negative mutation: force the accessor to return the OPPOSITE result, confirm production validation is load-bearing on it =="
cp lib/core/deployment.sh /tmp/_deployment6_backup.sh
# Invert the accessor's final boolean: `[ "$_web_server" != "2" ]` ->
# `[ "$_web_server" = "2" ]` -- the unique line deciding the accepted/
# rejected outcome once nginx-stream is required.
awk '
    BEGIN{n=0}
    /\[ "\$_web_server" != "2" \]/{
        n++
        if (n==1) { sub(/!= "2"/, "= \"2\""); }
    }
    {print}
' lib/core/deployment.sh > /tmp/_deployment6_mutated.sh

MUTATION_HIT_COUNT="$(grep -c "\[ \"\$_web_server\" = \"2\" \]" /tmp/_deployment6_mutated.sh)"
assert "negative-mutation precondition: the targeted comparison was actually found and inverted exactly once" \
    "$MUTATION_HIT_COUNT" "1"

if [ "$MUTATION_HIT_COUNT" = "1" ]; then
    cp /tmp/_deployment6_mutated.sh lib/core/deployment.sh
    NEG_OUT=$(bash -c '
        source lib/core/config.sh
        source lib/core/topology.sh
        source lib/core/deployment.sh
        # MODE=F, WEB_SERVER=1 used to be accepted (ok) -- with the
        # accessor inverted, it must now be rejected.
        core_deployment_web_server_ok "F" "1" && echo "ok" || echo "reject"
    ' 2>/dev/null)
    cp /tmp/_deployment6_backup.sh lib/core/deployment.sh
else
    NEG_OUT="MUTATION_NOT_APPLIED"
fi
DIFF_AFTER_RESTORE="$(diff -q /tmp/_deployment6_backup.sh lib/core/deployment.sh >/dev/null 2>&1 && echo identical || echo DIFFERS)"
rm -f /tmp/_deployment6_backup.sh /tmp/_deployment6_mutated.sh

assert "inverted accessor flips MODE=F,WEB_SERVER=1 from ok to reject (proves colocated.sh's guard is load-bearing on the accessor, not a no-op)" \
    "$NEG_OUT" "reject"
assert "self-repair: deployment.sh restored byte-identical to its pre-mutation content" \
    "$DIFF_AFTER_RESTORE" "identical"
assert "self-repair: bash -n deployment.sh still passes after restore" \
    "$(bash -n lib/core/deployment.sh; echo $?)" "0"

echo ""
echo "== 6. panel_cli_select_webserver()'s own CLI-time guard now calls the same Core accessor (migrated, no longer a separate raw table) =="
# Scope to the target function only -- other MODE comparisons in cli.sh
# (panel_cli_select_mode(), panel_cli_select_f_xhttp(), summary/label
# logic) are explicitly out of scope for this migration and must not be
# flagged here.
CLI_FUNC_REGION=$(awk '/^panel_cli_select_webserver\(\) \{/,/^\}$/' lib/panel/cli.sh)
assert "panel_cli_select_webserver() region is non-empty (region actually matched)" \
    "$([ -n "$CLI_FUNC_REGION" ] && echo present || echo MISSING)" "present"
assert "cli.sh's guard calls the Core accessor with (MODE, WEB_SERVER) exactly once" \
    "$(grep -c 'core_deployment_web_server_ok "\$MODE" "\$WEB_SERVER"' <<<"$CLI_FUNC_REGION")" "1"
assert "cli.sh's former raw MODE=F+WEB_SERVER=2 compatibility comparison is gone" \
    "$(grep -c '\[ "\$MODE" = "F" \] && \[ "\$WEB_SERVER" = "2" \]' <<<"$CLI_FUNC_REGION")" "0"
assert "cli.sh's former raw MODE=J+WEB_SERVER=2 compatibility comparison is gone" \
    "$(grep -c '\[ "\$MODE" = "J" \] && \[ "\$WEB_SERVER" = "2" \]' <<<"$CLI_FUNC_REGION")" "0"
assert "cli.sh still calls err() on rejection (exit behavior preserved)" \
    "$(grep -c 'err "' <<<"$CLI_FUNC_REGION")" "3"

echo ""
echo "== 7. call order / call-site sanity (documented precondition, not a live global read) =="
GEN_COMPOSE_LINE=$(grep -n 'panel_generate_compose "\$WEB_SERVER"' lib/panel/install.sh | head -1 | cut -d: -f1)
RESOLVE_LINE=$(grep -n 'core_resolve_deployment "\$MODE"' lib/panel/install.sh | head -1 | cut -d: -f1)
assert "both panel_generate_compose() and core_resolve_deployment() call sites found (single occurrence each)" \
    "$(grep -c 'panel_generate_compose "\$WEB_SERVER"' lib/panel/install.sh):$(grep -c 'core_resolve_deployment "\$MODE"' lib/panel/install.sh)" \
    "1:1"
# Documents (does not silently assume) that DEPLOYMENT_TOPOLOGY is NOT
# yet resolved when the migrated guard runs -- this is precisely why
# $MODE (a local parameter) is passed instead of $DEPLOYMENT_TOPOLOGY.
[ -n "$GEN_COMPOSE_LINE" ] && [ -n "$RESOLVE_LINE" ] && [ "$GEN_COMPOSE_LINE" -lt "$RESOLVE_LINE" ] \
    && PASS=$((PASS+1)) \
    || { FAIL=$((FAIL+1)); echo "  FAIL: panel_generate_compose (line $GEN_COMPOSE_LINE) is not called before core_resolve_deployment (line $RESOLVE_LINE) -- the documented precondition for using \$MODE instead of \$DEPLOYMENT_TOPOLOGY no longer holds, re-verify the call site"; }

echo ""
echo "==================================="
echo "PASS=$PASS FAIL=$FAIL"
echo "==================================="
[ "$FAIL" -eq 0 ]
