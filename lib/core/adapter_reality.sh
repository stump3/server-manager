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
#     TeleMT logic, no RuntimeComponent reference, and no topology table
#     of its own.
#   - Does not touch panel_reality_needs_2222_ufw_rule(),
#     panel_reality_dest_val(), panel_reality_inbound_port(), or
#     panel_reality_xhttp_inbound_port() -- those remain legacy
#     intentionally (see docs/CORE_RUNTIME_CONTRACTS.md-adjacent forensic
#     scan: their MODE split needs either a not-yet-modeled "colocated"
#     concept or the not-yet-implemented PortAllocation contract, neither
#     of which this file introduces).
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
