#!/usr/bin/env python3
"""
poc/network-inspect/tests/test_net_facts.py
===============================================

EXPERIMENTAL / RESEARCH POC — tests for net_facts.py, moved out of
the former monolithic test_inventory_build.py during the
network-inspect architecture split (see README.md "Architecture").

Entirely pure-function tests — net_facts.py makes no subprocess call
and no file I/O of its own, so every test here is a plain dict-in/
dict-out call, no mocking needed at all.
"""

from __future__ import annotations

import unittest

import _loader  # noqa: F401 - adds poc/network-inspect/ to sys.path

import net_facts


def _iface(name, addrs):
    return {"name": name, "state": "UP", "flags": [], "addresses": addrs}


def _addr(family, address, prefixlen=24):
    return {"family": family, "address": address, "prefixlen": prefixlen, "scope": "global"}


class TestIsGloballyRoutableIpv4(unittest.TestCase):
    def test_public_address(self):
        self.assertTrue(net_facts._is_globally_routable_ipv4("8.8.8.8"))

    def test_rfc1918(self):
        self.assertFalse(net_facts._is_globally_routable_ipv4("10.0.0.1"))

    def test_loopback(self):
        self.assertFalse(net_facts._is_globally_routable_ipv4("127.0.0.1"))

    def test_link_local(self):
        self.assertFalse(net_facts._is_globally_routable_ipv4("169.254.1.1"))

    def test_cgnat_regression(self):
        """RFC 6598 CGNAT (100.64.0.0/10) is not globally routable, and
        `ipaddress.IPv4Address.is_private` does NOT catch it — this is
        the concrete gap that motivated writing this stricter check
        instead of reusing inventory_build.py's `_is_public_ip()`."""
        self.assertFalse(net_facts._is_globally_routable_ipv4("100.64.0.5"))

    def test_ipv6_returns_none(self):
        self.assertIsNone(net_facts._is_globally_routable_ipv4("2001:db8::1"))

    def test_unparseable_returns_none(self):
        self.assertIsNone(net_facts._is_globally_routable_ipv4("not-an-ip"))

    def test_none_input_returns_none(self):
        self.assertIsNone(net_facts._is_globally_routable_ipv4(None))


class TestPublicIpv4Summary(unittest.TestCase):
    def test_one_public_ipv4(self):
        # 8.8.4.4 (a real, globally-routable Google DNS anycast
        # address) — deliberately NOT 203.0.113.0/24, which is RFC
        # 5737 TEST-NET-3 and is correctly treated as non-global by
        # Python's own ipaddress module (is_private=True for that
        # range), so it would be the wrong fixture to prove "public".
        block = {"available": True, "interfaces": [
            _iface("eth0", [_addr("inet", "8.8.4.4")]),
        ]}
        result = net_facts.public_ipv4_summary(block)
        self.assertEqual(result["status"], "available")
        self.assertEqual(result["count"], 1)

    def test_two_public_ipv4(self):
        block = {"available": True, "interfaces": [
            _iface("eth0", [_addr("inet", "8.8.8.8")]),
            _iface("eth1", [_addr("inet", "1.1.1.1")]),
        ]}
        result = net_facts.public_ipv4_summary(block)
        self.assertEqual(result["count"], 2)

    def test_zero_public_ipv4_only_private(self):
        block = {"available": True, "interfaces": [
            _iface("eth0", [_addr("inet", "10.0.0.5")]),
            _iface("lo", [_addr("inet", "127.0.0.1")]),
        ]}
        result = net_facts.public_ipv4_summary(block)
        self.assertEqual(result["count"], 0)

    def test_mixed_private_and_public(self):
        block = {"available": True, "interfaces": [
            _iface("eth0", [_addr("inet", "8.8.4.4"), _addr("inet", "10.0.0.5")]),
        ]}
        result = net_facts.public_ipv4_summary(block)
        self.assertEqual(result["count"], 1)
        self.assertEqual(result["addresses"][0]["address"], "8.8.4.4")

    def test_ipv6_only_does_not_count(self):
        block = {"available": True, "interfaces": [
            _iface("eth0", [_addr("inet6", "2001:db8::1")]),
        ]}
        result = net_facts.public_ipv4_summary(block)
        self.assertEqual(result["count"], 0)

    def test_docker_bridge_private_excluded(self):
        block = {"available": True, "interfaces": [
            _iface("docker0", [_addr("inet", "172.17.0.1")]),
        ]}
        result = net_facts.public_ipv4_summary(block)
        self.assertEqual(result["count"], 0)

    def test_cgnat_range_not_counted_as_public(self):
        block = {"available": True, "interfaces": [
            _iface("eth0", [_addr("inet", "100.64.0.5")]),
        ]}
        result = net_facts.public_ipv4_summary(block)
        self.assertEqual(
            result["count"], 0,
            "CGNAT (100.64.0.0/10) address was incorrectly counted as public",
        )

    def test_interfaces_unavailable_is_unresolved(self):
        block = {"available": False, "reason": "ip_not_found", "interfaces": []}
        result = net_facts.public_ipv4_summary(block)
        self.assertEqual(result["status"], "unresolved")
        self.assertEqual(result["unresolved_reason"], "ip_not_found")
        self.assertIsNone(result["count"])


if __name__ == "__main__":
    unittest.main()
