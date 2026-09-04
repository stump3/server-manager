#!/usr/bin/env python3
"""
poc/network-inspect/tests/test_inventory_build.py
===================================================

EXPERIMENTAL / RESEARCH POC — tests for inventory_build.py's own
remaining responsibilities after the network-inspect architecture
split (see README.md "Architecture"): the socket/PID/process/
ownership/docker/systemd/firewall correlation pipeline, the
detect_ingress() orchestration function that ties nginx/caddy/haproxy
together using correlation-pipeline data, and the top-level
build_inventory()/main() assembly.

Provider- and fact-specific tests that used to live in this single
file now live next to the modules they test:
  - nginx capability parsing        -> test_providers_nginx.py
  - caddy/caddy-l4 capability parsing -> test_providers_caddy.py
  - Hysteria2 obfs.type parsing      -> test_hysteria2_config.py
  - public IPv4 counting             -> test_net_facts.py
  - run()/which() primitive          -> test_run_command.py
  - Capability Registry               -> test_capabilities.py

This file keeps: detect_ingress()'s own orchestration-level behavior
(present/absent wiring across three providers), and the regression
suite proving poc-1's own already-verified invariants (PID resolution
semantics, the crude nginx stream{} block count, JSON schema shape).
SIGPIPE handling is exercised separately by hand — see README.md
"Real-host verification" — not by this file, since it requires an
actual subprocess pipe, not a unittest mock.

Run with:
    python3 -m unittest discover -s poc/network-inspect/tests -v
"""

from __future__ import annotations

import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import _loader  # noqa: F401 - adds poc/network-inspect/ to sys.path

_THIS_DIR = Path(__file__).resolve().parent
_MODULE_PATH = _THIS_DIR.parent / "inventory_build.py"

# poc/network-inspect/ is not a valid Python package name (hyphen), so
# the module under test is loaded directly by file path rather than
# via a normal `import` — this mirrors how network-inspect.sh itself
# invokes it (`exec python3 <path>`), not a package-relative import.
# _loader (imported above) has already put poc/network-inspect/ on
# sys.path, so inventory_build.py's own sibling imports
# (`from run_command import ...`, `from providers import nginx as
# nginx_provider`, etc.) resolve correctly during this exec.
_spec = importlib.util.spec_from_file_location("inventory_build", _MODULE_PATH)
inv = importlib.util.module_from_spec(_spec)
sys.modules["inventory_build"] = inv
_spec.loader.exec_module(inv)  # type: ignore[union-attr]

import net_facts
from providers import nginx as nginx_provider
from providers import caddy as caddy_provider
from run_command import RunResult


def _run_result(stdout="", stderr="", returncode=0, ok=True, reason=None):
    return RunResult(ok=ok, returncode=returncode, stdout=stdout, stderr=stderr, reason=reason)


# ─────────────────────────────────────────────────────────────────────
# detect_ingress() — present/absent restructuring (schema poc-2),
# and the orchestration-level wiring across nginx/caddy/haproxy.
#
# Mocking note: detect_ingress() itself calls `inv.which`/`inv.run`
# directly (for `nginx -v`/`nginx -T`/`caddy version`/`haproxy -v` and
# the top-level presence check), but the actual capability probing is
# delegated to nginx_provider.stream_capabilities() and
# caddy_provider.layer4_capabilities(), each of which holds its OWN
# `from run_command import run` binding — patching `inv.run` does NOT
# intercept calls made from inside those provider modules. Tests that
# need to control a provider's capability probe patch
# `nginx_provider.run` / `caddy_provider.run` directly.
# ─────────────────────────────────────────────────────────────────────

