#!/usr/bin/env python3
"""
poc/network-inspect/planner.py
=================================

EXPERIMENTAL / RESEARCH POC — implements the "Planner + Plan IR Design
Gate" (verdict: READY TO IMPLEMENT). This is the only module in this
PoC that makes decisions — Inventory, Capability Registry, and
Desired State each answer a narrower question ("what's there," "what
can it do," "what's wanted"); this module is where those answers are
combined into a topology choice and a Plan IR.

ARCHITECTURAL BOUNDARY (enforced, not just documented)
---------------------------------------------------------
This module performs NO subprocess calls, NO file I/O, and imports
nothing from `run_command`, `providers/*`, `net_facts`, or
`hysteria2_config` — verified directly by import inspection in this
module's own test suite (`test_planner.py::TestArchitectureBoundary`),
not merely asserted here. It reads:
  - `inventory` (a `build_inventory()`-shaped dict) directly, but
    ONLY for the specific facts named in the Planner Input Contract
    below (listeners/ownership, public IPv4, Hysteria2 obfuscation,
    firewall authority) — NEVER for provider capability judgments.
  - `capability_registry` (a `capabilities.build_capability_registry()`
    -shaped dict) as the EXCLUSIVE source for any "can provider X do Y"
    question. This module never reads `inventory["detected_ingress"]`
    for a capability judgment — grepped and tested for directly.
  - `desired_state` (an already-`desired_state.validate()`-passed
    document) — this module does NOT re-validate it and does NOT
    import `desired_state.py` at all (no need to; by the time this
    module runs, the document is assumed already valid — re-validating
    here would be redundant coupling, not an extra safety benefit).
  - `safety_policy` (optional; defaults to `DEFAULT_SAFETY_POLICY`
    below if omitted).

PLANNER INPUT CONTRACT
-------------------------
| Fact                                  | Source               | Direct read? |
|----------------------------------------|-----------------------|--------------|
| listeners[] + ownership                | Inventory             | yes          |
| public_ipv4.count / .addresses         | Inventory             | yes          |
| hysteria2.obfuscation.effective_value  | Inventory             | yes          |
| firewall.authoritative_frontend        | Inventory             | yes          |
| any tcp.*/udp.* capability dimension   | Capability Registry   | yes, EXCLUSIVELY |
| services[] / operator_preferences      | Desired State         | yes (via effective form) |
| rule outcomes                          | Safety Policy         | yes          |

EFFECTIVE DESIRED STATE
--------------------------
`make_effective_desired_state()` materializes exactly the two frozen
defaults (`quic.migration_tolerant` absent -> `false`,
`operator_preferences.complexity_tolerance` absent -> `"prefer_simple"`,
plus the same-principle `ip_sharing_preference` absent -> `"no_preference"`)
into a NEW dict — `desired_state.py`'s own document is never mutated.
Every function below the entry point operates on this effective form
exclusively, so no downstream code ever has to ask "was this omitted."

RESOURCE IDENTITY
-------------------
- Service identity: the Desired State `id` string — already unique
  (enforced by `desired_state.validate()`), used as-is.
- Listener identity: `(transport, bind_address, bind_port)` — exactly
  the tuple Inventory observes directly; no invented data.
- Provider/mechanism identity: the Capability Registry provider key
  (`"nginx"`, `"caddy_l4"`, `"haproxy"`) — this Inventory model has no
  concept of multiple instances of the same provider on one host, so
  the provider name itself is a stable, sufficient identity.
- Group identity: `plan_ir.group_id()` — sorted, joined service ids.

LIMITATION, STATED EXPLICITLY RATHER THAN PAPERED OVER: this Inventory
model cannot verify whether an existing, resolved-owner listener is
ALREADY configured exactly the way a SHARED_* candidate would need
(no config-content introspection exists anywhere in this PoC — by
design, see inventory_build.py's own "shallow" scope). Consequently:
  - `action: "keep"` is only ever emitted for a lone, non-grouped
    service whose exact desired `(transport, port)` is already bound
    by a resolved owner — the trivial "something is already listening
    here, nothing more is asked of it" case.
  - Any SHARED_* placement onto an existing resolved listener is
    always classified `action: "reuse"`, never `"keep"` — Planner
    cannot know an addition isn't needed, so it never claims otherwise.
  - Matching an existing listener's owner to a *mechanism* (for
    REUSE vs CHANGE classification) is done via a best-effort process
    `comm` name lookup (`_MECHANISM_TO_COMM` below) — a real, named
    heuristic, not a guarantee; a renamed/wrapped binary would fall
    through to the conservative `"change"` classification rather than
    a false `"reuse"`.

TEMPORARY COMPATIBILITY SHIM — PROXY-PROTOCOL CAPABILITY GAP
------------------------------------------------------------------
`capabilities.py`'s `CAPABILITY_DIMENSIONS` has no
`tcp.proxy_protocol_in`/`.tcp.proxy_protocol_out` dimension — a real,
previously-identified schema gap (Planner design gate, §19-Q1), not
fixed this round per explicit instruction not to modify
`capabilities.py` without a proven blocker (this gap has a documented,
conservative workaround, so it isn't one). `_PROXY_PROTOCOL_STATIC_ASSUMPTION`
below is the ONE, explicitly-named place this assumption lives — it is
NOT part of the Capability Registry, is never consulted as if it were,
and currently names exactly one mechanism (`"nginx"`, backed by
`ngx_stream_proxy_module`'s mature, documented `proxy_protocol`
directive). Every other mechanism gets `None` (unknown) here, which
this module treats exactly like a `capability_absent`/`unresolved`
capability — conservative, never silently assumed `True`. This
assumption must never be extended to another provider without that
provider's own research-backed justification, and must be removed
entirely once `capabilities.py` grows a real dimension for this.
"""

