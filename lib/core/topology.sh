# lib/core/topology.sh
#
# The single, canonical Edge Topology lookup for variant-f-j.
#
# Contract: docs/edge_contracts.md's "Current topology matrix" and
# "Topology contract" sections, verbatim — this file is a code-side
# lookup over exactly the facts already stated there, not a second or
# reinterpreted table. If this file and docs/edge_contracts.md ever
# disagree, the doc is the source of truth and this file has a bug.
#
# WHY THIS FILE EXISTS (the gap it closes): lib/core/deployment.sh
# previously carried its own small, closed-set encoding of these same
# facts directly inline (a `case "$_mode" in F) ... esac` for optional
# capabilities, a literal `"$DEPLOYMENT_TOPOLOGY" != "F"` check for XHTTP
# admissibility, a literal `case "$_mode" in F|J)` for the nginx-stream
# requirement) — its own comments flagged this explicitly as "the minimum
# needed to make this seam runnable before an actual Topology object
# exists in code". This file is that object. deployment.sh is updated to
# call these functions instead of encoding the facts itself, so there is
# now exactly ONE place semantic topology truth lives, not two agreeing
# tables.
#
# SCOPE: same as deployment.sh — read-only/descriptive, no runtime
# effect, not wired into lib/panel/install.sh, no generator touched.
# Sourcing this file has zero side effects (see test's "no side effects"
# check, mirrored for this file too).
#
# Deliberately excluded from this file (see docs/CORE_RUNTIME_CONTRACTS.md
# §14 #3, still an open question, not decided here):
#   - `web_server` is NOT modeled as a Topology field with two values
#     ("nginx" vs "caddy") here. What IS modeled, because it is the one
#     fact actually needed today, is `public_ingress_owner` — and F/J both
#     already have the same value ("nginx-stream") for it, which is the
#     real reason WEB_SERVER=2 (Caddy) is rejected for F/J: Caddy's
#     mholt/caddy-l4 gap means nothing can currently serve
#     public_ingress_owner="nginx-stream", not a rule about F or J by
#     name. core_topology_requires_nginx_stream() below expresses exactly
#     that one derived fact — it is not a second WEB_SERVER table.
#   - TeleMT is NOT listed in any topology's capability sets here, even
#     though docs/edge_contracts.md's own Capability table lists it
#     alongside XHTTP. CORE_RUNTIME_CONTRACTS.md §3.2 already decided
#     TeleMT is modeled as a separate Deployment field
#     (DEPLOYMENT_TELEMT_*), not a Capability list entry — this file
#     matches that decision rather than reopening it. Adding TeleMT to
#     core_topology_optional_capabilities() would create exactly the kind
#     of second, disagreeing model CORE_RUNTIME_CONTRACTS.md §3.2 already
#     ruled out.

# core_topology_is_valid <id> — 0 if id is one of the four current
# topologies, 1 otherwise. The one place the closed set "1 2 F J" is
# spelled out; every other function below dispatches on this same set
# and returns empty/failure for anything else.
core_topology_is_valid() {
    case "${1:-}" in
        1|2|F|J) return 0 ;;
        *) return 1 ;;
    esac
}

# core_topology_public_ingress_owner <id> — echoes one of
# "xray" | "nginx-http" | "nginx-stream", per edge_contracts.md's
# topology matrix "Public ingress owner" column. Empty output + exit 1
# for an unknown id.
core_topology_public_ingress_owner() {
    case "${1:-}" in
        1) echo "xray" ;;
        2) echo "nginx-http" ;;
        F|J) echo "nginx-stream" ;;
        *) return 1 ;;
    esac
}

# core_topology_required_capabilities <id> — echoes a space-separated
# list, per edge_contracts.md's topology matrix "Required capabilities"
# column. This is the one place that encodes "J requires XHTTP
# intrinsically" as data, not as a downstream `topology == J` branch.
core_topology_required_capabilities() {
    case "${1:-}" in
        1) echo "Vision" ;;
        2) echo "PanelSub" ;;
        F) echo "Vision" ;;
        J) echo "Vision XHTTP" ;;
        *) return 1 ;;
    esac
}

# core_topology_optional_capabilities <id> — echoes a space-separated
# list (possibly empty) of capabilities this topology CAN carry but does
# not require. Per edge_contracts.md's Capability table: XHTTP is
# optional for F only (real CLI toggle, F_XHTTP_ENABLE); no other
# topology has an optional capability in this list (TeleMT excluded —
# see file header).
core_topology_optional_capabilities() {
    case "${1:-}" in
        1|2|J) echo "" ;;
        F) echo "XHTTP" ;;
        *) return 1 ;;
    esac
}

# core_topology_capability_is_optional <id> <capability> — 0 if
# <capability> appears in <id>'s optional set, 1 otherwise (including for
# an unknown id/capability). This is the one predicate deployment.sh
# needs to decide "should this optional capability, if requested, be
# added to DEPLOYMENT_CAPABILITIES" without itself branching on topology
# id by name.
core_topology_capability_is_optional() {
    local _id="${1:-}" _cap="${2:-}" _opt _found=1 _c
    _opt="$(core_topology_optional_capabilities "$_id")" || return 1
    for _c in $_opt; do
        [ "$_c" = "$_cap" ] && _found=0
    done
    return "$_found"
}

# core_topology_capability_is_required <id> <capability> — same shape,
# for the required set (used by validation to explain, if ever needed,
# why a capability doesn't need to be listed as optional for a given
# topology; not currently called by deployment.sh's validator but kept
# symmetrical with core_topology_capability_is_optional() rather than
# leaving the required side only checkable by reading the list by hand).
core_topology_capability_is_required() {
    local _id="${1:-}" _cap="${2:-}" _req _found=1 _c
    _req="$(core_topology_required_capabilities "$_id")" || return 1
    for _c in $_req; do
        [ "$_c" = "$_cap" ] && _found=0
    done
    return "$_found"
}

# core_topology_requires_nginx_stream <id> — 0 if this topology's
# public_ingress_owner is "nginx-stream" (currently: F and J), 1
# otherwise. This is the single derived fact
# core_deployment_web_server_ok() in deployment.sh now queries instead of
# containing its own `case "$_mode" in F|J)` — expressed as a query
# against public_ingress_owner, not as a second F/J-shaped table.
core_topology_requires_nginx_stream() {
    local _owner
    _owner="$(core_topology_public_ingress_owner "${1:-}")" || return 1
    [ "$_owner" = "nginx-stream" ]
}
