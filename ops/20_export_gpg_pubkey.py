#!/usr/bin/env python3
# This file is a part of Julia. License is MIT: https://julialang.org/license
"""Export the KMS-held release tarball signing key as an OpenPGP public key.

The signing key is generated inside KMS (alias/julia-tarball-signing,
created by ops/terraform) and never leaves it. This script fetches the
RSA public half via `aws kms get-public-key`, wraps it in an OpenPGP v4
public key packet + user ID, and obtains the positive self-certification
with a `kms:Sign` call -- producing an armored public key block that GPG
and friends accept. Commit the output (secrets/tarball_signing.pub.asc)
and publish it as the Julia releases signing key; release signatures
made by utilities/kms_gpg_sign.py verify against it.

The OpenPGP fingerprint covers the key creation timestamp, so --created
must be pinned (pick the date the key was provisioned) and never changed
afterwards: re-running with the same --created/--uid reproduces the
identical key block, while a different timestamp would mint a "new"
identity for the same RSA key.

Usage:
    20_export_gpg_pubkey.py --created 2026-06-12 [--kms-key-id ALIAS] [-o FILE]

For testing without KMS access, `--local-key key.pem` uses a local RSA
private key via openssl, exercising the identical construction path.

Requires AWS credentials with kms:GetPublicKey + kms:Sign on the key.
"""

import argparse
import base64
import datetime
import os
import subprocess
import sys
import tempfile

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(SCRIPT_DIR, "..", "utilities"))

import kms_gpg_sign as K  # noqa: E402

DEFAULT_KMS_KEY = "alias/julia-tarball-signing"
DEFAULT_UID = "Julia Release Signing Key <buildbot@julialang.org>"
DEFAULT_OUTPUT = os.path.join(SCRIPT_DIR, "..", "secrets", "tarball_signing.pub.asc")


def parse_der(data, offset=0):
    """Parse one DER TLV; returns (tag, value, next_offset)."""
    tag = data[offset]
    length = data[offset + 1]
    offset += 2
    if length & 0x80:
        nbytes = length & 0x7F
        length = int.from_bytes(data[offset : offset + nbytes], "big")
        offset += nbytes
    return tag, data[offset : offset + length], offset + length


def rsa_components_from_spki(der):
    """Extract (n, e) from a SubjectPublicKeyInfo DER blob."""
    _, spki, _ = parse_der(der)                  # SEQUENCE SubjectPublicKeyInfo
    _, _, off = parse_der(spki)                  # SEQUENCE AlgorithmIdentifier
    tag, bits, _ = parse_der(spki, off)          # BIT STRING subjectPublicKey
    if tag != 0x03 or bits[0] != 0:
        raise ValueError("unexpected SPKI structure (not an RSA key?)")
    _, rsa, _ = parse_der(bits[1:])              # SEQUENCE RSAPublicKey
    tag_n, n_bytes, off = parse_der(rsa)         # INTEGER n
    tag_e, e_bytes, _ = parse_der(rsa, off)      # INTEGER e
    if tag_n != 0x02 or tag_e != 0x02:
        raise ValueError("unexpected RSAPublicKey structure")
    return int.from_bytes(n_bytes, "big"), int.from_bytes(e_bytes, "big")


def kms_public_key(key_id):
    out = subprocess.run(
        [
            "aws", "kms", "get-public-key",
            "--key-id", key_id,
            "--output", "text",
            "--query", "PublicKey",
        ],
        check=True,
        capture_output=True,
    )
    return base64.b64decode(out.stdout.strip())


def local_public_key(key_path):
    out = subprocess.run(
        ["openssl", "rsa", "-in", key_path, "-pubout", "-outform", "DER"],
        check=True,
        capture_output=True,
    )
    return out.stdout


def parse_created(value):
    try:
        return int(value)
    except ValueError:
        dt = datetime.datetime.strptime(value, "%Y-%m-%d")
        return int(dt.replace(tzinfo=datetime.timezone.utc).timestamp())


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--created", required=True,
                        help="key creation time (unix timestamp or YYYY-MM-DD, "
                             "interpreted as UTC midnight); part of the key "
                             "fingerprint -- pin it and never change it")
    parser.add_argument("--uid", default=DEFAULT_UID,
                        help=f"user ID for the key (default: {DEFAULT_UID!r})")
    parser.add_argument("-o", "--output", default=DEFAULT_OUTPUT,
                        help="output path for the armored public key block")
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--kms-key-id", default=DEFAULT_KMS_KEY,
                       help=f"AWS KMS key ID/ARN/alias (default: {DEFAULT_KMS_KEY})")
    group.add_argument("--local-key",
                       help="local RSA private key PEM (testing only)")
    args = parser.parse_args()

    timestamp = parse_created(args.created)

    if args.local_key:
        spki = local_public_key(args.local_key)
        signer = K.LocalOpensslSigner(args.local_key)
    else:
        spki = kms_public_key(args.kms_key_id)
        signer = K.KmsSigner(args.kms_key_id)

    n, e = rsa_components_from_spki(spki)
    key_body = K.build_rsa_key_body(n, e, timestamp)
    pubkey, cert = K.build_certificate(signer, key_body, args.uid, timestamp)
    armored = K.armor(cert, "PUBLIC KEY BLOCK")

    with open(args.output, "w") as f:
        f.write(armored)

    # Round-trip self-check: what we wrote parses back to the same key.
    assert K.load_public_key(args.output).fingerprint == pubkey.fingerprint

    print(f"Fingerprint: {pubkey.fingerprint.hex().upper()}")
    print(f"User ID:     {args.uid}")
    print(f"Created:     {timestamp}")
    print(f"Written to:  {args.output}")
    print()
    print("Commit this file, and publish it as the Julia releases signing key")
    print("(it replaces the pre-migration juliareleases.asc).")


if __name__ == "__main__":
    main()
