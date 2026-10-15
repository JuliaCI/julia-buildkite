#!/usr/bin/env python3
# This file is a part of Julia. License is MIT: https://julialang.org/license
"""A retried publish must publish a signature of the tarball that is
actually published, or refuse to publish.

Runs upload_to_s3.sh against a fake `aws` backed by a local directory, with
attempt B of a commit following a partial attempt A whose bytes differ
(repackaging is not reproducible). B goes through the steps upload_julia.sh
takes: reuse a published tarball, check published signatures, sign, upload
the tarball, then the signature.

* A uploaded its tarball only: B must sign and complete A's tarball.
* A uploaded its signature only: no tarball matches it, so B must fail
  before publishing anything.

Requires: bash, openssl.
"""

import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
UTILITIES = os.path.dirname(HERE)
sys.path.insert(0, UTILITIES)

import kms_gpg_sign as K
from test_kms_gpg_sign import build_test_certificate

# s3api put-object/head-object and s3 cp, with objects stored under $FAKE_S3
# as <bucket>/<key> plus <bucket>/<key>.commit for the build-commit metadata.
FAKE_AWS = r'''#!/usr/bin/env python3
import hashlib, os, shutil, sys
root = os.environ["FAKE_S3"]
args = sys.argv[1:]
def opt(name):
    return args[args.index(name) + 1] if name in args else None
def path(bucket, key):
    return os.path.join(root, bucket, key)
if args[:2] == ["s3api", "put-object"]:
    dest = path(opt("--bucket"), opt("--key"))
    if "--if-none-match" in args and os.path.exists(dest):
        sys.exit("An error occurred (PreconditionFailed) when calling the PutObject operation")
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    shutil.copyfile(opt("--body"), dest)
    meta = opt("--metadata") or ""
    with open(dest + ".commit", "w") as f:
        f.write(meta.split("=", 1)[1] if meta.startswith("build-commit=") else "None")
elif args[:2] == ["s3api", "head-object"]:
    src = path(opt("--bucket"), opt("--key"))
    if not os.path.exists(src):
        sys.exit("An error occurred (404) when calling the HeadObject operation: Not Found")
    etag = hashlib.md5(open(src, "rb").read()).hexdigest()
    print(f'"{etag}"\t{open(src + ".commit").read()}')
elif args[:2] == ["s3", "cp"]:
    bucket, key = args[-2][len("s3://"):].split("/", 1)
    shutil.copyfile(path(bucket, key), args[-1])
else:
    sys.exit(f"fake aws: unsupported {args}")
'''

COMMIT = "0123456789abcdef0123456789abcdef01234567"
BUCKET = "julialangnightlies"
KEY = "bin/linuxopt/x86_64/1.14/julia-1.14.0-linuxopt-x86_64.tar.gz"


def run(tmp, script, **env):
    return subprocess.run(
        ["bash", "-c", f"set -euo pipefail; source '{UTILITIES}/upload_to_s3.sh'; {script}"],
        cwd=tmp,
        env={**os.environ, "PATH": f"{tmp}/bin:{os.environ['PATH']}",
             "FAKE_S3": f"{tmp}/s3", "BUILDKITE_COMMIT": COMMIT, **env},
    ).returncode == 0


def attempt(tmp, payload, signer, pubkey, cert_path, uploads, checked):
    """One publish run; `uploads` are the objects it gets to upload before it
    stops. Returns whether it succeeded."""
    tarball = os.path.join(tmp, "julia-1.14.0-linuxopt-x86_64.tar.gz")
    with open(tarball, "wb") as f:
        f.write(payload)
    if checked:
        if not run(tmp, f"reuse_published_object '{tarball}' {BUCKET} {KEY}"):
            return False
        if not run(tmp, f"check_published_signatures '{tarball}' '{cert_path}' {BUCKET}/{KEY}"):
            return False
    K.sign_file_detached(signer, pubkey, tarball)
    for ext in uploads:
        if not run(tmp, f"upload_to_s3 '{tarball}{ext}' {BUCKET}/{KEY}{ext}"):
            return False
    return True


def published_signature_valid(tmp, pubkey):
    published = os.path.join(tmp, "s3", BUCKET, KEY)
    return K.verify_file_detached(pubkey, published, published + ".asc")


def scenario(key_path, pubkey, cert_path, first_uploads, checked):
    """Attempt A uploads `first_uploads` and stops; attempt B runs to the end.
    Returns (B succeeded, tarball published, published pair verifies)."""
    tmp = tempfile.mkdtemp()
    try:
        os.makedirs(os.path.join(tmp, "bin"))
        with open(os.path.join(tmp, "bin", "aws"), "w") as f:
            f.write(FAKE_AWS)
        os.chmod(os.path.join(tmp, "bin", "aws"), 0o755)
        signer = K.LocalOpensslSigner(key_path)
        attempt(tmp, b"attempt A" * 1000, signer, pubkey, cert_path, first_uploads, checked)
        ok = attempt(tmp, b"attempt B" * 1000, signer, pubkey, cert_path, ["", ".asc"], checked)
        published = os.path.exists(os.path.join(tmp, "s3", BUCKET, KEY))
        return ok, published, published and published_signature_valid(tmp, pubkey)
    finally:
        shutil.rmtree(tmp)


def main():
    tmp = tempfile.mkdtemp()
    key_path = os.path.join(tmp, "key.pem")
    subprocess.run(["openssl", "genrsa", "-out", key_path, "2048"],
                   check=True, capture_output=True)
    pubkey, cert = build_test_certificate(key_path, "Julia Test Signing <test@julialang.org>", 0)
    cert_path = os.path.join(tmp, "cert.asc")
    with open(cert_path, "w") as f:
        f.write(cert)

    # Without the checks, either partial upload leaves a published pair that
    # does not verify: the failures this test guards against.
    for first in ([""], [".asc"]):
        ok, published, valid = scenario(key_path, pubkey, cert_path, first, checked=False)
        assert ok and published and not valid, f"A uploaded {first}: expected a silent mismatch without the checks"
    print("without the checks: both partial uploads publish a mismatched pair (as expected)")

    ok, published, valid = scenario(key_path, pubkey, cert_path, [""], checked=True)
    assert ok and valid, "A uploaded its tarball only: the re-run did not publish a matching signature"
    print("tarball first: the re-run signs the published tarball")

    ok, published, valid = scenario(key_path, pubkey, cert_path, [".asc"], checked=True)
    assert not ok and not published, "A uploaded its signature only: the re-run should refuse to publish"
    print("signature first: the re-run refuses, publishing nothing")
    print("PASS")


if __name__ == "__main__":
    main()
