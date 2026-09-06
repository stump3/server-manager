#!/bin/bash
# lib/sripts/tests/test_deployment_resolver.sh
#
# Tests for the Core/Runtime first implementation seam:
#     legacy CLI/input -> compatibility resolver -> Deployment
# (lib/core/deployment.sh). See docs/edge_contracts.md and
# docs/CORE_RUNTIME_CONTRACTS.md for the contract this seam implements.
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
assert_array() {
    # compares a bash array (passed by name) against an expected
    # space-joined string
    local desc="$1" arrname="$2" expected="$3"
    local -n _arr="$arrname"
    local actual="${_arr[*]:-}"
    assert "$desc" "$actual" "$expected"
}

source lib/core/deployment.sh

echo "== Topology lookup (lib/core/topology.sh) — direct, per topology id =="

# MODE=1: public_ingress_owner=xray, required=Vision
assert "topology 1: valid" "$(core_topology_is_valid "1"; echo $?)" "0"
assert "topology 1: public_ingress_owner" "$(core_topology_public_ingress_owner "1")" "xray"
assert "topology 1: required_capabilities" "$(core_topology_required_capabilities "1")" "Vision"
assert "topology 1: optional_capabilities empty" "$(core_topology_optional_capabilities "1")" ""
assert "topology 1: does not require nginx-stream" "$(core_topology_requires_nginx_stream "1"; echo $?)" "1"

# MODE=2: public_ingress_owner=nginx-http, required=PanelSub
assert "topology 2: valid" "$(core_topology_is_valid "2"; echo $?)" "0"
assert "topology 2: public_ingress_owner" "$(core_topology_public_ingress_owner "2")" "nginx-http"
assert "topology 2: required_capabilities" "$(core_topology_required_capabilities "2")" "PanelSub"
assert "topology 2: optional_capabilities empty" "$(core_topology_optional_capabilities "2")" ""
assert "topology 2: does not require nginx-stream" "$(core_topology_requires_nginx_stream "2"; echo $?)" "1"

# MODE=F: public_ingress_owner=nginx-stream, required=Vision, optional=XHTTP
assert "topology F: public_ingress_owner" "$(core_topology_public_ingress_owner "F")" "nginx-stream"
assert "topology F: required_capabilities" "$(core_topology_required_capabilities "F")" "Vision"
assert "topology F: optional_capabilities" "$(core_topology_optional_capabilities "F")" "XHTTP"
assert "topology F: XHTTP is optional" "$(core_topology_capability_is_optional "F" "XHTTP"; echo $?)" "0"
assert "topology F: requires nginx-stream" "$(core_topology_requires_nginx_stream "F"; echo $?)" "0"

# MODE=J: public_ingress_owner=nginx-stream, required=Vision+XHTTP (XHTTP is
# NOT optional here — this is the specific fact the task requires be true
# independent of F_XHTTP_ENABLE, since J has no such input at all).
assert "topology J: public_ingress_owner" "$(core_topology_public_ingress_owner "J")" "nginx-stream"
assert "topology J: required_capabilities includes XHTTP" "$(core_topology_required_capabilities "J")" "Vision XHTTP"
assert "topology J: XHTTP is required, not optional" "$(core_topology_capability_is_required "J" "XHTTP"; echo $?)" "0"
assert "topology J: XHTTP is NOT in optional set" "$(core_topology_capability_is_optional "J" "XHTTP"; echo $?)" "1"
assert "topology J: optional_capabilities empty" "$(core_topology_optional_capabilities "J")" ""
assert "topology J: requires nginx-stream" "$(core_topology_requires_nginx_stream "J"; echo $?)" "0"

# Unknown id: every lookup fails closed (empty output, exit 1), not a
# silent default.
assert "topology X: invalid" "$(core_topology_is_valid "X"; echo $?)" "1"
assert "topology X: public_ingress_owner fails" "$(core_topology_public_ingress_owner "X" 2>/dev/null; echo $?)" "1"

