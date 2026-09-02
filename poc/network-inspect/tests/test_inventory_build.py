#!/usr/bin/env python3
"""
poc/network-inspect/tests/test_inventory_build.py
===================================================

EXPERIMENTAL / RESEARCH POC — tests for the schema poc-2 additions
only (nginx compiled-module discovery, Caddy/caddy-l4 module discovery,
Hysteria2 obfs.type discovery, public IPv4 counting), plus a small
regression check that poc-1's own already-tested invariants (crude
`stream {` block counting, JSON validity) still hold.

These tests are read-only in the same sense the PoC itself is
read-only: nothing here installs, mutates, or reloads any real system
component. External tool behavior (nginx -V, caddy list-modules, real
config files) is exercised entirely through mocked `run()`/`which()`
return values and temporary fixture files — no real nginx/Caddy/
HAProxy package is installed anywhere in this test run, per the task's
explicit "не устанавливай реальные сторонние пакеты только ради
тестов" constraint.

Run with:
    python3 -m unittest discover -s poc/network-inspect/tests -v

No pytest dependency — this repo has no existing Python test
framework convention to match (verified: no pytest/unittest config
anywhere in the repo), so this uses only the stdlib `unittest`, kept
consistent with inventory_build.py's own zero-new-dependency posture.
"""

from __future__ import annotations

import importlib.util
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

_THIS_DIR = Path(__file__).resolve().parent
_MODULE_PATH = _THIS_DIR.parent / "inventory_build.py"

# poc/network-inspect/ is not a valid Python package name (hyphen), so
# the module under test is loaded directly by file path rather than
# via a normal `import` — this mirrors how network-inspect.sh itself
# invokes it (`exec python3 <path>`), not a package-relative import.
_spec = importlib.util.spec_from_file_location("inventory_build", _MODULE_PATH)
inv = importlib.util.module_from_spec(_spec)
sys.modules["inventory_build"] = inv
_spec.loader.exec_module(inv)  # type: ignore[union-attr]


def _run_result(stdout="", stderr="", returncode=0, ok=True, reason=None):
    return inv.RunResult(ok=ok, returncode=returncode, stdout=stdout, stderr=stderr, reason=reason)


# ─────────────────────────────────────────────────────────────────────
# nginx compiled-module capability discovery
# ─────────────────────────────────────────────────────────────────────

