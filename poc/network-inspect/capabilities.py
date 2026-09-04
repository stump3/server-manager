#!/usr/bin/env python3
"""
poc/network-inspect/capabilities.py
=====================================

EXPERIMENTAL / RESEARCH POC — see poc/network-inspect/README.md
"Architecture" section for the full layering rationale.

THE FACT vs CAPABILITY BOUNDARY
--------------------------------
`inventory_build.py` (plus net_facts.py, hysteria2_config.py,
providers/*.py) answers "what did I observe on this host" — e.g.
"nginx -V's configure arguments contain --with-stream". This module
answers a DIFFERENT question: "what does that observation, combined
with what's generally known about this software (research-verified,
not re-derived here), MEAN for a named capability" — e.g.
"nginx.udp.quic_sni_routing = unsupported, because no QUIC/SNI
inspection module exists for stream-UDP in nginx at all, regardless
of what was compiled in on this particular host."

This module explicitly does NOT:
  - choose a topology ("therefore use caddy-l4")
  - recommend installing anything
  - score or rank providers against each other
  - accept a Desired State or produce a Plan
That is Planner-layer work (see README.md "Next step" / this
project's "Shared UDP & TCP/UDP Topology Planner" research document
§18-§21) and is explicitly out of scope here, per this round's task
brief §19/§20.

MODEL
-----
Each provider's Capability Registry entry has:
  - provider, provider_version   (identity)
  - present                      ("available" | "absent" | "unresolved" —
                                   note this reuses Inventory's own
                                   three-state vocabulary for whether
                                   the SOFTWARE ITSELF was found; NOT
                                   the four-state capability vocabulary
                                   below, since "is nginx installed" is
                                   a simpler question than "can nginx
                                   route QUIC")
  - capabilities: { "<dimension>": {status, confidence, evidence, module,
                     module_version} }

capability status is one of exactly four values, per this round's task
brief §16, never conflated:
  - "available"   capability confirmed present (host-verified or, for
                   providers Inventory can't probe, research-verified)
  - "unsupported" capability confirmed ABSENT — the software, even if
                   installed, does not have this capability (a
                   protocol/architecture fact, not a host-state fact)
  - "absent"      the PROVIDER itself is not installed on this host,
                   so the capability question doesn't apply here
  - "unresolved"  could not be determined — either the host-level
                   probe that would confirm/deny it failed, or (for
                   providers Inventory never probes, i.e. HAProxy's
                   compiled-feature list, or Envoy which has no
                   discovery adapter at all) no fact-gathering exists
                   to confirm it either way

confidence, reused verbatim from the "Shared UDP & TCP/UDP Topology
Planner" research document's own §20 vocabulary (kept for continuity
rather than inventing a new scheme):
  - "verified_by_probe"        this SPECIFIC host's actual installed
                                software was checked (nginx -V, caddy
                                list-modules) and the fact reflects
                                that host, not a general claim
  - "verified_by_docs"         a general, research-verified fact about
                                the software (upstream docs, or a real
                                observed working configuration cited in
                                the research document) — true of the
                                software in general, not re-confirmed
                                against this specific host's binary
  - "inferred_by_composition"  reasoned by combining several verified
                                facts, not directly observed or
                                documented as a single fact (reserved;
                                not currently used by any row below —
                                nothing in this round's provider matrix
                                required this level of inference)
  - "unverified"                genuinely not known either way

STATIC KNOWLEDGE TABLE
-----------------------
`_STATIC_CAPABILITY_FACTS` below is PROJECT-LEVEL knowledge — "what
does this software generally support" — checked once against
docs/MULTI_PROTOCOL_L4_INGRESS.md,
docs/MULTI_PROTOCOL_L4_INGRESS_REVIEW.md, and the "Shared UDP &
TCP/UDP Topology Planner" research document (delivered in an earlier
session), not re-derived from Inventory at call time. It is
deliberately NOT re-verified against live upstream sources on every
run — that would make this read-only PoC's output depend on external
network reachability, which contradicts the project's own
"idempotent, no side effects, no dependency on remote services"
posture (see inventory_build.py's own module docstring). If upstream
behavior changes, this table needs a manual update — flagged as an
open question in README.md "Architecture risks".

HOST-LEVEL OVERRIDES
----------------------
For nginx and Caddy specifically, Inventory DOES carry host-level
compiled/module facts (`detected_ingress.nginx.stream_capabilities`,
`detected_ingress.caddy.layer4_capabilities`) — `_nginx_entry()` and
`_caddy_entry()` below use those to CORRECT the static table's general
claim for THIS SPECIFIC host: e.g. static facts say nginx generally
supports `tcp.sni_inspection` when built with
`--with-stream_ssl_preread_module`, but if this host's nginx was NOT
compiled that way, the row becomes `unsupported` (confidence
`verified_by_probe`, evidence citing the actual `nginx -V` output) —
overriding, not merely footnoting, the general claim. HAProxy and
Envoy get NO such override in this round — Inventory has never probed
HAProxy's own `-vv` feature-flag output (poc-2 only added binary/
version/running detection for HAProxy, not compiled-feature parsing),
and has no discovery adapter for Envoy at all (deliberate — the
research document treats Envoy as reference-only, never a deployment
candidate for this project). Both are flagged explicitly in each
entry's own top-level note rather than silently presented as
host-verified when they are not.
"""

