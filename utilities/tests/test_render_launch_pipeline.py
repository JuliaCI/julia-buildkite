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


def render(*args, source=None, **build_env):
    env = os.environ.copy()
    for var in ("BUILDKITE_SOURCE", "BUILDKITE_PIPELINE_SLUG", "BUILDKITE_TAG",
                "BUILDKITE_BRANCH", "NOGPL_ONLY", "OPT_ONLY", "OPT_TESTS_ALLOW_FAIL",
                "ONLY_TRIPLETS", "TTFX_RELEASE"):
        env.pop(var, None)
    if source is not None:
        env["BUILDKITE_SOURCE"] = source
    env.update(build_env)
    return subprocess.run(
        [sys.executable, RENDERER, *args],
        cwd=ROOT,
        env=env,
        check=True,
        capture_output=True,
        text=True,
    ).stdout


NOGPL_TRIPLETS = [
    "x86_64-linux-gnunogpl",
    "x86_64-apple-darwinnogpl",
    "aarch64-apple-darwinnogpl",
    "x86_64-w64-mingw32nogpl",
]


# The scheduled optimized platforms with a build, a test and a publish job; i686
# has two test jobs and is checked separately.
OPT_TRIPLETS = (
    "x86_64-linux-gnuopt",
    "aarch64-linux-gnuopt",
    "x86_64-apple-darwinopt",
    "aarch64-apple-darwinopt",
    "x86_64-w64-mingw32opt",
)
ALL_OPT_TRIPLETS = sorted(OPT_TRIPLETS + ("i686-linux-gnuopt",))


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
                      "Optimized Build", "Optimized Tests (Allow Fail)",
                      "RISC-V Build (Allow Fail)"):
            self.assertEqual(output.count(f'group: "{group}"'), 1)
        self.assertNotIn('group: "Build"', output)
        self.assertNotIn('group: "Test"', output)

        self.assertEqual(output.count('key: "build_'), 13)
        self.assertEqual(output.count('key: "test_'), 9)
        self.assertEqual(output.count("soft_fail: false"), 11)
        self.assertEqual(output.count("soft_fail: true"), 12)  # the tests, TTFX opt, riscv64
        self.assertEqual(
            output.count('depends_on:\n          - "build_x86_64-linux-gnusrcassert"'),
            2,
        )
        for triplet in OPT_TRIPLETS:
            self.assertEqual(
                output.count(f'depends_on:\n          - "build_{triplet}"'),
                # its test job, and its publish trigger; macOS aarch64 its TTFX job too
                3 if triplet == "aarch64-apple-darwinopt" else 2,
            )
        self.assertEqual(
            output.count('depends_on:\n          - "build_i686-linux-gnuopt"'),
            3,  # its two test jobs (net / no-net), and its publish trigger
        )
        self.assertEqual(output.count('JULIA_CI_BUILD_MODE: "opt"'), 7)

        # riscv64 is cross-compiled on x86_64 hosts that run riscv64 code with qemu-user
        match = re.search(
            r'^      - label: ":linux: build riscv64-linux-gnu"\n'
            r'.*?(?=^      - |^  - group:|\Z)', output, re.M | re.S,
        )
        self.assertIsNotNone(match)
        step = match.group()
        self.assertIn('/package_linux_riscv64.x86_64.tar.gz', step)
        self.assertIn('arch: "x86_64"', step)
        self.assertIn('binfmt_riscv64: "true"', step)
        self.assertIn('XC_HOST=riscv64-linux-gnu', step)
        self.assertIn('timeout_in_minutes: 420\n', step)
        self.assertIn('soft_fail: true\n', step)
        self.assertIn('JL_CFLAGS=-Werror', step)
        self.assertIn('JULIA_CI_BUILD_MODE: ""', step)

        # The optimized riscv64 build: same hosts and image, PGO+ThinLTO through
        # contrib/optimized, and no tests either
        match = re.search(
            r'^      - label: ":linux: build riscv64-linux-gnuopt"\n'
            r'.*?(?=^      - |^  - group:|\Z)', output, re.M | re.S,
        )
        self.assertIsNotNone(match)
        step = match.group()
        self.assertIn('/package_linux_riscv64.x86_64.tar.gz', step)
        self.assertIn('binfmt_riscv64: "true"', step)
        self.assertIn('XC_HOST=riscv64-linux-gnu', step)
        self.assertNotIn('-Werror', step)
        self.assertIn('JULIA_CI_BUILD_MODE: "opt"', step)
        self.assertIn('timeout_in_minutes: 720\n', step)
        self.assertIn('soft_fail: true\n', step)
        self.assertNotIn('key: "test_riscv64', output)

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
        self.assertEqual(publish.count('trigger: "julia-publish"'), 12)
        self.assertEqual(publish.count('PUBLISH_SCHEDULED: "true"'), 12)
        self.assertEqual(publish.count('if: pipeline.slug == "julia-ci"'), 12)
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
        # no-GPL and riscv64 builds have no test jobs: they publish straight after the build
        self.assertIn(depends_on("build_x86_64-w64-mingw32nogpl"), publish)
        self.assertIn(depends_on("build_riscv64-linux-gnu"), publish)
        self.assertIn(depends_on("build_riscv64-linux-gnuopt"), publish)
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
        self.assertIn(depends_on("build_x86_64-linux-gnuassert", "test_x86_64-linux-gnuassert",
                                 "test_x86_64-linux-gnuassertrr", "test_x86_64-linux-gnuassertrr-net"), publish)
        self.assertIn(depends_on("build_aarch64-linux-gnu", "test_aarch64-linux-gnu"), publish)
        self.assertIn(depends_on("build_x86_64-unknown-freebsd", "test_x86_64-unknown-freebsd"), publish)
        # The docs trigger waits for the steps that stage the docs / source dists.
        self.assertIn(depends_on("doctest", "source_dist"), publish)

    def test_releases_build_and_publish_nogpl(self):
        for build_env in ({"BUILDKITE_TAG": "v1.14.0", "BUILDKITE_BRANCH": "v1.14.0"},
                          {"BUILDKITE_BRANCH": "v1.14.0"},
                          {"BUILDKITE_BRANCH": "release-1.14"}):
            output = render(BUILDKITE_PIPELINE_SLUG="julia-ci", **build_env)
            publish = publish_group(output)

            self.assertEqual(output.count('group: "no_GPL"'), 1)
            self.assertIn('group: "Build"', output)
            self.assertEqual(output.count('group: "Optimized Build"'), 1)
            # release-* pushes publish nightlies, which do not wait for the tests
            tests = ("Optimized Tests (Allow Fail)" if build_env["BUILDKITE_BRANCH"].startswith("release-")
                     else "Optimized Tests")
            self.assertEqual(re.findall(r'group: "(Optimized Tests[^"]*)"', output), [tests])
            self.assertEqual(
                sorted(re.findall(r'PUBLISH_TARGET: "([^"]+)"', publish)),
                sorted(PUBLISHED_TRIPLETS + NOGPL_TRIPLETS + ALL_OPT_TRIPLETS
                       + ["riscv64-linux-gnu", "riscv64-linux-gnuopt", "docs"]),
            )
            self.assertEqual(output.count('group: "RISC-V Build (Allow Fail)"'), 1)
            self.assertIn(depends_on("build_riscv64-linux-gnu"), publish)
            self.assertIn(depends_on("build_riscv64-linux-gnuopt"), publish)
            # Each optimized platform's publish waits for its own tests
            self.assertIn(depends_on("build_x86_64-linux-gnuopt", "test_x86_64-linux-gnuopt"), publish)
            self.assertIn(depends_on("build_i686-linux-gnuopt", "test_i686-linux-gnuopt",
                                     "test_i686-linux-gnuoptnet"), publish)
            for triplet in NOGPL_TRIPLETS:
                self.assertIn(depends_on(f"build_{triplet}"), publish)
            self.assertNotIn("PUBLISH_SCHEDULED", publish)

        # master (which gets them from the schedule), and release-like
        # branches outside julia-ci, do not.
        for build_env in ({"BUILDKITE_PIPELINE_SLUG": "julia-ci", "BUILDKITE_BRANCH": "master"},
                          {"BUILDKITE_PIPELINE_SLUG": "julia-pr", "BUILDKITE_BRANCH": "release-1.14"},
                          {"BUILDKITE_PIPELINE_SLUG": "julia-pr", "BUILDKITE_BRANCH": "v2-feature"}):
            output = render(**build_env)
            self.assertNotIn('group: "no_GPL"', output)
            self.assertNotIn('group: "Optimized Build"', output)
            self.assertNotIn('group: "RISC-V Build (Allow Fail)"', output)

    def test_nogpl_only(self):
        output = render(BUILDKITE_PIPELINE_SLUG="julia-ci", BUILDKITE_BRANCH="v1.13.1",
                        NOGPL_ONLY="true")

        self.assertEqual(re.findall(r'^  - group: "([^"]+)"', output, re.M), ["no_GPL", "Publish"])
        self.assertEqual(
            sorted(re.findall(r'PUBLISH_TARGET: "([^"]+)"', output)),
            sorted(NOGPL_TRIPLETS),
        )

        # The schedule keeps rendering all scheduled workloads.
        output = render(source="schedule", NOGPL_ONLY="true")
        self.assertIn('group: "Optimized Build"', output)

    def test_release_opt_tests_gate_their_publish(self):
        def opt_test_soft_fail(output):
            return set(re.findall(
                r'label: ":linux: test x86_64-linux-gnuopt"\n(?:.*\n)*?\s+soft_fail: (\w+)', output))

        release = {"BUILDKITE_PIPELINE_SLUG": "julia-ci", "BUILDKITE_BRANCH": "v1.14.0"}
        self.assertEqual(opt_test_soft_fail(render(**release)), {"false"})
        self.assertEqual(opt_test_soft_fail(render(OPT_ONLY="true", **release)), {"false"})
        allowed = render(OPT_TESTS_ALLOW_FAIL="true", **release)
        self.assertEqual(opt_test_soft_fail(allowed), {"true"})
        self.assertIn('group: "Optimized Tests (Allow Fail)"', allowed)
        # The nightlies keep publishing despite failing optimized tests
        self.assertEqual(opt_test_soft_fail(render(source="schedule")), {"true"})
        self.assertEqual(opt_test_soft_fail(render(BUILDKITE_PIPELINE_SLUG="julia-ci",
                                                   BUILDKITE_BRANCH="release-1.14")), {"true"})

    def test_opt_only(self):
        output = render(BUILDKITE_PIPELINE_SLUG="julia-ci", BUILDKITE_BRANCH="v1.14.0",
                        OPT_ONLY="true")

        self.assertEqual(re.findall(r'^  - group: "([^"]+)"', output, re.M),
                         ["Optimized Build", "Optimized Tests", "Publish"])
        self.assertEqual(
            sorted(re.findall(r'PUBLISH_TARGET: "([^"]+)"', output)),
            ALL_OPT_TRIPLETS,
        )
        self.assertNotIn("PUBLISH_SCHEDULED", output)

    def test_only_triplets(self):
        release = {"BUILDKITE_PIPELINE_SLUG": "julia-ci", "BUILDKITE_BRANCH": "v1.14.0"}
        groups = r'^  - group: "([^"]+)"'

        output = render(ONLY_TRIPLETS="riscv64-linux-gnu", **release)
        self.assertEqual(re.findall(groups, output, re.M), ["RISC-V Build (Allow Fail)", "Publish"])
        self.assertEqual(re.findall(r'PUBLISH_TARGET: "([^"]+)"', output), ["riscv64-linux-gnu"])
        self.assertIn(depends_on("build_riscv64-linux-gnu"), output)

        # A platform keeps all of its tests, which still gate its publish,
        # and platforms combine across groups.
        output = render(ONLY_TRIPLETS="x86_64-linux-gnuassert, i686-linux-gnuopt", **release)
        self.assertEqual(re.findall(groups, output, re.M),
                         ["Build", "Test", "Optimized Build", "Optimized Tests", "Publish"])
        self.assertEqual(set(re.findall(r'TRIPLET: "([^"]+)"', output)),
                         {"x86_64-linux-gnuassert", "i686-linux-gnuopt"})
        self.assertIn(depends_on("build_x86_64-linux-gnuassert", "test_x86_64-linux-gnuassert",
                                 "test_x86_64-linux-gnuassertrr", "test_x86_64-linux-gnuassertrr-net"),
                      output)
        self.assertIn(depends_on("build_i686-linux-gnuopt", "test_i686-linux-gnuopt",
                                 "test_i686-linux-gnuoptnet"), output)
        for job in ("doctest", "gcext", "juliac", "ttfx", "docs"):
            self.assertNotIn(f'"{job}"', output)

        # An unpublished platform is built and tested only.
        output = render(ONLY_TRIPLETS="x86_64-linux-gnummtk")
        self.assertNotIn('group: "Publish"', output)
        self.assertIn('key: "build_x86_64-linux-gnummtk"', output)

        # A scheduled platform is built and tested only, outside releases.
        output = render(ONLY_TRIPLETS="riscv64-linux-gnuopt")
        self.assertNotIn('group: "Publish"', output)
        self.assertIn('key: "build_riscv64-linux-gnuopt"', output)
        self.assertNotIn('key: "build_riscv64-linux-gnu"', output)

    def test_only_triplets_rejects_unknown_platforms(self):
        for build_env in ({"ONLY_TRIPLETS": "x86_64-linux-gnux"},
                          {"ONLY_TRIPLETS": "x86_64-linux-gnu,x86_64-linux-gnux"}):
            with self.subTest(env=build_env), self.assertRaises(subprocess.CalledProcessError) as cm:
                render(**build_env)
            self.assertIn("ONLY_TRIPLETS: no jobs for", cm.exception.stderr)

    def test_rr_only_outside_pull_requests(self):
        # pull requests test the assertion build without rr; the rr jobs are skipped
        output = render()
        for label, skip in [("test x86_64-linux-gnuassert", ""),
                            ("test x86_64-linux-gnuassertrr", "yes"),
                            ("test x86_64-linux-gnuassertrr-net", "yes")]:
            m = re.search(r'^      - label: ":linux: %s"\n(?:        .*\n)*?        if: (.*)$'
                          % re.escape(label), output, re.MULTILINE)
            self.assertIsNotNone(m, label)
            self.assertEqual(m.group(1), f'pipeline.slug != "julia-pr" || "{skip}" != "yes"', label)

    def test_ttfx_release_build_renders_only_the_release_jobs(self):
        for env in ({"TTFX_RELEASE": "latest"}, {"TTFX_RELEASE": "1.13.1"}):
            output = render(source="schedule", BUILDKITE_PIPELINE_SLUG="julia-ci", **env)
            self.assertEqual(re.findall(r'^  - group: "([^"]+)"', output, re.M), ["TTFX release"])
            self.assertEqual(output.count("- label:"), 3)
            self.assertIn('key: "ttfx_release_aarch64-apple-darwin"', output)
            self.assertIn('key: "ttfx_lts_aarch64-apple-darwin"', output)
            self.assertIn('key: "ttfx_branch_nightly_aarch64-apple-darwin"', output)
            self.assertIn("utilities/ttfx/ttfx_ci.sh", output)
            self.assertNotIn("build_", output)
            self.assertNotIn("trigger:", output)
        # The variable is left for the launch agent's `pipeline upload` to resolve
        self.assertIn('TTFX_RELEASE: "${TTFX_RELEASE:-latest}"', output)
        # The LTS and nightly jobs run on the weekly schedule only, not when one release is measured by hand
        lts = output[output.index('key: "ttfx_lts_'):output.index('key: "ttfx_branch_nightly_')]
        self.assertIn('if: build.env("TTFX_RELEASE") == "latest"', lts)
        self.assertIn('TTFX_RELEASE: "1.10"', lts)
        nightly = output[output.index('key: "ttfx_branch_nightly_'):]
        self.assertIn('if: build.env("TTFX_RELEASE") == "latest"', nightly)
        self.assertIn('TTFX_RELEASE: "branch-nightly"', nightly)

    def test_schedule_measures_the_optimized_build_on_ttfx(self):
        output = render(source="schedule", BUILDKITE_PIPELINE_SLUG="julia-ci")
        self.assertEqual(output.count('group: "TTFX opt"'), 1)
        step = re.search(
            r'^      - label: ":macos: TTFX opt aarch64-apple-darwin"\n'
            r'.*?(?=^      - |^  - group:|\Z)', output, re.M | re.S,
        ).group()
        self.assertIn('key: "ttfx_opt_aarch64-apple-darwin"', step)
        self.assertIn('depends_on:\n          - "build_aarch64-apple-darwinopt"', step)
        self.assertIn('TRIPLET: "aarch64-apple-darwinopt"', step)
        self.assertIn('TTFX_BASE: "commit"', step)
        self.assertIn("soft_fail: true", step)
        self.assertIn('arch: "aarch64"', step)
        # The master job's `TTFX` status is on the same commit
        self.assertNotIn("github_commit_status", step)
        # Not on labeled pull requests, nor on per-commit builds
        for args, source in ((("--scheduled-workloads",), None), ((), None)):
            self.assertNotIn("TTFX opt", render(*args, source=source))

    def test_publish_dependencies_exist(self):
        for source, build_env in ((None, {}), ("schedule", {}),
                                  (None, {"BUILDKITE_PIPELINE_SLUG": "julia-ci",
                                          "BUILDKITE_TAG": "v1.14.0"}),
                                  (None, {"BUILDKITE_PIPELINE_SLUG": "julia-ci",
                                          "BUILDKITE_BRANCH": "release-1.14"}),
                                  (None, {"NOGPL_ONLY": "true"}),
                                  (None, {"OPT_ONLY": "true"}),
                                  (None, {"BUILDKITE_PIPELINE_SLUG": "julia-ci",
                                          "BUILDKITE_BRANCH": "v1.14.0",
                                          "ONLY_TRIPLETS": "riscv64-linux-gnu,x86_64-linux-gnuopt"})):
            output = render(source=source, **build_env)
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


class InterpolateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        sys.path.insert(0, os.path.dirname(RENDERER))
        import render_launch_pipeline
        cls.interpolate = staticmethod(render_launch_pipeline.interpolate)

    def test_matches_agent(self):
        # each expected output is what `buildkite-agent pipeline upload` makes
        # of the template with this env
        env = {"FOO": "x", "EMPTY": ""}
        for text, expected in [
            # runtime escapes are left for the final upload...
            ("$${FOO}", "$${FOO}"), ("$$FOO", "$$FOO"), ("\\${FOO}", "\\${FOO}"),
            # ...but only consume their own two characters
            ("$$${FOO}", "$$x"), ("\\$$FOO", "\\$x"), ("\\\\${FOO}", "\\\\x"),
            # bare variables
            ("$FOO", "x"), ("a $FOO.b", "a x.b"),
            # nested defaults
            ("${EMPTY:-${FOO}}", "x"), ("${EMPTY:-$FOO}", "x"),
        ]:
            self.assertEqual(self.interpolate(text, env, "test"), expected, text)

    def test_unsupported_expansion_rejected(self):
        # these previously expanded to plain ${FOO}, dropping the suffix
        for text in ("${FOO:0:2}", "${FOO/a/b}", "${FOO:=d}"):
            with self.assertRaisesRegex(ValueError, "unsupported"):
                self.interpolate(text, {"FOO": "x"}, "test")


class PullRequestGatingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        sys.path.insert(0, os.path.dirname(RENDERER))
        import render_launch_pipeline
        cls.rlp = render_launch_pipeline

    def render_pr(self, changed):
        """The pipeline of a pull request that changes `changed` (None: every
        job runs, as with the `needs full CI` label)."""
        import contextlib
        import io
        from unittest import mock
        rlp = self.rlp
        for keys in (rlp.BUILD_KEYS, rlp.TEST_KEYS, rlp.SEEN_TRIPLETS):
            keys.clear()
        out = io.StringIO()
        env = {k: v for k, v in os.environ.items()
               if k not in ("BUILDKITE_SOURCE", "NOGPL_ONLY", "OPT_ONLY", "ONLY_TRIPLETS",
                            "TTFX_RELEASE", "BUILDKITE_TAG", "BUILDKITE_BRANCH")}
        env["BUILDKITE_PIPELINE_SLUG"] = "julia-pr"
        import tempfile
        cwd = os.getcwd()
        # A julia checkout with JuliaSyntax in it
        with tempfile.TemporaryDirectory() as julia:
            os.makedirs(os.path.join(julia, "JuliaSyntax"))
            open(os.path.join(julia, "JuliaSyntax", "Project.toml"), "w").close()
            os.chdir(julia)
            try:
                with mock.patch.object(rlp, "pr_changed_paths", lambda: changed), \
                        mock.patch.dict(os.environ, env, clear=True), \
                        mock.patch.object(sys, "argv", [RENDERER]), \
                        contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
                    rlp.main()
            finally:
                os.chdir(cwd)
        return out.getvalue()

    NATIVE_JOBS = ('key: "asan"', 'label: "tsan"', 'label: "llvmpasses"', 'label: "analyzegc"',
                   'label: "embedding"', 'label: "gcext"', 'key: "build_x86_64-linux-gnuprofiling"')

    def test_native_checks(self):
        everything = self.render_pr(None)
        for job in self.NATIVE_JOBS:
            self.assertIn(job, everything)
        julia_only = self.render_pr(["base/array.jl", "test/arrayops.jl"])
        for job in self.NATIVE_JOBS:
            self.assertNotIn(job, julia_only)
        # The required platforms still build and test
        self.assertIn('key: "build_x86_64-linux-gnu"', julia_only)
        self.assertIn('key: "test_x86_64-linux-gnu"', julia_only)
        self.assertIn('label: "doctest"', julia_only)
        for path in ("src/gf.c", "deps/llvm.mk", "Make.inc", "cli/loader_exe.c",
                     "contrib/asan/build.sh", "test/llvmpasses/alloc-opt.ll", "stdlib/Makefile"):
            output = self.render_pr([path])
            for job in self.NATIVE_JOBS:
                self.assertIn(job, output, path)

    def test_juliasyntax(self):
        group = 'group: "JuliaSyntax"'
        self.assertIn(group, self.render_pr(None))
        self.assertIn(group, self.render_pr(["JuliaSyntax/src/parser.jl"]))
        self.assertNotIn(group, self.render_pr(["base/array.jl", "src/gf.c"]))

    def test_pdf_docs(self):
        job = 'label: "pdf_docs_build"'
        self.assertIn(job, self.render_pr(None))
        self.assertIn(job, self.render_pr(["doc/src/manual/types.md"]))
        self.assertNotIn(job, self.render_pr(["base/array.jl", "src/gf.c"]))

    def test_mmtk(self):
        jobs = ('key: "build_x86_64-linux-gnummtkconcurrent"',
                'key: "test_x86_64-linux-gnummtkconcurrent"')
        for changed in (None, ["Compiler/src/optimize.jl"], ["src/gc-mmtk.c"]):
            output = self.render_pr(changed)
            for job in jobs:
                self.assertIn(job, output, changed)
        output = self.render_pr(["base/array.jl", "test/arrayops.jl"])
        for job in jobs:
            self.assertNotIn(job, output)

    def test_label_runs_everything(self):
        from unittest import mock
        rlp = self.rlp
        env = {"BUILDKITE_PIPELINE_SLUG": "julia-pr", "BUILDKITE_PULL_REQUEST": "123",
               "BUILDKITE_PULL_REQUEST_LABELS": "bugfix,needs full CI"}
        with mock.patch.dict(os.environ, env):
            rlp.pr_changed_paths.cache_clear()
            self.assertIsNone(rlp.pr_changed_paths())
        rlp.pr_changed_paths.cache_clear()
        # Not a pull request
        with mock.patch.dict(os.environ, {"BUILDKITE_PIPELINE_SLUG": "julia-ci"}):
            self.assertIsNone(rlp.pr_changed_paths())
        rlp.pr_changed_paths.cache_clear()


    def test_label_added_after_the_build_was_created(self):
        import io
        import json
        from unittest import mock
        rlp = self.rlp
        env = {"BUILDKITE_PULL_REQUEST": "63807", "BUILDKITE_PULL_REQUEST_LABELS": "bugfix",
               "BUILDKITE_REPO": "https://github.com/JuliaLang/julia.git"}
        urls = []

        def github(labels):
            def urlopen(request, timeout):
                urls.append(request.full_url)
                return io.BytesIO(json.dumps([{"name": n} for n in labels]).encode())
            return urlopen
        with mock.patch.dict(os.environ, env):
            with mock.patch("urllib.request.urlopen", github(["bugfix", "needs full CI"])):
                self.assertTrue(rlp.pr_has_label("needs full CI"))
            self.assertEqual(urls, ["https://api.github.com/repos/JuliaLang/julia/issues/63807/labels?per_page=100"])
            with mock.patch("urllib.request.urlopen", github(["bugfix"])):
                self.assertFalse(rlp.pr_has_label("needs full CI"))

            def unreachable(request, timeout):
                raise OSError("no network")
            with mock.patch("urllib.request.urlopen", unreachable), \
                    mock.patch.object(rlp, "log"):
                self.assertFalse(rlp.pr_has_label("needs full CI"))


if __name__ == "__main__":
    unittest.main()
