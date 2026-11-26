#!/usr/bin/env python3
"""Check that a pull request's merge-base is built from source only when the nightly has not
(utilities/build_julia_merge_base.sh), and that the benchmark jobs find either build
(utilities/src_merge_base.sh).

The scripts run against a fixture git repository, with doubles for `buildkite-agent`,
`curl` and the build script. Nothing is built or downloaded.
"""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]

AGENT = '''#!/usr/bin/env bash
echo "$*" >> "$FIXTURE_LOG"
case "$1 $2" in
  "meta-data set") echo "$4" > "$FIXTURE_META/$3" ;;
  "meta-data get") cat "$FIXTURE_META/$3" ;;
  "artifact download") [[ -n "${FIXTURE_ARTIFACT:-}" ]] && echo built > "$6/$FIXTURE_ARTIFACT" ;;
esac
'''


class SrcMergeBaseTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        tmp = Path(self.tmp.name)
        self.origin, self.work, self.bin = tmp / "origin", tmp / "work", tmp / "bin"
        self.meta, self.log = tmp / "meta", tmp / "calls.log"
        for d in (self.bin, self.meta):
            d.mkdir()
        self.git("init", "-q", "-b", "master", str(self.origin), cwd=tmp)
        self.commit(self.origin, "base")
        self.merge_base = self.git("rev-parse", "HEAD", cwd=self.origin)
        self.commit(self.origin, "master moves on")
        self.git("clone", "-q", str(self.origin), str(self.work), cwd=tmp)
        self.git("checkout", "-q", "-b", "pr", self.merge_base, cwd=self.work)
        self.commit(self.work, "the pull request")
        utils = self.work / ".buildkite/utilities"
        utils.mkdir(parents=True)
        for script in ("build_julia_merge_base.sh", "src_merge_base.sh", "extract_triplet.sh"):
            shutil.copy(ROOT / "utilities" / script, utils / script)
        # The build records the commit it was asked to build
        self.write(utils / "build_julia.sh", 'git rev-parse HEAD > "$FIXTURE_BUILT"; echo "$SKIP_STAGING" >> "$FIXTURE_BUILT"\n')
        self.write(self.bin / "buildkite-agent", AGENT)

    def git(self, *args, cwd):
        env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t",
               "GIT_COMMITTER_EMAIL": "t@t"}
        return subprocess.run(["git", *args], cwd=cwd, env=env, check=True, capture_output=True, text=True).stdout.strip()

    def commit(self, repo, message):
        self.git("commit", "-q", "--allow-empty", "-m", message, cwd=repo)

    def write(self, path, text):
        path.write_text("#!/usr/bin/env bash\n" + text if not text.startswith("#!") else text)
        path.chmod(0o755)

    def run_bash(self, script, curl_ok, **env):
        self.write(self.bin / "curl", f"#!/usr/bin/env bash\nexit {0 if curl_ok else 22}\n")
        full = {**os.environ, "PATH": f"{self.bin}:{os.environ['PATH']}", "TRIPLET": "aarch64-apple-darwinsrc",
                "BUILDKITE_PIPELINE_SLUG": "julia-pr", "BUILDKITE_REPO": str(self.origin),
                "BUILDKITE_PULL_REQUEST_BASE_BRANCH": "master", "FIXTURE_LOG": str(self.log),
                "FIXTURE_META": str(self.meta), "FIXTURE_BUILT": str(self.work / "built"), **env}
        return subprocess.run(["bash", "-c", script], cwd=self.work, env=full, capture_output=True, text=True)

    def test_builds_the_merge_base_when_the_nightly_did_not(self):
        r = self.run_bash("bash .buildkite/utilities/build_julia_merge_base.sh", curl_ok=False)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual((self.meta / "src-merge-base").read_text().strip(), self.merge_base)
        self.assertEqual((self.meta / "src-merge-base-branch").read_text().strip(), "master")
        self.assertEqual((self.work / "built").read_text().split(), [self.merge_base, "true"])

    def test_uses_the_nightly_build_of_the_merge_base(self):
        r = self.run_bash("bash .buildkite/utilities/build_julia_merge_base.sh", curl_ok=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("from source already", r.stdout)
        self.assertFalse((self.work / "built").exists())
        self.assertEqual((self.meta / "src-merge-base").read_text().strip(), self.merge_base)

    def test_benchmark_jobs_fetch_the_merge_base_build(self):
        (self.meta / "src-merge-base").write_text(self.merge_base)
        (self.meta / "src-merge-base-branch").write_text("master")
        fetch = ('source .buildkite/utilities/extract_triplet.sh; source .buildkite/utilities/src_merge_base.sh; '
                 'fetch_src_merge_base "$PWD/base.tar.gz" && echo "$MERGE_BASE $BASE_BRANCH"')
        # This build's merge-base job built it, named by its commit
        name = f"julia-{self.merge_base[:10]}-macossrc-aarch64.tar.gz"
        r = self.run_bash(fetch, curl_ok=False, FIXTURE_ARTIFACT=name)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn(f"{self.merge_base} master", r.stdout)
        self.assertEqual((self.work / "base.tar.gz").read_text(), "built\n")
        self.assertIn("artifact download --step build_aarch64-apple-darwinsrc_merge_base", self.log.read_text())
        # The nightly's build comes first; no artifact is asked for
        self.log.unlink()
        r = self.run_bash(fetch, curl_ok=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("artifact download", self.log.read_text())


if __name__ == "__main__":
    unittest.main()
