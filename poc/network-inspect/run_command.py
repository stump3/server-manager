#!/usr/bin/env python3
"""
poc/network-inspect/run_command.py
===================================

EXPERIMENTAL / RESEARCH POC — see poc/network-inspect/README.md.

Extracted from inventory_build.py during the network-inspect
architecture split (see README.md "Architecture" section for the
full rationale). This module solves exactly one problem — "run a
read-only command safely and return a structured result" — and is
deliberately NOT a framework: no retry policy, no plugin system, no
command-building DSL. Every discovery/provider module in this PoC
(inventory_build.py's own correlation pipeline, providers/nginx.py,
providers/caddy.py) imports `run`/`which`/`RunResult` from here
instead of re-implementing the same
try/except-FileNotFoundError/TimeoutExpired/capture_output dance —
this was real, verified duplication (identical try/except shape
repeated at every subprocess call site) before this extraction, not
a speculative one.

The "ok vs not-ok" distinction here is intentionally shallow — it
only answers "did the OS actually let us run this command at all"
(binary missing, or it hung past the timeout). Whether the command's
own exit code / stdout content represents "available" / "absent" /
"unresolved" is a per-caller interpretation, made by whichever
discovery function called `run()` — this module has no opinion on
that, by design (see README.md's "FACT vs CAPABILITY" principle:
this module only concerns itself with "did the OS run my command",
not "what did the output mean").
"""

from __future__ import annotations

import os
import shutil
import subprocess
from dataclasses import dataclass
from typing import Optional

DEFAULT_TIMEOUT = float(os.environ.get("SM_NETWORK_INSPECT_TIMEOUT", "5"))


@dataclass
class RunResult:
    ok: bool               # did we get a completed process at all
    returncode: Optional[int]
    stdout: str
    stderr: str
    reason: Optional[str] = None   # "not_found" | "timeout" | None


def run(cmd: list[str], timeout: float = DEFAULT_TIMEOUT) -> RunResult:
    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        return RunResult(True, proc.returncode, proc.stdout, proc.stderr)
    except FileNotFoundError:
        return RunResult(False, None, "", "", reason="not_found")
    except subprocess.TimeoutExpired:
        return RunResult(False, None, "", "", reason="timeout")


def which(binname: str) -> Optional[str]:
    return shutil.which(binname)
