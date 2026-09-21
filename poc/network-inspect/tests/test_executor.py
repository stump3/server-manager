#!/usr/bin/env python3
"""
tests/test_executor.py
=========================

Focused tests for executors/ — the Executor foundation and transaction
contract. Everything here runs against an in-memory fake `ExecutionPort`
whose "host" is a plain dict: no subprocess, no shell, no real
filesystem, no real nginx, no network, no systemctl. Multi-artifact
semantics ("never half-applied") are proven by asserting the fake host's
final contents, not only the call log.

Real Renderer output (renderers/nginx.py) is used wherever the scenario is
one the Renderer actually produces; hand-built RenderResults (using the
Renderer's own dataclasses as shape carriers) cover the structural
rejections and the provider-independent transaction mechanics.
"""

from __future__ import annotations

import ast
import contextlib
import copy
import inspect
import io
import unittest
from dataclasses import dataclass
from unittest import mock

import _loader  # noqa: F401 - adds poc/network-inspect/ to sys.path

import capabilities
import desired_state
import inventory_build
import net_facts
import plan_ir
import plan_validator
import planner
import renderers.nginx as nginx_renderer
import executors.core as core
import executors.nginx as nginx_executor
from test_planner import _doc, _svc, _inventory, _registry, _NGINX_TCP_FULL


# ─────────────────────────────────────────────────────────────────────
# Fixtures
# ─────────────────────────────────────────────────────────────────────

def _art(artifact_id, kind="fake_kind", name=None, content=None):
    return nginx_renderer.Artifact(
        artifact_id, kind, name if name is not None else artifact_id,
        content if content is not None else f"NEW:{artifact_id}")


def _rr(*artifacts, provider="fake", valid=True, diagnostics=None):
    return nginx_renderer.RenderResult(valid, provider, list(artifacts), list(diagnostics or []))


def _fake_rr(*ids):
    return _rr(*[_art(i) for i in ids])


def _codes(result):
    return [d.code for d in result.diagnostics]


class FakePolicy:
    """Provider-independent stand-in for a ProviderExecutor."""
    def __init__(self, provider="fake", kinds=("fake_kind",)):
        self.provider = provider
        self.kinds = kinds

    def structural_preflight(self, artifacts):
        return [core.Diagnostic("unsupported_artifact_kind", "error", a.artifact_id,
                                f"$.artifacts[{i}].target_kind", f"kind {a.target_kind!r}")
                for i, a in enumerate(artifacts) if a.target_kind not in self.kinds]


class FakePort:
    """In-memory ExecutionPort. `host` maps artifact_id -> content. A
    backup handle is simply the old content. Failures are injected per
    (operation, artifact_id-or-None)."""

    def __init__(self, ids, fail=None, partial=(), preflight=(), verify=(), provider="fake"):
        self.provider = provider
        self.host = {i: f"OLD:{i}" for i in ids}
        self.initial = dict(self.host)
        self.calls = []
        self.fail = dict(fail or {})
        self.partial = set(partial)          # apply() writes garbage, THEN raises
        self.preflight_result = list(preflight)
        self.verify_result = list(verify)

    def _maybe_fail(self, op, key):
        exc = self.fail.get((op, key))
        if exc is not None:
            raise exc

    def runtime_preflight(self, artifacts):
        self.calls.append(("runtime_preflight", tuple(a.artifact_id for a in artifacts)))
        self._maybe_fail("runtime_preflight", None)
        return self.preflight_result

    def backup(self, artifact):
        self.calls.append(("backup", artifact.artifact_id))
        self._maybe_fail("backup", artifact.artifact_id)
        return self.host[artifact.artifact_id]

    def apply(self, artifact):
        self.calls.append(("apply", artifact.artifact_id))
        if artifact.artifact_id in self.partial:
            self.host[artifact.artifact_id] = "PARTIAL"
        self._maybe_fail("apply", artifact.artifact_id)
        self.host[artifact.artifact_id] = artifact.content

    def verify(self, artifacts):
        self.calls.append(("verify", tuple(a.artifact_id for a in artifacts)))
        self._maybe_fail("verify", None)
        return self.verify_result

    def restore(self, artifact, backup):
        self.calls.append(("restore", artifact.artifact_id))
        self._maybe_fail("restore", artifact.artifact_id)
        self.host[artifact.artifact_id] = backup


def _run(ids, fail=None, partial=(), preflight=(), verify=(), order=None):
    """Execute a fake-provider RenderResult for `order or ids` against a
    fake port whose host holds `ids`. Returns (result, port)."""
    port = FakePort(ids, fail=fail, partial=partial, preflight=preflight, verify=verify)
    result = core.execute(_fake_rr(*(order or ids)), FakePolicy(), port)
    return result, port


def _diag(code, severity="error", resource_id=None):
    return core.Diagnostic(code, severity, resource_id, "$.x", f"{code} message")


def _svc_entry(service_id, ip="203.0.113.10", port=443, sni=None, backend_port=8443):
    return plan_ir.build_service_entry(
        service_id, "colocated", "create", "none",
        plan_ir.build_listener("tcp", ip, port), plan_ir.build_routing("sni", sni or []), [],
        "not_supported", plan_ir.build_backend("tcp", backend_port))


def _real_render(*service_ids):
    plan = plan_ir.assemble([plan_ir.build_group("SHARED_TCP_SNI", "nginx", [
        _svc_entry(sid, sni=[f"{sid}.example.com"], backend_port=8000 + n)
        for n, sid in enumerate(service_ids)])])
    rr = nginx_renderer.render(plan)
    assert rr.valid, rr.diagnostics
    return rr


# ─────────────────────────────────────────────────────────────────────
# 1. Valid RenderResult enters preparation
# ─────────────────────────────────────────────────────────────────────