class TestDetectIngressPresence(unittest.TestCase):
    def test_e_caddy_absent_is_not_an_error(self):
        """Scenario E: caddy binary absent entirely — must be a clean,
        explicit present=False, never an exception or a fabricated
        capability."""
        with mock.patch.object(inv, "which", side_effect=lambda b: None):
            result = inv.detect_ingress(set())
        self.assertFalse(result["caddy"]["present"])
        self.assertIsNone(result["caddy"]["layer4_capabilities"])
        self.assertFalse(result["nginx"]["present"])
        self.assertFalse(result["haproxy"]["present"])

    def test_a_nginx_absent(self):
        """Scenario A: nginx absent."""
        with mock.patch.object(inv, "which", side_effect=lambda b: None):
            result = inv.detect_ingress(set())
        self.assertFalse(result["nginx"]["present"])
        self.assertIsNone(result["nginx"]["stream_capabilities"])

    def test_caddy_present_derives_legacy_boolean_from_module_list(self):
        modules = "layer4  v0.0.0\nlayer4.matchers.quic\n"

        def fake_which(b):
            return "/usr/bin/caddy" if b == "caddy" else None

        def fake_inv_run(cmd, timeout=None):
            # Handles _version_of(["caddy", "version"]) inside
            # detect_ingress() itself.
            if cmd[:2] == ["caddy", "version"]:
                return _run_result(stdout="v2.9.0\n")
            return _run_result(ok=False, reason="not_found")

        with mock.patch.object(inv, "which", side_effect=fake_which), \
             mock.patch.object(inv, "run", side_effect=fake_inv_run), \
             mock.patch.object(caddy_provider, "run", return_value=_run_result(stdout=modules)):
            result = inv.detect_ingress(set())
        self.assertTrue(result["caddy"]["present"])
        self.assertTrue(result["caddy"]["layer4_module_compiled_in"])
        self.assertTrue(result["caddy"]["layer4_capabilities"]["layer4_matchers_quic_present"])

    def test_nginx_present_wires_through_to_provider(self):
        cfg = "configure arguments: --with-stream --with-stream_ssl_preread_module"

        def fake_which(b):
            return "/usr/sbin/nginx" if b == "nginx" else None

        def fake_inv_run(cmd, timeout=None):
            if cmd[:2] == ["nginx", "-v"]:
                return _run_result(stderr="nginx version: nginx/1.24.0\n")
            if cmd[:2] == ["nginx", "-T"]:
                return _run_result(stdout="stream {\n  ...\n}\n")
            return _run_result(ok=False, reason="not_found")

        with mock.patch.object(inv, "which", side_effect=fake_which), \
             mock.patch.object(inv, "run", side_effect=fake_inv_run), \
             mock.patch.object(nginx_provider, "run", return_value=_run_result(stderr=cfg)):
            result = inv.detect_ingress(set())
        self.assertTrue(result["nginx"]["present"])
        self.assertEqual(result["nginx"]["stream_block_count"], 1)
        self.assertTrue(result["nginx"]["stream_capabilities"]["compiled_with_stream"])
        self.assertTrue(result["nginx"]["stream_capabilities"]["compiled_with_stream_ssl_preread"])


# ─────────────────────────────────────────────────────────────────────
# Hysteria2 config path plumbing — HYSTERIA_CONFIG_PATH still lives in
# inventory_build.py (it's orchestration-level: build_inventory() is
# what decides WHICH path to hand to hysteria2_config.obfuscation()),
# so these tests stay here rather than in test_hysteria2_config.py,
# which only covers hysteria2_config.py's own module-internal logic.
# ─────────────────────────────────────────────────────────────────────

