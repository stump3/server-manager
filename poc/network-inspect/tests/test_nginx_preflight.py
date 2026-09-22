#!/usr/bin/env python3
"""
tests/test_nginx_preflight.py
=================================

Focused tests for executors/nginx.py's RUNTIME half added in the Runtime
Target Mapping + NGINX Preflight stage: `resolve_nginx_target()` and
`nginx_runtime_preflight()`. See test_target_mapping.py for the generic
TargetRegistry/ExecutionTarget layer this builds on, and test_executor.py
/ test_nginx_renderer.py for the STRUCTURAL preflight and Renderer this
stage does not change (only a coordinated target_kind rename touches
those files — see TestRenameIsTheOnlyRendererChange below).

Everything here runs against a fake NginxCommandPort (no real nginx, no
subprocess, no docker, no filesystem) — see TestNoRealIO.
"""

from __future__ import annotations

import ast
import contextlib
import inspect
import unittest
from unittest import mock

import _loader  # noqa: F401 - adds poc/network-inspect/ to sys.path

import plan_ir
import renderers.nginx as nginx_renderer
import executors.core as core
import executors.nginx as nginx_executor
import executors.targets as targets
from executors.nginx import (
    CommandResult, TargetStat, resolve_nginx_target, nginx_runtime_preflight,
)
from executors.targets import ExecutionTarget, TargetRegistry, MANAGED, UNMANAGED, UNKNOWN
from test_nginx_renderer import _ngroup, _svc_entry


LOCATION = "/opt/remnawave/nginx.conf"


def _target(management_scope=MANAGED, target_name="stream", location=LOCATION):
    return ExecutionTarget("nginx", "nginx_stream", target_name, location, management_scope)


def _registry(*targets_):
    return TargetRegistry(targets_)


class FakePort:
    """In-memory NginxCommandPort. Every method is independently
    overridable per test via the constructor, so a test only has to
    describe what it cares about."""

    def __init__(self, stat=None, syntax=None, dump=None,
                stat_raises=None, syntax_raises=None, dump_raises=None):
        self._stat = stat if stat is not None else TargetStat(True, True, False, True)
        self._syntax = syntax if syntax is not None else CommandResult(True, 0, "syntax is ok", "")
        self._dump = dump if dump is not None else CommandResult(True, 0, "http {}\n", "")
        self._stat_raises = stat_raises
        self._syntax_raises = syntax_raises
        self._dump_raises = dump_raises
        self.calls = []

    def stat_target(self, target):
        self.calls.append(("stat_target", target.location))
        if self._stat_raises:
            raise self._stat_raises
        return self._stat

    def check_syntax(self, target, content):
        self.calls.append(("check_syntax", target.location, content))
        if self._syntax_raises:
            raise self._syntax_raises
        return self._syntax

    def dump_config(self, target):
        self.calls.append(("dump_config", target.location))
        if self._dump_raises:
            raise self._dump_raises
        return self._dump


def _render_one_group():
    rr = nginx_renderer.render(plan_ir.assemble([_ngroup(["a", "b"])]))
    assert rr.valid and len(rr.artifacts) == 1, rr.diagnostics
    return rr


def _render_two_groups():
    rr = nginx_renderer.render(plan_ir.assemble([_ngroup(["a", "b"]), _ngroup(["c", "d"], ip="203.0.113.11")]))
    assert rr.valid and len(rr.artifacts) == 1, rr.diagnostics
    return rr


def _codes(diags):
    return [d.code for d in diags]


# ─────────────────────────────────────────────────────────────────────
# 1/2/3/16. resolve_nginx_target
# ─────────────────────────────────────────────────────────────────────

