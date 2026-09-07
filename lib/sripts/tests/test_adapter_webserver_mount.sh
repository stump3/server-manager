#!/bin/bash
# lib/sripts/tests/test_adapter_webserver_mount.sh
#
# Adapter #7: lib/panel/compose/colocated.sh's
# panel_compose_nginx_frontend_colocated() MOUNT_TARGET decision (does this
# topology need a top-level nginx.conf, to own a stream{} block, vs
# conf.d/default.conf) moves from a raw
# `[ "$MODE" = "F" ] || [ "$MODE" = "J" ]` to the existing,
# already-wired-in-this-file-once-before (Adapter #6) Core query
# lib/core/topology.sh:core_topology_requires_nginx_stream().
#
# NOT the same guard as this same file's own Adapter #6 WEB_SERVER
# compatibility check (`core_deployment_web_server_ok "$MODE" "$WEB_SERVER"`,
# a few lines below MOUNT_TARGET's decision) -- that one is a different
# decision (whether WEB_SERVER=2/Caddy is even allowed for this MODE) and
# is explicitly OUT OF SCOPE here, confirmed untouched in section 3 below.
#
# Precondition note (same as Adapter #6, re-verified independently here,
# not assumed carried over): panel_generate_compose() (lib/panel/install.sh:208)
# runs BEFORE core_resolve_deployment() (lib/panel/install.sh:222), so
# DEPLOYMENT_TOPOLOGY does not exist yet at this call site.
# core_topology_requires_nginx_stream() is a pure function of its own
# single argument (delegates to core_topology_public_ingress_owner(),
# itself a pure case-statement, no global reads) -- $MODE, already this
# function's own local parameter, is the correct, byte-identical input
# either way.
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
for f in lib/core/topology.sh lib/panel/compose/colocated.sh lib/panel/compose.sh lib/panel/install.sh; do
    bash -n "$f" 2>/tmp/synerr7 && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: bash -n $f"; cat /tmp/synerr7; }
done

