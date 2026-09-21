#!/usr/bin/env python3
"""
poc/network-inspect/executors/core.py
=========================================

EXPERIMENTAL / RESEARCH POC — the provider-independent Executor
foundation and transaction contract. Renderer decides WHAT
configuration/artifacts should exist; this module decides HOW they are
safely applied. FOUNDATION STAGE: nothing here mutates the host — there
is no filesystem, subprocess, shell, network or systemctl access in this
package, and no `ExecutionPort` implementation. Real primitives are a
future stage (see RUNTIME vs STRUCTURAL PREFLIGHT).

CONTRACT
----------
    prepare(render_result, provider_executor)          -> ExecutionResult
    execute(render_result, provider_executor, port)    -> ExecutionResult

`prepare()` is the dry run: it proves the RenderResult is structurally
executable and touches nothing. `execute()` drives the full transaction
through an injected `ExecutionPort`. Both return an `ExecutionResult`
that mirrors renderers/nginx.py's result shape (`valid`, `provider`,
`diagnostics`, `.errors()`, `.warnings()`, `.as_dict()`) — same field
names, independently defined here (this package must not import any
renderer; see ARCHITECTURAL BOUNDARY).

Every data problem is a structured Diagnostic — never a raised exception
and never stdout/stderr output. The only exception this module raises is
`InvalidTransition`, for misuse of the `Transaction` state machine.

LIFECYCLE (Transaction states)
--------------------------------
    NEW -> PREPARED -> VALIDATED -> BACKED_UP -> APPLIED -> VERIFIED -> COMMITTED
    any of NEW..APPLIED -> FAILED;   FAILED -> ROLLED_BACK

    NEW -> PREPARED     structural preflight passed (pure, no port)
    PREPARED -> VALIDATED   runtime preflight passed (port; future checks)
    VALIDATED -> BACKED_UP  a backup exists for EVERY artifact
    BACKED_UP -> APPLIED    every artifact applied, in order
    APPLIED -> VERIFIED     whole-set verification passed
    VERIFIED -> COMMITTED   terminal success (pure state change here)
    FAILED -> ROLLED_BACK   legal only if the failure happened while
                            mutation was possible (from BACKED_UP or
                            APPLIED) AND every restore succeeded

`BACKED_UP` is the one state beyond the minimal example in the stage
brief: it makes "APPLIED requires a complete backup" a property of the
state machine rather than of caller discipline. BACKED_UP also doubles
as "apply in progress" — a failure from it means mutation is possible.

Any transition not in the table raises `InvalidTransition`
deterministically (same message for the same misuse).

STATUS (ExecutionResult.status) — exhaustive, mutually exclusive
------------------------------------------------------------------
    prepared            dry run OK; host untouched.            (PREPARED)
    validation_failed   failed BEFORE any mutation: prepare, runtime
                        preflight, or backup. Host untouched.  (FAILED)
    apply_failed        failed while applying AND rollback did
                        not complete. HOST STATE UNKNOWN.      (FAILED)
    verification_failed failed while verifying AND rollback did
                        not complete. HOST STATE UNKNOWN.      (FAILED)
    applied             every artifact applied and verified.   (COMMITTED)
    rolled_back         an apply/verify failure was fully
                        undone; host restored.                 (ROLLED_BACK)

`ExecutionResult.failed_phase` records where the PRIMARY failure
happened (prepare | runtime_preflight | backup | apply | verify) even
when the final status is `rolled_back`. Rule of thumb for consumers:
`apply_failed` / `verification_failed` are the two statuses that mean
"operator attention required"; both always carry `rollback_failed`
diagnostics AFTER the primary failure diagnostic — the original failure
is never replaced by the rollback failure.

ARTIFACT CONTRACT (fields consumed from a Renderer's Artifact)
-----------------------------------------------------------------
Consumed and REQUIRED (non-empty `str`): artifact_id, target_kind,
target_name, content. `provider` is read from the RenderResult, not the
Artifact. Anything else — an extra Artifact field, an extra RenderResult
field, a non-dataclass object — is REJECTED, not ignored: if the
Renderer's contract grows (say a `mode` or a target path), the Executor
must be updated deliberately rather than silently applying an artifact
without honoring a field it does not understand. Identifiers
(artifact_id, target_kind, target_name) must additionally contain no
control characters. `content` is passed through byte-identical and never
inspected, edited, or completed.

Ordering: the Executor never reorders. Artifacts are backed up, applied
and verified in RenderResult order and restored in exact reverse.

PREFLIGHT — STRUCTURAL (now) vs RUNTIME (future stage)
---------------------------------------------------------
STRUCTURAL PREFLIGHT is pure and implemented here plus in each
`ProviderExecutor.structural_preflight()`: RenderResult shape, `valid`
is True, provider matches, artifacts non-empty and well-formed, unique
ids, supported target kinds. It runs in `prepare()` and as the first
step of `execute()`.

RUNTIME PREFLIGHT is `ExecutionPort.runtime_preflight()` and is NOT
implemented in this stage: for nginx it will cover target path allowed,
ownership/permissions, "managed by server-manager", correct nginx
configuration scope, and `nginx -t` syntax validation.

EXECUTION PORT CONTRACT (what a future runtime stage must provide)
--------------------------------------------------------------------
Checks RETURN a list of Diagnostic-shaped objects (an "error" severity
entry fails the phase); actions RAISE on failure (any Exception).

    runtime_preflight(artifacts)  -> diagnostics    check, whole set
    backup(artifact)              -> opaque handle  action, per artifact
    apply(artifact)               -> None           action, per artifact
    verify(artifacts)             -> diagnostics    check, whole set
    restore(artifact, handle)     -> None           action, per artifact

`apply` and `restore` MUST each be atomic for their one artifact —
replace-by-rename in the artifact's own directory (tempfile + os.replace,
per docs/CONTRACTS.md contract 8 and docs/ENGINEER_GUIDELINES.md §4), so
a failed or interrupted call leaves that artifact either wholly old or
wholly new. `restore` must be safe for an artifact whose `apply` failed
midway or never ran (restore-to-backup is unconditional and idempotent).
POSIX has no atomic multi-file replace, so MULTI-ARTIFACT all-or-nothing
is provided by the TRANSACTION, not by the port: back up all, apply all,
verify all, and on any failure restore everything attempted.

MULTI-ARTIFACT / FAILURE SEMANTICS
------------------------------------
1. All backups are taken before the first apply. A backup failure means
   nothing was mutated and no restore is issued.
2. On an apply failure at artifact k, the Executor stops applying,
   then restores artifacts 1..k (k included — it may be partly applied)
   in reverse order, continuing past individual restore failures to
   minimise damage. Nothing about artifacts 1..k-1 is lost:
   `applied_artifacts` lists what applied, `restored_artifacts` what was
   undone.
3. On a verify failure every artifact is restored.
4. Success of the rollback is all-or-nothing: only if EVERY restore
   succeeded does the transaction reach ROLLED_BACK.

Outcomes (scenario -> tx state -> status -> failed_phase):
    invalid RenderResult / unsupported artifact /
      structural preflight failure   FAILED       validation_failed   prepare
    runtime preflight failure        FAILED       validation_failed   runtime_preflight
    backup failure                   FAILED       validation_failed   backup
    apply failure, rollback OK       ROLLED_BACK  rolled_back         apply
    apply failure, rollback fails    FAILED       apply_failed        apply
    verify failure, rollback OK      ROLLED_BACK  rolled_back         verify
    verify failure, rollback fails   FAILED       verification_failed verify
    success                          COMMITTED    applied             None
    dry run                          PREPARED     prepared            None

KNOWN LIMITS (deliberately out of scope for this stage)
---------------------------------------------------------
- Rollback is in-process compensation. A process killed between two
  artifacts, or a BaseException (KeyboardInterrupt) mid-apply, is not
  recovered; a durable transaction journal / signal handling belongs to
  the runtime stage (docs/CONTRACTS.md contract 12).
- No activation phase (e.g. nginx reload) exists yet; the runtime stage
  must decide whether activation is part of `apply` (and then `restore`
  must re-activate) or a separate transaction phase.
- `rollback_available` reports that this execution's backups exist and
  were not consumed by a successful rollback; this stage exposes no
  entry point to roll back a COMMITTED transaction later.

ARCHITECTURAL BOUNDARY
------------------------
ALLOWED to import: the standard library only. FORBIDDEN to import:
planner, desired_state, inventory_build, net_facts, capabilities,
plan_ir, plan_validator, renderers.*, providers.*, hysteria2_config,
run_command, or anything touching subprocess/filesystem/network.
Dependency direction: Planner -> Plan IR -> Validator -> Renderer ->
Executor. No upstream layer may import this package. See
tests/test_executor.py's architecture tests (AST-based, enforced).

DETERMINISM
-------------
No timestamps, UUIDs, or dict/set iteration-order dependence. The same
RenderResult and the same port behavior always produce an equal
`ExecutionResult` and the same sequence of port calls.
"""