class TestResolveNginxTarget(unittest.TestCase):
    def test_artifact_resolves_to_an_explicit_target(self):
        rr = _render_one_group()
        t = _target()
        target, diags = resolve_nginx_target(rr, _registry(t))
        self.assertIs(target, t)
        self.assertEqual(diags, [])

    def test_missing_mapping_fails(self):
        rr = _render_one_group()
        target, diags = resolve_nginx_target(rr, _registry())
        self.assertIsNone(target)
        self.assertEqual(_codes(diags), ["target_not_mapped"])

    def test_ambiguous_mapping_fails(self):
        rr = _render_one_group()
        target, diags = resolve_nginx_target(rr, _registry(_target(location="/a"), _target(location="/b")))
        self.assertIsNone(target)
        self.assertEqual(_codes(diags), ["ambiguous_target_mapping"])

    def test_mapping_for_a_different_provider_does_not_match(self):
        rr = _render_one_group()
        foreign = ExecutionTarget("caddy_l4", "nginx_stream", "stream", "/x", MANAGED)
        target, diags = resolve_nginx_target(rr, _registry(foreign))
        self.assertIsNone(target)
        self.assertEqual(_codes(diags), ["target_not_mapped"])

    def test_render_result_with_no_artifacts_fails_without_touching_the_registry(self):
        empty = nginx_renderer.RenderResult(True, "nginx", [], [])
        target, diags = resolve_nginx_target(empty, _registry(_target()))
        self.assertIsNone(target)
        self.assertEqual(_codes(diags), ["no_nginx_artifact"])

    def test_multiple_nginx_groups_still_resolve_to_exactly_one_target(self):
        rr = _render_two_groups()
        self.assertEqual(len(rr.artifacts), 1)   # the Renderer already collapsed this; sanity check
        t = _target()
        target, diags = resolve_nginx_target(rr, _registry(t))
        self.assertIs(target, t)
        self.assertEqual(diags, [])

    def test_resolution_is_deterministic(self):
        rr = _render_two_groups()
        reg = _registry(_target())
        first = resolve_nginx_target(rr, reg)
        second = resolve_nginx_target(rr, reg)
        self.assertEqual(first[0], second[0])


# ─────────────────────────────────────────────────────────────────────
# 5/6/7. Ownership
# ─────────────────────────────────────────────────────────────────────

class TestOwnership(unittest.TestCase):
    def test_unknown_ownership_fails(self):
        artifacts = tuple(_render_one_group().artifacts)
        diags = nginx_runtime_preflight(_target(management_scope=UNKNOWN), artifacts, FakePort())
        self.assertEqual(_codes(diags), ["target_not_managed"])

    def test_unmanaged_target_fails(self):
        artifacts = tuple(_render_one_group().artifacts)
        diags = nginx_runtime_preflight(_target(management_scope=UNMANAGED), artifacts, FakePort())
        self.assertEqual(_codes(diags), ["target_not_managed"])
        self.assertIn("unmanaged", diags[0].message)

    def test_managed_target_passes_ownership_and_reaches_the_port(self):
        artifacts = tuple(_render_one_group().artifacts)
        port = FakePort()
        diags = nginx_runtime_preflight(_target(management_scope=MANAGED), artifacts, port)
        self.assertEqual(diags, [])
        self.assertTrue(port.calls)   # ownership passing means the rest of preflight actually ran

    def test_ownership_is_never_inferred_from_stat_or_syntax_results(self):
        # Even a port that reports a perfectly healthy target must not
        # override an UNKNOWN/UNMANAGED scope — ownership is asserted by
        # the caller, never inferred from what the port observes.
        healthy = FakePort(stat=TargetStat(True, True, False, True),
                           syntax=CommandResult(True, 0, "ok", ""),
                           dump=CommandResult(True, 0, "", ""))
        for scope in (UNKNOWN, UNMANAGED):
            with self.subTest(scope):
                artifacts = tuple(_render_one_group().artifacts)
                diags = nginx_runtime_preflight(_target(management_scope=scope), artifacts, healthy)
                self.assertIn("target_not_managed", _codes(diags))


# ─────────────────────────────────────────────────────────────────────
# 4/9. Structural cross-checks (kind support, artifact/target identity)
# ─────────────────────────────────────────────────────────────────────

