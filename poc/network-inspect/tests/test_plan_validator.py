#!/usr/bin/env python3
"""
poc/network-inspect/tests/test_plan_validator.py
====================================================

EXPERIMENTAL / RESEARCH POC — tests for plan_validator.py.

Entirely pure-function tests - plan_validator.py makes no subprocess
call and no file I/O, so every test here is a plain dict-in,
PlanValidationResult-out call. No mocking needed anywhere.

Two families of fixtures are used deliberately:
  - REAL Plan IR produced by calling planner.plan() end-to-end (for
    tests that should exercise a genuinely realistic artifact) - this
    file DOES import planner for fixture construction, but
    plan_validator.py itself never does (see
    TestPlanValidatorArchitecture, which checks the module under test,
    not this test file).
  - HAND-CRAFTED Plan IR built directly via plan_ir.py's own
    constructors, or as raw dicts, for tests that need to exercise a
    specific malformed/corrupted/adversarial shape a correctly-behaving
    Planner would never actually produce - this is the whole point of
    an independent Validator (defense in depth), so these fixtures are
    not a testing anti-pattern here.
"""

from __future__ import annotations

import copy
import unittest

import _loader  # noqa: F401 - adds poc/network-inspect/ to sys.path

import plan_validator
import plan_ir
import planner


# ─────────────────────────────────────────────────────────────────────
# Fixture builders - realistic, via planner.plan()
# ─────────────────────────────────────────────────────────────────────

def _inventory(listeners=None, public_ipv4_count=1, obfuscation="none", firewall="ufw"):
    addrs = [{"interface": "eth0", "address": f"203.0.113.{10+i}"} for i in range(public_ipv4_count)]
    return {
        "schema_version": "poc-2", "listeners": listeners or [],
        "firewall": {"authoritative_frontend": firewall},
        "detected_ingress": {"nginx": {"present": False}, "caddy": {"present": False}, "haproxy": {"present": False}},
        "hysteria2": {"obfuscation": {"effective_value": obfuscation}},
        "public_ipv4": {"status": "available", "count": len(addrs), "addresses": addrs},
    }


def _provider(present="available", **dims):
    caps = {d: {"status": s, "confidence": "verified_by_probe", "evidence": "t",
                "module": None, "module_version": None} for d, s in dims.items()}
    return {"provider": "x", "present": present, "capabilities": caps}


def _registry(**providers):
    return {"schema_version": "capabilities-1", "providers": providers}


_NGINX_TCP_FULL = _provider(**{
    "tcp.listen": "available", "tcp.proxy": "available", "tcp.sni_inspection": "available",
    "tcp.tls_passthrough": "available", "tcp.tls_termination": "available", "tcp.n_way_sni_routing": "available",
})
_CADDY_QUIC_FULL = _provider(**{
    "udp.listen": "available", "udp.proxy": "available", "udp.quic_inspection": "available",
    "udp.quic_sni_routing": "available", "udp.multi_backend_same_port": "available",
})


def _svc(id, transport="tcp", port_value=443, sharing="allowed", ip_selection="any_public",
          same_as=None, tls=None, quic=None):
    svc = {
        "id": id, "transport": transport, "exposure": "public",
        "port": {"selection": "specific", "value": port_value, "sharing": sharing},
        "ip": {"selection": ip_selection, "value": None, "same_as_service": same_as, "separate_from_service": None},
    }
    if tls is not None:
        svc["tls"] = tls
    if quic is not None:
        svc["quic"] = quic
    return svc


def _doc(*services, operator_preferences=None):
    d = {"schema_version": "desired-state-1", "services": list(services)}
    if operator_preferences:
        d["operator_preferences"] = operator_preferences
    return d


def _direct_tcp_plan_ir():
    doc = _doc(_svc("xray", tls={"mode": "passthrough"}))
    result = planner.plan(_inventory(), _registry(), doc)
    assert result["outcome"] == "planned", result
    return result["plan_ir"]


