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

# Split-stream variant of the two harnesses above, needed for sections 6,
# 11 and 12 below. run_node_block/run_host_block deliberately merge
# stdout+stderr with `) 2>&1` so sections 2-5/7-10 can grep either
# stream for the ok()/warn() message text without caring which one it
# landed on -- but that same merge makes it impossible to assert
# anything about stdout *in isolation* (section 12) or to capture a
# create-failure warn() into a variable at all (sections 6/11 originally
# wrote `$( ... ) 2>&1` with the redirect OUTSIDE the command
# substitution, which redirects the assignment's own -- empty --
# stderr, not the subshell's; ok()/warn() write to fd2 per
# lib/ui/output.sh, so that text never reached the captured variable).
# This variant leaves fd1/fd2 unmerged: the caller decides via its own
# `2>...` how to route each. Executed inside a real function (not a bare
# `$( ... )` at file scope) so `local` inside the eval'd production
# block works without the "local: can only be used in a function"
# builtin error the original bug also produced incidentally.
run_node_block_split() {
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
                    echo "POST:$url" >> /tmp/_c13_post_log
                    echo '{"response":{"uuid":"new-node-uuid"}}'
                fi
            }
        fi
        GET_RESPONSE="$1"
        API="127.0.0.1:3000"; TOKEN="tok"
        NODE_ADDR="1.2.3.4"; CFG_UUID="cfg-uuid"; ACTIVE_INBOUNDS_JSON='["ibd-uuid"]'
        eval "$NODE_BLOCK"
    )
}

run_host_block_split() {
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
                    echo "POST:$url" >> /tmp/_c13_post_log
                    echo '{"response":{"uuid":"new-host-uuid"}}'
                fi
            }
        fi
        GET_RESPONSE="$1"
        API="127.0.0.1:3000"; TOKEN="tok"
        CFG_UUID="cfg-uuid"; IBD_UUID="ibd-uuid"; SELFSTEAL_DOMAIN="n.example.com"
        eval "$HOST_BLOCK"
    )
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
NODE_STDERR_FILE=$(mktemp)
CREATE_FAIL_STDOUT=$(run_node_block_split '{"response":[]}' 1 2>"$NODE_STDERR_FILE")
assert "Node create failure: warn shown, not ok" \
    "$(grep -c 'Ошибка создания ноды' "$NODE_STDERR_FILE")" "1"
assert "Node create failure: stdout stays clean even on the failure path" \
    "$CREATE_FAIL_STDOUT" ""
rm -f "$NODE_STDERR_FILE"

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
echo "== 10. Vision-Host: response-shape fallback (.response as a flat array) =="
# NOTE: the XHTTP Host neighbor this was originally modeled after uses
# the same `(.response.hosts // .response // [])` idiom, but jq's `//`
# does not rescue a hard type error -- `.response.hosts` on an
# already-array `.response` throws "Cannot index array with string
# \"hosts\"" (confirmed directly with jq), which aborts the pipeline
# before 2>/dev/null's suppression is anything but cosmetic, silently
# producing "not found" and re-creating on every run for that shape.
# This lookup was rewritten to branch on .response's type instead
# (verified against both shapes directly with jq before the change).
# The XHTTP Host neighbor itself is untouched -- out of scope for this
# stage -- and still has the original, unverified-for-flat-array
# pattern.
rm -f /tmp/_c13_post_log
OUT=$(run_host_block '{"response":[{"uuid":"existing-host-uuid","inbound":{"configProfileInboundUuid":"ibd-uuid"}}]}')
assert "Vision-Host flat-array response shape also correctly detects existing" \
    "$(grep -c 'POST:http://127.0.0.1:3000/api/hosts' /tmp/_c13_post_log 2>/dev/null || echo 0)" "0"

echo ""
echo "== 11. Vision-Host: lookup failure (malformed GET response) -- preserves this file's established behavior =="
# Parity with section 5 (Node lookup failure): this case existed for
# Node but was missing for Vision-Host. Same established, non-strict
# convention -- a malformed response produces empty jq output (silenced
# by 2>/dev/null) and falls through to create, same as a genuinely
# empty/no-match list. Not a new behavior; just closing a coverage gap.
rm -f /tmp/_c13_post_log
OUT=$(run_host_block 'not-json-at-all{{{')
assert "Vision-Host lookup failure: falls through to create (matches established, non-strict convention)" \
    "$(grep -c 'POST:http://127.0.0.1:3000/api/hosts' /tmp/_c13_post_log 2>/dev/null || echo 0)" "1"

echo ""
echo "== 12. Vision-Host: create failure is preserved as failure (warn, not ok; does not abort the block) =="
HOST_STDERR_FILE=$(mktemp)
CREATE_FAIL_STDOUT=$(run_host_block_split '{"response":{"hosts":[]}}' 1 2>"$HOST_STDERR_FILE")
assert "Vision-Host create failure: warn shown, not ok" \
    "$(grep -c 'Ошибка создания хоста' "$HOST_STDERR_FILE")" "1"
assert "Vision-Host create failure: stdout stays clean even on the failure path" \
    "$CREATE_FAIL_STDOUT" ""
rm -f "$HOST_STDERR_FILE"

echo ""
echo "== 13. stdout/stderr contract: neither block writes to stdout (ok/warn go to stderr; POST/GET response bodies never echoed to stdout) =="
# Deliberately uses the split-stream harness, not run_node_block/
# run_host_block -- those two already merge stdout+stderr internally
# (`) 2>&1` inside their own body) for sections 2-5/7-10's convenience,
# which makes them structurally unable to prove "nothing landed on
# stdout": by the time the caller sees the output, ok()/warn()'s stderr
# text has already been folded into what looks like stdout.
STDOUT_ONLY=$(run_node_block_split '{"response":[]}' 2>/dev/null)
assert "Node block: stdout is empty on the create path (all UI on stderr)" "$STDOUT_ONLY" ""
STDOUT_ONLY=$(run_host_block_split '{"response":{"hosts":[]}}' 2>/dev/null)
assert "Vision-Host block: stdout is empty on the create path (all UI on stderr)" "$STDOUT_ONLY" ""
STDOUT_ONLY=$(run_node_block_split '{"response":[{"uuid":"x","name":"Steal"}]}' 2>/dev/null)
assert "Node block: stdout is empty on the reuse path too" "$STDOUT_ONLY" ""
STDOUT_ONLY=$(run_host_block_split '{"response":{"hosts":[{"uuid":"x","inbound":{"configProfileInboundUuid":"ibd-uuid"}}]}}' 2>/dev/null)
assert "Vision-Host block: stdout is empty on the reuse path too" "$STDOUT_ONLY" ""

rm -f /tmp/_c13_post_log

echo ""
echo "== 14. call-site precondition: panel_setup_api() still has exactly one production call site, unchanged =="
assert "panel_setup_api() single production call site preserved" \
    "$(grep -rn 'panel_setup_api "\$SUPERADMIN_USER"' lib/panel/*.sh lib/panel/*/*.sh 2>/dev/null | grep -c 'lib/panel/install.sh')" "1"

echo ""
echo "==================================="
echo "PASS=$PASS FAIL=$FAIL"
echo "==================================="
[ "$FAIL" -eq 0 ]
