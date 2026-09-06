#!/usr/bin/env python3
"""
poc/network-inspect/tests/test_planner.py
============================================

EXPERIMENTAL / RESEARCH POC — tests for planner.py + plan_ir.py.

Entirely pure-function tests — planner.py makes no subprocess call and
no file I/O, so every test here is a plain dict-in, dict-out call. No
mocking needed anywhere in this file.

Fixture builders (`_inventory`, `_registry`, `_provider`, `_svc`,
`_doc`) construct minimal, explicit, hand-built dicts matching the
real Inventory/Capability Registry/Desired State shapes exactly — no
shortcuts that would let a test pass against a shape Planner doesn't
actually receive in production.
"""

from __future__ import annotations

import copy
import unittest

import _loader  # noqa: F401 - adds poc/network-inspect/ to sys.path

import planner
import plan_ir
import desired_state as ds


# ─────────────────────────────────────────────────────────────────────
# Fixture builders
# ─────────────────────────────────────────────────────────────────────

def _inventory(listeners=None, public_ipv4_count=1, public_ipv4_addresses=None,
                obfuscation="none", firewall="ufw", **overrides):
    if public_ipv4_addresses is None:
        addrs = [{"interface": "eth0", "address": f"203.0.113.{10+i}"} for i in range(public_ipv4_count)]
    else:
        addrs = public_ipv4_addresses
    inv = {
        "schema_version": "poc-2",
        "generated_at": 0,
        "privilege": {"euid": 0, "is_root": True},
        "interfaces": {"available": True, "interfaces": []},
        "listeners": listeners or [],
        "firewall": {"authoritative_frontend": firewall, "backend": None, "detail": None},
        "detected_ingress": {
            "nginx": {"present": False}, "caddy": {"present": False}, "haproxy": {"present": False},
        },
        "hysteria2": {"obfuscation": {"effective_value": obfuscation}},
        "public_ipv4": {"status": "available", "count": len(addrs), "addresses": addrs},
        "warnings": [],
    }
    inv.update(overrides)
    return inv


def _listener(proto, port, address="0.0.0.0", pid_unresolved_reason=None, owner=None):
    return {
        "proto": proto, "bind_address": address, "bind_port": port,
        "state": "LISTEN", "inode": 1, "pid": None if pid_unresolved_reason else 999,
        "pid_unresolved_reason": pid_unresolved_reason,
        "process": None, "owner": owner or {"kind": "unknown"},
        "docker": None, "systemd": None, "public_exposure": "public",
    }


def _provider(present="available", **dims):
    caps = {}
    for dim, status in dims.items():
        caps[dim] = {"status": status, "confidence": "verified_by_probe", "evidence": "test fixture",
                     "module": None, "module_version": None}
    return {"provider": "x", "provider_version": "1.0", "present": present, "capabilities": caps}


def _registry(**providers):
    return {"schema_version": "capabilities-1", "generated_at": 0,
            "capability_dimensions": [], "providers": providers}


_NGINX_TCP_FULL = _provider(**{
    "tcp.listen": "available", "tcp.proxy": "available", "tcp.sni_inspection": "available",
    "tcp.tls_passthrough": "available", "tcp.tls_termination": "available", "tcp.n_way_sni_routing": "available",
})
_CADDY_QUIC_FULL = _provider(**{
    "udp.listen": "available", "udp.proxy": "available", "udp.quic_inspection": "available",
    "udp.quic_sni_routing": "available", "udp.multi_backend_same_port": "available",
})


def _svc(id, transport="tcp", port_selection="specific", port_value=443, sharing="allowed",
          ip_selection="any_public", ip_value=None, same_as=None, separate_from=None,
          tls=None, quic=None, proxy_protocol=None, exclusivity=None):
    svc = {
        "id": id, "transport": transport, "exposure": "public",
        "port": {"selection": port_selection, "value": port_value, "sharing": sharing},
        "ip": {"selection": ip_selection, "value": ip_value, "same_as_service": same_as,
               "separate_from_service": separate_from},
    }
    if port_selection == "any":
        svc["port"]["value"] = None
    if tls is not None:
        svc["tls"] = tls
    if quic is not None:
        svc["quic"] = quic
    if proxy_protocol is not None:
        svc["proxy_protocol"] = proxy_protocol
    if exclusivity is not None:
        svc["exclusivity"] = exclusivity
    return svc


