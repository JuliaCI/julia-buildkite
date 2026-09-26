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


def render(*args, source=None, source_build=False):
    env = os.environ.copy()
    if source is None:
        env.pop("BUILDKITE_SOURCE", None)
    else:
        env["BUILDKITE_SOURCE"] = source
    if source_build:
        env["SOURCE_BUILD"] = "true"
    else:
        env.pop("SOURCE_BUILD", None)
    return subprocess.run(
        [sys.executable, RENDERER, *args],
        cwd=ROOT,
        env=env,
        check=True,
        capture_output=True,
        text=True,
    ).stdout


# The scheduled optimized platforms with a build, a test and a publish job; i686
# has two test jobs and is checked separately.
OPT_TRIPLETS = (
    "x86_64-linux-gnuopt",
    "aarch64-linux-gnuopt",
    "x86_64-apple-darwinopt",
    "aarch64-apple-darwinopt",
    "x86_64-w64-mingw32opt",
)


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

        self.assertEqual(output.count('key: "build_'), 11)
        self.assertEqual(output.count('key: "test_'), 9)
        self.assertEqual(output.count("soft_fail: false"), 11)
        self.assertEqual(output.count("soft_fail: true"), 9)
        self.assertEqual(
            output.count('depends_on:\n          - "build_x86_64-linux-gnusrcassert"'),
            2,
        )
        for triplet in OPT_TRIPLETS:
            self.assertEqual(
                output.count(f'depends_on:\n          - "build_{triplet}"'),
                2,  # its test job, and its publish trigger
            )
        self.assertEqual(
            output.count('depends_on:\n          - "build_i686-linux-gnuopt"'),
            3,  # its two test jobs (net / no-net), and its publish trigger
        )
        self.assertEqual(output.count('JULIA_CI_BUILD_MODE: "opt"'), 6)

        # Check the new platform's rendered jobs, including agent routing and
        # sandbox images: aggregate job counts alone cannot catch a wrong arch.
        for job, image, tag, treehash, timeout, soft_fail in (
            ("build", "package_linux", "v8.8", "52b733db5ed13474c82a64dcacfef1291b5c7725", 420, "false"),
            ("test", "tester_linux", "v8.5", "c5927d46d70cb83c9baa94c0886c049998beb7cc", 255, "true"),
        ):
            with self.subTest(job=job):
                match = re.search(
                    rf'^      - label: ":linux: {job} aarch64-linux-gnuopt"\n'
                    r'.*?(?=^      - |^  - group:|\Z)', output, re.M | re.S,
                )
                self.assertIsNotNone(match)
                step = match.group()
                self.assertIn(f'key: "{job}_aarch64-linux-gnuopt"', step)
                self.assertIn(f'/{tag}/{image}.aarch64.tar.gz', step)
                self.assertIn(f'rootfs_treehash: "{treehash}"', step)
                self.assertIn(f'timeout_in_minutes: {timeout}\n', step)
                self.assertIn(f'soft_fail: {soft_fail}\n', step)
                self.assertIn(f'queue: "{job}"', step)
                self.assertIn('arch: "aarch64"', step)
                self.assertIn('TRIPLET: "aarch64-linux-gnuopt"', step)
                if job == "build":
                    self.assertIn('JULIA_CI_BUILD_MODE: "opt"', step)
                else:
                    self.assertIn('depends_on:\n          - "build_aarch64-linux-gnuopt"', step)
                    self.assertIn('USE_RR: ""', step)

        # One scheduled publish trigger per scheduled upload triplet, each
        # gated on that triplet's own jobs; no docs trigger, no wait barrier.
        publish = publish_group(output)
        self.assertEqual(publish.count('trigger: "julia-publish"'), 10)
        self.assertEqual(publish.count('PUBLISH_SCHEDULED: "true"'), 10)
        self.assertEqual(publish.count('if: pipeline.slug == "julia-ci"'), 10)
        self.assertNotIn('PUBLISH_TARGET: "docs"', output)
        self.assertNotIn("wait:", output)
        self.assertNotIn("PUBLISH_NOGPL", output)
        self.assertIn('label: ":rocket: publish x86_64-linux-gnuopt (scheduled)"', publish)
        self.assertIn('message: "publish x86_64-linux-gnuopt: ${BUILDKITE_MESSAGE}"', publish)
        self.assertIn('PUBLISH_TARGET: "aarch64-linux-gnuopt"', publish)
        for triplet in OPT_TRIPLETS:
            self.assertIn(depends_on(f"build_{triplet}", f"test_{triplet}"), publish)
        self.assertIn(depends_on("build_i686-linux-gnuopt", "test_i686-linux-gnuopt",
                                 "test_i686-linux-gnuoptnet"), publish)
        # no-GPL builds have no test jobs: they publish straight after the build
        self.assertIn(depends_on("build_x86_64-w64-mingw32nogpl"), publish)
        self.assertIn(depends_on("build_aarch64-apple-darwinnogpl"), publish)

    def test_normal_mode_excludes_schedule_groups(self):
        output = render()

        for group in ("Build", "Check", "Test", "Allow Fail", "JuliaC", "TTFX", "Publish"):
            self.assertIn(f'group: "{group}"', output)
        self.assertNotIn('group: "Source Build"', output)
        self.assertNotIn("PUBLISH_SCHEDULED", output)
        for triplet in (*OPT_TRIPLETS, "i686-linux-gnuopt"):
            self.assertNotIn(triplet, output)

    def test_optimized_windows_build_environment(self):
        output = render(source="schedule")
        build = re.search(
            r'^      - label: ":windows: build x86_64-w64-mingw32opt"\n'
            r'.*?(?=^      - label:|^  - group:|\Z)',
            output, re.M | re.S,
        ).group()
        self.assertIn('image: "juliapackaging/package-windows-x86_64:v8.10"', build)
        self.assertIn('timeout_in_minutes: 600', build)
        self.assertIn('soft_fail: false', build)
        self.assertIn('TRIPLET: "x86_64-w64-mingw32opt"', build)
        self.assertIn('JULIA_CI_BUILD_MODE: "opt"', build)
        # The Docker plugin must forward the mode into the build container.
        self.assertRegex(build, r'environment:\n(?:.*\n)*?\s+- "JULIA_CI_BUILD_MODE"')
        test = re.search(
            r'^      - label: ":windows: test x86_64-w64-mingw32opt"\n'
            r'.*?(?=^      - label:|^  - group:|\Z)',
            output, re.M | re.S,
        ).group()
        self.assertIn('timeout_in_minutes: 225', test)
        self.assertIn('soft_fail: true', test)

    def test_optimized_i686_jobs(self):
        for args, source in (((), "schedule"), (("--scheduled-workloads",), None)):
            with self.subTest(args=args, source=source):
                output = render(*args, source=source)
                jobs = {}
                for block in output.split("      - label: ")[1:]:
                    key = re.search(r'^        key: "([^"]+)"$', block, re.M)
                    if key:
                        jobs[key[1]] = block

                build = jobs["build_i686-linux-gnuopt"]
                self.assertIn("/v8.8/package_linux.i686.tar.gz", build)
                self.assertIn('rootfs_treehash: "58ec4d9a27f63c5512f2eddb2b401828c8af5910"', build)
                self.assertIn('JULIA_CI_BUILD_MODE: "opt"', build)
                self.assertIn("soft_fail: false", build)

                for suffix, group in (("", "no-net"), ("net", "net")):
                    job = jobs[f"test_i686-linux-gnuopt{suffix}"]
                    self.assertIn("/v8.5/tester_linux.i686.tar.gz", job)
                    self.assertIn('rootfs_treehash: "732df9bae7e11ac7c03bd6bd4f15027750552057"', job)
                    self.assertIn(f'i686_GROUP: "{group}"', job)
                    self.assertIn("soft_fail: true", job)
                    self.assertIn('depends_on:\n          - "build_i686-linux-gnuopt"', job)

                for key in ("build_i686-linux-gnuopt", "test_i686-linux-gnuopt", "test_i686-linux-gnuoptnet"):
                    self.assertIn('arch: "x86_64"', jobs[key])
                    self.assertIn('TRIPLET: "i686-linux-gnuopt"', jobs[key])

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
        for triplet in OPT_TRIPLETS:
            self.assertIn(f'key: "build_{triplet}"', output)
            self.assertIn(f'key: "test_{triplet}"', output)

    def test_scheduled_workloads_option_never_publishes(self):
        output = render("--scheduled-workloads", source="schedule")

        self.assertIn('group: "Source Build"', output)
        self.assertNotIn('group: "Publish"', output)
        self.assertNotIn('trigger: "julia-publish"', output)

    def test_source_build_mode(self):
        output = render(source_build=True)

        for group in ("Build", "Test", "Allow Fail"):
            self.assertEqual(output.count(f'  - group: "{group}"'), 1)
        for group in ("Check", "JuliaC", "TTFX", "Publish"):
            self.assertNotIn(f'group: "{group}"', output)
        self.assertNotIn('trigger: "julia-publish"', output)

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
        self.assertEqual(output.count("package_linux_mmtk.x86_64.tar.gz"), 2)
        self.assertIn("tester_linux.x86_64.tar.gz", output)

    def test_source_build_off_by_default(self):
        self.assertNotIn("USE_BINARYBUILDER", render())

    def test_source_build_ignored_in_schedule_modes(self):
        self.assertEqual(render(source="schedule"),
                         render(source="schedule", source_build=True))
        self.assertEqual(render("--scheduled-workloads"),
                         render("--scheduled-workloads", source_build=True))


if __name__ == "__main__":
    unittest.main()