from __future__ import annotations

import time
from typing import Optional

SCHEMA_VERSION = "capabilities-1"

# ─────────────────────────────────────────────────────────────────────
# Capability dimension vocabulary — exactly the 17 dimensions this
# round's task brief §17 asks for (6 tcp.*, 11 udp.*), used uniformly
# across every provider row so the schema shape never depends on which
# provider you're looking at.
# ─────────────────────────────────────────────────────────────────────

CAPABILITY_DIMENSIONS = (
    "tcp.listen",
    "tcp.proxy",
    "tcp.sni_inspection",
    "tcp.tls_passthrough",
    "tcp.tls_termination",
    "tcp.n_way_sni_routing",
    "udp.listen",
    "udp.proxy",
    "udp.reuseport",
    "udp.session_affinity",
    "udp.protocol_inspection",
    "udp.quic_inspection",
    "udp.quic_sni_routing",
    "udp.quic_sni_termination",
    "udp.quic_migration_safe",
    "udp.multi_backend_same_port",
    "udp.obfuscation_transparent",
)


def _row(status: str, confidence: Optional[str], evidence: str, module: Optional[str] = None) -> dict:
    return {
        "status": status,
        "confidence": confidence,
        "evidence": evidence,
        "module": module,
        # Inventory does not currently capture per-module VERSION
        # granularity (only the top-level provider binary version) —
        # see module docstring "HOST-LEVEL OVERRIDES". Always None in
        # this round; the field exists so the dimension is structurally
        # present rather than needing a schema change later.
        "module_version": None,
    }


# ─────────────────────────────────────────────────────────────────────
# Static, research-verified provider capability facts.
# ─────────────────────────────────────────────────────────────────────

_UNRESOLVED_NO_RESEARCH = ("unresolved", "unverified", "not addressed by this project's research to date — not guessed")

