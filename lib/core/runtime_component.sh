# lib/core/runtime_component.sh
#
# Second Core/Runtime seam:
#
#     Deployment (lib/core/deployment.sh, already resolved)
#         ↓
#     RuntimeComponent inventory (this file)
#
# Contract: docs/CORE_RUNTIME_CONTRACTS.md §5.2 (RuntimeComponent field
# list, individually justified) + §5.1 (ownership table, reused verbatim
# from docs/edge_contracts.md's "Runtime ownership" section) + §5.4
# (explicit non-claims this file must not contradict).
#
# SCOPE OF THIS FILE, STATED EXPLICITLY (mirrors deployment.sh's own
# scope note, for the same reason):
#   - Pure declarative inventory. Given an already-resolved Deployment
#     (i.e. after a core_resolve_deployment() call), this file answers
#     "which logical RuntimeComponents does this Deployment imply, and
#     what does the ownership contract say about each one" — nothing
#     more.
#   - Reads ONLY: DEPLOYMENT_* globals (set by deployment.sh) and
#     core_topology_* functions (topology.sh). Never reads MODE/
#     F_XHTTP_ENABLE/WEB_SERVER directly — same MODE-blind invariant as
#     deployment.sh, extended to this file (see test's own audit).
#   - Does NOT run `docker ps`, `systemctl status`, `nginx -T`, any Xray
#     runtime inspection, or anything else that reads real system state.
#     This is desired-shape inventory, not RuntimeObservation (§5.3) —
#     that boundary is the single most important invariant this file
#     must not cross, per the task that produced it.
#   - Does NOT implement lifecycle_state values or a state machine of any
#     kind (§5.4: no such state machine exists in variant-f-j for any
#     component today). See "Fields NOT implemented" below for the
#     specific, deliberate handling of §5.2's `lifecycle_state` field.
#   - Not wired into lib/panel/install.sh or any generator. Sourcing this
#     file has zero side effects, same as deployment.sh/topology.sh.
#
# Fields from CORE_RUNTIME_CONTRACTS.md §5.2's RuntimeComponent outline,
# and how each is (or isn't) represented here:
#
#   - identity              IMPLEMENTED — see core_runtime_component_identity()
#   - type                  IMPLEMENTED — one of: nginx | xray | panel |
#                            telemt | remote_node (the fixed 5-value
#                            enum from Edge's ownership table; no sixth
#                            value added speculatively)
#   - configuration_owner   IMPLEMENTED — core_runtime_component_configuration_owner()
#   - runtime_owner         IMPLEMENTED — core_runtime_component_runtime_owner()
#   - integration_owner     IMPLEMENTED — core_runtime_component_integration_owner()
#   - lifecycle_state       DELIBERATELY NOT IMPLEMENTED. §5.2 lists this
#                            as a field ("vocabulary only, not
#                            implemented" — no state-machine code exists
#                            for any component today), but the task that
#                            produced this file explicitly instructed
#                            against adding it to the concrete
#                            RuntimeComponent representation, to avoid
#                            any risk of this inventory seam being read
#                            as if it tracks or claims actual lifecycle
#                            state (which would contradict §5.4's
#                            explicit non-claim outright). This is a
#                            genuine, recorded tension between the task's
#                            instruction and the contract document's own
#                            field list — flagged in the final report as
#                            a remaining architectural question, not
#                            silently resolved either way.
#   - dependencies          IMPLEMENTED, narrowly — see
#                            core_runtime_component_dependencies(). §5.2
#                            justifies this field with exactly one
#                            current, real fact (nginx's generated config
#                            has a config-time dependency on TeleMT's
#                            domain/port existing, even though nginx
#                            never becomes TeleMT's runtime_owner) — only
#                            that one dependency is represented; nothing
#                            speculative.
#
# Component-presence rules used below are all derived from topology.sh's
# capability lists, never from a literal MODE/topology-id comparison —
# see core_runtime_component_types_for_deployment()'s own comments for
# the reasoning behind each of the 4 (not 5 — remote_node is deliberately
# excluded, see below) types' presence condition.
#
# remote_node is a fixed member of the type enum (Edge's ownership table
# lists it, so its owner mapping is defined below) but is NOT
# automatically added to any Deployment's inventory here. This is a
# recorded, deliberate exclusion, not an oversight: `lib/panel/node/*.sh`
# (Remote Node's actual registration code) takes no MODE input at all
# (confirmed by test_deployment_resolver.sh's own "Remote Node has zero
# MODE branches" assertion) — there is no current code path by which
# core_resolve_deployment()'s inputs could tell us "this Deployment also
# manages a Remote Node" without inventing a rule the contract does not
# state. Treated as an open architectural question, not resolved here.

