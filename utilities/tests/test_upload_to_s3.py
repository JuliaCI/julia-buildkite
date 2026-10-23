#!/usr/bin/env python3
"""Exercise upload_to_s3's Cache-Control and overwrite handling with a fake AWS CLI."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[2]
BASH = shutil.which("bash")


class UploadToS3Tests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.work = Path(self.tmp.name)
        bin_dir = self.work / "bin"
        bin_dir.mkdir()
        aws = bin_dir / "aws"
        aws.write_text(textwrap.dedent('''\
            #!/usr/bin/env python3
            import json, os, sys
            with open(os.environ["FIXTURE_AWS_LOG"], "a") as f:
                f.write(json.dumps(sys.argv[1:]) + "\\n")
            '''))
        aws.chmod(0o755)
        (self.work / "file").write_text("payload")
        self.log = self.work / "aws.log"
        self.env = {**os.environ, "PATH": f"{bin_dir}:{os.environ['PATH']}",
                    "FIXTURE_AWS_LOG": str(self.log), "BUILDKITE_COMMIT": "a" * 40}

    def upload(self, target, *cache_control, **env):
        args = " ".join(f"'{a}'" for a in (str(self.work / "file"), target, *cache_control))
        self.log.unlink(missing_ok=True)
        subprocess.run([BASH, "-c", f"source '{ROOT}/utilities/upload_to_s3.sh' && upload_to_s3 {args}"],
                       env={**self.env, **env}, check=True, capture_output=True, text=True)
        (call,) = [json.loads(line) for line in self.log.read_text().splitlines()]
        return call

    @staticmethod
    def option(call, name):
        return call[call.index(name) + 1] if name in call else None

    def test_default_cache_control(self):
        cases = {
            "julialangnightlies/bin/linux/x86_64/1.15/julia-82e07fcb36-linux-x86_64.tar.gz": "public,max-age=2678400",
            "julialangnightlies/bin/linux/x86_64/1.15/julia-latest-linux-x86_64.tar.gz": None,
            "julialangnightlies/bin/linux/x86_64/julia-latest-linux-x86_64.tar.gz.asc": None,
            "julialang2/bin/linux/x64/1.14/julia-1.14-latest-linux-x86_64.tar.gz": None,
            "julialangnightlies/src/1.14/julia-1.14.0-full.tar.gz": "public,max-age=2678400",
        }
        for target, expected in cases.items():
            with self.subTest(target=target):
                self.assertEqual(self.option(self.upload(target), "--cache-control"), expected)

    def test_explicit_cache_control_wins(self):
        call = self.upload("julialang2/bin/linux/x64/1.14/julia-1.14.0-linux-x86_64.tar.gz", "no-cache")
        self.assertEqual(self.option(call, "--cache-control"), "no-cache")

    def test_staging_uploads_get_no_default(self):
        call = self.upload("staging-bucket/abc/julia-fixture.tar.gz", UPLOAD_TO_S3_ACL="none")
        self.assertNotIn("--cache-control", call)
        self.assertNotIn("--acl", call)

    def test_latest_pointers_overwrite_others_are_write_once(self):
        latest = self.upload("julialangnightlies/bin/linux/x86_64/julia-latest-linux-x86_64.tar.gz")
        versioned = self.upload("julialangnightlies/bin/linux/x86_64/1.15/julia-82e07fcb36-linux-x86_64.tar.gz")
        self.assertNotIn("--if-none-match", latest)
        self.assertEqual(self.option(versioned, "--if-none-match"), "*")
        for call in (latest, versioned):
            self.assertEqual(self.option(call, "--acl"), "public-read")
            self.assertEqual(self.option(call, "--metadata"), "build-commit=" + "a" * 40)


if __name__ == "__main__":
    unittest.main()