class TestShapeAndKind(unittest.TestCase):
    def test_unsupported_target_kind_fails(self):
        artifacts = tuple(_render_one_group().artifacts)
        bad = ExecutionTarget("nginx", "nginx_http_server_block", "stream", LOCATION, MANAGED)
        # bypass identity-mismatch by using a matching-shaped artifact tuple with the same target_name
        diags = nginx_runtime_preflight(bad, artifacts, FakePort())
        self.assertIn("target_identity_mismatch", _codes(diags))   # kind differs from the artifact's own

    def test_target_kind_mismatched_from_a_hand_built_registry_entry_is_caught(self):
        # A registry entry whose kind the nginx executor has never heard
        # of, but whose (target_kind, target_name) happens to still equal
        # the artifact's own (simulating a stale/bad hand-authored entry).
        artifacts = (nginx_renderer.Artifact("nginx:stream", "nginx_http_server_block", "stream", "content"),)
        bad = ExecutionTarget("nginx", "nginx_http_server_block", "stream", LOCATION, MANAGED)
        diags = nginx_runtime_preflight(bad, artifacts, FakePort())
        self.assertEqual(_codes(diags), ["unsupported_artifact_kind"])

    def test_wrong_target_shape_zero_artifacts_fails(self):
        diags = nginx_runtime_preflight(_target(), (), FakePort())
        self.assertEqual(_codes(diags), ["wrong_target_shape"])

    def test_wrong_target_shape_multiple_artifacts_fails(self):
        art = _render_one_group().artifacts[0]
        diags = nginx_runtime_preflight(_target(), (art, art), FakePort())
        self.assertEqual(_codes(diags), ["wrong_target_shape"])

    def test_target_identity_mismatch_fails_and_stops_before_the_port(self):
        artifacts = tuple(_render_one_group().artifacts)   # target_name == "stream"
        mismatched = _target(target_name="other")
        port = FakePort()
        diags = nginx_runtime_preflight(mismatched, artifacts, port)
        self.assertEqual(_codes(diags), ["target_identity_mismatch"])
        self.assertEqual(port.calls, [])   # nothing safe to check once identity doesn't match

    def test_identity_mismatch_gates_every_other_check(self):
        # Even an unmanaged, unsupported-kind target with identity
        # mismatch reports ONLY the mismatch - nothing else is safe to
        # evaluate once the target doesn't even describe this artifact.
        artifacts = tuple(_render_one_group().artifacts)
        bad = ExecutionTarget("nginx", "nginx_http", "other", LOCATION, UNKNOWN)
        diags = nginx_runtime_preflight(bad, artifacts, FakePort())
        self.assertEqual(_codes(diags), ["target_identity_mismatch"])


# ─────────────────────────────────────────────────────────────────────
# 8. Filesystem-shaped checks (via the injected port)
# ─────────────────────────────────────────────────────────────────────

class TestTargetStat(unittest.TestCase):
    def _diags(self, stat):
        artifacts = tuple(_render_one_group().artifacts)
        return nginx_runtime_preflight(_target(), artifacts, FakePort(stat=stat))

    def test_missing_target_fails(self):
        diags = self._diags(TargetStat(False, False, False, False))
        self.assertIn("target_missing", _codes(diags))

    def test_unsafe_symlink_fails(self):
        diags = self._diags(TargetStat(True, True, True, True))
        self.assertIn("unsafe_symlink", _codes(diags))

    def test_wrong_target_type_not_a_regular_file_fails(self):
        diags = self._diags(TargetStat(True, False, False, True))
        self.assertIn("target_not_a_file", _codes(diags))

    def test_not_writable_fails(self):
        diags = self._diags(TargetStat(True, True, False, False))
        self.assertIn("target_not_writable", _codes(diags))

    def test_healthy_stat_passes_that_category_cleanly(self):
        diags = self._diags(TargetStat(True, True, False, True))
        self.assertEqual([d for d in diags if d.code in
                          ("target_missing", "unsafe_symlink", "target_not_a_file", "target_not_writable")], [])

    def test_symlink_and_wrong_type_can_both_be_reported_together(self):
        diags = self._diags(TargetStat(True, False, True, True))
        self.assertEqual(sorted(_codes(diags)), ["target_not_a_file", "unsafe_symlink"])

    def test_missing_target_does_not_also_report_symlink_or_type(self):
        # exists=False makes the other stat-derived facts meaningless
        diags = self._diags(TargetStat(False, False, False, False))
        self.assertEqual(_codes(diags), ["target_missing"])

    def test_stat_raising_is_a_structured_failure_not_an_exception(self):
        artifacts = tuple(_render_one_group().artifacts)
        port = FakePort(stat_raises=OSError("permission denied"))
        diags = nginx_runtime_preflight(_target(), artifacts, port)
        self.assertIn("stat_target_failed", _codes(diags))
        self.assertIn("permission denied", [d for d in diags if d.code == "stat_target_failed"][0].message)


# ─────────────────────────────────────────────────────────────────────
# 10/11. nginx runtime validation (check_syntax)
# ─────────────────────────────────────────────────────────────────────