_STATIC_CAPABILITY_FACTS: dict[str, dict[str, tuple]] = {
    "nginx": {
        "tcp.listen": ("available", "verified_by_docs", "ngx_stream_core_module — listen ... [udp]"),
        "tcp.proxy": ("available", "verified_by_docs", "ngx_stream_proxy_module"),
        "tcp.sni_inspection": ("available", "verified_by_docs", "ssl_preread (ngx_stream_ssl_preread_module) — requires --with-stream_ssl_preread_module compiled in"),
        "tcp.tls_passthrough": ("available", "verified_by_docs", "ssl_preread + proxy_pass, TCP-only, already used in this project's own MODE=F"),
        "tcp.tls_termination": ("available", "verified_by_docs", "http{} ssl or stream{} ssl termination"),
        "tcp.n_way_sni_routing": ("available", "verified_by_docs", "map $ssl_preread_server_name — N-way, already used in this project's MODE=F"),
        "udp.listen": ("available", "verified_by_docs", "listen ... udp [reuseport], ngx_stream_core_module 1.9.13+"),
        "udp.proxy": ("available", "verified_by_docs", "ngx_stream_proxy_module UDP support, 1.9.13+"),
        "udp.reuseport": ("available", "verified_by_docs", "listen ... udp reuseport — kernel SO_REUSEPORT scale-out, explicitly NOT protocol-aware (research doc §4)"),
        "udp.session_affinity": ("available", "verified_by_docs", "hash $remote_addr[:$remote_port] consistent — 4-tuple only, NOT migration-safe (research doc §15)"),
        "udp.protocol_inspection": ("unsupported", "verified_by_docs", "no protocol-sniffing module for UDP exists in nginx (research doc §8)"),
        "udp.quic_inspection": ("unsupported", "verified_by_docs", "no QUIC/SNI inspection module exists for stream-UDP in nginx — no udp_preread/quic_preread equivalent to ssl_preread (research doc §8)"),
        "udp.quic_sni_routing": ("unsupported", "verified_by_docs", "requires udp.quic_inspection, which is unsupported (research doc §8)"),
        "udp.quic_sni_termination": ("unsupported", "verified_by_docs", "no HTTP/3/QUIC termination module in stock nginx stream"),
        "udp.quic_migration_safe": ("unsupported", "verified_by_docs", "no CID-based session affinity in any surveyed provider, nginx included (research doc §15)"),
        "udp.multi_backend_same_port": ("unsupported", "verified_by_docs", "requires udp.quic_sni_routing (or an equivalent), which is unsupported"),
        "udp.obfuscation_transparent": ("unsupported", "verified_by_docs", "no provider surveyed can route Salamander/Gecko-obfuscated traffic (research doc §6)"),
    },
    "caddy_l4": {
        "tcp.listen": ("available", "verified_by_docs", "caddy-l4 docs/servers.md — tcp/ server addresses"),
        "tcp.proxy": ("available", "verified_by_docs", "layer4.handlers.proxy"),
        "tcp.sni_inspection": ("available", "verified_by_docs", "layer4.matchers.tls (SNI handshake match)"),
        "tcp.tls_passthrough": ("available", "verified_by_docs", "layer4.matchers.tls + proxy handler without cert configured — passthrough, real observed config (caddy-l4 issue #118)"),
        "tcp.tls_termination": ("available", "verified_by_docs", "layer4.handlers.tls"),
        "tcp.n_way_sni_routing": ("available", "verified_by_docs", "multiple routes matched by distinct SNI values on one listener — same config shape as issue #118's UDP example, applies to TCP routes too"),
        "udp.listen": ("available", "verified_by_docs", "caddy-l4 docs/servers.md — udp/ server addresses"),
        "udp.proxy": ("available", "verified_by_docs", "layer4.handlers.proxy with udp/... upstream dial"),
        "udp.reuseport": _UNRESOLVED_NO_RESEARCH,
        "udp.session_affinity": ("available", "verified_by_docs", "net.PacketConn session gated by matching_timeout — 4-tuple scoped, NOT migration-safe (research doc §15)"),
        "udp.protocol_inspection": ("available", "verified_by_docs", "layer4 protocol matchers generally (tls, quic, ssh, socks4/5, rdp, dns, regexp, ...)"),
        "udp.quic_inspection": ("available", "verified_by_docs", "layer4.matchers.quic — RFC9001 §5.2 public Initial Salt decrypt (research doc §5/§7)"),
        "udp.quic_sni_routing": ("available", "verified_by_docs", "layer4.matchers.quic + tls SNI handshake matcher, PASSTHROUGH (no cert configured) — real observed working config, caddy-l4 issue #118; upstream self-describes as still in development"),
        "udp.quic_sni_termination": ("available", "verified_by_docs", "layer4.handlers.tls on a udp/quic route — different route shape than the passthrough row above"),
        "udp.quic_migration_safe": ("unsupported", "verified_by_docs", "no QUIC-LB CID-based re-association found in the caddy-l4 codebase or docs (research doc §15)"),
        "udp.multi_backend_same_port": ("available", "verified_by_docs", "directly demonstrated in issue #118 (turn/vpn/dot routed to distinct UDP upstreams on one udp/:443 listener)"),
        "udp.obfuscation_transparent": ("unsupported", "verified_by_docs", "no obfuscation-aware QUIC matcher exists (research doc §6)"),
    },
    "haproxy": {
        "tcp.listen": ("available", "verified_by_docs", "bind directive, mature OSS feature"),
        "tcp.proxy": ("available", "verified_by_docs", "mode tcp + use_backend, mature OSS feature"),
        "tcp.sni_inspection": ("available", "verified_by_docs", "req.ssl_sni fetch — real HAProxy OSS feature; flagged by research doc §16 as not deeply investigated this round, but a well-documented, mature capability"),
        "tcp.tls_passthrough": ("available", "verified_by_docs", "req.ssl_sni + use_backend ACL routing, same mechanism as tcp.sni_inspection above"),
        "tcp.tls_termination": ("available", "verified_by_docs", "bind ... ssl crt ..., mature OSS feature"),
        "tcp.n_way_sni_routing": ("available", "verified_by_docs", "multiple use_backend ACL rules keyed on req.ssl_sni — arbitrary N-way, same underlying mechanism"),
        "udp.listen": _UNRESOLVED_NO_RESEARCH,
        "udp.proxy": ("unsupported", "verified_by_docs", "no general-purpose UDP passthrough reverse-proxy primitive found; `dgram-bind`/log-forward is scoped specifically to syslog message forwarding, not a general UDP proxy (research doc §9) — this is the exact 'proxy exists therefore multiplexing exists' trap the research explicitly warns against, and this row deliberately does NOT fall into it"),
        "udp.reuseport": _UNRESOLVED_NO_RESEARCH,
        "udp.session_affinity": _UNRESOLVED_NO_RESEARCH,
        "udp.protocol_inspection": _UNRESOLVED_NO_RESEARCH,
        "udp.quic_inspection": ("unsupported", "verified_by_docs", "HAProxy's QUIC support requires HTTP/3 TERMINATION (bind quic4@:443 ssl crt ... alpn h3) — no passthrough inspection found (research doc §9)"),
        "udp.quic_sni_routing": ("unsupported", "verified_by_docs", "no passthrough SNI routing for QUIC found; QUIC path is termination-only (research doc §9)"),
        "udp.quic_sni_termination": ("available", "verified_by_docs", "bind quic4@:443 ssl crt ... alpn h3 — real, documented HTTP/3-terminating configuration"),
        "udp.quic_migration_safe": ("unsupported", "verified_by_docs", "no CID-based affinity found (research doc §15)"),
        "udp.multi_backend_same_port": ("unsupported", "verified_by_docs", "requires passthrough udp.quic_sni_routing, which is unsupported"),
        "udp.obfuscation_transparent": ("unsupported", "verified_by_docs", "no provider surveyed supports this (research doc §6)"),
    },
    "envoy": {
        "tcp.listen": ("available", "verified_by_docs", "listener API, mature"),
        "tcp.proxy": ("available", "verified_by_docs", "tcp_proxy filter"),
        "tcp.sni_inspection": ("available", "verified_by_docs", "TLS Inspector listener filter + filter_chain_match server_names — mature, real"),
        "tcp.tls_passthrough": ("available", "verified_by_docs", "SNI dynamic forward proxy filter — real, but upstream self-flagged 'alpha and not production ready' (research doc §10)"),
        "tcp.tls_termination": ("available", "verified_by_docs", "downstream TLS transport socket + filter_chain_match, mature"),
        "tcp.n_way_sni_routing": ("available", "verified_by_docs", "multiple filter_chain_match server_names entries — arbitrary N-way, mature"),
        "udp.listen": ("available", "verified_by_docs", "udp_proxy listener filter, and quic_options on a listener"),
        "udp.proxy": ("available", "verified_by_docs", "udp_proxy listener filter — generic, protocol-agnostic session hashing (research doc §10)"),
        "udp.reuseport": _UNRESOLVED_NO_RESEARCH,
        "udp.session_affinity": ("available", "verified_by_docs", "udp_proxy session table, 4-tuple-scoped by default (research doc §15)"),
        "udp.protocol_inspection": _UNRESOLVED_NO_RESEARCH,
        "udp.quic_inspection": ("available", "verified_by_docs", "quic_options + filter_chain_match server_names — but only in service of TERMINATION, see udp.quic_sni_routing below (research doc §10)"),
        "udp.quic_sni_routing": ("unsupported", "verified_by_docs", "Envoy's QUIC listener requires HTTP Connection Manager / termination — GitHub issue #23857 confirms no generic passthrough QUIC+SNI upstream selection exists (research doc §10)"),
        "udp.quic_sni_termination": ("available", "verified_by_docs", "QuicDownstreamTransport + filter_chain_match server_names — real, requires cert/key, HTTP/3 termination"),
        "udp.quic_migration_safe": ("unsupported", "verified_by_docs", "no CID-based affinity found (research doc §15)"),
        "udp.multi_backend_same_port": ("unsupported", "verified_by_docs", "requires passthrough udp.quic_sni_routing, which is unsupported"),
        "udp.obfuscation_transparent": ("unsupported", "verified_by_docs", "not supported by any surveyed provider (research doc §6)"),
    },
}


