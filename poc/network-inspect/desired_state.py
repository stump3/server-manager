#!/usr/bin/env python3
"""
poc/network-inspect/desired_state.py
=======================================

EXPERIMENTAL / RESEARCH POC — see poc/network-inspect/README.md and
the "Desired State Schema Review Gate" design report this module
implements verbatim (schema frozen there; no shape decisions are made
in this file).

THE FOUR-ENTITY MODEL
-----------------------
  Inventory            = observed current state (inventory_build.py)
  Capability Registry   = available capabilities (capabilities.py)
  Desired State         = operator intent                (THIS MODULE)
  Safety Policy         = non-negotiable safety constraints (not yet implemented)
  Planner               = decision maker (not yet implemented)

Desired State and Safety Policy are independent Planner INPUTS, not
sequential layers on top of Inventory/Capabilities:

               Inventory
                   ↓
              Capabilities ─────┐
                                ├──→ Planner
  Desired State ────────────────┤
                                │
  Safety Policy ─────────────────┘

This module MUST NOT — and structurally does not — read, import, or
know about `inventory_build.py`, `net_facts.py`, `hysteria2_config.py`,
`providers/*`, or `capabilities.py`. `validate()` is a pure function
of the document it's handed: no subprocess calls, no file I/O, no
knowledge of what's actually running on any host. A Desired State
document is meaningful before any host has ever been inspected.

WHAT THIS MODULE DOES NOT DO
-------------------------------
No topology selection, no provider/mechanism choice, no scoring, no
Plan IR, no config rendering, no apply/rollback. `validate()` answers
exactly one question: "is this document an internally self-consistent
statement of intent" — never "is this achievable on any particular
host" (that requires Inventory + Capability Registry + Safety Policy,
i.e. Planner, which doesn't exist yet).

WHY A DENYLIST OF PROVIDER/TOPOLOGY NAMES EXISTS HERE
--------------------------------------------------------
This is the one place this module is allowed to know such names exist
— purely to REJECT them if an operator's `id` field collides with one,
per the Schema Review Gate's own provider/topology-independence
requirement. This is not the same as this module "knowing about"
providers or topologies in any functional sense: the list is never
consulted to make a decision, interpret a field, or infer anything —
it only ever produces a rejection when a document's own free-text
`id` value coincides with a name from a fixed, external list. See
`_DENYLISTED_NORMALIZED` below.

WHY VALIDATION IS DOCUMENT-LEVEL, NOT HOST-LEVEL
-----------------------------------------------------
Every check in this module is answerable by reading the document
alone: type/shape correctness, per-service field consistency (e.g.
`tls` only valid under `transport: tcp`), and a small set of
CROSS-SERVICE self-consistency checks that follow directly from the
Schema Review Gate's own corrected semantics for `port.sharing` and
`ip.selection` (see `_validate_cross_service_sharing()` below). None
of these checks ever require knowing what's actually installed or
listening on any real host — that distinction is exactly what keeps
this module in the Desired State layer rather than sliding into
Planner's job.

ERROR MODEL
-------------
`validate()` never raises on malformed input (missing keys, wrong
types, `None` where a mapping was expected, etc.) — every failure
mode is reported as a `ValidationError(code, path, message)` in the
returned `ValidationResult.errors` list, mirroring this project's own
established honest-unknown convention (specific reason, never a bare
crash or a silent `False`). Structural errors (wrong types, missing
required fields, invalid enum values) are collected first; the
cross-service semantic checks (§ port sharing satisfiability, ip
group contradictions) only run if the document is at least
structurally well-formed, so a malformed document never produces a
cascade of confusing, secondary semantic errors on top of its real,
structural one.

PUBLIC API
------------
    validate(document) -> ValidationResult
    ValidationResult.valid: bool
    ValidationResult.errors: list[ValidationError]
    ValidationResult.as_dict() -> dict   # JSON-serializable form
"""

from __future__ import annotations

from dataclasses import dataclass, field as dc_field
from typing import Any, Optional

SCHEMA_VERSION = "desired-state-1"

