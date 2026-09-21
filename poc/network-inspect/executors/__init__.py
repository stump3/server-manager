"""
poc/network-inspect/executors/
=================================

EXPERIMENTAL / RESEARCH POC — see poc/network-inspect/README.md.

The Executor layer consumes a Renderer's `RenderResult` (renderers/*.py)
and is responsible for HOW rendered artifacts are safely applied — never
for WHAT should exist (Planner), whether that is semantically valid
(Plan Validator), or what the artifacts contain (Renderer).

    core.py   — provider-independent transaction contract: `prepare()`
                (dry run), `execute()`, `Transaction`, `ExecutionResult`,
                and the two narrow interfaces `ProviderExecutor` /
                `ExecutionPort`. See core.py's module docstring.
    nginx.py  — the nginx `ProviderExecutor` (structural preflight only).

FOUNDATION STAGE: nothing in this package can touch the host. There is
no `ExecutionPort` implementation here; real primitives (backup, atomic
write, `nginx -t`, restore) are a future stage.
"""