def _doc(*services, operator_preferences=None):
    d = {"schema_version": "desired-state-1", "services": list(services)}
    if operator_preferences:
        d["operator_preferences"] = operator_preferences
    return d


def _assert_valid_ds(doc):
    result = ds.validate(doc)
    assert result.valid, f"test fixture itself is not valid Desired State: {result.errors}"


# ─────────────────────────────────────────────────────────────────────
# 1-4: direct / shared TCP / shared UDP
# ─────────────────────────────────────────────────────────────────────

class TestDirectAndShared(unittest.TestCase):
    def test_01_direct_tcp(self):
        doc = _doc(_svc("xray", tls={"mode": "passthrough"}))
        _assert_valid_ds(doc)
        result = planner.plan(_inventory(), _registry(), doc)
        self.assertEqual(result["outcome"], "planned")
        self.assertEqual(result["selected_topology"], "DIRECT_TCP")
        self.assertEqual(result["plan_ir"]["groups"][0]["services"][0]["action"], "create")

    def test_02_direct_udp(self):
        doc = _doc(_svc("hy2", transport="udp", quic={"sni_routing": "not_required"}))
        _assert_valid_ds(doc)
        result = planner.plan(_inventory(), _registry(), doc)
        self.assertEqual(result["outcome"], "planned")
        self.assertEqual(result["selected_topology"], "DIRECT_UDP")

    def test_03_shared_tcp_sni(self):
        doc = _doc(
            _svc("xray", sharing="required", tls={"mode": "passthrough"}),
            _svc("web", sharing="required", ip_selection="same_as_service", same_as="xray",
                 tls={"mode": "termination"}),
        )
        _assert_valid_ds(doc)
        result = planner.plan(_inventory(), _registry(nginx=_NGINX_TCP_FULL), doc)
        self.assertEqual(result["outcome"], "planned")
        self.assertEqual(result["selected_topology"], "SHARED_TCP_SNI")
        group = result["plan_ir"]["groups"][0]
        self.assertEqual(group["mechanism"], "nginx")
        self.assertEqual({s["service_id"] for s in group["services"]}, {"xray", "web"})

    def test_04_shared_udp_quic_sni(self):
        doc = _doc(
            _svc("hy2", transport="udp", sharing="required",
                 quic={"sni_routing": "passthrough", "migration_tolerant": True}),
            _svc("other", transport="udp", sharing="required", ip_selection="same_as_service", same_as="hy2",
                 quic={"sni_routing": "passthrough", "migration_tolerant": True}),
        )
        _assert_valid_ds(doc)
        result = planner.plan(_inventory(), _registry(caddy_l4=_CADDY_QUIC_FULL), doc)
        self.assertEqual(result["outcome"], "planned")
        self.assertEqual(result["selected_topology"], "SHARED_UDP_QUIC_SNI")
        self.assertTrue(any("migration" in w.lower() for w in result["plan_ir"]["warnings"]))


# ─────────────────────────────────────────────────────────────────────
# 5-6: separate ports, separate IPs
# ─────────────────────────────────────────────────────────────────────

class TestSeparatePortsAndIps(unittest.TestCase):
    def test_05_separate_ports_via_optional_pair_scoring(self):
        doc = _doc(
            _svc("a", port_value=8001, sharing="allowed"),
            _svc("b", port_value=8002, sharing="allowed"),
        )
        _assert_valid_ds(doc)
        result = planner.plan(_inventory(), _registry(nginx=_NGINX_TCP_FULL), doc)
        self.assertEqual(result["outcome"], "planned")
        topologies = {g["topology"] for g in result["plan_ir"]["groups"]}
        self.assertEqual(topologies, {"DIRECT_TCP"})

    def test_06_separate_ips_when_multiple_available(self):
        doc = _doc(
            _svc("a", port_value=443, sharing="allowed"),
            _svc("b", port_value=443, sharing="allowed"),
            operator_preferences={"ip_sharing_preference": "prefer_separate_ips"},
        )
        _assert_valid_ds(doc)
        result = planner.plan(_inventory(public_ipv4_count=2), _registry(nginx=_NGINX_TCP_FULL), doc)
        self.assertEqual(result["outcome"], "planned")
        topologies = {g["topology"] for g in result["plan_ir"]["groups"]}
        self.assertIn("SEPARATE_IPS", topologies)