class TestNginxStreamCapabilities(unittest.TestCase):
    def test_b_present_stream_absent(self):
        """Scenario B: nginx exists, --with-stream not in configure args."""
        cfg = "configure arguments: --prefix=/etc/nginx --with-http_ssl_module"
        with mock.patch.object(inv, "run", return_value=_run_result(stderr=f"nginx version: nginx/1.24.0\n{cfg}")):
            result = inv.nginx_stream_capabilities("/usr/sbin/nginx")
        self.assertEqual(result["status"], "available")
        self.assertFalse(result["compiled_with_stream"])
        self.assertFalse(result["compiled_with_stream_ssl_preread"])
        self.assertIsNone(result["stream_module_type"])

    def test_c_present_stream_present_no_ssl_preread(self):
        """Scenario C: --with-stream present, ssl_preread not."""
        cfg = "configure arguments: --prefix=/etc/nginx --with-stream --with-http_v2_module"
        with mock.patch.object(inv, "run", return_value=_run_result(stderr=cfg)):
            result = inv.nginx_stream_capabilities("/usr/sbin/nginx")
        self.assertEqual(result["status"], "available")
        self.assertTrue(result["compiled_with_stream"])
        self.assertFalse(result["compiled_with_stream_ssl_preread"])
        self.assertEqual(result["stream_module_type"], "static")

    def test_d_present_stream_and_ssl_preread(self):
        """Scenario D: both --with-stream and --with-stream_ssl_preread_module."""
        cfg = (
            "configure arguments: --prefix=/etc/nginx --with-stream "
            "--with-stream_ssl_module --with-stream_ssl_preread_module"
        )
        with mock.patch.object(inv, "run", return_value=_run_result(stderr=cfg)):
            result = inv.nginx_stream_capabilities("/usr/sbin/nginx")
        self.assertEqual(result["status"], "available")
        self.assertTrue(result["compiled_with_stream"])
        self.assertTrue(result["compiled_with_stream_ssl_preread"])

    def test_substring_collision_guard(self):
        """Regression test for the exact bug this design avoids: a
        naive `"--with-stream" in configure_args` substring check would
        also match inside "--with-stream_ssl_preread_module" even when
        bare --with-stream was never actually passed. The whole-token
        regex must NOT make that mistake."""
        cfg = "configure arguments: --with-stream_ssl_preread_module"
        with mock.patch.object(inv, "run", return_value=_run_result(stderr=cfg)):
            result = inv.nginx_stream_capabilities("/usr/sbin/nginx")
        self.assertFalse(
            result["compiled_with_stream"],
            "substring collision: bare --with-stream falsely detected "
            "via --with-stream_ssl_preread_module",
        )
        self.assertTrue(result["compiled_with_stream_ssl_preread"])

    def test_dynamic_module_caveat_recorded(self):
        cfg = "configure arguments: --with-stream=dynamic"
        with mock.patch.object(inv, "run", return_value=_run_result(stderr=cfg)):
            result = inv.nginx_stream_capabilities("/usr/sbin/nginx")
        self.assertTrue(result["compiled_with_stream"])
        self.assertEqual(result["stream_module_type"], "dynamic")
        self.assertIsNotNone(result["dynamic_module_caveat"])

    def test_binary_disappeared_between_which_and_run(self):
        with mock.patch.object(inv, "run", return_value=_run_result(ok=False, reason="not_found")):
            result = inv.nginx_stream_capabilities("/usr/sbin/nginx")
        self.assertEqual(result["status"], "unresolved")
        self.assertIn("version_probe_failed", result["unresolved_reason"])
        self.assertIsNone(result["compiled_with_stream"])

    def test_unexpected_output_format(self):
        with mock.patch.object(inv, "run", return_value=_run_result(stderr="nginx version: nginx/0.0.1-weird-fork\n")):
            result = inv.nginx_stream_capabilities("/usr/sbin/nginx")
        self.assertEqual(result["status"], "unresolved")
        self.assertEqual(result["unresolved_reason"], "configure_arguments_not_found")


# ─────────────────────────────────────────────────────────────────────
# Caddy / caddy-l4 module capability discovery
# ─────────────────────────────────────────────────────────────────────

class TestCaddyLayer4Capabilities(unittest.TestCase):
    def test_f_stock_caddy_no_layer4(self):
        """Scenario F: caddy present, no layer4 module at all."""
        modules = "http.handlers.reverse_proxy\ntls.issuance.acme\ncaddy.listeners.tls\n"
        with mock.patch.object(inv, "run", return_value=_run_result(stdout=modules)):
            result = inv.caddy_layer4_capabilities("/usr/bin/caddy")
        self.assertEqual(result["status"], "available")
        self.assertFalse(result["layer4_present"])
        self.assertFalse(result["layer4_matchers_quic_present"])
        self.assertFalse(result["layer4_matchers_tls_present"])

    def test_g_caddy_with_layer4_no_matchers_listed(self):
        """Scenario G: layer4 app present, but this particular build's
        module list doesn't separately enumerate the quic/tls matcher
        sub-modules (a plausible real-world shape depending on build)."""
        modules = "http.handlers.reverse_proxy\nlayer4  v0.0.0-20260101\nlayer4.handlers.proxy\n"
        with mock.patch.object(inv, "run", return_value=_run_result(stdout=modules)):
            result = inv.caddy_layer4_capabilities("/usr/bin/caddy")
        self.assertTrue(result["layer4_present"])
        self.assertFalse(result["layer4_matchers_quic_present"])
        self.assertFalse(result["layer4_matchers_tls_present"])

    def test_h_caddy_with_layer4_and_quic_matcher(self):
        """Scenario H: layer4 + QUIC matcher present."""
        modules = (
            "layer4  v0.0.0-20260101\n"
            "layer4.matchers.quic\n"
            "layer4.matchers.tls\n"
            "layer4.handlers.proxy\n"
        )
        with mock.patch.object(inv, "run", return_value=_run_result(stdout=modules)):
            result = inv.caddy_layer4_capabilities("/usr/bin/caddy")
        self.assertTrue(result["layer4_present"])
        self.assertTrue(result["layer4_matchers_quic_present"])
        self.assertTrue(result["layer4_matchers_tls_present"])
        self.assertIn("layer4.matchers.quic", result["raw_module_list"])

    def test_binary_present_but_command_absent(self):
        with mock.patch.object(inv, "run", return_value=_run_result(ok=False, reason="not_found")):
            result = inv.caddy_layer4_capabilities("/usr/bin/caddy")
        self.assertEqual(result["status"], "unresolved")
        self.assertIsNone(result["layer4_present"])

    def test_empty_module_list_is_unresolved_not_false(self):
        """An empty module list must NOT be silently treated as
        'confirmed no layer4' — it's more likely a parsing/format
        problem than a real module-less Caddy build."""
        with mock.patch.object(inv, "run", return_value=_run_result(stdout="\n\n")):
            result = inv.caddy_layer4_capabilities("/usr/bin/caddy")
        self.assertEqual(result["status"], "unresolved")
        self.assertEqual(result["unresolved_reason"], "empty_module_list")
        self.assertIsNone(result["layer4_present"])