def _shared_tcp_plan_ir():
    doc = _doc(
        _svc("xray", sharing="required", tls={"mode": "passthrough"}),
        _svc("web", sharing="required", ip_selection="same_as_service", same_as="xray", tls={"mode": "termination"}),
    )
    result = planner.plan(_inventory(), _registry(nginx=_NGINX_TCP_FULL), doc)
    assert result["outcome"] == "planned", result
    return result["plan_ir"]


def _shared_udp_quic_plan_ir():
    doc = _doc(
        _svc("hy2", transport="udp", sharing="required", quic={"sni_routing": "passthrough", "migration_tolerant": True}),
        _svc("other", transport="udp", sharing="required", ip_selection="same_as_service", same_as="hy2",
             quic={"sni_routing": "passthrough", "migration_tolerant": True}),
    )
    result = planner.plan(_inventory(), _registry(caddy_l4=_CADDY_QUIC_FULL), doc)
    assert result["outcome"] == "planned", result
    return result["plan_ir"]


def _separate_ips_plan_ir_with_known_bug():
    """Reproduces a REAL, disclosed defect in the current planner.py:
    a SEPARATE_IPS group assigns the SAME resolved IP to every service
    in the group (see _resolve_group_ip's per-candidate, not
    per-service, resolution), defeating the entire purpose of
    'separate IPs'. This fixture exists specifically to prove the
    Validator catches it - this is a genuine finding from this round,
    not a hypothetical."""
    doc = _doc(
        _svc("a", sharing="allowed"),
        _svc("b", sharing="allowed"),
        operator_preferences={"ip_sharing_preference": "prefer_separate_ips"},
    )
    result = planner.plan(_inventory(public_ipv4_count=2), _registry(nginx=_NGINX_TCP_FULL), doc)
    assert result["outcome"] == "planned", result
    assert result["selected_topology"] == "SEPARATE_IPS", result["selected_topology"]
    return result["plan_ir"]


# ─────────────────────────────────────────────────────────────────────
# 1-2: valid minimal plan, invalid schema version
# ─────────────────────────────────────────────────────────────────────

class TestSchemaValidity(unittest.TestCase):
    def test_01_valid_minimal_plan(self):
        result = plan_validator.validate_plan(_direct_tcp_plan_ir())
        self.assertTrue(result.valid, result.diagnostics)
        self.assertEqual(result.diagnostics, [])

    def test_02_invalid_schema_version(self):
        plan = _direct_tcp_plan_ir()
        plan["schema_version"] = "plan-ir-999"
        result = plan_validator.validate_plan(plan)
        self.assertFalse(result.valid)
        self.assertIn("unsupported_schema_version", [d.code for d in result.diagnostics])

    def test_not_a_mapping(self):
        result = plan_validator.validate_plan(["not", "a", "plan"])
        self.assertFalse(result.valid)
        self.assertIn("not_a_mapping", [d.code for d in result.diagnostics])


# ─────────────────────────────────────────────────────────────────────
# 3-4: identity
# ─────────────────────────────────────────────────────────────────────

class TestIdentity(unittest.TestCase):
    def test_03_duplicate_resource_identity(self):
        plan = _shared_tcp_plan_ir()
        plan["groups"].append(copy.deepcopy(plan["groups"][0]))
        result = plan_validator.validate_plan(plan)
        self.assertFalse(result.valid)
        self.assertIn("duplicate_group_id", [d.code for d in result.diagnostics])

    def test_04_dangling_resource_reference_via_group_id_mismatch(self):
        plan = _direct_tcp_plan_ir()
        plan["groups"][0]["group_id"] = "not-the-real-id"
        result = plan_validator.validate_plan(plan)
        self.assertFalse(result.valid)
        self.assertIn("group_id_mismatch", [d.code for d in result.diagnostics])

    def test_service_id_in_multiple_groups(self):
        plan = _direct_tcp_plan_ir()
        other_group = copy.deepcopy(plan["groups"][0])
        other_group["group_id"] = "xray-duplicate-group"
        plan["groups"].append(other_group)
        result = plan_validator.validate_plan(plan)
        self.assertFalse(result.valid)
        self.assertIn("service_id_in_multiple_groups", [d.code for d in result.diagnostics])

    def test_duplicate_service_id_within_one_group(self):
        plan = _direct_tcp_plan_ir()
        plan["groups"][0]["services"].append(copy.deepcopy(plan["groups"][0]["services"][0]))
        result = plan_validator.validate_plan(plan)
        self.assertFalse(result.valid)
        self.assertIn("duplicate_service_id_in_group", [d.code for d in result.diagnostics])