_VALID_TRANSPORTS = ("tcp", "udp")
_VALID_EXPOSURES = ("public", "private", "localhost")
_VALID_PORT_SELECTIONS = ("specific", "any", "preferred")
_VALID_SHARING = ("required", "preferred", "allowed", "forbidden")
_VALID_IP_SELECTIONS = ("specific", "any_public", "same_as_service", "separate_from_service")
_VALID_TLS_MODES = ("termination", "passthrough")
_VALID_QUIC_SNI_ROUTING = ("passthrough", "not_required")
_VALID_PROXY_PROTOCOL_ACCEPT = ("required", "optional", "not_supported")
_VALID_EXCLUSIVITY = ("single_ingress_path",)  # None is also valid — checked separately
_VALID_IP_SHARING_PREFERENCE = ("prefer_separate_ips", "prefer_shared_ip", "no_preference")
_VALID_COMPLEXITY_TOLERANCE = ("prefer_simple", "advanced_ok")

# Provider and topology names this module exists to REJECT if found as
# a service `id` — see module docstring "WHY A DENYLIST EXISTS HERE".
# Compared against a normalized (lowercased, non-alphanumeric stripped)
# form, so "caddy-l4", "caddy_l4", "Caddy L4" are all caught as the
# same entry without the list needing every punctuation variant
# spelled out.
_DENYLISTED_NORMALIZED = {
    "nginx", "caddy", "caddyl4", "haproxy", "envoy",
    "sharedtcpsni", "sharedudpquicsni",
    "directtcp", "directudp",
    "separateports", "separateips",
    "tcpsnirouter", "quicsnirouter",
    "colocated", "remotenode",
}


def _normalize(s: str) -> str:
    return "".join(ch for ch in s.lower() if ch.isalnum())


@dataclass
class ValidationError:
    code: str
    path: str
    message: str


@dataclass
class ValidationResult:
    valid: bool
    schema_version: str
    errors: list[ValidationError] = dc_field(default_factory=list)

    def as_dict(self) -> dict:
        return {
            "valid": self.valid,
            "schema_version": self.schema_version,
            "errors": [
                {"code": e.code, "path": e.path, "message": e.message}
                for e in self.errors
            ],
        }


# ─────────────────────────────────────────────────────────────────────
# Small internal helpers — not a validation framework, just enough
# shared plumbing to keep each check's own code short and consistent.
# ─────────────────────────────────────────────────────────────────────

def _is_mapping(x: Any) -> bool:
    return isinstance(x, dict)


def _err(errors: list[ValidationError], code: str, path: str, message: str) -> None:
    errors.append(ValidationError(code=code, path=path, message=message))


def _check_enum(errors: list[ValidationError], value: Any, allowed: tuple, path: str, *, required: bool = True) -> bool:
    """Returns True iff value is valid (present-and-allowed, or
    legitimately absent when not required)."""
    if value is None:
        if required:
            _err(errors, "missing_field", path, f"required field is missing (expected one of {allowed!r})")
            return False
        return True
    if value not in allowed:
        _err(errors, "invalid_enum_value", path, f"{value!r} is not one of {allowed!r}")
        return False
    return True


# ─────────────────────────────────────────────────────────────────────
# Top-level document validation
# ─────────────────────────────────────────────────────────────────────

def validate(document: Any) -> ValidationResult:
    errors: list[ValidationError] = []

    if not _is_mapping(document):
        _err(errors, "not_a_mapping", "$", "top-level document must be a mapping/object")
        return ValidationResult(valid=False, schema_version=SCHEMA_VERSION, errors=errors)

    schema_version = document.get("schema_version")
    if schema_version is None:
        _err(errors, "missing_schema_version", "$.schema_version", "schema_version is required")
    elif schema_version != SCHEMA_VERSION:
        _err(errors, "unsupported_schema_version", "$.schema_version",
             f"expected {SCHEMA_VERSION!r}, got {schema_version!r}")

    services = document.get("services")
    services_by_id: dict[str, dict] = {}
    if services is None:
        _err(errors, "missing_services", "$.services", "services is required")
    elif not isinstance(services, list):
        _err(errors, "services_not_a_list", "$.services", "services must be a list")
    elif len(services) == 0:
        _err(errors, "services_empty", "$.services", "services must contain at least one entry")
    else:
        for i, svc in enumerate(services):
            path = f"$.services[{i}]"
            if not _is_mapping(svc):
                _err(errors, "service_not_a_mapping", path, "each service must be a mapping/object")
                continue
            svc_id = svc.get("id")
            if not isinstance(svc_id, str) or not svc_id:
                _err(errors, "invalid_service_id", f"{path}.id", "id must be a non-empty string")
            elif svc_id in services_by_id:
                _err(errors, "duplicate_service_id", f"{path}.id", f"duplicate service id {svc_id!r}")
            else:
                if _normalize(svc_id) in _DENYLISTED_NORMALIZED:
                    _err(errors, "denylisted_identifier", f"{path}.id",
                         f"service id {svc_id!r} names a provider or topology — Desired State must "
                         f"describe intent, never a provider/topology choice (Planner's job)")
                services_by_id[svc_id] = svc

        for i, svc in enumerate(services):
            if _is_mapping(svc):
                _validate_service(errors, svc, f"$.services[{i}]", services_by_id)

    operator_preferences = document.get("operator_preferences")
    if operator_preferences is not None:
        _validate_operator_preferences(errors, operator_preferences, "$.operator_preferences")

    # Cross-service semantic checks only run once the document is at
    # least structurally sound — see module docstring "ERROR MODEL".
    if not errors and services:
        _validate_cross_service_sharing(errors, services, services_by_id)

    return ValidationResult(valid=not errors, schema_version=SCHEMA_VERSION, errors=errors)