class TestPrepare(unittest.TestCase):
    def test_real_renderer_output_is_structurally_executable(self):
        result = core.prepare(_real_render("a", "b"), nginx_executor.NginxExecutor())
        self.assertTrue(result.valid, result.diagnostics)
        self.assertEqual(result.status, "prepared")
        self.assertEqual(result.provider, "nginx")
        self.assertIsNone(result.failed_phase)
        self.assertEqual(result.diagnostics, [])
        self.assertEqual(result.applied_artifacts, [])
        self.assertEqual(result.restored_artifacts, [])
        self.assertFalse(result.rollback_available)   # nothing was backed up in a dry run

    def test_planner_to_renderer_to_executor_end_to_end(self):
        doc = _doc(
            _svc("xray", sharing="required", tls={"mode": "passthrough", "sni_values": ["xray.example.com"]},
                 backend_hint={"loopback_port": 8443}),
            _svc("web", sharing="required", ip_selection="same_as_service", same_as="xray",
                 tls={"mode": "termination", "sni_values": ["web.example.com"]}, backend_hint={"loopback_port": 7443}),
        )
        planned = planner.plan(_inventory(), _registry(nginx=_NGINX_TCP_FULL), doc)
        self.assertEqual(planned["outcome"], "planned")
        rr = nginx_renderer.render(planned["plan_ir"])
        self.assertTrue(rr.valid, rr.diagnostics)
        result = core.prepare(rr, nginx_executor.NginxExecutor())
        self.assertEqual(result.status, "prepared", result.diagnostics)

    def test_nginx_executor_is_pinned_to_the_renderers_contract(self):
        rr = _real_render("a", "b")
        self.assertEqual(nginx_executor.PROVIDER, nginx_renderer.PROVIDER)
        self.assertEqual(nginx_executor.NginxExecutor.provider, rr.provider)
        for art in rr.artifacts:
            self.assertIn(art.target_kind, nginx_executor.NginxExecutor.supported_target_kinds)

    def test_prepare_needs_no_port(self):
        # dry run is callable with only a provider executor
        self.assertEqual(core.prepare(_fake_rr("A"), FakePolicy()).status, "prepared")

    def test_prepare_has_no_way_to_reach_a_port(self):
        # the dry run is structurally incapable of mutation: its signature carries no port
        self.assertEqual(list(inspect.signature(core.prepare).parameters), ["render_result", "provider_executor"])


# ─────────────────────────────────────────────────────────────────────
# 2. Invalid RenderResult is rejected before apply
# ─────────────────────────────────────────────────────────────────────

class TestRenderResultRejection(unittest.TestCase):
    def _assert_rejected_without_port_calls(self, rr, code, policy=None, phase="prepare"):
        policy = policy or FakePolicy()
        port = FakePort(["A", "B"], provider=policy.provider)
        result = core.execute(rr, policy, port)
        self.assertFalse(result.valid)
        self.assertEqual(result.status, "validation_failed")
        self.assertEqual(result.failed_phase, phase)
        self.assertIn(code, _codes(result))
        self.assertEqual(port.calls, [], "no port operation may run for a rejected RenderResult")
        self.assertEqual(port.host, port.initial)
        self.assertEqual(result.applied_artifacts, [])
        self.assertFalse(result.rollback_available)
        return result

    def test_invalid_render_result_is_rejected(self):
        bad = _rr(valid=False, diagnostics=[nginx_renderer.Diagnostic(
            "missing_backend", "error", "svc", "$.backend", "no backend")])
        result = self._assert_rejected_without_port_calls(bad, "invalid_render_result")
        self.assertIn("missing_backend", result.diagnostics[0].message)   # renderer's reason is surfaced

    def test_partial_render_result_with_artifacts_is_still_rejected(self):
        # Renderer semantics: one group rendered, another failed -> valid=False
        # WITH an artifact present. Nothing may be applied.
        partial = _rr(_art("A"), valid=False, diagnostics=[nginx_renderer.Diagnostic(
            "malformed_group", "error", "g2", "$.services", "broken")])
        self._assert_rejected_without_port_calls(partial, "invalid_render_result")

    def test_valid_flag_with_error_diagnostics_is_inconsistent(self):
        liar = _rr(_art("A"), valid=True, diagnostics=[nginx_renderer.Diagnostic(
            "missing_backend", "error", "svc", "$.backend", "no backend")])
        self._assert_rejected_without_port_calls(liar, "inconsistent_render_result")

    def test_valid_render_result_with_only_warnings_is_accepted(self):
        ok = _rr(_art("A"), diagnostics=[nginx_renderer.Diagnostic("note", "warning", None, None, "fyi")])
        self.assertEqual(core.prepare(ok, FakePolicy()).status, "prepared")

    def test_non_dataclass_render_results_are_malformed(self):
        for label, obj in (("None", None), ("dict", {"valid": True, "provider": "fake", "artifacts": [],
                                                     "diagnostics": []}), ("object", object())):
            with self.subTest(label):
                self._assert_rejected_without_port_calls(obj, "malformed_render_result")

    def test_render_result_missing_a_field_is_malformed(self):
        @dataclass
        class NoDiagnostics:
            valid: bool
            provider: str
            artifacts: list
        self._assert_rejected_without_port_calls(NoDiagnostics(True, "fake", [_art("A")]), "malformed_render_result")

    def test_render_result_with_unexpected_field_is_rejected(self):
        @dataclass
        class Grown:
            valid: bool
            provider: str
            artifacts: list
            diagnostics: list
            rollback_plan: str
        self._assert_rejected_without_port_calls(Grown(True, "fake", [_art("A")], [], "x"),
                                                 "unexpected_render_result_field")

    def test_wrongly_typed_render_result_fields_are_malformed(self):
        for label, rr in (
            ("valid not bool", nginx_renderer.RenderResult("yes", "fake", [_art("A")], [])),
            ("provider empty", nginx_renderer.RenderResult(True, "", [_art("A")], [])),
            ("provider not str", nginx_renderer.RenderResult(True, None, [_art("A")], [])),
            ("artifacts not list", nginx_renderer.RenderResult(True, "fake", "oops", [])),
            ("diagnostics not list", nginx_renderer.RenderResult(True, "fake", [_art("A")], None)),
        ):
            with self.subTest(label):
                self._assert_rejected_without_port_calls(rr, "malformed_render_result")

    def test_render_result_without_artifacts_is_rejected(self):
        # Deliberate fail-closed choice: nothing to execute is a caller decision, not a commit.
        self._assert_rejected_without_port_calls(_rr(), "no_artifacts")

    def test_unsupported_provider_is_rejected(self):
        rr = _rr(_art("A"), provider="caddy_l4")
        result = self._assert_rejected_without_port_calls(rr, "unsupported_provider")
        self.assertEqual(result.provider, "caddy_l4")   # the input's provider is reported, not the executor's

    def test_real_nginx_render_result_for_wrong_provider_executor(self):
        self._assert_rejected_without_port_calls(_real_render("a", "b"), "unsupported_provider",
                                                 policy=FakePolicy(provider="caddy_l4"))


