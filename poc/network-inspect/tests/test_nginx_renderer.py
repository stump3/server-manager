#!/usr/bin/env python3
"""
tests/test_nginx_renderer.py
================================

Focused tests for renderers/nginx.py — the first Provider Renderer.
Uses real Plan IR from planner.plan() wherever the scenario is one
Planner actually produces (mirrors test_planner.py's own fixtures,
including the TeleMT+Xray shared-listener case from test_31c), and
hand-built plan_ir.py fixtures (mirrors test_plan_validator.py's own
style) for structured-error cases that a valid Plan IR would never
contain — the Renderer's own contract to safely reject those, not
Planner's job to produce them.
"""

from __future__ import annotations

import unittest

import _loader  # noqa: F401 - adds poc/network-inspect/ to sys.path

import planner
import plan_ir
import renderers.nginx as nginx_renderer
from test_planner import _doc, _svc, _inventory, _registry, _NGINX_TCP_FULL


def _svc_entry(service_id, ip="203.0.113.10", port=443, sni=None, backend_port=8443,
               proxy_protocol="not_supported"):
    routing = plan_ir.build_routing("sni", sni if sni is not None else [])
    return plan_ir.build_service_entry(
        service_id, "colocated", "create", "none",
        plan_ir.build_listener("tcp", ip, port), routing, [], proxy_protocol,
        plan_ir.build_backend("tcp", backend_port),
    )


