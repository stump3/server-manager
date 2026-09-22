#!/usr/bin/env python3
"""
poc/network-inspect/executors/targets.py
============================================

EXPERIMENTAL / RESEARCH POC — the RUNTIME TARGET MAPPING layer: the
explicit boundary between a Renderer's `Artifact` (logical identity:
provider, target_kind, target_name) and the physical place a future
Executor would eventually touch. Provider-independent — nothing here
knows what "nginx" or "stream" means.

    Artifact (logical)  --TargetRegistry.resolve()-->  ExecutionTarget (physical)

FOUNDATION STAGE, same posture as executors/core.py: nothing here
performs I/O, and there is no filesystem, subprocess, or network access
anywhere in this module (enforced by tests/test_target_mapping.py, both
by mock-patching and by an AST scan for path-shaped string literals in
this file's own code). This module answers "where does the target come
from and is it safe to even consider mutating," never "mutate it."

WHY A REGISTRY, NOT AUTO-DISCOVERY (repository evidence, not convenience)
----------------------------------------------------------------------------
Three models were possible: (A) Inventory discovers the location, (B) the
operator/execution context supplies it explicitly, (C) a dedicated
registry maps logical identity to location. The repository answers this
directly, not by omission:

  - inventory_build.py's `detect_ingress()["nginx"]` is, by its own
    comment, "shallow by design" and carries NO path field at all — only
    `present`/`binary`/`version`/`running`/`stream_block_count`. It also
    detects nginx via a bare `which("nginx")` + `nginx -T` run directly
    on the HOST — it has no concept of a Docker-hosted nginx's config
    path, and does not correlate with the docker/compose identity that
    `listeners[].docker` (via `docker_container_info()`) already carries
    for LISTENING SOCKETS. So (A) is not supported today — reusing
    Inventory is not possible without first adding a fact Inventory does
    not currently have (see MISSING FACT below), and this module does
    not add it silently (see ARCHITECTURAL BOUNDARY).
  - The legacy deployment (lib/panel/nginx/config.sh, variant_f.sh,
    variant_j.sh) writes a HOST path, `/opt/remnawave/nginx.conf`, that
    is Remnawave-Panel-specific (rooted under the Panel's own install
    directory), not an nginx-general convention — so it cannot become a
    generic Executor default either. Worse, it is not even stable WITHIN
    that one deployment: lib/panel/compose/colocated.sh mounts it at
    `/etc/nginx/nginx.conf` (top-level, stream{}-capable) only when
    `core_topology_requires_nginx_stream(MODE)` is true, and at
    `/etc/nginx/conf.d/default.conf` (NOT stream{}-capable — `stream{}`
    is a hard top-level-only nginx construct) otherwise; MODE=2's
    lib/panel/compose/remote.sh mounts conf.d/default.conf
    unconditionally, every time, with no MODE branch at all. Three
    different mount targets for the same generated file, from three
    different code paths, depending on facts (topology mode, deployment
    flavor) nothing in this pipeline currently carries into Plan IR or
    the Artifact. Hard-coding any one of these into this module would be
    silently wrong for the other two.
  - Ownership is actively disputed, not merely undocumented: docs/
    LEGACY_AUDIT.md's CFG-02 finding records that `lib/hy2/menu.sh`
    ALSO mutates `/opt/remnawave/nginx.conf` (a `sed -i` for a
    `hy-merger` location block) across a domain boundary, and states
    outright that "a future configuration-ownership contract ... would
    need to decide whether hy2 is allowed to mutate a panel-owned file
    at all ... Not decided here." There is no single-writer invariant
    for this file today to inherit.

(B), the operator/execution context supplying the mapping explicitly, is
therefore the only model the repository actually supports today, and it
is also the project's own standing convention: overview.md's "no
automatic apply, no production config mutation — all plans require
manual operator action" is exactly a policy of explicit human assertion
over inference. `TargetRegistry` is (C) — the SHAPE that holds what (B)
supplies: a small, explicit, caller-constructed mapping. Nothing in this
module ever invents, defaults, or infers an entry.

MISSING FACT (reported, not added — see ARCHITECTURAL BOUNDARY)
--------------------------------------------------------------------
If Inventory is ever extended to close this gap, the smallest fact it
would need is exactly the one `detected_ingress.nginx` is missing today:
which nginx process (if any) owns which config path, correlated through
the SAME `owner`/`docker` machinery `listeners[]` entries already carry
(`classify_ownership()`, `docker_container_info()` — `compose_service`
is already extracted there). That correlation does not exist between
`listeners[]` and `detected_ingress` today. This module does not add it;
see the stage report for why that is out of scope here.

EXECUTIONTARGET CONTRACT
---------------------------
Deliberately five fields, no more:
    provider           str  — must equal the artifact's RenderResult.provider
    target_kind         str  — must equal the artifact's target_kind
    target_name          str  — must equal the artifact's target_name
    location               str  — opaque to this module; provider-defined
                                    format (for nginx, a host filesystem
                                    path — see executors/nginx.py)
    management_scope         str  — one of MANAGED / UNMANAGED / UNKNOWN

No filesystem-path-shaped field is added beyond the single opaque
`location` string, and no docker/compose/mount-target fields are added
here: per the CONFIGURATION SCOPE evidence above, which physical mount is
active depends on facts (deployment mode, mount target) this module has
no source for — a real runtime stage would need to ask the SAME command
adapter that validates the target (see executors/nginx.py's
`dump_config`) rather than have this module guess from a static field.

`management_scope` deliberately does not attempt a richer model (e.g.
tracking CFG-02's second writer) — the three-value vocabulary is enough
to satisfy "fail closed on unknown/unmanaged," which is this stage's
actual safety requirement; anything richer would be modelling a
multi-writer registry nothing has asked for yet.

OWNERSHIP / MANAGEMENT AUTHORITY
------------------------------------
Three closed values, mirroring the SPIRIT (not the exact vocabulary) of
Inventory's existing `listeners[].owner.kind` (`docker`/`systemd`/
`process`/`unknown`) — a config target isn't owned by a PID, so it needs
its own vocabulary, but the same fail-closed posture:
    MANAGED     — the caller has explicitly asserted server-manager owns
                    this target and it may eventually be mutated.
    UNMANAGED    — the caller has explicitly asserted this target belongs
                    to something else (an administrator, a third-party
                    tool) and must never be mutated.
    UNKNOWN       — no assertion was made. This is the ONLY default; it is
                    never upgraded to MANAGED by inference. `ExecutionTarget`
                    does not itself default a missing/invalid value to
                    UNKNOWN — an invalid value is a construction error
                    (see below) — but a caller who has nothing to assert
                    should pass UNKNOWN explicitly.
This module never infers management_scope from whether a path exists,
whether nginx is installed, or anything else observable — every value
comes from the caller (see resolve_target_or_none's docstring).

RESOLUTION SEMANTICS
------------------------
`TargetRegistry` stores its entries as given — NOT deduplicated into a
dict — specifically so a caller-constructed collision is a detectable
condition, not a silent last-write-wins overwrite (a dict keyed by
(provider, target_kind, target_name) would hide exactly the "ambiguous
mapping" case this stage is required to fail on). `resolve()`:
    zero matches     -> `target_not_mapped` (never falls back to a guess)
    two+ matches      -> `ambiguous_target_mapping` (never picks one)
    exactly one match  -> that ExecutionTarget, no diagnostics
A malformed `ExecutionTarget` (bad `management_scope`, empty identity
field) is refused at CONSTRUCTION (raises `ValueError`) rather than
surfaced as a runtime Diagnostic — this is the same distinction
executors/core.py draws between `InvalidTransition` (caller/API misuse,
raised) and `Diagnostic` (a data-shaped problem the pipeline routes
through gracefully): a registry entry a human hand-built wrong is the
former, not a runtime condition an operator's plan run should have to
parse diagnostics for.

ARCHITECTURAL BOUNDARY
--------------------------
ALLOWED to import: the standard library, and `executors.core` (for
`Diagnostic` only — this module's resolve() returns the same
Diagnostic shape core.py and renderers/nginx.py already use, so a
caller can treat all three uniformly). FORBIDDEN, same as core.py:
planner, desired_state, inventory_build, net_facts, capabilities,
plan_ir, plan_validator, renderers.*, providers.*, run_command, or
anything importing subprocess/socket/filesystem access. This module
does not import `executors.nginx` either — it is providers'-eye-view
generic, the same direction executors/core.py already keeps (core does
not know about nginx; targets does not either).
"""