from __future__ import annotations

import dataclasses
from dataclasses import dataclass, field as dc_field
from typing import Any, Optional, Protocol

# ─────────────────────────────────────────────────────────────────────
# Constants
# ─────────────────────────────────────────────────────────────────────

# Transaction states
NEW = "NEW"
PREPARED = "PREPARED"
VALIDATED = "VALIDATED"
BACKED_UP = "BACKED_UP"
APPLIED = "APPLIED"
VERIFIED = "VERIFIED"
COMMITTED = "COMMITTED"
FAILED = "FAILED"
ROLLED_BACK = "ROLLED_BACK"

STATES = (NEW, PREPARED, VALIDATED, BACKED_UP, APPLIED, VERIFIED, COMMITTED, FAILED, ROLLED_BACK)

_TRANSITIONS = {
    NEW: (PREPARED, FAILED),
    PREPARED: (VALIDATED, FAILED),
    VALIDATED: (BACKED_UP, FAILED),
    BACKED_UP: (APPLIED, FAILED),
    APPLIED: (VERIFIED, FAILED),
    VERIFIED: (COMMITTED,),
    COMMITTED: (),
    FAILED: (ROLLED_BACK,),
    ROLLED_BACK: (),
}

# A failure from one of these states happened while mutation was possible,
# so a rollback is meaningful (and FAILED -> ROLLED_BACK is legal).
_MUTATION_POSSIBLE_FROM = (BACKED_UP, APPLIED)

