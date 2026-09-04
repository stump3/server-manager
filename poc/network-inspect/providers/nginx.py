#!/usr/bin/env python3
"""
poc/network-inspect/providers/nginx.py
========================================

EXPERIMENTAL / RESEARCH POC — see poc/network-inspect/README.md and
providers/__init__.py.

Raw-fact only — this module records what `nginx -V` says was compiled
in. It does NOT decide whether that makes any topology "possible";
that interpretation belongs to capabilities.py (the Capability
Registry), not to Discovery (research doc §7 principle).

Layering: `_parse_configure_output()` is a PURE function of an
already-obtained `nginx -V` text blob — no subprocess call, trivially
testable with a bare string. `stream_capabilities()` is the thin
subprocess-calling wrapper that runs the command, translates
run()-level failures into this project's unresolved-reason
vocabulary, and delegates all text parsing to the pure function.
"""

from __future__ import annotations

import re
from typing import Optional

from run_command import run

# Whole-token match: "--with-stream" must NOT match inside
# "--with-stream_ssl_preread_module" (a real, easy-to-get-wrong
# collision — the two flags share a common prefix). The (?<!\S)/(?!\S)
# boundaries require actual whitespace (or string start/end) around
# the token, which a naive substring check does not enforce.
_WITH_STREAM_RE = re.compile(r"(?<!\S)--with-stream(?:=\S+)?(?!\S)")
_WITH_STREAM_SSL_PREREAD_RE = re.compile(
    r"(?<!\S)--with-stream_ssl_preread_module(?:=\S+)?(?!\S)"
)
_CONFIGURE_ARGS_RE = re.compile(r"^configure arguments:\s*(.*)$", re.MULTILINE)
_DYNAMIC_RE = re.compile(r"(?<!\S)--with-stream(?:_ssl_preread_module)?=dynamic(?!\S)")

_NULL_FACTS = {
    "compiled_with_stream": None,
    "compiled_with_stream_ssl_preread": None,
    "stream_module_type": None,
    "dynamic_module_caveat": None,
    "configure_arguments_raw": None,
}


def _parse_configure_output(combined_text: str) -> dict:
    """Given the raw stdout+stderr text of `nginx -V`, extract
    compiled-module facts. Returns:
      {"status": "unresolved", "unresolved_reason": str, ...null facts}
    or
      {"status": "available", "unresolved_reason": None, ...facts}
    Never raises on unexpected input — an unparseable blob is an
    unresolved fact (`configure_arguments_not_found`), never a
    guessed "stream absent".
    """
    m = _CONFIGURE_ARGS_RE.search(combined_text)
    if not m:
        # Binary ran and returned successfully, but the expected
        # "configure arguments:" line wasn't found — an unexpected
        # output format (very old nginx, or a distro fork with a
        # different -V layout) is a real "couldn't check" case, not
        # evidence stream is absent.
        return {
            "status": "unresolved",
            "unresolved_reason": "configure_arguments_not_found",
            **_NULL_FACTS,
            "configure_arguments_raw": combined_text.strip() or None,
        }

    configure_args = m.group(1).strip()
    has_stream = bool(_WITH_STREAM_RE.search(configure_args))
    has_stream_ssl_preread = bool(_WITH_STREAM_SSL_PREREAD_RE.search(configure_args))
    # --with-X=dynamic is the documented nginx configure-time syntax
    # for building a module as a loadable .so instead of statically
    # linking it in.
    is_dynamic = bool(_DYNAMIC_RE.search(configure_args))

    return {
        "status": "available",
        "unresolved_reason": None,
        "compiled_with_stream": has_stream,
        "compiled_with_stream_ssl_preread": has_stream_ssl_preread,
        "stream_module_type": ("dynamic" if is_dynamic else "static") if has_stream else None,
        "dynamic_module_caveat": (
            "compiled as a dynamic module — actually being active at "
            "runtime additionally requires a `load_module` directive "
            "in nginx.conf, which this PoC does NOT check (shallow by "
            "design, see inventory_build.py module docstring)"
        ) if is_dynamic else None,
        "configure_arguments_raw": configure_args,
    }


def stream_capabilities(nginx_bin: str) -> dict:  # noqa: ARG001 - kept for call-site symmetry with caddy.layer4_capabilities(caddy_bin)
    """Reads `nginx -V` (note: capital -V, the flag that prints the
    configure-time arguments; distinct from `nginx -v`, the
    version-only flag inventory_build.py's `_version_of()` uses for
    `detected_ingress.nginx.version`). nginx famously writes this to
    STDERR, not stdout — both streams are read here for exactly this
    reason, matching `_version_of()`'s own tolerance.

    `nginx_bin` is accepted (matching providers/caddy.py's
    `layer4_capabilities(caddy_bin)` signature) but not directly used —
    `run()` invokes `nginx` by name, resolved via PATH the same way
    `which()` already found it; kept as a parameter for interface
    symmetry and so a future per-binary invocation (e.g. an
    operator-specified non-PATH nginx binary) is a small, local change
    here rather than a signature change at every call site.
    """
    res = run(["nginx", "-V"])
    if not res.ok:
        return {
            "status": "unresolved",
            "unresolved_reason": f"version_probe_failed:{res.reason}",
            **_NULL_FACTS,
        }
    if res.returncode not in (0, 1):
        # nginx -V exits 0 on most builds but some distro wrappers
        # return 1 while still printing the expected text — matches
        # the existing _version_of() tolerance, kept consistent rather
        # than inventing a stricter rule for this call site.
        return {
            "status": "unresolved",
            "unresolved_reason": f"version_probe_failed:returncode_{res.returncode}",
            **_NULL_FACTS,
        }
    return _parse_configure_output(res.stdout + res.stderr)