# ---------------------------------------------------------------------
# Canonical ownership mapping — the ONLY place type -> owner is encoded.
# Matches docs/edge_contracts.md's "Runtime ownership" table verbatim.
# There must never be a second, independent type->owner table anywhere
# else in this codebase; if one is ever needed, it should call these
# functions rather than re-stating the mapping.
# ---------------------------------------------------------------------

core_runtime_component_configuration_owner() {
    case "${1:-}" in
        nginx|xray)  echo "panel" ;;
        telemt)      echo "telemt" ;;
        panel)       echo "panel" ;;
        remote_node) echo "panel" ;;   # Edge: "Panel (remote)"
        *) return 1 ;;
    esac
}

core_runtime_component_runtime_owner() {
    case "${1:-}" in
        nginx|xray) echo "panel-compose" ;;
        telemt)     echo "telemt" ;;
        panel)      echo "panel-compose" ;;
        remote_node) echo "remote-host" ;;  # Edge: "remote host, outside this repo"
        *) return 1 ;;
    esac
}

core_runtime_component_integration_owner() {
    case "${1:-}" in
        nginx|xray|telemt|remote_node) echo "panel" ;;
        panel) echo "" ;;   # Edge table: "—" (no integration owner above Panel itself)
        *) return 1 ;;
    esac
}

# core_runtime_component_identity <type> — see file header for why only
# remote_node has a contractually-confirmed identity scheme today.
core_runtime_component_identity() {
    case "${1:-}" in
        remote_node)
            # Confirmed, CORE_RUNTIME_CONTRACTS.md §5.2:
            # Nodes.name = "RemoteNode-${SELFSTEAL_DOMAIN}". Uses the
            # already-resolved Deployment's own selfsteal domain, not a
            # second input.
            [ -n "${DEPLOYMENT_DOMAIN_SELFSTEAL:-}" ] || return 1
            echo "RemoteNode-${DEPLOYMENT_DOMAIN_SELFSTEAL}"
            ;;
        nginx|xray|panel|telemt)
            # No richer identity is confirmed by contract for these four
            # (§5.2 only verified Remote Node's). Each is a singleton per
            # Deployment in current code (one nginx config, one Xray
            # config, one Panel, one TeleMT integration per install), so
            # the type name itself is a stable, sufficient identity for
            # this seam's purpose today. NOT invented as a permanent
            # scheme — flagged in the final report as an open question
            # for whenever a component could exist more than once per
            # Deployment (no such case exists in variant-f-j today).
            echo "${1}"
            ;;
        *) return 1 ;;
    esac
}

# core_runtime_component_dependencies <type> — must be called with the
# Deployment already resolved (reads DEPLOYMENT_TELEMT_PRESENT). Only the
# one dependency §5.2 justifies with a current, real fact: nginx's
# generated config requires TeleMT's domain/port to exist at
# generation-time (variant_f.sh's TELEMT_MAP_LINE/TELEMT_UPSTREAM,
# emitted only `if [ -n "$TELEMT_DOMAIN" ]`) even though nginx never
# becomes TeleMT's runtime_owner. No other dependency is modeled.
core_runtime_component_dependencies() {
    case "${1:-}" in
        nginx)
            if [ "${DEPLOYMENT_TELEMT_PRESENT:-0}" = "1" ]; then
                echo "telemt"
            else
                echo ""
            fi
            ;;
        xray|panel|telemt|remote_node) echo "" ;;
        *) return 1 ;;
    esac
}

