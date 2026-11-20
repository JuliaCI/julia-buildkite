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
import sys
import tempfile
import textwrap
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

    def test_detached_descendants_dump_through_the_driver(self):
        # A wrapper (as `Base.runtests`) runs a driver, which relays the output of a worker
        # in a session of its own, which has a child of its own.  The worker's SIGQUIT
        # output must reach us through the driver, before the driver itself is signalled,
        # and its child must be signalled first.
        worker = textwrap.dedent("""\
            import os, signal, subprocess, sys, time
            child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(1000)"])
            def quit(*_):
                try:
                    child.wait(timeout=10)
                    state = "gone"
                except subprocess.TimeoutExpired:
                    state = "alive"
                print("worker: SIGQUIT, child " + state, flush=True)
                os._exit(3)
            signal.signal(signal.SIGQUIT, quit)
            print("worker: ready", flush=True)
            while True:
                time.sleep(0.1)
            """)
        driver = textwrap.dedent("""\
            import subprocess, sys
            w = subprocess.Popen([sys.executable, "-c", sys.argv[1]], start_new_session=True,
                                 stdout=subprocess.PIPE, text=True)
            for line in w.stdout:
                print("From worker 2: " + line, end="", flush=True)
            w.wait()
            print("driver: worker exited", w.returncode, flush=True)
            import time
            time.sleep(1000)
            """)
        proc, elapsed = self.run_timeout(
            "sh", "-c", '"$0" -c "$1" "$2"; status=$?; exit $status', sys.executable, driver, worker,
            JL_TEST_TIMEOUT="5s", JL_TERM_DETACH="true", JL_DUMP_DETACHED="true")
        out = proc.stdout
        self.assertIn("From worker 2: worker: SIGQUIT, child gone", out, proc.stderr)
        self.assertIn("driver: worker exited 3", out, proc.stderr)
        self.assertIn("Sent SIGQUIT to the 2 process(es)", proc.stderr)
        self.assertIn("sending SIGQUIT to PGID", proc.stderr)
        self.assertNotIn("SIGKILL", proc.stderr)
        self.assertLess(elapsed, 30, proc.stderr)

    def test_command_that_finishes(self):
        proc, _ = self.run_timeout("sh", "-c", "exit 3")
        self.assertEqual(proc.returncode, 3, proc.stderr)
        self.assertNotIn("SIGQUIT", proc.stderr)


if __name__ == "__main__":
    unittest.main()
