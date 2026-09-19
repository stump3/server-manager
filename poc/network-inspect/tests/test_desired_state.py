#!/usr/bin/env python3
"""
tests/test_desired_state.py
==============================

Focused unit tests for desired_state.py's `backend_hint` validation —
added alongside the backend endpoint semantic path (see plan_ir.py's
`build_backend()` and planner.py's own backend_hint gate). Scoped
narrowly to backend_hint: the rest of desired_state.py's validation
surface (port/ip/tls/quic/proxy_protocol/exclusivity/cross-service
sharing) has no dedicated unit test file of its own yet and is out of
scope for this change.
"""

from __future__ import annotations

import unittest

import _loader  # noqa: F401 - adds poc/network-inspect/ to sys.path

import desired_state as ds


def _doc(backend_hint):
    return {
        "schema_version": ds.SCHEMA_VERSION,
        "services": [{
            "id": "xray",
            "transport": "tcp",
            "exposure": "public",
            "port": {"selection": "specific", "value": 443, "sharing": "allowed"},
            "ip": {"selection": "any_public", "value": None, "same_as_service": None, "separate_from_service": None},
            "backend_hint": backend_hint,
        }],
    }


class TestBackendHint(unittest.TestCase):
    def test_valid_loopback_port_is_accepted(self):
        result = ds.validate(_doc({"loopback_port": 8443}))
        self.assertTrue(result.valid, result.errors)

    def test_absent_backend_hint_is_accepted(self):
        doc = _doc({"loopback_port": 8443})
        del doc["services"][0]["backend_hint"]
        result = ds.validate(doc)
        self.assertTrue(result.valid, result.errors)

    def test_port_below_range_is_rejected(self):
        result = ds.validate(_doc({"loopback_port": 0}))
        self.assertFalse(result.valid)
        self.assertIn("invalid_port_value", [e.code for e in result.errors])

    def test_port_above_range_is_rejected(self):
        result = ds.validate(_doc({"loopback_port": 65536}))
        self.assertFalse(result.valid)
        self.assertIn("invalid_port_value", [e.code for e in result.errors])

    def test_non_integer_port_is_rejected(self):
        result = ds.validate(_doc({"loopback_port": "8443"}))
        self.assertFalse(result.valid)
        self.assertIn("invalid_port_value", [e.code for e in result.errors])

    def test_backend_hint_not_a_mapping_is_rejected(self):
        result = ds.validate(_doc(8443))
        self.assertFalse(result.valid)
        self.assertIn("invalid_type", [e.code for e in result.errors])

    def test_missing_loopback_port_is_rejected(self):
        result = ds.validate(_doc({}))
        self.assertFalse(result.valid)
        self.assertIn("missing_field", [e.code for e in result.errors])


if __name__ == "__main__":
    unittest.main()