# ─────────────────────────────────────────────────────────────────────
# 3 / 4 / 5. Artifact contract
# ─────────────────────────────────────────────────────────────────────

class TestArtifactContract(unittest.TestCase):
    def _prepare(self, *artifacts, policy=None):
        return core.prepare(_rr(*artifacts), policy or FakePolicy())

    def test_non_dataclass_artifact_is_malformed(self):
        for label, obj in (("dict", {"artifact_id": "A", "target_kind": "fake_kind",
                                     "target_name": "A", "content": "x"}), ("None", None), ("str", "A")):
            with self.subTest(label):
                result = self._prepare(obj)
                self.assertEqual(result.status, "validation_failed")
                self.assertEqual(_codes(result), ["malformed_artifact"])
                self.assertEqual(result.diagnostics[0].field, "$.artifacts[0]")

    def test_missing_required_metadata_is_rejected(self):
        for missing in ("artifact_id", "target_kind", "target_name", "content"):
            with self.subTest(missing):
                names = [n for n in ("artifact_id", "target_kind", "target_name", "content") if n != missing]
                partial_cls = dataclass(type("Partial", (), {"__annotations__": {n: str for n in names}}))
                art = partial_cls(**{n: "v" for n in names})
                result = self._prepare(art)
                self.assertEqual(_codes(result), ["missing_artifact_field"])
                self.assertEqual(result.diagnostics[0].field, f"$.artifacts[0].{missing}")

    def test_empty_or_mistyped_fields_are_rejected(self):
        cases = {
            "empty content": _art("A", content=""),
            "blank content": _art("A", content="  \n\t "),
            "empty artifact_id": _art("", name="n"),
            "empty target_kind": _art("A", kind=""),
            "empty target_name": nginx_renderer.Artifact("A", "fake_kind", "", "x"),
            "None target_name": nginx_renderer.Artifact("A", "fake_kind", None, "x"),
            "int content": nginx_renderer.Artifact("A", "fake_kind", "A", 42),
        }
        for label, art in cases.items():
            with self.subTest(label):
                result = self._prepare(art)
                self.assertEqual(result.status, "validation_failed")
                self.assertEqual(_codes(result), ["invalid_artifact_field"])

    def test_control_characters_in_identifiers_are_rejected(self):
        for label, art in (
            ("newline id", _art("A\nB", name="n")),
            ("NUL name", nginx_renderer.Artifact("A", "fake_kind", "a\x00b", "x")),
            ("tab kind", nginx_renderer.Artifact("A", "fake\tkind", "A", "x")),
        ):
            with self.subTest(label):
                self.assertEqual(_codes(self._prepare(art)), ["invalid_artifact_field"])

    def test_content_may_contain_newlines(self):
        self.assertEqual(self._prepare(_art("A", content="stream {\n}\n")).status, "prepared")

    def test_unexpected_artifact_field_is_rejected_not_ignored(self):
        @dataclass
        class WithMode:
            artifact_id: str
            target_kind: str
            target_name: str
            content: str
            mode: str
        result = self._prepare(WithMode("A", "fake_kind", "A", "x", "0644"))
        self.assertEqual(_codes(result), ["unexpected_artifact_field"])
        self.assertEqual(result.diagnostics[0].field, "$.artifacts[0].mode")

    def test_duplicate_artifact_ids_are_rejected(self):
        result = self._prepare(_art("A"), _art("B"), _art("A", name="other"))
        self.assertEqual(_codes(result), ["duplicate_artifact_id"])
        self.assertEqual(result.diagnostics[0].field, "$.artifacts[2].artifact_id")

    def test_all_bad_artifacts_are_reported_in_one_pass(self):
        result = self._prepare(_art("A", content=""), None, _art("C", kind=""))
        self.assertEqual(_codes(result), ["invalid_artifact_field", "malformed_artifact", "invalid_artifact_field"])

    def test_unsupported_artifact_kind_is_rejected(self):
        result = self._prepare(_art("A", kind="http_server_block"), policy=FakePolicy())
        self.assertEqual(_codes(result), ["unsupported_artifact_kind"])

    def test_provider_policy_errors_do_not_reach_the_port(self):
        port = FakePort(["A"])
        result = core.execute(_rr(_art("A", kind="weird")), FakePolicy(), port)
        self.assertEqual(result.status, "validation_failed")
        self.assertEqual(port.calls, [])

    def test_crashing_provider_policy_fails_closed(self):
        class Boom(FakePolicy):
            def structural_preflight(self, artifacts):
                raise RuntimeError("policy exploded")
        result = core.prepare(_fake_rr("A"), Boom())
        self.assertEqual(result.status, "validation_failed")
        self.assertEqual(_codes(result), ["structural_preflight_failed"])
        self.assertIn("policy exploded", result.diagnostics[0].message)

    def test_malformed_provider_policy_result_fails_closed(self):
        for label, bad in (("None", None), ("str", "ok"), ("junk entry", [object()])):
            with self.subTest(label):
                class Bad(FakePolicy):
                    def structural_preflight(self, artifacts, _bad=bad):
                        return _bad
                result = core.prepare(_fake_rr("A"), Bad())
                self.assertEqual(result.status, "validation_failed")
                self.assertEqual(_codes(result), ["structural_preflight_failed"])


