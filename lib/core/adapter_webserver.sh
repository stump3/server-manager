# lib/core/adapter_webserver.sh
#
# First Core/Runtime adapter seam that actually participates in the real
# execution flow (unlike topology.sh/deployment.sh/runtime_component.sh,
# which are deliberately inert/unwired per their own headers):
#
#     legacy input (lib/panel/install.sh's already-collected locals)
#         ↓
#     core_resolve_deployment()          (lib/core/deployment.sh)
#         ↓
#     Deployment (DEPLOYMENT_* globals)
#         ↓
#     panel_core_generate_webserver_config()      <-- this file
#         ↓
#     panel_generate_webserver_config()   (lib/panel/nginx/config.sh,
#                                           UNCHANGED — still does its own
#                                           internal MODE=F/J dispatch,
#                                           exactly as before)
#
# What this adapter does and does not do (docs/CORE_RUNTIME_CONTRACTS.md
# §8's placement rule, applied literally):
#   - It reads ONLY already-resolved DEPLOYMENT_*/_RESOLVER_WEB_SERVER
#     globals (set by a prior core_resolve_deployment() call) plus the
#     handful of purely legacy-transport values Deployment never modeled
#     at all (see below) — never MODE/F_XHTTP_ENABLE/WEB_SERVER directly.
#   - It makes NO topology decision of its own. DEPLOYMENT_TOPOLOGY is
#     forwarded byte-for-byte as panel_generate_webserver_config()'s MODE
#     argument — that function still contains the one and only
#     [ "$MODE" = "J" ] / [ "$MODE" = "F" ] branch that picks
#     panel_generate_nginx_config_j()/_f(), unchanged. This file does not
#     add a second "F -> variant_f, J -> variant_j" table anywhere.
#   - It does NOT use lib/core/runtime_component.sh. Investigated first:
#     core_runtime_component_types_for_deployment() answers "which
#     component TYPES exist" (nginx|xray|panel|telemt|remote_node) and
#     returns the identical {panel, nginx, xray} set for BOTH MODE=F and
#     MODE=J — its 5-value type enum has no way to distinguish which
#     nginx *variant* to run, and was never meant to (RuntimeComponent is
#     inventory, not dispatch, per its own file header's §5.2 scope).
#     Answering "which generator" from DEPLOYMENT_TOPOLOGY directly is
#     not a new table — it is the same "F"|"J" identity Edge's own
#     Topology.id contract already defines as the dispatch key, sourced
#     from Core's resolved Deployment instead of a raw MODE local.
#   - It does NOT change what panel_generate_webserver_config() or either
#     F/J generator receives: DEPLOYMENT_DOMAIN_PANEL/_SUB/_SELFSTEAL and
#     DEPLOYMENT_TELEMT_DOMAIN/_PORT are copies of the exact same values
#     core_resolve_deployment() was called with (PANEL_DOMAIN/SUB_DOMAIN/
#     SELFSTEAL_DOMAIN/TELEMT_DOMAIN/TELEMT_PORT) — this is a round trip,
#     not a transformation. The one derived value, F_XHTTP_ENABLE, is
#     recovered losslessly from DEPLOYMENT_CAPABILITIES containing
#     "XHTTP" (present iff F_XHTTP_ENABLE="1" was passed to the resolver
#     — see deployment.sh's own core_resolve_deployment(), which only
#     ever adds "XHTTP" when core_topology_capability_is_optional()
#     agrees, which is true only for topology "F"). The generated
#     nginx.conf is therefore provably byte-identical to calling
#     panel_generate_webserver_config() directly with the original
#     legacy values — proven by test_adapter_webserver.sh's diff check,
#     not merely argued here.
#
# Legacy-transport arguments Deployment does NOT model at all (per
# CORE_RUNTIME_CONTRACTS.md §3.1's own "Fields considered and not added"
# list, plus PC/SC/STC/COOKIE_KEY/COOKIE_VAL, which no Core document has
# ever claimed — these are certificate-path domain values and mgmt-script
# cookie auth tokens, orthogonal to any architectural decision):
#   $1  PC           certificate-path domain for Panel's vhost
#   $2  SC           certificate-path domain for Sub's vhost
#   $3  STC          certificate-path domain for Selfsteal's vhost
#   $4  COOKIE_KEY
#   $5  COOKIE_VAL
#
# Precondition: the caller MUST have already called core_resolve_deployment()
# with this same install's legacy values. This function does not call it
# itself — it is an adapter over an already-resolved Deployment, not a
# second resolver entry point (mirrors deployment.sh's own layering: the
# resolver's job stops at DEPLOYMENT_*; this file's job starts there).
panel_core_generate_webserver_config() {
    local PC="$1" SC="$2" STC="$3" COOKIE_KEY="$4" COOKIE_VAL="$5"

    # The one and only place this adapter inspects DEPLOYMENT_CAPABILITIES
    # — recovering the legacy F_XHTTP_ENABLE flag losslessly, never
    # re-deciding topology or capability admissibility (already decided,
    # by core_resolve_deployment(), before this function was ever called).
    local _xhttp_enable="0" _cap
    for _cap in "${DEPLOYMENT_CAPABILITIES[@]:-}"; do
        [ "$_cap" = "XHTTP" ] && _xhttp_enable="1"
    done

    panel_generate_webserver_config \
        "$_RESOLVER_WEB_SERVER" \
        "$DEPLOYMENT_TOPOLOGY" \
        "$DEPLOYMENT_DOMAIN_PANEL" \
        "$DEPLOYMENT_DOMAIN_SUB" \
        "$DEPLOYMENT_DOMAIN_SELFSTEAL" \
        "$PC" "$SC" "$STC" \
        "$COOKIE_KEY" "$COOKIE_VAL" \
        "$DEPLOYMENT_TELEMT_DOMAIN" \
        "$DEPLOYMENT_TELEMT_PORT" \
        "$_xhttp_enable"
}
