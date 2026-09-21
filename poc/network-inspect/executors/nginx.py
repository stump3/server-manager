#!/usr/bin/env python3
"""
poc/network-inspect/executors/nginx.py
=========================================

EXPERIMENTAL / RESEARCH POC — the nginx `ProviderExecutor`: the pure,
STRUCTURAL half of nginx-specific execution policy. It answers one
question about a RenderResult's artifacts, from their metadata alone:
"could an nginx executor ever apply these?" It never reads artifact
`content`, never performs I/O, and implements NO runtime behavior — no
`nginx -t`, no target-path resolution, no ownership checks, no reload.
Those are RUNTIME PREFLIGHT and belong to a future `ExecutionPort` for
nginx (see executors/core.py).

WHAT IT CHECKS
----------------
- `target_kind` is one this executor knows: currently only
  `nginx_stream_server_block`, exactly what renderers/nginx.py emits.
  Any other kind is `unsupported_artifact_kind` — never guessed at.
- `target_name` contains no path separators. Desired State only requires
  service ids to be non-empty strings, so a group id (which becomes
  `target_name`) can contain anything; refusing `/` and `\\` here means
  no later stage can mistake an identifier for a path.
- At most ONE `nginx_stream_server_block` artifact per transaction.
  Verified empirically with nginx 1.24: a configuration containing two
  top-level `stream {}` blocks fails `nginx -t` with
  `[emerg] "stream" directive is duplicate`. The current Renderer emits a
  complete `stream { ... }` wrapper per group, so a multi-group plan
  yields artifacts that cannot coexist. This is a KNOWN UPSTREAM CONTRACT
  GAP (see below): this check does not fix it, it only refuses an
  unappliable input loudly and early. Remove it when the Renderer
  contract is resolved.

KNOWN CONTRACT GAPS (reported, not patched — see stage report)
----------------------------------------------------------------
1. Composition: the Renderer's artifact is a `stream {}` FRAGMENT with no
   statement of where it lives in the final nginx configuration. Legacy
   (lib/panel/nginx/variant_f.sh / variant_j.sh) writes one complete
   `/opt/remnawave/nginx.conf` for a docker-hosted nginx, containing
   both `http {}` and exactly one `stream {}`.
2. Location: `Artifact` carries a logical `target_name` (a group id), no
   filesystem path and no mode/owner. This executor never invents one.
   A future runtime stage needs an explicit, operator-supplied
   (target_kind, target_name) -> location mapping, or a Renderer contract
   change; either way it is a decision for the human owner.

ARCHITECTURAL BOUNDARY
------------------------
Imports the standard library and `executors.core` only. Does not import
`renderers.nginx` (its `PROVIDER` / target-kind strings are duplicated
here on purpose and pinned to the Renderer's by tests/test_executor.py),
nor planner, desired_state, inventory_build, net_facts, capabilities,
plan_ir, plan_validator, providers.*, or run_command.
"""

from __future__ import annotations

from executors import core

PROVIDER = "nginx"
TARGET_KIND_STREAM_SERVER_BLOCK = "nginx_stream_server_block"
SUPPORTED_TARGET_KINDS = (TARGET_KIND_STREAM_SERVER_BLOCK,)


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
            elif art.target_kind == TARGET_KIND_STREAM_SERVER_BLOCK:
                stream_blocks.append(art.artifact_id)
            if "/" in art.target_name or "\\" in art.target_name:
                _err(diags, "invalid_target_name", art.artifact_id, f"{base}.target_name",
                          f"target_name {art.target_name!r} must not contain path separators")
        if len(stream_blocks) > 1:
            _err(diags, "multiple_stream_blocks", None, "$.artifacts",
                      f"{len(stream_blocks)} {TARGET_KIND_STREAM_SERVER_BLOCK!r} artifacts "
                      f"({stream_blocks}); nginx permits exactly one top-level stream{{}} block, "
                      f"so these cannot be applied together")
        return diags
