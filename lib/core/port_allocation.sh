# lib/core/port_allocation.sh
#
# The single, canonical PortAllocation lookup for variant-f-j.
#
# Contract: docs/edge_contracts.md's "Port allocation model (conceptual
# shape only — values unchanged)" section, verbatim — this file is a
# code-side lookup over exactly the facts already stated there, not a
# second or reinterpreted table. If this file and docs/edge_contracts.md
# ever disagree, re-verify against lib/panel/nginx/variant_f.sh and
# variant_j.sh (the actual generators) before trusting either — both were
# re-diffed line-by-line against this file's table at the time it was
# written (2026-09-07) and matched exactly.
#
# WHY THIS FILE DOES NOT READ $F_*/$J_* DIRECTLY (read this before
# "simplifying" it to an indirect variable lookup): lib/core/*.sh must
# not depend on lib/panel/*.sh — every existing Core file (topology.sh,
# deployment.sh, runtime_component.sh) is a leaf Panel calls into, never
# the reverse. lib/panel/nginx/variant_f.sh's/variant_j.sh's own
# F_NGINX_HTTPS_PORT=7443 etc. assignments are top-level (module-scope,
# not `local`), set the moment those files are sourced — reading them
# from here via `${!varname}` would (a) invert that dependency direction
# (Core reaching into Panel) and (b) make this file's answers depend on
# whether lib/panel.sh's loader has already sourced nginx/variant_f.sh /
# variant_j.sh by the time a caller asks — exactly the load-order
# coupling this file exists to avoid. So this table's values are its own
# static data, verified equal to variant_f.sh's/variant_j.sh's literals
# by lib/sripts/tests/test_port_allocation.sh, not derived from them at
# runtime. lib/panel/nginx/variant_f.sh and variant_j.sh remain the only
# place those numbers actually get interpolated into a generated
# nginx.conf — this file is a separate, parallel description for code
# that needs to REASON about the port scheme (e.g. a future lib/panel/
# api.sh migration away from its own duplicated ${F_XRAY_XHTTP_PORT:-19444}
# fallback — see "19444" note below), not a replacement for that
# interpolation.
#
# SCOPE (2026-09-07, first implementation; wired the same day —
# Candidates 1-3): read-only/descriptive at its own layer, zero runtime
# side effects (no top-level side-effecting statement below, only
# function definitions). Being wired into production consumers below
# does not change what this file *is*: it remains an
# independently-verified static mirror, not the canonical source — the
# canonical topology port values still live in
# lib/panel/nginx/variant_f.sh and variant_j.sh (see "WHY THIS FILE
# DOES NOT READ $F_*/$J_* DIRECTLY" above; that constraint is unchanged
# by any of the wiring below — this file still never reads $F_*/$J_*
# at runtime).
#
# NOW WIRED (previously was not): lib/panel/api.sh's
# panel_reality_xhttp_inbound_port() (Candidate 1) reads the XHTTP
# internal port via core_port_allocation_internal("F"/"J", "xhttp")
# instead of independently re-typing the literal fallback it used to
# carry. The same file's Host-registration block (Candidate 3) reads
# the XHTTP public port via core_port_allocation_public("$MODE",
# "xhttp"), inside its own XHTTP_ENABLE gate. lib/panel/install.sh's
# XHTTP UFW rule (Candidate 2) reads the public port the same way,
# inside its own XHTTP-capability gate. This file is registered in
# server-manager.sh's module loader as core/port_allocation, loaded
# before panel; lib/sripts/tests/test_port_allocation.sh also still
# sources it directly by path, the same way every other Core adapter
# test in this repo does.
#
# WEB_SERVER and Plan IR (poc/network-inspect/): both explicitly out of
# scope for this file — see the "Architecture Gap Discovery" report this
# session's own design phase is based on. Neither is referenced below.
#
# TOPOLOGIES 1 AND 2: valid topologies (core_topology_is_valid "1"/"2"
# both return 0), but neither has ANY row in this table — MODE=1 has
# Xray directly on :443 with no internal/public port split at all, and
# MODE=2 has plain nginx http{} directly on :443. Every lookup below for
# topology 1 or 2 fails (exit 1, empty output) the same way an unknown
# role or an entirely invalid topology string does — this file does not
# distinguish "valid topology with no row" from "invalid topology
# string" at the exit-code level, matching every existing core_topology_*
# function's own convention (core_topology_public_ingress_owner("9") and
# core_topology_public_ingress_owner("1")'s hypothetical missing case
# would both just be "unhandled" the same way, if 1 didn't have a case
# arm — this file's "1"/"2" rows are the same kind of intentional
# omission, not an oversight).
#
# TELEMT'S internal_port: NOT a fixed topology fact, unlike every other
# cell in this table. docs/edge_contracts.md's own table already writes
# it as the literal placeholder `$TELEMT_PORT`, not a number — it is
# whatever the operator configured at CLI time, already resolved as
# DEPLOYMENT_TELEMT_PORT by lib/core/deployment.sh's
# core_resolve_deployment(). Inventing a fixed number for it here would
# misrepresent it as topology-fixed data when it is actually
# per-Deployment data — core_port_allocation_internal() below fails
# (exit 1) for role=telemt specifically, on purpose, rather than ever
# returning the internal sentinel string used for it in this file's own
# row table. telemt's other four fields (public_port=443 — same shared
# :443 SNI-multiplexed entry point as vision/panel_sub, protocol,
# proxy_protocol, owner) ARE fixed topology facts and are looked up
# normally.
#
# "19444" regression note (historical — RESOLVED by Candidate 1,
# 2026-09-07): lib/panel/api.sh used to independently redeclare F's
# XHTTP internal port as a fallback default
# (`${F_XRAY_XHTTP_PORT:-19444}`) — named as a duplicated literal in
# docs/CORE_RUNTIME_CONTRACTS.md §13 and docs/edge_contracts.md's Port
# allocation section. That duplication is gone: api.sh:131-132 now
# calls this file's core_port_allocation_internal("F"/"J", "xhttp")
# instead of re-typing the literal. This file's own F/xhttp
# internal_port row is unaffected by that fix and remains independently
# written as its own literal "19444" (not copied via any shared
# constant, on purpose — see the no-cross-file-dependency note above,
# and note this is this file's own static table data, not a runtime
# read of $F_XRAY_XHTTP_PORT), so
# lib/sripts/tests/test_port_allocation.sh's truth table still
# specifically pins this value as a regression check on this
# independently-maintained table, separately from api.sh's own
# migration.

