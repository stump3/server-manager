#!/usr/bin/env python3
"""
tests/test_target_mapping.py
================================

Focused tests for executors/targets.py — the generic (provider-
independent) runtime target mapping layer. See test_nginx_preflight.py
for the nginx-specific runtime preflight adapter that consumes this.
"""

from __future__ import annotations

import ast
import contextlib
import inspect
import re
import unittest
from unittest import mock

import _loader  # noqa: F401 - adds poc/network-inspect/ to sys.path

import executors.core as core
import executors.targets as targets
from executors.targets import ExecutionTarget, TargetRegistry, MANAGED, UNMANAGED, UNKNOWN


def _target(provider="nginx", target_kind="nginx_stream", target_name="stream",
            location="/opt/remnawave/nginx.conf", management_scope=MANAGED):
    return ExecutionTarget(provider, target_kind, target_name, location, management_scope)


class TestExecutionTargetConstruction(unittest.TestCase):
    def test_valid_target_constructs(self):
        t = _target()
        self.assertEqual(t.identity(), ("nginx", "nginx_stream", "stream"))
        self.assertEqual(t.location, "/opt/remnawave/nginx.conf")
        self.assertEqual(t.management_scope, MANAGED)

    def test_is_frozen(self):
        t = _target()
        with self.assertRaises(Exception):
            t.location = "/somewhere/else"

    def test_every_management_scope_value_is_accepted(self):
        for scope in (MANAGED, UNMANAGED, UNKNOWN):
            with self.subTest(scope):
                self.assertEqual(_target(management_scope=scope).management_scope, scope)

    def test_unknown_management_scope_value_is_rejected(self):
        for bad in ("Managed", "MANAGED", "owned", "", None, 1):
            with self.subTest(bad):
                with self.assertRaises(ValueError):
                    _target(management_scope=bad)

    def test_empty_or_blank_identity_fields_are_rejected(self):
        for field_ in ("provider", "target_kind", "target_name", "location"):
            with self.subTest(field_):
                for bad in ("", "   ", "\t\n"):
                    with self.assertRaises(ValueError):
                        _target(**{field_: bad})

    def test_non_string_identity_fields_are_rejected(self):
        for field_ in ("provider", "target_kind", "target_name", "location"):
            with self.subTest(field_):
                with self.assertRaises(ValueError):
                    _target(**{field_: 42})

    def test_construction_error_names_the_offending_field_and_value(self):
        with self.assertRaises(ValueError) as ctx:
            _target(target_name="")
        self.assertIn("target_name", str(ctx.exception))


class TestTargetRegistryConstruction(unittest.TestCase):
    def test_empty_registry_is_valid(self):
        self.assertEqual(TargetRegistry().targets, ())
        self.assertEqual(TargetRegistry([]).targets, ())

    def test_non_execution_target_entries_are_rejected(self):
        for bad in ("a target", {"provider": "nginx"}, None, 42):
            with self.subTest(bad):
                with self.assertRaises(ValueError):
                    TargetRegistry([bad])

    def test_one_bad_entry_among_good_ones_still_rejects_construction(self):
        with self.assertRaises(ValueError):
            TargetRegistry([_target(), "not a target", _target(target_name="other")])

    def test_registry_accepts_any_iterable(self):
        def gen():
            yield _target()
            yield _target(target_name="other")
        self.assertEqual(len(TargetRegistry(gen()).targets), 2)

    def test_duplicate_identity_entries_are_stored_not_collapsed(self):
        # Construction itself does not dedupe — resolve() is where a
        # collision must be detected, not silently hidden by a dict.
        reg = TargetRegistry([_target(location="/a"), _target(location="/b")])
        self.assertEqual(len(reg.targets), 2)


