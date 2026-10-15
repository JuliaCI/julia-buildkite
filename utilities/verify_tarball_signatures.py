#!/usr/bin/env python3
# This file is a part of Julia. License is MIT: https://julialang.org/license
"""Check that every FILE has a valid detached signature FILE.asc by the key
in PUBKEY (the signatures kms_gpg_sign.py makes). Needs no gpg.

Usage:
    verify_tarball_signatures.py PUBKEY FILE [FILE...]
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import kms_gpg_sign as K


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    pubkey = K.load_public_key(sys.argv[1])
    bad = [path for path in sys.argv[2:] if not K.verify_file_detached(pubkey, path)]
    for path in bad:
        print(f"ERROR: {path}.asc is not a valid signature of {path}", file=sys.stderr)
    if bad:
        sys.exit(1)
    print(f"{len(sys.argv) - 2} signature(s) valid for key {pubkey.fingerprint.hex().upper()}")


if __name__ == "__main__":
    main()
