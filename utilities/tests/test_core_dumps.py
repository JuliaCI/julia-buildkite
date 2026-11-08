#!/usr/bin/env python3
"""Check the core dump limits that test_julia.sh applies while the tests run (utilities/core_dumps.sh).

`df` is replaced by a double that reports the free space in a file, so the tests can fake a
nearly full disk; the core dumps are small files named like real ones.
"""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
BASH = shutil.which("bash")
GIB_KIB = 1024 * 1024


class CoreDumpTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.work = Path(self.tmp.name) / "checkout"
        (self.work / "test").mkdir(parents=True)
        self.bin = Path(self.tmp.name) / "tools"
        self.bin.mkdir()
        self.free = Path(self.tmp.name) / "free_kib"
        self.set_free_gib(100)
        df = self.bin / "df"
        df.write_text(f'''#!/usr/bin/env bash
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/disk1 1000000000 0 $(cat {self.free}) 1% /"
''')
        df.chmod(0o755)
        self.env = {**os.environ, "PATH": f"{self.bin}:{os.environ['PATH']}"}

    def set_free_gib(self, gib):
        self.free.write_text(str(gib * GIB_KIB))

    def bash(self, script):
        proc = subprocess.Popen(
            [BASH, "-c", f"set -euo pipefail; source {ROOT / 'utilities/core_dumps.sh'}; {script}"],
            cwd=self.work, env=self.env, stdout=subprocess.PIPE, text=True)
        self.addCleanup(self.stop, proc)
        return proc

    @staticmethod
    def stop(proc):
        proc.kill()
        proc.wait()
        proc.stdout.close()

    def core(self, name):
        path = self.work / "test" / name
        path.write_bytes(b"core")
        return path

    def wait_for(self, condition, timeout=15):
        deadline = time.monotonic() + timeout
        while not condition():
            self.assertLess(time.monotonic(), deadline, "timed out")
            time.sleep(0.2)

    def test_limit_leaves_the_reserve_free(self):
        # The 4 cores that are kept share what is left after the reserve
        out, _ = self.bash("limit_core_dumps; ulimit -c").communicate()
        self.assertEqual(int(out), 20 * GIB_KIB)

        self.set_free_gib(15)
        out, _ = self.bash("limit_core_dumps; ulimit -c").communicate()
        self.assertEqual(int(out), 0)

        self.set_free_gib(100)
        self.env["MAX_CORE_DUMPS"] = "0"
        out, _ = self.bash("limit_core_dumps; ulimit -c").communicate()
        self.assertEqual(int(out), 0)

    def test_reaper_keeps_the_first_cores(self):
        first = [self.core(f"julia-pid{i}.core") for i in range(1, 5)]
        reaper = self.bash("reap_core_dumps")

        # The next core beyond MAX_CORE_DUMPS (4) goes, the first ones stay
        time.sleep(1)
        late = self.core("julia-pid5.core")
        self.wait_for(lambda: not late.exists())
        self.assertTrue(all(core.exists() for core in first))
        reaper.kill()
        out, _ = reaper.communicate()
        self.assertIn("Deleting core dump ./test/julia-pid5.core: already kept 4", out)

    def test_reaper_keeps_the_reserve_free(self):
        first = self.core("julia-pid1.core")
        self.bash("reap_core_dumps")
        time.sleep(1)
        second = self.core("julia-pid2.core")
        time.sleep(6)
        # Both were kept; once the disk fills up, only the first one stays
        self.set_free_gib(10)
        self.wait_for(lambda: not second.exists())
        self.assertTrue(first.exists())
        late = self.core("julia-pid3.core")
        self.wait_for(lambda: not late.exists())
        self.assertTrue(first.exists())

    def test_reaper_checks_a_recreated_core_again(self):
        # Core patterns without the PID reuse names
        self.env["MAX_CORE_DUMPS"] = "0"
        self.bash("reap_core_dumps")
        core = self.core("julia.core")
        self.wait_for(lambda: not core.exists())
        self.core("julia.core")
        self.wait_for(lambda: not core.exists())

    def test_reaper_stops_with_its_parent(self):
        # The reaper runs as a background job of a shell that then exits
        parent = self.bash("reap_core_dumps & echo $!; sleep 0.5")
        reaper_pid = int(parent.stdout.readline())
        parent.wait()
        self.wait_for(lambda: subprocess.run(["kill", "-0", str(reaper_pid)],
                                             stderr=subprocess.DEVNULL).returncode != 0)


if __name__ == "__main__":
    unittest.main()
