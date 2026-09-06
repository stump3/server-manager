# lib/core/deployment.sh
#
# Sources lib/core/topology.sh (relative to this file, via BASH_SOURCE)
# for the core_topology_* lookup functions this file calls. No existing
# cross-sourcing convention exists yet among lib/core/*.sh files (each is
# currently a standalone leaf loaded once by a central loader this seam
# is explicitly not wired into) — self-sourcing by relative path keeps
# `source lib/core/deployment.sh` alone sufficient for callers/tests,
# rather than requiring them to know topology.sh must be sourced first.
_CORE_DEPLOYMENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./topology.sh
source "${_CORE_DEPLOYMENT_DIR}/topology.sh"
unset _CORE_DEPLOYMENT_DIR
#
# Core/Runtime architecture, first implementation seam:
#
#     legacy CLI/input -> compatibility resolver -> Deployment
#
# Contract for this file: docs/edge_contracts.md + docs/CORE_RUNTIME_CONTRACTS.md
# (verified against origin/variant-f-j @ f46226b / d0b690f — see those two
# documents' own "Verified baseline" lines).
#
# SCOPE OF THIS FILE, STATED EXPLICITLY (per CORE_RUNTIME_CONTRACTS.md §12
# and the task that produced this file):
#   - This is a READ-ONLY / DESCRIPTIVE seam. It turns already-collected
#     legacy install-time values into an explicit `Deployment`
#     representation. It does not call, wrap, or replace any existing
#     generator (variant_f.sh/variant_j.sh/api.sh/render.sh/compose/
#     TeleMT) directly. UPDATED (first adapter seam, see
#     lib/core/adapter_webserver.sh): core_resolve_deployment() IS now
#     called from lib/panel/install.sh's actual install flow — its output
#     (the DEPLOYMENT_* globals set here) is what
#     lib/core/adapter_webserver.sh's panel_core_generate_webserver_config()
#     forwards to the still-unchanged panel_generate_webserver_config().
#     This file's own resolver body is unchanged by that wiring — it is
#     still read-only/descriptive with respect to every generator, and
#     still does not itself call, wrap, or replace variant_f.sh/
#     variant_j.sh/api.sh/render.sh/compose/TeleMT. Only the ADAPTER file
#     added alongside it performs the forwarding call.
#   - No RuntimeComponent, RuntimeObservation, LifecycleIntent, Reconciler,
#     adapter execution, or desired/actual state store is implemented here.
#     Those remain vocabulary-only per CORE_RUNTIME_CONTRACTS.md §11/§12.
#   - MODE (and F_XHTTP_ENABLE/WEB_SERVER, its siblings in the same legacy
#     chain) is read ONLY inside core_resolve_deployment() below — this is
#     the compatibility-resolver boundary the contract requires
#     (edge_contracts.md "Legacy MODE compatibility";
#     CORE_RUNTIME_CONTRACTS.md §8). Nothing downstream of this file's
#     public surface (core_validate_deployment, core_deployment_dump) reads
#     MODE/F_XHTTP_ENABLE/WEB_SERVER directly — they read DEPLOYMENT_*
#     fields only. This is the exact invariant the task's "MODE-blind test"
#     checks for.