# ─────────────────────────────────────────────────────────────────────
# 5: conflicting CREATE, 6-9: invalid KEEP/REUSE/CHANGE/REMOVE
# ─────────────────────────────────────────────────────────────────────

class TestReconciliationConsistency(unittest.TestCase):
    def test_05_conflicting_create_same_endpoint_different_groups(self):
        svc_a = plan_ir.build_service_entry("a", "colocated", "create", "none",
                                             plan_ir.build_listener("tcp", "203.0.113.10", 443), None, [], "not_supported")
        svc_b = plan_ir.build_service_entry("b", "colocated", "create", "none",
                                             plan_ir.build_listener("tcp", "203.0.113.10", 443), None, [], "not_supported")
        plan = plan_ir.assemble([plan_ir.build_group("DIRECT_TCP", None, [svc_a]),
                                  plan_ir.build_group("DIRECT_TCP", None, [svc_b])])
        result = plan_validator.validate_plan(plan)
        self.assertFalse(result.valid)
        self.assertIn("cross_group_endpoint_collision", [d.code for d in result.diagnostics])

    def test_06_invalid_keep_with_mutation(self):
        svc = plan_ir.build_service_entry("a", "colocated", "keep", "parameter",
                                           plan_ir.build_listener("tcp", "203.0.113.10", 443), None, [], "not_supported")
        plan = plan_ir.assemble([plan_ir.build_group("DIRECT_TCP", None, [svc])])
        result = plan_validator.validate_plan(plan)
        self.assertFalse(result.valid)
        self.assertIn("action_change_scope_mismatch", [d.code for d in result.diagnostics])

    def test_07_invalid_reuse_with_mutation(self):
        svc = plan_ir.build_service_entry("a", "colocated", "reuse", "topology",
                                           plan_ir.build_listener("tcp", "203.0.113.10", 443), None, [], "not_supported")
        plan = plan_ir.assemble([plan_ir.build_group("DIRECT_TCP", None, [svc])])
        result = plan_validator.validate_plan(plan)
        self.assertFalse(result.valid)
        self.assertIn("action_change_scope_mismatch", [d.code for d in result.diagnostics])

    def test_08_invalid_change_with_no_scope(self):
        svc = plan_ir.build_service_entry("a", "colocated", "change", "none",
                                           plan_ir.build_listener("tcp", "203.0.113.10", 443), None, [], "not_supported")
        plan = plan_ir.assemble([plan_ir.build_group("DIRECT_TCP", None, [svc])])
        result = plan_validator.validate_plan(plan)
        self.assertFalse(result.valid)
        self.assertIn("action_change_scope_mismatch", [d.code for d in result.diagnostics])

    def test_09_invalid_remove_missing_confirmation(self):
        plan = _direct_tcp_plan_ir()
        plan["removals"] = [{"resource": "old-listener", "requires_explicit_confirmation": False}]
        result = plan_validator.validate_plan(plan)
        self.assertFalse(result.valid)
        self.assertIn("removal_missing_explicit_confirmation", [d.code for d in result.diagnostics])

    def test_10_remove_without_explicit_authorization_field_absent(self):
        plan = _direct_tcp_plan_ir()
        plan["removals"] = [{"resource": "old-listener"}]
        result = plan_validator.validate_plan(plan)
        self.assertFalse(result.valid)
        self.assertIn("removal_missing_explicit_confirmation", [d.code for d in result.diagnostics])

    def test_33_explicit_remove_with_authorization_is_valid(self):
        plan = _direct_tcp_plan_ir()
        plan["removals"] = [plan_ir.build_removal("some-old-resource")]
        result = plan_validator.validate_plan(plan)
        self.assertTrue(result.valid, result.diagnostics)