# ─────────────────────────────────────────────────────────────────────
# 7-11: sharing semantics
# ─────────────────────────────────────────────────────────────────────

class TestSharingSemantics(unittest.TestCase):
    def test_07_required_without_partner_rejected_by_validator_before_planner(self):
        doc = _doc(_svc("lonely", sharing="required"))
        result = ds.validate(doc)
        self.assertFalse(result.valid)
        self.assertIn("sharing_required_no_partner", [e.code for e in result.errors])

    def test_08_required_with_incompatible_transport_partner(self):
        doc = {"schema_version": "desired-state-1", "services": [
            _svc("a", transport="tcp", sharing="required"),
            _svc("b", transport="udp", sharing="required", port_value=443),
        ]}
        result = ds.validate(doc)
        self.assertFalse(result.valid)

    def test_09_sharing_preferred_is_advisory_only(self):
        doc = _doc(
            _svc("a", port_value=443, sharing="preferred"),
            _svc("b", port_value=443, sharing="preferred", ip_selection="same_as_service", same_as="a"),
        )
        _assert_valid_ds(doc)
        result = planner.plan(_inventory(), _registry(nginx=_NGINX_TCP_FULL), doc)
        self.assertEqual(result["outcome"], "planned")

    def test_10_sharing_allowed_is_neutral(self):
        doc = _doc(_svc("a", port_value=443, sharing="allowed"))
        _assert_valid_ds(doc)
        result = planner.plan(_inventory(), _registry(), doc)
        self.assertEqual(result["outcome"], "planned")
        self.assertEqual(result["selected_topology"], "DIRECT_TCP")

    def test_11_sharing_forbidden_excludes_shared_candidate(self):
        doc = _doc(
            _svc("a", port_value=443, sharing="forbidden"),
            _svc("b", port_value=8080, sharing="allowed"),
        )
        _assert_valid_ds(doc)
        result = planner.plan(_inventory(), _registry(nginx=_NGINX_TCP_FULL), doc)
        self.assertEqual(result["outcome"], "planned")
        topologies = {g["topology"] for g in result["plan_ir"]["groups"]}
        self.assertEqual(topologies, {"DIRECT_TCP"})


# ─────────────────────────────────────────────────────────────────────
# 12-16: ports and IP allocation
# ─────────────────────────────────────────────────────────────────────

class TestPortsAndIps(unittest.TestCase):
    def test_12_specific_port(self):
        doc = _doc(_svc("a", port_selection="specific", port_value=8443))
        _assert_valid_ds(doc)
        result = planner.plan(_inventory(), _registry(), doc)
        listener = result["plan_ir"]["groups"][0]["services"][0]["listener"]
        self.assertEqual(listener["port"], 8443)

    def test_13_any_port(self):
        doc = _doc(_svc("a", port_selection="any"))
        _assert_valid_ds(doc)
        result = planner.plan(_inventory(), _registry(), doc)
        self.assertEqual(result["outcome"], "planned")
        listener = result["plan_ir"]["groups"][0]["services"][0]["listener"]
        self.assertIsInstance(listener["port"], int)

    def test_14_preferred_port_is_honored_when_uncontested(self):
        doc = _doc(_svc("a", port_selection="preferred", port_value=9443))
        _assert_valid_ds(doc)
        result = planner.plan(_inventory(), _registry(), doc)
        listener = result["plan_ir"]["groups"][0]["services"][0]["listener"]
        self.assertEqual(listener["port"], 9443)

    def test_15_same_as_service_places_on_identical_ip(self):
        doc = _doc(
            _svc("a", port_value=443, sharing="required", ip_selection="specific", ip_value="203.0.113.99"),
            _svc("b", port_value=443, sharing="required", ip_selection="same_as_service", same_as="a"),
        )
        _assert_valid_ds(doc)
        result = planner.plan(_inventory(), _registry(nginx=_NGINX_TCP_FULL), doc)
        self.assertEqual(result["outcome"], "planned")
        group = result["plan_ir"]["groups"][0]
        ips = {s["listener"]["ip"] for s in group["services"]}
        self.assertEqual(ips, {"203.0.113.99"})

    def test_16_separate_from_service_is_pairwise_only(self):
        doc = _doc(
            _svc("a", port_value=443, sharing="allowed"),
            _svc("b", port_value=8080, sharing="allowed", ip_selection="separate_from_service", separate_from="a"),
        )
        _assert_valid_ds(doc)
        result = planner.plan(_inventory(public_ipv4_count=2), _registry(), doc)
        self.assertEqual(result["outcome"], "planned")