# Failure phase, keyed by the state the transaction failed FROM.
PHASE_PREPARE = "prepare"
PHASE_RUNTIME_PREFLIGHT = "runtime_preflight"
PHASE_BACKUP = "backup"
PHASE_APPLY = "apply"
PHASE_VERIFY = "verify"
_PHASE_BY_FAILED_FROM = {
    NEW: PHASE_PREPARE,
    PREPARED: PHASE_RUNTIME_PREFLIGHT,
    VALIDATED: PHASE_BACKUP,
    BACKED_UP: PHASE_APPLY,
    APPLIED: PHASE_VERIFY,
}

# ExecutionResult.status
STATUS_PREPARED = "prepared"
STATUS_VALIDATION_FAILED = "validation_failed"
STATUS_APPLY_FAILED = "apply_failed"
STATUS_VERIFICATION_FAILED = "verification_failed"
STATUS_APPLIED = "applied"
STATUS_ROLLED_BACK = "rolled_back"
STATUSES = (
    STATUS_PREPARED, STATUS_VALIDATION_FAILED, STATUS_APPLY_FAILED,
    STATUS_VERIFICATION_FAILED, STATUS_APPLIED, STATUS_ROLLED_BACK,
)

_RENDER_RESULT_FIELDS = ("valid", "provider", "artifacts", "diagnostics")
_ARTIFACT_FIELDS = ("artifact_id", "target_kind", "target_name", "content")
_IDENTIFIER_FIELDS = ("artifact_id", "target_kind", "target_name")
_PORT_OPERATIONS = ("runtime_preflight", "backup", "apply", "verify", "restore")
_SEVERITIES = ("error", "warning")


