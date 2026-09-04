#!/usr/bin/env python3
"""
poc/network-inspect/hysteria2_config.py
=========================================

EXPERIMENTAL / RESEARCH POC — see poc/network-inspect/README.md.

Kept OUTSIDE providers/ deliberately: nginx/caddy (providers/) are
being evaluated as *candidate L4 routers* — "can this software route
traffic for someone else." Hysteria2 here is the opposite role — it's
the protocol *being routed*, and the fact this module extracts
(`obfs.type`) is not a capability of a router at all. It's a
precondition/constraint that will later determine whether ANY router's
QUIC-inspection capability can even apply to Hysteria2's own traffic
(research doc §3/§6/§13: Salamander/Gecko obfuscation defeats every
QUIC-aware L4 router surveyed, regardless of that router's own
capability). Conflating this with providers/ would blur a distinction
that matters for the Capability Registry (capabilities.py) that
consumes this fact as an input constraint, not as its own
provider-capability-matrix row.

The single most safety-critical new discovery fact per the research
document (§13/§19): a shared-UDP-QUIC-SNI planner decision can only
ever be safe if this value is actually known, not assumed.

Layering within this module mirrors the same boundary
providers/nginx.py and providers/caddy.py use, and was extracted for
the identical reason (see README.md "Architecture" section, "parser
vs adapter" discussion): `_parse_obfs_block()` is a PURE function of
already-read text — no file I/O, no environment dependency, trivially
testable with a bare string, no tempfile needed. `obfuscation()` is
the thin I/O-boundary wrapper that turns "reading this specific path
went wrong" into the same honest unresolved-state vocabulary the rest
of this PoC uses, then delegates all actual parsing to the pure
function.

This is a deliberately MINIMAL, TARGETED extractor for exactly the
two-level `obfs: / type: <value>` block Hysteria2's own docs show —
it is NOT a general YAML parser, and does not try to be one. No
PyYAML (or any other new) dependency is introduced: this project's
existing Hysteria2 config-editing code (lib/hy2/install.sh,
lib/hy2/integration.sh) already edits this same file with
regex/line-oriented `re.sub`-style logic rather than a full YAML
round-trip, and this module follows that same, already-established
project convention rather than introducing a new one.
"""

from __future__ import annotations

import os
import re
from typing import Optional

_OBFS_TOP_KEY_RE = re.compile(r"^obfs:\s*(#.*)?$")
_OBFS_TOP_KEY_INLINE_RE = re.compile(r"^obfs:\s*(\S.*)$")
_OBFS_TYPE_LINE_RE = re.compile(r"^(?P<indent>[ ]+)type:\s*(?P<value>.*)$")


def _strip_yaml_comment(value: str) -> str:
    """Best-effort trailing-comment strip for a scalar value on one
    line — good enough for the specific `type: <bareword>` shape this
    extractor targets (Hysteria2's obfs.type is always a short
    unquoted identifier: none/salamander/gecko in every example this
    research found), not a general YAML scalar parser."""
    m = re.search(r"\s#", value)
    return (value[: m.start()] if m else value).strip()


# ─────────────────────────────────────────────────────────────────────
# Pure parser — given text, no I/O. This is the piece unit tests should
# target directly whenever they're only exercising parsing logic (see
# tests/test_hysteria2_config.py) — no tempfile required.
# ─────────────────────────────────────────────────────────────────────

