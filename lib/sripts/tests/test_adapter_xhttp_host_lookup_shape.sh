#!/bin/bash
# lib/sripts/tests/test_adapter_xhttp_host_lookup_shape.sh
#
# XHTTP Host lookup investigation (follow-up to
# test_adapter_colocated_node_host_lookup.sh's section 10 note, which
# flagged this exact neighbor as "out of scope for this stage" and
# "still has the original, unverified-for-flat-array pattern").
#
# panel_setup_api()'s XHTTP Host lookup-before-create used
# `(.response.hosts // .response // [])[]?` against GET /api/hosts.
# jq's `//` only rescues null/false, not a hard type error --
# `.response.hosts` on an already-array `.response` raises "Cannot
# index array with string \"hosts\"" (exit 5), which aborts the whole
# pipeline before `2>/dev/null` is anything but cosmetic for the
# message text, silently producing "not found" every time.
#
# Investigation confirmed the real API contract is the array shape,
# not the object-wrapped one this parser assumed:
#   - @remnawave/backend-contract's GetHostsCommand
#     (libs/contract/commands/hosts/get-hosts.command.ts, upstream
#     remnawave/backend) defines `response: z.array(HostsSchema)` --
#     .response for GET /api/hosts is always the flat array.
#   - This project's own lib/sripts/tests/harness.sh mocks this exact
#     endpoint as `{"response":[...]}` throughout (never
#     `{"response":{"hosts":[...]}}`), independently encoding the same
#     fact.
# So the old parser had it backwards: the shape it treated as the
# fallback (flat array) is the one the real API always returns, and
# the shape it tried first (`.response.hosts`) is the one that
# doesn't exist in production -- meaning this lookup always failed on
# real traffic and recreated the XHTTP Host on every re-run. This is
# the exact Contract 13 (lookup-before-create) failure mode the
# neighboring Vision Host lookup was already fixed for; this closes
# the same gap for its XHTTP sibling, using the identical, already-
# proven type-branching pattern -- no new abstraction.
#
# Same extraction/harness approach as
# test_adapter_colocated_node_host_lookup.sh: the real production
# block is pulled out verbatim via awk and exercised in isolation
# against a mocked panel_api(), since panel_setup_api() itself needs a
# live Panel API and cannot be called end-to-end here.
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
bash -n lib/panel/api.sh 2>/tmp/_xhttp_synerr && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: bash -n lib/panel/api.sh"; cat /tmp/_xhttp_synerr; }
rm -f /tmp/_xhttp_synerr

echo ""
echo "== 1. production source inspection =="
assert "XHTTP-Host lookup-before-create block present exactly once" \
    "$(grep -c 'local EXISTING_XHTTP_HOST' lib/panel/api.sh)" "1"
assert "no unconditional (unguarded) POST for the XHTTP Host remains" \
    "$(awk '/local EXISTING_XHTTP_HOST/,/^        fi$/' lib/panel/api.sh | grep -c '^        panel_api "POST"')" "0"
assert "the old type-unsafe fallback idiom is gone from this block" \
    "$(awk '/local EXISTING_XHTTP_HOST/,/^        fi$/' lib/panel/api.sh | grep -c '(\.response\.hosts // \.response // \[\])')" "0"
assert "the block now branches on .response's actual type (Vision-Host's proven pattern)" \
    "$(awk '/local EXISTING_XHTTP_HOST/,/^        fi$/' lib/panel/api.sh | grep -c '(\.response|type)==\"object\"')" "1"

XHTTP_BLOCK="$(awk '/local EXISTING_XHTTP_HOST/,/^        fi$/' lib/panel/api.sh)"
assert "XHTTP-Host block actually extracted (non-empty)" "$([ -n "$XHTTP_BLOCK" ] && echo present || echo MISSING)" "present"