def _static_provider_capabilities(provider_key: str) -> dict:
    facts = _STATIC_CAPABILITY_FACTS[provider_key]
    out = {}
    for dim in CAPABILITY_DIMENSIONS:
        status, confidence, evidence = facts[dim]
        module = None
        if provider_key == "nginx" and dim in (
            "tcp.sni_inspection", "tcp.tls_passthrough", "tcp.proxy", "tcp.listen",
            "tcp.n_way_sni_routing", "udp.listen", "udp.proxy", "udp.reuseport",
            "udp.session_affinity",
        ):
            module = "stream_ssl_preread" if "sni_inspection" in dim or "passthrough" in dim else "stream"
        elif provider_key == "caddy_l4" and dim.startswith(("udp.quic", "udp.protocol_inspection", "udp.multi_backend")):
            module = "layer4.matchers.quic" if "quic" in dim and "termination" not in dim else "layer4"
        out[dim] = _row(status, confidence, evidence, module=module)
    return out


# ─────────────────────────────────────────────────────────────────────
# Host-level overrides — the piece that makes this a REGISTRY, not
# just a static lookup table. Combines "what this software generally
# supports" (above) with "what THIS HOST's actual installed instance
# was observed to have" (from Inventory), always preferring the more
# specific, host-verified fact when Inventory actually checked it.
# ─────────────────────────────────────────────────────────────────────