# core_resolve_deployment — the compatibility resolver.
#
# Input: the existing legacy values, exactly as lib/panel/cli.sh and
# lib/panel/install.sh already collect them today. This function does not
# introduce a second source for any of them — it is called WITH those
# already-set variables' values, never re-reading a file/env of its own.
#
#   $1  MODE              "1" | "2" | "F" | "J"
#   $2  F_XHTTP_ENABLE     "0" | "1" | ""   (only meaningful for MODE=F;
#                                            ignored otherwise, per Edge's
#                                            own Capability table: J's
#                                            XHTTP is topology-required,
#                                            never a toggle)
#   $3  WEB_SERVER         "1" | "2" | ""
#   $4  PANEL_DOMAIN
#   $5  SUB_DOMAIN
#   $6  SELFSTEAL_DOMAIN
#   $7  TELEMT_DOMAIN      "" if TeleMT integration is off
#   $8  TELEMT_PORT        "" if TeleMT integration is off
#
# Output: sets DEPLOYMENT_* globals (see "Deployment shape" below). Bash
# has no return-by-value for structured data, and this project is
# shell-only (no interpreter change) — namespaced globals are the
# simplest idiomatic representation available, matching the task's own
# "самый простой идиоматичный вариант" instruction. Every call resets all
# DEPLOYMENT_* fields first, so stale state from a previous call can never
# leak into the next one.
#
# Deployment shape (CORE_RUNTIME_CONTRACTS.md §3.1):
#   DEPLOYMENT_TOPOLOGY          reference to one Edge Topology, by its id
#                                 ("1"|"2"|"F"|"J") — NOT a copy of that
#                                 Topology's own fields (public_ingress_
#                                 owner/required_listeners/... stay on the
#                                 Edge side, conceptually; see the "Edge
#                                 Topology has no code embodiment yet"
#                                 caveat below).
#   DEPLOYMENT_CAPABILITIES       array of the OPTIONAL capabilities
#                                 actually turned on. Required capabilities
#                                 (J's XHTTP) are never listed here — they
#                                 are implied by DEPLOYMENT_TOPOLOGY alone,
#                                 exactly as Edge's Capability table states.
#   DEPLOYMENT_DOMAIN_PANEL       )
#   DEPLOYMENT_DOMAIN_SUB         ) Edge Domain contract roles, by value —
#   DEPLOYMENT_DOMAIN_SELFSTEAL   ) no second Domain model, just the roles
#                                 ) Edge already names, held as data.
#   DEPLOYMENT_TELEMT_PRESENT     "1" | "0" — whether telemt block exists
#   DEPLOYMENT_TELEMT_DOMAIN      "" when DEPLOYMENT_TELEMT_PRESENT=0
#   DEPLOYMENT_TELEMT_PORT        "" when DEPLOYMENT_TELEMT_PRESENT=0
#
# Fields deliberately NOT included (matching CORE_RUNTIME_CONTRACTS.md
# §3.1's own "Fields considered and not added" list):
#   - No DEPLOYMENT_WEB_SERVER field on Deployment itself. WEB_SERVER is
#     kept as a separate, resolver-local concern (see
#     core_deployment_web_server_ok() below) rather than a Deployment
#     field, because the contract's own position (§3.1) is that
#     WEB_SERVER really belongs on Edge's Topology (a provider-choice
#     fact), not duplicated onto Deployment — but Edge's Topology has no
#     code embodiment in this branch yet (see caveat below), so there is
#     nowhere correct to *put* it as a first-class field without either
#     duplicating it onto Deployment (which the contract says not to do)
#     or inventing the missing Topology object (out of scope for this
#     seam, per the task). Recorded as Remaining debt in the final report,
#     not silently resolved either way.
#   - No xhttp_public_port/xhttp_internal_port field — those are Edge
#     PortAllocation facts, looked up by (topology, capability, role), not
#     re-stated on Deployment (this exact duplication is what Edge's
#     "Current limitations" section already flags for 19444).
#
# TOPOLOGY LOOKUP: lib/core/topology.sh now provides the Edge Topology
# object this file's own CAVEAT used to say didn't exist yet
# (core_topology_is_valid/public_ingress_owner/required_capabilities/
# optional_capabilities/requires_nginx_stream). Every place below that
# needs a semantic fact about a topology id calls one of those functions
# instead of encoding the fact itself — this file no longer contains its
# own `case "$_mode" in F|J)`-shaped tables. See topology.sh's own header
# for why TeleMT and WEB_SERVER are deliberately not modeled as Topology
# capabilities/fields there (same reasoning applies here, unchanged from
# the original CAVEAT: WEB_SERVER is a §14 #3 open question, TeleMT stays
# a separate Deployment field per §3.2 — this update does not reopen
# either decision, it only removes the literal-string stand-in that used
# to encode facts topology.sh now owns).
core_resolve_deployment() {
    local _mode="${1:-}"
    local _f_xhttp_enable="${2:-0}"
    local _web_server="${3:-}"
    local _panel_domain="${4:-}"
    local _sub_domain="${5:-}"
    local _selfsteal_domain="${6:-}"
    local _telemt_domain="${7:-}"
    local _telemt_port="${8:-}"

    # Reset every field first — no stale state survives across calls.
    DEPLOYMENT_TOPOLOGY=""
    DEPLOYMENT_CAPABILITIES=()
    DEPLOYMENT_DOMAIN_PANEL=""
    DEPLOYMENT_DOMAIN_SUB=""
    DEPLOYMENT_DOMAIN_SELFSTEAL=""
    DEPLOYMENT_TELEMT_PRESENT="0"
    DEPLOYMENT_TELEMT_DOMAIN=""
    DEPLOYMENT_TELEMT_PORT=""
    # Resolver-local only, deliberately NOT a Deployment field — see the
    # "Fields deliberately NOT included" note above. Exposed as its own
    # variable (not folded into DEPLOYMENT_*) precisely so it stays
    # visibly outside the Deployment shape while still being resolvable
    # from the same legacy input in one pass.
    _RESOLVER_WEB_SERVER="$_web_server"

    DEPLOYMENT_TOPOLOGY="$_mode"

    # The one and only place in this file that reads MODE for a semantic
    # decision — the compatibility-resolver boundary itself. Note this is
    # no longer a `case "$_mode" in F) ... esac`: XHTTP's admissibility as
    # an OPTIONAL capability is now a topology.sh lookup
    # (core_topology_capability_is_optional), not a literal "$_mode = F"
    # branch. J's XHTTP is topology-required (topology.sh's
    # required_capabilities for "J" already includes it), so it is never
    # a candidate for DEPLOYMENT_CAPABILITIES here regardless of
    # $_f_xhttp_enable — matching CORE_RUNTIME_CONTRACTS.md §4's explicit
    # worked example ("F_XHTTP_ENABLE must not change semantic topology
    # J"), now enforced structurally (J's optional-capability set is
    # simply empty) rather than by this function remembering not to add
    # it for J.
    if [ "$_f_xhttp_enable" = "1" ] && core_topology_capability_is_optional "$_mode" "XHTTP"; then
        DEPLOYMENT_CAPABILITIES+=("XHTTP")
    fi

    DEPLOYMENT_DOMAIN_PANEL="$_panel_domain"
    DEPLOYMENT_DOMAIN_SUB="$_sub_domain"
    DEPLOYMENT_DOMAIN_SELFSTEAL="$_selfsteal_domain"

    if [ -n "$_telemt_domain" ] || [ -n "$_telemt_port" ]; then
        DEPLOYMENT_TELEMT_PRESENT="1"
        DEPLOYMENT_TELEMT_DOMAIN="$_telemt_domain"
        DEPLOYMENT_TELEMT_PORT="$_telemt_port"
    fi
}