# ─────────────────────────────────────────────────────────────────────
# Per-service structural + cross-field validation
# ─────────────────────────────────────────────────────────────────────

def _validate_service(errors: list[ValidationError], svc: dict, path: str, services_by_id: dict[str, dict]) -> None:
    transport = svc.get("transport")
    _check_enum(errors, transport, _VALID_TRANSPORTS, f"{path}.transport")

    _check_enum(errors, svc.get("exposure"), _VALID_EXPOSURES, f"{path}.exposure")

    _validate_port(errors, svc.get("port"), f"{path}.port")
    _validate_ip(errors, svc.get("ip"), f"{path}.ip", svc.get("id"), services_by_id)

    tls = svc.get("tls")
    if tls is not None:
        if transport != "tcp":
            _err(errors, "tls_requires_tcp_transport", f"{path}.tls",
                 f"tls block is only valid when transport == 'tcp' (got transport={transport!r})")
        _validate_tls(errors, tls, f"{path}.tls")

    quic = svc.get("quic")
    if quic is not None:
        if transport != "udp":
            _err(errors, "quic_requires_udp_transport", f"{path}.quic",
                 f"quic block is only valid when transport == 'udp' (got transport={transport!r})")
        _validate_quic(errors, quic, f"{path}.quic")

    proxy_protocol = svc.get("proxy_protocol")
    if proxy_protocol is not None:
        if not _is_mapping(proxy_protocol):
            _err(errors, "invalid_type", f"{path}.proxy_protocol", "proxy_protocol must be a mapping")
        else:
            _check_enum(errors, proxy_protocol.get("accept"), _VALID_PROXY_PROTOCOL_ACCEPT, f"{path}.proxy_protocol.accept")

    exclusivity = svc.get("exclusivity")
    if exclusivity is not None and exclusivity not in _VALID_EXCLUSIVITY:
        _err(errors, "invalid_enum_value", f"{path}.exclusivity",
             f"{exclusivity!r} is not one of {_VALID_EXCLUSIVITY!r} (or null)")


def _validate_port(errors: list[ValidationError], port: Any, path: str) -> None:
    if port is None:
        _err(errors, "missing_field", path, "port is required")
        return
    if not _is_mapping(port):
        _err(errors, "invalid_type", path, "port must be a mapping")
        return

    selection = port.get("selection")
    if not _check_enum(errors, selection, _VALID_PORT_SELECTIONS, f"{path}.selection"):
        selection = None  # avoid cascading a bogus value into the checks below

    value = port.get("value")
    if selection == "any":
        if value is not None:
            _err(errors, "port_value_forbidden_for_any", f"{path}.value",
                 "value must be null when selection == 'any'")
    elif selection in ("specific", "preferred"):
        if value is None:
            _err(errors, "port_value_required", f"{path}.value",
                 f"value is required when selection == {selection!r}")
        elif not isinstance(value, int) or isinstance(value, bool) or not (1 <= value <= 65535):
            _err(errors, "invalid_port_value", f"{path}.value", f"{value!r} is not a valid port number (1-65535)")

    _check_enum(errors, port.get("sharing"), _VALID_SHARING, f"{path}.sharing")


