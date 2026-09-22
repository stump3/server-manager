#!/usr/bin/env python3
"""
poc/network-inspect/executors/nginx.py
=========================================

EXPERIMENTAL / RESEARCH POC — the nginx `ProviderExecutor`, plus the
nginx RUNTIME PREFLIGHT adapter. Two halves, both nginx-specific:

`NginxExecutor.structural_preflight()` — the pure, STRUCTURAL half. It
answers one question about a RenderResult's artifacts, from their
metadata alone: "could an nginx executor ever apply these?" It never
reads artifact `content`, never performs I/O.

`nginx_runtime_preflight()` — the RUNTIME half, added this stage. It
answers "is THIS resolved ExecutionTarget safe to even consider
mutating?" using an injected `NginxCommandPort` — never real I/O (see
RUNTIME PREFLIGHT ADAPTER below). Still no reload, no write, no apply:
those remain future stages.

STRUCTURAL PREFLIGHT — WHAT IT CHECKS
----------------------------------------
- `target_kind` is one this executor knows: currently only `nginx_stream`
  (renamed this stage from `nginx_stream_server_block` — see TARGET_KIND
  RENAME below), exactly what renderers/nginx.py emits. Any other kind is
  `unsupported_artifact_kind` — never guessed at.
- `target_name` contains no path separators. It is an identifier, never a
  path: the Renderer's is the constant `stream`, but earlier per-group
  artifacts used group ids, and Desired State only requires ids to be
  non-empty strings, so identifiers can contain anything. Refusing `/` and
  `\\` here means no later stage can mistake an identifier for a path.
- At most ONE `nginx_stream` artifact per transaction. nginx accepts
  exactly one top-level `stream {}` block (verified against nginx 1.24: a
  second fails `nginx -t` with `[emerg] "stream" directive is
  duplicate`). renderers/nginx.py aggregates every nginx group into a
  single artifact, so valid Renderer output never trips this; it remains
  as a DEFENSIVE guard against hand-built or legacy-shaped RenderResults
  (the old per-group shape is pinned as still-refused by
  tests/test_executor.py). It counts artifacts by kind only: this
  executor does not parse configuration text and does not know how
  groups combine — that is Renderer responsibility.

TARGET_KIND RENAME (this stage)
-----------------------------------
`nginx_stream_server_block` -> `nginx_stream`, a coordinated, no-alias
rename across renderers/nginx.py, this file, and every test — done NOW
per the deferred decision from the multi-group-aggregation review: the
name was already a known misnomer (one Artifact is the whole `stream{}`
scope, not a "server block"), and this stage is the first to make
`target_kind` part of a persistent structure (`ExecutionTarget`,
`TargetRegistry` — see executors/targets.py), so the rename had to land
before that structure existed, not after. Verified before renaming (same
method as the earlier review): every consumer in the repository is one
of these three files — no production caller, no doc, no fixture outside
them — so a plain rename is exact, not lossy, and no compatibility alias
is warranted.

RUNTIME PREFLIGHT ADAPTER
-----------------------------
`nginx_runtime_preflight(target, artifacts, port)` orchestrates, in
order (first failure stops the rest for that CATEGORY of check, but
independent categories still all run so every problem is reported once):
  1. shape: exactly one artifact, and its (target_kind, target_name)
     matches `target`'s — `wrong_target_shape` / `target_identity_mismatch`.
  2. `target.target_kind` is one this executor supports —
     `unsupported_artifact_kind` (same code as structural preflight;
     defense in depth against a hand-built ExecutionTarget).
  3. `target.management_scope == MANAGED` — anything else (UNMANAGED,
     or the UNKNOWN default) is `target_not_managed`. Never inferred —
     see executors/targets.py's OWNERSHIP section for why.
  4. `port.stat_target(target)` — `target_missing` / `target_not_a_file`
     / `unsafe_symlink` / `target_not_writable`.
  5. `port.dump_config(target)` — counts EXISTING top-level `stream {}`
     blocks at the target (same regex Inventory's own
     `detect_ingress()` uses: `^\\s*stream\\s*{`, so this reuses an
     already-verified convention rather than inventing a second one).
     More than one already present is `incompatible_configuration_scope`
     — a pre-existing problem this stage refuses to paper over, since it
     cannot yet write anything to fix it.
  6. `port.check_syntax(target, content)` — validates the CANDIDATE
     artifact content (not the target's current on-disk content — see
     `NginxCommandPort.check_syntax`'s own docstring for why) —
     `nginx_syntax_invalid` / `nginx_syntax_check_failed`.
Every check is independent: a `port` failure at one step does not skip
the others (all diagnostics from every step are collected before
returning), except step 1, which gates everything after it (there is
nothing safe to check about a target that doesn't match the artifact).

RUNTIME PREFLIGHT ADAPTER — WHAT IT DOES NOT DO
----------------------------------------------------
No filesystem, subprocess, or network call exists anywhere below —
`NginxCommandPort` is a `Protocol`/interface only. Every test in
tests/test_nginx_preflight.py injects a fake. A real implementation
(bare `nginx -t`, or `docker exec remnawave-nginx nginx -t` — repository
evidence for the latter: docs/LEGACY_AUDIT.md's configuration-ownership
table, `mgmt_script.sh:171`) is future work, same posture as
executors/core.py's `ExecutionPort.backup`/`.apply`/`.restore`, which
also have zero real implementations yet.

KNOWN CONTRACT GAPS (reported, not patched — see stage reports)
----------------------------------------------------------------
1. Composition (multi-group aggregation is RESOLVED in the Renderer;
   this remains): the Renderer's artifact is a `stream {}` FRAGMENT with
   no statement of where it lives in the final nginx configuration.
   Legacy (lib/panel/nginx/variant_f.sh / variant_j.sh) writes one
   complete `/opt/remnawave/nginx.conf` for a docker-hosted nginx,
   containing both `http {}` and exactly one `stream {}`. This stage's
   `ExecutionTarget.location` names WHERE that whole file lives (an
   explicit, operator-supplied fact — see executors/targets.py); it does
   not compose the fragment into that file's `http {}` neighbor. That
   composition is still a future stage's problem, not solved here.
2. Location (RESOLVED this stage): `Artifact` still carries only a
   logical `target_name`; the physical location is now supplied
   explicitly by a `TargetRegistry` entry (executors/targets.py),
   resolved via `resolve_nginx_target()` below, never invented here.

ARCHITECTURAL BOUNDARY
------------------------
Imports the standard library, `executors.core`, and `executors.targets`
only. Does not import `renderers.nginx` (its `PROVIDER` / target-kind
strings are duplicated here on purpose and pinned to the Renderer's by
tests/test_executor.py and tests/test_nginx_preflight.py), nor planner,
desired_state, inventory_build, net_facts, capabilities, plan_ir,
plan_validator, providers.*, or run_command. `NginxCommandPort` is a
`Protocol` only — no module implementing it (subprocess, `docker`,
filesystem) is imported here or anywhere in this stage.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Optional, Protocol

from executors import core
from executors.targets import MANAGED, ExecutionTarget, TargetRegistry

PROVIDER = "nginx"
TARGET_KIND = "nginx_stream"
SUPPORTED_TARGET_KINDS = (TARGET_KIND,)

# Same regex inventory_build.py's detect_ingress() uses for
# stream_block_count — deliberately reused, not reinvented (see module
# docstring's RUNTIME PREFLIGHT ADAPTER, step 5).
_STREAM_BLOCK_RE = re.compile(r"^\s*stream\s*{", re.MULTILINE)


def _err(diags: list, code: str, resource_id, field_, message: str) -> None:
    diags.append(core.Diagnostic(code, "error", resource_id, field_, message))


class NginxExecutor:
    provider = PROVIDER
    supported_target_kinds = SUPPORTED_TARGET_KINDS

    def structural_preflight(self, artifacts: tuple) -> list:
        diags: list = []
        stream_blocks = []
        for index, art in enumerate(artifacts):
            base = f"$.artifacts[{index}]"
            if art.target_kind not in SUPPORTED_TARGET_KINDS:
                _err(diags, "unsupported_artifact_kind", art.artifact_id, f"{base}.target_kind",
                          f"nginx executor supports {list(SUPPORTED_TARGET_KINDS)}, got {art.target_kind!r}")
            elif art.target_kind == TARGET_KIND:
                stream_blocks.append(art.artifact_id)
            if "/" in art.target_name or "\\" in art.target_name:
                _err(diags, "invalid_target_name", art.artifact_id, f"{base}.target_name",
                          f"target_name {art.target_name!r} must not contain path separators")
        if len(stream_blocks) > 1:
            _err(diags, "multiple_stream_blocks", None, "$.artifacts",
                      f"{len(stream_blocks)} {TARGET_KIND!r} artifacts "
                      f"({stream_blocks}); nginx permits exactly one top-level stream{{}} block, "
                      f"so these cannot be applied together")
        return diags


# ─────────────────────────────────────────────────────────────────────
# Runtime preflight — see module docstring's RUNTIME PREFLIGHT ADAPTER
# ─────────────────────────────────────────────────────────────────────

@dataclass(frozen=True)
class CommandResult:
    """Structured result of one command the port ran. Field names
    deliberately mirror run_command.RunResult's shape (ok, returncode,
    stdout, stderr) for a reader already familiar with that convention —
    this module does not import run_command (see ARCHITECTURAL BOUNDARY
    at the top of this file); `ok=False` means the OS never gave back a
    completed process at all (binary missing, timeout, ...), independent
    of `returncode`, exactly as run_command.py's own docstring defines
    it."""
    ok: bool
    returncode: Optional[int]
    stdout: str
    stderr: str


@dataclass(frozen=True)
class TargetStat:
    """A read-only snapshot of one ExecutionTarget's location. `exists`
    is False for every other field's purposes when the location is
    entirely absent (a fresh install with no prior config) — that is a
    legitimate, expected state this stage still refuses to mutate, since
    "create the file" is real apply."""
    exists: bool
    is_regular_file: bool
    is_symlink: bool
    writable: bool


class NginxCommandPort(Protocol):
    """Injected runtime primitives for nginx preflight. NOT implemented
    anywhere in this stage — every test uses a fake. A real
    implementation is a future stage's problem (bare `nginx -t`, or
    `docker exec remnawave-nginx nginx -t` — see module docstring)."""

    def stat_target(self, target: ExecutionTarget) -> TargetStat: ...

    def check_syntax(self, target: ExecutionTarget, content: str) -> CommandResult:
        """Validate `content` — the CANDIDATE artifact content, not
        whatever currently exists at `target` — as if it were nginx's
        configuration at `target`'s location. Taking content explicitly,
        rather than reading the target's current file, is what lets this
        check run with zero filesystem mutation: nothing is written
        anywhere to perform it (a real implementation might use
        `nginx -t -c /dev/stdin`, or a future apply stage's own scratch
        file — either way, not this stage's concern)."""
        ...

    def dump_config(self, target: ExecutionTarget) -> CommandResult:
        """Return target's EXISTING configuration text (e.g. `nginx -T`
        equivalent) so the caller can inspect current scope — this one is
        necessarily about what is already there, not candidate content."""
        ...


def resolve_nginx_target(render_result, registry: TargetRegistry):
    """Resolve the ONE nginx artifact's ExecutionTarget. Returns
    (ExecutionTarget | None, list[Diagnostic]). Structural validity of
    `render_result` is NOT re-checked here — that is
    `executors.core.prepare()`'s job; this function assumes it has
    already been called and passed. Always resolves to at most one
    target: the Renderer emits at most one nginx artifact per scope (see
    renderers/nginx.py CONFIGURATION SCOPE), so "multiple nginx groups"
    were already collapsed to one artifact_id/target_name before this
    function ever runs — there is only ever one identity to resolve."""
    artifacts = getattr(render_result, "artifacts", None) or []
    if not artifacts:
        return None, [core.Diagnostic(
            "no_nginx_artifact", "error", None, "$.artifacts",
            "render result has no artifacts; there is no nginx target to resolve")]
    artifact = artifacts[0]
    return registry.resolve(getattr(render_result, "provider", None),
                            getattr(artifact, "target_kind", None),
                            getattr(artifact, "target_name", None))


def nginx_runtime_preflight(target: ExecutionTarget, artifacts: tuple, port: NginxCommandPort) -> list:
    """See module docstring's RUNTIME PREFLIGHT ADAPTER for the exact
    check sequence and failure codes. Never raises for a port failure —
    a port method raising is treated the same as it returning a failing
    result (`ok=False` / an error CommandResult), never propagated."""
    diags: list = []

    if len(artifacts) != 1:
        _err(diags, "wrong_target_shape", target.target_name, "$.artifacts",
             f"nginx runtime preflight expects exactly one artifact, got {len(artifacts)}")
        return diags
    artifact = artifacts[0]
    if (artifact.target_kind, artifact.target_name) != (target.target_kind, target.target_name):
        _err(diags, "target_identity_mismatch", target.target_name, "$.artifacts[0]",
             f"resolved target (target_kind={target.target_kind!r}, target_name={target.target_name!r}) "
             f"does not match the artifact (target_kind={artifact.target_kind!r}, "
             f"target_name={artifact.target_name!r})")
        return diags

    if target.target_kind not in SUPPORTED_TARGET_KINDS:
        _err(diags, "unsupported_artifact_kind", target.target_name, "$.target_kind",
             f"nginx executor supports {list(SUPPORTED_TARGET_KINDS)}, got {target.target_kind!r}")

    if target.management_scope != MANAGED:
        _err(diags, "target_not_managed", target.target_name, "$.management_scope",
             f"target {target.location!r} has management_scope={target.management_scope!r}, not "
             f"{MANAGED!r}; refusing to consider mutating a target that was not explicitly asserted "
             f"as managed")

    try:
        stat = port.stat_target(target)
    except Exception as exc:
        _err(diags, "stat_target_failed", target.target_name, None,
             f"inspecting {target.location!r} failed: {type(exc).__name__}: {exc}")
        stat = None
    if stat is not None:
        if not stat.exists:
            _err(diags, "target_missing", target.target_name, "$.location",
                 f"target {target.location!r} does not exist; creating it is real apply, out of "
                 f"scope for this stage")
        else:
            if stat.is_symlink:
                _err(diags, "unsafe_symlink", target.target_name, "$.location",
                     f"target {target.location!r} is a symlink; refusing to treat an indirect "
                     f"target as safe without operator confirmation of what it resolves to")
            if not stat.is_regular_file:
                _err(diags, "target_not_a_file", target.target_name, "$.location",
                     f"target {target.location!r} exists but is not a regular file")
            if not stat.writable:
                _err(diags, "target_not_writable", target.target_name, "$.location",
                     f"target {target.location!r} is not writable")

    try:
        dumped = port.dump_config(target)
    except Exception as exc:
        _err(diags, "dump_config_failed", target.target_name, None,
             f"reading current configuration at {target.location!r} failed: "
             f"{type(exc).__name__}: {exc}")
        dumped = None
    if dumped is not None:
        if not dumped.ok:
            _err(diags, "dump_config_failed", target.target_name, None,
                 f"reading current configuration at {target.location!r} did not complete "
                 f"(returncode={dumped.returncode!r}): {dumped.stderr.strip() or dumped.stdout.strip()}")
        else:
            existing_blocks = len(_STREAM_BLOCK_RE.findall(dumped.stdout))
            if existing_blocks > 1:
                _err(diags, "incompatible_configuration_scope", target.target_name, None,
                     f"target {target.location!r} already contains {existing_blocks} top-level "
                     f"stream{{}} blocks; nginx permits exactly one, and this stage cannot yet "
                     f"write a fix — a human needs to resolve this before any future apply")

    try:
        checked = port.check_syntax(target, artifact.content)
    except Exception as exc:
        _err(diags, "nginx_syntax_check_failed", target.target_name, None,
             f"validating candidate content for {target.location!r} failed: "
             f"{type(exc).__name__}: {exc}")
        checked = None
    if checked is not None:
        if not checked.ok:
            _err(diags, "nginx_syntax_check_failed", target.target_name, None,
                 f"syntax validation for {target.location!r} did not complete "
                 f"(returncode={checked.returncode!r}): {checked.stderr.strip() or checked.stdout.strip()}")
        elif checked.returncode != 0:
            _err(diags, "nginx_syntax_invalid", target.target_name, None,
                 f"candidate content for {target.location!r} failed nginx syntax validation "
                 f"(returncode={checked.returncode}): {checked.stderr.strip() or checked.stdout.strip()}")

    return diags