def _parse_obfs_block(text: str) -> dict:
    """Returns one of:
      {"kind": "flow_style_not_supported"}
      {"kind": "malformed_tab_indentation"}
      {"kind": "absent"}
      {"kind": "block_type_missing"}
      {"kind": "type_value_empty"}
      {"kind": "malformed_unbalanced_quote"}
      {"kind": "resolved", "raw_type_value": str, "effective_value": str,
       "confidence": "high"|"medium"}
    Never raises on malformed input — every branch is a terminal,
    named "kind" the caller (obfuscation()) maps to the project's
    standard unresolved-reason vocabulary.
    """
    lines = text.splitlines()

    # YAML forbids tab characters for indentation — a tab anywhere in
    # a line's leading whitespace is an unambiguous, cheaply-detected
    # structural error worth flagging as malformed rather than risking
    # a misparse of the block below.
    for line in lines:
        stripped_leading = line[: len(line) - len(line.lstrip(" \t"))]
        if "\t" in stripped_leading:
            return {"kind": "malformed_tab_indentation"}

    top_key_idx = None
    for i, line in enumerate(lines):
        if _OBFS_TOP_KEY_RE.match(line):
            top_key_idx = i
            break
        if _OBFS_TOP_KEY_INLINE_RE.match(line):
            # `obfs: {type: salamander}` (flow style) or some other
            # non-block-mapping form on the same line — explicitly
            # out of scope for this minimal extractor, per its own
            # docstring. Do not guess; report the real limitation.
            return {"kind": "flow_style_not_supported"}

    if top_key_idx is None:
        # No top-level `obfs:` key anywhere in the file at all.
        # Per upstream Hysteria2/sing-box documentation ("Configs that
        # omit obfs use the unobfuscated path"), this is a real,
        # positively-resolvable fact, not an unknown — but the
        # PHYSICAL absence of the field is still recorded separately
        # from the EFFECTIVE value by the caller, per this project's
        # explicit requirement (obfuscation()'s docstring).
        return {"kind": "absent"}

    # Walk the indented block following `obfs:` looking for the first
    # `type:` line at the block's own (shallowest) indentation level.
    block_indent = None
    type_value_raw = None
    j = top_key_idx + 1
    while j < len(lines):
        line = lines[j]
        if line.strip() == "" or line.lstrip().startswith("#"):
            j += 1
            continue
        indent = len(line) - len(line.lstrip(" "))
        if indent == 0:
            break  # dedented back to top level — obfs block has ended
        if block_indent is None:
            block_indent = indent
        if indent == block_indent:
            m = _OBFS_TYPE_LINE_RE.match(line)
            if m and len(m.group("indent")) == block_indent:
                candidate = m.group("value").strip()
                if candidate.startswith(("'", '"')):
                    # Quoted scalar — this minimal extractor does not
                    # attempt quote-aware unescaping; report the
                    # literal quoted form rather than guessing.
                    type_value_raw = candidate
                else:
                    type_value_raw = _strip_yaml_comment(candidate)
                break
        j += 1

    if type_value_raw is None:
        return {"kind": "block_type_missing"}
    if not type_value_raw:
        return {"kind": "type_value_empty"}
    if type_value_raw.count('"') % 2 == 1 or type_value_raw.count("'") % 2 == 1:
        return {"kind": "malformed_unbalanced_quote"}

    normalized = type_value_raw.strip("'\"").strip().lower()
    effective = normalized if normalized in ("none", "salamander", "gecko") else "unknown"
    return {
        "kind": "resolved",
        "raw_type_value": type_value_raw,
        "effective_value": effective,
        "confidence": "high" if effective != "unknown" else "medium",
    }


# ─────────────────────────────────────────────────────────────────────
# I/O-boundary wrapper — reads the file, translates OS-level failure
# modes into this project's standard unresolved-reason vocabulary,
# then delegates to the pure parser above for everything else.
# ─────────────────────────────────────────────────────────────────────

def _unresolved(config_path: str, reason: str, field_present_in_config: Optional[bool] = None) -> dict:
    return {
        "config_path": config_path,
        "status": "unresolved",
        "unresolved_reason": reason,
        "field_present_in_config": field_present_in_config,
        "raw_type_value": None,
        "effective_value": None,
        "effective_value_basis": None,
        "confidence": None,
    }


def obfuscation(config_path: str) -> dict:
    if not os.path.exists(config_path):
        return _unresolved(config_path, "config_missing")

    try:
        with open(config_path, "r", encoding="utf-8") as fh:
            try:
                text = fh.read()
            except UnicodeDecodeError:
                return _unresolved(config_path, "decode_error")
    except PermissionError:
        return _unresolved(config_path, "config_unreadable")
    except OSError as exc:
        return _unresolved(config_path, f"config_unreadable:{exc.__class__.__name__}")

    parsed = _parse_obfs_block(text)
    kind = parsed["kind"]

    if kind == "flow_style_not_supported":
        return _unresolved(config_path, "flow_style_not_supported", field_present_in_config=True)
    if kind == "malformed_tab_indentation":
        return _unresolved(config_path, "malformed_yaml:tab_indentation")
    if kind == "block_type_missing":
        return _unresolved(config_path, "obfs_block_present_but_type_missing", field_present_in_config=True)
    if kind == "type_value_empty":
        return _unresolved(config_path, "obfs_type_value_empty", field_present_in_config=True)
    if kind == "malformed_unbalanced_quote":
        return _unresolved(config_path, "malformed_yaml:unbalanced_quote", field_present_in_config=True)
    if kind == "absent":
        return {
            "config_path": config_path,
            "status": "resolved",
            "unresolved_reason": None,
            "field_present_in_config": False,
            "raw_type_value": None,
            "effective_value": "none",
            "effective_value_basis": "default_when_absent",
            "confidence": "high",
        }
    # kind == "resolved"
    return {
        "config_path": config_path,
        "status": "resolved",
        "unresolved_reason": None,
        "field_present_in_config": True,
        "raw_type_value": parsed["raw_type_value"],
        "effective_value": parsed["effective_value"],
        "effective_value_basis": "explicit_in_config",
        "confidence": parsed["confidence"],
    }
