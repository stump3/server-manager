#!/usr/bin/env python3
"""
poc/network-inspect/net_facts.py
==================================

EXPERIMENTAL / RESEARCH POC — public IPv4 counting (schema poc-2).
Extracted from inventory_build.py; see README.md "Architecture".
"""

from __future__ import annotations

import ipaddress
from typing import Optional


def _is_globally_routable_ipv4(addr: Optional[str]) -> Optional[bool]:
    """Stricter than the existing _is_public_ip() used for per-listener
    public_exposure classification. `ipaddress.IPv4Address.is_private`
    (used by _is_public_ip) does NOT cover RFC 6598 Carrier-Grade NAT
    shared address space (100.64.0.0/10) — verified directly against
    Python's own ipaddress module (100.64.0.1: is_private=False,
    is_global=False). A host whose only "public-looking" interface
    address is actually CGNAT space is NOT reachable from the public
    internet on that address, so counting it as a public IPv4 would be
    exactly the false-precision the research document and this task
    both warn against. `ipaddress`'s own `is_global` property is used
    instead, since it is the stdlib's own maintained answer to "is
    this IANA-globally-routable" and already correctly excludes
    loopback, link-local, RFC1918, CGNAT, and the various
    documentation/benchmarking ranges (verified: 198.18.0.1 and
    203.0.113.5 both come back is_private=True in this Python version,
    so those are already excluded by the pre-existing helper too —
    the CGNAT range was the one confirmed gap).

    Returns None (not True/False) if `addr` doesn't parse as an IPv4
    address at all — an unparseable address is an unresolved fact, not
    a confirmed non-public one.
    """
    if not addr:
        return None
    try:
        ip_obj = ipaddress.ip_address(addr)
    except ValueError:
        return None
    if not isinstance(ip_obj, ipaddress.IPv4Address):
        return None
    return bool(ip_obj.is_global)


def public_ipv4_summary(interfaces_block: dict) -> dict:
    if not interfaces_block.get("available"):
        return {
            "status": "unresolved",
            "unresolved_reason": interfaces_block.get("reason") or "interfaces_unavailable",
            "count": None,
            "addresses": [],
            "routability_verified": False,
        }

    addresses = []
    for iface in interfaces_block.get("interfaces", []):
        for a in iface.get("addresses", []):
            if a.get("family") != "inet":
                continue
            addr = a.get("address")
            is_global = _is_globally_routable_ipv4(addr)
            if is_global:
                addresses.append({
                    "interface": iface.get("name"),
                    "address": addr,
                    "prefixlen": a.get("prefixlen"),
                })

    return {
        "status": "available",
        "unresolved_reason": None,
        "count": len(addresses),
        "addresses": addresses,
        # This counts addresses the ipaddress stdlib module classifies
        # as globally-routable-per-IANA-registry. It does NOT verify
        # actual internet reachability (no outbound probe is made by
        # this read-only PoC) — a host could still be behind an
        # upstream NAT/firewall that this offline check cannot see.
        # Recorded explicitly so a consumer never mistakes this for a
        # stronger guarantee than it is.
        "routability_verified": False,
    }
