#!/bin/bash
# lib/sripts/tests/test_adapter_remote_node_reinstall_warning.sh
#
# F2 (post-C13 audit): panel_install_remote_node()'s (lib/panel/node/
# install.sh) pre-flight warning used to claim a re-run "создаст новую
# ноду/хост в Panel (операция не идемпотентна)" -- a blanket "not
# idempotent" claim about Panel-side Node/Host creation. That became
# stale once Contract 13 was extended to this flow's own
# panel_node_register() (lib/panel/node/api.sh): that function now does
# lookup-before-create for config-profile/Node/Host alike, so a re-run
# does NOT unconditionally duplicate them in Panel any more.
#
# This test does not re-verify Contract 13's own lookup-before-create
# logic (already covered end-to-end by
# test_adapter_colocated_node_host_lookup.sh for the sibling MODE=1/F/J
# path, and by panel_node_register()'s own header/body for this path).
# It verifies two narrower, deterministic things instead:
#   1. The stale, now-false claim's exact wording is gone from the
#      warning shown to the operator.
#   2. The new wording's two factual claims are still true against the
#      actual code, not just asserted in prose:
#        a) panel_node_register() really does have a lookup-before-
#           create branch for both Node and Host (NODE_EXISTING/
#           HOST_EXISTING), matching what the new warning says.
#        b) the SSH-side redeploy (PUT into remote /opt/remnanode) is
#           still unconditional -- i.e. the new warning's remaining
#           "not idempotent" claim, narrowed to the SSH/redeploy part,
#           is not itself an overclaim in the other direction.
# F1 (SSH timeout/signal handling) is untouched by this change and is
# not re-tested here -- see test_ssh_reliability_f1.sh for that.

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

INSTALL_FILE="lib/panel/node/install.sh"
API_FILE="lib/panel/node/api.sh"

echo ""
echo "== 0. bash -n =="
bash -n "$INSTALL_FILE" || { echo "SYNTAX ERROR in $INSTALL_FILE"; exit 1; }

echo ""
echo "== 1. stale false claim is gone from panel_install_remote_node()'s LIVE warning =="
# Matched as an actual warn "..." call, not the FIXED-comment's own
# quote of the old text (that quote is expected and documents the
# change, same convention as this file's other FIXED comments) --
# distinguished by requiring `warn "` immediately before the phrase.
assert "old blanket 'создаст новую ноду/хост' claim removed from the live warn() call" \
    "$(grep -c 'warn "Повторный запуск создаст новую ноду/хост' "$INSTALL_FILE")" "0"

echo ""
echo "== 2. new warning text is present, in the same function, exactly once =="
assert "new wording present exactly once" \
    "$(grep -c 'переиспользует существующие конфиг-профиль/ноду/хост в Panel' "$INSTALL_FILE")" "1"

echo ""
echo "== 3. new warning still names the genuinely non-idempotent part (remote redeploy) =="
assert "new wording still flags /opt/remnanode redeploy as non-idempotent, in a live warn() call" \
    "$(grep -c 'warn ".*не идемпотентна' "$INSTALL_FILE")" "1"

echo ""
echo "== 4. precondition preserved: admin-credentials warning untouched, still first =="
assert "admin-credentials warning still present" \
    "$(grep -c 'Panel должна быть уже установлена' "$INSTALL_FILE")" "1"

echo ""
echo "== 5. factual claim (a): panel_node_register() really has lookup-before-create for Node AND Host =="
# Anchored to the standalone assignment line shape (whitespace + the
# bare assignment, nothing else on the line) so an unrelated comment
# that merely *mentions* the variable name in passing (there is one,
# a couple lines below the real Node assignment) doesn't also count.
assert "NODE_EXISTING=true assignment present in panel_node_register()" \
    "$(grep -cE '^[[:space:]]*NODE_EXISTING=true[[:space:]]*$' "$API_FILE")" "1"
assert "HOST_EXISTING=true assignment present in panel_node_register()" \
    "$(grep -cE '^[[:space:]]*HOST_EXISTING=true[[:space:]]*$' "$API_FILE")" "1"

echo ""
echo "== 6. factual claim (b): the SSH-side PUT into /opt/remnanode is still unconditional (genuinely not idempotent) =="
# Extract the region from panel_install_remote_node()'s start to the PUT
# call and confirm no lookup-before-create-style guard (an `if` testing
# an *_EXISTING-shaped condition) wraps it -- i.e. this session did not
# accidentally also claim the SSH side became idempotent when it did not.
PUT_REGION=$(awk '/^panel_install_remote_node\(\)/,/PUT \/opt\/remnanode\/docker-compose.yml/' "$INSTALL_FILE")
assert "PUT region actually matched (non-empty)" \
    "$([ -n "$PUT_REGION" ] && echo yes || echo no)" "yes"
assert "no *_EXISTING-style guard wraps the PUT call (redeploy still unconditional)" \
    "$(grep -c 'EXISTING' <<<"$PUT_REGION")" "0"

echo ""
echo "==================================="
echo "PASS=$PASS FAIL=$FAIL"
echo "==================================="
[ "$FAIL" -eq 0 ]
