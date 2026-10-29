#!/usr/bin/env python3
"""Exercise the Fastly purge helpers with fake curl and AWS CLIs."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[2]
BASH = shutil.which("bash")


class FastlyPurgeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.work = Path(self.tmp.name)
        bin_dir = self.work / "bin"
        bin_dir.mkdir()
        self.calls = self.work / "calls.log"
        for tool in ("curl", "aws"):
            path = bin_dir / tool
            path.write_text(textwrap.dedent(f'''\
                #!/usr/bin/env python3
                import os, sys
                with open(os.environ["FIXTURE_CALLS"], "a") as f:
                    f.write("{tool} " + " ".join(sys.argv[1:]) + "\\n")
                if "{tool}" == "aws":
                    if "FIXTURE_SSM_TOKEN" not in os.environ:
                        sys.exit("An error occurred (AccessDeniedException) when calling the GetParameter operation")
                    print(os.environ["FIXTURE_SSM_TOKEN"])
                '''))
            path.chmod(0o755)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith("FASTLY_PURGE_TOKEN")}
        self.env.update({"PATH": f"{bin_dir}:{os.environ['PATH']}", "FIXTURE_CALLS": str(self.calls)})

    def run_bash(self, script, **env):
        self.calls.unlink(missing_ok=True)
        result = subprocess.run([BASH, "-c", f"set -euo pipefail; source '{ROOT}/utilities/fastly_purge.sh'; {script}"],
                                env={**self.env, **env}, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls.read_text().splitlines() if self.calls.exists() else []
        return result, calls

    TARGETS = " ".join([
        "julialangnightlies/bin/linux/x86_64/1.15/julia-82e07fcb36-linux-x86_64.tar.gz",
        "julialangnightlies/bin/linux/x86_64/1.15/julia-latest-linux-x86_64.tar.gz",
        "julialangnightlies/bin/linux/x86_64/julia-latest-linux-x86_64.tar.gz.asc",
        "julialang2/bin/linux/x64/1.14/julia-1.14-latest-linux-x86_64.tar.gz",
        "julialang-nogpl/bin/linux/x86_64/julia-latest-linux-x86_64.tar.gz",
        "test-bucket/bin/julia-latest-fixture.tar.gz",
    ])

    def test_purges_targets_on_their_cdn(self):
        _, calls = self.run_bash(f"fastly_purge_targets {self.TARGETS}", FASTLY_PURGE_TOKEN="tok")
        urls = sorted(c.split()[-1] for c in calls if c.startswith("curl"))
        self.assertEqual(urls, [
            "https://julialang-s3.julialang.org/bin/linux/x64/1.14/julia-1.14-latest-linux-x86_64.tar.gz",
            "https://julialangnightlies-s3.julialang.org/bin/linux/x86_64/1.15/julia-82e07fcb36-linux-x86_64.tar.gz",
            "https://julialangnightlies-s3.julialang.org/bin/linux/x86_64/1.15/julia-latest-linux-x86_64.tar.gz",
            "https://julialangnightlies-s3.julialang.org/bin/linux/x86_64/julia-latest-linux-x86_64.tar.gz.asc",
        ])
        for call in calls:
            self.assertIn("-X PURGE", call)
            self.assertIn("Fastly-Key: tok", call)
            self.assertNotIn("Fastly-Soft-Purge", call)

    def test_without_token_warns_once_per_cdn_and_does_not_purge(self):
        result, calls = self.run_bash(f"fastly_purge_targets {self.TARGETS}")
        self.assertEqual(calls, [])
        self.assertEqual(result.stderr.count("no Fastly purge token"), 2, result.stderr)

    def test_token_from_ssm_is_read_once(self):
        _, calls = self.run_bash("load_fastly_purge_token /julia-publish/tokens/fastly_purge_token; "
                                 "load_fastly_purge_token /julia-publish/tokens/fastly_purge_token; "
                                 "fastly_purge https://julialangnightlies-s3.julialang.org bin/x/julia-latest-x.tar.gz",
                                 FIXTURE_SSM_TOKEN="from-ssm")
        self.assertEqual(sum(c.startswith("aws ssm get-parameter") for c in calls), 1)
        self.assertIn("/julia-publish/tokens/fastly_purge_token", calls[0])
        self.assertIn("Fastly-Key: from-ssm", calls[-1])

    def test_preset_token_skips_ssm(self):
        _, calls = self.run_bash("load_fastly_purge_token /p", FASTLY_PURGE_TOKEN="preset")
        self.assertEqual(calls, [])

    def test_unreadable_token_only_warns(self):
        result, calls = self.run_bash("load_fastly_purge_token /julia-publish/tokens/fastly_purge_token; "
                                      "fastly_purge https://julialangnightlies-s3.julialang.org bin/x/julia-latest-x.tar.gz")
        self.assertIn("could not read /julia-publish/tokens/fastly_purge_token", result.stderr)
        self.assertFalse(any(c.startswith("curl") for c in calls))

    def test_failed_purge_only_warns(self):
        failing = self.work / "bin" / "curl"
        failing.write_text("#!/usr/bin/env bash\nexit 22\n")
        result, _ = self.run_bash("fastly_purge https://julialangnightlies-s3.julialang.org bin/x/julia-latest-x.tar.gz",
                                  FASTLY_PURGE_TOKEN="tok")
        self.assertIn("cache purge failed for https://julialangnightlies-s3.julialang.org/bin/x/julia-latest-x.tar.gz",
                      result.stderr)


if __name__ == "__main__":
    unittest.main()