# ─────────────────────────────────────────────────────────────────────
# 17-19: capability status handling
# ─────────────────────────────────────────────────────────────────────

class TestCapabilityStatusHandling(unittest.TestCase):
    def _shared_doc(self):
        return _doc(
            _svc("a", sharing="required", tls={"mode": "passthrough"}),
            _svc("b", sharing="required", ip_selection="same_as_service", same_as="a", tls={"mode": "termination"}),
        )

    def test_17_unresolved_capability_rejects_not_assumes(self):
        doc = self._shared_doc()
        _assert_valid_ds(doc)
        reg = _registry(nginx=_provider(**{
            "tcp.listen": "available", "tcp.proxy": "available", "tcp.sni_inspection": "unresolved",
            "tcp.tls_passthrough": "available", "tcp.tls_termination": "available",
        }))
        result = planner.plan(_inventory(), reg, doc)
        self.assertEqual(result["outcome"], "unsatisfiable")
        self.assertTrue(any(r["rejection_class"] == "capability_unresolved" for r in result["rejected_alternatives"]))

    def test_18_unsupported_capability_permanently_rejects(self):
        doc = self._shared_doc()
        _assert_valid_ds(doc)
        reg = _registry(nginx=_provider(**{
            "tcp.listen": "available", "tcp.proxy": "available", "tcp.sni_inspection": "unsupported",
            "tcp.tls_passthrough": "available", "tcp.tls_termination": "available",
        }))
        result = planner.plan(_inventory(), reg, doc)
        self.assertEqual(result["outcome"], "unsatisfiable")
        rej = [r for r in result["rejected_alternatives"] if r["rejection_class"] == "capability_unsupported"]
        self.assertTrue(rej)
        self.assertEqual(rej[0]["permanence"], "permanent")

    def test_19_absent_provider_rejects_conditionally(self):
        doc = self._shared_doc()
        _assert_valid_ds(doc)
        result = planner.plan(_inventory(), _registry(nginx=_provider(present="absent")), doc)
        self.assertEqual(result["outcome"], "unsatisfiable")
        rej = [r for r in result["rejected_alternatives"] if r["rejection_class"] == "capability_absent"]
        self.assertTrue(rej)
        self.assertEqual(rej[0]["permanence"], "conditional")


# ─────────────────────────────────────────────────────────────────────
# 20-21: ownership / SO_REUSEPORT
# ─────────────────────────────────────────────────────────────────────

class TestOwnershipAndReuseport(unittest.TestCase):
    def test_20_permission_denied_owner_stops(self):
        doc = _doc(_svc("a", port_value=443))
        _assert_valid_ds(doc)
        inv = _inventory(listeners=[_listener("tcp", 443, pid_unresolved_reason="permission_denied")])
        result = planner.plan(inv, _registry(), doc)
        self.assertEqual(result["outcome"], "stopped")
        self.assertIn("stop_on_unknown_owner", result["failure_reason"])

    def test_21_so_reuseport_never_treated_as_multiplexing(self):
        doc = _doc(
            _svc("a", transport="udp", sharing="required", quic={"sni_routing": "passthrough", "migration_tolerant": True}),
            _svc("b", transport="udp", sharing="required", ip_selection="same_as_service", same_as="a",
                 quic={"sni_routing": "passthrough", "migration_tolerant": True}),
        )
        _assert_valid_ds(doc)
        reg = _registry(nginx=_provider(**{
            "udp.listen": "available", "udp.proxy": "available", "udp.reuseport": "available",
            "udp.quic_inspection": "unsupported", "udp.quic_sni_routing": "unsupported",
            "udp.multi_backend_same_port": "unsupported",
        }))
        result = planner.plan(_inventory(), reg, doc)
        self.assertEqual(result["outcome"], "unsatisfiable")
        self.assertIsNone(result["selected_topology"])


