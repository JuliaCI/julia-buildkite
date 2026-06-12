#!/usr/bin/env python3
# This file is a part of Julia. License is MIT: https://julialang.org/license
"""Round-trip test for ops/gpg_to_pkcs8.py.

Generates an RSA key with openssl, wraps it into an OpenPGP v4 secret key
packet (the format `gpg --export-secret-keys` produces for unprotected
keys), converts it back to PKCS#8 with the code under test, and checks
that openssl parses the result and that key parameters survived intact.
"""

import os
import struct
import subprocess
import sys
import tempfile
import time

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(TESTS_DIR, "..", "..", "ops"))
sys.path.insert(0, os.path.join(TESTS_DIR, ".."))

import kms_gpg_sign as K  # noqa: E402


def openssl_key_params(key_path):
    """Extract n, e, d, p, q from an openssl RSA private key."""
    text = subprocess.run(
        ["openssl", "rsa", "-in", key_path, "-noout", "-text"],
        check=True, capture_output=True, text=True,
    ).stdout

    params = {}
    current = None
    hexbuf = []
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith(("modulus:", "privateExponent:", "prime1:", "prime2:")):
            if current:
                params[current] = int("".join(hexbuf).replace(":", ""), 16)
            current = stripped.rstrip(":").split(":")[0]
            hexbuf = []
        elif stripped.startswith("publicExponent:"):
            if current:
                params[current] = int("".join(hexbuf).replace(":", ""), 16)
                current = None
            params["publicExponent"] = int(stripped.split()[1])
        elif current and all(c in "0123456789abcdef:" for c in stripped) and stripped:
            hexbuf.append(stripped)
        elif current and stripped and not all(c in "0123456789abcdef:" for c in stripped):
            params[current] = int("".join(hexbuf).replace(":", ""), 16)
            current = None
    if current and hexbuf:
        params[current] = int("".join(hexbuf).replace(":", ""), 16)

    return (params["modulus"], params["publicExponent"],
            params["privateExponent"], params["prime1"], params["prime2"])


def build_gpg_secret_key(n, e, d, p, q, timestamp):
    """Build an OpenPGP v4 unprotected RSA secret key packet (tag 5)."""
    u = pow(p, -1, q)  # OpenPGP's u = p^-1 mod q

    secret_mpis = b"".join(K.encode_mpi(x) for x in (d, p, q, u))
    checksum = sum(secret_mpis) % 65536

    body = (
        bytes([4])
        + struct.pack(">I", timestamp)
        + bytes([1])  # RSA
        + K.encode_mpi(n)
        + K.encode_mpi(e)
        + bytes([0])  # S2K usage 0: unprotected
        + secret_mpis
        + struct.pack(">H", checksum)
    )
    return K.encode_packet(5, body)


def main():
    tmp = tempfile.mkdtemp()
    key_path = os.path.join(tmp, "key.pem")
    subprocess.run(["openssl", "genrsa", "-out", key_path, "2048"],
                   check=True, capture_output=True)

    n, e, d, p, q = openssl_key_params(key_path)

    gpg_path = os.path.join(tmp, "secret.gpg")
    with open(gpg_path, "wb") as f:
        f.write(build_gpg_secret_key(n, e, d, p, q, int(time.time())))

    out_path = os.path.join(tmp, "out.pkcs8.der")
    subprocess.run(
        [sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                      "..", "..", "ops", "gpg_to_pkcs8.py"),
         gpg_path, out_path],
        check=True,
    )

    # openssl must parse the result and agree on the modulus
    out_mod = subprocess.run(
        ["openssl", "rsa", "-in", out_path, "-inform", "DER", "-noout", "-modulus"],
        check=True, capture_output=True, text=True,
    ).stdout
    assert int(out_mod.strip().split("=")[1], 16) == n, "modulus mismatch"

    check = subprocess.run(
        ["openssl", "rsa", "-in", out_path, "-inform", "DER", "-check", "-noout"],
        capture_output=True, text=True,
    )
    assert check.returncode == 0 and "RSA key ok" in check.stdout, check.stdout + check.stderr

    print("PASS")


if __name__ == "__main__":
    main()
