#!/usr/bin/env python3

import os
import re
import subprocess
import sys
import unittest


ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RENDERER = os.path.join(ROOT, "utilities", "render_launch_pipeline.py")

# The per-commit published platforms (pipelines/main/platforms/upload_*.arches).
PUBLISHED_TRIPLETS = [
    "aarch64-linux-gnu",
    "i686-linux-gnu",
    "x86_64-linux-gnu",
    "x86_64-linux-gnuassert",
    "x86_64-apple-darwin",
    "aarch64-apple-darwin",
    "x86_64-w64-mingw32",
    "i686-w64-mingw32",
    "x86_64-unknown-freebsd",
]


def render(*args, source=None):
    env = os.environ.copy()
    if source is None:
        env.pop("BUILDKITE_SOURCE", None)
    else:
        env["BUILDKITE_SOURCE"] = source
    return subprocess.run(
        [sys.executable, RENDERER, *args],
        cwd=ROOT,
        env=env,
        check=True,
        capture_output=True,
        text=True,
    ).stdout


def publish_group(output):
    """The text of the trailing Publish group."""
    return output[output.index('  - group: "Publish"'):]


def depends_on(*keys):
    """A publish trigger's exact `depends_on:` block for the given keys."""
    return ("        depends_on:\n"
            + "".join(f'          - "{key}"\n' for key in keys)
            + "        build:")


class RenderLaunchPipelineTests(unittest.TestCase):
    def test_schedule_mode(self):
        output = render(source="schedule")

        for group in ("Source Build", "Source Tests (Allow Fail)", "no_GPL",
                      "Optimized Build", "Optimized Tests (Allow Fail)"):
            self.assertEqual(output.count(f'group: "{group}"'), 1)
        self.assertNotIn('group: "Build"', output)
        self.assertNotIn('group: "Test"', output)

        self.assertEqual(output.count('key: "build_'), 6)
        self.assertEqual(output.count('key: "test_'), 3)
        self.assertEqual(output.count("soft_fail: false"), 6)
        self.assertEqual(output.count("soft_fail: true"), 3)
        self.assertEqual(
            output.count('depends_on:\n          - "build_x86_64-linux-gnusrcassert"'),
            2,
        )
        self.assertEqual(
            output.count('depends_on:\n          - "build_x86_64-linux-gnuopt"'),
            2,  # its test job, and its publish trigger
        )
        self.assertEqual(output.count('JULIA_CI_BUILD_MODE: "pgo-lto-bolt"'), 1)

        # One scheduled publish trigger per scheduled upload triplet, each
        # gated on that triplet's own jobs; no docs trigger, no wait barrier.
        publish = publish_group(output)
        self.assertEqual(publish.count('trigger: "julia-publish"'), 5)
        self.assertEqual(publish.count('PUBLISH_SCHEDULED: "true"'), 5)
        self.assertEqual(publish.count('if: pipeline.slug == "julia-ci"'), 5)
        self.assertNotIn('PUBLISH_TARGET: "docs"', output)
        self.assertNotIn("wait:", output)
        self.assertNotIn("PUBLISH_NOGPL", output)
        self.assertIn('label: ":rocket: publish x86_64-linux-gnuopt (scheduled)"', publish)
        self.assertIn('message: "publish x86_64-linux-gnuopt: ${BUILDKITE_MESSAGE}"', publish)
        self.assertIn(depends_on("build_x86_64-linux-gnuopt", "test_x86_64-linux-gnuopt"), publish)
        # no-GPL builds have no test jobs: they publish straight after the build
        self.assertIn(depends_on("build_x86_64-w64-mingw32nogpl"), publish)
        self.assertIn(depends_on("build_aarch64-apple-darwinnogpl"), publish)

    def test_normal_mode_excludes_schedule_groups(self):
        output = render()

        for group in ("Build", "Check", "Test", "Allow Fail", "JuliaC", "TTFX", "Publish"):
            self.assertIn(f'group: "{group}"', output)
        self.assertNotIn('group: "Source Build"', output)
        self.assertNotIn("PUBLISH_SCHEDULED", output)

    def test_publish_triggers_gate_on_their_own_platform(self):
        output = render()
        publish = publish_group(output)

        # One trigger per published platform plus the per-commit docs one,
        # every one of them julia-ci only, and no build-wide wait barrier.
        self.assertEqual(publish.count('trigger: "julia-publish"'), len(PUBLISHED_TRIPLETS) + 1)
        self.assertEqual(publish.count('if: pipeline.slug == "julia-ci"'), len(PUBLISHED_TRIPLETS) + 1)
        self.assertNotIn("wait:", output)
        self.assertEqual(
            sorted(re.findall(r'PUBLISH_TARGET: "([^"]+)"', publish)),
            sorted(PUBLISHED_TRIPLETS + ["docs"]),
        )
        self.assertIn('label: ":rocket: publish x86_64-linux-gnu"', publish)
        self.assertIn('message: "publish x86_64-linux-gnu: ${BUILDKITE_MESSAGE}"', publish)
        self.assertIn('commit: "${BUILDKITE_COMMIT}"', publish)
        self.assertIn('branch: "${BUILDKITE_BRANCH}"', publish)

        # Every test job of a platform gates its publish -- including the
        # soft-failing ones (Allow Fail), which Buildkite counts as complete.
        self.assertIn(depends_on("build_x86_64-linux-gnu", "test_x86_64-linux-gnu"), publish)
        self.assertIn(depends_on("build_i686-linux-gnu", "test_i686-linux-gnu", "test_i686-linux-gnunet"), publish)
        self.assertIn(depends_on("build_x86_64-linux-gnuassert", "test_x86_64-linux-gnuassertrr", "test_x86_64-linux-gnuassertrr-net"), publish)
        self.assertIn(depends_on("build_aarch64-linux-gnu", "test_aarch64-linux-gnu"), publish)
        self.assertIn(depends_on("build_x86_64-unknown-freebsd", "test_x86_64-unknown-freebsd"), publish)
        # The docs trigger waits for the steps that stage the docs / source dists.
        self.assertIn(depends_on("doctest", "source_dist"), publish)

    def test_publish_dependencies_exist(self):
        for source in (None, "schedule"):
            output = render(source=source)
            keys = set(re.findall(r'^\s+key:\s*"?([^"\s]+)"?\s*$', output, re.M))
            deps = set(re.findall(r'^          - "([^"]+)"$', publish_group(output), re.M))
            self.assertTrue(deps)
            self.assertLessEqual(deps, keys)

    def test_labeled_pr_mode_emits_scheduled_workloads_without_publish(self):
        output = render("--scheduled-workloads")

        for group in ("Source Build", "Source Tests (Allow Fail)", "no_GPL"):
            self.assertEqual(output.count(f'group: "{group}"'), 1)
        self.assertNotIn('group: "Build"', output)
        self.assertNotIn('group: "Publish"', output)
        self.assertNotIn('trigger: "julia-publish"', output)
        self.assertNotIn("PUBLISH_NOGPL", output)

    def test_scheduled_workloads_option_never_publishes(self):
        output = render("--scheduled-workloads", source="schedule")

        self.assertIn('group: "Source Build"', output)
        self.assertNotIn('group: "Publish"', output)
        self.assertNotIn('trigger: "julia-publish"', output)


if __name__ == "__main__":
    unittest.main()
