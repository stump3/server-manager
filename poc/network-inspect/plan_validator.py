#!/usr/bin/env python3
"""
poc/network-inspect/plan_validator.py
========================================

EXPERIMENTAL / RESEARCH POC — implements the layer between Planner and
a future renderer/executor:

    Plan IR -> Plan Validator -> validated Plan IR -> renderer/executor

FOUR RESPONSIBILITIES, KEPT SEPARATE (do not blur these):
    Planner   : decides what should happen
    Validator : verifies the resulting Plan IR is internally valid
                and safe to hand off (THIS MODULE)
    Renderer  : translates a validated plan into provider syntax
    Executor  : applies it

This module answers exactly one question: "is this Plan IR document,
taken as data, internally self-consistent and safe to pass on" — never
"is this the right topology" (Planner's job, not re-litigated here)
and never "does this actually work on a real host" (Renderer/Executor
territory — this module makes no subprocess call, no file read, no
network probe, ever).

ARCHITECTURAL BOUNDARY (enforced, verified by
test_plan_validator.py::TestPlanValidatorArchitecture, not just
documented)
------------------------------------------------------------------
This module imports ONLY `plan_ir` (for its frozen enums/constants —
`TOPOLOGIES`, `PLACEMENTS`, `ACTIONS`, `CHANGE_SCOPES`,
`SCHEMA_VERSION`, and `group_id()` for a re-derivation check) plus the
standard library. It does NOT import `planner`, `inventory_build`,
`capabilities`, or `desired_state` — this module never re-runs
candidate generation, never re-consults the Capability Registry, never
re-reads Inventory, and never re-validates Desired State. It receives
only the `plan_ir` document itself (the dict `plan_ir.assemble()`
produces / `planner.plan()`'s `["plan_ir"]` value) and validates that
artifact on its own terms.

WHY SEVERAL P0 SAFETY INVARIANTS ARE NOT "ACTIVELY RE-VERIFIED" HERE
------------------------------------------------------------------------
Read this section before assuming a gap is a bug. Plan IR's frozen
schema (`plan_ir.py`, not modified by this module) does not carry
forward every fact that went into Planner's decision — by design,
Plan IR is meant to be the OUTPUT of already-resolved reasoning, not a
full audit trail of every intermediate fact. Concretely, Plan IR never
states a Capability Registry dimension's raw STATUS (available /
unsupported / absent / unresolved) — only, on a winning candidate,
which dimension NAMES were required (`required_capabilities`, always
already-satisfied by construction, since `planner.py`'s
`_eligible_mechanisms()` only ever assigns a mechanism to a group when
every one of its needed dimensions was confirmed `available`). Nor
does Plan IR carry Hysteria2's obfuscation state, or a structured
`migration_tolerant`/`quic_migration_safe` comparison — only a
free-text warning string when Planner's own `_build_plan_ir()` chose
to emit one.

This means three classes of P0 invariant from the Planner round fall
into a THIRD category, distinct from "actively validated" and "not
covered":

  GUARANTEED BY UPSTREAM CONSTRUCTION, NOT INDEPENDENTLY RE-CHECKABLE
  FROM THIS SCHEMA:
    - unresolved capability != unsupported (Planner's own
      `_mechanism_satisfies()`/`_eligible_mechanisms()` never lets an
      `unresolved` or `unsupported` dimension become a winning
      candidate's `required_capabilities` entry in the first place —
      by the time Plan IR exists, this distinction has already been
      correctly enforced. There is no representable "this dimension
      was actually unresolved" state left in the artifact to check.)
    - Hysteria2 obfuscation != provider capability (Plan IR carries no
      obfuscation field at all — the gate already fired, or didn't,
      before this candidate was ever generated.)
    - `migration_tolerant` (operator acceptance) is structurally
      incapable of being confused with `quic_migration_safe` (provider
      capability) in this module's code, for the simple reason that
      neither name, nor any capability-status value, appears anywhere
      in Plan IR's schema for this module to read or conflate.

This module does NOT paper over this by inventing a check that looks
thorough but can't actually catch anything real (which the previous
Discovery/Capability Registry rounds established a repeated,
project-wide standard against). It states the boundary plainly instead
— see LIMITATIONS in the accompanying report, and the
`RECOMMENDED_FUTURE_SCHEMA_ADDITIONS` note below, which names exactly
what a future `plan-ir-2` would need to make these independently
re-checkable, without adding that schema itself here.

RECOMMENDED_FUTURE_SCHEMA_ADDITIONS (not implemented — naming a gap is
not license to fix it unilaterally in a frozen artifact):
  - A structured `migration_risk: {"acknowledged": bool, "reason": str}`
    field per SHARED_UDP_QUIC_SNI group, replacing today's free-text
    warning string, OR a `safety_decisions` entry with a reserved
    `rule_id` for this specific fact (the mechanism already exists in
    the schema for `single_ingress_path` — extending its use is a
    smaller change than adding a wholly new field).
  - A `capability_evidence: {dimension: confidence}` map per group, if
    a future Validator round is ever asked to re-verify confidence
    tiers rather than trusting Planner's own scoring.

WHAT THIS MODULE ACTIVELY VALIDATES (see accompanying report's
"VALIDATION RULES" section for the authoritative list; summarized
here):
  A. Schema/enum validity of every object in the document.
  B. Resource identity: uniqueness of service_id (within a group AND
     across the whole plan — a service must never receive two
     different operations), uniqueness of group_id, and a
     re-derivation check that each group's own claimed group_id
     actually matches `plan_ir.group_id()` computed from its listed
     services (catches a corrupted/hand-edited artifact).
  C. Endpoint (transport, ip, port) consistency: services in a
     SHARED_* group MUST share one identical endpoint; services in a
     non-shared group (or across DIFFERENT groups entirely) MUST NOT
     collide on one — this is the check that catches a REAL, disclosed
     defect in the current `planner.py` (see report).
  D. Reconciliation action/change_scope consistency (keep/reuse ->
     change_scope none; create -> none; change -> parameter or
     topology, never none).
  E. Routing/mechanism consistency: `routing` (SNI or QUIC-SNI match)
     is only valid when the group actually has a `mechanism` and the
     matching `SHARED_*` topology — a routing entry under a DIRECT_*/
     SEPARATE_* topology, or with no mechanism at all, is invalid (no
     router exists there to perform the routing).
  F. SHARED_UDP_QUIC_SNI-specific dimension-name checks: must require
     `udp.multi_backend_same_port` and `udp.quic_sni_routing`
     specifically — never substitutable by `udp.reuseport` or
     `udp.quic_sni_termination` alone (SO_REUSEPORT-is-not-multiplexing
     and termination-is-not-passthrough, enforced at the level of
     which dimension NAMES the plan itself declares as required).
  G. Removal safety: every `removals[]` entry must have
     `requires_explicit_confirmation` literally `True`.
  H. Dependency graph shape (best-effort — see LIMITATIONS; the
     current `planner.py` never populates `dependencies`, so this
     exercises only an always-empty list today, kept for forward
     compatibility against the shape the design gate documented).

DETERMINISM
-------------
Given the same Plan IR document, `validate_plan()` always returns the
same diagnostics in the same order. Diagnostics are produced by
iterating the document's own lists in their given (already
deterministic, per Planner's own guarantees) order — this module never
introduces its own dict/set iteration-order dependency: anywhere a
`set()` is built internally for a uniqueness check, it is converted to
a `sorted()` list before any diagnostic is emitted from it.
`validate_plan()` never mutates its input.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field as dc_field
from typing import Any, Optional

import plan_ir

SUPPORTED_SCHEMA = plan_ir.SCHEMA_VERSION

_IPV4_RE = re.compile(r"^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$")
_VALID_TRANSPORTS = ("tcp", "udp")
_VALID_PROXY_PROTOCOL = ("required", "optional", "not_supported")
_SHARED_TOPOLOGIES = ("SHARED_TCP_SNI", "SHARED_UDP_QUIC_SNI")
_NON_SHARED_TOPOLOGIES = ("DIRECT_TCP", "DIRECT_UDP", "SEPARATE_PORTS", "SEPARATE_IPS")


def _is_valid_ipv4(s: Any) -> bool:
    if not isinstance(s, str):
        return False
    m = _IPV4_RE.match(s)
    if not m:
        return False
    return all(0 <= int(octet) <= 255 for octet in m.groups())


@dataclass
class Diagnostic:
    code: str
    severity: str  # "error" | "warning"
    resource_id: Optional[str]
    field: Optional[str]
    message: str

    def as_dict(self) -> dict:
        return {
            "code": self.code, "severity": self.severity,
            "resource_id": self.resource_id, "field": self.field,
            "message": self.message,
        }


@dataclass
class PlanValidationResult:
    valid: bool
    schema_version: str
    diagnostics: list = dc_field(default_factory=list)

    def as_dict(self) -> dict:
        return {
            "valid": self.valid,
            "schema_version": self.schema_version,
            "diagnostics": [d.as_dict() for d in self.diagnostics],
        }

    def errors(self) -> list:
        return [d for d in self.diagnostics if d.severity == "error"]

    def warnings(self) -> list:
        return [d for d in self.diagnostics if d.severity == "warning"]


def _err(diags: list, code: str, resource_id, field_, message: str) -> None:
    diags.append(Diagnostic(code, "error", resource_id, field_, message))


def _warn(diags: list, code: str, resource_id, field_, message: str) -> None:
    diags.append(Diagnostic(code, "warning", resource_id, field_, message))


def _is_mapping(x: Any) -> bool:
    return isinstance(x, dict)


# ─────────────────────────────────────────────────────────────────────
# A. Structural / schema / enum validity
# ─────────────────────────────────────────────────────────────────────

def _validate_structure(plan: Any) -> list:
    diags: list = []

    if not _is_mapping(plan):
        _err(diags, "not_a_mapping", None, "$", "top-level Plan IR document must be a mapping/object")
        return diags

    schema_version = plan.get("schema_version")
    if schema_version is None:
        _err(diags, "missing_schema_version", None, "$.schema_version", "schema_version is required")
    elif schema_version != SUPPORTED_SCHEMA:
        _err(diags, "unsupported_schema_version", None, "$.schema_version",
             f"expected {SUPPORTED_SCHEMA!r}, got {schema_version!r}")

    groups = plan.get("groups")
    if not isinstance(groups, list):
        _err(diags, "groups_not_a_list", None, "$.groups", "groups must be a list")
        groups = []

    removals = plan.get("removals")
    if not isinstance(removals, list):
        _err(diags, "removals_not_a_list", None, "$.removals", "removals must be a list")
        removals = []

    dependencies = plan.get("dependencies")
    if not isinstance(dependencies, list):
        _err(diags, "dependencies_not_a_list", None, "$.dependencies", "dependencies must be a list")

    warnings = plan.get("warnings")
    if not isinstance(warnings, list) or not all(isinstance(w, str) for w in warnings):
        _err(diags, "warnings_not_a_string_list", None, "$.warnings", "warnings must be a list of strings")

    for gi, group in enumerate(groups):
        gpath = f"$.groups[{gi}]"
        if not _is_mapping(group):
            _err(diags, "group_not_a_mapping", None, gpath, "each group must be a mapping/object")
            continue
        gid = group.get("group_id")
        if not isinstance(gid, str) or not gid:
            _err(diags, "invalid_group_id", gid, f"{gpath}.group_id", "group_id must be a non-empty string")
        topology = group.get("topology")
        if topology not in plan_ir.TOPOLOGIES:
            _err(diags, "invalid_topology", gid, f"{gpath}.topology", f"{topology!r} is not one of {plan_ir.TOPOLOGIES!r}")
        mechanism = group.get("mechanism")
        if mechanism is not None and (not isinstance(mechanism, str) or not mechanism):
            _err(diags, "invalid_mechanism", gid, f"{gpath}.mechanism", "mechanism must be null or a non-empty string")
        services = group.get("services")
        if not isinstance(services, list) or not services:
            _err(diags, "invalid_services_list", gid, f"{gpath}.services", "services must be a non-empty list")
            services = []
        safety_decisions = group.get("safety_decisions")
        if not isinstance(safety_decisions, list):
            _err(diags, "invalid_safety_decisions", gid, f"{gpath}.safety_decisions", "safety_decisions must be a list")
            safety_decisions = []

        for si, svc in enumerate(services):
            spath = f"{gpath}.services[{si}]"
            if not _is_mapping(svc):
                _err(diags, "service_not_a_mapping", gid, spath, "each service entry must be a mapping/object")
                continue
            sid = svc.get("service_id")
            if not isinstance(sid, str) or not sid:
                _err(diags, "invalid_service_id", gid, f"{spath}.service_id", "service_id must be a non-empty string")
            if svc.get("placement") not in plan_ir.PLACEMENTS:
                _err(diags, "invalid_placement", sid, f"{spath}.placement", f"{svc.get('placement')!r} is not one of {plan_ir.PLACEMENTS!r}")
            if svc.get("action") not in plan_ir.ACTIONS:
                _err(diags, "invalid_action", sid, f"{spath}.action", f"{svc.get('action')!r} is not one of {plan_ir.ACTIONS!r}")
            if svc.get("change_scope") not in plan_ir.CHANGE_SCOPES:
                _err(diags, "invalid_change_scope", sid, f"{spath}.change_scope", f"{svc.get('change_scope')!r} is not one of {plan_ir.CHANGE_SCOPES!r}")

            listener = svc.get("listener")
            if not _is_mapping(listener):
                _err(diags, "invalid_listener", sid, f"{spath}.listener", "listener must be a mapping")
            else:
                if listener.get("transport") not in _VALID_TRANSPORTS:
                    _err(diags, "invalid_listener_transport", sid, f"{spath}.listener.transport",
                         f"{listener.get('transport')!r} is not one of {_VALID_TRANSPORTS!r}")
                if not _is_valid_ipv4(listener.get("ip")):
                    _err(diags, "invalid_listener_ip", sid, f"{spath}.listener.ip",
                         f"{listener.get('ip')!r} is not a syntactically valid IPv4 address")
                port = listener.get("port")
                if not isinstance(port, int) or isinstance(port, bool) or not (1 <= port <= 65535):
                    _err(diags, "invalid_listener_port", sid, f"{spath}.listener.port",
                         f"{port!r} is not a valid port number (1-65535)")

            routing = svc.get("routing")
            if routing is not None:
                if not _is_mapping(routing) or not _is_mapping(routing.get("match")):
                    _err(diags, "invalid_routing", sid, f"{spath}.routing", "routing must be null or {'match': {...}}")
                else:
                    match = routing["match"]
                    match_keys = set(match.keys())
                    if match_keys not in ({"sni"}, {"quic_sni"}):
                        _err(diags, "invalid_routing_match_kind", sid, f"{spath}.routing.match",
                             f"match must have exactly one key, 'sni' or 'quic_sni' (got {sorted(match_keys)!r})")
                    else:
                        values = list(match.values())[0]
                        if not isinstance(values, list) or not all(isinstance(v, str) for v in values):
                            _err(diags, "invalid_routing_match_values", sid, f"{spath}.routing.match",
                                 "match values must be a list of strings")

            required_capabilities = svc.get("required_capabilities")
            if not isinstance(required_capabilities, list) or not all(isinstance(c, str) for c in required_capabilities):
                _err(diags, "invalid_required_capabilities", sid, f"{spath}.required_capabilities",
                     "required_capabilities must be a list of strings")

            if svc.get("proxy_protocol") not in _VALID_PROXY_PROTOCOL:
                _err(diags, "invalid_proxy_protocol", sid, f"{spath}.proxy_protocol",
                     f"{svc.get('proxy_protocol')!r} is not one of {_VALID_PROXY_PROTOCOL!r}")

        for di, sd in enumerate(safety_decisions):
            dpath = f"{gpath}.safety_decisions[{di}]"
            if not _is_mapping(sd):
                _err(diags, "safety_decision_not_a_mapping", gid, dpath, "each safety_decisions entry must be a mapping")
                continue
            if not isinstance(sd.get("rule_id"), str) or not sd["rule_id"]:
                _err(diags, "invalid_safety_decision_rule_id", gid, f"{dpath}.rule_id", "rule_id must be a non-empty string")
            if sd.get("outcome") not in ("passed", "warning"):
                _err(diags, "invalid_safety_decision_outcome", gid, f"{dpath}.outcome",
                     f"{sd.get('outcome')!r} is not one of ('passed', 'warning')")
            if not isinstance(sd.get("detail"), str) or not sd["detail"]:
                _err(diags, "invalid_safety_decision_detail", gid, f"{dpath}.detail", "detail must be a non-empty string")

    for ri, removal in enumerate(removals):
        rpath = f"$.removals[{ri}]"
        if not _is_mapping(removal):
            _err(diags, "removal_not_a_mapping", None, rpath, "each removal must be a mapping")
            continue
        resource = removal.get("resource")
        if not isinstance(resource, str) or not resource:
            _err(diags, "invalid_removal_resource", resource, f"{rpath}.resource", "resource must be a non-empty string")

    return diags


# ─────────────────────────────────────────────────────────────────────
# B. Resource identity
# ─────────────────────────────────────────────────────────────────────

def _validate_identity(plan: dict) -> list:
    diags: list = []
    groups = plan.get("groups", [])

    seen_group_ids: dict = {}
    seen_service_ids: dict = {}

    for group in groups:
        gid = group["group_id"]
        if gid in seen_group_ids:
            _err(diags, "duplicate_group_id", gid, "$.groups[].group_id",
                 f"group_id {gid!r} appears more than once")
        seen_group_ids[gid] = seen_group_ids.get(gid, 0) + 1

        expected_gid = plan_ir.group_id([s["service_id"] for s in group["services"]])
        if gid != expected_gid:
            _err(diags, "group_id_mismatch", gid, "$.groups[].group_id",
                 f"group_id {gid!r} does not match plan_ir.group_id() computed from its own "
                 f"services ({expected_gid!r}) — this artifact may be corrupted or hand-edited")

        seen_in_this_group = set()
        for svc in group["services"]:
            sid = svc["service_id"]
            if sid in seen_in_this_group:
                _err(diags, "duplicate_service_id_in_group", sid, "$.groups[].services[].service_id",
                     f"service_id {sid!r} appears more than once within group {gid!r}")
            seen_in_this_group.add(sid)

            if sid in seen_service_ids and seen_service_ids[sid] != gid:
                _err(diags, "service_id_in_multiple_groups", sid, "$.groups[].services[].service_id",
                     f"service_id {sid!r} appears in both group {seen_service_ids[sid]!r} and "
                     f"group {gid!r} — one logical service must never receive two independent "
                     f"operations from the same plan")
            seen_service_ids[sid] = gid

    # Removal identity must not silently coincide with an active
    # group's own identity — best-effort only, since Plan IR does not
    # standardize a resource-string format for removals (see module
    # docstring's disclosed limitation).
    active_group_ids = set(seen_group_ids.keys())
    for removal in plan.get("removals", []):
        resource = removal.get("resource")
        if resource in active_group_ids:
            _err(diags, "removal_conflicts_with_active_group", resource, "$.removals[].resource",
                 f"removal targets {resource!r}, which is also an active group_id in this same "
                 f"plan — a resource cannot be both removed and kept/reused/changed/created "
                 f"in the same plan")

    return diags


# ─────────────────────────────────────────────────────────────────────
# C. Endpoint (transport, ip, port) consistency
# ─────────────────────────────────────────────────────────────────────

def _validate_placement(plan: dict) -> list:
    diags: list = []
    endpoint_to_groups: dict = {}  # (transport, ip, port) -> sorted list of group_ids

    for group in plan.get("groups", []):
        gid = group["group_id"]
        topology = group["topology"]
        endpoints_in_group: dict = {}
        for svc in group["services"]:
            listener = svc.get("listener") or {}
            key = (listener.get("transport"), listener.get("ip"), listener.get("port"))
            if any(v is None for v in key):
                continue  # already flagged as structurally invalid; don't cascade here
            endpoints_in_group.setdefault(key, []).append(svc["service_id"])
            endpoint_to_groups.setdefault(key, set()).add(gid)

        distinct_endpoints = len(endpoints_in_group)
        if topology in _SHARED_TOPOLOGIES:
            if distinct_endpoints > 1:
                _err(diags, "shared_group_endpoint_mismatch", gid, "$.groups[].services[].listener",
                     f"group {gid!r} is topology {topology!r} (services should share one "
                     f"endpoint) but its services resolve to {distinct_endpoints} distinct "
                     f"(transport, ip, port) endpoints: {sorted(endpoints_in_group.keys())!r}")
        elif topology in _NON_SHARED_TOPOLOGIES:
            for key, sids in endpoints_in_group.items():
                if len(sids) > 1:
                    _err(diags, "non_shared_group_endpoint_collision", gid, "$.groups[].services[].listener",
                         f"group {gid!r} is topology {topology!r} (services should NOT share an "
                         f"endpoint) but services {sorted(sids)!r} all resolve to the identical "
                         f"endpoint {key!r}")

    for key, gids in endpoint_to_groups.items():
        if len(gids) > 1:
            _err(diags, "cross_group_endpoint_collision", None, "$.groups[].services[].listener",
                 f"endpoint {key!r} is claimed by more than one group: {sorted(gids)!r} — two "
                 f"independently-planned groups cannot occupy the identical listener without "
                 f"being modeled as a single shared group")

    return diags


# ─────────────────────────────────────────────────────────────────────
# D. Reconciliation action / change_scope consistency
# ─────────────────────────────────────────────────────────────────────

_EXPECTED_CHANGE_SCOPE = {
    "keep": {"none"},
    "reuse": {"none"},
    "create": {"none"},
    "change": {"parameter", "topology"},
}


def _validate_reconciliation(plan: dict) -> list:
    diags: list = []
    for group in plan.get("groups", []):
        for svc in group["services"]:
            action = svc.get("action")
            change_scope = svc.get("change_scope")
            expected = _EXPECTED_CHANGE_SCOPE.get(action)
            if expected is not None and change_scope not in expected:
                _err(diags, "action_change_scope_mismatch", svc.get("service_id"),
                     "$.groups[].services[].change_scope",
                     f"action {action!r} must have change_scope in {sorted(expected)!r}, "
                     f"got {change_scope!r}")
    return diags


# ─────────────────────────────────────────────────────────────────────
# E. Routing / mechanism consistency, F. UDP/QUIC dimension-name checks
# ─────────────────────────────────────────────────────────────────────

_TOPOLOGY_FOR_MATCH_KIND = {"sni": "SHARED_TCP_SNI", "quic_sni": "SHARED_UDP_QUIC_SNI"}


def _validate_routing_safety(plan: dict) -> list:
    diags: list = []
    for group in plan.get("groups", []):
        gid = group["group_id"]
        topology = group["topology"]
        mechanism = group.get("mechanism")

        for svc in group["services"]:
            sid = svc["service_id"]
            routing = svc.get("routing")
            if routing is None:
                continue
            match = (routing or {}).get("match") or {}
            match_kind = next(iter(match.keys()), None)
            if mechanism is None:
                _err(diags, "routing_without_mechanism", sid, "$.groups[].services[].routing",
                     f"service {sid!r} has a routing entry (match kind {match_kind!r}) but its "
                     f"group {gid!r} has no mechanism — routing requires an L4 router to perform "
                     f"it, which a mechanism-less (DIRECT_*/SEPARATE_*) group does not have")
                continue
            expected_topology = _TOPOLOGY_FOR_MATCH_KIND.get(match_kind)
            if expected_topology is not None and topology != expected_topology:
                _err(diags, "routing_topology_mismatch", sid, "$.groups[].services[].routing",
                     f"service {sid!r} has a {match_kind!r} routing entry, which requires "
                     f"topology {expected_topology!r}, but its group {gid!r} is {topology!r}")

        # F. SHARED_UDP_QUIC_SNI-specific dimension-name checks.
        if topology == "SHARED_UDP_QUIC_SNI":
            all_required = set()
            for svc in group["services"]:
                all_required.update(svc.get("required_capabilities") or [])
            if "udp.multi_backend_same_port" not in all_required:
                _err(diags, "quic_shared_missing_multi_backend_dimension", gid,
                     "$.groups[].services[].required_capabilities",
                     f"group {gid!r} is SHARED_UDP_QUIC_SNI but no service's "
                     f"required_capabilities includes 'udp.multi_backend_same_port' — "
                     f"SO_REUSEPORT-class dimensions (e.g. 'udp.reuseport') are never a "
                     f"substitute for this")
            if "udp.quic_sni_routing" not in all_required:
                _err(diags, "quic_shared_missing_passthrough_dimension", gid,
                     "$.groups[].services[].required_capabilities",
                     f"group {gid!r} is SHARED_UDP_QUIC_SNI but no service's "
                     f"required_capabilities includes 'udp.quic_sni_routing' (passthrough) — "
                     f"'udp.quic_sni_termination' is a different capability and is never a "
                     f"substitute for passthrough routing")
            if "udp.reuseport" in all_required and "udp.multi_backend_same_port" not in all_required:
                _err(diags, "reuseport_treated_as_multiplexing", gid,
                     "$.groups[].services[].required_capabilities",
                     f"group {gid!r} lists 'udp.reuseport' among its required capabilities "
                     f"without also requiring 'udp.multi_backend_same_port' — SO_REUSEPORT is a "
                     f"kernel scale-out primitive, never evidence of protocol-aware multiplexing")

        # Migration-risk acknowledgment — best-effort, see module
        # docstring's disclosed limitation: today this is only ever
        # expressed as a free-text warning string, never a structured
        # field, because planner.py doesn't emit a structured one.
        if topology == "SHARED_UDP_QUIC_SNI":
            needs_passthrough = any(
                "udp.quic_sni_routing" in (svc.get("required_capabilities") or [])
                for svc in group["services"]
            )
            if needs_passthrough:
                structured_ack = any(
                    sd.get("rule_id") == "migration_unsafe_requires_explicit_optin"
                    for sd in group.get("safety_decisions", [])
                )
                freeform_ack = any("migration" in w.lower() for w in plan.get("warnings", []))
                if not (structured_ack or freeform_ack):
                    _warn(diags, "migration_risk_not_acknowledged_in_plan", gid,
                          "$.warnings / $.groups[].safety_decisions",
                          f"group {gid!r} requires udp.quic_sni_routing (shared QUIC passthrough) "
                          f"but neither a structured safety_decisions entry nor a free-text "
                          f"warning about migration risk is present anywhere in this plan — "
                          f"see module docstring's RECOMMENDED_FUTURE_SCHEMA_ADDITIONS for why "
                          f"this can only be a 'warning', not an 'error', given the current "
                          f"Plan IR schema's lack of a structured field for this fact")

    return diags


# ─────────────────────────────────────────────────────────────────────
# G. Removal safety
# ─────────────────────────────────────────────────────────────────────

def _validate_removals(plan: dict) -> list:
    diags: list = []
    for removal in plan.get("removals", []):
        if removal.get("requires_explicit_confirmation") is not True:
            _err(diags, "removal_missing_explicit_confirmation", removal.get("resource"),
                 "$.removals[].requires_explicit_confirmation",
                 f"removal of {removal.get('resource')!r} does not have "
                 f"requires_explicit_confirmation == True — a destructive operation must never "
                 f"be silently authorized")
    return diags


# ─────────────────────────────────────────────────────────────────────
# H. Dependency graph shape (best-effort — see module docstring;
# planner.py never populates this today, so this exercises only an
# always-empty list in the current codebase, kept for forward
# compatibility against the shape the design gate documented:
# {"before": <id>, "after": <id>}).
# ─────────────────────────────────────────────────────────────────────

def _validate_dependencies(plan: dict) -> list:
    diags: list = []
    dependencies = plan.get("dependencies", [])
    if not isinstance(dependencies, list) or not dependencies:
        return diags  # nothing to check — see module docstring

    known_ids = {g["group_id"] for g in plan.get("groups", [])}
    edges = []
    for i, dep in enumerate(dependencies):
        dpath = f"$.dependencies[{i}]"
        if not _is_mapping(dep) or "before" not in dep or "after" not in dep:
            _err(diags, "invalid_dependency_shape", None, dpath,
                 "each dependency must be a mapping with 'before' and 'after' keys")
            continue
        before, after = dep["before"], dep["after"]
        if before not in known_ids:
            _err(diags, "dangling_dependency_reference", before, f"{dpath}.before",
                 f"dependency references unknown resource {before!r}")
        if after not in known_ids:
            _err(diags, "dangling_dependency_reference", after, f"{dpath}.after",
                 f"dependency references unknown resource {after!r}")
        if before in known_ids and after in known_ids:
            edges.append((before, after))

    # Cycle detection — simple DFS, deterministic (sorted adjacency).
    adjacency: dict = {}
    for before, after in edges:
        adjacency.setdefault(before, []).append(after)
    for node in adjacency:
        adjacency[node].sort()

    WHITE, GRAY, BLACK = 0, 1, 2
    color = {n: WHITE for n in known_ids}
    cycle_found = [False]

    def dfs(node):
        color[node] = GRAY
        for neighbor in adjacency.get(node, []):
            if color.get(neighbor) == GRAY:
                cycle_found[0] = True
                return
            if color.get(neighbor) == WHITE:
                dfs(neighbor)
        color[node] = BLACK

    for node in sorted(known_ids):
        if color[node] == WHITE:
            dfs(node)
        if cycle_found[0]:
            break

    if cycle_found[0]:
        _err(diags, "dependency_cycle", None, "$.dependencies",
             "the dependency graph contains a cycle — operation order cannot be determined")

    return diags


# ─────────────────────────────────────────────────────────────────────
# Public entry point
# ─────────────────────────────────────────────────────────────────────

def validate_plan(plan: Any) -> PlanValidationResult:
    """Pure function: Plan IR dict in, PlanValidationResult out. Never
    mutates `plan`. Structural errors are checked first; if any are
    found, deeper semantic checks are skipped entirely (they would
    only cascade confusing secondary diagnostics off an already-broken
    shape) and only the structural diagnostics are returned — mirroring
    `desired_state.py`'s own established error-model convention."""
    structural = _validate_structure(plan)
    if any(d.severity == "error" for d in structural):
        return PlanValidationResult(valid=False, schema_version=SUPPORTED_SCHEMA, diagnostics=structural)

    diagnostics = list(structural)
    diagnostics += _validate_identity(plan)
    diagnostics += _validate_placement(plan)
    diagnostics += _validate_reconciliation(plan)
    diagnostics += _validate_routing_safety(plan)
    diagnostics += _validate_removals(plan)
    diagnostics += _validate_dependencies(plan)

    valid = not any(d.severity == "error" for d in diagnostics)
    return PlanValidationResult(valid=valid, schema_version=SUPPORTED_SCHEMA, diagnostics=diagnostics)