class TestHappyPath(unittest.TestCase):
    def test_minimal_shared_tcp_sni_group(self):
        doc = _doc(
            _svc("xray", sharing="required", tls={"mode": "passthrough", "sni_values": ["xray.example.com"]},
                 backend_hint={"loopback_port": 8443}),
            _svc("web", sharing="required", ip_selection="same_as_service", same_as="xray",
                 tls={"mode": "termination", "sni_values": ["web.example.com"]}, backend_hint={"loopback_port": 7443}),
        )
        result = planner.plan(_inventory(), _registry(nginx=_NGINX_TCP_FULL), doc)
        self.assertEqual(result["outcome"], "planned")
        rr = nginx_renderer.render(result["plan_ir"])
        self.assertTrue(rr.valid, rr.diagnostics)
        self.assertEqual(len(rr.artifacts), 1)
        self.assertEqual(rr.artifacts[0].target_kind, "nginx_stream_server_block")

    def test_multiple_services_share_one_listener(self):
        plan = plan_ir.assemble([plan_ir.build_group("SHARED_TCP_SNI", "nginx", [
            _svc_entry("a", sni=["a.example.com"], backend_port=8001),
            _svc_entry("b", sni=["b.example.com"], backend_port=8002),
            _svc_entry("c", sni=["c.example.com"], backend_port=8003),
        ])])
        rr = nginx_renderer.render(plan)
        self.assertTrue(rr.valid, rr.diagnostics)
        content = rr.artifacts[0].content
        self.assertEqual(content.count("listen 203.0.113.10:443;"), 1)
        for name in ("a", "b", "c"):
            self.assertIn(f"upstream {name} {{ server 127.0.0.1:800{1 + ord(name) - ord('a')}; }}", content)

    def test_multiple_sni_values_route_to_distinct_backends(self):
        plan = plan_ir.assemble([plan_ir.build_group("SHARED_TCP_SNI", "nginx", [
            _svc_entry("multi", sni=["one.example.com", "two.example.com"], backend_port=9001),
            _svc_entry("other", sni=["three.example.com"], backend_port=9002),
        ])])
        rr = nginx_renderer.render(plan)
        self.assertTrue(rr.valid, rr.diagnostics)
        content = rr.artifacts[0].content
        self.assertIn("one.example.com multi;", content)
        self.assertIn("two.example.com multi;", content)
        self.assertIn("three.example.com other;", content)

    def test_backend_address_and_port_rendered_exactly(self):
        plan = plan_ir.assemble([plan_ir.build_group("SHARED_TCP_SNI", "nginx", [
            _svc_entry("a", sni=["a.example.com"], backend_port=54321),
            _svc_entry("b", sni=["b.example.com"], backend_port=8443),
        ])])
        rr = nginx_renderer.render(plan)
        self.assertIn("upstream a { server 127.0.0.1:54321; }", rr.artifacts[0].content)
        self.assertIn("upstream b { server 127.0.0.1:8443; }", rr.artifacts[0].content)

    def test_listener_ip_and_port_rendered_exactly(self):
        plan = plan_ir.assemble([plan_ir.build_group("SHARED_TCP_SNI", "nginx", [
            _svc_entry("a", ip="198.51.100.7", port=9443, sni=["a.example.com"]),
            _svc_entry("b", ip="198.51.100.7", port=9443, sni=["b.example.com"]),
        ])])
        rr = nginx_renderer.render(plan)
        self.assertIn("listen 198.51.100.7:9443;", rr.artifacts[0].content)

    def test_proxy_protocol_rendered_when_required(self):
        plan = plan_ir.assemble([plan_ir.build_group("SHARED_TCP_SNI", "nginx", [
            _svc_entry("a", sni=["a.example.com"], proxy_protocol="required"),
            _svc_entry("b", sni=["b.example.com"], proxy_protocol="optional"),
        ])])
        rr = nginx_renderer.render(plan)
        self.assertIn("proxy_protocol on;", rr.artifacts[0].content)

    def test_proxy_protocol_omitted_when_not_needed(self):
        plan = plan_ir.assemble([plan_ir.build_group("SHARED_TCP_SNI", "nginx", [
            _svc_entry("a", sni=["a.example.com"], proxy_protocol="optional"),
            _svc_entry("b", sni=["b.example.com"], proxy_protocol="not_supported"),
        ])])
        rr = nginx_renderer.render(plan)
        self.assertNotIn("proxy_protocol", rr.artifacts[0].content)

    def test_empty_sni_becomes_default_branch(self):
        plan = plan_ir.assemble([plan_ir.build_group("SHARED_TCP_SNI", "nginx", [
            _svc_entry("a", sni=["a.example.com"]),
            _svc_entry("b", sni=[]),
        ])])
        rr = nginx_renderer.render(plan)
        self.assertTrue(rr.valid, rr.diagnostics)
        self.assertIn("default b;", rr.artifacts[0].content)

    def test_telemt_xray_regression_fixture_from_test_31c(self):
        """Same fixture as test_planner.py's test_31c — the currently
        valid single_ingress_path + compatible proxy_protocol shared
        listener scenario."""
        doc = _doc(
            _svc("xray-reality", sharing="required", tls={"mode": "passthrough", "sni_values": ["reality.example.com"]},
                 proxy_protocol={"accept": "optional"}, backend_hint={"loopback_port": 8443}),
            _svc("telemt", sharing="required", ip_selection="same_as_service", same_as="xray-reality",
                 tls={"mode": "passthrough", "sni_values": ["telemt-mask.example.com"]},
                 proxy_protocol={"accept": "required"}, exclusivity="single_ingress_path",
                 backend_hint={"loopback_port": 9443}),
        )
        result = planner.plan(_inventory(), _registry(nginx=_NGINX_TCP_FULL), doc)
        self.assertEqual(result["outcome"], "planned")
        rr = nginx_renderer.render(result["plan_ir"])
        self.assertTrue(rr.valid, rr.diagnostics)
        content = rr.artifacts[0].content
        self.assertIn("reality.example.com xray_reality;", content)
        self.assertIn("telemt-mask.example.com telemt;", content)
        self.assertIn("upstream xray_reality { server 127.0.0.1:8443; }", content)
        self.assertIn("upstream telemt { server 127.0.0.1:9443; }", content)
        self.assertIn("proxy_protocol on;", content)
        self.assertIn("listen 203.0.113.10:443;", content)


