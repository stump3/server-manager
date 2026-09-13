#!/bin/bash
# lib/sripts/tests/test_adapter_colocated_node_host_lookup.sh
#
# Contract 13 (lookup-before-create) extension: lib/panel/api.sh's
# panel_setup_api() (the colocated, MODE=1/F/J-compatible install path)
# used to POST /api/nodes and POST /api/hosts (the "Vision" Host)
# unconditionally on every invocation -- a second run against an
# already-provisioned Panel would either duplicate the Node/Host or hit
# Nodes.name's DB-unique constraint, surfacing only as a generic
# "Ошибка создания ноды" warn. Config Profile (same function, above) and
# the XHTTP Host (same function, below) already followed lookup-before-
# create; this closes the last two unconverted call sites, using the
# exact same pattern already proven at those two neighboring sites --
# no new abstraction, no content-diff/reconciliation (explicitly out of
# scope, matching Config Profile/XHTTP Host's own documented boundary).
#
# panel_setup_api() itself is not invoked end-to-end here -- it requires
# a live Panel API, superadmin session, Reality keypair generation, and
# already-generated Xray inbounds JSON, none of which are available in
# this environment (same reason test_adapter_node_addr.sh, the existing
# precedent test for this exact function, only extracts a bounded region
# rather than calling the whole function). Instead, each of the two new
# lookup-before-create blocks is extracted verbatim via awk (the real
# production code, not a reimplementation) and exercised in isolation
# against a mocked panel_api(), which is the smallest real production
# boundary this behavior can be tested at.
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
for f in lib/panel/api.sh; do
    bash -n "$f" 2>/tmp/_c13_synerr && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: bash -n $f"; cat /tmp/_c13_synerr; }
done
rm -f /tmp/_c13_synerr

echo ""
echo "== 1. production source inspection: both blocks present exactly once, structurally shaped as lookup-before-create =="
assert "Node lookup-before-create block present exactly once" \
    "$(grep -c 'local EXISTING_NODE' lib/panel/api.sh)" "1"
assert "Vision-Host lookup-before-create block present exactly once" \
    "$(grep -c 'local EXISTING_VISION_HOST' lib/panel/api.sh)" "1"
assert "no unconditional (unguarded) POST /api/nodes remains" \
    "$(awk '/local EXISTING_NODE/,/^    fi$/' lib/panel/api.sh | grep -c '^    panel_api "POST"')" "0"
assert "no unconditional (unguarded) POST for the Vision Host remains" \
    "$(awk '/local EXISTING_VISION_HOST/,/^    fi$/' lib/panel/api.sh | grep -c '^    panel_api "POST"')" "0"

# Extract the two real production blocks verbatim for sections 2-5 below.
NODE_BLOCK="$(awk '/local EXISTING_NODE/,/^    fi$/' lib/panel/api.sh)"
HOST_BLOCK="$(awk '/local EXISTING_VISION_HOST/,/^    fi$/' lib/panel/api.sh)"
assert "Node block actually extracted (non-empty)" "$([ -n "$NODE_BLOCK" ] && echo present || echo MISSING)" "present"
assert "Vision-Host block actually extracted (non-empty)" "$([ -n "$HOST_BLOCK" ] && echo present || echo MISSING)" "present"

# Common harness: mocks panel_api() to answer GET with a scripted response
# and record every POST it's asked to make, without any real network call.
run_node_block() {
    # $1 = GET /api/nodes response body (controls lookup outcome)
    (
        source lib/ui/output.sh
        POST_LOG=""
        panel_api() {
            local method="$1" url="$2"
            if [ "$method" = "GET" ]; then
                echo "$GET_RESPONSE"
            elif [ "$method" = "POST" ]; then
                echo "POST:$url" >> /tmp/_c13_post_log
                echo '{"response":{"uuid":"new-node-uuid"}}'
            fi
        }
        GET_RESPONSE="$1"
        API="127.0.0.1:3000"; TOKEN="tok"
        NODE_ADDR="1.2.3.4"; CFG_UUID="cfg-uuid"; ACTIVE_INBOUNDS_JSON='["ibd-uuid"]'
        eval "$NODE_BLOCK"
    ) 2>&1
}