class TestSyntaxValidation(unittest.TestCase):
    def test_nginx_runtime_validation_success_is_structured(self):
        artifacts = tuple(_render_one_group().artifacts)
        port = FakePort(syntax=CommandResult(True, 0, "syntax is ok", ""))
        diags = nginx_runtime_preflight(_target(), artifacts, port)
        self.assertEqual([d for d in diags if "syntax" in d.code], [])

    def test_nginx_runtime_validation_failure_is_structured(self):
        artifacts = tuple(_render_one_group().artifacts)
        port = FakePort(syntax=CommandResult(True, 1, "", "nginx: [emerg] unexpected end of file"))
        diags = nginx_runtime_preflight(_target(), artifacts, port)
        self.assertEqual(_codes(diags), ["nginx_syntax_invalid"])
        self.assertIn("unexpected end of file", diags[0].message)

    def test_syntax_check_that_could_not_run_is_distinguished_from_invalid_syntax(self):
        artifacts = tuple(_render_one_group().artifacts)
        port = FakePort(syntax=CommandResult(False, None, "", "binary not found"))
        diags = nginx_runtime_preflight(_target(), artifacts, port)
        self.assertEqual(_codes(diags), ["nginx_syntax_check_failed"])

    def test_syntax_check_raising_is_a_structured_failure(self):
        artifacts = tuple(_render_one_group().artifacts)
        port = FakePort(syntax_raises=TimeoutError("docker exec timed out"))
        diags = nginx_runtime_preflight(_target(), artifacts, port)
        self.assertEqual(_codes(diags), ["nginx_syntax_check_failed"])
        self.assertIn("docker exec timed out", diags[0].message)

    def test_syntax_check_receives_the_candidate_artifact_content_not_the_targets_current_content(self):
        rr = _render_one_group()
        artifact = rr.artifacts[0]
        port = FakePort()
        nginx_runtime_preflight(_target(), (artifact,), port)
        seen_content = [c[2] for c in port.calls if c[0] == "check_syntax"][0]
        self.assertEqual(seen_content, artifact.content)
        self.assertNotEqual(seen_content, port._dump.stdout)   # never confused with dump_config's text


# ─────────────────────────────────────────────────────────────────────
# Configuration scope compatibility (dump_config)
# ─────────────────────────────────────────────────────────────────────

class TestConfigurationScope(unittest.TestCase):
    def test_single_existing_stream_block_is_compatible(self):
        artifacts = tuple(_render_one_group().artifacts)
        port = FakePort(dump=CommandResult(True, 0, "http {}\nstream {\n  server {}\n}\n", ""))
        diags = nginx_runtime_preflight(_target(), artifacts, port)
        self.assertEqual([d for d in diags if "scope" in d.code], [])

    def test_no_existing_stream_block_is_compatible(self):
        artifacts = tuple(_render_one_group().artifacts)
        port = FakePort(dump=CommandResult(True, 0, "http {}\n", ""))
        diags = nginx_runtime_preflight(_target(), artifacts, port)
        self.assertEqual([d for d in diags if "scope" in d.code], [])

    def test_two_existing_stream_blocks_are_incompatible(self):
        artifacts = tuple(_render_one_group().artifacts)
        port = FakePort(dump=CommandResult(True, 0, "stream {}\nstream {}\n", ""))
        diags = nginx_runtime_preflight(_target(), artifacts, port)
        self.assertEqual(_codes(diags), ["incompatible_configuration_scope"])

    def test_uses_the_same_regex_convention_inventory_uses(self):
        # inventory_build.py's detect_ingress(): re.findall(r"^\s*stream\s*{", text, re.MULTILINE)
        artifacts = tuple(_render_one_group().artifacts)
        port = FakePort(dump=CommandResult(True, 0, "  stream   {\nstream{\n", ""))
        diags = nginx_runtime_preflight(_target(), artifacts, port)
        self.assertEqual(_codes(diags), ["incompatible_configuration_scope"])
        self.assertIn("2 top-level", diags[0].message)

    def test_dump_config_that_could_not_run_is_structured(self):
        artifacts = tuple(_render_one_group().artifacts)
        port = FakePort(dump=CommandResult(False, None, "", "docker: no such container"))
        diags = nginx_runtime_preflight(_target(), artifacts, port)
        self.assertEqual(_codes(diags), ["dump_config_failed"])

    def test_dump_config_raising_is_structured(self):
        artifacts = tuple(_render_one_group().artifacts)
        port = FakePort(dump_raises=ConnectionError("docker socket unreachable"))
        diags = nginx_runtime_preflight(_target(), artifacts, port)
        self.assertEqual(_codes(diags), ["dump_config_failed"])
        self.assertIn("docker socket unreachable", diags[0].message)


# ─────────────────────────────────────────────────────────────────────
# Independent checks all run; several failures all surface
# ─────────────────────────────────────────────────────────────────────

