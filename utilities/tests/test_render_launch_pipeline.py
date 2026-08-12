#!/usr/bin/env python3

import os
import subprocess
import sys
import unittest


ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RENDERER = os.path.join(ROOT, "utilities", "render_launch_pipeline.py")


def render(source=None):
    env = os.environ.copy()
    if source is None:
        env.pop("BUILDKITE_SOURCE", None)
    else:
        env["BUILDKITE_SOURCE"] = source
    return subprocess.run(
        [sys.executable, RENDERER],
        cwd=ROOT,
        env=env,
        check=True,
        capture_output=True,
        text=True,
    ).stdout


class RenderLaunchPipelineTests(unittest.TestCase):
    def test_schedule_mode(self):
        output = render("schedule")

        for group in ("Source Build", "Source Tests (Allow Fail)", "no_GPL"):
            self.assertEqual(output.count(f'group: "{group}"'), 1)
        self.assertNotIn('group: "Build"', output)
        self.assertNotIn('group: "Test"', output)

        self.assertEqual(output.count('key: "build_'), 5)
        self.assertEqual(output.count('key: "test_'), 2)
        self.assertEqual(output.count("soft_fail: false"), 5)
        self.assertEqual(output.count("soft_fail: true"), 2)
        self.assertEqual(
            output.count('depends_on:\n          - "build_x86_64-linux-gnusrcassert"'),
            2,
        )
        self.assertIn('PUBLISH_NOGPL: "true"', output)
        self.assertIn('trigger: "julia-publish"', output)

    def test_normal_mode_excludes_schedule_groups(self):
        output = render()

        for group in ("Build", "Check", "Test", "Allow Fail"):
            self.assertIn(f'group: "{group}"', output)
        self.assertNotIn('group: "Source Build"', output)
        self.assertNotIn("PUBLISH_NOGPL", output)


if __name__ == "__main__":
    unittest.main()
