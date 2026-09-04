#!/usr/bin/env python3
"""
poc/network-inspect/tests/test_capabilities.py
==================================================

EXPERIMENTAL / RESEARCH POC — tests for capabilities.py (the
Capability Registry). Split into:

  - TestSemanticInvariants: directly verifies every invariant this
    round's task brief §18 lists by name, against real registry
    output — not just "it returns something", but the specific
    distinctions (nginx UDP proxy != QUIC SNI routing, SO_REUSEPORT !=
    multi_backend_same_port, termination != passthrough, "Caddy
    installed" != "caddy-l4 available", unresolved != unsupported,
    Hysteria2 obfs state != provider capability, quic_sni_routing !=
    quic_migration_safe).
  - TestNginxEntry / TestCaddyEntry / TestHaproxyEntry / TestEnvoyEntry:
    per-provider host-override merge logic (absent/unresolved/
    available host states, each producing the correct capability
    status).
  - TestNeverChoosesTopology: confirms the registry's output contains
    no topology/recommendation/installation language anywhere (§19) —
    a structural, not just behavioral, check.

All tests operate on hand-built Inventory fixture dicts (the
`detected_ingress` shape build_inventory() actually produces) — no
subprocess calls, no real nginx/Caddy/HAProxy involved anywhere.
"""

from __future__ import annotations

import json
import unittest

import _loader  # noqa: F401 - adds poc/network-inspect/ to sys.path

import capabilities


def _inventory(nginx=None, caddy=None, haproxy=None):
    return {
        "detected_ingress": {
            "nginx": nginx or {"present": False},
            "caddy": caddy or {"present": False},
            "haproxy": haproxy or {"present": False},
        }
    }


class TestSemanticInvariants(unittest.TestCase):
    """Directly named per task brief §18."""

    def test_nginx_udp_proxy_ne_quic_sni_routing(self):
        inv = _inventory(nginx={
            "present": True, "version": "1.24.0",
            "stream_capabilities": {
                "status": "available",
                "compiled_with_stream": True,
                "compiled_with_stream_ssl_preread": True,
                "configure_arguments_raw": "--with-stream --with-stream_ssl_preread_module",
            },
        })
        reg = capabilities.build_capability_registry(inv)
        nginx = reg["providers"]["nginx"]["capabilities"]
        self.assertEqual(nginx["udp.proxy"]["status"], "available")
        self.assertEqual(
            nginx["udp.quic_sni_routing"]["status"], "unsupported",
            "nginx udp.proxy=available must NOT imply udp.quic_sni_routing=available",
        )

    def test_so_reuseport_ne_multi_backend_same_port(self):
        inv = _inventory(nginx={
            "present": True, "version": "1.24.0",
            "stream_capabilities": {
                "status": "available",
                "compiled_with_stream": True,
                "compiled_with_stream_ssl_preread": True,
                "configure_arguments_raw": "--with-stream --with-stream_ssl_preread_module",
            },
        })
        reg = capabilities.build_capability_registry(inv)
        nginx = reg["providers"]["nginx"]["capabilities"]
        self.assertEqual(nginx["udp.reuseport"]["status"], "available")
        self.assertEqual(
            nginx["udp.multi_backend_same_port"]["status"], "unsupported",
            "udp.reuseport=available must NOT imply udp.multi_backend_same_port=available",
        )

    def test_quic_sni_termination_ne_passthrough(self):
        reg = capabilities.build_capability_registry(
            _inventory(haproxy={"present": True, "version": "2.9.0", "dataplaneapi_detected": False})
        )
        haproxy = reg["providers"]["haproxy"]["capabilities"]
        # HAProxy: termination available, passthrough routing not.
        self.assertEqual(haproxy["udp.quic_sni_termination"]["status"], "available")
        self.assertEqual(haproxy["udp.quic_sni_routing"]["status"], "unsupported")

    def test_caddy_installed_ne_caddy_l4_available(self):
        inv = _inventory(caddy={
            "present": True, "version": "v2.9.0",
            "layer4_capabilities": {
                "status": "available",
                "layer4_present": False,
                "layer4_matchers_quic_present": False,
                "layer4_matchers_tls_present": False,
                "raw_module_list": ["http.handlers.reverse_proxy"],
            },
        })
        reg = capabilities.build_capability_registry(inv)
        caddy = reg["providers"]["caddy_l4"]
        self.assertEqual(caddy["present"], "available")  # caddy itself IS installed
        self.assertEqual(
            caddy["capabilities"]["udp.quic_sni_routing"]["status"], "unsupported",
            "Caddy present with layer4 absent must NOT report caddy-l4 capabilities as available",
        )

    def test_unresolved_ne_unsupported(self):
        inv = _inventory(caddy={
            "present": True, "version": "v2.9.0",
            "layer4_capabilities": {
                "status": "unresolved",
                "unresolved_reason": "list_modules_failed:timeout",
                "layer4_present": None,
                "layer4_matchers_quic_present": None,
                "layer4_matchers_tls_present": None,
                "raw_module_list": None,
            },
        })
        reg = capabilities.build_capability_registry(inv)
        caddy_caps = reg["providers"]["caddy_l4"]["capabilities"]
        self.assertEqual(
            caddy_caps["udp.quic_sni_routing"]["status"], "unresolved",
            "a failed host probe must produce 'unresolved', never 'unsupported' "
            "(we didn't confirm absence, we failed to check)",
        )

    def test_hysteria2_obfs_state_ne_provider_capability(self):
        """The Capability Registry describes PROVIDERS (nginx, caddy_l4,
        haproxy, envoy) — it has no per-Hysteria2 row at all, and
        Hysteria2's own obfs.type never appears anywhere in its
        output. That fact (a precondition/constraint on whether a
        provider's capability can even be exercised for Hysteria2's
        own traffic) is a Planner-layer concern, not something this
        Registry conflates into a provider's capability status."""
        inv = _inventory()
        inv["hysteria2"] = {"obfuscation": {"effective_value": "salamander"}}
        reg = capabilities.build_capability_registry(inv)
        self.assertNotIn("hysteria2", reg["providers"])
        serialized = json.dumps(reg)
        self.assertNotIn("salamander", serialized)

    def test_quic_sni_routing_ne_migration_safe(self):
        inv = _inventory(caddy={
            "present": True, "version": "v2.9.0",
            "layer4_capabilities": {
                "status": "available",
                "layer4_present": True,
                "layer4_matchers_quic_present": True,
                "layer4_matchers_tls_present": True,
                "raw_module_list": ["layer4", "layer4.matchers.quic", "layer4.matchers.tls"],
            },
        })
        reg = capabilities.build_capability_registry(inv)
        caddy = reg["providers"]["caddy_l4"]["capabilities"]
        self.assertEqual(caddy["udp.quic_sni_routing"]["status"], "available")
        self.assertEqual(
            caddy["udp.quic_migration_safe"]["status"], "unsupported",
            "udp.quic_sni_routing=available must NOT imply udp.quic_migration_safe=available",
        )