# ─────────────────────────────────────────────────────────────────────
# Result types — deliberately mirror renderers/nginx.py's Diagnostic /
# RenderResult field names and helper methods; independently defined.
# ─────────────────────────────────────────────────────────────────────

@dataclass
class Diagnostic:
    code: str
    severity: str  # "error" | "warning"
    resource_id: Optional[str]
    field: Optional[str]
    message: str

    def as_dict(self) -> dict:
        return {
            "code": self.code, "severity": self.severity,
            "resource_id": self.resource_id, "field": self.field,
            "message": self.message,
        }


@dataclass(frozen=True)
class PreparedArtifact:
    """Immutable snapshot of one Renderer artifact, as handed to a
    ProviderExecutor / ExecutionPort. `content` is the Renderer's text,
    untouched. `provider` comes from the RenderResult."""
    provider: str
    artifact_id: str
    target_kind: str
    target_name: str
    content: str

    def as_dict(self) -> dict:
        return {
            "provider": self.provider, "artifact_id": self.artifact_id,
            "target_kind": self.target_kind, "target_name": self.target_name,
            "content": self.content,
        }


@dataclass
class ExecutionResult:
    valid: bool                      # True iff status is "prepared" or "applied"
    provider: Optional[str]
    status: str                      # one of STATUSES
    failed_phase: Optional[str] = None
    diagnostics: list = dc_field(default_factory=list)
    applied_artifacts: list = dc_field(default_factory=list)   # artifact_ids whose apply() returned, in apply order
    restored_artifacts: list = dc_field(default_factory=list)  # artifact_ids whose restore() returned, in restore order
    rollback_available: bool = False  # backups exist and were not consumed by a successful rollback

    def as_dict(self) -> dict:
        return {
            "valid": self.valid, "provider": self.provider, "status": self.status,
            "failed_phase": self.failed_phase,
            "diagnostics": [d.as_dict() for d in self.diagnostics],
            "applied_artifacts": list(self.applied_artifacts),
            "restored_artifacts": list(self.restored_artifacts),
            "rollback_available": self.rollback_available,
        }

    def errors(self) -> list:
        return [d for d in self.diagnostics if d.severity == "error"]

    def warnings(self) -> list:
        return [d for d in self.diagnostics if d.severity == "warning"]


# ─────────────────────────────────────────────────────────────────────
# Narrow interfaces
# ─────────────────────────────────────────────────────────────────────

class ProviderExecutor(Protocol):
    """Pure, provider-specific STRUCTURAL policy. Must not perform I/O."""
    provider: str

    def structural_preflight(self, artifacts: tuple) -> list:
        """Given the ordered tuple of PreparedArtifact, return a list of
        Diagnostic-shaped objects (empty list == acceptable). Field paths
        should be `$.artifacts[<index>].<field>` (index into `artifacts`)."""
        ...


class ExecutionPort(Protocol):
    """Runtime primitives, injected. NOT implemented in this stage. See
    EXECUTION PORT CONTRACT in the module docstring. Checks return
    diagnostics; actions raise on failure."""
    provider: str

    def runtime_preflight(self, artifacts: tuple) -> list: ...
    def backup(self, artifact: PreparedArtifact) -> Any: ...
    def apply(self, artifact: PreparedArtifact) -> None: ...
    def verify(self, artifacts: tuple) -> list: ...
    def restore(self, artifact: PreparedArtifact, backup: Any) -> None: ...


# ─────────────────────────────────────────────────────────────────────
# Transaction — explicit state machine, no I/O, no nginx knowledge
# ─────────────────────────────────────────────────────────────────────

class InvalidTransition(Exception):
    """Raised, deterministically, for any transition not in the table."""