class TestResolve(unittest.TestCase):
    def test_exactly_one_match_resolves(self):
        t = _target()
        reg = TargetRegistry([t])
        found, diags = reg.resolve("nginx", "nginx_stream", "stream")
        self.assertIs(found, t)
        self.assertEqual(diags, [])

    def test_missing_mapping_fails(self):
        reg = TargetRegistry([_target()])
        for provider, kind, name in (
            ("caddy_l4", "nginx_stream", "stream"),
            ("nginx", "nginx_http", "stream"),
            ("nginx", "nginx_stream", "other"),
        ):
            with self.subTest(provider=provider, kind=kind, name=name):
                found, diags = reg.resolve(provider, kind, name)
                self.assertIsNone(found)
                self.assertEqual([d.code for d in diags], ["target_not_mapped"])
                self.assertEqual(diags[0].severity, "error")

    def test_empty_registry_always_misses(self):
        found, diags = TargetRegistry().resolve("nginx", "nginx_stream", "stream")
        self.assertIsNone(found)
        self.assertEqual([d.code for d in diags], ["target_not_mapped"])

    def test_ambiguous_mapping_fails_and_picks_neither(self):
        a = _target(location="/a")
        b = _target(location="/b")
        reg = TargetRegistry([a, b])
        found, diags = reg.resolve("nginx", "nginx_stream", "stream")
        self.assertIsNone(found)
        self.assertEqual([d.code for d in diags], ["ambiguous_target_mapping"])
        self.assertIn("2 execution targets", diags[0].message)

    def test_three_way_ambiguity_is_still_one_diagnostic(self):
        reg = TargetRegistry([_target(location=f"/{n}") for n in range(3)])
        found, diags = reg.resolve("nginx", "nginx_stream", "stream")
        self.assertIsNone(found)
        self.assertEqual(len(diags), 1)
        self.assertIn("3 execution targets", diags[0].message)

    def test_resolution_is_exact_per_field_not_a_partial_match(self):
        # Two entries that differ only in target_name must not cross-match.
        reg = TargetRegistry([_target(target_name="stream"), _target(target_name="stream2")])
        found, diags = reg.resolve("nginx", "nginx_stream", "stream")
        self.assertEqual(found.target_name, "stream")
        self.assertEqual(diags, [])

    def test_registry_with_multiple_unrelated_providers_resolves_independently(self):
        nginx_t = _target(provider="nginx")
        caddy_t = _target(provider="caddy_l4", target_kind="caddy_layer4", target_name="udp")
        reg = TargetRegistry([nginx_t, caddy_t])
        found, _ = reg.resolve("nginx", "nginx_stream", "stream")
        self.assertIs(found, nginx_t)
        found, _ = reg.resolve("caddy_l4", "caddy_layer4", "udp")
        self.assertIs(found, caddy_t)

    def test_resolve_diagnostics_are_the_same_shape_as_core_diagnostics(self):
        _, diags = TargetRegistry().resolve("nginx", "nginx_stream", "stream")
        self.assertIsInstance(diags[0], core.Diagnostic)
        self.assertEqual(set(diags[0].as_dict()), {"code", "severity", "resource_id", "field", "message"})

    def test_resolve_never_raises_for_a_missing_or_ambiguous_mapping(self):
        # Contrast with construction, which DOES raise for caller misuse
        # (a malformed ExecutionTarget) — resolve() only ever returns.
        try:
            TargetRegistry().resolve("nginx", "nginx_stream", "stream")
            TargetRegistry([_target(), _target()]).resolve("nginx", "nginx_stream", "stream")
        except Exception as exc:  # pragma: no cover - failure path
            self.fail(f"resolve() raised {exc!r}")


class TestDeterminism(unittest.TestCase):
    def test_repeated_resolve_is_identical(self):
        reg = TargetRegistry([_target()])
        first = reg.resolve("nginx", "nginx_stream", "stream")
        second = reg.resolve("nginx", "nginx_stream", "stream")
        self.assertEqual(first[0], second[0])
        self.assertEqual([d.as_dict() for d in first[1]], [d.as_dict() for d in second[1]])

    def test_repeated_failed_resolve_is_identical(self):
        reg = TargetRegistry([_target(location="/a"), _target(location="/b")])
        first = reg.resolve("nginx", "nginx_stream", "stream")
        second = reg.resolve("nginx", "nginx_stream", "stream")
        self.assertEqual([d.as_dict() for d in first[1]], [d.as_dict() for d in second[1]])