_NGINX_STREAM_DEPENDENT_DIMS = (
    "tcp.listen", "tcp.proxy", "tcp.tls_passthrough", "tcp.n_way_sni_routing",
    "udp.listen", "udp.proxy", "udp.reuseport", "udp.session_affinity",
)
_NGINX_SSL_PREREAD_DEPENDENT_DIMS = ("tcp.sni_inspection",)


def _nginx_entry(detected_nginx: dict) -> dict:
    capabilities = _static_provider_capabilities("nginx")

    if not detected_nginx.get("present"):
        for dim in CAPABILITY_DIMENSIONS:
            capabilities[dim] = _row("absent", "verified_by_probe", "nginx binary not found on this host (detected_ingress.nginx.present = false)")
        return {"provider": "nginx", "provider_version": None, "present": "absent", "capabilities": capabilities}

    stream_caps = detected_nginx.get("stream_capabilities") or {}
    probe_status = stream_caps.get("status")

    if probe_status == "unresolved":
        reason = stream_caps.get("unresolved_reason")
        for dim in _NGINX_STREAM_DEPENDENT_DIMS + _NGINX_SSL_PREREAD_DEPENDENT_DIMS:
            capabilities[dim] = _row(
                "unresolved", "unverified",
                f"nginx present, but the live `nginx -V` compiled-module probe itself was unresolved "
                f"(unresolved_reason={reason!r}) — cannot confirm or deny for THIS host without guessing",
            )
        return {
            "provider": "nginx",
            "provider_version": detected_nginx.get("version"),
            "present": "available",
            "capabilities": capabilities,
        }

    if probe_status == "available":
        has_stream = stream_caps.get("compiled_with_stream")
        has_ssl_preread = stream_caps.get("compiled_with_stream_ssl_preread")
        evidence_base = f"live nginx -V probe on this host: configure_arguments={stream_caps.get('configure_arguments_raw')!r}"

        if has_stream is False:
            for dim in _NGINX_STREAM_DEPENDENT_DIMS + _NGINX_SSL_PREREAD_DEPENDENT_DIMS:
                capabilities[dim] = _row("unsupported", "verified_by_probe", f"this host's nginx was NOT compiled with --with-stream — {evidence_base}")
        else:
            for dim in _NGINX_STREAM_DEPENDENT_DIMS:
                capabilities[dim] = _row("available", "verified_by_probe", f"this host's nginx was compiled with --with-stream — {evidence_base}")
            if has_ssl_preread is False:
                for dim in _NGINX_SSL_PREREAD_DEPENDENT_DIMS:
                    capabilities[dim] = _row("unsupported", "verified_by_probe", f"this host's nginx was compiled with --with-stream but NOT --with-stream_ssl_preread_module — {evidence_base}")
            else:
                for dim in _NGINX_SSL_PREREAD_DEPENDENT_DIMS:
                    capabilities[dim] = _row("available", "verified_by_probe", f"this host's nginx was compiled with --with-stream_ssl_preread_module — {evidence_base}")

    return {
        "provider": "nginx",
        "provider_version": detected_nginx.get("version"),
        "present": "available",
        "capabilities": capabilities,
    }