from __future__ import annotations

from dataclasses import dataclass

from executors.core import Diagnostic

MANAGED = "managed"
UNMANAGED = "unmanaged"
UNKNOWN = "unknown"
MANAGEMENT_SCOPES = (MANAGED, UNMANAGED, UNKNOWN)

_IDENTITY_FIELDS = ("provider", "target_kind", "target_name", "location")


@dataclass(frozen=True)
class ExecutionTarget:
    """A physical resolution of one (provider, target_kind, target_name)
    identity. Construction itself is the validation boundary — see the
    module docstring's RESOLUTION SEMANTICS. `location` is opaque here;
    only provider-specific code (e.g. executors/nginx.py) interprets it."""
    provider: str
    target_kind: str
    target_name: str
    location: str
    management_scope: str

    def __post_init__(self) -> None:
        for name in _IDENTITY_FIELDS:
            value = getattr(self, name)
            if not isinstance(value, str) or not value.strip():
                raise ValueError(f"ExecutionTarget.{name} must be a non-empty string, got {value!r}")
        if self.management_scope not in MANAGEMENT_SCOPES:
            raise ValueError(
                f"ExecutionTarget.management_scope must be one of {MANAGEMENT_SCOPES}, "
                f"got {self.management_scope!r}")

    def identity(self) -> tuple:
        return (self.provider, self.target_kind, self.target_name)