from __future__ import annotations

import copy
import itertools
from typing import Any, Optional

import plan_ir

SUPPORTED_INVENTORY_SCHEMA = "poc-2"
SUPPORTED_CAPABILITY_SCHEMA = "capabilities-1"
SUPPORTED_DESIRED_STATE_SCHEMA = "desired-state-1"


# ─────────────────────────────────────────────────────────────────────
# Temporary compatibility shim — see module docstring. Isolated here,
# on its own, never merged into the capability-lookup helpers below.
# ─────────────────────────────────────────────────────────────────────

_PROXY_PROTOCOL_STATIC_ASSUMPTION = {
    "nginx": True,  # ngx_stream_proxy_module's `proxy_protocol` directive — mature, documented
}


def _mechanism_supports_proxy_protocol_out(mechanism: str) -> Optional[bool]:
    """None means unknown — callers must treat this exactly like an
    unresolved/absent capability, never as a silent False OR a silent
    True."""
    return _PROXY_PROTOCOL_STATIC_ASSUMPTION.get(mechanism)


# ─────────────────────────────────────────────────────────────────────
# Effective Desired State
# ─────────────────────────────────────────────────────────────────────

def make_effective_desired_state(document: dict) -> dict:
    """Returns a NEW dict — `document` (the caller's already-validated
    Desired State) is never mutated. Materializes exactly the frozen
    defaults; adds nothing else."""
    effective = copy.deepcopy(document)
    for svc in effective.get("services", []):
        quic = svc.get("quic")
        if quic is not None:
            quic.setdefault("migration_tolerant", False)
    prefs = effective.setdefault("operator_preferences", {})
    prefs.setdefault("complexity_tolerance", "prefer_simple")
    prefs.setdefault("ip_sharing_preference", "no_preference")
    return effective


# ─────────────────────────────────────────────────────────────────────
# Small internal helpers — compatibility checks mirroring (but not
# importing — see module docstring) desired_state.py's own internal
# union-find pattern. Kept independent so Planner never depends on
# desired_state.py's private implementation details, only its public
# `validate()` contract.
# ─────────────────────────────────────────────────────────────────────

class _UnionFind:
    def __init__(self, keys):
        self.parent = {k: k for k in keys}

    def find(self, k):
        while self.parent[k] != k:
            self.parent[k] = self.parent[self.parent[k]]
            k = self.parent[k]
        return k

    def union(self, a, b):
        ra, rb = self.find(a), self.find(b)
        if ra != rb:
            self.parent[ra] = rb


def _forced_separate(a: dict, b: dict) -> bool:
    a_ip, b_ip = a.get("ip") or {}, b.get("ip") or {}
    if a_ip.get("selection") == "separate_from_service" and a_ip.get("separate_from_service") == b["id"]:
        return True
    if b_ip.get("selection") == "separate_from_service" and b_ip.get("separate_from_service") == a["id"]:
        return True
    return False


def _ip_compatible(a: dict, b: dict) -> bool:
    a_ip, b_ip = a.get("ip") or {}, b.get("ip") or {}
    if a_ip.get("selection") == "specific" and b_ip.get("selection") == "specific":
        return a_ip.get("value") == b_ip.get("value")
    return True


def _ports_compatible(a: dict, b: dict) -> bool:
    a_port, b_port = a.get("port") or {}, b.get("port") or {}
    if a_port.get("selection") == "specific" and b_port.get("selection") == "specific":
        return a_port.get("value") == b_port.get("value")
    return True


def _placement_compatible(a: dict, b: dict) -> bool:
    """A pair of services that COULD share one (ip, port) listener —
    used both to form mandatory groups (when 'required' is involved)
    and to enumerate optional pairwise sharing candidates (when only
    'preferred'/'allowed' is involved)."""
    if a.get("transport") != b.get("transport"):
        return False
    a_port, b_port = a.get("port") or {}, b.get("port") or {}
    if a_port.get("sharing") == "forbidden" or b_port.get("sharing") == "forbidden":
        return False
    if _forced_separate(a, b):
        return False
    if not _ip_compatible(a, b):
        return False
    if not _ports_compatible(a, b):
        return False
    return True


def _ip_group_key(svc: dict) -> Optional[str]:
    ip = svc.get("ip") or {}
    if ip.get("selection") == "specific" and ip.get("value"):
        return f"__ip__:{ip['value']}"
    return None