# ─────────────────────────────────────────────────────────────────────
# 22-24: QUIC termination vs passthrough, obfuscation, migration
# ─────────────────────────────────────────────────────────────────────

class TestQuicSafety(unittest.TestCase):
    def _shared_udp_doc(self, migration_tolerant=True):
        return _doc(
            _svc("a", transport="udp", sharing="required",
                 quic={"sni_routing": "passthrough", "migration_tolerant": migration_tolerant}),
            _svc("b", transport="udp", sharing="required", ip_selection="same_as_service", same_as="a",
                 quic={"sni_routing": "passthrough", "migration_tolerant": migration_tolerant}),
        )

    def test_22_quic_termination_never_substitutes_for_passthrough(self):
        doc = self._shared_udp_doc()
        _assert_valid_ds(doc)
        reg = _registry(haproxy=_provider(**{
            "udp.listen": "unresolved", "udp.proxy": "unsupported",
            "udp.quic_inspection": "available", "udp.quic_sni_termination": "available",
            "udp.quic_sni_routing": "unsupported", "udp.multi_backend_same_port": "unsupported",
        }))
        result = planner.plan(_inventory(), reg, doc)
        self.assertEqual(result["outcome"], "unsatisfiable")

    def test_23_obfuscation_not_none_blocks_shared_quic(self):
        doc = self._shared_udp_doc()
        _assert_valid_ds(doc)
        result = planner.plan(_inventory(obfuscation="salamander"), _registry(caddy_l4=_CADDY_QUIC_FULL), doc)
        self.assertEqual(result["outcome"], "unsatisfiable")
        self.assertTrue(any("obfuscation" in r["reason"].lower() for r in result["rejected_alternatives"]))

    def test_23b_obfuscation_unresolved_also_blocks(self):
        doc = self._shared_udp_doc()
        _assert_valid_ds(doc)
        result = planner.plan(_inventory(obfuscation=None), _registry(caddy_l4=_CADDY_QUIC_FULL), doc)
        self.assertEqual(result["outcome"], "unsatisfiable")

    def test_24_migration_tolerant_vs_migration_safe_never_conflated(self):
        doc = self._shared_udp_doc(migration_tolerant=True)
        _assert_valid_ds(doc)
        result = planner.plan(_inventory(), _registry(caddy_l4=_CADDY_QUIC_FULL), doc)
        self.assertEqual(result["outcome"], "planned")
        self.assertTrue(any("migration" in w.lower() for w in result["plan_ir"]["warnings"]))


# ─────────────────────────────────────────────────────────────────────
# 25: deterministic tie-break
# ─────────────────────────────────────────────────────────────────────

class TestDeterminism(unittest.TestCase):
    def test_25_deterministic_tie_break_across_repeated_runs(self):
        doc = _doc(
            _svc("a", sharing="required", tls={"mode": "passthrough"}),
            _svc("b", sharing="required", ip_selection="same_as_service", same_as="a", tls={"mode": "passthrough"}),
        )
        _assert_valid_ds(doc)
        reg = _registry(
            caddy_l4=_provider(**{"tcp.listen": "available", "tcp.proxy": "available",
                                    "tcp.sni_inspection": "available", "tcp.tls_passthrough": "available"}),
            nginx=_provider(**{"tcp.listen": "available", "tcp.proxy": "available",
                                 "tcp.sni_inspection": "available", "tcp.tls_passthrough": "available"}),
        )
        inv = _inventory()
        results = [planner.plan(inv, reg, doc) for _ in range(20)]
        mechanisms = {r["plan_ir"]["groups"][0]["mechanism"] for r in results}
        self.assertEqual(len(mechanisms), 1, f"non-deterministic winner across runs: {mechanisms}")
        self.assertEqual(mechanisms.pop(), "caddy_l4")

    def test_25b_same_inputs_same_plan_ir_byte_for_byte(self):
        doc = _doc(_svc("a", tls={"mode": "passthrough"}))
        _assert_valid_ds(doc)
        inv = _inventory()
        reg = _registry(nginx=_NGINX_TCP_FULL)
        r1 = planner.plan(inv, reg, doc)
        r2 = planner.plan(inv, reg, doc)
        self.assertEqual(r1["plan_ir"], r2["plan_ir"])


