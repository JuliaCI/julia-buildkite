#!/usr/bin/env python3
"""Check that build and test jobs size themselves from the scheduler's grant (utilities/width.sh).

The scripts run for real against offline doubles: a `julia` that records its command line and
environment, a `make` that records its flags, and a `build_envs.sh` that only exports what the
scripts read. Nothing runs Julia's test suite or builds anything.
"""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
BASH = shutil.which("bash")

RECORDER = '''#!/usr/bin/env python3
import json, os, sys
with open(os.environ["FIXTURE_LOG"], "a") as f:
    f.write(json.dumps({"argv": sys.argv, "env": dict(os.environ)}) + "\\n")
if "binary-dist" in sys.argv:
    open(os.environ["UPLOAD_FILENAME"] + ".tar.gz", "w").close()
'''


class WidthTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.work = Path(self.tmp.name)
        self.utils = self.work / ".buildkite/utilities"
        self.utils.mkdir(parents=True)
        self.bin = self.work / "tools"
        self.bin.mkdir()
        self.log = self.work / "calls.jsonl"
        for script in ("build_julia.sh", "test_julia.sh", "word.sh", "width.sh"):
            if (ROOT / "utilities" / script).exists():
                shutil.copy(ROOT / "utilities" / script, self.utils / script)
        self.write(self.utils / "build_envs.sh", '''
export JULIA_INSTALL_DIR=julia-fixture JULIA_BINARY=julia-fixture/bin/julia
export UPLOAD_FILENAME=julia-fixture JULIA_BINARYDIST_FILENAME=julia-fixture
export STAGING_TARGET=staging/julia-fixture TRIPLET="${ARCH}-fixture"
export MAKE=make MAKE_FLAGS= JULIA_CPU_TARGET=generic HAS_CHECKBOUNDS_PKGIMAGES=false
export EXTERNAL_STDLIB_NAMES=""
''')
        self.write(self.utils / "upload_to_s3.sh", "upload_to_s3() { :; }\n")
        self.write(self.utils / "aws_oidc.sh", ":\n")
        self.write(self.utils / "macos/codesign.sh", "#!/usr/bin/env bash\n")
        for tool in ("julia", "make"):
            self.write(self.bin / tool, RECORDER)
        for tool in ("buildkite-agent", "git", "cc", "ld", "sysctl"):
            self.write(self.bin / tool, "#!/usr/bin/env bash\n")
        (self.work / "julia-fixture/bin").mkdir(parents=True)
        shutil.copy(self.bin / "julia", self.work / "julia-fixture/bin/julia")
        (self.work / "usr/bin").mkdir(parents=True)
        shutil.copy(self.bin / "julia", self.work / "usr/bin/julia")
        self.write(self.work / "VERSION", "1.14.0-DEV")
        # The agent hook sets JULIA_CPU_THREADS from SBA_CPUS_LIMIT before the pipeline runs.
        self.env = {"PATH": f"{self.bin}:{os.environ['PATH']}", "HOME": str(self.work),
                    "FIXTURE_LOG": str(self.log), "BUILDKITE_TIMEOUT": "225",
                    "BUILDKITE_BRANCH": "master", "OS": "linux", "ARCH": "x86_64",
                    "JULIA_CPU_THREADS": "8"}

    def write(self, path, text):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        path.chmod(0o755)

    def run_script(self, name, success=True, **env):
        result = subprocess.run([BASH, str(self.utils / name)], cwd=self.work,
                                env={**self.env, **env}, capture_output=True, text=True)
        output = result.stdout + result.stderr
        if success:
            self.assertEqual(result.returncode, 0, output)
        else:
            self.assertNotEqual(result.returncode, 0, output)
        calls = [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []
        return output, calls

    def run_tests(self, **env):
        """Run test_julia.sh and return (output, environment of the test-suite process, ncores)."""
        output, calls = self.run_script("test_julia.sh", **env)
        suite = [c for c in calls if any("Base.runtests" in a for a in c["argv"])]
        self.assertEqual(len(suite), 1, output)
        ncores = suite[0]["argv"][-1].rsplit("ncores = ", 1)[1].removesuffix(")")
        return output, suite[0]["env"], ncores

    def assert_width(self, env, width):
        for var in ("JULIA_CPU_THREADS", "NCORES_FOR_TESTS", "OPENBLAS_NUM_THREADS", "JULIA_PRECOMPILE_THREADS"):
            self.assertEqual(env[var], str(width), var)

    # macOS test step: MEM_PER_THREAD_GIB=2.5, the whole host's grant from the scheduler
    GRANTS = (("M1", "6", "4", 2), ("M2", "20", "4", 4), ("M6", "12", "6", 4),
              ("13 GiB host", "13", "4", 4), ("CPU-bound host", "26", "6", 6))

    def test_macos_grants(self):
        for host, mem, cpus, width in self.GRANTS:
            with self.subTest(host=host):
                self.log.unlink(missing_ok=True)
                output, env, ncores = self.run_tests(
                    OS="macos", ARCH="aarch64", MEM_PER_THREAD_GIB="2.5",
                    SBA_MEM_GIB=mem, SBA_CPUS_LIMIT=cpus, JULIA_CPU_THREADS=cpus)
                self.assertEqual(ncores, str(width))
                self.assert_width(env, width)
                self.assertEqual(env["JULIA_TEST_MAXRSS_MB"], "2560")
                self.assertIn(f"SBA_MEM_GIB={mem}", output)
                self.assertIn(f"JULIA_CPU_THREADS={width}", output)

    def test_missing_memory_grant_fails(self):
        output, calls = self.run_script("test_julia.sh", success=False, OS="macos", ARCH="aarch64",
                                        MEM_PER_THREAD_GIB="2.5", JULIA_CPU_THREADS="4")
        self.assertIn("SBA_MEM_GIB", output)
        self.assertEqual(calls, [])

    def test_grant_too_small_fails(self):
        for script in ("test_julia.sh", "build_julia.sh"):
            with self.subTest(script=script):
                output, calls = self.run_script(script, success=False, MEM_PER_THREAD_GIB="2.5",
                                                SBA_MEM_GIB="3", JULIA_CPU_THREADS="4")
                self.assertIn("this host's memory grant (3 GiB) is too small for this step", output)
                self.assertEqual(calls, [])

    def test_fractional_inputs(self):
        # (4.3 - 1) / 1.1 is 2.9999999999999996 in binary floating point.
        for mem, per, cpus, width in (("4.3", "1.1", "8", 3), ("8.5", "2.5", "8", 3),
                                      ("7", "2", "2", 2), ("3.5", "2.5", "4", 1)):
            with self.subTest(mem=mem, per=per, cpus=cpus):
                result = subprocess.run(
                    [BASH, "-c", 'set -euo pipefail; source .buildkite/utilities/width.sh; echo "W=${JULIA_CPU_THREADS}"'],
                    cwd=self.work, capture_output=True, text=True,
                    env={**self.env, "MEM_PER_THREAD_GIB": per, "SBA_MEM_GIB": mem, "JULIA_CPU_THREADS": cpus})
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(result.stdout.splitlines()[-1], f"W={width}")

    def test_unset_leaves_tests_alone(self):
        # A tiny grant must not matter when the step does not declare MEM_PER_THREAD_GIB.
        for name, env, maxrss in (("linux", {}, "3800"),
                                  ("macos", {"OS": "macos", "ARCH": "aarch64"}, "3800"),
                                  ("i686", {"ARCH": "i686"}, "1536")):
            with self.subTest(path=name):
                self.log.unlink(missing_ok=True)
                output, suite, ncores = self.run_tests(SBA_MEM_GIB="1", **env)
                self.assertEqual(ncores, "8")
                self.assert_width(suite, 8)
                self.assertEqual(suite["JULIA_TEST_MAXRSS_MB"], maxrss)
                self.assertNotIn("MEM_PER_THREAD_GIB", output)

    def test_unset_leaves_rr_alone(self):
        output, suite, ncores = self.run_tests(SBA_MEM_GIB="1", USE_RR="rr")
        self.assertIn("rr_capture.jl", suite["JULIA_CMD_FOR_TESTS"])
        self.assertEqual(ncores, 'parse(Int, ENV["JULIA_RRCAPTURE_NUM_CORES"])')
        for var in ("JULIA_CPU_THREADS", "OPENBLAS_NUM_THREADS", "JULIA_PRECOMPILE_THREADS"):
            self.assertEqual(suite[var], "8", var)
        self.assertEqual(suite["JULIA_TEST_MAXRSS_MB"], "3800")

    def test_i686_keeps_its_maxrss(self):
        _, suite, ncores = self.run_tests(ARCH="i686", MEM_PER_THREAD_GIB="2.5", SBA_MEM_GIB="13")
        self.assertEqual(ncores, "4")
        self.assertEqual(suite["JULIA_TEST_MAXRSS_MB"], "1536")

    def build(self, **env):
        _, calls = self.run_script("build_julia.sh", **env)
        makes = [c for c in calls if Path(c["argv"][0]).name == "make"]
        self.assertTrue(makes)
        return makes

    def test_unset_leaves_build_alone(self):
        for make in self.build(SBA_MEM_GIB="1"):
            self.assertIn("-j8", make["argv"])
            self.assertEqual(make["env"]["JULIA_IMAGE_THREADS"], "8")
            self.assertEqual(make["env"]["JULIA_PRECOMPILE_THREADS"], "8")

    def test_build_follows_memory_grant(self):
        for make in self.build(MEM_PER_THREAD_GIB="2.5", SBA_MEM_GIB="6"):
            self.assertIn("-j2", make["argv"])
            self.assertEqual(make["env"]["JULIA_IMAGE_THREADS"], "2")
            self.assertEqual(make["env"]["JULIA_PRECOMPILE_THREADS"], "2")


if __name__ == "__main__":
    unittest.main()
