#!/bin/bash
# lib/sripts/tests/test_adapter_xhttp_host_lookup_shape.sh
#
# Lifecycle audit finding (response-shape verification pass): the XHTTP
# Host lookup in lib/panel/api.sh's panel_setup_api() used
# `(.response.hosts // .response // [])[]?` to parse GET /api/hosts.
# jq's `//` only rescues null/false, never a hard type error -- and
# `.response.hosts` on an already-array `.response` raises exactly that
# ("Cannot index array with string \"hosts\""), aborting the whole
# expression before the call site's `2>/dev/null` can do anything but
# silence it. Confirmed against the real Remnawave API contract
# (GetAllHostsResponseDto -- response: Vec<HostDto>, i.e. GET /api/hosts
# returns `.response` as a flat array) that this IS the shape hit in
# production, meaning the lookup silently returned empty on every real
# call and Contract 13 (lookup-before-create) never actually worked for
# this call site -- every re-run of panel_setup_api() with XHTTP enabled
# would create a duplicate Host.
#
# The neighboring Vision Host lookup (same file, same GET /api/hosts
# endpoint, a few dozen lines above) already carries the correct fix for
# this exact defect: branch on `.response`'s actual type instead of
# relying on `//` across a type boundary. This test proves the XHTTP
# Host lookup now uses that identical, already-proven pattern, using
# the REAL jq binary throughout (no fake/mocked jq) so the assertions
# are about actual jq semantics, not a stand-in's approximation of them.
#
# This test is deliberately load-bearing: section 2 reproduces the
# exact pre-fix expression inline and proves it fails under the real
# API shape (the bug is real, not hypothetical), then section 1 proves
# the current production expression succeeds under that same shape.
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

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed in this environment -- not substituting a mock (see test header)."; echo "PASS=0 FAIL=0"; exit 0; }

echo "== 0. bash -n =="
bash -n lib/panel/api.sh && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: bash -n lib/panel/api.sh"; }

echo ""
echo "== 1. production source inspection: the fixed expression is present exactly once, old broken expression is gone =="
FIXED_EXPR='(if (.response|type)=="object" then (.response.hosts // []) else (.response // []) end)[]? | select(.inbound.configProfileInboundUuid==$iu) | .uuid'
# The XHTTP Host fix mirrors the Vision Host lookup's pattern exactly, so
# this identical filter text now appears twice in the file: once at the
# (untouched) Vision Host lookup, once at the fixed XHTTP Host lookup.
assert "fixed type-aware expression present at both lookup sites (Vision Host untouched + XHTTP Host fixed)" \
    "$(grep -Fc "$FIXED_EXPR" lib/panel/api.sh)" "2"
assert "old broken (.response.hosts // .response // []) fallback is gone from api.sh's CODE (comments may still discuss it historically, same convention as the Vision Host fix's own comment)" \
    "$(grep -vE '^\s*#' lib/panel/api.sh | grep -cF '.response.hosts // .response // []')" "0"

# Section 1 above already proved (via grep -F, an exact literal substring
# match against the real file) that $FIXED_EXPR appears verbatim in the
# production file exactly once. Reuse that same string here as the filter
# under test, rather than re-deriving it with a second, independent (and
# more brittle) extraction mechanism -- the grep match IS the proof this
# text is what's actually in production.
PROD_FILTER="$FIXED_EXPR"

echo ""
echo "== 2. LOAD-BEARING: the OLD pre-fix expression really does fail under the real (flat-array) API shape =="
OLD_FILTER='(.response.hosts // .response // [])[]? | select(.inbound.configProfileInboundUuid==$iu) | .uuid'
FLAT_MATCH='{"response":[{"uuid":"existing-xhttp-host-uuid","inbound":{"configProfileInboundUuid":"target-ibd"}}]}'
OLD_OUT="$(echo "$FLAT_MATCH" | jq -r --arg iu "target-ibd" "$OLD_FILTER" 2>/dev/null | head -1)"
OLD_ERR="$(echo "$FLAT_MATCH" | jq -r --arg iu "target-ibd" "$OLD_FILTER" 2>&1 1>/dev/null)"
assert "OLD expression on real flat-array shape: silently produces empty output (the actual production symptom)" \
    "$OLD_OUT" ""