# Common harness: mocks panel_api() to answer GET with a scripted
# response and records every POST it's asked to make, without any
# real network call. Mirrors run_host_block/run_host_block_split from
# test_adapter_colocated_node_host_lookup.sh, retargeted at the XHTTP
# variables this block actually reads (XHTTP_IBD_UUID, not IBD_UUID;
# XHTTP_PUBLIC_PORT_VAL, not a Vision-side var).
run_xhttp_block() {
    (
        source lib/ui/output.sh
        panel_api() {
            local method="$1" url="$2"
            if [ "$method" = "GET" ]; then
                echo "$GET_RESPONSE"
            elif [ "$method" = "POST" ]; then
                echo "POST:$url" >> /tmp/_xhttp_post_log
                echo '{"response":{"uuid":"new-xhttp-host-uuid"}}'
            fi
        }
        GET_RESPONSE="$1"
        API="127.0.0.1:3000"; TOKEN="tok"
        CFG_UUID="cfg-uuid"; XHTTP_IBD_UUID="xhttp-ibd-uuid"
        SELFSTEAL_DOMAIN="n.example.com"; XHTTP_PATH="/xhttp"
        XHTTP_ENABLE="1"
        core_port_allocation_public() { echo 9443; }
        MODE="F"
        eval "$XHTTP_BLOCK"
    ) 2>&1
}

run_xhttp_block_split() {
    # $1 = GET response, $2 = "1" to force every POST call to fail
    (
        source lib/ui/output.sh
        if [ "${2:-}" = "1" ]; then
            panel_api() { [ "$1" = "GET" ] && { echo "$GET_RESPONSE"; return 0; }; return 1; }
        else
            panel_api() {
                local method="$1" url="$2"
                if [ "$method" = "GET" ]; then
                    echo "$GET_RESPONSE"
                elif [ "$method" = "POST" ]; then
                    echo "POST:$url" >> /tmp/_xhttp_post_log
                    echo '{"response":{"uuid":"new-xhttp-host-uuid"}}'
                fi
            }
        fi
        GET_RESPONSE="$1"
        API="127.0.0.1:3000"; TOKEN="tok"
        CFG_UUID="cfg-uuid"; XHTTP_IBD_UUID="xhttp-ibd-uuid"
        SELFSTEAL_DOMAIN="n.example.com"; XHTTP_PATH="/xhttp"
        XHTTP_ENABLE="1"
        core_port_allocation_public() { echo 9443; }
        MODE="F"
        eval "$XHTTP_BLOCK"
    )
}

echo ""
echo "== 2. real API shape (flat array, per GetHostsCommand/harness.sh): missing -> POST happens =="
rm -f /tmp/_xhttp_post_log
OUT=$(run_xhttp_block '{"response":[]}')
assert "flat-array, missing: exactly one POST to /api/hosts" \
    "$(grep -c 'POST:http://127.0.0.1:3000/api/hosts' /tmp/_xhttp_post_log 2>/dev/null || echo 0)" "1"
assert "flat-array, missing: 'создан' message shown" \
    "$(grep -c 'Хост для XHTTP создан' <<<"$OUT")" "1"

echo ""
echo "== 3. real API shape (flat array): existing Host for this inbound -> lookup finds it, no POST -- THE BUG THIS FIX CLOSES =="
# This is the case the old `(.response.hosts // .response // [])` idiom
# got wrong: on this exact real-world shape it threw a hard jq type
# error (confirmed directly with jq: "Cannot index array with string
# \"hosts\""), silenced by 2>/dev/null, always reporting "not found"
# and always re-POSTing a duplicate Host.
rm -f /tmp/_xhttp_post_log
OUT=$(run_xhttp_block '{"response":[{"uuid":"existing-xhttp-host-uuid","inbound":{"configProfileInboundUuid":"xhttp-ibd-uuid"}}]}')
assert "flat-array, existing: zero POSTs to /api/hosts" \
    "$(grep -c 'POST:http://127.0.0.1:3000/api/hosts' /tmp/_xhttp_post_log 2>/dev/null || echo 0)" "0"