# ─────────────────────────────────────────────────────────────────────
# 11-12: duplicate (ip, port, transport)
# ─────────────────────────────────────────────────────────────────────

class TestEndpointConflicts(unittest.TestCase):
    def test_11_duplicate_ip_port_tcp(self):
        result = plan_validator.validate_plan(_separate_ips_plan_ir_with_known_bug())
        self.assertFalse(result.valid)
        self.assertIn("non_shared_group_endpoint_collision", [d.code for d in result.diagnostics])

    def test_12_duplicate_ip_port_udp(self):
        svc_a = plan_ir.build_service_entry("a", "colocated", "create", "none",
                                             plan_ir.build_listener("udp", "203.0.113.10", 443), None, [], "not_supported")
        svc_b = plan_ir.build_service_entry("b", "colocated", "create", "none",
                                             plan_ir.build_listener("udp", "203.0.113.10", 443), None, [], "not_supported")
        plan = plan_ir.assemble([plan_ir.build_group("SEPARATE_IPS", None, [svc_a, svc_b])])
        result = plan_validator.validate_plan(plan)
        self.assertFalse(result.valid)
        self.assertIn("non_shared_group_endpoint_collision", [d.code for d in result.diagnostics])


# ─────────────────────────────────────────────────────────────────────
# 13-16: sharing / exclusivity
# ─────────────────────────────────────────────────────────────────────

class TestSharingAndExclusivity(unittest.TestCase):
    def test_13_invalid_sharing_partner_shared_group_endpoint_mismatch(self):
        svc_a = plan_ir.build_service_entry("a", "colocated", "create", "none",
                                             plan_ir.build_listener("tcp", "203.0.113.10", 443), None, [], "not_supported")
        svc_b = plan_ir.build_service_entry("b", "colocated", "create", "none",
                                             plan_ir.build_listener("tcp", "203.0.113.11", 8443), None, [], "not_supported")
        plan = plan_ir.assemble([plan_ir.build_group("SHARED_TCP_SNI", "nginx", [svc_a, svc_b])])
        result = plan_validator.validate_plan(plan)
        self.assertFalse(result.valid)
        self.assertIn("shared_group_endpoint_mismatch", [d.code for d in result.diagnostics])

    def test_14b_shared_topology_single_service_is_flagged(self):
        """This round's targeted defect review (Finding 3) confirmed
        this is directly checkable from Plan IR alone (topology name +
        services array length, no additional schema information
        needed) and added shared_topology_requires_multiple_services
        as a minimal, additive validation rule — previously this
        shape passed silently (a genuine, disclosed limitation at the
        time); now it correctly fails."""
        svc = plan_ir.build_service_entry("a", "colocated", "create", "none",
                                           plan_ir.build_listener("tcp", "203.0.113.10", 443), None, [], "not_supported")
        plan = plan_ir.assemble([plan_ir.build_group("SHARED_TCP_SNI", "nginx", [svc])])
        result = plan_validator.validate_plan(plan)
        self.assertFalse(result.valid)
        self.assertIn("shared_topology_requires_multiple_services", [d.code for d in result.diagnostics])

    def test_14b_shared_topology_with_two_services_is_not_flagged(self):
        """Confirms the new rule only fires on the singleton case,
        never as a false positive on a genuinely-shared, correctly
        endpoint-matched pair."""
        svc_a = plan_ir.build_service_entry("a", "colocated", "create", "none",
                                             plan_ir.build_listener("tcp", "203.0.113.10", 443), None, [], "not_supported")
        svc_b = plan_ir.build_service_entry("b", "colocated", "create", "none",
                                             plan_ir.build_listener("tcp", "203.0.113.10", 443), None, [], "not_supported")
        plan = plan_ir.assemble([plan_ir.build_group("SHARED_TCP_SNI", "nginx", [svc_a, svc_b])])
        result = plan_validator.validate_plan(plan)
        self.assertTrue(result.valid, result.diagnostics)

    def test_15_forbidden_sharing_manifests_as_endpoint_collision(self):
        result = plan_validator.validate_plan(_separate_ips_plan_ir_with_known_bug())
        self.assertFalse(result.valid)

    def test_16_exclusive_ingress_conflict_subsumed_by_identity_check(self):
        plan = _shared_tcp_plan_ir()
        telemt_like = copy.deepcopy(plan["groups"][0])
        telemt_like["group_id"] = "duplicate-of-xray-web"
        plan["groups"].append(telemt_like)
        result = plan_validator.validate_plan(plan)
        self.assertFalse(result.valid)
        self.assertIn("service_id_in_multiple_groups", [d.code for d in result.diagnostics])


