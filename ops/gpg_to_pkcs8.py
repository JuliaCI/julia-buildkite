#!/usr/bin/env python3
# This file is a part of Julia. License is MIT: https://julialang.org/license
"""Convert an (unencrypted) exported GPG RSA secret key to PKCS#8 DER.

Used to import the existing Julia release tarball signing key into AWS KMS
(EXTERNAL origin key), so that new KMS-produced signatures keep verifying
against the long-published GPG public key.

Usage: gpg_to_pkcs8.py tarball_signing.gpg output.pkcs8.der

The input is the binary (or armored) output of `gpg --export-secret-keys`
with no passphrase protection (S2K usage 0), which is what
.buildkite/secrets/tarball_signing.gpg has always been.

Stdlib only. Refuses encrypted keys.
"""

import struct
import sys

sys.path.insert(0, __file__.rsplit("/", 2)[0] + "/utilities")
from kms_gpg_sign import dearmor, iter_packets, read_mpi  # noqa: E402

PKT_SECRET_KEY = 5


def parse_secret_key(body):
    """Extract RSA parameters from a v4 secret key packet body."""
    if body[0] != 4:
        raise ValueError(f"only v4 keys supported (got v{body[0]})")
    algo = body[5]
    if algo not in (1, 3):
        raise ValueError(f"not an RSA key (algorithm {algo})")

    n, off = read_mpi(body, 6)
    e, off = read_mpi(body, off)

    s2k_usage = body[off]
    if s2k_usage != 0:
        raise ValueError(
            f"secret key is passphrase-protected (S2K usage {s2k_usage}); "
            "export it without protection first"
        )
    off += 1

    d, off = read_mpi(body, off)
    p, off = read_mpi(body, off)
    q, off = read_mpi(body, off)
    u, off = read_mpi(body, off)  # OpenPGP stores u = p^-1 mod q (unused here)

    # Sanity checks
    if p * q != n:
        raise ValueError("p * q != n; corrupt key?")
    if pow(pow(2, e, n), d, n) != 2:
        raise ValueError("d does not invert e; corrupt key?")

    return n, e, d, p, q


# --- Minimal DER encoding -----------------------------------------------------

def der_len(n):
    if n < 0x80:
        return bytes([n])
    raw = n.to_bytes((n.bit_length() + 7) // 8, "big")
    return bytes([0x80 | len(raw)]) + raw


def der_int(value):
    raw = value.to_bytes((value.bit_length() + 8) // 8 or 1, "big")
    return b"\x02" + der_len(len(raw)) + raw


def der_seq(*parts):
    body = b"".join(parts)
    return b"\x30" + der_len(len(body)) + body


def der_octet_string(data):
    return b"\x04" + der_len(len(data)) + data


def rsa_private_key_der(n, e, d, p, q):
    """RFC 8017 RSAPrivateKey."""
    dp = d % (p - 1)
    dq = d % (q - 1)
    qinv = pow(q, -1, p)
    return der_seq(
        der_int(0),
        der_int(n), der_int(e), der_int(d),
        der_int(p), der_int(q),
        der_int(dp), der_int(dq), der_int(qinv),
    )


def pkcs8_der(rsa_der):
    # AlgorithmIdentifier: rsaEncryption (1.2.840.113549.1.1.1), NULL params
    alg = der_seq(
        bytes.fromhex("06092a864886f70d010101"),  # OID
        b"\x05\x00",                              # NULL
    )
    return der_seq(der_int(0), alg, der_octet_string(rsa_der))


def main():
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        sys.exit(1)

    data = dearmor(open(sys.argv[1], "rb").read())

    for tag, body in iter_packets(data):
        if tag == PKT_SECRET_KEY:
            n, e, d, p, q = parse_secret_key(body)
            break
    else:
        raise SystemExit("no secret key packet found")

    der = pkcs8_der(rsa_private_key_der(n, e, d, p, q))
    with open(sys.argv[2], "wb") as f:
        f.write(der)
    print(f"wrote PKCS#8 DER ({len(der)} bytes, RSA-{n.bit_length()}) to {sys.argv[2]}")


if __name__ == "__main__":
    main()