run_host_block() {
    (
        source lib/ui/output.sh
        panel_api() {
            local method="$1" url="$2"
            if [ "$method" = "GET" ]; then
                echo "$GET_RESPONSE"
            elif [ "$method" = "POST" ]; then
                echo "POST:$url" >> /tmp/_c13_post_log
                echo '{"response":{"uuid":"new-host-uuid"}}'
            fi
        }
        GET_RESPONSE="$1"
        API="127.0.0.1:3000"; TOKEN="tok"
        CFG_UUID="cfg-uuid"; IBD_UUID="ibd-uuid"; SELFSTEAL_DOMAIN="n.example.com"
        eval "$HOST_BLOCK"
    ) 2>&1
}

echo ""
echo "== 2. Node: missing -> lookup says absent -> POST happens =="
rm -f /tmp/_c13_post_log
OUT=$(run_node_block '{"response":[]}')
assert "Node missing: exactly one POST to /api/nodes" \
    "$(grep -c 'POST:http://127.0.0.1:3000/api/nodes' /tmp/_c13_post_log 2>/dev/null || echo 0)" "1"
assert "Node missing: 'создана' (created) message shown, not 'уже существует'" \
    "$(grep -c 'создана' <<<"$OUT"):$(grep -c 'уже существует' <<<"$OUT")" "1:0"

echo ""
echo "== 3. Node: already exists -> lookup finds it -> POST does NOT happen =="
rm -f /tmp/_c13_post_log
OUT=$(run_node_block '{"response":[{"uuid":"existing-node-uuid","name":"Steal"}]}')
assert "Node existing: zero POSTs to /api/nodes" \
    "$(grep -c 'POST:http://127.0.0.1:3000/api/nodes' /tmp/_c13_post_log 2>/dev/null || echo 0)" "0"
assert "Node existing: 'уже существует' (reuse) message shown, not 'создана'" \
    "$(grep -c 'уже существует' <<<"$OUT"):$(grep -c 'создана' <<<"$OUT")" "1:0"

echo ""
echo "== 4. Node: a DIFFERENTLY-NAMED existing node must not be mistaken for a match =="
rm -f /tmp/_c13_post_log
OUT=$(run_node_block '{"response":[{"uuid":"unrelated-uuid","name":"SomeOtherNode"}]}')
assert "Node lookup correctly ignores a non-matching name -- still creates" \
    "$(grep -c 'POST:http://127.0.0.1:3000/api/nodes' /tmp/_c13_post_log 2>/dev/null || echo 0)" "1"

echo ""
echo "== 5. Node: lookup failure (malformed GET response) -- preserves this file's existing, established behavior =="
# Config Profile and XHTTP Host (the two pre-existing lookup-before-create
# sites in this same function) have no explicit "lookup failed, abort"
# branch -- a malformed response just produces empty jq output (silenced
# by 2>/dev/null) and falls through to create, same as a genuinely empty
# list. This is the established local contract (unlike the stricter,
# type-checked GET handling in lib/panel/node/api.sh's separate,
# different-generation adapter) -- preserved here, not newly introduced.
rm -f /tmp/_c13_post_log
OUT=$(run_node_block 'not-json-at-all{{{')
assert "Node lookup failure: falls through to create (matches this file's established, non-strict convention)" \
    "$(grep -c 'POST:http://127.0.0.1:3000/api/nodes' /tmp/_c13_post_log 2>/dev/null || echo 0)" "1"

echo ""
echo "== 6. Node: create failure is preserved as failure (warn, not ok; does not abort the block) =="
CREATE_FAIL_OUT=$(
    source lib/ui/output.sh
    panel_api() {
        local method="$1"
        [ "$method" = "GET" ] && { echo '{"response":[]}'; return 0; }
        return 1
    }
    API="127.0.0.1:3000"; TOKEN="tok"
    NODE_ADDR="1.2.3.4"; CFG_UUID="cfg-uuid"; ACTIVE_INBOUNDS_JSON='["ibd-uuid"]'
    eval "$NODE_BLOCK"
    echo "REACHED_END"
) 2>&1
assert "Node create failure: warn shown, not ok" \
    "$(grep -c 'Ошибка создания ноды' <<<"$CREATE_FAIL_OUT")" "1"
assert "Node create failure: block completes (non-fatal, matches existing && / || convention)" \
    "$(grep -c 'REACHED_END' <<<"$CREATE_FAIL_OUT")" "1"