# ─────────────────────────────────────────────────────────────────────
# 17-21: TCP/UDP/QUIC safety invariants
# ─────────────────────────────────────────────────────────────────────

class TestTcpUdpQuicInvariants(unittest.TestCase):
    def test_17_tls_termination_passthrough_are_distinct_capability_names(self):
        """Confirmed structurally: Plan IR carries no tls.mode field at
        all on a service entry — TLS-mode intent is only representable
        via the distinct capability dimension NAMES
        tcp.tls_passthrough / tcp.tls_termination in
        required_capabilities, never a single ambiguous 'tls' flag.

        NOTE — a real, disclosed planner.py precision defect surfaced
        while writing this test (not fixed here, per this round's
        explicit instruction not to modify planner.py without a proven
        blocker; reported in the accompanying summary instead):
        planner.py's `_required_dimensions_for_group()` computes ONE
        dimension set for the WHOLE group and assigns that same union
        to EVERY service's required_capabilities — so in a mixed
        passthrough+termination group, `web` (termination) also
        incorrectly claims `tcp.tls_passthrough`, and `xray`
        (passthrough) also incorrectly claims `tcp.tls_termination`.
        This is not an internal Plan IR CONTRADICTION the Validator can
        detect on its own (there is no per-service tls.mode field left
        in the artifact to cross-check required_capabilities against —
        the imprecision is only visible by comparing against the
        original Desired State, which plan_validator.py is
        architecturally forbidden from importing). This test therefore
        only asserts what IS genuinely, always true regardless of that
        imprecision: each service's own correct dimension is present."""
        plan = _shared_tcp_plan_ir()
        caps_by_service = {s["service_id"]: set(s["required_capabilities"]) for g in plan["groups"] for s in g["services"]}
        self.assertIn("tcp.tls_passthrough", caps_by_service["xray"])
        self.assertIn("tcp.tls_termination", caps_by_service["web"])
        result = plan_validator.validate_plan(plan)
        self.assertTrue(result.valid, result.diagnostics)

    def test_18_sni_routing_without_topology_semantics(self):
        svc = plan_ir.build_service_entry("a", "colocated", "create", "none",
                                           plan_ir.build_listener("tcp", "203.0.113.10", 443),
                                           plan_ir.build_routing("sni", ["example.com"]),
                                           ["tcp.sni_inspection"], "not_supported")
        plan = plan_ir.assemble([plan_ir.build_group("DIRECT_TCP", None, [svc])])
        result = plan_validator.validate_plan(plan)
        self.assertFalse(result.valid)
        self.assertIn("routing_without_mechanism", [d.code for d in result.diagnostics])

    def test_18b_sni_routing_with_mismatched_topology(self):
        svc = plan_ir.build_service_entry("a", "colocated", "create", "none",
                                           plan_ir.build_listener("udp", "203.0.113.10", 443),
                                           plan_ir.build_routing("sni", ["example.com"]),
                                           ["tcp.sni_inspection"], "not_supported")
        plan = plan_ir.assemble([plan_ir.build_group("SHARED_UDP_QUIC_SNI", "caddy_l4", [svc])])
        result = plan_validator.validate_plan(plan)
        self.assertFalse(result.valid)
        self.assertIn("routing_topology_mismatch", [d.code for d in result.diagnostics])

    def test_19_proxy_protocol_enum_validity(self):
        svc = plan_ir.build_service_entry("a", "colocated", "create", "none",
                                           plan_ir.build_listener("tcp", "203.0.113.10", 443), None, [], "maybe")
        plan = plan_ir.assemble([plan_ir.build_group("DIRECT_TCP", None, [svc])])
        result = plan_validator.validate_plan(plan)
        self.assertFalse(result.valid)
        self.assertIn("invalid_proxy_protocol", [d.code for d in result.diagnostics])

    def test_20_quic_termination_never_substitutes_for_routing(self):
        svc_a = plan_ir.build_service_entry("a", "colocated", "create", "none",
                                             plan_ir.build_listener("udp", "203.0.113.10", 443), None,
                                             ["udp.listen", "udp.quic_sni_termination", "udp.multi_backend_same_port"], "not_supported")
        svc_b = plan_ir.build_service_entry("b", "colocated", "create", "none",
                                             plan_ir.build_listener("udp", "203.0.113.10", 443), None,
                                             ["udp.listen", "udp.quic_sni_termination", "udp.multi_backend_same_port"], "not_supported")
        plan = plan_ir.assemble([plan_ir.build_group("SHARED_UDP_QUIC_SNI", "haproxy", [svc_a, svc_b])])
        result = plan_validator.validate_plan(plan)
        self.assertFalse(result.valid)
        self.assertIn("quic_shared_missing_passthrough_dimension", [d.code for d in result.diagnostics])

    def test_21_migration_safety_violation_produces_warning_not_silent_pass(self):
        svc_a = plan_ir.build_service_entry("a", "colocated", "create", "none",
                                             plan_ir.build_listener("udp", "203.0.113.10", 443), None,
                                             ["udp.listen", "udp.quic_sni_routing", "udp.multi_backend_same_port"], "not_supported")
        svc_b = plan_ir.build_service_entry("b", "colocated", "create", "none",
                                             plan_ir.build_listener("udp", "203.0.113.10", 443), None,
                                             ["udp.listen", "udp.quic_sni_routing", "udp.multi_backend_same_port"], "not_supported")
        plan = plan_ir.assemble([plan_ir.build_group("SHARED_UDP_QUIC_SNI", "caddy_l4", [svc_a, svc_b])],
                                 warnings=[])
        result = plan_validator.validate_plan(plan)
        self.assertTrue(result.valid)
        self.assertTrue(any(d.code == "migration_risk_not_acknowledged_in_plan" and d.severity == "warning"
                             for d in result.diagnostics))

    def test_21b_migration_safety_acknowledged_via_real_planner_output(self):
        plan = _shared_udp_quic_plan_ir()
        result = plan_validator.validate_plan(plan)
        self.assertTrue(result.valid, result.diagnostics)
        self.assertFalse(any(d.code == "migration_risk_not_acknowledged_in_plan" for d in result.diagnostics))