# core_deployment_web_server_ok — the ONE fact about WEB_SERVER this seam
# needs (§3.1: "WEB_SERVER... belongs on Topology... F/J are
# nginx-stream{}-only by construction"). Now expressed as a query against
# topology.sh's core_topology_requires_nginx_stream() — i.e. "this
# topology's public_ingress_owner is nginx-stream, and Caddy
# (WEB_SERVER=2) cannot currently serve that" — rather than a literal
# `case "$_mode" in F|J)`. The observable rule is unchanged (still exactly
# F and J today, since those are the only two topologies with
# public_ingress_owner=nginx-stream), but it is no longer this file's own
# second F/J-shaped table — it is a derived consequence of the one
# Topology fact topology.sh owns. Mirrors the same condition already
# enforced today in lib/panel/cli.sh's panel_cli_select_webserver().
core_deployment_web_server_ok() {
    local _mode="$1" _web_server="$2"
    core_topology_requires_nginx_stream "$_mode" || return 0
    [ "$_web_server" != "2" ]
}

# core_validate_deployment — validates the DEPLOYMENT_* globals set by the
# most recent core_resolve_deployment() call. Returns 0 (valid) or 1
# (invalid, with CORE_VALIDATION_ERRORS populated). Reads only
# DEPLOYMENT_*/_RESOLVER_WEB_SERVER fields — never MODE/F_XHTTP_ENABLE
# directly (see the MODE-blind invariant stated at the top of this file).
core_validate_deployment() {
    CORE_VALIDATION_ERRORS=()

    core_topology_is_valid "$DEPLOYMENT_TOPOLOGY" || \
        CORE_VALIDATION_ERRORS+=("unknown topology: '${DEPLOYMENT_TOPOLOGY}'")

    [ -z "$DEPLOYMENT_DOMAIN_PANEL" ]     && CORE_VALIDATION_ERRORS+=("missing domain: panel")
    [ -z "$DEPLOYMENT_DOMAIN_SUB" ]       && CORE_VALIDATION_ERRORS+=("missing domain: sub")
    [ -z "$DEPLOYMENT_DOMAIN_SELFSTEAL" ] && CORE_VALIDATION_ERRORS+=("missing domain: selfsteal")

    # Capability admissibility — a capability listed in
    # DEPLOYMENT_CAPABILITIES must be in this topology's OPTIONAL set
    # (topology.sh). No literal "$DEPLOYMENT_TOPOLOGY != 'F'"-style check:
    # today XHTTP is the only capability this seam models, and it happens
    # to be optional only for F, but this loop does not know or care
    # which topology that is — it only knows "optional, per topology.sh,
    # or not". A capability that's valid but simply not in the known set
    # this seam recognizes (currently only "XHTTP") is still rejected as
    # unknown, same as before.
    local _cap
    for _cap in "${DEPLOYMENT_CAPABILITIES[@]:-}"; do
        [ -z "$_cap" ] && continue
        case "$_cap" in
            XHTTP)
                core_topology_capability_is_optional "$DEPLOYMENT_TOPOLOGY" "$_cap" || \
                    CORE_VALIDATION_ERRORS+=("capability '${_cap}' is not valid for topology '${DEPLOYMENT_TOPOLOGY}'")
                ;;
            *)
                CORE_VALIDATION_ERRORS+=("unknown capability: '${_cap}'")
                ;;
        esac
    done

    # TeleMT block internal consistency: domain and port must both be
    # present or both be absent — never one without the other (a
    # half-configured TeleMT integration has no valid meaning downstream:
    # variant_f.sh/variant_j.sh's own TELEMT_MAP_LINE/TELEMT_UPSTREAM
    # generation is gated on TELEMT_DOMAIN being non-empty alone, so a
    # domain-without-port would silently generate a broken nginx upstream
    # pointing at an empty port).
    if [ "$DEPLOYMENT_TELEMT_PRESENT" = "1" ]; then
        [ -z "$DEPLOYMENT_TELEMT_DOMAIN" ] && CORE_VALIDATION_ERRORS+=("telemt: present but domain is empty")
        [ -z "$DEPLOYMENT_TELEMT_PORT" ]   && CORE_VALIDATION_ERRORS+=("telemt: present but port is empty")
    else
        [ -n "$DEPLOYMENT_TELEMT_DOMAIN" ] && CORE_VALIDATION_ERRORS+=("telemt: not present but domain is set")
        [ -n "$DEPLOYMENT_TELEMT_PORT" ]   && CORE_VALIDATION_ERRORS+=("telemt: not present but port is set")
    fi

    # WEB_SERVER admissibility for this topology/adapter availability —
    # see core_deployment_web_server_ok()'s own comment for why this is
    # one reused fact, not a second table.
    if [ -n "$_RESOLVER_WEB_SERVER" ]; then
        core_deployment_web_server_ok "$DEPLOYMENT_TOPOLOGY" "$_RESOLVER_WEB_SERVER" || \
            CORE_VALIDATION_ERRORS+=("web_server '${_RESOLVER_WEB_SERVER}' is not valid for topology '${DEPLOYMENT_TOPOLOGY}' (nginx stream{} required)")
    fi

    [ "${#CORE_VALIDATION_ERRORS[@]}" -eq 0 ]
}

# core_deployment_dump — diagnostic/debug representation only (explicitly
# permitted by the task: "Можно добавить диагностический/debug
# representation, если это не меняет behavior"). Never called from any
# install path; purely for tests/manual inspection.
core_deployment_dump() {
    echo "Deployment:"
    echo "  topology: \"${DEPLOYMENT_TOPOLOGY}\""
    if [ "${#DEPLOYMENT_CAPABILITIES[@]}" -eq 0 ]; then
        echo "  capabilities: []"
    else
        echo "  capabilities: [${DEPLOYMENT_CAPABILITIES[*]}]"
    fi
    echo "  domains:"
    echo "    panel: \"${DEPLOYMENT_DOMAIN_PANEL}\""
    echo "    sub:   \"${DEPLOYMENT_DOMAIN_SUB}\""
    echo "    selfsteal: \"${DEPLOYMENT_DOMAIN_SELFSTEAL}\""
    if [ "$DEPLOYMENT_TELEMT_PRESENT" = "1" ]; then
        echo "  telemt:"
        echo "    domain: \"${DEPLOYMENT_TELEMT_DOMAIN}\""
        echo "    port: ${DEPLOYMENT_TELEMT_PORT}"
    else
        echo "  telemt: absent"
    fi
}
