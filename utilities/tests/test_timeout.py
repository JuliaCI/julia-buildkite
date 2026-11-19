#!/usr/bin/env python3
"""Check the escalation of utilities/timeout.jl when the wrapped command hangs.

The tests run timeout.jl for real under the `julia` on PATH (or $JULIA), with short
timeouts, and skip when there is none outside CI. Core dumps are disabled, so the SIGQUIT
stage leaves nothing behind.
"""

import os
from pathlib import Path
import resource
import shutil
import signal
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
JULIA = os.environ.get("JULIA") or shutil.which("julia")


def no_cores():
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


# CI must not skip these silently
@unittest.skipIf(JULIA is None and not os.environ.get("CI"), "no julia on PATH")
class TimeoutTests(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(JULIA, "no julia on PATH")
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def run_timeout(self, *cmd, **env):
        # Escalate as on Windows: SIGQUIT the command alone, then SIGKILL.
        env = {**os.environ, "JL_TEST_TIMEOUT": "2s", "JL_TEARDOWN_TIMEOUT": "60s",
               "JL_KILL_TIMEOUT": "60s", "JL_TERM_DETACH": "false", "JL_TERM_SIGTERM": "false",
               "JL_TERM_SIGQUIT": "true", **env}
        env.pop("BUILDKITE", None)
        start = time.monotonic()
        # In its own session, so that a broken wrapper cannot leave the command behind
        with subprocess.Popen([JULIA, "--startup-file=no", str(ROOT / "utilities/timeout.jl"), *cmd],
                              cwd=self.tmp.name, env=env, preexec_fn=no_cores,
                              start_new_session=True, stdin=subprocess.DEVNULL,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as proc:
            try:
                stdout, stderr = proc.communicate(timeout=300)
            except BaseException:
                # before Popen reaps the wrapper, while its group ID is still ours
                os.killpg(proc.pid, signal.SIGKILL)
                raise
        return subprocess.CompletedProcess(proc.args, proc.returncode, stdout, stderr), \
            time.monotonic() - start

    def test_sigquit_ends_a_hung_command(self):
        # Without JL_TERM_DETACH (as on Windows) the command shares our stdio, and stays
        # "open" after it exits: each stage must still notice that it is gone, instead of
        # waiting out JL_KILL_TIMEOUT and sending SIGKILL to a dead process.
        proc, elapsed = self.run_timeout("sleep", "1000")
        self.assertIn("sending SIGQUIT", proc.stderr)
        self.assertNotIn("SIGKILL", proc.stderr)
        self.assertLess(elapsed, 30, proc.stderr)
        self.assertNotEqual(proc.returncode, 0, proc.stderr)

    def test_command_that_finishes(self):
        proc, _ = self.run_timeout("sh", "-c", "exit 3")
        self.assertEqual(proc.returncode, 3, proc.stderr)
        self.assertNotIn("SIGQUIT", proc.stderr)


if __name__ == "__main__":
    unittest.main()