# Extract the REAL decision snippet straight out of colocated.sh (not a
# hand-copied re-implementation) -- from the function's opening brace to
# the line right before its heredoc starts -- and wrap it as a standalone
# function so it can be exercised directly against a real or mutated
# topology.sh. This exercises the actual production lines, not a proxy
# for them.
extract_decision_snippet() {
    awk '
        /^panel_compose_nginx_frontend_colocated\(\) \{$/ { grab=1; next }
        grab && /^    cat << EOFYML$/ { exit }
        grab { print }
    ' lib/panel/compose/colocated.sh
}

DECISION_SNIPPET="$(extract_decision_snippet)"

assert "decision snippet was actually extracted (non-empty -- awk range matched)" \
    "$([ -n "$DECISION_SNIPPET" ] && echo present || echo MISSING)" "present"
assert "extracted snippet's CODE (not comments) calls core_topology_requires_nginx_stream (sanity check on the extraction itself)" \
    "$(grep -vE '^\s*#' <<<"$DECISION_SNIPPET" | grep -c 'core_topology_requires_nginx_stream')" "1"

# Build a runnable wrapper: the extracted snippet plus a trailing echo of
# the variable it sets. This is real production code, run for real.
run_real_decision() {
    local _topology_file="$1" _mode="$2"
    bash -c '
        source "'"$_topology_file"'"
        _run() {
            '"$DECISION_SNIPPET"'
            echo "$MOUNT_TARGET"
        }
        _run "'"$_mode"'" ""
    ' 2>/dev/null
}

echo ""
echo "== 1. truth table 4/4: real extracted production code vs core_topology_requires_nginx_stream =="
declare -A EXPECTED=( [1]="conf.d/default.conf" [2]="conf.d/default.conf" [F]="nginx.conf" [J]="nginx.conf" )
for MODE in 1 2 F J; do
    ACTUAL="$(run_real_decision lib/core/topology.sh "$MODE")"
    assert "MODE=$MODE -> ${EXPECTED[$MODE]}" "$ACTUAL" "${EXPECTED[$MODE]}"
done

echo ""
echo "== 2. legacy equivalence: old raw F/J formula vs new accessor-driven real code, for all 4 MODEs =="
for MODE in 1 2 F J; do
    if [ "$MODE" = "F" ] || [ "$MODE" = "J" ]; then OLD="nginx.conf"; else OLD="conf.d/default.conf"; fi
    NEW="$(run_real_decision lib/core/topology.sh "$MODE")"
    assert "legacy equivalence MODE=$MODE (old=$OLD new=$NEW)" "$NEW" "$OLD"
done

echo ""
echo "== 3. production code: no raw MODE leak in the migrated decision, calls the Core accessor, Adapter #6 guard untouched =="
DECISION_CODE_ONLY=$(grep -vE '^\s*#' <<<"$DECISION_SNIPPET")
assert "migrated decision's CODE (not comments) contains no raw [ \"\$MODE\" = ... ] comparison" \
    "$(grep -cE '\[ *"\$MODE" *=' <<<"$DECISION_CODE_ONLY")" "0"
assert "migrated decision calls core_topology_requires_nginx_stream with \$MODE" \
    "$(grep -c 'core_topology_requires_nginx_stream "\$MODE"' <<<"$DECISION_CODE_ONLY")" "1"
assert "migrated decision does NOT read \$DEPLOYMENT_TOPOLOGY" \
    "$(grep -c 'DEPLOYMENT_TOPOLOGY' <<<"$DECISION_CODE_ONLY")" "0"
assert "old raw '[ \"\$MODE\" = \"F\" ] || [ \"\$MODE\" = \"J\" ]' formula is gone from this decision's CODE" \
    "$(grep -c '\[ "\$MODE" = "F" \] || \[ "\$MODE" = "J" \]' <<<"$DECISION_CODE_ONLY")" "0"
# Adapter #6's own, separate WEB_SERVER-compatibility guard lives a few
# lines further down in the SAME file and must be untouched by this
# change -- confirm it is still exactly as Adapter #6 left it.
assert "Adapter #6's own core_deployment_web_server_ok(\$MODE, \$WEB_SERVER) guard is untouched, still present exactly once" \
    "$(grep -c 'core_deployment_web_server_ok "\$MODE" "\$WEB_SERVER"' lib/panel/compose/colocated.sh)" "1"

echo ""
echo "== 4. negative mutation: invert core_topology_requires_nginx_stream's own comparison, confirm the REAL production code flips =="
cp lib/core/topology.sh /tmp/_topology7_backup.sh
awk '
    BEGIN{n=0}
    /\[ "\$_owner" = "nginx-stream" \]/{
        n++
        if (n==1) { sub(/= "nginx-stream"/, "!= \"nginx-stream\""); }
    }
    {print}
' lib/core/topology.sh > /tmp/_topology7_mutated.sh

MUTATION_HIT_COUNT="$(grep -c '\[ "\$_owner" != "nginx-stream" \]' /tmp/_topology7_mutated.sh)"
assert "negative-mutation precondition: the targeted comparison was actually found and inverted exactly once" \
    "$MUTATION_HIT_COUNT" "1"

if [ "$MUTATION_HIT_COUNT" = "1" ]; then
    # MODE=F used to resolve to nginx.conf -- with the accessor inverted,
    # the REAL extracted production snippet (unchanged) must now resolve
    # to conf.d/default.conf, proving the decision is actually
    # load-bearing on the accessor and not a coincidental match.
    MUT_F="$(run_real_decision /tmp/_topology7_mutated.sh "F")"
    MUT_1="$(run_real_decision /tmp/_topology7_mutated.sh "1")"
else
    MUT_F="MUTATION_NOT_APPLIED"
    MUT_1="MUTATION_NOT_APPLIED"
fi
DIFF_AFTER_MUTATION_CHECK="$(diff -q /tmp/_topology7_backup.sh lib/core/topology.sh >/dev/null 2>&1 && echo identical || echo DIFFERS)"
rm -f /tmp/_topology7_backup.sh /tmp/_topology7_mutated.sh

assert "inverted accessor flips MODE=F from nginx.conf to conf.d/default.conf (proves the real decision is load-bearing on the accessor)" \
    "$MUT_F" "conf.d/default.conf"
assert "inverted accessor flips MODE=1 from conf.d/default.conf to nginx.conf (both directions checked, not just one)" \
    "$MUT_1" "nginx.conf"
assert "the real lib/core/topology.sh on disk was never touched by this mutation (mutation happened only in /tmp copies)" \
    "$DIFF_AFTER_MUTATION_CHECK" "identical"
assert "bash -n lib/core/topology.sh still passes after the mutation exercise" \
    "$(bash -n lib/core/topology.sh; echo $?)" "0"

echo ""
echo "== 5. missing accessor: neutralize core_topology_requires_nginx_stream entirely, confirm this test's own truth table actually FAILS to match expected =="
cp lib/core/topology.sh /tmp/_topology7_backup2.sh
# Rename the function definition so the name the production code calls is
# simply undefined -- not a grep-only stand-in, an actual removal of the
# callable symbol.
sed 's/^core_topology_requires_nginx_stream() {/core_topology_requires_nginx_stream_DISABLED() {/' \
    lib/core/topology.sh > /tmp/_topology7_disabled.sh
DISABLE_HIT_COUNT="$(grep -c '^core_topology_requires_nginx_stream() {' /tmp/_topology7_disabled.sh)"
assert "missing-accessor precondition: the function definition was actually renamed away (0 remaining)" \
    "$DISABLE_HIT_COUNT" "0"

if [ "$DISABLE_HIT_COUNT" = "0" ]; then
    MISSING_F="$(run_real_decision /tmp/_topology7_disabled.sh "F")"
    MISSING_J="$(run_real_decision /tmp/_topology7_disabled.sh "J")"
else
    MISSING_F="ACCESSOR_STILL_PRESENT"
    MISSING_J="ACCESSOR_STILL_PRESENT"
fi
DIFF_AFTER_DISABLE_CHECK="$(diff -q /tmp/_topology7_backup2.sh lib/core/topology.sh >/dev/null 2>&1 && echo identical || echo DIFFERS)"
rm -f /tmp/_topology7_backup2.sh /tmp/_topology7_disabled.sh

# With the accessor undefined, `core_topology_requires_nginx_stream "$MODE"`
# in the `if` position hits "command not found" (exit 127), which the
# `if` treats as false -- so MOUNT_TARGET silently stays at its default
# "conf.d/default.conf" for EVERY mode, including F and J. This is the
# exact silent-wrong-config failure mode this whole adapter series exists
# to prevent, and this section proves that if the accessor were ever
# accidentally deleted or renamed, this focused test's own truth-table
# assertions (section 1, expecting "nginx.conf" for F/J) would fail loudly
# rather than silently passing.
assert "with the accessor missing, MODE=F wrongly resolves to conf.d/default.conf (mismatches section 1's expectation of nginx.conf -- proves this test would catch a missing accessor)" \
    "$MISSING_F" "conf.d/default.conf"
assert "with the accessor missing, MODE=J wrongly resolves to conf.d/default.conf (same proof, second data point)" \
    "$MISSING_J" "conf.d/default.conf"
assert "the real lib/core/topology.sh on disk was never touched by this missing-accessor exercise" \
    "$DIFF_AFTER_DISABLE_CHECK" "identical"
assert "bash -n lib/core/topology.sh still passes after the missing-accessor exercise" \
    "$(bash -n lib/core/topology.sh; echo $?)" "0"

echo ""
echo "== 6. call order / call-site sanity (documented precondition, not a live global read) =="
GEN_COMPOSE_LINE=$(grep -n 'panel_generate_compose "\$WEB_SERVER"' lib/panel/install.sh | head -1 | cut -d: -f1)
RESOLVE_LINE=$(grep -n 'core_resolve_deployment "\$MODE"' lib/panel/install.sh | head -1 | cut -d: -f1)
assert "both panel_generate_compose() and core_resolve_deployment() call sites found (single occurrence each)" \
    "$(grep -c 'panel_generate_compose "\$WEB_SERVER"' lib/panel/install.sh):$(grep -c 'core_resolve_deployment "\$MODE"' lib/panel/install.sh)" \
    "1:1"
[ -n "$GEN_COMPOSE_LINE" ] && [ -n "$RESOLVE_LINE" ] && [ "$GEN_COMPOSE_LINE" -lt "$RESOLVE_LINE" ] \
    && PASS=$((PASS+1)) \
    || { FAIL=$((FAIL+1)); echo "  FAIL: panel_generate_compose (line $GEN_COMPOSE_LINE) is not called before core_resolve_deployment (line $RESOLVE_LINE) -- the documented precondition for using \$MODE instead of \$DEPLOYMENT_TOPOLOGY no longer holds, re-verify the call site"; }
# The call chain from panel_generate_compose() down to this specific
# decision point, confirmed by grep at each hop (not assumed):
assert "panel_generate_compose() calls panel_generate_compose_colocated() (dispatcher hop 1)" \
    "$(grep -vE '^\s*#' lib/panel/compose.sh | grep -c 'panel_generate_compose_colocated')" "1"
assert "panel_generate_compose_colocated() calls panel_compose_nginx_frontend_colocated() with \$MODE (dispatcher hop 2)" \
    "$(grep -c 'panel_compose_nginx_frontend_colocated "\$MODE"' lib/panel/compose/colocated.sh)" "1"

echo ""
echo "==================================="
echo "PASS=$PASS FAIL=$FAIL"
echo "==================================="
[ "$FAIL" -eq 0 ]