def _build_mandatory_groups(services: list[dict]) -> dict[str, list[dict]]:
    """Union-find over service ids: two placement-compatible services
    are merged into one mandatory group ONLY when at least one side
    declares `sharing: required` on that edge — 'preferred'/'allowed'
    edges never force a merge by themselves (see module docstring's
    'do not turn required into preferred' requirement, honored here
    structurally: only 'required' edges ever call `.union()`)."""
    by_id = {s["id"]: s for s in services}
    ip_keys = {_ip_group_key(s) for s in services if _ip_group_key(s)}

    uf = _UnionFind(list(by_id.keys()) + list(ip_keys))
    for svc in services:
        key = _ip_group_key(svc)
        if key:
            uf.union(svc["id"], key)

    for a, b in itertools.combinations(sorted(by_id.keys()), 2):
        sa, sb = by_id[a], by_id[b]
        if not _placement_compatible(sa, sb):
            continue
        pa, pb = sa.get("port") or {}, sb.get("port") or {}
        if pa.get("sharing") == "required" or pb.get("sharing") == "required":
            uf.union(a, b)

    groups: dict[str, list[str]] = {}
    for sid in by_id:
        root = uf.find(sid)
        groups.setdefault(root, []).append(sid)

    return {root: [by_id[sid] for sid in sorted(ids)] for root, ids in groups.items() if len(ids) >= 2}


def _optional_pairs(services: list[dict], mandatory_ids: set) -> list:
    """Pairs eligible for an OPTIONAL (preferred/allowed) shared
    candidate — excludes any service already absorbed into a
    mandatory group (kept simple: no 3+-way optional grouping this
    round, a deliberate MVP scope limit, not a defect — see module
    docstring)."""
    pairs = []
    candidates = [s for s in services if s["id"] not in mandatory_ids]
    for a, b in itertools.combinations(sorted(candidates, key=lambda s: s["id"]), 2):
        if _placement_compatible(a, b):
            pairs.append((a, b))
    return pairs


# ─────────────────────────────────────────────────────────────────────
# Capability lookups — the ONLY place this module reads Capability
# Registry data, and the ONLY functions permitted to answer "can
# provider X do Y". Never bypassed elsewhere in this module — verified
# directly by `test_planner.py::TestArchitectureBoundary`.
# ─────────────────────────────────────────────────────────────────────

def _capability_status(capability_registry: dict, mechanism: str, dimension: str):
    """Returns (status, full_row). status is always one of
    available/unsupported/absent/unresolved — never invented."""
    provider = capability_registry.get("providers", {}).get(mechanism)
    if provider is None:
        return "absent", {"status": "absent", "confidence": None, "evidence": f"no Capability Registry entry for {mechanism!r}"}
    if provider.get("present") == "absent":
        return "absent", (provider.get("capabilities", {}) or {}).get(dimension, {})
    row = provider.get("capabilities", {}).get(dimension)
    if row is None:
        return "unresolved", {"status": "unresolved", "confidence": None, "evidence": f"no {dimension!r} row for {mechanism!r}"}
    return row.get("status", "unresolved"), row


def _mechanism_satisfies(capability_registry: dict, mechanism: str, dimensions: list):
    """Returns (fully_available, blocking_rows) — blocking_rows names
    every dimension that is NOT `available`, each tagged with its own
    status so the caller can classify the rejection precisely
    (unsupported vs absent vs unresolved) rather than collapsing them."""
    blocking = []
    for dim in dimensions:
        status, row = _capability_status(capability_registry, mechanism, dim)
        if status != "available":
            blocking.append({"dimension": dim, "status": status, "row": row})
    return (len(blocking) == 0), blocking


def _eligible_mechanisms(capability_registry: dict, dimensions: list):
    """Deterministically ordered (sorted) list of mechanisms whose
    Capability Registry entry satisfies every dimension. Iterating
    `capability_registry["providers"]` (a dict) is made safe here by
    sorting the keys before returning — dict iteration order is never
    allowed to influence which mechanism ends up first."""
    mechanisms = sorted(capability_registry.get("providers", {}).keys())
    eligible = []
    for m in mechanisms:
        ok, _ = _mechanism_satisfies(capability_registry, m, dimensions)
        if ok:
            eligible.append(m)
    return eligible


# ─────────────────────────────────────────────────────────────────────
# Safety Policy — declarative rule *data* (id + action, toggle-able),
# fixed condition-check *code* per rule (deliberately not a generic
# condition-interpreter/DSL — see module docstring's framing).
# ─────────────────────────────────────────────────────────────────────

DEFAULT_SAFETY_POLICY = {
    "schema_version": "safety-policy-1",
    "allow_remove": False,
    "rules": {
        "stop_on_unknown_owner": "stop",
        "unresolved_capability_not_assumed_available": "exclude_from_plan",
        "unsupported_capability_never_substituted": "exclude_from_plan",
        "migration_unsafe_requires_explicit_optin": "exclude_from_plan",
        "obfuscation_blocks_quic_sni_shared": "exclude_from_plan",
        "unmanaged_ingress_never_mutated": "exclude_from_plan",
        "firewall_authority_unknown_no_mutation": "exclude_from_plan",
    },
}


def _rule_action(safety_policy: dict, rule_id: str):
    return (safety_policy or {}).get("rules", {}).get(rule_id)


# ─────────────────────────────────────────────────────────────────────
# Inventory-only P0 checks — evaluated BEFORE candidate generation,
# per the design gate's own dispatch rule ("Inventory-only conditions
# -> pre-generation, action: stop"). This is rule #1 from the P0 list:
# unknown/permission-denied ownership.
# ─────────────────────────────────────────────────────────────────────