class Transaction:
    def __init__(self) -> None:
        self._state = NEW
        self._failed_from: Optional[str] = None
        self._history = [NEW]

    @property
    def state(self) -> str:
        return self._state

    @property
    def history(self) -> tuple:
        return tuple(self._history)

    @property
    def failed_phase(self) -> Optional[str]:
        return _PHASE_BY_FAILED_FROM.get(self._failed_from) if self._failed_from else None

    def transition(self, target: str) -> None:
        if target not in STATES:
            raise InvalidTransition(f"unknown transaction state {target!r}")
        if target not in _TRANSITIONS[self._state]:
            raise InvalidTransition(f"invalid transition {self._state} -> {target}")
        if (self._state, target) == (FAILED, ROLLED_BACK) and self._failed_from not in _MUTATION_POSSIBLE_FROM:
            raise InvalidTransition(
                f"invalid transition {FAILED} -> {ROLLED_BACK}: failure from "
                f"{self._failed_from} happened before any mutation was possible")
        if target == FAILED:
            self._failed_from = self._state
        self._state = target
        self._history.append(target)


# ─────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────

def _err(diags: list, code: str, resource_id: Optional[str], field_: Optional[str], message: str) -> None:
    diags.append(Diagnostic(code, "error", resource_id, field_, message))


def _describe(exc: BaseException) -> str:
    return f"{type(exc).__name__}: {exc}"


def _dataclass_field_names(obj: Any) -> Optional[tuple]:
    if dataclasses.is_dataclass(obj) and not isinstance(obj, type):
        return tuple(f.name for f in dataclasses.fields(obj))
    return None


def _has_control_char(text: str) -> bool:
    return any(ord(ch) < 32 or ord(ch) == 127 for ch in text)


def _coerce_diagnostics(raw: Any, origin: str, invalid_code: str, diags: list) -> Optional[list]:
    """Normalise a port/provider check result into our own Diagnostics.
    Returns None (after appending an `invalid_code` error) if `raw` is not
    a list of Diagnostic-shaped objects with a known severity — a check
    that cannot report properly is a failed check, never a passed one."""
    if not isinstance(raw, (list, tuple)):
        _err(diags, invalid_code, None, None,
             f"{origin} must return a list of diagnostics, got {type(raw).__name__}")
        return None
    out = []
    for item in raw:
        try:
            d = Diagnostic(str(item.code), str(item.severity), item.resource_id, item.field, str(item.message))
        except AttributeError:
            _err(diags, invalid_code, None, None, f"{origin} returned an entry that is not diagnostic-shaped")
            return None
        if d.severity not in _SEVERITIES:
            _err(diags, invalid_code, None, None, f"{origin} returned an unknown severity {d.severity!r}")
            return None
        out.append(d)
    return out


def _provider_name(render_result: Any) -> Optional[str]:
    name = getattr(render_result, "provider", None)
    return name if isinstance(name, str) else None


# ─────────────────────────────────────────────────────────────────────
# Structural preparation (pure)
# ─────────────────────────────────────────────────────────────────────

def _check_collaborators(provider_executor: Any, port: Any, need_port: bool, diags: list) -> bool:
    ok = True
    pe_name = getattr(provider_executor, "provider", None)
    if not isinstance(pe_name, str) or not pe_name.strip():
        _err(diags, "invalid_provider_executor", None, "provider",
             "provider executor must expose a non-empty string `provider`")
        ok = False
    if not callable(getattr(provider_executor, "structural_preflight", None)):
        _err(diags, "invalid_provider_executor", None, "structural_preflight",
             "provider executor must expose a callable `structural_preflight`")
        ok = False
    if need_port:
        # Completeness is checked BEFORE any operation can run: a port
        # that cannot `restore` must never be allowed to `apply`.
        missing = [op for op in _PORT_OPERATIONS if not callable(getattr(port, op, None))]
        if missing:
            _err(diags, "invalid_execution_port", None, None,
                 f"execution port is missing required operation(s): {missing}")
            ok = False
        port_name = getattr(port, "provider", None)
        if not isinstance(port_name, str) or not port_name.strip():
            _err(diags, "invalid_execution_port", None, "provider",
                 "execution port must expose a non-empty string `provider`")
            ok = False
        elif isinstance(pe_name, str) and port_name != pe_name:
            _err(diags, "provider_mismatch", None, "provider",
                 f"execution port is for provider {port_name!r} but provider executor is for {pe_name!r}")
            ok = False
    return ok


