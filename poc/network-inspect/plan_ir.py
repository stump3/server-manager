#!/usr/bin/env python3
"""
poc/network-inspect/plan_ir.py
=================================

EXPERIMENTAL / RESEARCH POC — the Plan IR schema (`plan-ir-1`) frozen
by the "Planner + Plan IR Design Gate". This module is pure data
assembly: it builds the IR's shape from values `planner.py` has
already decided. It makes NO decisions of its own — no topology
choice, no scoring, no capability interpretation, no reconciliation
classification. Every function here is a thin, deterministic
constructor.

DETERMINISM
-------------
`group_id()` and `candidate_id()` are derived by sorting and joining
inputs — never a UUID, never a timestamp, never dependent on dict/set
iteration order. The same set of services placed the same way always
produces the same identifiers. A wrapping envelope (e.g. one that adds
`generated_at`) may add a timestamp OUTSIDE the `plan_ir` body — this
module itself never does.

PROVIDER INDEPENDENCE
------------------------
Nothing in this module's vocabulary — `topology`, `mechanism`,
`placement`, `action`, `listener`, `routing` — is provider-specific
syntax. `mechanism` is a plain string identifying a Capability
Registry provider key (`"nginx"`, `"caddy_l4"`, `"haproxy"`) — this
module stores it as an opaque label, never interprets it, never emits
nginx/Caddy/HAProxy configuration syntax of any kind.
"""

from __future__ import annotations

from typing import Optional

SCHEMA_VERSION = "plan-ir-1"

# Ingress-sharing axis — the only valid top-level `topology` values.
TOPOLOGIES = (
    "DIRECT_TCP",
    "DIRECT_UDP",
    "SHARED_TCP_SNI",
    "SHARED_UDP_QUIC_SNI",
    "SEPARATE_PORTS",
    "SEPARATE_IPS",
)

# Placement axis — independent of topology, one per service.
PLACEMENTS = ("colocated", "remote_node")

ACTIONS = ("keep", "reuse", "change", "create")
CHANGE_SCOPES = ("none", "parameter", "topology")


def group_id(service_ids) -> str:
    """Deterministic identity for a placement group — sorted, joined
    service ids, never a UUID."""
    return "+".join(sorted(service_ids))


def candidate_id(topology: str, mechanism: Optional[str], service_ids) -> str:
    """Deterministic identity for a candidate — used both as the
    `rejected_alternatives[].candidate_id` and internally for
    tie-breaking (planner.py sorts on this string as the final,
    always-available tie-break tier)."""
    return f"{topology}:{mechanism or 'none'}:{group_id(service_ids)}"


def build_listener(transport: str, ip: str, port: int) -> dict:
    return {"transport": transport, "ip": ip, "port": port}


def build_routing(match_kind: Optional[str], match_values: Optional[list]) -> Optional[dict]:
    """`match_kind` is "sni" (TCP) or "quic_sni" (UDP/QUIC) or None
    (no routing needed — e.g. a DIRECT_* placement with no fronting
    router at all)."""
    if match_kind is None:
        return None
    return {"match": {match_kind: list(match_values or [])}}


def build_service_entry(
    service_id: str,
    placement: str,
    action: str,
    change_scope: str,
    listener: dict,
    routing: Optional[dict],
    required_capabilities: list,
    proxy_protocol: str,
) -> dict:
    if placement not in PLACEMENTS:
        raise ValueError(f"invalid placement: {placement!r}")
    if action not in ACTIONS:
        raise ValueError(f"invalid action: {action!r}")
    if change_scope not in CHANGE_SCOPES:
        raise ValueError(f"invalid change_scope: {change_scope!r}")
    return {
        "service_id": service_id,
        "placement": placement,
        "action": action,
        "change_scope": change_scope,
        "listener": listener,
        "routing": routing,
        "required_capabilities": sorted(required_capabilities),
        "proxy_protocol": proxy_protocol,
    }


def build_safety_decision(rule_id: str, outcome: str, detail: str) -> dict:
    if outcome not in ("passed", "warning"):
        raise ValueError(f"invalid safety decision outcome: {outcome!r}")
    return {"rule_id": rule_id, "outcome": outcome, "detail": detail}


def build_group(
    topology: str,
    mechanism: Optional[str],
    services: list,
    safety_decisions: Optional[list] = None,
) -> dict:
    if topology not in TOPOLOGIES:
        raise ValueError(f"invalid topology: {topology!r}")
    service_ids = [s["service_id"] for s in services]
    return {
        "group_id": group_id(service_ids),
        "topology": topology,
        "mechanism": mechanism,
        "services": services,
        "safety_decisions": safety_decisions or [],
    }


def build_removal(resource: str) -> dict:
    return {"resource": resource, "requires_explicit_confirmation": True}


def assemble(groups: list, removals: Optional[list] = None, dependencies: Optional[list] = None,
             warnings: Optional[list] = None) -> dict:
    """Top-level Plan IR assembly. `groups` should already be in a
    deterministic order (planner.py sorts by `group_id` before calling
    this) — this function does not re-sort, since re-deriving order
    here would duplicate a decision planner.py already made."""
    return {
        "schema_version": SCHEMA_VERSION,
        "groups": groups,
        "removals": removals or [],
        "dependencies": dependencies or [],
        "warnings": sorted(set(warnings or [])),
    }


def build_rejected_alternative(
    topology: str,
    mechanism: Optional[str],
    service_ids: list,
    rejection_class: str,
    reason: str,
    relevant_fact: dict,
    permanence: str,
) -> dict:
    if rejection_class not in (
        "capability_unsupported", "capability_unresolved", "capability_absent",
        "safety_policy_stop", "safety_policy_exclude",
        "inventory_conflict", "unsatisfiable_placement", "lower_score",
    ):
        raise ValueError(f"invalid rejection_class: {rejection_class!r}")
    if permanence not in ("permanent", "conditional"):
        raise ValueError(f"invalid permanence: {permanence!r}")
    return {
        "candidate_id": candidate_id(topology, mechanism, service_ids),
        "topology": topology,
        "mechanism": mechanism,
        "rejection_class": rejection_class,
        "reason": reason,
        "relevant_fact": relevant_fact,
        "permanence": permanence,
    }