class TestNginxExecutorPolicy(unittest.TestCase):
    def test_unsupported_kind_for_nginx(self):
        rr = _rr(_art("nginx:x", kind="nginx_http_server_block"), provider="nginx")
        result = core.prepare(rr, nginx_executor.NginxExecutor())
        self.assertEqual(_codes(result), ["unsupported_artifact_kind"])
        self.assertEqual(result.diagnostics[0].field, "$.artifacts[0].target_kind")

    def test_path_separators_in_target_name_are_rejected(self):
        for name in ("a/b", "..\\x", "/etc/passwd"):
            with self.subTest(name):
                rr = _rr(_art("nginx:x", kind="nginx_stream_server_block", name=name), provider="nginx")
                self.assertEqual(_codes(core.prepare(rr, nginx_executor.NginxExecutor())), ["invalid_target_name"])

    def test_group_id_style_names_are_accepted(self):
        rr = _rr(_art("nginx:a+b-c", kind="nginx_stream_server_block", name="a+b-c"), provider="nginx")
        self.assertEqual(core.prepare(rr, nginx_executor.NginxExecutor()).status, "prepared")

    def test_two_stream_blocks_are_refused(self):
        rr = _rr(_art("nginx:g1", kind="nginx_stream_server_block", name="g1"),
                 _art("nginx:g2", kind="nginx_stream_server_block", name="g2"), provider="nginx")
        result = core.prepare(rr, nginx_executor.NginxExecutor())
        self.assertEqual(result.status, "validation_failed")
        self.assertEqual(_codes(result), ["multiple_stream_blocks"])

    def test_two_group_renderer_output_is_refused_known_contract_gap(self):
        """DOCUMENTS A KNOWN UPSTREAM GAP, does not hide it: the Renderer
        emits a complete `stream {}` wrapper per group, and nginx rejects two
        top-level stream blocks ('"stream" directive is duplicate'). A
        genuinely valid multi-group Renderer result is therefore not
        applicable as independent artifacts."""
        plan = plan_ir.assemble([
            plan_ir.build_group("SHARED_TCP_SNI", "nginx", [
                _svc_entry("a", ip="203.0.113.10", sni=["a.example.com"]),
                _svc_entry("b", ip="203.0.113.10", sni=["b.example.com"])]),
            plan_ir.build_group("SHARED_TCP_SNI", "nginx", [
                _svc_entry("c", ip="203.0.113.11", sni=["c.example.com"]),
                _svc_entry("d", ip="203.0.113.11", sni=["d.example.com"])]),
        ])
        rr = nginx_renderer.render(plan)
        self.assertTrue(rr.valid, rr.diagnostics)
        self.assertEqual(len(rr.artifacts), 2)
        for art in rr.artifacts:
            self.assertTrue(art.content.startswith("stream {"))
        result = core.prepare(rr, nginx_executor.NginxExecutor())
        self.assertEqual(_codes(result), ["multiple_stream_blocks"])

    def test_executor_does_not_touch_artifact_content(self):
        rr = _real_render("a", "b")
        before = rr.artifacts[0].content
        core.prepare(rr, nginx_executor.NginxExecutor())
        self.assertIs(rr.artifacts[0].content, before)


# ─────────────────────────────────────────────────────────────────────
# Collaborator validation (fail-closed before any port operation)
# ─────────────────────────────────────────────────────────────────────

class TestCollaborators(unittest.TestCase):
    def test_port_missing_restore_is_rejected_before_any_operation(self):
        class NoRestore(FakePort):
            restore = None
        port = NoRestore(["A"])
        result = core.execute(_fake_rr("A"), FakePolicy(), port)
        self.assertEqual(result.status, "validation_failed")
        self.assertEqual(_codes(result), ["invalid_execution_port"])
        self.assertIn("restore", result.diagnostics[0].message)
        self.assertEqual(port.calls, [])

    def test_port_missing_every_operation_lists_them_all(self):
        class Bare:
            provider = "fake"
        result = core.execute(_fake_rr("A"), FakePolicy(), Bare())
        self.assertEqual(_codes(result), ["invalid_execution_port"])
        for op in ("runtime_preflight", "backup", "apply", "verify", "restore"):
            self.assertIn(op, result.diagnostics[0].message)

    def test_none_port_is_rejected(self):
        result = core.execute(_fake_rr("A"), FakePolicy(), None)
        self.assertEqual(result.status, "validation_failed")
        self.assertIn("invalid_execution_port", _codes(result))

    def test_port_provider_must_match_provider_executor(self):
        port = FakePort(["A"], provider="caddy_l4")
        result = core.execute(_fake_rr("A"), FakePolicy(), port)
        self.assertEqual(_codes(result), ["provider_mismatch"])
        self.assertEqual(port.calls, [])

    def test_invalid_provider_executor_is_rejected(self):
        result = core.prepare(_fake_rr("A"), object())
        self.assertEqual(result.status, "validation_failed")
        self.assertIn("invalid_provider_executor", _codes(result))


# ─────────────────────────────────────────────────────────────────────
# 6. Transaction state machine
# ─────────────────────────────────────────────────────────────────────

_PATH_TO = {
    "NEW": [],
    "PREPARED": ["PREPARED"],
    "VALIDATED": ["PREPARED", "VALIDATED"],
    "BACKED_UP": ["PREPARED", "VALIDATED", "BACKED_UP"],
    "APPLIED": ["PREPARED", "VALIDATED", "BACKED_UP", "APPLIED"],
    "VERIFIED": ["PREPARED", "VALIDATED", "BACKED_UP", "APPLIED", "VERIFIED"],
    "COMMITTED": ["PREPARED", "VALIDATED", "BACKED_UP", "APPLIED", "VERIFIED", "COMMITTED"],
}
_ALL_STATES = ["NEW", "PREPARED", "VALIDATED", "BACKED_UP", "APPLIED", "VERIFIED", "COMMITTED",
               "FAILED", "ROLLED_BACK"]


def _tx_at(state, failed_from=None):
    tx = core.Transaction()
    if state in ("FAILED", "ROLLED_BACK"):
        for s in _PATH_TO[failed_from]:
            tx.transition(s)
        tx.transition("FAILED")
        if state == "ROLLED_BACK":
            tx.transition("ROLLED_BACK")
    else:
        for s in _PATH_TO[state]:
            tx.transition(s)
    return tx


def _allowed(state, failed_from, dst):
    """Independently re-stated transition rules (deliberately NOT imported from core)."""
    forward = {"NEW": "PREPARED", "PREPARED": "VALIDATED", "VALIDATED": "BACKED_UP",
               "BACKED_UP": "APPLIED", "APPLIED": "VERIFIED", "VERIFIED": "COMMITTED"}
    if state in forward:
        return dst == forward[state] or (dst == "FAILED" and state != "VERIFIED")
    if state == "FAILED":
        return dst == "ROLLED_BACK" and failed_from in ("BACKED_UP", "APPLIED")
    return False   # COMMITTED, ROLLED_BACK are terminal