assert "flat-array, existing: 'уже существует' message shown" \
    "$(grep -c 'Хост для XHTTP уже существует' <<<"$OUT")" "1"

echo ""
echo "== 4. real API shape (flat array): a Host for a DIFFERENT inbound must not be mistaken for a match =="
rm -f /tmp/_xhttp_post_log
OUT=$(run_xhttp_block '{"response":[{"uuid":"other-uuid","inbound":{"configProfileInboundUuid":"some-other-ibd"}}]}')
assert "flat-array, non-matching inbound: still creates" \
    "$(grep -c 'POST:http://127.0.0.1:3000/api/hosts' /tmp/_xhttp_post_log 2>/dev/null || echo 0)" "1"

echo ""
echo "== 5. object-wrapped shape (.response.hosts): still handled, same as before -- no regression for this hypothetical shape =="
rm -f /tmp/_xhttp_post_log
OUT=$(run_xhttp_block '{"response":{"hosts":[{"uuid":"existing-xhttp-host-uuid","inbound":{"configProfileInboundUuid":"xhttp-ibd-uuid"}}]}}')
assert "object-wrapped, existing: zero POSTs to /api/hosts" \
    "$(grep -c 'POST:http://127.0.0.1:3000/api/hosts' /tmp/_xhttp_post_log 2>/dev/null || echo 0)" "0"
rm -f /tmp/_xhttp_post_log
OUT=$(run_xhttp_block '{"response":{"hosts":[]}}')
assert "object-wrapped, missing: exactly one POST to /api/hosts" \
    "$(grep -c 'POST:http://127.0.0.1:3000/api/hosts' /tmp/_xhttp_post_log 2>/dev/null || echo 0)" "1"

echo ""
echo "== 6. lookup failure (malformed GET response) -- preserves this file's established, non-strict convention =="
rm -f /tmp/_xhttp_post_log
OUT=$(run_xhttp_block 'not-json-at-all{{{')
assert "malformed lookup: falls through to create (matches established convention)" \
    "$(grep -c 'POST:http://127.0.0.1:3000/api/hosts' /tmp/_xhttp_post_log 2>/dev/null || echo 0)" "1"

echo ""
echo "== 7. create failure is preserved as failure (warn, not ok; does not abort the block) =="
XHTTP_STDERR_FILE=$(mktemp)
CREATE_FAIL_STDOUT=$(run_xhttp_block_split '{"response":[]}' 1 2>"$XHTTP_STDERR_FILE")
assert "create failure: warn shown, not ok" \
    "$(grep -c 'Ошибка создания хоста для XHTTP' "$XHTTP_STDERR_FILE")" "1"
assert "create failure: stdout stays clean even on the failure path" \
    "$CREATE_FAIL_STDOUT" ""
rm -f "$XHTTP_STDERR_FILE"

echo ""
echo "== 8. stdout/stderr contract: block never writes to stdout (ok/warn on stderr; response bodies never echoed to stdout) =="
STDOUT_ONLY=$(run_xhttp_block_split '{"response":[]}' 2>/dev/null)
assert "stdout empty on the create path" "$STDOUT_ONLY" ""
STDOUT_ONLY=$(run_xhttp_block_split '{"response":[{"uuid":"x","inbound":{"configProfileInboundUuid":"xhttp-ibd-uuid"}}]}' 2>/dev/null)
assert "stdout empty on the reuse path too" "$STDOUT_ONLY" ""

rm -f /tmp/_xhttp_post_log

echo ""
echo "== 9. call-site precondition: panel_setup_api() still has exactly one production call site, unchanged =="
assert "panel_setup_api() single production call site preserved" \
    "$(grep -rn 'panel_setup_api "\$SUPERADMIN_USER"' lib/panel/*.sh lib/panel/*/*.sh 2>/dev/null | grep -c 'lib/panel/install.sh')" "1"

echo ""
echo "==================================="
echo "PASS=$PASS FAIL=$FAIL"
echo "==================================="
[ "$FAIL" -eq 0 ]