def _find_listener(inventory: dict, transport, port):
    for l in inventory.get("listeners", []):
        if l.get("proto") == transport and l.get("bind_port") == port:
            return l
    return None


def _check_unknown_ownership_stop(inventory: dict, effective_ds: dict, safety_policy: dict):
    """Returns a failure_reason string if the global STOP fires,
    else None."""
    if _rule_action(safety_policy, "stop_on_unknown_owner") != "stop":
        return None  # rule disabled by policy — not silently skipped, an explicit choice recorded in the policy itself
    for svc in effective_ds.get("services", []):
        port = svc.get("port") or {}
        if port.get("selection") != "specific":
            continue
        listener = _find_listener(inventory, svc.get("transport"), port.get("value"))
        if listener is None:
            continue
        if listener.get("pid_unresolved_reason") is not None:
            return (
                f"stop_on_unknown_owner: service {svc['id']!r} requires "
                f"{svc.get('transport')}:{port.get('value')}, which is already bound but its "
                f"owning process could not be resolved (pid_unresolved_reason="
                f"{listener['pid_unresolved_reason']!r}) — refusing to plan around an unknown owner"
            )
        owner = listener.get("owner") or {}
        if owner.get("kind") == "unknown":
            return (
                f"stop_on_unknown_owner: service {svc['id']!r} requires "
                f"{svc.get('transport')}:{port.get('value')}, which is already bound by a "
                f"resolved PID whose ownership could not be classified — refusing to plan "
                f"around an unknown owner"
            )
    return None


# ─────────────────────────────────────────────────────────────────────
# Existing-state reconciliation classification — KEEP / REUSE / CHANGE
# / CREATE (REMOVE handled separately, see `_compute_removals`).
# Classification only — no mutation, no rendering, matching the design
# gate's explicit scope.
# ─────────────────────────────────────────────────────────────────────

_MECHANISM_TO_COMM = {"nginx": "nginx", "caddy_l4": "caddy", "haproxy": "haproxy"}


def _classify_existing(inventory: dict, svc: dict, mechanism, is_grouped: bool):
    """Returns (action, change_scope, matched_listener_or_None)."""
    port = svc.get("port") or {}
    if port.get("selection") != "specific":
        return "create", "none", None
    listener = _find_listener(inventory, svc.get("transport"), port.get("value"))
    if listener is None:
        return "create", "none", None
    owner = listener.get("owner") or {}

    if mechanism is None:
        # DIRECT_* — this service's ENTIRE requirement is "own this
        # exact port," with no routing/sharing configuration to verify
        # beyond that. Inventory has no concept of an "expected binary
        # name" for an arbitrary standalone Desired State service, so
        # a RESOLVED existing owner is the strongest, and sufficient,
        # confirmation available — classified "keep" outright, never
        # gated on a comm-name match that DIRECT_* candidates have no
        # basis to require in the first place. (An unresolved owner
        # here is unreachable in practice: `_check_unknown_ownership_stop`
        # already halts the whole run before candidate generation for
        # that case.)
        if owner.get("kind") in ("docker", "systemd", "process"):
            return "keep", "none", listener
        return "change", "topology", listener

    comm = owner.get("comm") if owner.get("kind") == "process" else None
    if comm is None and owner.get("kind") == "systemd":
        comm = owner.get("unit")  # best-effort — systemd unit name often mirrors the binary
    mechanism_matches = comm is not None and _MECHANISM_TO_COMM.get(mechanism) == comm
    if mechanism_matches:
        if is_grouped:
            # Per module docstring's stated limitation: Inventory
            # cannot verify an existing listener already has the
            # exact routing this group needs — never claim "keep"
            # here, only "reuse" (an addition may be required).
            return "reuse", "none", listener
        return "keep", "none", listener
    # Something else is bound at this exact port — not a match for
    # the mechanism this candidate needs.
    return "change", "topology", listener


# ─────────────────────────────────────────────────────────────────────
# Candidate model — a plain dict, not a class, matching this project's
# established "just use dicts" convention throughout Inventory/
# Capabilities/Desired State.
# ─────────────────────────────────────────────────────────────────────

def _make_candidate(topology: str, mechanism, services: list):
    return {
        "topology": topology,
        "mechanism": mechanism,
        "services": services,
        "service_ids": [s["id"] for s in services],
        "candidate_id": plan_ir.candidate_id(topology, mechanism, [s["id"] for s in services]),
    }


def _required_dimensions_for_group(services: list):
    """Deterministic, sorted list of Capability Registry dimensions a
    SHARED_* candidate for this group needs, derived purely from the
    services' own declared requirements — never guessed, never
    provider-specific."""
    dims = set()
    transport = services[0].get("transport")
    if transport == "tcp":
        dims.add("tcp.listen")
        dims.add("tcp.proxy")
        dims.add("tcp.n_way_sni_routing" if len(services) > 2 else "tcp.sni_inspection")
        for s in services:
            tls = s.get("tls")
            if tls and tls.get("mode") == "passthrough":
                dims.add("tcp.tls_passthrough")
            elif tls and tls.get("mode") == "termination":
                dims.add("tcp.tls_termination")
    else:
        dims.add("udp.listen")
        dims.add("udp.proxy")
        for s in services:
            quic = s.get("quic")
            if quic and quic.get("sni_routing") == "passthrough":
                dims.add("udp.quic_inspection")
                dims.add("udp.quic_sni_routing")
        dims.add("udp.multi_backend_same_port")
    return sorted(dims)


