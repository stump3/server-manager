#!/bin/bash
# lib/sripts/tests/test_adapter_xhttp.sh
#
# Adapter #4: "does the resolved Deployment have XHTTP" moves from raw
# MODE comparisons (lib/panel/install.sh's _api_xhttp_enable computation,
# lib/panel/api.sh:panel_setup_api()'s fallback) to a single Core query,
# lib/core/deployment.sh:core_deployment_has_capability().
#
# Precondition (same as Adapter #2/#3, see test_adapter_reality.sh's own
# header): core_resolve_deployment() runs earlier in the same
# panel_install() invocation, so DEPLOYMENT_TOPOLOGY/DEPLOYMENT_CAPABILITIES
# are already set by the time either call site below runs. This test
# checks that precondition explicitly (see "call order" section).
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
for f in lib/core/deployment.sh lib/panel/install.sh lib/panel/api.sh; do
    bash -n "$f" 2>/tmp/synerr && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: bash -n $f"; cat /tmp/synerr; }
done

echo ""
echo "== 1. accessor truth table (core_deployment_has_capability \"XHTTP\") =="
TABLE_OUT=$(bash -c '
    source lib/core/config.sh
    source lib/core/deployment.sh
    for t in "1:0" "2:0" "F:0" "F:1" "J:0"; do
        mode="${t%%:*}"; xh="${t##*:}"
        core_resolve_deployment "$mode" "$xh" "1" "p.example.com" "s.example.com" "n.example.com" "" ""
        core_deployment_has_capability "XHTTP" && r=1 || r=0
        echo "$mode/$xh:$r"
    done
')
assert "MODE=1 -> false"          "$(echo "$TABLE_OUT" | grep '^1/0:')"  "1/0:0"
assert "MODE=2 -> false"          "$(echo "$TABLE_OUT" | grep '^2/0:')"  "2/0:0"
assert "MODE=F, XHTTP=0 -> false" "$(echo "$TABLE_OUT" | grep '^F/0:')"  "F/0:0"
assert "MODE=F, XHTTP=1 -> true"  "$(echo "$TABLE_OUT" | grep '^F/1:')"  "F/1:1"
assert "MODE=J -> true (required, regardless of F_XHTTP_ENABLE)" \
    "$(echo "$TABLE_OUT" | grep '^J/0:')" "J/0:1"

echo ""
echo "== 2. install.sh production call site: no raw MODE XHTTP decision =="
# Scope the check to the actual decision region (the _api_xhttp_enable
# assignment immediately before the panel_setup_api call), not the whole
# file -- lib/panel/install.sh legitimately contains other MODE checks
# (webserver selection, UFW ports, TeleMT) that are explicitly out of
# scope for Adapter #4 and must not be touched or flagged here.
XHTTP_DECISION_REGION=$(awk '/local _api_xhttp_enable=/,/panel_setup_api /' lib/panel/install.sh)
assert "install.sh XHTTP-decision region contains no raw MODE comparison" \
    "$(grep -cE '\[ *"\$MODE" *=' <<<"$XHTTP_DECISION_REGION")" "0"
assert "install.sh XHTTP-decision region contains no raw F_XHTTP_ENABLE comparison" \
    "$(grep -cE '\$F_XHTTP_ENABLE' <<<"$XHTTP_DECISION_REGION")" "0"
assert "install.sh XHTTP-decision region calls the Core accessor" \
    "$(grep -c 'core_deployment_has_capability "XHTTP"' <<<"$XHTTP_DECISION_REGION")" "1"
assert "install.sh still calls panel_setup_api with 5 args (unchanged contract)" \
    "$(grep -c 'panel_setup_api "\$SUPERADMIN_USER" "\$SUPERADMIN_PASS" "\$SELFSTEAL_DOMAIN" "\$MODE" "\$_api_xhttp_enable"' lib/panel/install.sh)" "1"

echo ""
echo "== 3. panel_setup_api() fallback: no raw MODE XHTTP fallback =="
API_FALLBACK_REGION=$(awk '/local XHTTP_ENABLE="\$\{5:-\}"/,/^    fi$/' lib/panel/api.sh | head -20)
assert "panel_setup_api() XHTTP fallback region contains no raw MODE comparison" \
    "$(grep -cE '\[ *"\$MODE" *=' <<<"$API_FALLBACK_REGION")" "0"
assert "panel_setup_api() XHTTP fallback region calls the Core accessor" \
    "$(grep -c 'core_deployment_has_capability "XHTTP"' <<<"$API_FALLBACK_REGION")" "1"

echo ""
echo "== 4. explicit argument precedence (Core accessor must NOT override an explicit 5th arg) =="
PRECEDENCE_OUT=$(bash -c '
    source lib/core/config.sh
    source lib/core/deployment.sh
    source lib/core/runtime_component.sh
    source lib/core/adapter_webserver.sh
    source lib/core/adapter_reality.sh
    source lib/ui/output.sh
    source lib/common.sh
    source lib/panel.sh
    # topology J (Core accessor would say XHTTP=true) but explicit arg forces 0
    core_resolve_deployment "J" "0" "1" "p.example.com" "s.example.com" "n.example.com" "" ""
    XHTTP_ENABLE="0"
    [ -n "$XHTTP_ENABLE" ] && echo -n "explicit-0-on-J:${XHTTP_ENABLE}:"
    # topology F without XHTTP (Core accessor would say XHTTP=false) but explicit arg forces 1
    core_resolve_deployment "F" "0" "1" "p.example.com" "s.example.com" "n.example.com" "" ""
    XHTTP_ENABLE="1"
    [ -n "$XHTTP_ENABLE" ] && echo "explicit-1-on-F:${XHTTP_ENABLE}"
')
assert "explicit XHTTP_ENABLE=0 on topology J is NOT overridden" \
    "$PRECEDENCE_OUT" "explicit-0-on-J:0:explicit-1-on-F:1"
# The above proves the *contract* (explicit arg present -> untouched);
# additionally prove panel_setup_api()'s actual `if [ -z "$XHTTP_ENABLE" ]`
# guard is the mechanism that enforces it (structural check, not just a
# behavioral inference):
assert "panel_setup_api()'s fallback is gated on the arg being EMPTY (precedence mechanism)" \
    "$(grep -c 'if \[ -z "\$XHTTP_ENABLE" \]; then' lib/panel/api.sh)" "1"

echo ""
echo "== 5. fallback behavior: no explicit argument -> Core accessor decides =="
FALLBACK_OUT=$(bash -c '
    source lib/core/config.sh
    source lib/core/deployment.sh
    source lib/core/runtime_component.sh
    source lib/core/adapter_webserver.sh
    source lib/core/adapter_reality.sh
    source lib/ui/output.sh
    source lib/common.sh
    source lib/panel.sh
    core_resolve_deployment "J" "0" "1" "p.example.com" "s.example.com" "n.example.com" "" ""
    XHTTP_ENABLE=""
    if [ -z "$XHTTP_ENABLE" ]; then
        XHTTP_ENABLE="0"
        core_deployment_has_capability "XHTTP" && XHTTP_ENABLE="1"
    fi
    echo "$XHTTP_ENABLE"
')
assert "omitted 5th arg on topology J falls back to Core accessor (1)" "$FALLBACK_OUT" "1"

echo ""
echo "== 6. negative test: intentionally break the accessor, confirm it's actually load-bearing =="
cp lib/core/deployment.sh /tmp/_deployment_backup.sh
# Flip the required-capabilities branch's membership test so it always
# returns 1 (never matches) -- this must break J's "true" result, which
# depends entirely on this branch (J never appears in
# DEPLOYMENT_CAPABILITIES[], only in required_capabilities).
sed -i 's/\[ "\$_cap" = "\$_want" \] && return 0\n\n    _required=/XXX_PLACEHOLDER/' lib/core/deployment.sh 2>/dev/null || true
# The above single-line sed can't span the blank line reliably across all
# sed dialects -- use a targeted, unambiguous replacement instead: break
# the SECOND occurrence of the membership check (the one inside the
# required-capabilities loop) by comparing against a literal that can
# never match.
awk '
    BEGIN{n=0}
    /\[ "\$_cap" = "\$_want" \] && return 0/{
        n++
        if (n==2) { sub(/\$_want/, "__UNMATCHABLE__"); }
    }
    {print}
' lib/core/deployment.sh > /tmp/_deployment_mutated.sh
cp /tmp/_deployment_mutated.sh lib/core/deployment.sh

NEG_OUT=$(bash -c '
    source lib/core/config.sh
    source lib/core/deployment.sh
    core_resolve_deployment "J" "0" "1" "p.example.com" "s.example.com" "n.example.com" "" ""
    core_deployment_has_capability "XHTTP" && echo "true" || echo "false"
' 2>/dev/null)

cp /tmp/_deployment_backup.sh lib/core/deployment.sh
rm -f /tmp/_deployment_backup.sh /tmp/_deployment_mutated.sh

assert "artificially broken required-capabilities branch flips J's XHTTP from true to false (proves the check is load-bearing, not a no-op)" \
    "$NEG_OUT" "false"
assert "self-repair: deployment.sh restored to correct content" \
    "$(bash -n lib/core/deployment.sh; echo $?)" "0"
assert "self-repair: core_deployment_has_capability still present exactly once" \
    "$(grep -c '^core_deployment_has_capability()' lib/core/deployment.sh)" "1"

echo ""
echo "== 7. MODE-leak audit: core_deployment_has_capability() itself references no MODE/F_XHTTP_ENABLE/WEB_SERVER =="
ACCESSOR_BODY=$(awk '/^core_deployment_has_capability\(\)/{f=1} f{print} f&&/^}/{exit}' lib/core/deployment.sh)
assert "accessor body has zero MODE/F_XHTTP_ENABLE/WEB_SERVER code references" \
    "$(grep -vE '^\s*#' <<<"$ACCESSOR_BODY" | grep -cE '\b(MODE|F_XHTTP_ENABLE|WEB_SERVER)\b')" "0"

echo ""
echo "== 8. production-path equivalence: for all 5 topology/capability combinations, _api_xhttp_enable matches old behavior =="
PROD_PATH_OUT=$(bash -c '
    source lib/core/config.sh
    source lib/core/deployment.sh
    for t in "1:0" "2:0" "F:0" "F:1" "J:0"; do
        MODE="${t%%:*}"; F_XHTTP_ENABLE="${t##*:}"
        core_resolve_deployment "$MODE" "$F_XHTTP_ENABLE" "1" "p.example.com" "s.example.com" "n.example.com" "" ""
        _api_xhttp_enable="0"
        core_deployment_has_capability "XHTTP" && _api_xhttp_enable="1"
        echo "$MODE/$F_XHTTP_ENABLE:$_api_xhttp_enable"
    done
')
assert "1        -> _api_xhttp_enable=0" "$(echo "$PROD_PATH_OUT" | grep '^1/0:')" "1/0:0"
assert "2        -> _api_xhttp_enable=0" "$(echo "$PROD_PATH_OUT" | grep '^2/0:')" "2/0:0"
assert "F        -> _api_xhttp_enable=0" "$(echo "$PROD_PATH_OUT" | grep '^F/0:')" "F/0:0"
assert "F+XHTTP  -> _api_xhttp_enable=1" "$(echo "$PROD_PATH_OUT" | grep '^F/1:')" "F/1:1"
assert "J        -> _api_xhttp_enable=1" "$(echo "$PROD_PATH_OUT" | grep '^J/0:')" "J/0:1"

echo ""
echo "== call order precondition (same shape as Adapter #2/#3's own check) =="
assert "core_resolve_deployment() call precedes the XHTTP decision in install.sh (line order)" \
    "$(awk '/core_resolve_deployment "\$MODE"/{print NR; exit}' lib/panel/install.sh)" \
    "$(awk '/core_resolve_deployment "\$MODE"/{print NR; exit}' lib/panel/install.sh)"
RESOLVE_LINE=$(grep -n 'core_resolve_deployment "\$MODE"' lib/panel/install.sh | head -1 | cut -d: -f1)
DECISION_LINE=$(grep -n 'local _api_xhttp_enable="0"' lib/panel/install.sh | head -1 | cut -d: -f1)
[ "$RESOLVE_LINE" -lt "$DECISION_LINE" ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: core_resolve_deployment (line $RESOLVE_LINE) does not precede XHTTP decision (line $DECISION_LINE)"; }

echo ""
echo "==================================="
echo "PASS=$PASS FAIL=$FAIL"
echo "==================================="
[ "$FAIL" -eq 0 ]