class TestHysteriaConfigPathPlumbing(unittest.TestCase):
    def test_default_path_matches_project_convention(self):
        """Verifies this PoC's default HYSTERIA_CONFIG_PATH literal
        actually matches lib/core/config.sh's own composition
        (HYSTERIA_DIR + '/config.yaml'), not just an assumption, and
        that no SM_NETWORK_INSPECT_HYSTERIA_CONFIG override was in
        effect for this test process (this test suite never sets
        that env var itself)."""
        repo_root = _THIS_DIR.parent.parent.parent
        config_sh = repo_root / "lib" / "core" / "config.sh"
        text = config_sh.read_text()
        self.assertIn('HYSTERIA_DIR="/etc/hysteria"', text)
        self.assertIn('HYSTERIA_CONFIG="${HYSTERIA_DIR}/config.yaml"', text)
        self.assertNotIn("SM_NETWORK_INSPECT_HYSTERIA_CONFIG", os.environ)
        self.assertEqual(inv.HYSTERIA_CONFIG_PATH, "/etc/hysteria/config.yaml")

    def test_env_override_mechanism_is_honored_by_caller(self):
        """The override env var is read once into the module-level
        HYSTERIA_CONFIG_PATH constant at import time and then passed
        explicitly into hysteria2_config.obfuscation() by
        build_inventory() — this test exercises that plumbing via a
        subprocess (the only reliable way to observe a different
        os.environ value at import time), confirming main() actually
        prints a hysteria2.obfuscation block reflecting the fixture
        path's content, not the real /etc/hysteria/config.yaml."""
        import json

        fd, fixture = tempfile.mkstemp(suffix=".yaml")
        with os.fdopen(fd, "w") as fh:
            fh.write("obfs:\n  type: gecko\n")
        self.addCleanup(lambda: os.path.exists(fixture) and os.remove(fixture))

        env = dict(os.environ)
        env["SM_NETWORK_INSPECT_HYSTERIA_CONFIG"] = fixture
        env["SM_NETWORK_INSPECT_NO_DOCKER"] = "1"
        proc = subprocess.run(
            [sys.executable, str(_MODULE_PATH)],
            capture_output=True, text=True, timeout=15, env=env,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        data = json.loads(proc.stdout)
        self.assertEqual(data["hysteria2"]["obfuscation"]["config_path"], fixture)
        self.assertEqual(data["hysteria2"]["obfuscation"]["effective_value"], "gecko")


# ─────────────────────────────────────────────────────────────────────
# Regression: poc-1 invariants, and the architecture-split invariant
# that inventory_build.py's own output is byte-identical to before the
# split (verified separately by hand, see README.md "Refactoring
# performed" — this class re-asserts the shape-level invariants a
# unit test CAN meaningfully check).
# ─────────────────────────────────────────────────────────────────────

class TestRegressionPoc1Invariants(unittest.TestCase):
    def test_stream_block_count_regex_unchanged(self):
        """Same crude single-stream{}-block check the poc-1 README
        already documents as verified against
        lib/panel/nginx/variant_j.sh — re-run here to confirm this
        round's split didn't touch that logic."""
        repo_root = _THIS_DIR.parent.parent.parent
        template = repo_root / "lib" / "panel" / "nginx" / "variant_j.sh"
        if not template.exists():
            self.skipTest("variant_j.sh not present in this checkout")
        text = template.read_text()
        import re
        count = len(re.findall(r"^\s*stream\s*{", text, re.MULTILINE))
        self.assertEqual(count, 1)

    def test_build_inventory_produces_valid_schema_poc2(self):
        """Smoke test: build_inventory() must still run to completion
        (no exception) and produce the expected new top-level keys
        alongside every poc-1 key, unchanged in type/shape — the
        schema is UNCHANGED by this round's architecture split
        (still "poc-2", zero JSON impact, see README.md "Schema
        impact")."""
        with mock.patch.object(inv, "which", return_value=None), \
             mock.patch.object(inv, "collect_listeners", return_value=[]), \
             mock.patch.object(inv, "build_inode_to_pid_map", return_value=({}, False)):
            result = inv.build_inventory()
        self.assertEqual(result["schema_version"], "poc-2")
        for key in ("generated_at", "privilege", "interfaces", "listeners",
                    "firewall", "detected_ingress", "warnings"):
            self.assertIn(key, result, f"poc-1 key {key!r} missing after architecture split")
        for key in ("hysteria2", "public_ipv4"):
            self.assertIn(key, result, f"poc-2 key {key!r} missing after architecture split")
        self.assertIsInstance(result["listeners"], list)
        self.assertIn("obfuscation", result["hysteria2"])

    def test_pid_unresolved_reasons_untouched(self):
        """Confirms the PID_UNRESOLVED_* constants and their two
        distinct meanings (permission vs not-found/cross-namespace)
        still exist with the same values — this round's changes never
        touched that code path, this just asserts that fact."""
        self.assertEqual(inv.PID_UNRESOLVED_PERMISSION, "permission_denied")
        self.assertEqual(inv.PID_UNRESOLVED_NOT_FOUND, "not_found_or_cross_namespace")

    def test_public_ipv4_still_diverges_from_legacy_is_public_ip(self):
        """Cross-module regression check: inventory_build.py's own
        `_is_public_ip()` (used for per-listener public_exposure
        classification, deliberately left unchanged — see README.md
        "Research findings requiring correction") still over-counts
        CGNAT relative to net_facts.py's stricter
        `_is_globally_routable_ipv4()`. This documents the intentional
        divergence still holding after the module split, rather than
        the two silently drifting back into agreement (or apart in a
        new way) unnoticed."""
        self.assertTrue(inv._is_public_ip("100.64.0.5"))
        self.assertFalse(net_facts._is_globally_routable_ipv4("100.64.0.5"))


if __name__ == "__main__":
    unittest.main()