def _quic_migration_gate_ok(services: list) -> bool:
    """P0 rule: migration risk requires EVERY affected service's
    effective migration_tolerant == true — one holdout blocks the
    whole group."""
    for s in services:
        quic = s.get("quic")
        if quic and quic.get("sni_routing") == "passthrough":
            if not quic.get("migration_tolerant", False):
                return False
    return True


def _obfuscation_gate_ok(inventory: dict):
    obf = inventory.get("hysteria2", {}).get("obfuscation", {})
    effective = obf.get("effective_value")
    if effective == "none":
        return True, "none"
    return False, str(effective)


# ─────────────────────────────────────────────────────────────────────
# Candidate generation
# ─────────────────────────────────────────────────────────────────────

def _generate_candidates(effective_ds: dict, inventory: dict, capability_registry: dict):
    """Returns (candidates, rejected_alternatives_from_generation) —
    some rejections are natural byproducts of generation itself (e.g.
    an ineligible mechanism for a mandatory group) and are recorded
    here rather than silently dropped."""
    services = effective_ds.get("services", [])
    rejected = []
    candidates = []

    mandatory_groups = _build_mandatory_groups(services)
    mandatory_ids = {s["id"] for group in mandatory_groups.values() for s in group}

    # Standalone DIRECT_* baseline for every service NOT in a
    # mandatory group.
    for svc in services:
        if svc["id"] in mandatory_ids:
            continue
        topology = "DIRECT_TCP" if svc.get("transport") == "tcp" else "DIRECT_UDP"
        candidates.append(_make_candidate(topology, None, [svc]))

    # Mandatory SHARED_* candidates — one per eligible mechanism.
    for group in mandatory_groups.values():
        transport = group[0].get("transport")
        dims = _required_dimensions_for_group(group)
        topology = "SHARED_TCP_SNI" if transport == "tcp" else "SHARED_UDP_QUIC_SNI"

        if topology == "SHARED_UDP_QUIC_SNI":
            obf_ok, obf_value = _obfuscation_gate_ok(inventory)
            if not obf_ok:
                rejected.append(plan_ir.build_rejected_alternative(
                    topology, None, [s["id"] for s in group],
                    "safety_policy_exclude",
                    f"Hysteria2 obfuscation is {obf_value!r}, not 'none' — no surveyed provider "
                    f"can route obfuscated QUIC traffic, so no shared-UDP-QUIC-SNI candidate is offered",
                    {"source": "inventory", "path": "hysteria2.obfuscation.effective_value", "value": obf_value},
                    "conditional",
                ))
                continue
            if not _quic_migration_gate_ok(group):
                rejected.append(plan_ir.build_rejected_alternative(
                    topology, None, [s["id"] for s in group],
                    "safety_policy_exclude",
                    "at least one service in this group has quic.sni_routing: passthrough but "
                    "effective migration_tolerant == false — shared UDP/QUIC routing is never "
                    "migration-safe on any surveyed provider, so this requires explicit operator opt-in",
                    {"source": "desired_state", "path": "services[].quic.migration_tolerant", "value": False},
                    "conditional",
                ))
                continue

        eligible = _eligible_mechanisms(capability_registry, dims)
        if not eligible:
            # Record ONE representative rejection per mechanism actually
            # present in the Registry, so the reason is traceable —
            # not a single vague "no mechanism available" line.
            for m in sorted(capability_registry.get("providers", {}).keys()):
                ok, blocking = _mechanism_satisfies(capability_registry, m, dims)
                if ok:
                    continue
                worst = blocking[0]
                permanence = "permanent" if worst["status"] == "unsupported" else "conditional"
                rejection_class = {
                    "unsupported": "capability_unsupported",
                    "absent": "capability_absent",
                    "unresolved": "capability_unresolved",
                }.get(worst["status"], "capability_unresolved")
                rejected.append(plan_ir.build_rejected_alternative(
                    topology, m, [s["id"] for s in group], rejection_class,
                    f"{m} does not satisfy required dimension {worst['dimension']!r} "
                    f"(status={worst['status']!r})",
                    {"source": "capability_registry", "path": f"providers.{m}.capabilities.{worst['dimension']}",
                     "value": worst["status"]},
                    permanence,
                ))
            continue

        for m in eligible:
            candidates.append(_make_candidate(topology, m, group))

    # Optional pairwise sharing candidates (preferred/allowed) —
    # generated alongside the standalone baselines already added
    # above for these same services; scoring decides between them.
    for a, b in _optional_pairs(services, mandatory_ids):
        transport = a.get("transport")
        dims = _required_dimensions_for_group([a, b])
        topology = "SHARED_TCP_SNI" if transport == "tcp" else "SHARED_UDP_QUIC_SNI"
        if topology == "SHARED_UDP_QUIC_SNI":
            obf_ok, _ = _obfuscation_gate_ok(inventory)
            if not obf_ok or not _quic_migration_gate_ok([a, b]):
                continue  # optional candidate simply isn't offered — not a "rejection" worth recording, since nothing required it
        eligible = _eligible_mechanisms(capability_registry, dims)
        for m in eligible:
            candidates.append(_make_candidate(topology, m, [a, b]))
        # SEPARATE_IPS alternative, only meaningful if ≥2 public IPs exist
        pub = inventory.get("public_ipv4", {})
        if pub.get("status") == "available" and (pub.get("count") or 0) >= 2:
            candidates.append(_make_candidate("SEPARATE_IPS", None, [a, b]))

    return candidates, rejected