# ─────────────────────────────────────────────────────────────────────
# 26-30: reconciliation KEEP/REUSE/CHANGE/CREATE/REMOVE
# ─────────────────────────────────────────────────────────────────────

class TestReconciliation(unittest.TestCase):
    def test_26_keep_existing_compatible_resource(self):
        doc = _doc(_svc("xray", port_value=443, tls={"mode": "passthrough"}))
        _assert_valid_ds(doc)
        inv = _inventory(listeners=[_listener("tcp", 443, owner={"kind": "process", "comm": "nginx"})],
                          detected_ingress={"nginx": {"present": True}, "caddy": {"present": False}, "haproxy": {"present": False}})
        result = planner.plan(inv, _registry(), doc)
        self.assertEqual(result["outcome"], "planned")
        self.assertEqual(result["plan_ir"]["groups"][0]["services"][0]["action"], "keep")

    def test_27_reuse_existing_resource_for_a_group(self):
        doc = _doc(
            _svc("xray", sharing="required", tls={"mode": "passthrough"}),
            _svc("web", sharing="required", ip_selection="same_as_service", same_as="xray", tls={"mode": "termination"}),
        )
        _assert_valid_ds(doc)
        inv = _inventory(listeners=[_listener("tcp", 443, owner={"kind": "process", "comm": "nginx"})])
        result = planner.plan(inv, _registry(nginx=_NGINX_TCP_FULL), doc)
        self.assertEqual(result["outcome"], "planned")
        actions = {s["action"] for s in result["plan_ir"]["groups"][0]["services"]}
        self.assertEqual(actions, {"reuse"})

    def test_28_change_incompatible_resource(self):
        """CHANGE is only decidable where Planner has something
        concrete to check the existing resource against — for a
        standalone DIRECT_* service (mechanism=None), Desired State
        never declares an implementation binary (by design — see
        module docstring's provider-independence), so Planner cannot
        distinguish 'the right thing is already there' from 'the
        wrong thing is there' beyond 'a resolved owner exists at
        all' (see test_26). CHANGE only becomes decidable once a
        SHARED_* candidate's required mechanism gives Planner
        something concrete to compare against, as here: nginx is
        needed, but the existing resolved owner is a different,
        unrelated process."""
        doc = _doc(
            _svc("xray", sharing="required", tls={"mode": "passthrough"}),
            _svc("web", sharing="required", ip_selection="same_as_service", same_as="xray", tls={"mode": "termination"}),
        )
        _assert_valid_ds(doc)
        inv = _inventory(listeners=[_listener("tcp", 443, owner={"kind": "process", "comm": "some-other-daemon"})])
        result = planner.plan(inv, _registry(nginx=_NGINX_TCP_FULL), doc)
        self.assertEqual(result["outcome"], "planned")
        actions = {s["action"] for s in result["plan_ir"]["groups"][0]["services"]}
        self.assertEqual(actions, {"change"})
        self.assertTrue(all(s["change_scope"] == "topology" for s in result["plan_ir"]["groups"][0]["services"]))

    def test_29_create_missing_resource(self):
        doc = _doc(_svc("xray", port_value=443, tls={"mode": "passthrough"}))
        _assert_valid_ds(doc)
        result = planner.plan(_inventory(), _registry(), doc)
        self.assertEqual(result["plan_ir"]["groups"][0]["services"][0]["action"], "create")

    def test_30_remove_never_proposed_without_explicit_policy(self):
        doc = _doc(_svc("xray", port_value=443, tls={"mode": "passthrough"}))
        _assert_valid_ds(doc)
        inv = _inventory(listeners=[_listener("udp", 9999, owner={"kind": "process", "comm": "some-unrelated-thing"})])
        result = planner.plan(inv, _registry(), doc)
        self.assertEqual(result["plan_ir"]["removals"], [])


