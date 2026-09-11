"""
poc/network-inspect/tests/_loader.py
======================================

EXPERIMENTAL / RESEARCH POC — shared test bootstrap, not a test
framework. poc/network-inspect/ is not a valid Python package name
(hyphen), so none of this PoC's modules can be imported the normal
package-relative way from tests/. When network-inspect.sh runs
inventory_build.py directly, Python puts that script's own directory
at sys.path[0] automatically — the sibling imports inside
inventory_build.py (from run_command import ..., from providers
import nginx as nginx_provider, etc.) rely on exactly that. Test
files loading these modules via importlib.util.spec_from_file_location
don't get that for free, so this one small shared helper inserts
poc/network-inspect/ onto sys.path once, before any test file
loads a module under test — avoiding every test file re-deriving the
same three lines, and avoiding the alternative of turning this PoC
into an installable package just to satisfy test imports (out of
scope, and not needed for a one-shot inspection script).
"""

from __future__ import annotations

import sys
from pathlib import Path

PACKAGE_DIR = Path(__file__).resolve().parent.parent

if str(PACKAGE_DIR) not in sys.path:
    sys.path.insert(0, str(PACKAGE_DIR))