# ─────────────────────────────────────────────────────────────────────
# Hard eligibility gates applied to every generated candidate — after
# generation, before scoring, per the frozen order:
#   generate -> exclude unsafe/ineligible -> score -> tie-break
# ─────────────────────────────────────────────────────────────────────

def _apply_hard_gates(candidates: list, inventory: dict, capability_registry: dict, safety_policy: dict):
    survivors = []
    rejected = []
    for c in candidates:
        ok, reason_row = _candidate_passes_gates(c, inventory, capability_registry, safety_policy)
        if ok:
            survivors.append(c)
        else:
            rejected.append(plan_ir.build_rejected_alternative(
                c["topology"], c["mechanism"], c["service_ids"],
                reason_row["rejection_class"], reason_row["reason"],
                reason_row["relevant_fact"], reason_row["permanence"],
            ))
    return survivors, rejected


def _candidate_passes_gates(c: dict, inventory: dict, capability_registry: dict, safety_policy: dict):
    services = c["services"]

    # NOTE: an existing, RESOLVED-but-non-matching listener at a
    # `specific` port is NOT a hard-reject condition here — it is
    # exactly the design gate's own "existing managed listener
    # conflicting -> CHANGE" worked example (§14): Planner is allowed
    # to PROPOSE replacing it (classified `action: "change"` in Plan
    # IR by `_classify_existing`/`_build_plan_ir`), it just never
    # scores as well as a candidate that can `keep`/`reuse` instead
    # (see `_score`'s tier2, which only rewards keep/reuse, not
    # change). Only an UNRESOLVED owner is a hard stop, and that's
    # already handled by `_check_unknown_ownership_stop` before
    # candidate generation ever runs — no separate gate is needed or
    # correct here.

    # Proxy-protocol requirement, via the temporary shim (see module
    # docstring) — applies only when a service actually declares it.
    for svc in services:
        pp = (svc.get("proxy_protocol") or {}).get("accept")
        if pp == "required" and c["mechanism"] is not None:
            supported = _mechanism_supports_proxy_protocol_out(c["mechanism"])
            if supported is not True:
                gap_note = ("unknown (no Capability Registry dimension exists yet — see "
                            "module docstring KNOWN GAP)") if supported is None else "not supported"
                return False, {
                    "rejection_class": "capability_unresolved" if supported is None else "capability_unsupported",
                    "reason": f"{svc['id']!r} requires proxy_protocol.accept: required, but "
                              f"mechanism {c['mechanism']!r}'s ability to send PROXY protocol is {gap_note}",
                    "relevant_fact": {"source": "planner_static_assumption",
                                      "path": "_PROXY_PROTOCOL_STATIC_ASSUMPTION", "value": supported},
                    "permanence": "conditional",
                }

    # Firewall authority unknown — only matters for a candidate that
    # would need a NEW port opened beyond what's already bound.
    if _rule_action(safety_policy, "firewall_authority_unknown_no_mutation") == "exclude_from_plan":
        firewall = inventory.get("firewall", {})
        if firewall.get("authoritative_frontend") == "none-detected":
            for svc in services:
                port = svc.get("port") or {}
                if port.get("selection") == "specific":
                    existing = _find_listener(inventory, svc.get("transport"), port.get("value"))
                    if existing is None:
                        return False, {
                            "rejection_class": "safety_policy_exclude",
                            "reason": f"no authoritative firewall frontend detected, and "
                                      f"{svc['id']!r} would require opening a new port — refusing "
                                      f"to plan a mutation with unknown firewall authority",
                            "relevant_fact": {"source": "inventory", "path": "firewall.authoritative_frontend",
                                               "value": "none-detected"},
                            "permanence": "conditional",
                        }

    return True, {}


# ─────────────────────────────────────────────────────────────────────
# Scoring — tiered, deterministic, lexicographic. Never overrides a
# hard gate (candidates reaching this point already survived all of
# them).
# ─────────────────────────────────────────────────────────────────────