# core_runtime_component_types_for_deployment — the actual inventory
# question: given the Deployment currently resolved (DEPLOYMENT_* globals
# already set by core_resolve_deployment()), which component types does
# it imply? Echoes a space-separated list. Every rule below is expressed
# through topology.sh's capability lookups, never a literal
# "$DEPLOYMENT_TOPOLOGY" = "F"/"J" comparison.
core_runtime_component_types_for_deployment() {
    local _topology="${DEPLOYMENT_TOPOLOGY:-}"
    core_topology_is_valid "$_topology" || return 1

    local _types=()

    # panel: every resolved Deployment is a Panel install by construction
    # (core_resolve_deployment() has no "no Panel" case) — always present.
    _types+=("panel")

    # nginx: present whenever this topology's public ingress is owned by
    # nginx in ANY form (http-only for MODE=2, stream for F/J) — i.e.
    # whenever it is NOT "xray" (MODE=1, where Xray itself is the public
    # ingress and no nginx sits in front of it). Derived from
    # public_ingress_owner, not from a MODE=1-vs-not comparison.
    local _owner
    _owner="$(core_topology_public_ingress_owner "$_topology")"
    [ "$_owner" != "xray" ] && _types+=("nginx")

    # xray: present whenever this Deployment has at least one Xray-backed
    # capability active — Vision (required by 1/F/J, NOT required by 2 —
    # MODE=2's Xray runs on the remote node, not locally) or XHTTP
    # (required by J, optional-and-active for F). Derived from topology's
    # required_capabilities plus the Deployment's own active optional
    # capabilities — never a literal MODE check.
    local _required _cap _has_xray_capability=1
    _required="$(core_topology_required_capabilities "$_topology")"
    for _cap in $_required; do
        case "$_cap" in Vision|XHTTP) _has_xray_capability=0 ;; esac
    done
    for _cap in "${DEPLOYMENT_CAPABILITIES[@]:-}"; do
        case "$_cap" in XHTTP) _has_xray_capability=0 ;; esac
    done
    [ "$_has_xray_capability" -eq 0 ] && _types+=("xray")

    # telemt: present iff the resolved Deployment's own TeleMT block is
    # present — independent of topology entirely (TeleMT is an optional
    # integration available under both F and J, never a topology
    # capability — CORE_RUNTIME_CONTRACTS.md §3.2).
    [ "${DEPLOYMENT_TELEMT_PRESENT:-0}" = "1" ] && _types+=("telemt")

    # remote_node: deliberately never added here — see file header.

    echo "${_types[*]}"
}

# core_runtime_component_dump — diagnostic only (mirrors
# core_deployment_dump()'s own stated purpose: never called from any
# install path, purely for tests/manual inspection). Prints the full
# inventory for the currently-resolved Deployment.
core_runtime_component_dump() {
    local _types _t
    _types="$(core_runtime_component_types_for_deployment)" || { echo "invalid deployment"; return 1; }
    echo "RuntimeComponent inventory for topology '${DEPLOYMENT_TOPOLOGY}':"
    for _t in $_types; do
        echo "  - type: ${_t}"
        echo "    identity: $(core_runtime_component_identity "$_t" 2>/dev/null)"
        echo "    configuration_owner: $(core_runtime_component_configuration_owner "$_t")"
        echo "    runtime_owner: $(core_runtime_component_runtime_owner "$_t")"
        echo "    integration_owner: $(core_runtime_component_integration_owner "$_t")"
        local _deps
        _deps="$(core_runtime_component_dependencies "$_t")"
        echo "    dependencies: [${_deps}]"
    done
}

# core_runtime_component_exists <type> — 0 if <type> is present in the
# currently-resolved Deployment's inventory, 1 otherwise. Added as a
# small, natural predicate alongside the existing
# core_runtime_component_types_for_deployment() list accessor (same
# pattern as topology.sh's core_topology_capability_is_optional()
# sitting next to core_topology_optional_capabilities()) — not a new
# field, not a new type, not a redesign of this file's model. Exists
# because callers that only need a yes/no answer for one type (e.g. "is
# xray present") would otherwise have to re-implement this exact
# string-membership loop themselves at every call site — first real
# consumer: lib/core/adapter_reality.sh.
core_runtime_component_exists() {
    local _want="${1:-}" _types _t
    _types="$(core_runtime_component_types_for_deployment)" || return 1
    for _t in $_types; do
        [ "$_t" = "$_want" ] && return 0
    done
    return 1
}
