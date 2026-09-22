# lib/core/adapter_reality.sh
#
# Second Core/Runtime adapter seam, following the same pattern as
# lib/core/adapter_webserver.sh (see that file's header for the general
# shape of this pattern):
#
#     legacy input (already-resolved Deployment, see precondition below)
#         ↓
#     DEPLOYMENT_TOPOLOGY
#         ↓
#     core_topology_requires_nginx_stream()   (lib/core/topology.sh, UNCHANGED)
#         ↓
#     panel_core_reality_accept_proxy_protocol() / panel_core_reality_listen_addr()   <-- this file
#         ↓
#     panel_setup_api()'s panel_xray_render_inbounds() call (lib/panel/api.sh, arguments UNCHANGED)
#
# Precondition proven before writing this file (not assumed): grepped
# every call site of panel_setup_api() (exactly one:
# lib/panel/install.sh:312, inside panel_install()) and confirmed
# core_resolve_deployment() already runs unconditionally, earlier in
# that same panel_install() invocation (the same seam
# lib/core/adapter_webserver.sh already relies on), on every path
# (fresh install and panel_reinstall() -> panel_install()). No other
# caller of panel_reality_accept_proxy_protocol()/panel_reality_listen_addr()
# exists outside panel_setup_api()'s own body (the only other references
# are lib/sripts/tests/test_f_xhttp_commit2.sh's direct unit tests of
# the legacy functions themselves, which remain valid and untouched --
# see Step 3 of the task this file implements).
#
# What this adapter does and does not do (identical discipline to
# adapter_webserver.sh):
#   - Reads ONLY DEPLOYMENT_TOPOLOGY (already resolved by the time
#     panel_setup_api() runs) -- never MODE directly.
#   - Makes NO topology decision of its own: both functions are a single
#     call to the existing, unmodified core_topology_requires_nginx_stream(),
#     which already encodes exactly the F/J-vs-1/2 split these two
#     legacy functions hard-coded. No new accessor was added to
#     topology.sh; none was needed -- proven by the byte-identical
#     truth table in lib/sripts/tests/test_adapter_reality.sh.
#   - Contains no MODE branching, no "F"/"J" literal, no port logic, no
#     TeleMT logic, and no topology/component table of its own — both new
#     functions below (panel_core_reality_needs_2222_ufw_rule/_dest_val)
#     delegate entirely to the existing, unmodified
#     core_runtime_component_exists() rather than re-deriving membership.
#   - Does not touch panel_reality_inbound_port() or
#     panel_reality_xhttp_inbound_port() — those return PORT NUMBERS per
#     topology (8443/18443/443, 19444/18444), which is squarely
#     PortAllocation-contract territory, not yet implemented as a Core
#     concept. Migrating them is a distinct, larger seam this session
#     deliberately did not start (see this session's own forensic
#     report).
#
# Expected semantics (must remain byte-identical to the legacy
# functions this replaces at the call site, for every one of the four
# current topologies):
#   accept_proxy_protocol: nginx-stream topology (F, J) -> "true";  otherwise (1, 2) -> "false"
#   listen_addr:            nginx-stream topology (F, J) -> "127.0.0.1"; otherwise (1, 2) -> ""
panel_core_reality_accept_proxy_protocol() {
    if core_topology_requires_nginx_stream "${DEPLOYMENT_TOPOLOGY:-}"; then
        echo "true"
    else
        echo "false"
    fi
}

panel_core_reality_listen_addr() {
    if core_topology_requires_nginx_stream "${DEPLOYMENT_TOPOLOGY:-}"; then
        echo "127.0.0.1"
    else
        echo ""
    fi
}

# --- Added in this session: two more panel_setup_api() decision points ---
#
# Forensic scan (this session) found panel_reality_needs_2222_ufw_rule()
# and panel_reality_dest_val() share ONE underlying fact with each other
# — "does this Deployment have a co-located (local) Xray, or not" — and,
# critically, that this exact fact is already answerable through the
# EXISTING, unmodified lib/core/runtime_component.sh: proven empirically
# for all four current topologies (1, 2, F, J) that
# `core_runtime_component_exists xray` produces the identical true/false
# result as each legacy function's own `[ "$MODE" = "1" ] || "F" || "J"`
# condition. This is NOT a new "colocated" Topology concept — the task's
# own Step 3 explicitly warned against inventing
# core_topology_is_colocated() before checking whether an existing entity
# already answers the question, and RuntimeComponent's xray-presence
# already does, with no modification to that file's model, fields, or
# types needed. No PortAllocation dependency either: neither function
# below produces or consumes a port number.
#
# Precondition: identical to the two functions above — both legacy
# targets have their sole production call site inside panel_setup_api()
# (lib/panel/api.sh:175,264), which already guarantees
# core_resolve_deployment() ran earlier in the same panel_install()
# invocation. Requires lib/core/runtime_component.sh to be loaded (added
# to server-manager.sh's module list in this same change — it was
# previously deliberately unwired, per its own header, since it had no
# production consumer until now).
panel_core_reality_needs_2222_ufw_rule() {
    core_runtime_component_exists "xray"
}

panel_core_reality_dest_val() {
    local _selfsteal_domain="${1:?panel_core_reality_dest_val requires SELFSTEAL_DOMAIN}"
    if core_runtime_component_exists "xray"; then
        echo '/dev/shm/nginx.sock'
    else
        echo "${_selfsteal_domain}:443"
    fi
}
