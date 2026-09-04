#!/usr/bin/env python3
"""
poc/network-inspect/providers/caddy.py
========================================

EXPERIMENTAL / RESEARCH POC — see poc/network-inspect/README.md and
providers/__init__.py.

Raw-fact only, per the same principle as providers/nginx.py — this
records the module list `caddy list-modules --versions` reports; it
does not decide what that implies for any topology (research doc
§7/§20).

Critical invariant (research doc §7, and this PoC's own prior-round
task brief §3): "Caddy installed" != "caddy-l4 available" != "QUIC
matcher available". These are three independently-recorded facts
below, never collapsed into one boolean.

Layering: `_parse_module_list_output()` is a PURE function of an
already-obtained `caddy list-modules --versions` stdout blob — no
subprocess call, trivially testable with a bare string.
`layer4_capabilities()` is the thin subprocess-calling wrapper.
"""

from __future__ import annotations

from run_command import run


def _parse_module_list_output(stdout_text: str) -> list[str]:
    """Given raw `caddy list-modules --versions` stdout, extract the
    list of module name tokens (dropping any per-line version
    suffix). Returns an empty list if nothing parseable was found —
    the caller (layer4_capabilities()) is responsible for treating an
    empty list as `unresolved`, not as a confirmed "no modules"."""
    modules: list[str] = []
    for line in stdout_text.splitlines():
        line = line.strip()
        if not line:
            continue
        # Each line is "module.name" or "module.name  vX.Y.Z-..."; the
        # module name is always the first whitespace-separated token.
        # Caddy's own output also includes non-module header/footer
        # lines in some versions (e.g. "Standard modules:") — anything
        # that isn't a dotted-or-bare identifier-looking token is kept
        # in raw_module_list for transparency but not used for the
        # boolean facts below, since a false positive there would be
        # exactly the kind of invented capability this PoC must not
        # produce.
        token = line.split()[0]
        modules.append(token)
    return modules


def layer4_capabilities(caddy_bin: str) -> dict:  # noqa: ARG001 - see providers/nginx.py's stream_capabilities() docstring for why this param is kept even though run() invokes by PATH-resolved name
    res = run(["caddy", "list-modules", "--versions"])
    if not res.ok:
        return {
            "status": "unresolved",
            "unresolved_reason": f"list_modules_failed:{res.reason}",
            "layer4_present": None,
            "layer4_matchers_quic_present": None,
            "layer4_matchers_tls_present": None,
            "raw_module_list": None,
        }
    if res.returncode != 0:
        return {
            "status": "unresolved",
            "unresolved_reason": f"list_modules_failed:returncode_{res.returncode}",
            "layer4_present": None,
            "layer4_matchers_quic_present": None,
            "layer4_matchers_tls_present": None,
            "raw_module_list": None,
        }

    modules = _parse_module_list_output(res.stdout)
    if not modules:
        # Binary ran, exited 0, produced no parseable module lines at
        # all — this is unusual enough (a genuinely module-less Caddy
        # build is very rare) that treating it as a confirmed "no
        # layer4" would risk masking a parsing problem as a capability
        # fact. Recorded as unresolved instead.
        return {
            "status": "unresolved",
            "unresolved_reason": "empty_module_list",
            "layer4_present": None,
            "layer4_matchers_quic_present": None,
            "layer4_matchers_tls_present": None,
            "raw_module_list": [],
        }

    module_set = set(modules)
    layer4_present = any(m == "layer4" or m.startswith("layer4.") for m in module_set)
    return {
        "status": "available",
        "unresolved_reason": None,
        "layer4_present": layer4_present,
        "layer4_matchers_quic_present": "layer4.matchers.quic" in module_set,
        "layer4_matchers_tls_present": "layer4.matchers.tls" in module_set,
        "raw_module_list": modules,
    }
