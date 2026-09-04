#!/usr/bin/env python3
"""
poc/network-inspect/tests/test_providers_caddy.py
====================================================

EXPERIMENTAL / RESEARCH POC — tests for providers/caddy.py, moved out
of the former monolithic test_inventory_build.py during the
network-inspect architecture split (see README.md "Architecture").

Split the same way as test_providers_nginx.py: pure-parser tests
against `_parse_module_list_output()` (plain strings, no mocking) and
I/O-wrapper tests against `layer4_capabilities()` (mocked
`providers.caddy.run` — note the target, not `inventory_build.run`).
"""

from __future__ import annotations

import unittest
from unittest import mock

import _loader  # noqa: F401 - adds poc/network-inspect/ to sys.path

from providers import caddy as caddy_provider
from run_command import RunResult


def _run_result(stdout="", stderr="", returncode=0, ok=True, reason=None):
    return RunResult(ok=ok, returncode=returncode, stdout=stdout, stderr=stderr, reason=reason)


class TestParseModuleListOutput(unittest.TestCase):
    """Pure-parser tests — no subprocess, no mocking."""

    def test_module_names_extracted_ignoring_versions(self):
        stdout = "layer4  v0.0.0-20260101\nlayer4.matchers.quic\nhttp.handlers.reverse_proxy  v2.9.0\n"
        modules = caddy_provider._parse_module_list_output(stdout)
        self.assertEqual(
            modules,
            ["layer4", "layer4.matchers.quic", "http.handlers.reverse_proxy"],
        )

    def test_empty_input_yields_empty_list(self):
        self.assertEqual(caddy_provider._parse_module_list_output("\n\n  \n"), [])

    def test_blank_lines_skipped(self):
        modules = caddy_provider._parse_module_list_output("layer4\n\n\nlayer4.matchers.tls\n")
        self.assertEqual(modules, ["layer4", "layer4.matchers.tls"])


class TestLayer4Capabilities(unittest.TestCase):
    """I/O-boundary tests — mocked providers.caddy.run()."""

    def test_f_stock_caddy_no_layer4(self):
        """Scenario F: caddy present, no layer4 module at all."""
        modules = "http.handlers.reverse_proxy\ntls.issuance.acme\ncaddy.listeners.tls\n"
        with mock.patch.object(caddy_provider, "run", return_value=_run_result(stdout=modules)):
            result = caddy_provider.layer4_capabilities("/usr/bin/caddy")
        self.assertEqual(result["status"], "available")
        self.assertFalse(result["layer4_present"])
        self.assertFalse(result["layer4_matchers_quic_present"])
        self.assertFalse(result["layer4_matchers_tls_present"])

    def test_g_layer4_present_no_matchers_listed(self):
        """Scenario G: layer4 app present, but this particular build's
        module list doesn't separately enumerate the quic/tls matcher
        sub-modules (a plausible real-world shape depending on build)."""
        modules = "http.handlers.reverse_proxy\nlayer4  v0.0.0-20260101\nlayer4.handlers.proxy\n"
        with mock.patch.object(caddy_provider, "run", return_value=_run_result(stdout=modules)):
            result = caddy_provider.layer4_capabilities("/usr/bin/caddy")
        self.assertTrue(result["layer4_present"])
        self.assertFalse(result["layer4_matchers_quic_present"])
        self.assertFalse(result["layer4_matchers_tls_present"])

    def test_h_layer4_and_quic_matcher(self):
        """Scenario H: layer4 + QUIC matcher present."""
        modules = (
            "layer4  v0.0.0-20260101\n"
            "layer4.matchers.quic\n"
            "layer4.matchers.tls\n"
            "layer4.handlers.proxy\n"
        )
        with mock.patch.object(caddy_provider, "run", return_value=_run_result(stdout=modules)):
            result = caddy_provider.layer4_capabilities("/usr/bin/caddy")
        self.assertTrue(result["layer4_present"])
        self.assertTrue(result["layer4_matchers_quic_present"])
        self.assertTrue(result["layer4_matchers_tls_present"])
        self.assertIn("layer4.matchers.quic", result["raw_module_list"])

    def test_binary_present_but_command_absent(self):
        with mock.patch.object(caddy_provider, "run", return_value=_run_result(ok=False, reason="not_found")):
            result = caddy_provider.layer4_capabilities("/usr/bin/caddy")
        self.assertEqual(result["status"], "unresolved")
        self.assertIsNone(result["layer4_present"])

    def test_empty_module_list_is_unresolved_not_false(self):
        """An empty module list must NOT be silently treated as
        'confirmed no layer4' — it's more likely a parsing/format
        problem than a real module-less Caddy build."""
        with mock.patch.object(caddy_provider, "run", return_value=_run_result(stdout="\n\n")):
            result = caddy_provider.layer4_capabilities("/usr/bin/caddy")
        self.assertEqual(result["status"], "unresolved")
        self.assertEqual(result["unresolved_reason"], "empty_module_list")
        self.assertIsNone(result["layer4_present"])


if __name__ == "__main__":
    unittest.main()
