#!/usr/bin/env python3
# This file is a part of Julia. License is MIT: https://julialang.org/license
"""Interop test for kms_gpg_sign.py against an independent OpenPGP
implementation (gpg, or rsop as fallback).

Generates a fresh RSA key with openssl, constructs a minimal OpenPGP
certificate (public key + uid + self-certification) and a detached
signature using the packet construction code under test, then verifies
the result with gpg (which also validates the self-certification on
import) or rsop (https://crates.io/crates/rsop, backed by rPGP).

The local openssl signer exercises the exact code path used in
production with AWS KMS: both consume a SHA-256 digest and produce a
raw RSASSA-PKCS1-v1_5 signature.

Requires: openssl, and gpg or rsop on PATH.
"""

import os
import shutil
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import kms_gpg_sign as K


def openssl_rsa_components(key_path):
    """Extract (n, e) from an RSA private key PEM via openssl."""
    out = subprocess.run(
        ["openssl", "rsa", "-in", key_path, "-noout", "-modulus"],
        check=True, capture_output=True, text=True,
    ).stdout
    n = int(out.strip().split("=", 1)[1], 16)

    text = subprocess.run(
        ["openssl", "rsa", "-in", key_path, "-noout", "-text"],
        check=True, capture_output=True, text=True,
    ).stdout
    for line in text.splitlines():
        if line.startswith("publicExponent:"):
            e = int(line.split()[1])
            break
    else:
        raise RuntimeError("publicExponent not found")
    return n, e


def build_test_certificate(key_path, uid, timestamp):
    """Build a certificate for the key via the production helper
    (the same code path ops/20_export_gpg_pubkey.py uses)."""
    n, e = openssl_rsa_components(key_path)
    key_body = K.build_rsa_key_body(n, e, timestamp)
    pubkey, cert = K.build_certificate(
        K.LocalOpensslSigner(key_path), key_body, uid, timestamp
    )
    return pubkey, K.armor(cert, "PUBLIC KEY BLOCK")


def make_verifier(tmp, cert_path):
    """Return verify(sig_path, data_path) -> bool using gpg or rsop."""
    if shutil.which("gpg"):
        homedir = os.path.join(tmp, "gnupg")
        os.makedirs(homedir, mode=0o700)
        base = ["gpg", "--homedir", homedir, "--batch"]
        # Import validates the self-certification; a bad one is fatal here.
        subprocess.run(base + ["--import", cert_path],
                       check=True, capture_output=True)
        out = subprocess.run(base + ["--check-sigs"],
                             check=True, capture_output=True, text=True)
        assert "sig!" in out.stdout, f"self-certification not valid:\n{out.stdout}"

        def verify(sig_path, data_path):
            return subprocess.run(
                base + ["--verify", sig_path, data_path],
                capture_output=True,
            ).returncode == 0
        return "gpg", verify

    if shutil.which("rsop"):
        def verify(sig_path, data_path):
            with open(data_path, "rb") as f:
                return subprocess.run(
                    ["rsop", "verify", sig_path, cert_path],
                    stdin=f, capture_output=True,
                ).returncode == 0
        return "rsop", verify

    print("SKIP: neither gpg nor rsop on PATH")
    sys.exit(0)


def main():
    tmp = tempfile.mkdtemp()
    key_path = os.path.join(tmp, "key.pem")
    subprocess.run(
        ["openssl", "genrsa", "-out", key_path, "2048"],
        check=True, capture_output=True,
    )

    timestamp = int(time.time())
    pubkey, cert_armored = build_test_certificate(
        key_path, "Julia Test Signing <test@julialang.org>", timestamp
    )
    cert_path = os.path.join(tmp, "cert.asc")
    with open(cert_path, "w") as f:
        f.write(cert_armored)

    # Check the armored public key round-trips through the loader
    loaded = K.load_public_key(cert_path)
    assert loaded.fingerprint == pubkey.fingerprint, "fingerprint mismatch"

    data_path = os.path.join(tmp, "data.tar.gz")
    with open(data_path, "wb") as f:
        f.write(os.urandom(1 << 16))

    sig_path = K.sign_file_detached(
        K.LocalOpensslSigner(key_path), pubkey, data_path
    )

    # Independent verification
    name, verify = make_verifier(tmp, cert_path)
    if not verify(sig_path, data_path):
        print(f"{name} verify FAILED")
        sys.exit(1)
    print(f"{name} verify OK")

    # Negative test: corrupted data must not verify
    bad_path = os.path.join(tmp, "bad.tar.gz")
    with open(data_path, "rb") as f:
        bad = bytearray(f.read())
    bad[0] ^= 0xFF
    with open(bad_path, "wb") as f:
        f.write(bad)
    assert not verify(sig_path, bad_path), "corrupted data verified?!"
    print("negative test OK (corrupted data rejected)")

    print("PASS")


if __name__ == "__main__":
    main()
