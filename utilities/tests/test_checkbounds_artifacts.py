#!/usr/bin/env python3
"""Exercise companion publishing with real archives and offline service/signing doubles."""

import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[2]
BASH = shutil.which("bash")


class CheckboundsArtifactsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.work = Path(self.tmp.name)
        self.utils = self.work / ".buildkite/utilities"
        self.utils.mkdir(parents=True)
        self.bin = self.work / "tools"
        self.bin.mkdir()
        self.stage = self.work / "stage"
        self.stage.mkdir()
        self.output = self.work / "output"
        self.output.mkdir()
        self.env = {**os.environ, "PATH": f"{self.bin}:{os.environ['PATH']}",
                    "FIXTURE_STAGE": str(self.stage), "FIXTURE_OUTPUT": str(self.output),
                    "OS": "linux", "HAS_CHECKBOUNDS_PKGIMAGES": "true",
                    "PUBLISH_PREAUTHED": "1", "PUBLISH_SKIP_NOTARIZATION": "1",
                    "PUBLISH_SKIP_WINDOWS_SIGN": "1", "BUILDKITE_BRANCH": "v1.14.0",
                    "BUILDKITE_COMMIT": "a" * 40, "BUILDKITE_JOB_ID": "fixture",
                    "BUILDKITE_TIMEOUT": "90", "BUILDKITE_PIPELINE_SLUG": "fixture"}
        for script in ("upload_julia.sh", "promote_release.sh", "test_julia.sh", "build_julia.sh", "word.sh"):
            shutil.copy(ROOT / "utilities" / script, self.utils / script)
        self.write(self.utils / "build_envs.sh", '''
export UPLOAD_FILENAME=julia-fixture JULIA_INSTALL_DIR=julia-fixture
export JULIA_BINARY=julia-fixture/bin/julia STAGING_TARGET=staging/julia-fixture
export JULIA_CPU_THREADS=1 ARCH=x86_64 TRIPLET=x86_64-fixture MAJMIN=1.14
export JULIA_VERSION=1.14.0 EXTERNAL_STDLIB_NAMES=""
UPLOAD_TARGETS=(published/julia-fixture published/julia-latest-fixture)
''')
        self.write(self.utils / "upload_to_s3.sh", '''
upload_to_s3() {
    mkdir -p "${FIXTURE_OUTPUT}/$(dirname "$2")"
    cp "$1" "${FIXTURE_OUTPUT}/$2"
}
''')
        for helper in ("verify_trusted_commit.sh", "aws_oidc.sh"):
            self.write(self.utils / helper, "#!/usr/bin/env bash\nexit 0\n" if helper.startswith("verify") else ":\n")
        self.python(self.bin / "aws", '''
import os, pathlib, shutil, sys
args = sys.argv[1:]
if args[:2] == ["s3api", "head-object"]:
    key = args[args.index("--key") + 1]
    if key.startswith("bin/src/"):
        sys.exit(1)
    print(os.environ["BUILDKITE_COMMIT"])
elif args[:2] == ["s3", "cp"]:
    shutil.copy(pathlib.Path(os.environ["FIXTURE_STAGE"]) / pathlib.Path(args[-2]).name, args[-1])
else:
    raise RuntimeError(args)
''')
        self.python(self.utils / "kms_gpg_sign.py", '''
import pathlib, sys
p = pathlib.Path(sys.argv[-1])
assert p.is_file()
p.with_name(p.name + ".asc").write_text("signature")
''')
        signer = '''
import pathlib, sys
root = pathlib.Path(sys.argv[-1])
if "--seal-only" not in sys.argv:
    for path in root.rglob("*"):
        if path.suffix in (".so", ".dll", ".dylib"):
            path.write_text(path.read_text() + " signed")
'''
        for platform in ("macos", "windows"):
            self.python(self.utils / platform / "codesign.sh", signer)
        self.python(self.bin / "julia", '''
import pathlib, sys
if any("update_stdlib_pkgimage_checksums" in a for a in sys.argv):
    root = pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 else pathlib.Path("julia-fixture")
    for p in root.rglob("*.ji"):
        lib = next(q for q in p.parent.glob(p.stem + ".*") if q.suffix != ".ji")
        assert lib.read_text().endswith(" signed")
        p.write_text("fixed checksum")
''')
        self.python(self.utils / "macos/build_dmg.sh", '''
import os, pathlib
pathlib.Path(os.environ["UPLOAD_FILENAME"] + ".dmg").write_text("dmg")
''')
        self.python(self.bin / "wine", '''
import pathlib, sys
if sys.argv[1] == "winepath":
    print(sys.argv[-1])
else:
    pathlib.Path("julia-fixture.exe").write_text("installer")
''')
        self.python(self.bin / "7z", 'import pathlib; pathlib.Path("julia-fixture.zip").write_text("zip")\n')
        self.python(self.bin / "curl", 'print("200")\n')
        self.python(self.bin / "sysctl", 'print("core")\n')
        self.python(self.bin / "buildkite-agent", '''
import os, pathlib, shutil, sys
if sys.argv[1:3] == ["artifact", "download"]:
    assert sys.argv[3:5] == ["--step", "build_x86_64-fixture"]
    sources = list(pathlib.Path(os.environ["FIXTURE_STAGE"]).glob(sys.argv[-2]))
    assert sources, sys.argv[-2]
    for source in sources:
        shutil.copy(source, sys.argv[-1])
elif sys.argv[1:3] == ["artifact", "upload"]:
    dest = pathlib.Path(os.environ["FIXTURE_OUTPUT"]) / "artifacts"
    dest.mkdir(exist_ok=True)
    shutil.copy(sys.argv[-1], dest)
else:
    assert sys.argv[1:] == ["--version"]
''')
        for algo in ("sha256", "md5"):
            self.python(self.bin / (algo + "sum"), f'''
import hashlib, pathlib, sys
for name in sys.argv[1:]:
    print(hashlib.{algo}(pathlib.Path(name).read_bytes()).hexdigest() + "  " + name)
''')

    def write(self, path, text):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        path.chmod(0o755)

    def python(self, path, text):
        self.write(path, "#!/usr/bin/env python3\n" + text)

    def archive(self, name, source, arcname):
        with tarfile.open(self.stage / name, "w:gz") as tar:
            tar.add(source, arcname=arcname)

    def fixtures(self, platform):
        self.env["OS"] = platform
        suffix = {"macos": "dylib", "windows": "dll"}.get(platform, "so")
        normal = self.work / "normal"
        cache = Path("share/julia/compiled/v1.14/Test")
        self.write(normal / cache / f"auto.{suffix}", "default image")
        self.write(normal / cache / "auto.ji", "default checksum")
        shutil.copy(self.bin / "julia", normal / "julia")
        (normal / "bin").mkdir()
        shutil.move(normal / "julia", normal / "bin/julia")
        self.archive("julia-fixture.tar.gz", normal, "julia-fixture")
        companion = self.work / "companion"
        self.write(companion / cache / f"checked.{suffix}", "checked image")
        self.write(companion / cache / "checked.ji", "checked checksum")
        self.archive("julia-fixture.checkbounds.tar.gz", companion / "share", "share")
        if platform == "macos":
            app = self.work / "app/Julia-1.14.app"
            shutil.copytree(normal, app / "Contents/Resources/julia")
            self.archive("julia-fixture.app.tar.gz", app, app.name)

    def run_script(self, name, *args, success=True):
        result = subprocess.run([BASH, str(self.utils / name), *args], cwd=self.work,
                                env=self.env, capture_output=True, text=True)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def test_publish_platforms(self):
        for platform in ("linux", "macos", "windows", "freebsd"):
            with self.subTest(platform=platform):
                # Each platform gets a fresh fixture, as real publish jobs do.
                with CheckboundsArtifactsTests(methodName="runTest") as case:
                    case.fixtures(platform)
                    case.run_script("upload_julia.sh", "publish")
                    for target in ("julia-fixture", "julia-latest-fixture"):
                        published = case.output / "published"
                        with tarfile.open(published / (target + ".tar.gz")) as tar:
                            self.assertFalse(any("checked." in n for n in tar.getnames()))
                        with tarfile.open(published / (target + ".checkbounds.tar.gz")) as tar:
                            self.assertFalse(any("auto." in n for n in tar.getnames()))
                            ji = tar.extractfile("share/julia/compiled/v1.14/Test/checked.ji").read()
                            self.assertEqual(ji, b"fixed checksum" if platform in ("macos", "windows") else b"checked checksum")
                        self.assertTrue((published / (target + ".checkbounds.tar.gz.asc")).is_file())

    def __enter__(self):
        self.setUp()
        return self

    def __exit__(self, *args):
        self.doCleanups()

    def test_build_companion_after_macos_app_packaging(self):
        self.fixtures("macos")
        self.write(self.work / "VERSION", "1.14.0")
        (self.work / "usr/bin").mkdir(parents=True)
        shutil.copy(self.bin / "julia", self.work / "usr/bin/julia")
        with (self.utils / "build_envs.sh").open("a") as f:
            f.write("export MAKE=make MAKE_FLAGS= JULIA_CPU_TARGET=generic EXPECTED_WORD_SIZE=64 JULIA_BINARYDIST_FILENAME=julia-build\n")
        for tool in ("git", "cc", "ld"):
            self.write(self.bin / tool, "#!/usr/bin/env bash\nexit 0\n")
        self.python(self.bin / "make", '''
import os, pathlib, shutil, sys
args = sys.argv[1:]
assert args[-1] != "JULIA_CHECK_BOUNDS_PKGIMAGES=1"
assert "JULIA_CHECK_BOUNDS_PKGIMAGES=0" in args
stage = pathlib.Path(os.environ["FIXTURE_STAGE"])
if "binary-dist" in args or "contrib/mac/app" in args:
    for p in pathlib.Path(".").glob("julia-*.tar.gz"):
        p.unlink()
    shutil.copy(stage / "julia-fixture.tar.gz", "julia-build.tar.gz")
    if "contrib/mac/app" in args:
        shutil.copytree("app/Julia-1.14.app", "contrib/mac/app/dmg/Julia-1.14.app")
elif "checkbounds-pkgimages" in args:
    assert pathlib.Path("contrib/mac/app/dmg/Julia-1.14.app").is_dir()
    shutil.copy(stage / "julia-fixture.checkbounds.tar.gz", "julia-build.checkbounds.tar.gz")
''')
        self.run_script("build_julia.sh")
        for location in ("artifacts", "staging"):
            self.assertTrue((self.output / location / "julia-fixture.tar.gz").is_file())
            self.assertTrue((self.output / location / "julia-fixture.checkbounds.tar.gz").is_file())
        self.assertTrue((self.output / "staging/julia-fixture.app.tar.gz").is_file())

    def test_missing_companion_fails_publish(self):
        self.fixtures("linux")
        (self.stage / "julia-fixture.checkbounds.tar.gz").unlink()
        self.run_script("upload_julia.sh", "publish", success=False)
        self.assertEqual(list(self.output.iterdir()), [])

    def test_juliac_extracts_normal_archive_with_companion_available(self):
        for platform, arch in (("linux", "x86_64"), ("linux", "aarch64"),
                               ("macos", "x86_64"), ("macos", "aarch64"),
                               ("windows", "x86_64")):
            with self.subTest(platform=platform, arch=arch):
                with CheckboundsArtifactsTests(methodName="runTest") as case:
                    case.fixtures(platform)
                    basename = f"julia-fixture-{platform}-{arch}"
                    for suffix in ("tar.gz", "checkbounds.tar.gz"):
                        shutil.copy(case.stage / f"julia-fixture.{suffix}",
                                    case.stage / f"{basename}.{suffix}")
                    pipeline = ROOT / f"pipelines/main/misc/juliac/test_juliac_{platform}.yml"
                    # Execute the actual download/extraction block, stopping before Julia runs.
                    lines = []
                    for line in pipeline.read_text().split("commands: |\n", 1)[1].splitlines():
                        lines.append(line)
                        if line.strip().startswith("tar -C ./usr "):
                            break
                    else:
                        self.fail(f"No extraction command in {pipeline}")
                    commands = textwrap.dedent("\n".join(lines)).replace("${ARCH?}", arch)
                    commands = commands.replace("${TRIPLET}", "x86_64-fixture")
                    case.write(case.utils / "extract.sh", "set -eu\n" + commands)
                    case.run_script("extract.sh")
                    self.assertTrue((case.work / "usr/bin/julia").is_file())
                    self.assertFalse((case.work / f"{basename}.checkbounds.tar.gz").exists())

    def test_legacy_publish(self):
        self.fixtures("linux")
        self.env["HAS_CHECKBOUNDS_PKGIMAGES"] = "false"
        (self.stage / "julia-fixture.checkbounds.tar.gz").unlink()
        self.run_script("upload_julia.sh", "publish")
        self.assertFalse(list(self.output.rglob("*.checkbounds.*")))

    def test_test_job_installs_before_macos_signing(self):
        self.fixtures("macos")
        self.run_script("test_julia.sh")
        cache = self.work / "julia-fixture/share/julia/compiled/v1.14/Test"
        self.assertEqual((cache / "checked.ji").read_text(), "fixed checksum")
        self.assertEqual((cache / "auto.ji").read_text(), "fixed checksum")

    def test_release_promotion_includes_companions_and_checksums(self):
        self.write(self.work / "Makefile", "checkbounds-pkgimages:\n")
        platforms = ("linux-x86_64", "linux-i686", "linux-aarch64", "mac64", "macaarch64", "win64", "win32", "freebsd-x86_64")
        for platform in platforms:
            for ext in ("tar.gz", "checkbounds.tar.gz"):
                for signature in ("", ".asc"):
                    self.write(self.stage / f"julia-1.14.0-{platform}.{ext}{signature}", "archive")
            for ext in (("dmg",) if platform.startswith("mac") else ("exe", "zip") if platform.startswith("win") else ()):
                self.write(self.stage / f"julia-1.14.0-{platform}.{ext}", "installer")
        self.run_script("promote_release.sh")
        manifest = (self.output / "julialang2/bin/checksums/julia-1.14.0.sha256").read_text()
        for platform in platforms:
            self.assertIn(f"julia-1.14.0-{platform}.checkbounds.tar.gz", manifest)
        self.assertEqual(len(list(self.output.rglob("*.checkbounds.tar.gz.asc"))), 16)


if __name__ == "__main__":
    unittest.main()