_CADDY_LAYER4_DEPENDENT_DIMS = (
    "udp.listen", "udp.proxy", "udp.protocol_inspection", "udp.multi_backend_same_port",
)
_CADDY_QUIC_MATCHER_DEPENDENT_DIMS = (
    "udp.quic_inspection", "udp.quic_sni_routing",
)


def _caddy_entry(detected_caddy: dict) -> dict:
    capabilities = _static_provider_capabilities("caddy_l4")

    if not detected_caddy.get("present"):
        for dim in CAPABILITY_DIMENSIONS:
            capabilities[dim] = _row("absent", "verified_by_probe", "caddy binary not found on this host (detected_ingress.caddy.present = false)")
        return {"provider": "caddy_l4", "provider_version": None, "present": "absent", "capabilities": capabilities}

    layer4_caps = detected_caddy.get("layer4_capabilities") or {}
    probe_status = layer4_caps.get("status")

    if probe_status == "unresolved":
        reason = layer4_caps.get("unresolved_reason")
        for dim in CAPABILITY_DIMENSIONS:
            if dim.startswith("udp.") or dim.startswith("tcp."):
                # every capability row in this table depends, directly
                # or transitively, on layer4 being present at all
                capabilities[dim] = _row(
                    "unresolved", "unverified",
                    f"caddy present, but `caddy list-modules --versions` itself was unresolved "
                    f"(unresolved_reason={reason!r}) — cannot confirm or deny for THIS host without guessing",
                )
        return {
            "provider": "caddy_l4",
            "provider_version": detected_caddy.get("version"),
            "present": "available",
            "capabilities": capabilities,
        }

    if probe_status == "available":
        layer4_present = layer4_caps.get("layer4_present")
        evidence_base = f"live `caddy list-modules --versions` probe on this host: raw_module_list={layer4_caps.get('raw_module_list')!r}"

        if not layer4_present:
            # "Caddy installed" != "caddy-l4 available" (critical
            # invariant, this round's task brief §18) — this provider
            # entry is literally named "caddy_l4" (the layer4 app's
            # capabilities specifically, not generic Caddy), and every
            # one of this provider's 17 static evidence strings cites
            # a layer4-specific mechanism (layer4.handlers.proxy,
            # layer4.handlers.tls, caddy-l4 docs/servers.md, etc. — see
            # _STATIC_CAPABILITY_FACTS["caddy_l4"] above). So when the
            # host-level probe confirms layer4 itself is NOT compiled
            # in, ALL 17 dimensions become UNSUPPORTED, not just the
            # udp.* ones — anything less would silently keep reporting
            # e.g. tcp.proxy/tcp.tls_termination as "available" while
            # their own cited evidence (layer4.handlers.proxy /
            # layer4.handlers.tls) is confirmed absent on this exact
            # host, which is precisely the FACT-vs-CAPABILITY
            # inconsistency this Registry exists to prevent.
            for dim in CAPABILITY_DIMENSIONS:
                capabilities[dim] = _row("unsupported", "verified_by_probe", f"this host's Caddy build does not have the layer4 app compiled in — {evidence_base}")
        else:
            for dim in _CADDY_LAYER4_DEPENDENT_DIMS:
                capabilities[dim] = _row("available", "verified_by_probe", f"this host's Caddy build has layer4 compiled in — {evidence_base}")

            quic_matcher_present = layer4_caps.get("layer4_matchers_quic_present")
            if quic_matcher_present:
                for dim in _CADDY_QUIC_MATCHER_DEPENDENT_DIMS:
                    capabilities[dim] = _row("available", "verified_by_probe", f"this host's Caddy build has layer4.matchers.quic compiled in — {evidence_base}", module="layer4.matchers.quic")
            else:
                # NOT "unsupported" — per poc-2's own README caveat
                # (still true, cited here rather than re-litigated):
                # absence of a SEPARATELY-ENUMERATED
                # layer4.matchers.quic line doesn't necessarily prove
                # the matcher isn't functionally available via
                # layer4's own composed matcher list. Propagating
                # "unresolved" here, not resolving the ambiguity by
                # fiat, is itself an instance of this round's
                # "unresolved != unsupported" invariant (task brief
                # §18) — done for a REAL, previously-documented reason,
                # not invented for this task.
                for dim in _CADDY_QUIC_MATCHER_DEPENDENT_DIMS:
                    capabilities[dim] = _row(
                        "unresolved", "unverified",
                        "layer4 is compiled in, but layer4.matchers.quic was not separately "
                        "enumerated in this host's `caddy list-modules --versions` output — "
                        "this does NOT necessarily mean the matcher is unavailable (see poc-2 "
                        "README's own documented limitation on this exact point), so this is "
                        "recorded as unresolved rather than guessed either way — "
                        f"{evidence_base}",
                    )

    return {
        "provider": "caddy_l4",
        "provider_version": detected_caddy.get("version"),
        "present": "available",
        "capabilities": capabilities,
    }