# ─────────────────────────────────────────────────────────────────────
# 31: TeleMT
# ─────────────────────────────────────────────────────────────────────

class TestTeleMT(unittest.TestCase):
    def test_31_telemt_single_ingress_path_with_proxy_protocol(self):
        doc = _doc(
            _svc("xray-reality", sharing="required", tls={"mode": "passthrough"}),
            _svc("telemt", sharing="required", ip_selection="same_as_service", same_as="xray-reality",
                 tls={"mode": "passthrough"}, proxy_protocol={"accept": "required"},
                 exclusivity="single_ingress_path"),
        )
        _assert_valid_ds(doc)
        result = planner.plan(_inventory(), _registry(nginx=_NGINX_TCP_FULL), doc)
        self.assertEqual(result["outcome"], "planned")
        self.assertEqual(result["selected_topology"], "SHARED_TCP_SNI")
        self.assertEqual(result["plan_ir"]["groups"][0]["mechanism"], "nginx")
        telemt_entry = next(s for s in result["plan_ir"]["groups"][0]["services"] if s["service_id"] == "telemt")
        self.assertEqual(telemt_entry["proxy_protocol"], "required")
        safety_ids = {d["rule_id"] for d in result["plan_ir"]["groups"][0]["safety_decisions"]}
        self.assertIn("single_ingress_path", safety_ids)

    def test_31b_telemt_proxy_protocol_unsupported_mechanism_rejected(self):
        doc = _doc(
            _svc("xray-reality", transport="udp", sharing="required",
                 quic={"sni_routing": "passthrough", "migration_tolerant": True}),
            _svc("telemt", transport="udp", sharing="required", ip_selection="same_as_service", same_as="xray-reality",
                 quic={"sni_routing": "passthrough", "migration_tolerant": True},
                 proxy_protocol={"accept": "required"}),
        )
        _assert_valid_ds(doc)
        result = planner.plan(_inventory(), _registry(caddy_l4=_CADDY_QUIC_FULL), doc)
        self.assertEqual(result["outcome"], "unsatisfiable")
        self.assertTrue(any(r["rejection_class"] == "capability_unresolved" for r in result["rejected_alternatives"]))


# ─────────────────────────────────────────────────────────────────────
# 32: architecture boundary — no raw provider facts, no I/O
# ─────────────────────────────────────────────────────────────────────

class TestArchitectureBoundary(unittest.TestCase):
    def test_32_no_raw_provider_fact_access(self):
        import inspect
        source = inspect.getsource(planner)
        # Strip the module's own top-level docstring first — it
        # legitimately discusses these terms in prose (explaining the
        # boundary this test verifies), which would otherwise produce
        # a false positive against the bare word.
        import ast
        tree = ast.parse(source)
        module_docstring = ast.get_docstring(tree) or ""
        code_only = source.replace(module_docstring, "")
        for forbidden in ('["stream_capabilities"]', '.get("stream_capabilities"',
                          '["layer4_capabilities"]', '.get("layer4_capabilities"',
                          '["detected_ingress"]', '.get("detected_ingress"'):
            self.assertNotIn(forbidden, code_only, f"planner.py must not access {forbidden!r} directly")

    def test_no_subprocess_or_file_io(self):
        import inspect
        source = inspect.getsource(planner)
        for forbidden in ("import subprocess", "open(", "socket.socket"):
            self.assertNotIn(forbidden, source, f"planner.py must not perform I/O ({forbidden!r})")

    def test_no_forbidden_imports(self):
        import inspect
        source = inspect.getsource(planner)
        for forbidden in ("import run_command", "from providers", "import net_facts",
                          "import hysteria2_config", "import inventory_build", "import desired_state"):
            self.assertNotIn(forbidden, source, f"planner.py must not import {forbidden!r}")

    def test_no_hardcoded_provider_branches(self):
        import inspect
        source = inspect.getsource(planner)
        for forbidden in ('== "caddy_l4"', '== "nginx"', '== "haproxy"', '== "envoy"'):
            self.assertNotIn(forbidden, source, f"planner.py must not hard-code a provider branch ({forbidden!r})")
        self.assertIn("_PROXY_PROTOCOL_STATIC_ASSUMPTION", source)

    def test_plan_ir_never_contains_provider_syntax(self):
        doc = _doc(
            _svc("a", sharing="required", tls={"mode": "passthrough"}),
            _svc("b", sharing="required", ip_selection="same_as_service", same_as="a", tls={"mode": "termination"}),
        )
        _assert_valid_ds(doc)
        result = planner.plan(_inventory(), _registry(nginx=_NGINX_TCP_FULL), doc)
        import json
        serialized = json.dumps(result["plan_ir"])
        for forbidden in ("stream {", "ssl_preread", "load_module", "server_name", "location /"):
            self.assertNotIn(forbidden, serialized)