class TestStructuredErrors(unittest.TestCase):
    def test_missing_backend_is_structured_error(self):
        svc_a = _svc_entry("a", sni=["a.example.com"])
        svc_b = plan_ir.build_service_entry(
            "b", "colocated", "create", "none",
            plan_ir.build_listener("tcp", "203.0.113.10", 443),
            plan_ir.build_routing("sni", ["b.example.com"]), [], "not_supported", None,
        )
        plan = plan_ir.assemble([plan_ir.build_group("SHARED_TCP_SNI", "nginx", [svc_a, svc_b])])
        rr = nginx_renderer.render(plan)
        self.assertFalse(rr.valid)
        self.assertIn("missing_backend", [d.code for d in rr.diagnostics])
        self.assertEqual(rr.artifacts, [])

    def test_unsupported_backend_kind_is_structured_error(self):
        svc_a = _svc_entry("a", sni=["a.example.com"])
        svc_b = plan_ir.build_service_entry(
            "b", "colocated", "create", "none",
            plan_ir.build_listener("tcp", "203.0.113.10", 443),
            plan_ir.build_routing("sni", ["b.example.com"]), [], "not_supported",
            plan_ir.build_backend("udp", 8443),
        )
        plan = plan_ir.assemble([plan_ir.build_group("SHARED_TCP_SNI", "nginx", [svc_a, svc_b])])
        rr = nginx_renderer.render(plan)
        self.assertFalse(rr.valid)
        self.assertIn("unsupported_backend_kind", [d.code for d in rr.diagnostics])

    def test_unsupported_transport_is_structured_error(self):
        svc_a = plan_ir.build_service_entry(
            "a", "colocated", "create", "none", plan_ir.build_listener("udp", "203.0.113.10", 443),
            plan_ir.build_routing("sni", ["a.example.com"]), [], "not_supported",
            plan_ir.build_backend("udp", 8443),
        )
        svc_b = plan_ir.build_service_entry(
            "b", "colocated", "create", "none", plan_ir.build_listener("udp", "203.0.113.10", 443),
            plan_ir.build_routing("sni", ["b.example.com"]), [], "not_supported",
            plan_ir.build_backend("udp", 8444),
        )
        plan = plan_ir.assemble([plan_ir.build_group("SHARED_TCP_SNI", "nginx", [svc_a, svc_b])])
        rr = nginx_renderer.render(plan)
        self.assertFalse(rr.valid)
        self.assertIn("unsupported_transport", [d.code for d in rr.diagnostics])

    def test_ambiguous_default_sni_is_structured_error(self):
        plan = plan_ir.assemble([plan_ir.build_group("SHARED_TCP_SNI", "nginx", [
            _svc_entry("a", sni=[]),
            _svc_entry("b", sni=[]),
        ])])
        rr = nginx_renderer.render(plan)
        self.assertFalse(rr.valid)
        self.assertIn("ambiguous_default_sni_backend", [d.code for d in rr.diagnostics])

    def test_duplicate_sni_value_is_structured_error(self):
        plan = plan_ir.assemble([plan_ir.build_group("SHARED_TCP_SNI", "nginx", [
            _svc_entry("a", sni=["same.example.com"]),
            _svc_entry("b", sni=["same.example.com"]),
        ])])
        rr = nginx_renderer.render(plan)
        self.assertFalse(rr.valid)
        self.assertIn("duplicate_sni_value", [d.code for d in rr.diagnostics])

    def test_unsupported_topology_for_nginx_mechanism_is_structured_error(self):
        svc = _svc_entry("a", sni=["a.example.com"])
        plan = plan_ir.assemble([plan_ir.build_group("DIRECT_TCP", "nginx", [svc])])
        rr = nginx_renderer.render(plan)
        self.assertFalse(rr.valid)
        self.assertIn("unsupported_topology", [d.code for d in rr.diagnostics])

    def test_non_nginx_mechanism_is_silently_skipped_not_an_error(self):
        svc_a = plan_ir.build_service_entry(
            "a", "colocated", "create", "none", plan_ir.build_listener("udp", "203.0.113.10", 443),
            plan_ir.build_routing("quic_sni", None), ["udp.listen"], "not_supported",
            plan_ir.build_backend("udp", 9443),
        )
        svc_b = plan_ir.build_service_entry(
            "b", "colocated", "create", "none", plan_ir.build_listener("udp", "203.0.113.10", 443),
            plan_ir.build_routing("quic_sni", None), ["udp.listen"], "not_supported",
            plan_ir.build_backend("udp", 9444),
        )
        plan = plan_ir.assemble([plan_ir.build_group("SHARED_UDP_QUIC_SNI", "caddy_l4", [svc_a, svc_b])])
        rr = nginx_renderer.render(plan)
        self.assertTrue(rr.valid)
        self.assertEqual(rr.artifacts, [])
        self.assertEqual(rr.diagnostics, [])

    def test_mechanism_less_group_is_silently_skipped(self):
        svc = plan_ir.build_service_entry(
            "a", "colocated", "create", "none", plan_ir.build_listener("tcp", "203.0.113.10", 443),
            None, [], "not_supported", None,
        )
        plan = plan_ir.assemble([plan_ir.build_group("DIRECT_TCP", None, [svc])])
        rr = nginx_renderer.render(plan)
        self.assertTrue(rr.valid)
        self.assertEqual(rr.artifacts, [])

    def test_conflicting_listener_across_groups_is_structured_error(self):
        group1 = plan_ir.build_group("SHARED_TCP_SNI", "nginx", [
            _svc_entry("a", sni=["a.example.com"]), _svc_entry("b", sni=["b.example.com"]),
        ])
        group2 = plan_ir.build_group("SHARED_TCP_SNI", "nginx", [
            _svc_entry("c", sni=["c.example.com"]), _svc_entry("d", sni=["d.example.com"]),
        ])
        plan = plan_ir.assemble([group1, group2])
        rr = nginx_renderer.render(plan)
        self.assertFalse(rr.valid)
        self.assertIn("conflicting_listener_across_groups", [d.code for d in rr.diagnostics])

    def test_malformed_plan_is_structured_error(self):
        rr = nginx_renderer.render(["not", "a", "mapping"])
        self.assertFalse(rr.valid)
        self.assertIn("malformed_plan", [d.code for d in rr.diagnostics])

    def test_wrong_schema_version_is_structured_error(self):
        rr = nginx_renderer.render({"schema_version": "not-the-real-one", "groups": []})
        self.assertFalse(rr.valid)
        self.assertIn("unsupported_schema_version", [d.code for d in rr.diagnostics])