def _score(candidate: dict, effective_ds: dict, inventory: dict, capability_registry: dict):
    """Lower tuple sorts first (i.e., wins). Every tier is an
    explicit, documented, small integer or string — no opaque
    aggregate weight anywhere."""
    prefs = effective_ds.get("operator_preferences", {})

    # Tier 1 — fewer new capability dependencies (prefers DIRECT_*/
    # SEPARATE_* over SHARED_*).
    tier1 = 0 if candidate["topology"] in ("DIRECT_TCP", "DIRECT_UDP", "SEPARATE_PORTS", "SEPARATE_IPS") else 1

    # Tier 2 — favors reuse/keep over create.
    reuse_count = 0
    for svc in candidate["services"]:
        port = svc.get("port") or {}
        if port.get("selection") == "specific":
            action, _, _ = _classify_existing(inventory, svc, candidate["mechanism"], is_grouped=len(candidate["services"]) > 1)
            if action in ("keep", "reuse"):
                reuse_count += 1
    tier2 = -reuse_count  # more reuse => more negative => sorts first

    # Tier 3 — operator preference alignment.
    tier3 = 0
    if candidate["topology"] == "SEPARATE_IPS" and prefs.get("ip_sharing_preference") == "prefer_separate_ips":
        tier3 = -1
    elif candidate["topology"] in ("SHARED_TCP_SNI", "SHARED_UDP_QUIC_SNI") and prefs.get("ip_sharing_preference") == "prefer_shared_ip":
        tier3 = -1
    if candidate["topology"] in ("SHARED_TCP_SNI", "SHARED_UDP_QUIC_SNI") and prefs.get("complexity_tolerance") == "prefer_simple":
        tier3 += 1  # simple-preferring operators mildly penalize shared/advanced topologies

    # Tier 4 — preferred port satisfaction (reserved for future
    # refinement — always 0 in this MVP; see _allocate_port).
    tier4 = 0

    # Tier 5 — aggregate confidence of required capabilities (higher
    # confidence sorts first => encoded as a smaller rank).
    confidence_rank = {"verified_by_probe": 0, "verified_by_docs": 1, "inferred_by_composition": 2, "unverified": 3, None: 3}
    if candidate["mechanism"]:
        dims = _required_dimensions_for_group(candidate["services"])
        worst_conf = 0
        for dim in dims:
            _, row = _capability_status(capability_registry, candidate["mechanism"], dim)
            worst_conf = max(worst_conf, confidence_rank.get(row.get("confidence"), 3))
        tier5 = worst_conf
    else:
        tier5 = 0

    # Tier 6 — final, always-deterministic tie-break: candidate_id
    # lexicographic order. Never randomness, never insertion order.
    tier6 = candidate["candidate_id"]

    return (tier1, tier2, tier3, tier4, tier5, tier6)


# ─────────────────────────────────────────────────────────────────────
# Plan IR assembly for the winning candidate set
# ─────────────────────────────────────────────────────────────────────

def _build_plan_ir(selected: list, effective_ds: dict, inventory: dict, safety_policy: dict):
    groups = []
    warnings = []

    for c in sorted(selected, key=lambda c: c["candidate_id"]):
        services_ir = []
        safety_decisions = []
        group_ip = _resolve_group_ip(c, inventory)
        for svc in c["services"]:
            port = svc.get("port") or {}
            is_grouped = len(c["services"]) > 1
            action, change_scope, listener = ("create", "none", None)
            if port.get("selection") == "specific":
                action, change_scope, listener = _classify_existing(inventory, svc, c["mechanism"], is_grouped)

            resolved_port = port.get("value") if port.get("selection") in ("specific", "preferred") else _allocate_port(svc, c)

            routing = None
            if c["mechanism"] is not None:
                if svc.get("tls"):
                    routing = plan_ir.build_routing("sni", svc["tls"].get("sni_values"))
                elif svc.get("quic"):
                    routing = plan_ir.build_routing("quic_sni", None)

            dims = _required_dimensions_for_group(c["services"]) if c["mechanism"] else []

            services_ir.append(plan_ir.build_service_entry(
                service_id=svc["id"],
                placement="colocated",
                action=action,
                change_scope=change_scope,
                listener=plan_ir.build_listener(svc.get("transport"), group_ip, resolved_port),
                routing=routing,
                required_capabilities=dims,
                proxy_protocol=(svc.get("proxy_protocol") or {}).get("accept", "not_supported"),
            ))

            if svc.get("exclusivity") == "single_ingress_path":
                safety_decisions.append(plan_ir.build_safety_decision(
                    "single_ingress_path", "passed",
                    f"{svc['id']!r} is placed on exactly one ingress path, honoring its "
                    f"exclusivity requirement",
                ))
            if svc.get("quic") and svc["quic"].get("migration_tolerant"):
                warnings.append(
                    "udp.quic_migration_safe is unsupported by every currently-known provider — "
                    "this plan relies on operator-accepted migration risk (migration_tolerant=true), "
                    "not on any provider actually solving NAT-rebinding/connection-migration"
                )

        groups.append(plan_ir.build_group(c["topology"], c["mechanism"], services_ir, safety_decisions))

    groups.sort(key=lambda g: g["group_id"])
    return plan_ir.assemble(groups, removals=[], dependencies=[], warnings=warnings)


def _allocate_port(svc: dict, candidate: dict) -> int:
    """`any`/`preferred` allocation — deterministic, minimal: prefers
    the declared `preferred` value if present, else 443 for the
    service's transport as this project's own overwhelmingly common
    case — a real, documented simplification, not a production port
    registry (no cross-service collision search is performed here;
    see LIMITATIONS in the accompanying report)."""
    port = svc.get("port") or {}
    if port.get("selection") == "preferred" and port.get("value"):
        return port["value"]
    return 443