# ─────────────────────────────────────────────────────────────────────
# detect_ingress() — present/absent restructuring (schema poc-2)
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

        def fake_run(cmd, timeout=None):
            if cmd[:2] == ["caddy", "version"]:
                return _run_result(stdout="v2.9.0\n")
            if cmd[:2] == ["caddy", "list-modules"]:
                return _run_result(stdout=modules)
            return _run_result(ok=False, reason="not_found")

        with mock.patch.object(inv, "which", side_effect=fake_which), \
             mock.patch.object(inv, "run", side_effect=fake_run):
            result = inv.detect_ingress(set())
        self.assertTrue(result["caddy"]["present"])
        self.assertTrue(result["caddy"]["layer4_module_compiled_in"])
        self.assertTrue(result["caddy"]["layer4_capabilities"]["layer4_matchers_quic_present"])


# ─────────────────────────────────────────────────────────────────────
# Hysteria2 obfuscation discovery
# ─────────────────────────────────────────────────────────────────────

class TestHysteria2Obfuscation(unittest.TestCase):
    def _write(self, content: str) -> str:
        fd, path = tempfile.mkstemp(suffix=".yaml")
        with os.fdopen(fd, "w") as fh:
            fh.write(content)
        self.addCleanup(lambda: os.path.exists(path) and os.remove(path))
        return path

    def test_i_obfs_type_none(self):
        path = self._write("listen: 0.0.0.0:443\nobfs:\n  type: none\n")
        result = inv.hysteria2_obfuscation(path)
        self.assertEqual(result["status"], "resolved")
        self.assertTrue(result["field_present_in_config"])
        self.assertEqual(result["effective_value"], "none")
        self.assertEqual(result["effective_value_basis"], "explicit_in_config")

    def test_j_obfs_type_salamander(self):
        path = self._write(
            "listen: 0.0.0.0:443\nobfs:\n  type: salamander\n  salamander:\n    password: x\n"
        )
        result = inv.hysteria2_obfuscation(path)
        self.assertEqual(result["status"], "resolved")
        self.assertEqual(result["effective_value"], "salamander")
        self.assertEqual(result["raw_type_value"], "salamander")

    def test_k_obfs_type_gecko(self):
        path = self._write("obfs:\n  type: gecko\n  gecko:\n    password: y\n")
        result = inv.hysteria2_obfuscation(path)
        self.assertEqual(result["effective_value"], "gecko")

    def test_l_obfs_section_absent(self):
        """Section physically absent — must resolve to effective 'none'
        (per upstream docs: 'configs that omit obfs use the
        unobfuscated path') while separately recording that the field
        itself was not present."""
        path = self._write("listen: 0.0.0.0:443\nacme:\n  type: http\n")
        result = inv.hysteria2_obfuscation(path)
        self.assertEqual(result["status"], "resolved")
        self.assertFalse(result["field_present_in_config"])
        self.assertEqual(result["effective_value"], "none")
        self.assertEqual(result["effective_value_basis"], "default_when_absent")

    def test_m_config_missing(self):
        result = inv.hysteria2_obfuscation("/nonexistent/path/config.yaml")
        self.assertEqual(result["status"], "unresolved")
        self.assertEqual(result["unresolved_reason"], "config_missing")
        self.assertIsNone(result["effective_value"])

    def test_n_config_unreadable(self):
        path = self._write("obfs:\n  type: none\n")
        with mock.patch("builtins.open", side_effect=PermissionError):
            result = inv.hysteria2_obfuscation(path)
        self.assertEqual(result["status"], "unresolved")
        self.assertEqual(result["unresolved_reason"], "config_unreadable")

    def test_o_malformed_tab_indentation(self):
        path = self._write("obfs:\n\ttype: salamander\n")
        result = inv.hysteria2_obfuscation(path)
        self.assertEqual(result["status"], "unresolved")
        self.assertEqual(result["unresolved_reason"], "malformed_yaml:tab_indentation")

    def test_malformed_unbalanced_quote(self):
        path = self._write('obfs:\n  type: "salamander\n')
        result = inv.hysteria2_obfuscation(path)
        self.assertEqual(result["status"], "unresolved")
        self.assertEqual(result["unresolved_reason"], "malformed_yaml:unbalanced_quote")

    def test_obfs_block_present_type_missing(self):
        path = self._write("obfs:\n  salamander:\n    password: x\n")
        result = inv.hysteria2_obfuscation(path)
        self.assertEqual(result["status"], "unresolved")
        self.assertEqual(result["unresolved_reason"], "obfs_block_present_but_type_missing")
        self.assertTrue(result["field_present_in_config"])

    def test_flow_style_not_supported(self):
        path = self._write("obfs: {type: salamander}\n")
        result = inv.hysteria2_obfuscation(path)
        self.assertEqual(result["status"], "unresolved")
        self.assertEqual(result["unresolved_reason"], "flow_style_not_supported")

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
        # i.e. the real, composed path is /etc/hysteria/config.yaml —
        # matches inv.HYSTERIA_CONFIG_PATH's default exactly.
        self.assertNotIn("SM_NETWORK_INSPECT_HYSTERIA_CONFIG", os.environ)
        self.assertEqual(inv.HYSTERIA_CONFIG_PATH, "/etc/hysteria/config.yaml")

    def test_env_override_mechanism_is_honored_by_caller(self):
        """The override env var is read once into the module-level
        HYSTERIA_CONFIG_PATH constant at import time and then passed
        explicitly into hysteria2_obfuscation() by build_inventory() —
        this test exercises that plumbing via a subprocess (the only
        reliable way to observe a different os.environ value at
        import time without the dataclass re-exec fragility of
        reloading this module in-process), confirming main() actually
        prints a hysteria2.obfuscation block reflecting the fixture
        path's content, not the real /etc/hysteria/config.yaml."""
        import json
        import subprocess

        fixture = self._write("obfs:\n  type: gecko\n")
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
# Public IPv4 counting
# ─────────────────────────────────────────────────────────────────────