def _validate_ip(errors: list[ValidationError], ip: Any, path: str, own_id: Any, services_by_id: dict[str, dict]) -> None:
    if ip is None:
        _err(errors, "missing_field", path, "ip is required")
        return
    if not _is_mapping(ip):
        _err(errors, "invalid_type", path, "ip must be a mapping")
        return

    selection = ip.get("selection")
    if not _check_enum(errors, selection, _VALID_IP_SELECTIONS, f"{path}.selection"):
        return

    value = ip.get("value")
    same_as = ip.get("same_as_service")
    separate_from = ip.get("separate_from_service")

    if selection == "specific":
        if not value or not isinstance(value, str):
            _err(errors, "ip_value_required", f"{path}.value", "value is required (non-empty string) when selection == 'specific'")
    elif value is not None:
        _err(errors, "ip_value_forbidden", f"{path}.value", f"value must be null when selection == {selection!r}")

    if selection == "same_as_service":
        _validate_service_reference(errors, same_as, f"{path}.same_as_service", "ip_same_as_service", own_id, services_by_id)
    elif same_as is not None:
        _err(errors, "ip_same_as_service_forbidden", f"{path}.same_as_service",
             f"same_as_service must be null when selection == {selection!r}")

    if selection == "separate_from_service":
        _validate_service_reference(errors, separate_from, f"{path}.separate_from_service", "ip_separate_from_service", own_id, services_by_id)
    elif separate_from is not None:
        _err(errors, "ip_separate_from_service_forbidden", f"{path}.separate_from_service",
             f"separate_from_service must be null when selection == {selection!r}")


def _validate_service_reference(errors: list[ValidationError], ref: Any, path: str, code_prefix: str,
                                 own_id: Any, services_by_id: dict[str, dict]) -> None:
    if not ref or not isinstance(ref, str):
        _err(errors, f"{code_prefix}_required", path, "a non-empty service id reference is required")
        return
    if ref == own_id:
        _err(errors, f"{code_prefix}_self_reference", path, "a service cannot reference itself here")
        return
    if ref not in services_by_id:
        _err(errors, f"{code_prefix}_unknown_reference", path, f"references unknown service id {ref!r}")


def _validate_tls(errors: list[ValidationError], tls: Any, path: str) -> None:
    if not _is_mapping(tls):
        _err(errors, "invalid_type", path, "tls must be a mapping")
        return
    _check_enum(errors, tls.get("mode"), _VALID_TLS_MODES, f"{path}.mode")
    sni_values = tls.get("sni_values")
    if sni_values is not None:
        if not isinstance(sni_values, list) or not all(isinstance(v, str) for v in sni_values):
            _err(errors, "invalid_type", f"{path}.sni_values", "sni_values must be a list of strings")


def _validate_quic(errors: list[ValidationError], quic: Any, path: str) -> None:
    if not _is_mapping(quic):
        _err(errors, "invalid_type", path, "quic must be a mapping")
        return
    _check_enum(errors, quic.get("sni_routing"), _VALID_QUIC_SNI_ROUTING, f"{path}.sni_routing")
    migration_tolerant = quic.get("migration_tolerant", False)
    if not isinstance(migration_tolerant, bool):
        _err(errors, "invalid_type", f"{path}.migration_tolerant", "migration_tolerant must be a boolean if present (defaults to false)")


def _validate_operator_preferences(errors: list[ValidationError], prefs: Any, path: str) -> None:
    if not _is_mapping(prefs):
        _err(errors, "invalid_type", path, "operator_preferences must be a mapping")
        return
    _check_enum(errors, prefs.get("ip_sharing_preference"), _VALID_IP_SHARING_PREFERENCE,
                f"{path}.ip_sharing_preference", required=False)
    _check_enum(errors, prefs.get("complexity_tolerance"), _VALID_COMPLEXITY_TOLERANCE,
                f"{path}.complexity_tolerance", required=False)


# ─────────────────────────────────────────────────────────────────────
# Cross-service semantic checks — the two rules the Schema Review Gate
# specifically added on top of pure per-service structural validation.
# Deliberately minimal: each answers a question that is decidable from
# the document ALONE (no host knowledge), and each traces to a named
# scenario from the review gate (C/D for the "required" satisfiability
# check, F for the "forbidden" contradiction check) — no additional
# cross-service rule is added beyond these two, per the "do not
# over-model" instruction carried through every round of this design.
# ─────────────────────────────────────────────────────────────────────

class _UnionFind:
    """Tiny disjoint-set structure — not a general graph library, just
    enough to group services (and synthetic "specific IP value" nodes)
    that are FORCED to share an IP, so the two checks below can ask
    "are these two services provably on the same IP" in O(1) after
    O(n) setup, instead of re-walking reference chains per pair."""

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