def _haproxy_entry(detected_haproxy: dict) -> dict:
    capabilities = _static_provider_capabilities("haproxy")
    present = detected_haproxy.get("present")

    if not present:
        for dim in CAPABILITY_DIMENSIONS:
            capabilities[dim] = _row("absent", "verified_by_probe", "haproxy binary not found on this host (detected_ingress.haproxy.present = false)")
        return {"provider": "haproxy", "provider_version": None, "present": "absent", "capabilities": capabilities}

    # Inventory has NEVER probed HAProxy's own compiled-feature list
    # (`haproxy -vv`'s "Feature list" line, e.g. `+QUIC`) — poc-2 only
    # added binary/version/running/dataplaneapi_detected for HAProxy,
    # unlike nginx/Caddy which got real compiled-capability parsing.
    # Every capability row below therefore stays at its STATIC,
    # research-only confidence — never silently upgraded to
    # "verified_by_probe" just because the binary itself was found.
    # This gap is intentional to flag, not paper over — see README.md
    # "Architecture risks / open questions".
    return {
        "provider": "haproxy",
        "provider_version": detected_haproxy.get("version"),
        "present": "available",
        "capabilities": capabilities,
        "note": (
            "HAProxy's own compiled-feature list (`haproxy -vv`'s "
            "Feature list line) is not probed by Inventory in this "
            "round — every capability row above reflects general, "
            "research-verified knowledge about HAProxy, NOT a "
            "host-specific compiled-feature check, unlike nginx/caddy_l4."
        ),
    }


def _envoy_entry() -> dict:
    # No discovery adapter exists for Envoy anywhere in this Inventory
    # — deliberate, per the research document treating Envoy as
    # reference-only, never a deployment candidate for this project.
    # "present" is therefore "unresolved", NOT "absent" — this project
    # genuinely does not know whether Envoy is installed on any given
    # host, because it has never looked; claiming "absent" would be
    # exactly the false-precision this whole PoC exists to avoid.
    capabilities = _static_provider_capabilities("envoy")
    return {
        "provider": "envoy",
        "provider_version": None,
        "present": "unresolved",
        "capabilities": capabilities,
        "note": (
            "No discovery adapter exists for Envoy in this Inventory "
            "(deliberate design choice — see research document, Envoy "
            "is treated as reference-only, never a deployment "
            "candidate for this project). `present` is unresolved, not "
            "absent: this project has never checked, so it does not "
            "know. Capability rows below are entirely research-derived "
            "(confidence: verified_by_docs), never host-verified."
        ),
    }


def build_capability_registry(inventory: dict) -> dict:
    """Pure function: Inventory dict in, Capability Registry dict out.
    No subprocess calls, no file I/O — everything this function needs
    was already gathered by build_inventory(). Never mutates the
    Inventory it's given.
    """
    detected = inventory.get("detected_ingress", {})
    return {
        "schema_version": SCHEMA_VERSION,
        "generated_at": int(time.time()),
        "capability_dimensions": list(CAPABILITY_DIMENSIONS),
        "providers": {
            "nginx": _nginx_entry(detected.get("nginx", {})),
            "caddy_l4": _caddy_entry(detected.get("caddy", {})),
            "haproxy": _haproxy_entry(detected.get("haproxy", {})),
            "envoy": _envoy_entry(),
        },
    }
