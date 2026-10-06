#!/usr/bin/env python3
"""
Check that every pipeline YAML, and the rendered launch pipeline, can be
interpolated and parsed by `buildkite-agent pipeline upload --dry-run`.

Every variable a YAML references is set to a dummy value, so this catches
syntax the agent cannot parse (e.g. `${VAR:+...}`, see #645) rather than
missing values. Skipped if `buildkite-agent` is not on PATH (or at
$BUILDKITE_AGENT_BIN).
"""

import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RENDERER = os.path.join(ROOT, "utilities", "render_launch_pipeline.py")
AGENT = os.environ.get("BUILDKITE_AGENT_BIN") or shutil.which("buildkite-agent")

# `--dry-run` refuses to start without these, but never contacts the endpoint
AGENT_ENV = {
    "BUILDKITE_AGENT_ACCESS_TOKEN": "dry-run",
    "BUILDKITE_JOB_ID": "00000000-0000-0000-0000-000000000000",
    "BUILDKITE_AGENT_ENDPOINT": "http://127.0.0.1:9",
}

_NAME_RE = re.compile(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)")


def dry_run(path):
    with open(path) as f:
        names = set(_NAME_RE.findall(f.read()))
    return subprocess.run(
        [AGENT, "pipeline", "upload", "--dry-run", path],
        env={"PATH": os.environ["PATH"], **{n: "x" for n in names}, **AGENT_ENV},
        capture_output=True, text=True,
    )


@unittest.skipUnless(AGENT, "buildkite-agent not found")
class PipelineDryRunTests(unittest.TestCase):
    def assertDryRuns(self, path, label):
        result = dry_run(path)
        self.assertEqual(result.returncode, 0, f"{label}:\n{result.stderr}")

    def test_pipeline_yamls(self):
        for dirpath, _, files in os.walk(os.path.join(ROOT, "pipelines")):
            for f in sorted(files):
                if f.endswith(".yml"):
                    path = os.path.join(dirpath, f)
                    with self.subTest(path=os.path.relpath(path, ROOT)):
                        self.assertDryRuns(path, os.path.relpath(path, ROOT))

    def test_rendered_launch_pipeline(self):
        release = {"BUILDKITE_PIPELINE_SLUG": "julia-ci", "BUILDKITE_BRANCH": "v1.14.0"}
        branch = {"BUILDKITE_PIPELINE_SLUG": "julia-ci", "BUILDKITE_BRANCH": "release-1.14"}
        for args, build_env in (([], {}), (["--scheduled-workloads"], {}),
                                ([], release), ([], branch),
                                ([], {**release, "NOGPL_ONLY": "true"})):
            with self.subTest(args=args, env=build_env), tempfile.TemporaryDirectory() as tmp:
                rendered = os.path.join(tmp, "pipeline.yml")
                with open(rendered, "w") as f:
                    subprocess.run([sys.executable, RENDERER, *args], cwd=ROOT,
                                   env={**os.environ, **build_env},
                                   check=True, stdout=f, stderr=subprocess.DEVNULL)
                self.assertDryRuns(rendered, f"render_launch_pipeline.py {' '.join(args)} {build_env}")


if __name__ == "__main__":
    unittest.main()