class TestAllChecksRun(unittest.TestCase):
    def test_every_category_can_fail_simultaneously_and_all_are_reported(self):
        artifacts = tuple(_render_one_group().artifacts)
        port = FakePort(stat=TargetStat(True, True, True, False),
                        syntax=CommandResult(True, 1, "", "bad syntax"),
                        dump=CommandResult(True, 0, "stream{}\nstream{}\n", ""))
        diags = nginx_runtime_preflight(_target(management_scope=UNMANAGED), artifacts, port)
        self.assertEqual(sorted(_codes(diags)), sorted([
            "target_not_managed", "unsafe_symlink", "target_not_writable",
            "incompatible_configuration_scope", "nginx_syntax_invalid",
        ]))

    def test_a_port_failure_in_one_category_does_not_suppress_another(self):
        artifacts = tuple(_render_one_group().artifacts)
        port = FakePort(stat_raises=OSError("boom"), syntax=CommandResult(True, 1, "", "bad"))
        diags = nginx_runtime_preflight(_target(), artifacts, port)
        self.assertEqual(sorted(_codes(diags)), ["nginx_syntax_invalid", "stat_target_failed"])


# ─────────────────────────────────────────────────────────────────────
# 7 (continued) / determinism
# ─────────────────────────────────────────────────────────────────────

class TestHappyPathAndDeterminism(unittest.TestCase):
    def test_fully_managed_healthy_target_passes_every_check(self):
        artifacts = tuple(_render_two_groups().artifacts)
        diags = nginx_runtime_preflight(_target(), artifacts, FakePort())
        self.assertEqual(diags, [])

    def test_preflight_calls_the_port_in_a_fixed_order(self):
        artifacts = tuple(_render_one_group().artifacts)
        port = FakePort()
        nginx_runtime_preflight(_target(), artifacts, port)
        self.assertEqual([c[0] for c in port.calls], ["stat_target", "dump_config", "check_syntax"])

    def test_repeated_preflight_against_the_same_port_is_deterministic(self):
        artifacts = tuple(_render_one_group().artifacts)
        target = _target()
        first = nginx_runtime_preflight(target, artifacts, FakePort())
        second = nginx_runtime_preflight(target, artifacts, FakePort())
        self.assertEqual([d.as_dict() for d in first], [d.as_dict() for d in second])

    def test_end_to_end_resolve_then_preflight(self):
        rr = _render_two_groups()
        registry = _registry(_target())
        target, resolve_diags = resolve_nginx_target(rr, registry)
        self.assertEqual(resolve_diags, [])
        preflight_diags = nginx_runtime_preflight(target, tuple(rr.artifacts), FakePort())
        self.assertEqual(preflight_diags, [])


# ─────────────────────────────────────────────────────────────────────
# 12/13. No real I/O anywhere in this stage's new code
# ─────────────────────────────────────────────────────────────────────

class TestNoRealIO(unittest.TestCase):
    def test_no_filesystem_subprocess_or_network_primitive_is_ever_touched(self):
        rr = _render_two_groups()
        registry = _registry(_target())
        target, _ = resolve_nginx_target(rr, registry)
        targets_list = ["builtins.open", "os.replace", "os.rename", "os.remove", "os.stat", "os.lstat",
                        "subprocess.Popen", "subprocess.run", "subprocess.call", "socket.socket",
                        "shutil.rmtree", "shutil.copy"]
        with contextlib.ExitStack() as stack:
            mocks = {t: stack.enter_context(mock.patch(t)) for t in targets_list}
            nginx_runtime_preflight(target, tuple(rr.artifacts), FakePort())
            nginx_runtime_preflight(_target(management_scope=UNMANAGED), tuple(rr.artifacts), FakePort())
        for target_name, m in mocks.items():
            self.assertFalse(m.called, f"{target_name} must never be used by nginx_runtime_preflight")

    def test_nginx_command_port_is_a_protocol_with_no_real_implementation_in_this_stage(self):
        self.assertTrue(hasattr(nginx_executor.NginxCommandPort, "_is_protocol")
                        or "Protocol" in [b.__name__ for b in nginx_executor.NginxCommandPort.__mro__])
        # No module this package can reach implements it for real. Checked
        # via imports (AST), not a text search — the module docstring
        # legitimately DISCUSSES subprocess/docker in prose as future work.
        tree = ast.parse(inspect.getsource(nginx_executor))
        imported = set()
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                imported.update(a.name.split(".")[0] for a in node.names)
            elif isinstance(node, ast.ImportFrom):
                imported.add((node.module or "").split(".")[0])
        self.assertFalse(imported & {"subprocess", "socket", "docker", "os"})