# ─────────────────────────────────────────────────────────────────────
# 22-23: ownership safety (guaranteed by construction - documented)
# ─────────────────────────────────────────────────────────────────────

class TestOwnershipSafetyBoundary(unittest.TestCase):
    def test_22_unresolved_ownership_never_reaches_plan_ir(self):
        doc = _doc(_svc("a"))
        inv = _inventory(listeners=[{
            "proto": "tcp", "bind_port": 443, "bind_address": "0.0.0.0",
            "pid_unresolved_reason": "permission_denied", "owner": {"kind": "unknown"},
        }])
        result = planner.plan(inv, _registry(), doc)
        self.assertEqual(result["outcome"], "stopped")
        self.assertIsNone(result["plan_ir"])

    def test_23_unknown_ownership_never_produces_destructive_operation(self):
        plan = _direct_tcp_plan_ir()
        plan["removals"] = [{"resource": "unknown-owner-listener", "requires_explicit_confirmation": True}]
        result = plan_validator.validate_plan(plan)
        self.assertTrue(result.valid)


# ─────────────────────────────────────────────────────────────────────
# 24-26: determinism, no mutation
# ─────────────────────────────────────────────────────────────────────

class TestDeterminismAndPurity(unittest.TestCase):
    def test_24_deterministic_diagnostics(self):
        plan = _separate_ips_plan_ir_with_known_bug()
        results = [plan_validator.validate_plan(copy.deepcopy(plan)) for _ in range(10)]
        codes = [[d.code for d in r.diagnostics] for r in results]
        self.assertTrue(all(c == codes[0] for c in codes))

    def test_25_deterministic_valid_result(self):
        plan = _shared_tcp_plan_ir()
        results = [plan_validator.validate_plan(copy.deepcopy(plan)).valid for _ in range(10)]
        self.assertTrue(all(r is True for r in results))

    def test_26_no_mutation_of_input(self):
        plan = _shared_tcp_plan_ir()
        original = copy.deepcopy(plan)
        plan_validator.validate_plan(plan)
        self.assertEqual(plan, original)