class TestTransaction(unittest.TestCase):
    def test_happy_path_walks_the_documented_states(self):
        tx = core.Transaction()
        self.assertEqual(tx.state, "NEW")
        for s in _PATH_TO["COMMITTED"]:
            tx.transition(s)
        self.assertEqual(tx.history, ("NEW", "PREPARED", "VALIDATED", "BACKED_UP", "APPLIED",
                                      "VERIFIED", "COMMITTED"))
        self.assertIsNone(tx.failed_phase)

    def test_every_transition_in_every_configuration_matches_the_table(self):
        configs = [(s, None) for s in _PATH_TO]
        configs += [("FAILED", f) for f in ("NEW", "PREPARED", "VALIDATED", "BACKED_UP", "APPLIED")]
        configs += [("ROLLED_BACK", f) for f in ("BACKED_UP", "APPLIED")]
        for state, failed_from in configs:
            for dst in _ALL_STATES:
                with self.subTest(state=state, failed_from=failed_from, dst=dst):
                    tx = _tx_at(state, failed_from)
                    if _allowed(state, failed_from, dst):
                        tx.transition(dst)
                        self.assertEqual(tx.state, dst)
                    else:
                        with self.assertRaises(core.InvalidTransition):
                            tx.transition(dst)
                        self.assertEqual(tx.state, state, "a rejected transition must not change state")

    def test_invalid_transition_message_is_deterministic(self):
        messages = []
        for _ in range(2):
            with self.assertRaises(core.InvalidTransition) as ctx:
                core.Transaction().transition("APPLIED")
            messages.append(str(ctx.exception))
        self.assertEqual(messages[0], messages[1])
        self.assertEqual(messages[0], "invalid transition NEW -> APPLIED")

    def test_unknown_state_is_rejected(self):
        with self.assertRaises(core.InvalidTransition):
            core.Transaction().transition("BOGUS")

    def test_cannot_skip_backup(self):
        tx = _tx_at("VALIDATED")
        with self.assertRaises(core.InvalidTransition):
            tx.transition("APPLIED")

    def test_terminal_states_accept_nothing(self):
        for tx in (_tx_at("COMMITTED"), _tx_at("ROLLED_BACK", "APPLIED")):
            for dst in _ALL_STATES:
                with self.assertRaises(core.InvalidTransition):
                    tx.transition(dst)

    def test_rollback_is_illegal_when_no_mutation_was_possible(self):
        for failed_from in ("NEW", "PREPARED", "VALIDATED"):
            with self.subTest(failed_from):
                with self.assertRaises(core.InvalidTransition):
                    _tx_at("FAILED", failed_from).transition("ROLLED_BACK")

    def test_failed_phase_is_derived_from_where_the_failure_happened(self):
        expected = {"NEW": "prepare", "PREPARED": "runtime_preflight", "VALIDATED": "backup",
                    "BACKED_UP": "apply", "APPLIED": "verify"}
        for failed_from, phase in expected.items():
            with self.subTest(failed_from):
                self.assertEqual(_tx_at("FAILED", failed_from).failed_phase, phase)
        # a rolled-back transaction still remembers what failed
        self.assertEqual(_tx_at("ROLLED_BACK", "APPLIED").failed_phase, "verify")


# ─────────────────────────────────────────────────────────────────────
# 7. Successful execution
# ─────────────────────────────────────────────────────────────────────

class TestExecuteSuccess(unittest.TestCase):
    def test_success_reaches_committed_semantics(self):
        result, port = _run(["A", "B", "C"])
        self.assertTrue(result.valid, result.diagnostics)
        self.assertEqual(result.status, "applied")
        self.assertIsNone(result.failed_phase)
        self.assertEqual(result.applied_artifacts, ["A", "B", "C"])
        self.assertEqual(result.restored_artifacts, [])
        self.assertTrue(result.rollback_available)     # backups exist, none consumed
        self.assertEqual(port.host, {i: f"NEW:{i}" for i in "ABC"})

    def test_phase_ordering_backup_all_then_apply_all_then_verify(self):
        _, port = _run(["A", "B", "C"])
        self.assertEqual(port.calls, [
            ("runtime_preflight", ("A", "B", "C")),
            ("backup", "A"), ("backup", "B"), ("backup", "C"),
            ("apply", "A"), ("apply", "B"), ("apply", "C"),
            ("verify", ("A", "B", "C")),
        ])

    def test_no_restore_on_success(self):
        _, port = _run(["A", "B"])
        self.assertNotIn("restore", [c[0] for c in port.calls])

    def test_content_reaches_the_port_byte_identical(self):
        seen = []
        class Recording(FakePort):
            def apply(self, artifact):
                seen.append(artifact)
                super().apply(artifact)
        rr = _rr(_art("A", content="stream {\r\n  # ünïcode ✓\n}\n"), _art("B", content=" leading\tand trailing \n\n"))
        originals = [a.content for a in rr.artifacts]
        core.execute(rr, FakePolicy(), Recording(["A", "B"]))
        self.assertEqual([a.content for a in seen], originals)

    def test_runtime_preflight_warnings_pass_through_and_do_not_block(self):
        result, _ = _run(["A"], preflight=[_diag("owner_differs", "warning", "A")])
        self.assertEqual(result.status, "applied")
        self.assertEqual(_codes(result), ["owner_differs"])
        self.assertEqual(len(result.warnings()), 1)
        self.assertEqual(result.errors(), [])

    def test_prepared_artifacts_are_immutable_snapshots(self):
        seen = []
        class Recording(FakePort):
            def apply(self, artifact):
                seen.append(artifact)
                super().apply(artifact)
        core.execute(_fake_rr("A"), FakePolicy(), Recording(["A"]))
        with self.assertRaises(Exception):
            seen[0].content = "tampered"


# ─────────────────────────────────────────────────────────────────────
# 8 / 9 / 10 / 11 / 13. Failure semantics
# ─────────────────────────────────────────────────────────────────────