assert "OLD expression on real flat-array shape: the underlying jq error is a hard type error, not a clean miss" \
    "$(echo "$OLD_ERR" | grep -c 'Cannot index array with string')" "1"

echo ""
echo "== 3. FIXED (production) expression: real flat-array shape, matching host -- reuse, no duplicate create =="
NEW_OUT="$(echo "$FLAT_MATCH" | jq -r --arg iu "target-ibd" "$PROD_FILTER" 2>/dev/null | head -1)"
assert "flat-array + matching inbound UUID: existing host UUID is found" \
    "$NEW_OUT" "existing-xhttp-host-uuid"

FLAT_NOMATCH='{"response":[{"uuid":"some-other-host","inbound":{"configProfileInboundUuid":"different-ibd"}}]}'
NEW_OUT_NOMATCH="$(echo "$FLAT_NOMATCH" | jq -r --arg iu "target-ibd" "$PROD_FILTER" 2>/dev/null | head -1)"
assert "flat-array, no matching inbound UUID: empty (falls through to create, as intended)" \
    "$NEW_OUT_NOMATCH" ""

FLAT_EMPTY='{"response":[]}'
NEW_OUT_EMPTY="$(echo "$FLAT_EMPTY" | jq -r --arg iu "target-ibd" "$PROD_FILTER" 2>/dev/null | head -1)"
assert "flat-array, empty array: empty (falls through to create)" \
    "$NEW_OUT_EMPTY" ""

echo ""
echo "== 4. FIXED expression: defensive object-wrapped shape ({response:{hosts:[...]}}) still works =="
OBJ_MATCH='{"response":{"hosts":[{"uuid":"existing-xhttp-host-uuid","inbound":{"configProfileInboundUuid":"target-ibd"}}]}}'
NEW_OUT_OBJ="$(echo "$OBJ_MATCH" | jq -r --arg iu "target-ibd" "$PROD_FILTER" 2>/dev/null | head -1)"
assert "object-wrapped + matching inbound UUID: existing host UUID is found (defensive fallback intact)" \
    "$NEW_OUT_OBJ" "existing-xhttp-host-uuid"

OBJ_NOMATCH='{"response":{"hosts":[{"uuid":"some-other-host","inbound":{"configProfileInboundUuid":"different-ibd"}}]}}'
NEW_OUT_OBJ_NOMATCH="$(echo "$OBJ_NOMATCH" | jq -r --arg iu "target-ibd" "$PROD_FILTER" 2>/dev/null | head -1)"
assert "object-wrapped, no matching inbound UUID: empty (falls through to create)" \
    "$NEW_OUT_OBJ_NOMATCH" ""

echo ""
echo "== 5. malformed / non-JSON response: existing safe fall-through-to-create behavior preserved =="
MALFORMED='not json at all'
NEW_OUT_MALFORMED="$(echo "$MALFORMED" | jq -r --arg iu "target-ibd" "$PROD_FILTER" 2>/dev/null | head -1 || true)"
assert "malformed input: empty output (same silent fall-through-to-create convention as before this fix -- unchanged by this fix, this is the pre-existing 2>/dev/null convention at the call site, not something the type-branching rewrite alters)" \
    "$NEW_OUT_MALFORMED" ""

echo ""
echo "== 6. stdout/stderr contract: the lookup's own stderr is what 2>/dev/null exists to silence, stdout carries only the uuid or nothing =="
CLEAN_STDOUT="$(echo "$FLAT_MATCH" | jq -r --arg iu "target-ibd" "$PROD_FILTER" 2>/dev/null)"
assert "stdout contains only the matched uuid, nothing else" \
    "$CLEAN_STDOUT" "existing-xhttp-host-uuid"

echo ""
echo "==================================="
echo "PASS=$PASS FAIL=$FAIL"
echo "==================================="
[ "$FAIL" -eq 0 ]