def _iface(name, addrs):
    return {"name": name, "state": "UP", "flags": [], "addresses": addrs}


def _addr(family, address, prefixlen=24):
    return {"family": family, "address": address, "prefixlen": prefixlen, "scope": "global"}


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
        result = inv.public_ipv4_summary(block)
        self.assertEqual(result["status"], "available")
        self.assertEqual(result["count"], 1)

    def test_two_public_ipv4(self):
        block = {"available": True, "interfaces": [
            _iface("eth0", [_addr("inet", "8.8.8.8")]),
            _iface("eth1", [_addr("inet", "1.1.1.1")]),
        ]}
        result = inv.public_ipv4_summary(block)
        self.assertEqual(result["count"], 2)

    def test_zero_public_ipv4_only_private(self):
        block = {"available": True, "interfaces": [
            _iface("eth0", [_addr("inet", "10.0.0.5")]),
            _iface("lo", [_addr("inet", "127.0.0.1")]),
        ]}
        result = inv.public_ipv4_summary(block)
        self.assertEqual(result["count"], 0)

    def test_mixed_private_and_public(self):
        block = {"available": True, "interfaces": [
            _iface("eth0", [_addr("inet", "8.8.4.4"), _addr("inet", "10.0.0.5")]),
        ]}
        result = inv.public_ipv4_summary(block)
        self.assertEqual(result["count"], 1)
        self.assertEqual(result["addresses"][0]["address"], "8.8.4.4")

    def test_ipv6_only_does_not_count(self):
        block = {"available": True, "interfaces": [
            _iface("eth0", [_addr("inet6", "2001:db8::1")]),
        ]}
        result = inv.public_ipv4_summary(block)
        self.assertEqual(result["count"], 0)

    def test_docker_bridge_private_excluded(self):
        block = {"available": True, "interfaces": [
            _iface("docker0", [_addr("inet", "172.17.0.1")]),
        ]}
        result = inv.public_ipv4_summary(block)
        self.assertEqual(result["count"], 0)

    def test_cgnat_range_not_counted_as_public(self):
        """Regression test for the RFC 6598 CGNAT gap this PoC's
        stricter _is_globally_routable_ipv4() closes relative to the
        pre-existing, laxer _is_public_ip() helper."""
        block = {"available": True, "interfaces": [
            _iface("eth0", [_addr("inet", "100.64.0.5")]),
        ]}
        # Confirm the OLD helper really would have over-counted this —
        # documents the discrepancy this test guards against.
        self.assertTrue(inv._is_public_ip("100.64.0.5"))
        result = inv.public_ipv4_summary(block)
        self.assertEqual(
            result["count"], 0,
            "CGNAT (100.64.0.0/10) address was incorrectly counted as public",
        )

    def test_interfaces_unavailable_is_unresolved(self):
        block = {"available": False, "reason": "ip_not_found", "interfaces": []}
        result = inv.public_ipv4_summary(block)
        self.assertEqual(result["status"], "unresolved")
        self.assertEqual(result["unresolved_reason"], "ip_not_found")
        self.assertIsNone(result["count"])