class TestRuntimePreflightAndBackupFailures(unittest.TestCase):
    def test_runtime_preflight_error_stops_before_any_backup(self):
        result, port = _run(["A", "B"], preflight=[_diag("target_not_allowed", resource_id="B")])
        self.assertFalse(result.valid)
        self.assertEqual(result.status, "validation_failed")
        self.assertEqual(result.failed_phase, "runtime_preflight")
        self.assertEqual(_codes(result), ["runtime_preflight_failed", "target_not_allowed"])
        self.assertEqual([c[0] for c in port.calls], ["runtime_preflight"])
        self.assertEqual(port.host, port.initial)
        self.assertFalse(result.rollback_available)

    def test_runtime_preflight_exception_fails_closed(self):
        result, port = _run(["A"], fail={("runtime_preflight", None): OSError("cannot stat target")})
        self.assertEqual(result.status, "validation_failed")
        self.assertEqual(result.failed_phase, "runtime_preflight")
        self.assertIn("OSError: cannot stat target", result.diagnostics[0].message)
        self.assertEqual([c[0] for c in port.calls], ["runtime_preflight"])

    def test_malformed_runtime_preflight_result_fails_closed(self):
        for label, bad in (("None", None), ("junk", [object()]),
                           ("bad severity", [core.Diagnostic("x", "fatal", None, None, "m")])):
            with self.subTest(label):
                port = FakePort(["A"])
                port.preflight_result = bad
                result = core.execute(_fake_rr("A"), FakePolicy(), port)
                self.assertEqual(result.status, "validation_failed")
                self.assertEqual(result.failed_phase, "runtime_preflight")
                self.assertEqual(_codes(result), ["runtime_preflight_failed"])
                self.assertEqual([c[0] for c in port.calls], ["runtime_preflight"])

    def test_backup_failure_means_nothing_was_applied_and_nothing_is_restored(self):
        result, port = _run(["A", "B", "C"], fail={("backup", "B"): OSError("disk full")})
        self.assertEqual(result.status, "validation_failed")
        self.assertEqual(result.failed_phase, "backup")
        self.assertEqual(_codes(result), ["backup_failed"])
        self.assertEqual(result.diagnostics[0].resource_id, "B")
        self.assertEqual(port.calls, [("runtime_preflight", ("A", "B", "C")), ("backup", "A"), ("backup", "B")])
        self.assertEqual(port.host, port.initial)
        self.assertEqual(result.applied_artifacts, [])
        self.assertFalse(result.rollback_available)


class TestApplyFailure(unittest.TestCase):
    def test_apply_failure_with_successful_rollback_restores_the_whole_host(self):
        result, port = _run(["A", "B", "C"], fail={("apply", "B"): RuntimeError("write failed")})
        self.assertFalse(result.valid)
        self.assertEqual(result.status, "rolled_back")
        self.assertEqual(result.failed_phase, "apply")
        # host is exactly as it was: A (applied) undone, B (failed) restored, C never touched
        self.assertEqual(port.host, port.initial)
        # C was never attempted, verify never ran
        self.assertNotIn(("apply", "C"), port.calls)
        self.assertNotIn("verify", [c[0] for c in port.calls])
        self.assertFalse(result.rollback_available)     # backups were consumed

    def test_later_failure_keeps_information_about_earlier_artifacts(self):
        result, _ = _run(["A", "B", "C"], fail={("apply", "C"): RuntimeError("boom")})
        self.assertEqual(result.status, "rolled_back")
        self.assertEqual(result.applied_artifacts, ["A", "B"])          # what had applied
        self.assertEqual(result.restored_artifacts, ["C", "B", "A"])    # what was undone, reverse order
        self.assertEqual(result.diagnostics[0].resource_id, "C")

    def test_rollback_covers_the_failed_artifact_which_may_be_partly_written(self):
        result, port = _run(["A", "B"], fail={("apply", "A"): RuntimeError("torn write")}, partial={"A"})
        self.assertEqual(result.status, "rolled_back")
        self.assertEqual(port.host, port.initial, "partial write of the failed artifact must be undone")
        self.assertEqual(result.applied_artifacts, [])
        self.assertEqual(result.restored_artifacts, ["A"])
        self.assertNotIn(("apply", "B"), port.calls)

    def test_restores_run_in_exact_reverse_order_of_attempts(self):
        _, port = _run(["A", "B", "C"], fail={("apply", "C"): RuntimeError("x")})
        self.assertEqual([c for c in port.calls if c[0] == "restore"],
                         [("restore", "C"), ("restore", "B"), ("restore", "A")])

    def test_primary_failure_diagnostic_comes_first_and_names_the_artifact(self):
        result, _ = _run(["A", "B"], fail={("apply", "B"): RuntimeError("write failed")})
        first = result.diagnostics[0]
        self.assertEqual((first.code, first.severity, first.resource_id), ("apply_failed", "error", "B"))
        self.assertIn("RuntimeError: write failed", first.message)

    def test_apply_failure_with_failed_rollback_ends_failed_not_rolled_back(self):
        result, port = _run(["A", "B"], fail={("apply", "B"): RuntimeError("write failed"),
                                              ("restore", "A"): OSError("restore blocked")})
        self.assertFalse(result.valid)
        self.assertEqual(result.status, "apply_failed")       # transaction stayed FAILED
        self.assertEqual(result.failed_phase, "apply")
        self.assertTrue(result.rollback_available, "backups still exist for a manual retry")
        self.assertNotEqual(port.host, port.initial, "host is knowingly not restored")


class TestVerificationFailure(unittest.TestCase):
    def test_verification_error_triggers_rollback_of_everything(self):
        result, port = _run(["A", "B", "C"], verify=[_diag("nginx_syntax_invalid", resource_id="B")])
        self.assertFalse(result.valid)
        self.assertEqual(result.status, "rolled_back")
        self.assertEqual(result.failed_phase, "verify")
        self.assertEqual(port.host, port.initial)
        self.assertEqual(result.applied_artifacts, ["A", "B", "C"])
        self.assertEqual(result.restored_artifacts, ["C", "B", "A"])
        self.assertEqual(_codes(result), ["verification_failed", "nginx_syntax_invalid"])
        self.assertFalse(result.rollback_available)

    def test_verification_exception_triggers_rollback(self):
        result, port = _run(["A", "B"], fail={("verify", None): RuntimeError("verifier crashed")})
        self.assertEqual(result.status, "rolled_back")
        self.assertEqual(result.failed_phase, "verify")
        self.assertEqual(port.host, port.initial)
        self.assertIn("RuntimeError: verifier crashed", result.diagnostics[0].message)

    def test_malformed_verification_result_is_a_failed_verification(self):
        port = FakePort(["A"])
        port.verify_result = None
        result = core.execute(_fake_rr("A"), FakePolicy(), port)
        self.assertEqual(result.status, "rolled_back")
        self.assertEqual(result.failed_phase, "verify")
        self.assertEqual(port.host, port.initial)

    def test_verification_warnings_alone_do_not_fail(self):
        result, _ = _run(["A"], verify=[_diag("slow_reload", "warning")])
        self.assertEqual(result.status, "applied")
        self.assertEqual(_codes(result), ["slow_reload"])

    def test_verification_failure_with_failed_rollback_ends_failed(self):
        result, port = _run(["A", "B"], verify=[_diag("nginx_syntax_invalid")],
                            fail={("restore", "A"): OSError("restore blocked")})
        self.assertEqual(result.status, "verification_failed")
        self.assertEqual(result.failed_phase, "verify")
        self.assertTrue(result.rollback_available)
        self.assertEqual(result.restored_artifacts, ["B"])