echo ""
echo "== 7. Vision-Host: missing -> lookup says absent -> POST happens =="
rm -f /tmp/_c13_post_log
OUT=$(run_host_block '{"response":{"hosts":[]}}')
assert "Vision-Host missing: exactly one POST to /api/hosts" \
    "$(grep -c 'POST:http://127.0.0.1:3000/api/hosts' /tmp/_c13_post_log 2>/dev/null || echo 0)" "1"
assert "Vision-Host missing: 'создан' (created) message shown" \
    "$(grep -c 'Хост создан' <<<"$OUT")" "1"

echo ""
echo "== 8. Vision-Host: already exists -> lookup finds it -> POST does NOT happen =="
rm -f /tmp/_c13_post_log
OUT=$(run_host_block '{"response":{"hosts":[{"uuid":"existing-host-uuid","inbound":{"configProfileInboundUuid":"ibd-uuid"}}]}}')
assert "Vision-Host existing: zero POSTs to /api/hosts" \
    "$(grep -c 'POST:http://127.0.0.1:3000/api/hosts' /tmp/_c13_post_log 2>/dev/null || echo 0)" "0"
assert "Vision-Host existing: 'уже существует' message shown" \
    "$(grep -c 'Хост уже существует' <<<"$OUT")" "1"

echo ""
echo "== 9. Vision-Host: a Host for a DIFFERENT inbound must not be mistaken for a match =="
rm -f /tmp/_c13_post_log
OUT=$(run_host_block '{"response":{"hosts":[{"uuid":"other-uuid","inbound":{"configProfileInboundUuid":"some-other-ibd"}}]}}')
assert "Vision-Host lookup correctly ignores a non-matching inbound -- still creates" \
    "$(grep -c 'POST:http://127.0.0.1:3000/api/hosts' /tmp/_c13_post_log 2>/dev/null || echo 0)" "1"

echo ""
echo "== 10. Vision-Host: response-shape fallback (.response as flat array, like the XHTTP Host neighbor already handles) =="
rm -f /tmp/_c13_post_log
OUT=$(run_host_block '{"response":[{"uuid":"existing-host-uuid","inbound":{"configProfileInboundUuid":"ibd-uuid"}}]}')
assert "Vision-Host flat-array response shape also correctly detects existing" \
    "$(grep -c 'POST:http://127.0.0.1:3000/api/hosts' /tmp/_c13_post_log 2>/dev/null || echo 0)" "0"

echo ""
echo "== 11. Vision-Host: create failure is preserved as failure (warn, not ok; does not abort the block) =="
CREATE_FAIL_OUT=$(
    source lib/ui/output.sh
    panel_api() {
        local method="$1"
        [ "$method" = "GET" ] && { echo '{"response":{"hosts":[]}}'; return 0; }
        return 1
    }
    API="127.0.0.1:3000"; TOKEN="tok"
    CFG_UUID="cfg-uuid"; IBD_UUID="ibd-uuid"; SELFSTEAL_DOMAIN="n.example.com"
    eval "$HOST_BLOCK"
    echo "REACHED_END"
) 2>&1
assert "Vision-Host create failure: warn shown, not ok" \
    "$(grep -c 'Ошибка создания хоста' <<<"$CREATE_FAIL_OUT")" "1"
assert "Vision-Host create failure: block completes (non-fatal)" \
    "$(grep -c 'REACHED_END' <<<"$CREATE_FAIL_OUT")" "1"

echo ""
echo "== 12. stdout/stderr contract: neither block writes to stdout (ok/warn go to stderr; POST/GET response bodies never echoed to stdout) =="
STDOUT_ONLY=$(run_node_block '{"response":[]}' 2>/dev/null)
assert "Node block: stdout is empty on the create path (all UI on stderr)" "$STDOUT_ONLY" ""
STDOUT_ONLY=$(run_host_block '{"response":{"hosts":[]}}' 2>/dev/null)
assert "Vision-Host block: stdout is empty on the create path (all UI on stderr)" "$STDOUT_ONLY" ""

rm -f /tmp/_c13_post_log

echo ""
echo "== 13. call-site precondition: panel_setup_api() still has exactly one production call site, unchanged =="
assert "panel_setup_api() single production call site preserved" \
    "$(grep -rn 'panel_setup_api "\$SUPERADMIN_USER"' lib/panel/*.sh lib/panel/*/*.sh 2>/dev/null | grep -c 'lib/panel/install.sh')" "1"

echo ""
echo "==================================="
echo "PASS=$PASS FAIL=$FAIL"
echo "==================================="
[ "$FAIL" -eq 0 ]
