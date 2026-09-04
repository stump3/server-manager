#!/usr/bin/env python3
"""
poc/network-inspect/tests/test_run_command.py
================================================

EXPERIMENTAL / RESEARCH POC — direct tests for run_command.py, the
shared subprocess-safety primitive extracted from inventory_build.py
during the network-inspect architecture split (see README.md
"Architecture"). Previously this logic was only exercised indirectly
through whatever discovery function happened to call it; now that it
is a standalone module with its own narrow contract ("did the OS run
this command, and if so what came back"), it gets its own direct
tests.

Run with:
    python3 -m unittest discover -s poc/network-inspect/tests -v
"""

from __future__ import annotations

import unittest

import _loader  # noqa: F401 - adds poc/network-inspect/ to sys.path

import run_command


class TestRun(unittest.TestCase):
    def test_successful_command(self):
        result = run_command.run(["echo", "hello"])
        self.assertTrue(result.ok)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), "hello")
        self.assertIsNone(result.reason)

    def test_nonzero_exit_is_still_ok(self):
        """A command that ran and exited non-zero is still `ok=True` —
        `ok` answers 'did the OS run this at all', not 'did it
        succeed'. Whether a non-zero exit means 'unresolved' or
        'confirmed absent' is entirely up to the caller."""
        result = run_command.run(["false"])
        self.assertTrue(result.ok)
        self.assertEqual(result.returncode, 1)

    def test_missing_binary(self):
        result = run_command.run(["this-binary-almost-certainly-does-not-exist-xyz"])
        self.assertFalse(result.ok)
        self.assertEqual(result.reason, "not_found")
        self.assertIsNone(result.returncode)

    def test_timeout(self):
        result = run_command.run(["sleep", "5"], timeout=0.1)
        self.assertFalse(result.ok)
        self.assertEqual(result.reason, "timeout")

    def test_stdout_and_stderr_both_captured(self):
        result = run_command.run(
            ["python3", "-c", "import sys; print('out'); print('err', file=sys.stderr)"]
        )
        self.assertTrue(result.ok)
        self.assertIn("out", result.stdout)
        self.assertIn("err", result.stderr)


class TestWhich(unittest.TestCase):
    def test_finds_a_real_binary(self):
        self.assertIsNotNone(run_command.which("python3"))

    def test_missing_binary_returns_none(self):
        self.assertIsNone(run_command.which("this-binary-almost-certainly-does-not-exist-xyz"))


if __name__ == "__main__":
    unittest.main()
