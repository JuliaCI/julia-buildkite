#!/usr/bin/env python3
"""Exercise upload_to_s3_all's ordering and overwrite handling with a fake AWS CLI."""

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


class FakeAwsTestCase(unittest.TestCase):
    """Runs the helpers against a fake `aws` that logs its arguments."""

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
            args = sys.argv[1:]
            with open(os.environ["FIXTURE_AWS_LOG"], "a") as f:
                f.write(json.dumps(args) + "\\n")
            # FIXTURE_TAKEN_KEY: already published by another commit
            taken = args[args.index("--key") + 1] == os.environ.get("FIXTURE_TAKEN_KEY")
            if taken and args[1] == "put-object" and "--if-none-match" in args:
                sys.exit("An error occurred (PreconditionFailed) when calling the PutObject operation")
            if taken and args[1] == "head-object":
                print('"0123"\\t' + "b" * 40)
            '''))
        aws.chmod(0o755)
        (self.work / "file").write_text("payload")
        self.log = self.work / "aws.log"
        self.env = {**os.environ, "PATH": f"{bin_dir}:{os.environ['PATH']}",
                    "FIXTURE_AWS_LOG": str(self.log), "BUILDKITE_COMMIT": "a" * 40}


class UploadAllTests(FakeAwsTestCase):
    VERSIONED = "julialangnightlies/bin/linux/x86_64/1.14/julia-1.14.0-linux-x86_64.tar.gz"
    LATEST = "julialangnightlies/bin/linux/x86_64/1.14/julia-latest-linux-x86_64.tar.gz"

    def upload_all(self, *targets, **env):
        args = " ".join(f"'{self.work / 'file'}' '{t}'" for t in targets)
        self.log.unlink(missing_ok=True)
        result = subprocess.run(
            [BASH, "-c", f"source '{ROOT}/utilities/upload_to_s3.sh' && upload_to_s3_all {args}"],
            env={**self.env, **env}, capture_output=True, text=True)
        calls = [json.loads(line) for line in self.log.read_text().splitlines()]
        puts = [c[c.index("--key") + 1] for c in calls if c[1] == "put-object"]
        return result, puts

    def test_latest_pointers_follow_the_other_uploads(self):
        result, puts = self.upload_all(self.LATEST, self.VERSIONED)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(puts, [self.VERSIONED.split("/", 1)[1], self.LATEST.split("/", 1)[1]])

    def test_refused_upload_keeps_the_latest_pointers(self):
        result, puts = self.upload_all(self.LATEST, self.VERSIONED,
                                       FIXTURE_TAKEN_KEY=self.VERSIONED.split("/", 1)[1])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("refusing to overwrite", result.stderr)
        self.assertIn("Moving a release tag after it was published", result.stderr)
        self.assertIn("not moving the latest pointers", result.stderr)
        self.assertEqual(puts, [self.VERSIONED.split("/", 1)[1]])


if __name__ == "__main__":
    unittest.main()