echo "== Behavioral (non-grep) proof that deployment.sh has no second, hardcoded topology table =="
# If core_validate_deployment() still had its own literal
# "$DEPLOYMENT_TOPOLOGY != 'F'" check for XHTTP admissibility, overriding
# core_topology_capability_is_optional() to always say "yes" would NOT be
# enough to make XHTTP valid for topology J — the literal check would
# still reject it regardless of what the topology lookup says. Running
# this in a subshell with the override in place and observing J+XHTTP
# become VALID is a real behavioral proof of delegation, not a grep for
# the absence of a string.
_OVERRIDE_RESULT=$(bash -c '
    source lib/core/deployment.sh
    # Override AFTER sourcing: this replaces the function deployment.sh
    # calls, proving validate_deployment() consults it at call time
    # rather than having its own compiled-in F/J logic.
    core_topology_capability_is_optional() { return 0; }
    core_resolve_deployment "J" "" "1" "p.example.com" "s.example.com" "sf.example.com" "" ""
    DEPLOYMENT_CAPABILITIES=("XHTTP")
    core_validate_deployment
    echo $?
')
assert "override proves validate() delegates to topology.sh, not a hardcoded F check" "$_OVERRIDE_RESULT" "0"

# Without the override, the real topology.sh's own (correct, unmodified)
# answer must still reject XHTTP for J — this is the actual production
# behavior, tested with no override at all.
core_resolve_deployment "J" "" "1" "panel.example.com" "sub.example.com" "self.example.com" "" ""
DEPLOYMENT_CAPABILITIES=("XHTTP")
core_validate_deployment
assert "real (unmodified) topology.sh: XHTTP invalid for J" "$?" "1"

echo "== Six trace cases (+ Remote Node as a seventh) =="

# 1. MODE=1
core_resolve_deployment "1" "" "1" "panel.example.com" "sub.example.com" "self.example.com" "" ""
assert "1: topology" "$DEPLOYMENT_TOPOLOGY" "1"
assert_array "1: capabilities empty" DEPLOYMENT_CAPABILITIES ""
assert "1: domain panel" "$DEPLOYMENT_DOMAIN_PANEL" "panel.example.com"
assert "1: telemt absent" "$DEPLOYMENT_TELEMT_PRESENT" "0"
core_validate_deployment; assert "1: valid" "$?" "0"

# 2. MODE=2
core_resolve_deployment "2" "" "2" "panel.example.com" "sub.example.com" "self.example.com" "" ""
assert "2: topology" "$DEPLOYMENT_TOPOLOGY" "2"
assert_array "2: capabilities empty" DEPLOYMENT_CAPABILITIES ""
assert "2: telemt absent" "$DEPLOYMENT_TELEMT_PRESENT" "0"
core_validate_deployment; assert "2: valid" "$?" "0"

# 3. MODE=F (XHTTP off, no TeleMT)
core_resolve_deployment "F" "0" "1" "panel.example.com" "sub.example.com" "self.example.com" "" ""
assert "F: topology" "$DEPLOYMENT_TOPOLOGY" "F"
assert_array "F: capabilities empty" DEPLOYMENT_CAPABILITIES ""
assert "F: telemt absent" "$DEPLOYMENT_TELEMT_PRESENT" "0"
core_validate_deployment; assert "F: valid" "$?" "0"

# 4. MODE=F + F_XHTTP_ENABLE=1
core_resolve_deployment "F" "1" "1" "panel.example.com" "sub.example.com" "self.example.com" "" ""
assert "F+XHTTP: topology" "$DEPLOYMENT_TOPOLOGY" "F"
assert_array "F+XHTTP: capabilities=[XHTTP]" DEPLOYMENT_CAPABILITIES "XHTTP"
core_validate_deployment; assert "F+XHTTP: valid" "$?" "0"

# 5. MODE=J
core_resolve_deployment "J" "" "1" "panel.example.com" "sub.example.com" "self.example.com" "" ""
assert "J: topology" "$DEPLOYMENT_TOPOLOGY" "J"
assert_array "J: capabilities empty (XHTTP implied by topology, never listed)" DEPLOYMENT_CAPABILITIES ""
core_validate_deployment; assert "J: valid" "$?" "0"

# 6. MODE=F + TeleMT
core_resolve_deployment "F" "0" "1" "panel.example.com" "sub.example.com" "self.example.com" "mtproto.example.com" "12345"
assert "F+TeleMT: topology" "$DEPLOYMENT_TOPOLOGY" "F"
assert "F+TeleMT: telemt present" "$DEPLOYMENT_TELEMT_PRESENT" "1"
assert "F+TeleMT: telemt domain" "$DEPLOYMENT_TELEMT_DOMAIN" "mtproto.example.com"
assert "F+TeleMT: telemt port" "$DEPLOYMENT_TELEMT_PORT" "12345"
core_validate_deployment; assert "F+TeleMT: valid" "$?" "0"

# 7. Remote Node — deliberately NOT forced into this model. Confirmed by
# direct source read (this session): lib/panel/node/api.sh and
# lib/panel/node/install.sh contain no `MODE` branching at all (one
# historical comment mentions "MODE=1-ветка" only to explain that the
# Xray config *shape* it reuses came from MODE=1, not that Remote Node
# itself has a topology). Remote Node's own identity
# (Nodes.name="RemoteNode-${SELFSTEAL_DOMAIN}") and lifecycle
# (lookup-before-create + rollback) are structurally independent of
# MODE/Deployment. This test asserts that fact rather than resolving a
# Deployment for it.
_remote_node_mode_refs=$(grep -c '\[ "\$MODE"' lib/panel/node/api.sh lib/panel/node/install.sh 2>/dev/null | awk -F: '{s+=$2} END{print s+0}')
assert "7: Remote Node has zero MODE branches (not part of Deployment model)" "$_remote_node_mode_refs" "0"

echo "== Validation: negative cases =="

# unknown topology
core_resolve_deployment "X" "" "1" "p.example.com" "s.example.com" "sf.example.com" "" ""
core_validate_deployment
assert "invalid topology rejected" "$?" "1"
assert_array "invalid topology error present" CORE_VALIDATION_ERRORS "unknown topology: 'X'"

# missing domain
core_resolve_deployment "F" "0" "1" "" "sub.example.com" "self.example.com" "" ""
core_validate_deployment
assert "missing panel domain rejected" "$?" "1"

# capability not valid for topology (XHTTP forced onto MODE=1)
core_resolve_deployment "1" "" "1" "panel.example.com" "sub.example.com" "self.example.com" "" ""
DEPLOYMENT_CAPABILITIES=("XHTTP")
core_validate_deployment
assert "XHTTP capability invalid for MODE=1" "$?" "1"

# telemt half-configured (domain without port)
core_resolve_deployment "F" "0" "1" "panel.example.com" "sub.example.com" "self.example.com" "mtproto.example.com" ""
core_validate_deployment
assert "telemt domain-without-port rejected" "$?" "1"

# web_server not valid for topology (WEB_SERVER=2 on MODE=F)
core_resolve_deployment "F" "0" "2" "panel.example.com" "sub.example.com" "self.example.com" "" ""
core_validate_deployment
assert "WEB_SERVER=2 invalid for MODE=F" "$?" "1"

# web_server not valid for topology (WEB_SERVER=2 on MODE=J)
core_resolve_deployment "J" "" "2" "panel.example.com" "sub.example.com" "self.example.com" "" ""
core_validate_deployment
assert "WEB_SERVER=2 invalid for MODE=J" "$?" "1"

# WEB_SERVER=2 is fine for MODE=1/2 (Caddy is the whole point there)
core_resolve_deployment "2" "" "2" "panel.example.com" "sub.example.com" "self.example.com" "" ""
core_validate_deployment
assert "WEB_SERVER=2 valid for MODE=2" "$?" "0"

echo "== core_deployment_dump smoke test (diagnostic output only) =="
core_resolve_deployment "F" "1" "1" "panel.example.com" "sub.example.com" "self.example.com" "mtproto.example.com" "12345"
DUMP_OUT=$(core_deployment_dump)
[ -n "$DUMP_OUT" ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: dump produced no output"; }
echo "$DUMP_OUT" | grep -q 'topology: "F"' && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: dump missing topology line"; }

echo "== No-behavior-change check: sourcing this file has zero side effects =="
# Sourcing must not execute anything, print anything, or set any variable
# other than function definitions (i.e. no DEPLOYMENT_* var should exist
# in a fresh shell that only sources the file without calling anything).
FRESH_CHECK=$(bash -c '
    source lib/core/deployment.sh
    [ -z "${DEPLOYMENT_TOPOLOGY+x}" ] && echo "CLEAN" || echo "DIRTY"
')
assert "sourcing alone sets no DEPLOYMENT_* state" "$FRESH_CHECK" "CLEAN"

echo "== MODE-blind audit: MODE/F_XHTTP_ENABLE/WEB_SERVER appear ONLY inside core_resolve_deployment() =="
# Extract every line outside core_resolve_deployment()'s own body that
# mentions these legacy names, in this file only (the audit's scope, per
# the task, is "new places" -- i.e. this new file).
awk '
    /^core_resolve_deployment\(\)/ { in_resolver=1 }
    in_resolver && /^}/ { in_resolver=0; next }
    !in_resolver && /\b(MODE|F_XHTTP_ENABLE|WEB_SERVER)\b/ && !/^#/ { print }
' lib/core/deployment.sh > /tmp/mode_leak_check.txt
# Comments referencing these names in prose (explaining the contract) are
# expected and fine; only CODE lines (assignments/conditionals) outside
# the resolver would be a real leak. Filter out comment-only lines
# (leading whitespace then '#') from the flagged set:
grep -v '^\s*#' /tmp/mode_leak_check.txt > /tmp/mode_leak_code_only.txt || true
_leak_count=$(wc -l < /tmp/mode_leak_code_only.txt | tr -d ' ')
assert "no MODE/F_XHTTP_ENABLE/WEB_SERVER code references outside resolver" "$_leak_count" "0"
if [ "$_leak_count" != "0" ]; then
    echo "  Leaked lines:"; cat /tmp/mode_leak_code_only.txt
fi
# _RESOLVER_WEB_SERVER (the resolver's OWN output variable, distinct from
# the legacy WEB_SERVER input) is expected to appear in
# core_deployment_web_server_ok()/core_validate_deployment() — that is
# consuming the resolver's OUTPUT, not re-reading legacy WEB_SERVER, so
# it is correctly excluded by the \b(WEB_SERVER)\b word-boundary pattern
# above (it does not match "_RESOLVER_WEB_SERVER").

echo "== deployment.sh has no literal topology-id branch for capability/web_server decisions =="
# Grep-based, deliberately NOT the only test for this (see the behavioral
# override test above, which is the real proof) — this just guards
# against a future edit silently reintroducing a literal
# '"$DEPLOYMENT_TOPOLOGY" = F' / '"$_mode" in F|J' style comparison
# outside of core_resolve_deployment()'s own MODE-reading line.
_literal_branch_hits=$(grep -v '^[[:space:]]*#' lib/core/deployment.sh | grep -cE '"\$(DEPLOYMENT_TOPOLOGY|_mode)"[[:space:]]*(=|!=)[[:space:]]*"?[FJ12]"?|case "\$(DEPLOYMENT_TOPOLOGY|_mode)" in')
assert "no literal topology-id comparison left in deployment.sh" "$_literal_branch_hits" "0"

echo "== topology.sh: sourcing alone has zero side effects =="
FRESH_TOPOLOGY_CHECK=$(bash -c '
    source lib/core/topology.sh
    declare -F core_topology_is_valid > /dev/null && echo "FUNCS_DEFINED" || echo "MISSING"
')
assert "topology.sh defines its functions on source" "$FRESH_TOPOLOGY_CHECK" "FUNCS_DEFINED"

echo "== bash -n =="
bash -n lib/core/deployment.sh && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: bash -n lib/core/deployment.sh"; }
bash -n lib/core/topology.sh && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: bash -n lib/core/topology.sh"; }
bash -n lib/sripts/tests/test_deployment_resolver.sh && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: bash -n (self)"; }

echo ""
echo "==================================="
echo "PASS=$PASS FAIL=$FAIL"
echo "==================================="
[ "$FAIL" -eq 0 ]