# ─────────────────────────────────────────────────────────────────────
# 27-28: dependency graph (best-effort - see module docstring)
# ─────────────────────────────────────────────────────────────────────

class TestDependencies(unittest.TestCase):
    def test_empty_dependencies_always_pass(self):
        plan = _direct_tcp_plan_ir()
        self.assertEqual(plan["dependencies"], [])
        result = plan_validator.validate_plan(plan)
        self.assertTrue(result.valid)

    def test_27_dangling_dependency_reference(self):
        plan = _direct_tcp_plan_ir()
        gid = plan["groups"][0]["group_id"]
        plan["dependencies"] = [{"before": gid, "after": "nonexistent-group"}]
        result = plan_validator.validate_plan(plan)
        self.assertFalse(result.valid)
        self.assertIn("dangling_dependency_reference", [d.code for d in result.diagnostics])

    def test_28_dependency_cycle(self):
        doc = _doc(_svc("a", port_value=1111), _svc("b", port_value=2222))
        result = planner.plan(_inventory(), _registry(), doc)
        self.assertEqual(len(result["plan_ir"]["groups"]), 2)
        gid_a, gid_b = [g["group_id"] for g in result["plan_ir"]["groups"]]
        plan = result["plan_ir"]
        plan["dependencies"] = [{"before": gid_a, "after": gid_b}, {"before": gid_b, "after": gid_a}]
        vresult = plan_validator.validate_plan(plan)
        self.assertFalse(vresult.valid)
        self.assertIn("dependency_cycle", [d.code for d in vresult.diagnostics])

    def test_valid_acyclic_dependency_chain(self):
        doc = _doc(_svc("a", port_value=1111), _svc("b", port_value=2222))
        result = planner.plan(_inventory(), _registry(), doc)
        gid_a, gid_b = [g["group_id"] for g in result["plan_ir"]["groups"]]
        plan = result["plan_ir"]
        plan["dependencies"] = [{"before": gid_a, "after": gid_b}]
        vresult = plan_validator.validate_plan(plan)
        self.assertTrue(vresult.valid, vresult.diagnostics)


# ─────────────────────────────────────────────────────────────────────
# 29-32: malformed / empty / multiple / mixed
# ─────────────────────────────────────────────────────────────────────