class TestRollbackRepresentation(unittest.TestCase):
    def test_successful_rollback_is_represented_as_rolled_back(self):
        result, _ = _run(["A", "B"], fail={("apply", "B"): RuntimeError("x")})
        self.assertEqual(result.status, "rolled_back")
        self.assertIn(result.status, core.STATUSES)
        self.assertFalse(result.valid)                   # a rollback is a clean failure, not a success
        self.assertEqual(result.errors()[0].code, "apply_failed")   # the cause is not erased

    def test_rollback_failure_preserves_primary_and_rollback_errors(self):
        result, _ = _run(["A", "B"], fail={("apply", "B"): RuntimeError("disk full"),
                                           ("restore", "A"): OSError("permission denied")})
        self.assertEqual(_codes(result), ["apply_failed", "rollback_failed"])
        primary, rollback = result.diagnostics
        self.assertIn("disk full", primary.message)
        self.assertEqual(primary.resource_id, "B")
        self.assertIn("permission denied", rollback.message)
        self.assertEqual(rollback.resource_id, "A")

    def test_rollback_continues_past_a_failed_restore(self):
        # restore order is B then A; B's restore fails, A must still be restored
        result, port = _run(["A", "B"], partial={"B"}, fail={("apply", "B"): RuntimeError("torn write"),
                                                             ("restore", "B"): OSError("stuck")})
        self.assertEqual(result.status, "apply_failed")
        self.assertEqual(result.restored_artifacts, ["A"])
        self.assertEqual(port.host["A"], "OLD:A")
        self.assertEqual(port.host["B"], "PARTIAL", "the artifact whose restore failed stays dirty")

    def test_every_failed_restore_is_reported(self):
        result, _ = _run(["A", "B", "C"], fail={("apply", "C"): RuntimeError("x"),
                                                ("restore", "A"): OSError("a"), ("restore", "B"): OSError("b")})
        self.assertEqual(_codes(result), ["apply_failed", "rollback_failed", "rollback_failed"])
        self.assertEqual([d.resource_id for d in result.diagnostics], ["C", "B", "A"])
        self.assertEqual(result.restored_artifacts, ["C"])

    def test_status_valid_and_phase_are_consistent_for_every_outcome(self):
        scenarios = {
            "success": _run(["A"])[0],
            "preflight": _run(["A"], preflight=[_diag("x")])[0],
            "backup": _run(["A"], fail={("backup", "A"): OSError("x")})[0],
            "apply rolled back": _run(["A"], fail={("apply", "A"): OSError("x")})[0],
            "apply stuck": _run(["A"], fail={("apply", "A"): OSError("x"), ("restore", "A"): OSError("y")})[0],
            "verify rolled back": _run(["A"], verify=[_diag("x")])[0],
            "verify stuck": _run(["A"], verify=[_diag("x")], fail={("restore", "A"): OSError("y")})[0],
            "dry run": core.prepare(_fake_rr("A"), FakePolicy()),
        }
        for label, result in scenarios.items():
            with self.subTest(label):
                self.assertIn(result.status, core.STATUSES)
                self.assertEqual(result.valid, result.status in ("prepared", "applied"))
                self.assertEqual(result.failed_phase is None, result.valid)
                self.assertEqual(bool(result.errors()), not result.valid)


# ─────────────────────────────────────────────────────────────────────
# 12 / 17. Determinism and ordering
# ─────────────────────────────────────────────────────────────────────

class TestOrderingAndDeterminism(unittest.TestCase):
    def test_executor_never_reorders_artifacts(self):
        # RenderResult order is the execution order, even when it is not sorted
        _, port = _run(["A", "B", "C"], order=["C", "A", "B"], fail={("apply", "B"): RuntimeError("x")})
        self.assertEqual([c[1] for c in port.calls if c[0] == "backup"], ["C", "A", "B"])
        self.assertEqual([c[1] for c in port.calls if c[0] == "apply"], ["C", "A", "B"])
        self.assertEqual([c[1] for c in port.calls if c[0] == "restore"], ["B", "A", "C"])

    def test_repeated_execution_of_the_same_input_is_deterministic(self):
        rr = _fake_rr("A", "B", "C")
        scenarios = {
            "success": {},
            "apply failure": {"fail": {("apply", "B"): RuntimeError("boom")}},
            "rollback failure": {"fail": {("apply", "B"): RuntimeError("boom"), ("restore", "A"): OSError("no")}},
            "verify failure": {"verify": [_diag("nginx_syntax_invalid", resource_id="A")]},
        }
        for label, kwargs in scenarios.items():
            with self.subTest(label):
                p1 = FakePort(["A", "B", "C"], **kwargs)
                p2 = FakePort(["A", "B", "C"], **kwargs)
                r1 = core.execute(rr, FakePolicy(), p1)
                r2 = core.execute(rr, FakePolicy(), p2)
                self.assertEqual(r1.as_dict(), r2.as_dict())
                self.assertEqual(p1.calls, p2.calls)
                self.assertEqual(p1.host, p2.host)

    def test_repeated_prepare_is_deterministic(self):
        rr = _real_render("a", "b", "c")
        policy = nginx_executor.NginxExecutor()
        self.assertEqual(core.prepare(rr, policy).as_dict(), core.prepare(rr, policy).as_dict())

    def test_rejection_diagnostics_are_deterministic(self):
        bad = _rr(_art("A", content=""), None, _art("A"), _art("C", kind=""))
        self.assertEqual(core.prepare(bad, FakePolicy()).as_dict(), core.prepare(bad, FakePolicy()).as_dict())

    def test_execute_the_same_render_result_twice_against_one_port_is_repeatable(self):
        rr = _fake_rr("A", "B")
        port = FakePort(["A", "B"])
        first = core.execute(rr, FakePolicy(), port)
        # second run backs up the *new* state; result shape is unchanged
        second = core.execute(rr, FakePolicy(), port)
        self.assertEqual(first.as_dict(), second.as_dict())

    def test_result_as_dict_shape(self):
        result, _ = _run(["A"], fail={("apply", "A"): RuntimeError("x")})
        self.assertEqual(set(result.as_dict()), {
            "valid", "provider", "status", "failed_phase", "diagnostics",
            "applied_artifacts", "restored_artifacts", "rollback_available"})
        self.assertIsInstance(result.as_dict()["diagnostics"][0], dict)