class TestDeterminism(unittest.TestCase):
    def test_render_is_byte_identical_across_repeated_calls(self):
        doc = _doc(
            _svc("xray", sharing="required", tls={"mode": "passthrough", "sni_values": ["xray.example.com"]},
                 backend_hint={"loopback_port": 8443}),
            _svc("web", sharing="required", ip_selection="same_as_service", same_as="xray",
                 tls={"mode": "termination", "sni_values": ["web.example.com"]}, backend_hint={"loopback_port": 7443}),
        )
        result = planner.plan(_inventory(), _registry(nginx=_NGINX_TCP_FULL), doc)
        r1 = nginx_renderer.render(result["plan_ir"])
        r2 = nginx_renderer.render(result["plan_ir"])
        self.assertEqual(r1.as_dict(), r2.as_dict())
        self.assertEqual(r1.artifacts[0].content, r2.artifacts[0].content)

    def test_does_not_mutate_plan_ir(self):
        plan = plan_ir.assemble([plan_ir.build_group("SHARED_TCP_SNI", "nginx", [
            _svc_entry("a", sni=["a.example.com"]), _svc_entry("b", sni=["b.example.com"]),
        ])])
        import copy
        before = copy.deepcopy(plan)
        nginx_renderer.render(plan)
        self.assertEqual(plan, before)


class TestNginxRendererArchitecture(unittest.TestCase):
    def _code_only_source(self):
        import inspect
        import ast
        source = inspect.getsource(nginx_renderer)
        tree = ast.parse(source)
        doc = ast.get_docstring(tree) or ""
        return source.replace(doc, "")

    def test_no_subprocess(self):
        code = self._code_only_source()
        for forbidden in ("import subprocess", "os.system", "subprocess.run", "subprocess.call"):
            self.assertNotIn(forbidden, code, forbidden)

    def test_no_shell_execution(self):
        code = self._code_only_source()
        for forbidden in ("os.popen", "shell=True", "eval(", "exec("):
            self.assertNotIn(forbidden, code, forbidden)

    def test_no_filesystem_mutation(self):
        code = self._code_only_source()
        for forbidden in ("open(", "os.remove", "os.unlink", "shutil.", "os.rename", "os.mkdir"):
            self.assertNotIn(forbidden, code, forbidden)

    def test_no_network_access(self):
        code = self._code_only_source()
        for forbidden in ("socket.", "http.client", "urllib", "requests."):
            self.assertNotIn(forbidden, code, forbidden)

    def test_no_forbidden_imports(self):
        import inspect
        source = inspect.getsource(nginx_renderer)
        for forbidden in ("import planner", "import inventory_build", "import capabilities",
                          "import desired_state", "from providers", "import run_command",
                          "import net_facts", "import hysteria2_config"):
            self.assertNotIn(forbidden, source, f"renderers/nginx.py must not import {forbidden!r}")

    def test_only_imports_plan_ir_and_stdlib(self):
        import ast
        import inspect
        tree = ast.parse(inspect.getsource(nginx_renderer))
        allowed_stdlib = {"re", "dataclasses", "typing", "__future__"}
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                for alias in node.names:
                    top = alias.name.split(".")[0]
                    self.assertIn(top, allowed_stdlib | {"plan_ir"}, f"unexpected import: {alias.name}")
            elif isinstance(node, ast.ImportFrom):
                top = (node.module or "").split(".")[0]
                self.assertIn(top, allowed_stdlib | {"plan_ir"}, f"unexpected import from: {node.module}")