class TargetRegistry:
    """An explicit, caller-supplied mapping from logical artifact identity
    to an ExecutionTarget. Never populated by inference — see the module
    docstring's WHY A REGISTRY section for why that is the correct
    behavior here, not a missing feature. A plain class, not a dataclass:
    construction validates its entries (see RESOLUTION SEMANTICS), which
    a dataclass-generated `__init__` cannot do."""

    def __init__(self, targets=()) -> None:
        # Stored as a tuple, not a dict: see RESOLUTION SEMANTICS above —
        # deduplicating by identity here would silently hide a collision.
        materialized = tuple(targets)
        for t in materialized:
            if not isinstance(t, ExecutionTarget):
                raise ValueError(f"TargetRegistry entries must be ExecutionTarget, got {type(t).__name__}")
        self.targets = materialized

    def resolve(self, provider: str, target_kind: str, target_name: str) -> tuple:
        """Returns (ExecutionTarget | None, list[Diagnostic]). Never
        raises for a missing or ambiguous mapping — those are data-shaped
        outcomes of a caller-supplied registry, not misuse of this API."""
        wanted = (provider, target_kind, target_name)
        matches = [t for t in self.targets if t.identity() == wanted]
        if not matches:
            return None, [Diagnostic(
                "target_not_mapped", "error", target_name, "$.provider/target_kind/target_name",
                f"no execution target is mapped for provider={provider!r} target_kind={target_kind!r} "
                f"target_name={target_name!r}; refusing to guess a location")]
        if len(matches) > 1:
            return None, [Diagnostic(
                "ambiguous_target_mapping", "error", target_name, "$.provider/target_kind/target_name",
                f"{len(matches)} execution targets are mapped for provider={provider!r} "
                f"target_kind={target_kind!r} target_name={target_name!r}; refusing to pick one")]
        return matches[0], []