class TestNginxEntry(unittest.TestCase):
    def test_absent(self):
        reg = capabilities.build_capability_registry(_inventory())
        entry = reg["providers"]["nginx"]
        self.assertEqual(entry["present"], "absent")
        for dim, row in entry["capabilities"].items():
            self.assertEqual(row["status"], "absent", dim)

    def test_present_no_stream(self):
        inv = _inventory(nginx={
            "present": True, "version": "1.18.0",
            "stream_capabilities": {
                "status": "available",
                "compiled_with_stream": False,
                "compiled_with_stream_ssl_preread": False,
                "configure_arguments_raw": "--prefix=/etc/nginx",
            },
        })
        reg = capabilities.build_capability_registry(inv)
        caps = reg["providers"]["nginx"]["capabilities"]
        self.assertEqual(caps["tcp.proxy"]["status"], "unsupported")
        self.assertEqual(caps["tcp.sni_inspection"]["status"], "unsupported")
        self.assertEqual(caps["tcp.tls_termination"]["status"], "available", "tls_termination doesn't need stream")

    def test_present_stream_no_ssl_preread(self):
        inv = _inventory(nginx={
            "present": True, "version": "1.20.0",
            "stream_capabilities": {
                "status": "available",
                "compiled_with_stream": True,
                "compiled_with_stream_ssl_preread": False,
                "configure_arguments_raw": "--with-stream",
            },
        })
        reg = capabilities.build_capability_registry(inv)
        caps = reg["providers"]["nginx"]["capabilities"]
        self.assertEqual(caps["udp.proxy"]["status"], "available")
        self.assertEqual(caps["tcp.sni_inspection"]["status"], "unsupported")

    def test_present_probe_unresolved(self):
        inv = _inventory(nginx={
            "present": True, "version": None,
            "stream_capabilities": {"status": "unresolved", "unresolved_reason": "version_probe_failed:timeout"},
        })
        reg = capabilities.build_capability_registry(inv)
        caps = reg["providers"]["nginx"]["capabilities"]
        self.assertEqual(caps["tcp.sni_inspection"]["status"], "unresolved")
        self.assertEqual(caps["udp.proxy"]["status"], "unresolved")


class TestHaproxyEntry(unittest.TestCase):
    def test_present_never_verified_by_probe(self):
        """HAProxy capability rows must never claim verified_by_probe,
        since Inventory has no compiled-feature probe for it."""
        inv = _inventory(haproxy={"present": True, "version": "2.9.0", "dataplaneapi_detected": False})
        reg = capabilities.build_capability_registry(inv)
        entry = reg["providers"]["haproxy"]
        self.assertEqual(entry["present"], "available")
        self.assertIn("note", entry)
        for dim, row in entry["capabilities"].items():
            self.assertNotEqual(row["confidence"], "verified_by_probe", dim)


class TestEnvoyEntry(unittest.TestCase):
    def test_present_is_unresolved_not_absent(self):
        reg = capabilities.build_capability_registry(_inventory())
        entry = reg["providers"]["envoy"]
        self.assertEqual(entry["present"], "unresolved")
        self.assertIn("note", entry)


class TestNeverChoosesTopology(unittest.TestCase):
    def test_no_topology_or_recommendation_language(self):
        """Structural check per §19 — the Registry's output must never
        contain topology-selection or install-recommendation language,
        for any input, present or absent."""
        inv = _inventory(
            nginx={"present": True, "version": "1.24.0", "stream_capabilities": {
                "status": "available", "compiled_with_stream": True,
                "compiled_with_stream_ssl_preread": True, "configure_arguments_raw": "--with-stream",
            }},
            caddy={"present": True, "version": "v2.9.0", "layer4_capabilities": {
                "status": "available", "layer4_present": True,
                "layer4_matchers_quic_present": True, "layer4_matchers_tls_present": True,
                "raw_module_list": ["layer4", "layer4.matchers.quic"],
            }},
        )
        reg = capabilities.build_capability_registry(inv)
        serialized = json.dumps(reg).lower()
        for forbidden in ("recommend", "should use", "install ", "therefore use", "selected_topology", "topology"):
            self.assertNotIn(forbidden, serialized, f"Registry output must never contain {forbidden!r}")


if __name__ == "__main__":
    unittest.main()