class TestNoSideEffects(unittest.TestCase):
    def test_no_filesystem_subprocess_or_network_primitive_is_ever_touched(self):
        targets_list = ["builtins.open", "os.replace", "os.rename", "os.remove", "os.stat", "os.lstat",
                        "subprocess.Popen", "subprocess.run", "subprocess.call", "socket.socket"]
        with contextlib.ExitStack() as stack:
            mocks = {t: stack.enter_context(mock.patch(t)) for t in targets_list}
            reg = TargetRegistry([_target(), _target(location="/other")])
            reg.resolve("nginx", "nginx_stream", "stream")
            reg.resolve("nginx", "nginx_stream", "missing")
            try:
                _target(management_scope="bogus")
            except ValueError:
                pass
        for target_, m in mocks.items():
            self.assertFalse(m.called, f"{target_} must never be used by executors.targets")

    def test_registry_construction_and_resolve_do_not_mutate_inputs(self):
        entries = [_target(), _target(location="/other")]
        before = list(entries)
        reg = TargetRegistry(entries)
        reg.resolve("nginx", "nginx_stream", "stream")
        self.assertEqual(entries, before)
        self.assertEqual(reg.targets, tuple(before))


class TestArchitecturalBoundary(unittest.TestCase):
    """See executors/targets.py's own ARCHITECTURAL BOUNDARY section."""

    def _imported_top_level_names(self):
        tree = ast.parse(inspect.getsource(targets))
        names = set()
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                names.update(a.name.split(".")[0] for a in node.names)
            elif isinstance(node, ast.ImportFrom):
                names.add((node.module or "").split(".")[0])
        return names

    def test_imports_only_stdlib_and_executors_core(self):
        self.assertLessEqual(self._imported_top_level_names(), {"__future__", "dataclasses", "typing", "executors"})

    def test_does_not_import_nginx_or_forbidden_pipeline_modules(self):
        forbidden = {"planner", "desired_state", "inventory_build", "net_facts", "capabilities",
                     "plan_ir", "plan_validator", "renderers", "providers", "hysteria2_config",
                     "run_command"}
        self.assertFalse(self._imported_top_level_names() & forbidden)
        # executors.nginx specifically: targets.py must stay nginx-unaware,
        # the same direction executors/core.py already keeps from nginx.py.
        # AST-based (not a text search) so the module docstring's own
        # prose references to "executors/nginx.py" don't false-positive.
        tree = ast.parse(inspect.getsource(targets))
        submodules_imported = set()
        for node in ast.walk(tree):
            if isinstance(node, ast.ImportFrom) and node.module:
                submodules_imported.add(node.module)
            elif isinstance(node, ast.Import):
                submodules_imported.update(a.name for a in node.names)
        self.assertNotIn("executors.nginx", submodules_imported)

    def test_no_io_capable_or_dynamic_calls(self):
        forbidden_calls = {"open", "print", "eval", "exec", "compile", "__import__", "input"}
        tree = ast.parse(inspect.getsource(targets))
        for node in ast.walk(tree):
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Name):
                self.assertNotIn(node.func.id, forbidden_calls, f"targets.py: {node.func.id}()")

    def test_no_hard_coded_runtime_path_in_generic_target_mapping_code(self):
        """No hard-coded runtime path exists in generic Executor code (see
        stage report). Scans every string literal in this module's actual
        CODE (module docstring excluded — prose there legitimately cites
        real example paths as evidence) for anything shaped like an
        absolute filesystem path with at least two segments."""
        source = inspect.getsource(targets)
        tree = ast.parse(source)
        doc = ast.get_docstring(tree) or ""
        path_like = re.compile(r"^/[\w.\-]+(?:/[\w.\-]+)+$")
        offenders = []
        for node in ast.walk(tree):
            if isinstance(node, ast.Constant) and isinstance(node.value, str):
                if node.value in doc:
                    continue   # substring of the docstring's own prose, not code
                if path_like.match(node.value):
                    offenders.append(node.value)
        self.assertEqual(offenders, [])

    def test_core_module_also_has_no_hard_coded_runtime_path(self):
        # executors/core.py predates this stage but is the other half of
        # "generic Executor code" the same invariant applies to.
        import executors.core as core_module
        source = inspect.getsource(core_module)
        tree = ast.parse(source)
        doc = ast.get_docstring(tree) or ""
        path_like = re.compile(r"^/[\w.\-]+(?:/[\w.\-]+)+$")
        offenders = [n.value for n in ast.walk(tree)
                    if isinstance(n, ast.Constant) and isinstance(n.value, str)
                    and n.value not in doc and path_like.match(n.value)]
        self.assertEqual(offenders, [])


if __name__ == "__main__":
    unittest.main()
