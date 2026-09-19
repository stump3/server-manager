#!/usr/bin/env python3
"""
poc/network-inspect/renderers/nginx.py
=========================================

EXPERIMENTAL / RESEARCH POC — first Provider Renderer. Translates an
already-valid Plan IR (plan_ir.py, verified by plan_validator.py) into
deterministic nginx configuration text for `SHARED_TCP_SNI` groups
whose `mechanism == "nginx"`. No other topology or mechanism is
handled by this module (see SCOPE below).

CONTRACT
----------
    render(plan: dict) -> RenderResult

    RenderResult.valid: bool
    RenderResult.provider: str            # always "nginx"
    RenderResult.artifacts: list[Artifact]
    RenderResult.diagnostics: list[Diagnostic]

`Diagnostic`/`Artifact`/`RenderResult` deliberately mirror
plan_validator.py's own `Diagnostic`/`PlanValidationResult` field names
(`code`, `severity`, `resource_id`, `field`, `message` /
`valid`, `diagnostics`, `.errors()`, `.warnings()`) — same shape,
independently defined here (this module must not import
plan_validator.py; see ARCHITECTURAL BOUNDARY below).

SCOPE — WHAT THIS RENDERS
----------------------------
Only `plan["groups"]` entries where `group["mechanism"] == "nginx"`.
Every other group (`mechanism: null` for DIRECT_*/SEPARATE_*, or any
other mechanism string) is silently skipped — not an error, simply
not this renderer's concern, exactly the way a provider-specific
adapter is expected to ignore resources it doesn't own. Within the
groups it does own, only `topology == "SHARED_TCP_SNI"` is supported
— the only topology this project's own Planner/Capability Registry
ever actually assigns to nginx (nginx is modeled as TCP-only; see
capabilities.py's `_nginx_entry()` and `_NGINX_TCP_FULL` in
tests/test_planner.py). A `mechanism: "nginx"` group with any other
topology is a structured `unsupported_topology` error, not a silent
skip — that combination should never occur from real Planner output,
so if it does, something upstream is wrong and this module says so
rather than guessing.

`plan["removals"]` is never processed here. `build_removal()`
(plan_ir.py) produces only `{"resource": str, "requires_explicit_
confirmation": true}` — no listener, no backend, no config shape at
all — there is nothing in that schema for a Renderer to translate.
Removal *rendering* is not a gap this module works around; it is
simply not representable by the current Plan IR schema, and inventing
a shape for it here would be exactly the kind of "Renderer becomes a
second Planner" this whole layer exists to avoid.

SOURCE-GROUNDED SYNTAX
--------------------------
The map/upstream/server{} shape below is not generic nginx knowledge —
it is the exact structure this project's own legacy generators already
use for this precise scenario, read directly from source before
writing anything here:

    lib/panel/nginx/variant_f.sh (stream{} block, "Public :443"):

        stream {
            map $ssl_preread_server_name $f_backend {
                panel.example   panel_and_sub;
                sub.example     panel_and_sub;
                telemt.example  telemt;
                default         xray_reality;
            }
            upstream panel_and_sub { server 127.0.0.1:8443; }
            upstream xray_reality  { server 127.0.0.1:9443; }
            upstream telemt        { server 127.0.0.1:10001; }

            server {
                listen 443;
                ssl_preread on;
                proxy_pass $f_backend;
                proxy_protocol on;
            }
        }

    lib/panel/nginx/variant_j.sh's stream{} block is structurally
    identical (confirmed by direct comparison, same map/upstream/
    server{} shape, same `$j_backend` naming pattern).

TLS MODE DOES NOT CHANGE THIS SYNTAX
-----------------------------------------
Traced directly from the legacy source, not assumed: the shared
stream{} server{} block above forwards raw, unterminated TCP bytes via
`proxy_pass` to whichever `upstream` the SNI map selected — it never
terminates TLS itself (`ssl_preread` reads the ClientHello's SNI
without consuming the connection). Whether the *destination* service
terminates TLS (`panel_and_sub`, an http{} server{} block on a
loopback port with its own certs — a SEPARATE artifact this renderer
does not generate, since Plan IR carries no certificate path
information) or passes it through untouched (`xray_reality`, REALITY)
is entirely invisible at this layer: both are just an `upstream`
pointing at a `backend.address:backend.port`. Consequently
`tls.mode`/`required_capabilities` entries like `tcp.tls_termination`/
`tcp.tls_passthrough` are not consumed by this renderer at all — they
already did their job during Planner's mechanism-eligibility checks,
and change nothing about the stream{}-level dispatch text.

PROXY PROTOCOL
------------------
`proxy_protocol` is rendered exactly the way variant_f.sh/variant_j.sh
already do it: one `proxy_protocol on;` line in the shared server{}
block if ANY service in the group has `proxy_protocol == "required"`,
omitted entirely otherwise (nginx's own default is off — omitting the
line is not an invented "off" state, it is nginx's documented
behavior). Never rendered per-backend — Planner's own group-level gate
(planner.py's `_candidate_passes_gates()`) already guarantees, by the
time a group reaches this renderer, that "required" and "not_supported"
never coexist in the same nginx-mechanism group; this renderer trusts
that invariant rather than re-deriving it (see docs #15 — proxy
protocol compatibility is Planner's decision, not re-litigated here).

EMPTY SNI / DEFAULT BACKEND
--------------------------------
A service with an empty `routing.match.sni` becomes the map's
`default` branch — plan_validator.py's `ambiguous_default_sni_backend`
rule already guarantees at most one such service per group. This
renderer defensively re-counts that invariant (never re-decides it)
purely because it is handed a plan directly in tests without always
going through plan_validator.py first — see ARCHITECTURAL BOUNDARY.
Two *different* services both claiming the *same* SNI hostname is not
covered by any existing Plan Validator rule; this renderer cannot
guess which one should win, so it reports `duplicate_sni_value`
rather than picking one arbitrarily.

WHAT THIS DELIBERATELY DOES NOT DO
---------------------------------------
No subprocess, no shell, no filesystem access, no `nginx -t`, no
reload, no reading of running nginx/Inventory/Desired State, no
topology or mechanism selection, no IP/port allocation, no capability
analysis, no proxy_protocol compatibility re-checking, no TLS
certificate handling, no removal rendering, no automatic apply. A pure
function of the Plan IR document it is handed — see ARCHITECTURAL
BOUNDARY below for the enforced import list, and Determinism below.

ARCHITECTURAL BOUNDARY
---------------------------
ALLOWED to import: plan_ir (its SCHEMA_VERSION constant only — for the
same reason plan_validator.py imports it: verifying the input speaks
the schema version this renderer was built against, not re-deriving
any Plan IR construction logic), this package's own types, and the
standard library.

FORBIDDEN to import: inventory_build, net_facts, desired_state,
planner, capabilities, hysteria2_config, providers.*, run_command, or
anything that calls subprocess/touches the filesystem/network. See
tests/test_nginx_renderer.py's own architecture-boundary test for the
enforced list.

DETERMINISM
---------------
The same Plan IR input must produce byte-identical output. No UUIDs,
no timestamps, no dict-iteration-order assumptions: services are
processed in `sorted(service_id)` order, SNI map lines sorted by
hostname with any `default` line always last (matching the legacy
convention), upstream blocks sorted by their identifier.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field as dc_field
from typing import Any, Optional

import plan_ir

PROVIDER = "nginx"
SUPPORTED_TOPOLOGY = "SHARED_TCP_SNI"


# ─────────────────────────────────────────────────────────────────────
# Result types — deliberately mirror plan_validator.py's Diagnostic /
# PlanValidationResult field names and helper methods; independently
# defined here rather than imported (see module docstring).
# ─────────────────────────────────────────────────────────────────────

@dataclass
class Diagnostic:
    code: str
    severity: str  # "error" | "warning" — this renderer only ever emits "error"
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
class Artifact:
    artifact_id: str
    target_kind: str
    target_name: str
    content: str

    def as_dict(self) -> dict:
        return {
            "artifact_id": self.artifact_id, "target_kind": self.target_kind,
            "target_name": self.target_name, "content": self.content,
        }


@dataclass
class RenderResult:
    valid: bool
    provider: str
    artifacts: list = dc_field(default_factory=list)
    diagnostics: list = dc_field(default_factory=list)

    def as_dict(self) -> dict:
        return {
            "valid": self.valid, "provider": self.provider,
            "artifacts": [a.as_dict() for a in self.artifacts],
            "diagnostics": [d.as_dict() for d in self.diagnostics],
        }

    def errors(self) -> list:
        return [d for d in self.diagnostics if d.severity == "error"]

    def warnings(self) -> list:
        return [d for d in self.diagnostics if d.severity == "warning"]


def _err(diags: list, code: str, resource_id: Optional[str], field_: Optional[str], message: str) -> None:
    diags.append(Diagnostic(code, "error", resource_id, field_, message))


def _is_mapping(x: Any) -> bool:
    return isinstance(x, dict)


def _nginx_ident(raw: str) -> str:
    """A deterministic, syntactically-safe nginx identifier (used for
    both `upstream` names and the SNI-dispatch map's variable name) —
    mechanical character substitution only, never a semantic decision.
    nginx identifiers are letters/digits/underscores; anything else in
    `raw` (group_id's own `+` joiner, a service_id's `-`, etc.) becomes
    `_`, with a leading `_` added if the result wouldn't otherwise
    start with a letter/underscore."""
    ident = re.sub(r"[^A-Za-z0-9_]", "_", raw)
    if not ident or not (ident[0].isalpha() or ident[0] == "_"):
        ident = "_" + ident
    return ident


# ─────────────────────────────────────────────────────────────────────
# Top-level entry point
# ─────────────────────────────────────────────────────────────────────

def render(plan: Any) -> RenderResult:
    diags: list = []

    if not _is_mapping(plan):
        _err(diags, "malformed_plan", None, "$", "plan must be a mapping")
        return RenderResult(False, PROVIDER, [], diags)

    schema_version = plan.get("schema_version")
    if schema_version != plan_ir.SCHEMA_VERSION:
        _err(diags, "unsupported_schema_version", None, "$.schema_version",
             f"expected {plan_ir.SCHEMA_VERSION!r}, got {schema_version!r}")
        return RenderResult(False, PROVIDER, [], diags)

    groups = plan.get("groups") or []
    nginx_groups = [g for g in groups if _is_mapping(g) and g.get("mechanism") == "nginx"]

    # Cross-group defensive check only — plan_validator.py's own
    # resource-identity rules are the real, authoritative source of
    # "two groups never claim the same listener"; this is a shallow
    # safety net against being handed a plan directly (see
    # ARCHITECTURAL BOUNDARY), never a re-implementation of that rule.
    # Two DIFFERENT nginx groups sharing one (transport, ip, port)
    # would require two stream{server{}} blocks binding the same
    # address, which is not valid nginx.
    claimed_by: dict = {}
    for g in nginx_groups:
        gid = g.get("group_id")
        for svc in g.get("services") or []:
            listener = svc.get("listener") or {}
            key = (listener.get("transport"), listener.get("ip"), listener.get("port"))
            prior = claimed_by.get(key)
            if prior is not None and prior != gid:
                _err(diags, "conflicting_listener_across_groups", gid, "$.listener",
                     f"listener {key!r} is claimed by both group {prior!r} and {gid!r}")
            else:
                claimed_by[key] = gid

    artifacts = []
    for g in sorted(nginx_groups, key=lambda g: g.get("group_id") or ""):
        artifact, group_diags = _render_group(g)
        diags.extend(group_diags)
        if artifact is not None:
            artifacts.append(artifact)

    valid = not any(d.severity == "error" for d in diags)
    return RenderResult(valid, PROVIDER, artifacts, diags)


# ─────────────────────────────────────────────────────────────────────
# Per-group rendering
# ─────────────────────────────────────────────────────────────────────

def _render_group(group: dict):
    diags: list = []
    gid = group.get("group_id")
    topology = group.get("topology")

    if topology != SUPPORTED_TOPOLOGY:
        _err(diags, "unsupported_topology", gid, "$.topology",
             f"nginx renderer only supports {SUPPORTED_TOPOLOGY!r} groups, got {topology!r}")
        return None, diags

    services = group.get("services") or []
    if len(services) < 2:
        _err(diags, "malformed_group", gid, "$.services",
             f"{SUPPORTED_TOPOLOGY} group must have at least 2 services, got {len(services)}")
        return None, diags

    listener = None
    entries = []          # (ident, address, port)
    map_lines = []         # (hostname_or_None, ident)
    seen_idents: dict = {}
    proxy_protocol_needed = False

    for svc in sorted(services, key=lambda s: s.get("service_id") or ""):
        sid = svc.get("service_id")

        svc_listener = svc.get("listener") or {}
        if listener is None:
            listener = svc_listener
        elif svc_listener != listener:
            _err(diags, "inconsistent_listener", sid, "$.listener",
                 f"service {sid!r} declares a different listener than the rest of group {gid!r}")
            continue

        if not svc_listener.get("ip") or not isinstance(svc_listener.get("port"), int):
            _err(diags, "malformed_listener", sid, "$.listener",
                 f"service {sid!r} has an incomplete listener (ip/port)")
            continue

        if svc_listener.get("transport") != "tcp":
            _err(diags, "unsupported_transport", sid, "$.listener.transport",
                 f"nginx {SUPPORTED_TOPOLOGY} renderer requires transport 'tcp', got "
                 f"{svc_listener.get('transport')!r}")
            continue

        backend = svc.get("backend")
        if backend is None:
            _err(diags, "missing_backend", sid, "$.backend",
                 f"service {sid!r} has no backend endpoint for nginx to proxy_pass to")
            continue
        if not _is_mapping(backend) or backend.get("kind") != "loopback_tcp":
            _err(diags, "unsupported_backend_kind", sid, "$.backend.kind",
                 f"nginx {SUPPORTED_TOPOLOGY} renderer requires backend.kind 'loopback_tcp', got "
                 f"{(backend or {}).get('kind')!r}")
            continue
        address, port = backend.get("address"), backend.get("port")
        if not address or not isinstance(port, int):
            _err(diags, "malformed_backend", sid, "$.backend",
                 f"service {sid!r} backend is missing address/port")
            continue

        ident = _nginx_ident(sid)
        prior_sid = seen_idents.get(ident)
        if prior_sid is not None and prior_sid != sid:
            _err(diags, "duplicate_backend_identifier", sid, "$.service_id",
                 f"service {sid!r} and {prior_sid!r} both sanitize to the same nginx "
                 f"identifier {ident!r}")
            continue
        seen_idents[ident] = sid
        entries.append((ident, address, port))

        sni_values = ((svc.get("routing") or {}).get("match") or {}).get("sni")
        if sni_values:
            for hostname in sni_values:
                map_lines.append((hostname, ident))
        else:
            map_lines.append((None, ident))

        if (svc.get("proxy_protocol")) == "required":
            proxy_protocol_needed = True

    if diags:
        return None, diags

    default_idents = [ident for hostname, ident in map_lines if hostname is None]
    if len(default_idents) > 1:
        _err(diags, "ambiguous_default_sni_backend", gid, "$.services[].routing.match.sni",
             f"group {gid!r} has {len(default_idents)} services with no SNI value — at most "
             f"one is renderable as the map's default")
        return None, diags

    claimed_hostnames: dict = {}
    for hostname, ident in map_lines:
        if hostname is None:
            continue
        prior = claimed_hostnames.get(hostname)
        if prior is not None and prior != ident:
            _err(diags, "duplicate_sni_value", gid, "$.services[].routing.match.sni",
                 f"SNI value {hostname!r} is claimed by more than one backend in group {gid!r}")
        else:
            claimed_hostnames[hostname] = ident
    if diags:
        return None, diags

    content = _render_stream_block(gid, listener, entries, map_lines, proxy_protocol_needed)
    artifact = Artifact(
        artifact_id=f"nginx:{gid}",
        target_kind="nginx_stream_server_block",
        target_name=gid,
        content=content,
    )
    return artifact, diags


# ─────────────────────────────────────────────────────────────────────
# nginx text generation — pure string assembly, no I/O
# ─────────────────────────────────────────────────────────────────────

def _render_stream_block(group_id: str, listener: dict, entries: list, map_lines: list,
                          proxy_protocol_needed: bool) -> str:
    var_name = f"backend_{_nginx_ident(group_id)}"

    hostname_lines = sorted((h, i) for h, i in map_lines if h is not None)
    default_idents = sorted(i for h, i in map_lines if h is None)

    lines = ["stream {"]
    lines.append(f"    map $ssl_preread_server_name ${var_name} {{")
    for hostname, ident in hostname_lines:
        lines.append(f"        {hostname} {ident};")
    for ident in default_idents:
        lines.append(f"        default {ident};")
    lines.append("    }")

    for ident, address, port in sorted(entries, key=lambda e: e[0]):
        lines.append(f"    upstream {ident} {{ server {address}:{port}; }}")

    lines.append("")
    lines.append("    server {")
    lines.append(f"        listen {listener['ip']}:{listener['port']};")
    lines.append("        ssl_preread on;")
    lines.append(f"        proxy_pass ${var_name};")
    if proxy_protocol_needed:
        lines.append("        proxy_protocol on;")
    lines.append("    }")
    lines.append("}")
    return "\n".join(lines) + "\n"