def _check_artifact(index: int, obj: Any, provider: str, diags: list) -> Optional[PreparedArtifact]:
    base = f"$.artifacts[{index}]"
    names = _dataclass_field_names(obj)
    if names is None:
        _err(diags, "malformed_artifact", None, base,
             f"artifact must be a dataclass instance with fields {list(_ARTIFACT_FIELDS)}, "
             f"got {type(obj).__name__}")
        return None

    rid = getattr(obj, "artifact_id", None)
    resource_id = rid if isinstance(rid, str) and rid else None
    ok = True
    for name in _ARTIFACT_FIELDS:
        if name not in names:
            _err(diags, "missing_artifact_field", resource_id, f"{base}.{name}",
                 f"artifact has no required field {name!r}")
            ok = False
    for name in names:
        if name not in _ARTIFACT_FIELDS:
            _err(diags, "unexpected_artifact_field", resource_id, f"{base}.{name}",
                 f"artifact has field {name!r} which this Executor does not understand; refusing to "
                 f"apply an artifact without honoring it")
            ok = False
    if not ok:
        return None

    values = {}
    for name in _ARTIFACT_FIELDS:
        value = getattr(obj, name)
        if not isinstance(value, str):
            _err(diags, "invalid_artifact_field", resource_id, f"{base}.{name}",
                 f"artifact field {name!r} must be a string, got {type(value).__name__}")
            ok = False
        elif not value.strip():
            _err(diags, "invalid_artifact_field", resource_id, f"{base}.{name}",
                 f"artifact field {name!r} must not be empty")
            ok = False
        elif name in _IDENTIFIER_FIELDS and _has_control_char(value):
            _err(diags, "invalid_artifact_field", resource_id, f"{base}.{name}",
                 f"artifact field {name!r} must not contain control characters")
            ok = False
        values[name] = value
    if not ok:
        return None
    return PreparedArtifact(provider, values["artifact_id"], values["target_kind"],
                            values["target_name"], values["content"])