# ─────────────────────────────────────────────────────────────────────
# Additional invariants
# ─────────────────────────────────────────────────────────────────────

class TestAdditionalInvariants(unittest.TestCase):
    def test_effective_desired_state_does_not_mutate_original(self):
        doc = _doc(_svc("a", transport="udp", quic={"sni_routing": "not_required"}))
        original = copy.deepcopy(doc)
        planner.make_effective_desired_state(doc)
        self.assertEqual(doc, original)

    def test_effective_defaults_materialized(self):
        doc = _doc(_svc("a", transport="udp", quic={"sni_routing": "not_required"}))
        eff = planner.make_effective_desired_state(doc)
        self.assertEqual(eff["services"][0]["quic"]["migration_tolerant"], False)
        self.assertEqual(eff["operator_preferences"]["complexity_tolerance"], "prefer_simple")
        self.assertEqual(eff["operator_preferences"]["ip_sharing_preference"], "no_preference")

    def test_unsupported_schema_version_stops(self):
        result = planner.plan({"schema_version": "poc-1"}, _registry(), _doc(_svc("a")))
        self.assertEqual(result["outcome"], "stopped")

    def test_output_contract_shape(self):
        doc = _doc(_svc("a", tls={"mode": "passthrough"}))
        result = planner.plan(_inventory(), _registry(), doc)
        for key in ("outcome", "selected_topology", "plan_ir", "rejected_alternatives", "failure_reason"):
            self.assertIn(key, result)
        self.assertIn(result["outcome"], ("planned", "unsatisfiable", "stopped"))

    def test_plan_ir_group_ids_deterministic_sorted(self):
        doc = _doc(_svc("zebra", port_value=1234, tls={"mode": "passthrough"}),
                    _svc("alpha", port_value=5678, tls={"mode": "passthrough"}))
        _assert_valid_ds(doc)
        result = planner.plan(_inventory(), _registry(), doc)
        group_ids = [g["group_id"] for g in result["plan_ir"]["groups"]]
        self.assertEqual(group_ids, sorted(group_ids))

    def test_candidate_id_deterministic(self):
        cid1 = plan_ir.candidate_id("SHARED_TCP_SNI", "nginx", ["b", "a"])
        cid2 = plan_ir.candidate_id("SHARED_TCP_SNI", "nginx", ["a", "b"])
        self.assertEqual(cid1, cid2)

    def test_rejected_alternatives_are_categorized_not_freeform(self):
        doc = _doc(
            _svc("a", sharing="required", tls={"mode": "passthrough"}),
            _svc("b", sharing="required", ip_selection="same_as_service", same_as="a", tls={"mode": "passthrough"}),
        )
        _assert_valid_ds(doc)
        result = planner.plan(_inventory(), _registry(nginx=_provider(present="absent")), doc)
        valid_classes = {"capability_unsupported", "capability_unresolved", "capability_absent",
                          "safety_policy_stop", "safety_policy_exclude", "inventory_conflict",
                          "unsatisfiable_placement", "lower_score"}
        for r in result["rejected_alternatives"]:
            self.assertIn(r["rejection_class"], valid_classes)


if __name__ == "__main__":
    unittest.main()
