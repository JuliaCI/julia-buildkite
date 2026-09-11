#!/usr/bin/env python3

# Trimmed from the `main` test suite: release-1.13's renderer has no schedule
# mode, so only the source-build mode and the default render are covered.

import os
import re
import subprocess
import sys
import unittest


ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RENDERER = os.path.join(ROOT, "utilities", "render_launch_pipeline.py")


def render(source_build=False):
    env = os.environ.copy()
    if source_build:
        env["SOURCE_BUILD"] = "true"
    else:
        env.pop("SOURCE_BUILD", None)
    return subprocess.run(
        [sys.executable, RENDERER],
        cwd=ROOT,
        env=env,
        check=True,
        capture_output=True,
        text=True,
    ).stdout


class RenderLaunchPipelineTests(unittest.TestCase):
    def test_source_build_mode(self):
        output = render(source_build=True)

        for group in ("Build", "Test", "Allow Fail"):
            self.assertEqual(output.count(f'  - group: "{group}"'), 1)
        self.assertNotIn('group: "Check"', output)
        self.assertNotIn('trigger: "julia-publish"', output)
        self.assertNotIn("wait:", output)

        # A manual source-build run must not overwrite the commit's real
        # Build / Test commit statuses.
        self.assertIn('context: "Build (source build)"', output)
        self.assertIn('context: "Test (source build)"', output)

        # Every build compiles its deps from source, with the from-source
        # timeout; MAKE_FLAGS only appears on build jobs.
        num_builds = output.count('key: "build_')
        self.assertGreater(num_builds, 0)
        flags = re.findall(r'MAKE_FLAGS: "([^"]*)"', output)
        self.assertEqual(len(flags), num_builds)
        for f in flags:
            self.assertTrue(f.endswith("USE_BINARYBUILDER=0"), f)
        self.assertEqual(output.count("timeout_in_minutes: 240"), num_builds)

        # Linux builds move onto the full-toolchain llvm_passes image
        # (package_linux has no gfortran); mmtk has no such variant and
        # keeps its image; test jobs keep theirs untouched.
        self.assertEqual(output.count("llvm_passes.x86_64.tar.gz"), 3)
        self.assertEqual(output.count("llvm_passes.i686.tar.gz"), 1)
        self.assertEqual(output.count("llvm_passes.aarch64.tar.gz"), 1)
        self.assertEqual(output.count("package_linux_mmtk.x86_64.tar.gz"), 1)
        self.assertIn("tester_linux.x86_64.tar.gz", output)

    def test_source_build_off_by_default(self):
        output = render()
        self.assertNotIn("USE_BINARYBUILDER", output)
        self.assertIn('trigger: "julia-publish"', output)


if __name__ == "__main__":
    unittest.main()