def _check_render_result(render_result: Any, provider_executor: Any, diags: list) -> Optional[tuple]:
    names = _dataclass_field_names(render_result)
    if names is None:
        _err(diags, "malformed_render_result", None, "$",
             f"render result must be a dataclass instance with fields {list(_RENDER_RESULT_FIELDS)}, "
             f"got {type(render_result).__name__}")
        return None
    bad = False
    for name in _RENDER_RESULT_FIELDS:
        if name not in names:
            _err(diags, "malformed_render_result", None, f"$.{name}",
                 f"render result has no required field {name!r}")
            bad = True
    for name in names:
        if name not in _RENDER_RESULT_FIELDS:
            _err(diags, "unexpected_render_result_field", None, f"$.{name}",
                 f"render result has field {name!r} which this Executor does not understand")
            bad = True
    if bad:
        return None

    if not isinstance(render_result.valid, bool):
        _err(diags, "malformed_render_result", None, "$.valid", "`valid` must be a bool")
        bad = True
    if not isinstance(render_result.provider, str) or not render_result.provider.strip():
        _err(diags, "malformed_render_result", None, "$.provider", "`provider` must be a non-empty string")
        bad = True
    if not isinstance(render_result.artifacts, (list, tuple)):
        _err(diags, "malformed_render_result", None, "$.artifacts", "`artifacts` must be a list")
        bad = True
    if not isinstance(render_result.diagnostics, (list, tuple)):
        _err(diags, "malformed_render_result", None, "$.diagnostics", "`diagnostics` must be a list")
        bad = True
    if bad:
        return None

    renderer_errors = sorted({str(getattr(d, "code", None)) for d in render_result.diagnostics
                              if getattr(d, "severity", None) == "error"})

    # A partial RenderResult (some artifacts rendered, some groups failed)
    # is valid=False: artifacts are present but nothing may be applied.
    if render_result.valid is not True:
        _err(diags, "invalid_render_result", None, "$.valid",
             f"render result is not valid; renderer errors: {renderer_errors or 'none reported'}; "
             f"nothing will be applied")
        return None
    if renderer_errors:
        _err(diags, "inconsistent_render_result", None, "$.diagnostics",
             f"render result claims valid=True but carries error diagnostics {renderer_errors}")
        return None

    if render_result.provider != provider_executor.provider:
        _err(diags, "unsupported_provider", None, "$.provider",
             f"render result is for provider {render_result.provider!r}; this executor handles "
             f"{provider_executor.provider!r}")
        return None

    if not render_result.artifacts:
        _err(diags, "no_artifacts", None, "$.artifacts",
             "render result has no artifacts; there is nothing to execute")
        return None

    mark = len(diags)
    prepared = []
    for index, obj in enumerate(render_result.artifacts):
        art = _check_artifact(index, obj, render_result.provider, diags)
        if art is not None:
            prepared.append(art)
    if len(diags) != mark:
        return None

    seen: dict = {}
    for index, art in enumerate(prepared):
        if art.artifact_id in seen:
            _err(diags, "duplicate_artifact_id", art.artifact_id, f"$.artifacts[{index}].artifact_id",
                 f"artifact_id {art.artifact_id!r} already used by artifacts[{seen[art.artifact_id]}]")
        else:
            seen[art.artifact_id] = index
    if len(diags) != mark:
        return None

    artifacts = tuple(prepared)
    try:
        raw = provider_executor.structural_preflight(artifacts)
    except Exception as exc:  # fail closed: a crashing policy is a failed policy
        _err(diags, "structural_preflight_failed", None, None,
             f"provider structural preflight raised {_describe(exc)}")
        return None
    coerced = _coerce_diagnostics(raw, "structural_preflight", "structural_preflight_failed", diags)
    if coerced is None:
        return None
    diags.extend(coerced)
    if any(d.severity == "error" for d in coerced):
        return None
    return artifacts


def _begin(render_result: Any, provider_executor: Any, port: Any, need_port: bool):
    """NEW -> PREPARED, or NEW -> FAILED. Returns (tx, artifacts_or_None, diagnostics)."""
    tx = Transaction()
    diags: list = []
    artifacts = None
    if _check_collaborators(provider_executor, port, need_port, diags):
        artifacts = _check_render_result(render_result, provider_executor, diags)
    tx.transition(PREPARED if artifacts is not None else FAILED)
    return tx, artifacts, diags


# ─────────────────────────────────────────────────────────────────────
# Result assembly
# ─────────────────────────────────────────────────────────────────────

def _finish(tx: Transaction, render_result: Any, diags: list, applied: list, restored: list,
            rollback_available: bool) -> ExecutionResult:
    state, phase = tx.state, tx.failed_phase
    if state == PREPARED:
        status = STATUS_PREPARED
    elif state == COMMITTED:
        status = STATUS_APPLIED
    elif state == ROLLED_BACK:
        status = STATUS_ROLLED_BACK
    elif phase == PHASE_APPLY:
        status = STATUS_APPLY_FAILED
    elif phase == PHASE_VERIFY:
        status = STATUS_VERIFICATION_FAILED
    else:
        status = STATUS_VALIDATION_FAILED
    return ExecutionResult(
        valid=status in (STATUS_PREPARED, STATUS_APPLIED),
        provider=_provider_name(render_result),
        status=status,
        failed_phase=phase,
        diagnostics=list(diags),
        applied_artifacts=list(applied),
        restored_artifacts=list(restored),
        rollback_available=rollback_available,
    )