# ─────────────────────────────────────────────────────────────────────
# 14. Renderer output unchanged except the approved target_kind rename
# ─────────────────────────────────────────────────────────────────────

class TestRenameIsTheOnlyRendererChange(unittest.TestCase):
    def test_content_is_still_byte_identical_only_target_kind_changed(self):
        rr = nginx_renderer.render(plan_ir.assemble([plan_ir.build_group("SHARED_TCP_SNI", "nginx", [
            _svc_entry("web", sni=["web.example.com", "www.example.com"], backend_port=7443, proxy_protocol="required"),
            _svc_entry("xray", sni=[], backend_port=8443, proxy_protocol="required"),
            _svc_entry("telemt", sni=["tm.example.com"], backend_port=10001, proxy_protocol="required"),
        ])]))
        self.assertTrue(rr.valid, rr.diagnostics)
        self.assertEqual(rr.artifacts[0].content, """stream {
    map $ssl_preread_server_name $backend_telemt_web_xray {
        tm.example.com telemt;
        web.example.com web;
        www.example.com web;
        default xray;
    }
    upstream telemt { server 127.0.0.1:10001; }
    upstream web { server 127.0.0.1:7443; }
    upstream xray { server 127.0.0.1:8443; }

    server {
        listen 203.0.113.10:443;
        ssl_preread on;
        proxy_pass $backend_telemt_web_xray;
        proxy_protocol on;
    }
}
""")
        self.assertEqual(rr.artifacts[0].target_kind, "nginx_stream")
        self.assertEqual(rr.artifacts[0].artifact_id, "nginx:stream")
        self.assertEqual(rr.artifacts[0].target_name, "stream")

    def test_renderer_and_executor_target_kind_constants_still_agree(self):
        self.assertEqual(nginx_renderer.TARGET_KIND, nginx_executor.TARGET_KIND)
        self.assertEqual(nginx_renderer.TARGET_KIND, "nginx_stream")

    def test_structural_preflight_still_accepts_real_renderer_output(self):
        rr = _render_two_groups()
        result = core.prepare(rr, nginx_executor.NginxExecutor())
        self.assertEqual(result.status, "prepared", result.diagnostics)

    def test_old_target_kind_string_no_longer_accepted_anywhere(self):
        rr = nginx_renderer.RenderResult(True, "nginx", [
            nginx_renderer.Artifact("nginx:stream", "nginx_stream_server_block", "stream", "stream {}\n")], [])
        result = core.prepare(rr, nginx_executor.NginxExecutor())
        self.assertEqual(result.status, "validation_failed")
        self.assertIn("unsupported_artifact_kind", _codes(result.diagnostics))


# ─────────────────────────────────────────────────────────────────────
# 15/17. Regression + generic-layer path-hygiene (nginx.py's own share)
# ─────────────────────────────────────────────────────────────────────

class TestRegressionAndPathHygiene(unittest.TestCase):
    def test_existing_executor_foundation_tests_still_pass_standalone(self):
        # Smoke check only - the real assurance is running test_executor.py
        # itself (see stage report's VALIDATION section); this confirms the
        # rename didn't leave the two modules disagreeing at import time.
        self.assertIn(nginx_renderer.TARGET_KIND, nginx_executor.SUPPORTED_TARGET_KINDS)

    def test_no_hard_coded_example_path_in_nginx_py_code_outside_tests(self):
        """nginx.py is provider-specific (unlike targets.py/core.py, it is
        allowed to know what an nginx path looks like in prose), but it
        must still never hard-code one as a runtime DEFAULT. Every real
        `/opt/...`-shaped literal in this stage's tests comes from a test
        fixture (LOCATION, above), never from nginx.py itself."""
        import re as re_module
        source = inspect.getsource(nginx_executor)
        tree = ast.parse(source)
        doc = ast.get_docstring(tree) or ""
        path_like = re_module.compile(r"^/[\w.\-]+(?:/[\w.\-]+)+$")
        offenders = [n.value for n in ast.walk(tree)
                    if isinstance(n, ast.Constant) and isinstance(n.value, str)
                    and n.value not in doc and path_like.match(n.value)]
        self.assertEqual(offenders, [])


if __name__ == "__main__":
    unittest.main()
