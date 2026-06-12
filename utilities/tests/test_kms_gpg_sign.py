#!/usr/bin/env python3
# This file is a part of Julia. License is MIT: https://julialang.org/license
"""Interop test for kms_gpg_sign.py against an independent OpenPGP
implementation (rsop, https://crates.io/crates/rsop, backed by rPGP).

Generates a fresh RSA key with openssl, constructs a minimal OpenPGP
certificate (public key + uid + self-certification) and a detached
signature using the packet construction code under test, then verifies
the result with rsop.

The local openssl signer exercises the exact code path used in
production with AWS KMS: both consume a SHA-256 digest and produce a
raw RSASSA-PKCS1-v1_5 signature.

Requires: openssl, rsop on PATH.
"""

import hashlib
import os
import struct
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
    """Build a minimal transferable public key (certificate) for the key."""
    n, e = openssl_rsa_components(key_path)

    key_body = (
        bytes([4])
        + struct.pack(">I", timestamp)
        + bytes([K.ALGO_RSA])
        + K.encode_mpi(n)
        + K.encode_mpi(e)
    )
    pubkey = K.PublicKeyInfo(key_body)

    uid_body = uid.encode()

    # Self-certification (positive certification, sig type 0x13) over
    # key + uid, per RFC 4880 section 5.2.4.
    hasher = hashlib.sha256()
    hasher.update(b"\x99" + struct.pack(">H", len(key_body)) + key_body)
    hasher.update(b"\xb4" + struct.pack(">I", len(uid_body)) + uid_body)

    signer = K.LocalOpensslSigner(key_path)
    # Key flags: certify + sign
    key_flags = K.encode_subpacket(27, b"\x03")
    cert_sig = K.build_signature_packet(
        signer, pubkey, hasher, sig_type=0x13, timestamp=timestamp,
        extra_hashed_subpkts=key_flags,
    )

    cert = (
        K.encode_packet(K.PKT_PUBLIC_KEY, key_body)
        + K.encode_packet(13, uid_body)
        + cert_sig
    )
    return pubkey, K.armor(cert, "PUBLIC KEY BLOCK")


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

    # Independent verification with rsop (rPGP)
    with open(data_path, "rb") as f:
        result = subprocess.run(
            ["rsop", "verify", sig_path, cert_path],
            stdin=f, capture_output=True, text=True,
        )
    if result.returncode != 0:
        print("rsop verify FAILED")
        print(result.stdout)
        print(result.stderr)
        sys.exit(1)

    print("rsop verify OK:", result.stdout.strip())

    # Negative test: corrupted data must not verify
    bad_path = os.path.join(tmp, "bad.tar.gz")
    with open(data_path, "rb") as f:
        bad = bytearray(f.read())
    bad[0] ^= 0xFF
    with open(bad_path, "wb") as f:
        f.write(bad)
    with open(bad_path, "rb") as f:
        result = subprocess.run(
            ["rsop", "verify", sig_path, cert_path],
            stdin=f, capture_output=True, text=True,
        )
    assert result.returncode != 0, "corrupted data verified?!"
    print("negative test OK (corrupted data rejected)")

    print("PASS")


if __name__ == "__main__":
    main()