# core_port_allocation_role_is_valid <role> — 0 if role is one of the
# four roles this table knows about, 1 otherwise. Mirrors
# core_topology_is_valid()'s shape in topology.sh.
core_port_allocation_role_is_valid() {
    case "${1:-}" in
        vision|xhttp|panel_sub|telemt) return 0 ;;
        *) return 1 ;;
    esac
}

# _core_port_allocation_row <topology> <role> — INTERNAL. The one place
# this file's data lives; every public core_port_allocation_* function
# below is a thin field-extraction wrapper around this row, so there is
# exactly one table to keep in sync with docs/edge_contracts.md, not five
# separately-maintained case statements. Echoes
# "public_port|internal_port|protocol|proxy_protocol|owner"
# pipe-delimited (no field's value contains "|"). Exit 1 + no output for
# any topology/role pair with no row (invalid topology, valid-but-rowless
# topology 1/2, invalid role, or role="telemt" is fine here — its row
# exists; only its internal_port FIELD is the sentinel "DYNAMIC", handled
# by core_port_allocation_internal() below, not by failing this lookup
# entirely).
_core_port_allocation_row() {
    local _topology="${1:-}" _role="${2:-}"
    case "${_topology}:${_role}" in
        "F:vision")    echo "443|8443|reality/tcp|yes|Xray" ;;
        "F:panel_sub") echo "443|7443|http/tls|yes (in)|nginx" ;;
        "F:xhttp")     echo "9443|19444|reality/xhttp|no|Xray" ;;
        "F:telemt")    echo "443|DYNAMIC|mtproto/tls|yes|TeleMT" ;;
        "J:vision")    echo "443|18443|reality/tcp|yes|Xray" ;;
        "J:panel_sub") echo "443|7444|http/tls|yes (in)|nginx" ;;
        "J:xhttp")     echo "8443|18444|reality/xhttp|no|Xray" ;;
        "J:telemt")    echo "443|DYNAMIC|mtproto/tls|yes|TeleMT" ;;
        *) return 1 ;;
    esac
}

# core_port_allocation_public <topology> <role> — echoes the public
# (internet-facing) port for this topology/role. Always succeeds for any
# of the 8 valid F/J × {vision,xhttp,panel_sub,telemt} pairs, including
# telemt (its public_port IS a fixed fact — the shared :443 SNI entry —
# unlike its internal_port).
core_port_allocation_public() {
    local _row
    _row="$(_core_port_allocation_row "${1:-}" "${2:-}")" || return 1
    echo "${_row}" | cut -d'|' -f1
}

# core_port_allocation_internal <topology> <role> — echoes the internal
# (loopback) port. Fails on purpose for role="telemt" (see file header —
# not a fixed topology fact, see DEPLOYMENT_TELEMT_PORT instead) even
# though the row itself exists for public_port/protocol/proxy_protocol/
# owner lookups.
core_port_allocation_internal() {
    local _row _val
    _row="$(_core_port_allocation_row "${1:-}" "${2:-}")" || return 1
    _val="$(echo "${_row}" | cut -d'|' -f2)"
    [ "${_val}" = "DYNAMIC" ] && return 1
    echo "${_val}"
}

# core_port_allocation_protocol <topology> <role> — echoes the wire
# protocol label (e.g. "reality/tcp", "http/tls", "reality/xhttp",
# "mtproto/tls").
core_port_allocation_protocol() {
    local _row
    _row="$(_core_port_allocation_row "${1:-}" "${2:-}")" || return 1
    echo "${_row}" | cut -d'|' -f3
}

# core_port_allocation_proxy_protocol <topology> <role> — echoes one of
# "yes" | "yes (in)" | "no", matching docs/edge_contracts.md's own
# three-value vocabulary verbatim (not collapsed to a boolean — "yes (in)"
# carries real information: PROXY protocol is consumed/terminated at this
# hop, not merely forwarded, per the panel_sub role's own nginx behavior).
core_port_allocation_proxy_protocol() {
    local _row
    _row="$(_core_port_allocation_row "${1:-}" "${2:-}")" || return 1
    echo "${_row}" | cut -d'|' -f4
}

# core_port_allocation_owner <topology> <role> — echoes which process
# terminates/owns this role's traffic ("Xray" | "nginx" | "TeleMT").
core_port_allocation_owner() {
    local _row
    _row="$(_core_port_allocation_row "${1:-}" "${2:-}")" || return 1
    echo "${_row}" | cut -d'|' -f5
}