class TestScopeContract(unittest.TestCase):
    """Proves RenderResult means (B): 'everything this renderer owns
    rendered successfully' — never (A) 'the entire Plan IR document
    was rendered'. A mixed plan containing both an nginx-mechanism
    group and a group this renderer does not own must render the
    nginx portion fully and simply omit the other, with valid=True
    reflecting only the nginx-owned outcome."""

    def test_mixed_plan_renders_nginx_portion_and_ignores_the_rest(self):
        nginx_group = plan_ir.build_group("SHARED_TCP_SNI", "nginx", [
            _svc_entry("a", sni=["a.example.com"]), _svc_entry("b", sni=["b.example.com"]),
        ])
        caddy_svc_a = plan_ir.build_service_entry(
            "hy2a", "colocated", "create", "none", plan_ir.build_listener("udp", "203.0.113.20", 443),
            plan_ir.build_routing("quic_sni", None), ["udp.listen"], "not_supported",
            plan_ir.build_backend("udp", 9001),
        )
        caddy_svc_b = plan_ir.build_service_entry(
            "hy2b", "colocated", "create", "none", plan_ir.build_listener("udp", "203.0.113.20", 443),
            plan_ir.build_routing("quic_sni", None), ["udp.listen"], "not_supported",
            plan_ir.build_backend("udp", 9002),
        )
        caddy_group = plan_ir.build_group("SHARED_UDP_QUIC_SNI", "caddy_l4", [caddy_svc_a, caddy_svc_b])
        plan = plan_ir.assemble([nginx_group, caddy_group])

        rr = nginx_renderer.render(plan)
        self.assertTrue(rr.valid)
        self.assertEqual(len(rr.artifacts), 1)
        self.assertEqual(rr.artifacts[0].target_name, nginx_group["group_id"])
        self.assertEqual(rr.diagnostics, [])
        # the caddy group's own identifiers must never leak into the
        # rendered nginx artifact or any diagnostic - proof this
        # renderer did not attempt to interpret it at all
        content = rr.artifacts[0].content
        self.assertNotIn("hy2a", content)
        self.assertNotIn("hy2b", content)

    def test_every_nginx_owned_group_is_never_silently_dropped(self):
        """Every group this renderer owns (mechanism == "nginx") must
        surface in either artifacts or diagnostics - never neither.
        Constructed with one renderable group and one malformed one to
        prove both outcomes are always accounted for."""
        good_group = plan_ir.build_group("SHARED_TCP_SNI", "nginx", [
            _svc_entry("a", sni=["a.example.com"]), _svc_entry("b", sni=["b.example.com"]),
        ])
        broken_group = plan_ir.build_group("SHARED_TCP_SNI", "nginx", [
            _svc_entry("c", ip="203.0.113.11", sni=["c.example.com"]),
        ])  # single service - structurally malformed for SHARED_TCP_SNI
        plan = plan_ir.assemble([good_group, broken_group])

        rr = nginx_renderer.render(plan)
        rendered_group_ids = {a.target_name for a in rr.artifacts}
        diagnosed_group_ids = {d.resource_id for d in rr.diagnostics}
        self.assertIn(good_group["group_id"], rendered_group_ids)
        self.assertIn(broken_group["group_id"], diagnosed_group_ids)
        # every nginx-owned group_id is accounted for somewhere
        for g in (good_group, broken_group):
            self.assertTrue(
                g["group_id"] in rendered_group_ids or g["group_id"] in diagnosed_group_ids,
                f"group {g['group_id']!r} vanished silently",
            )


if __name__ == "__main__":
    unittest.main()