def _run_check(tx: Transaction, check, artifacts: tuple, origin: str, failure_code: str,
               diags: list) -> bool:
    """Run a port check. On any error-severity finding, an exception, or a
    malformed return: append the failure diagnostics (summary first, then
    the port's own findings), transition to FAILED, and return False."""
    try:
        raw = check(artifacts)
    except Exception as exc:
        _err(diags, failure_code, None, None, f"{origin} raised {_describe(exc)}")
        tx.transition(FAILED)
        return False
    found = _coerce_diagnostics(raw, origin, failure_code, diags)
    if found is None:
        tx.transition(FAILED)
        return False
    if any(d.severity == "error" for d in found):
        n = sum(1 for d in found if d.severity == "error")
        _err(diags, failure_code, None, None, f"{origin} reported {n} error(s)")
        diags.extend(found)
        tx.transition(FAILED)
        return False
    diags.extend(found)
    return True


def _rollback(tx: Transaction, port: Any, attempted: list, handles: dict, diags: list):
    """Restore every artifact whose apply was attempted, in reverse order,
    continuing past individual failures. Returns (restored_ids, all_ok)."""
    restored: list = []
    all_ok = True
    for art in reversed(attempted):
        try:
            port.restore(art, handles[art.artifact_id])
            restored.append(art.artifact_id)
        except Exception as exc:
            all_ok = False
            _err(diags, "rollback_failed", art.artifact_id, None,
                 f"restoring {art.artifact_id!r} failed: {_describe(exc)}")
    if all_ok:
        tx.transition(ROLLED_BACK)
    return restored, all_ok


# ─────────────────────────────────────────────────────────────────────
# Public entry points
# ─────────────────────────────────────────────────────────────────────

def prepare(render_result: Any, provider_executor: Any) -> ExecutionResult:
    """Dry run. Proves the RenderResult is structurally executable
    (NEW -> PREPARED) and nothing else: no port, no I/O, no mutation.
    Status is "prepared" or "validation_failed"."""
    tx, _artifacts, diags = _begin(render_result, provider_executor, None, need_port=False)
    return _finish(tx, render_result, diags, [], [], False)


def execute(render_result: Any, provider_executor: Any, port: Any) -> ExecutionResult:
    """Run the full transaction through `port`. See the module docstring
    for lifecycle, outcomes, and the port contract. Never raises for data
    or port failures; those become diagnostics."""
    tx, artifacts, diags = _begin(render_result, provider_executor, port, need_port=True)
    if artifacts is None:
        return _finish(tx, render_result, diags, [], [], False)

    # PREPARED -> VALIDATED : runtime preflight
    if not _run_check(tx, port.runtime_preflight, artifacts, "runtime_preflight",
                      "runtime_preflight_failed", diags):
        return _finish(tx, render_result, diags, [], [], False)
    tx.transition(VALIDATED)

    # VALIDATED -> BACKED_UP : a backup for EVERY artifact before any apply
    handles: dict = {}
    for art in artifacts:
        try:
            handles[art.artifact_id] = port.backup(art)
        except Exception as exc:
            _err(diags, "backup_failed", art.artifact_id, None,
                 f"backing up {art.artifact_id!r} failed: {_describe(exc)}")
            tx.transition(FAILED)
            return _finish(tx, render_result, diags, [], [], False)
    tx.transition(BACKED_UP)

    # BACKED_UP -> APPLIED : apply in order; first failure triggers rollback
    attempted: list = []
    applied: list = []
    for art in artifacts:
        attempted.append(art)
        try:
            port.apply(art)
        except Exception as exc:
            _err(diags, "apply_failed", art.artifact_id, None,
                 f"applying {art.artifact_id!r} failed: {_describe(exc)}")
            tx.transition(FAILED)
            restored, ok = _rollback(tx, port, attempted, handles, diags)
            return _finish(tx, render_result, diags, applied, restored, not ok)
        applied.append(art.artifact_id)
    tx.transition(APPLIED)

    # APPLIED -> VERIFIED : whole-set verification; failure rolls everything back
    if not _run_check(tx, port.verify, artifacts, "verify", "verification_failed", diags):
        restored, ok = _rollback(tx, port, attempted, handles, diags)
        return _finish(tx, render_result, diags, applied, restored, not ok)
    tx.transition(VERIFIED)

    # VERIFIED -> COMMITTED
    tx.transition(COMMITTED)
    return _finish(tx, render_result, diags, applied, [], True)
