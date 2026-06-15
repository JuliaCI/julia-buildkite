#!/usr/bin/env python3
# This file is a part of Julia. License is MIT: https://julialang.org/license
"""Export the KMS-held release tarball signing key as an OpenPGP public key.

The signing key is generated inside KMS (alias/julia-tarball-signing,
created by ops/terraform) and never leaves it. This script fetches the
RSA public half via `aws kms get-public-key`, wraps it in an OpenPGP v4
public key packet + user ID, and obtains the positive self-certification
with a `kms:Sign` call -- producing an armored public key block that GPG
and friends accept. Commit the output (signing-pubkeys/tarball_signing.pub.asc)
and publish it as the Julia releases signing key; release signatures
made by utilities/kms_gpg_sign.py verify against it.

The OpenPGP fingerprint covers the key creation timestamp. It defaults to
the KMS key's own CreationDate (kms:DescribeKey) -- an immutable, already-
pinned value that also matches what kms_gpg_sign.py's --public-key-from-kms
signing path derives -- so re-running reproduces the identical key block.
--created overrides it only to reproduce a key minted under a different
timestamp; a changed timestamp would mint a "new" identity for the same key.

Usage:
    20_export_gpg_pubkey.py [--created YYYY-MM-DD] [--kms-key-id ALIAS] [-o FILE]

For testing without KMS access, `--local-key key.pem` uses a local RSA
private key via openssl, exercising the identical construction path.

Requires AWS credentials with kms:GetPublicKey + kms:Sign on the key.
"""

import argparse
import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(SCRIPT_DIR, "..", "utilities"))

import kms_gpg_sign as K  # noqa: E402

# The DER/SPKI parsing, kms:GetPublicKey fetch, and --created parsing live in
# kms_gpg_sign.py (shared with its --public-key-from-kms signing mode).

DEFAULT_KMS_KEY = "alias/julia-tarball-signing"
DEFAULT_UID = "Julia Release Signing Key <buildbot@julialang.org>"
DEFAULT_OUTPUT = os.path.join(SCRIPT_DIR, "..", "signing-pubkeys", "tarball_signing.pub.asc")


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--created",
                        help="override the key creation time (unix timestamp or "
                             "YYYY-MM-DD UTC midnight); part of the key fingerprint. "
                             "Defaults to the KMS key's own CreationDate")
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

    if args.created:
        timestamp = K.parse_created(args.created)
    elif args.local_key:
        # A local test key has no KMS CreationDate; pin a fixed epoch so the
        # construction path stays deterministic.
        timestamp = 0
    else:
        # Pin the fingerprint to the KMS key's immutable provisioning date,
        # matching kms_gpg_sign.py's --public-key-from-kms signing path.
        timestamp = K.kms_key_creation_date(args.kms_key_id)

    if args.local_key:
        spki = K.local_public_key(args.local_key)
        signer = K.LocalOpensslSigner(args.local_key)
    else:
        spki = K.kms_public_key(args.kms_key_id)
        signer = K.KmsSigner(args.kms_key_id)

    n, e = K.rsa_components_from_spki(spki)
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