class TestMalformedAndMixed(unittest.TestCase):
    def test_29_malformed_resource_missing_required_field(self):
        plan = _direct_tcp_plan_ir()
        del plan["groups"][0]["services"][0]["listener"]
        result = plan_validator.validate_plan(plan)
        self.assertFalse(result.valid)
        self.assertIn("invalid_listener", [d.code for d in result.diagnostics])

    def test_30_empty_plan_is_valid(self):
        plan = plan_ir.assemble([])
        result = plan_validator.validate_plan(plan)
        self.assertTrue(result.valid, result.diagnostics)

    def test_31_multiple_valid_resources(self):
        doc = _doc(_svc("a", port_value=1111), _svc("b", port_value=2222), _svc("c", port_value=3333))
        result = planner.plan(_inventory(), _registry(), doc)
        vresult = plan_validator.validate_plan(result["plan_ir"])
        self.assertTrue(vresult.valid, vresult.diagnostics)
        self.assertEqual(len(result["plan_ir"]["groups"]), 3)

    def test_32_mixed_keep_reuse_change_create(self):
        keep_svc = plan_ir.build_service_entry("keep-me", "colocated", "keep", "none",
                                                plan_ir.build_listener("tcp", "203.0.113.10", 111), None, [], "not_supported")
        reuse_svc = plan_ir.build_service_entry("reuse-me", "colocated", "reuse", "none",
                                                 plan_ir.build_listener("tcp", "203.0.113.10", 222), None, [], "not_supported")
        change_svc = plan_ir.build_service_entry("change-me", "colocated", "change", "parameter",
                                                  plan_ir.build_listener("tcp", "203.0.113.10", 333), None, [], "not_supported")
        create_svc = plan_ir.build_service_entry("create-me", "colocated", "create", "none",
                                                  plan_ir.build_listener("tcp", "203.0.113.10", 444), None, [], "not_supported")
        plan = plan_ir.assemble([
            plan_ir.build_group("DIRECT_TCP", None, [keep_svc]),
            plan_ir.build_group("DIRECT_TCP", None, [reuse_svc]),
            plan_ir.build_group("DIRECT_TCP", None, [change_svc]),
            plan_ir.build_group("DIRECT_TCP", None, [create_svc]),
        ])
        result = plan_validator.validate_plan(plan)
        self.assertTrue(result.valid, result.diagnostics)

    def test_34_identical_plans_produce_equivalent_results(self):
        plan1 = _shared_udp_quic_plan_ir()
        plan2 = copy.deepcopy(plan1)
        r1 = plan_validator.validate_plan(plan1)
        r2 = plan_validator.validate_plan(plan2)
        self.assertEqual(r1.as_dict(), r2.as_dict())


# ─────────────────────────────────────────────────────────────────────
# Architecture boundary
# ─────────────────────────────────────────────────────────────────────

class TestPlanValidatorArchitecture(unittest.TestCase):
    def _code_only_source(self):
        import inspect
        import ast
        source = inspect.getsource(plan_validator)
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

    def test_no_provider_name_branches(self):
        code = self._code_only_source()
        for forbidden in ('== "nginx"', '== "caddy_l4"', '== "haproxy"', '== "envoy"'):
            self.assertNotIn(forbidden, code, forbidden)

    def test_no_forbidden_imports(self):
        import inspect
        source = inspect.getsource(plan_validator)
        for forbidden in ("import planner", "import inventory_build", "import capabilities",
                          "import desired_state", "from providers", "import run_command",
                          "import net_facts", "import hysteria2_config"):
            self.assertNotIn(forbidden, source, f"plan_validator.py must not import {forbidden!r}")

    def test_only_imports_plan_ir_and_stdlib(self):
        import ast
        import inspect
        tree = ast.parse(inspect.getsource(plan_validator))
        allowed_stdlib = {"re", "dataclasses", "typing", "__future__"}
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                for alias in node.names:
                    top = alias.name.split(".")[0]
                    self.assertIn(top, allowed_stdlib | {"plan_ir"}, f"unexpected import: {alias.name}")
            elif isinstance(node, ast.ImportFrom):
                top = (node.module or "").split(".")[0]
                self.assertIn(top, allowed_stdlib | {"plan_ir"}, f"unexpected import from: {node.module}")


if __name__ == "__main__":
    unittest.main()