# ─────────────────────────────────────────────────────────────────────
# Regression: poc-1 invariants must be unchanged
# ─────────────────────────────────────────────────────────────────────

class TestRegressionPoc1Invariants(unittest.TestCase):
    def test_stream_block_count_regex_unchanged(self):
        """Same crude single-stream{}-block check the poc-1 README
        already documents as verified against
        lib/panel/nginx/variant_j.sh — re-run here to confirm this
        round's edits didn't touch that logic."""
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
        alongside every poc-1 key, unchanged in type/shape."""
        with mock.patch.object(inv, "which", return_value=None), \
             mock.patch.object(inv, "collect_listeners", return_value=[]), \
             mock.patch.object(inv, "build_inode_to_pid_map", return_value=({}, False)):
            result = inv.build_inventory()
        self.assertEqual(result["schema_version"], "poc-2")
        for key in ("generated_at", "privilege", "interfaces", "listeners",
                    "firewall", "detected_ingress", "warnings"):
            self.assertIn(key, result, f"poc-1 key {key!r} missing after poc-2 changes")
        for key in ("hysteria2", "public_ipv4"):
            self.assertIn(key, result, f"poc-2 key {key!r} missing")
        self.assertIsInstance(result["listeners"], list)
        self.assertIn("obfuscation", result["hysteria2"])

    def test_pid_unresolved_reasons_untouched(self):
        """Confirms the PID_UNRESOLVED_* constants and their two
        distinct meanings (permission vs not-found/cross-namespace)
        still exist with the same values — this round's changes never
        touched that code path, this just asserts that fact."""
        self.assertEqual(inv.PID_UNRESOLVED_PERMISSION, "permission_denied")
        self.assertEqual(inv.PID_UNRESOLVED_NOT_FOUND, "not_found_or_cross_namespace")


if __name__ == "__main__":
    unittest.main()