def _build_ip_groups(services: list[dict]) -> _UnionFind:
    keys = [svc["id"] for svc in services]
    # Synthetic nodes for each distinct specific IP literal, so two
    # services both declaring the SAME specific value are grouped
    # together without needing a same_as_service link between them.
    specific_values = {
        svc["ip"]["value"]
        for svc in services
        if _is_mapping(svc.get("ip")) and svc["ip"].get("selection") == "specific" and svc["ip"].get("value")
    }
    uf = _UnionFind(keys + [f"__ip__:{v}" for v in specific_values])

    for svc in services:
        ip = svc.get("ip")
        if not _is_mapping(ip):
            continue
        selection = ip.get("selection")
        if selection == "specific" and ip.get("value"):
            uf.union(svc["id"], f"__ip__:{ip['value']}")
        elif selection == "same_as_service" and ip.get("same_as_service"):
            uf.union(svc["id"], ip["same_as_service"])

    return uf


def _forced_separate(a: dict, b: dict) -> bool:
    """Direct (non-transitive) separate_from_service check only — see
    module docstring / Schema Review Gate open question: transitive
    separation chains are not modeled, since no A-K scenario requires
    them (do-not-over-model principle)."""
    a_ip, b_ip = a.get("ip") or {}, b.get("ip") or {}
    if a_ip.get("selection") == "separate_from_service" and a_ip.get("separate_from_service") == b["id"]:
        return True
    if b_ip.get("selection") == "separate_from_service" and b_ip.get("separate_from_service") == a["id"]:
        return True
    return False


def _ports_compatible(a_port: dict, b_port: dict) -> bool:
    """Two port requirements are compatible (i.e. NOT provably unable
    to coexist) unless both are 'specific' with different values."""
    if a_port.get("selection") == "specific" and b_port.get("selection") == "specific":
        return a_port.get("value") == b_port.get("value")
    return True


def _validate_cross_service_sharing(errors: list[ValidationError], services: list[dict], services_by_id: dict[str, dict]) -> None:
    uf = _build_ip_groups(services)

    # Rule 1 (scenario F): port.sharing == "forbidden" contradicted by
    # being FORCED onto the same (ip, port) as another service.
    for i, a in enumerate(services):
        for b in services[i + 1:]:
            a_port, b_port = a.get("port") or {}, b.get("port") or {}
            if a_port.get("sharing") != "forbidden" and b_port.get("sharing") != "forbidden":
                continue
            same_ip = uf.find(a["id"]) == uf.find(b["id"])
            same_specific_port = (
                a_port.get("selection") == "specific"
                and b_port.get("selection") == "specific"
                and a_port.get("value") == b_port.get("value")
            )
            if same_ip and same_specific_port:
                _err(
                    errors, "sharing_forbidden_contradiction",
                    f"$.services[{a['id']!r},{b['id']!r}]",
                    f"services {a['id']!r} and {b['id']!r} are forced onto the same "
                    f"(ip, port={a_port.get('value')}) but at least one declares "
                    f"port.sharing: forbidden — this document is self-contradictory",
                )

    # Rule 2 (scenarios C/D): port.sharing == "required" must have at
    # least one plausible partner elsewhere in the document.
    for svc in services:
        port = svc.get("port") or {}
        if port.get("sharing") != "required":
            continue
        has_partner = False
        for other in services:
            if other["id"] == svc["id"]:
                continue
            other_port = other.get("port") or {}
            if other.get("transport") != svc.get("transport"):
                continue
            if other_port.get("sharing") == "forbidden":
                continue
            if not _ports_compatible(port, other_port):
                continue
            if _forced_separate(svc, other):
                continue
            # If both declare a specific, different IP, they can never
            # coexist regardless of port compatibility.
            svc_ip, other_ip = svc.get("ip") or {}, other.get("ip") or {}
            if (svc_ip.get("selection") == "specific" and other_ip.get("selection") == "specific"
                    and svc_ip.get("value") != other_ip.get("value")):
                continue
            has_partner = True
            break
        if not has_partner:
            _err(
                errors, "sharing_required_no_partner", f"$.services[{svc['id']!r}].port.sharing",
                f"service {svc['id']!r} declares port.sharing: required, but no other service "
                f"in this document is a plausible sharing partner (matching transport, "
                f"compatible port, sharing != forbidden, not explicitly separated) — "
                f"this document is unsatisfiable as written",
            )