def _resolve_group_ip(candidate: dict, inventory: dict) -> str:
    """Resolved ONCE per candidate/group — every service sharing this
    candidate's listener gets the SAME address, since sharing a
    listener literally means sharing one (ip, port). Any explicit
    `ip.selection: specific` value among the group's services acts as
    the anchor (validated already to be mutually consistent within a
    group by `desired_state.py`); `same_as_service` services never
    need their own separate lookup because they're already unioned
    into this same candidate's service list by
    `_build_mandatory_groups`/`_optional_pairs` — resolving the WHOLE
    group at once is what actually fixes that, rather than resolving
    each service independently and hoping they happen to agree."""
    services = candidate["services"]
    specific_values = sorted({
        s["ip"]["value"] for s in services
        if (s.get("ip") or {}).get("selection") == "specific" and s["ip"].get("value")
    })
    if specific_values:
        return specific_values[0]
    pub = inventory.get("public_ipv4", {})
    addresses = pub.get("addresses") or []
    if addresses:
        return addresses[0]["address"]
    return "0.0.0.0"  # no known public IPv4 — see design gate §19-Q2 (IPv6 unmodeled)


# ─────────────────────────────────────────────────────────────────────
# Top-level entry point
# ─────────────────────────────────────────────────────────────────────

def plan(inventory: dict, capability_registry: dict, desired_state: dict, safety_policy=None) -> dict:
    """The only public function in this module. Pure — no I/O, no
    mutation of any input. `desired_state` is assumed already
    `desired_state.validate()`-passed; this function does not
    re-validate it (see module docstring)."""
    safety_policy = safety_policy or DEFAULT_SAFETY_POLICY

    if inventory.get("schema_version") != SUPPORTED_INVENTORY_SCHEMA:
        return {"outcome": "stopped", "selected_topology": None, "plan_ir": None,
                "rejected_alternatives": [],
                "failure_reason": f"unsupported inventory schema_version {inventory.get('schema_version')!r}"}
    if capability_registry.get("schema_version") != SUPPORTED_CAPABILITY_SCHEMA:
        return {"outcome": "stopped", "selected_topology": None, "plan_ir": None,
                "rejected_alternatives": [],
                "failure_reason": f"unsupported capability registry schema_version {capability_registry.get('schema_version')!r}"}
    if desired_state.get("schema_version") != SUPPORTED_DESIRED_STATE_SCHEMA:
        return {"outcome": "stopped", "selected_topology": None, "plan_ir": None,
                "rejected_alternatives": [],
                "failure_reason": f"unsupported desired state schema_version {desired_state.get('schema_version')!r}"}

    effective_ds = make_effective_desired_state(desired_state)

    stop_reason = _check_unknown_ownership_stop(inventory, effective_ds, safety_policy)
    if stop_reason:
        return {"outcome": "stopped", "selected_topology": None, "plan_ir": None,
                "rejected_alternatives": [], "failure_reason": stop_reason}

    candidates, gen_rejected = _generate_candidates(effective_ds, inventory, capability_registry)
    survivors, gate_rejected = _apply_hard_gates(candidates, inventory, capability_registry, safety_policy)
    rejected_alternatives = gen_rejected + gate_rejected

    all_service_ids = {s["id"] for s in effective_ds.get("services", [])}

    if not survivors:
        return {
            "outcome": "unsatisfiable", "selected_topology": None, "plan_ir": None,
            "rejected_alternatives": rejected_alternatives,
            "failure_reason": "no eligible candidate satisfies every required service under the "
                               "given Inventory, Capability Registry, and Safety Policy",
        }

    # Group survivors by disjoint service coverage, choosing the
    # best-scoring candidate per uncovered service set, deterministically.
    survivors_sorted = sorted(survivors, key=lambda c: _score(c, effective_ds, inventory, capability_registry))
    selected = []
    covered = set()
    for c in survivors_sorted:
        if covered & set(c["service_ids"]):
            continue  # a higher/equal-scoring candidate already covers one of these services
        selected.append(c)
        covered |= set(c["service_ids"])

    for c in survivors_sorted:
        if c in selected:
            continue
        if set(c["service_ids"]) & covered:
            winner = next(s for s in selected if set(s["service_ids"]) & set(c["service_ids"]))
            rejected_alternatives.append(plan_ir.build_rejected_alternative(
                c["topology"], c["mechanism"], c["service_ids"],
                "lower_score",
                f"candidate {c['candidate_id']!r} scored lower than the selected "
                f"candidate {winner['candidate_id']!r} for overlapping service(s)",
                {"source": "planner_scoring", "path": "score_tuple", "value": None},
                "conditional",
            ))

    if covered != all_service_ids:
        missing = sorted(all_service_ids - covered)
        return {
            "outcome": "unsatisfiable", "selected_topology": None, "plan_ir": None,
            "rejected_alternatives": rejected_alternatives,
            "failure_reason": f"no surviving candidate covers service(s) {missing!r}",
        }

    plan_ir_doc = _build_plan_ir(selected, effective_ds, inventory, safety_policy)
    topologies = sorted({c["topology"] for c in selected})
    selected_topology = topologies[0] if len(topologies) == 1 else topologies

    return {
        "outcome": "planned",
        "selected_topology": selected_topology,
        "plan_ir": plan_ir_doc,
        "rejected_alternatives": rejected_alternatives,
        "failure_reason": None,
    }