# ─────────────────────────────────────────────────────────────────────
# 14 / 15 / 16. No mutation, no side effects, RenderResult untouched
# ─────────────────────────────────────────────────────────────────────

def _all_scenarios():
    """Callables covering prepare, success, and every failure path."""
    yield lambda rr, ids: core.prepare(rr, FakePolicy())
    yield lambda rr, ids: core.execute(rr, FakePolicy(), FakePort(ids))
    yield lambda rr, ids: core.execute(rr, FakePolicy(), FakePort(ids, fail={("backup", ids[-1]): OSError("x")}))
    yield lambda rr, ids: core.execute(rr, FakePolicy(), FakePort(ids, fail={("apply", ids[-1]): OSError("x")}))
    yield lambda rr, ids: core.execute(rr, FakePolicy(), FakePort(ids, verify=[_diag("x")]))
    yield lambda rr, ids: core.execute(rr, FakePolicy(), FakePort(
        ids, verify=[_diag("x")], fail={("restore", ids[0]): OSError("y")}))
    yield lambda rr, ids: core.execute(_rr(valid=False), FakePolicy(), FakePort(ids))


class TestNoSideEffects(unittest.TestCase):
    IDS = ["A", "B", "C"]

    def test_execution_does_not_mutate_the_render_result(self):
        for n, run in enumerate(_all_scenarios()):
            with self.subTest(scenario=n):
                rr = _fake_rr(*self.IDS)
                before = copy.deepcopy(rr)
                artifact_objects = list(rr.artifacts)
                contents = [a.content for a in rr.artifacts]
                list_object = rr.artifacts
                run(rr, self.IDS)
                self.assertEqual(rr, before)
                self.assertIs(rr.artifacts, list_object)
                self.assertEqual(rr.artifacts, artifact_objects)
                for art, content in zip(rr.artifacts, contents):
                    self.assertIs(art.content, content)

    def test_no_filesystem_subprocess_or_network_primitive_is_ever_touched(self):
        targets = ["builtins.open", "os.replace", "os.rename", "os.remove", "os.unlink", "os.mkdir",
                   "os.makedirs", "os.system", "subprocess.Popen", "subprocess.run", "subprocess.call",
                   "socket.socket", "shutil.rmtree", "shutil.copy", "shutil.move"]
        with contextlib.ExitStack() as stack:
            mocks = {t: stack.enter_context(mock.patch(t)) for t in targets}
            for run in _all_scenarios():
                run(_fake_rr(*self.IDS), self.IDS)
            core.prepare(_real_render("a", "b"), nginx_executor.NginxExecutor())
        for target, m in mocks.items():
            self.assertFalse(m.called, f"{target} must never be used by the Executor foundation")

    def test_nothing_is_written_to_stdout_or_stderr(self):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            for run in _all_scenarios():
                run(_fake_rr(*self.IDS), self.IDS)
            core.prepare(_real_render("a", "b"), nginx_executor.NginxExecutor())
        self.assertEqual(out.getvalue(), "")
        self.assertEqual(err.getvalue(), "")

    def test_a_port_that_mutates_a_prepared_artifact_cannot_reach_the_render_result(self):
        class Evil(FakePort):
            def apply(self, artifact):
                try:
                    artifact.content = "tampered"
                except Exception:
                    pass
                super().apply(artifact)
        rr = _fake_rr("A")
        core.execute(rr, FakePolicy(), Evil(["A"]))
        self.assertEqual(rr.artifacts[0].content, "NEW:A")


# ─────────────────────────────────────────────────────────────────────
# Architectural boundary (AST-based, enforced)
# ─────────────────────────────────────────────────────────────────────

def _imported_top_level_names(module):
    tree = ast.parse(inspect.getsource(module))
    names = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            names.update(a.name.split(".")[0] for a in node.names)
        elif isinstance(node, ast.ImportFrom):
            names.add((node.module or "").split(".")[0])
    return names


class TestExecutorArchitecture(unittest.TestCase):
    EXECUTOR_MODULES = (core, nginx_executor)

    def test_core_imports_only_the_standard_library(self):
        self.assertLessEqual(_imported_top_level_names(core), {"__future__", "dataclasses", "typing"})

    def test_nginx_executor_imports_only_core_and_future(self):
        self.assertLessEqual(_imported_top_level_names(nginx_executor), {"__future__", "executors"})

    def test_no_forbidden_pipeline_imports(self):
        forbidden = {"planner", "desired_state", "inventory_build", "net_facts", "capabilities",
                     "plan_ir", "plan_validator", "renderers", "providers", "hysteria2_config",
                     "run_command"}
        for module in self.EXECUTOR_MODULES:
            self.assertFalse(_imported_top_level_names(module) & forbidden, module.__name__)

    def test_no_io_capable_or_dynamic_calls(self):
        forbidden_calls = {"open", "print", "eval", "exec", "compile", "__import__", "input"}
        for module in self.EXECUTOR_MODULES:
            tree = ast.parse(inspect.getsource(module))
            for node in ast.walk(tree):
                if isinstance(node, ast.Call) and isinstance(node.func, ast.Name):
                    self.assertNotIn(node.func.id, forbidden_calls, f"{module.__name__}: {node.func.id}()")

    def test_no_upstream_layer_imports_the_executor(self):
        upstream = (desired_state, capabilities, planner, plan_ir, plan_validator, nginx_renderer,
                    inventory_build, net_facts)
        for module in upstream:
            self.assertNotIn("executors", _imported_top_level_names(module),
                             f"{module.__name__} must not depend on the Executor (no reverse dependency)")

    def test_executor_source_does_not_call_upstream_stages(self):
        # belt and braces: no attribute access on names that would mean planning/validating/rendering
        for module in self.EXECUTOR_MODULES:
            source = inspect.getsource(module)
            tree = ast.parse(source)
            doc = ast.get_docstring(tree) or ""
            code = source.replace(doc, "")
            for forbidden in ("planner.", "plan_validator.", "desired_state.", "nginx_renderer.", "render("):
                self.assertNotIn(forbidden, code, f"{module.__name__}: {forbidden}")


if __name__ == "__main__":
    unittest.main()
