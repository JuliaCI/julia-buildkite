#!/usr/bin/env python3
# This file is a part of Julia. License is MIT: https://julialang.org/license
"""Create OpenPGP (GPG-compatible) detached signatures with AWS KMS.

This replaces `gpg --detach-sig` for tarball signing. The OpenPGP packet
structure is assembled locally, but the raw RSA signature is produced by
AWS KMS (`kms:Sign` with RSASSA_PKCS1_V1_5_SHA_256). The signing key is
generated inside KMS and never leaves it; the matching OpenPGP public
key (including its self-certification, built with the certificate
helpers below) is exported once with ops/20_export_gpg_pubkey.py and
published as the Julia release signing key.

The public half of the signing key is read from a normal GPG public key
file (armored or binary) and is only used to derive the issuer
fingerprint/key ID embedded in the signature (and to sanity check the
signature against the modulus).

AWS credentials are resolved by the AWS CLI; in CI they come from
Buildkite OIDC web identity federation (see utilities/aws_oidc.sh).

Usage:
    kms_gpg_sign.py --public-key tarball_signing.pub.asc \
        --kms-key-id alias/julia-tarball-signing \
        FILE [FILE...]

Produces FILE.asc for each FILE.

For testing without KMS access, `--local-key key.pem` signs with a local
RSA private key via openssl, exercising the identical packet construction
path (openssl pkeyutl consumes the same SHA-256 digest KMS would).

Only RSA signing keys and SHA-256 are supported.
"""

import argparse
import base64
import datetime
import hashlib
import os
import struct
import subprocess
import sys
import tempfile
import time

# OpenPGP constants (RFC 4880)
PKT_SIGNATURE = 2
PKT_PUBLIC_KEY = 6
PKT_USER_ID = 13
SIG_BINARY = 0x00
SIG_POSITIVE_CERT = 0x13
ALGO_RSA = 1  # also accept 3 (RSA sign-only); 2 (encrypt-only) is rejected
HASH_SHA256 = 8
SUBPKT_CREATION_TIME = 2
SUBPKT_ISSUER_KEY_ID = 16
SUBPKT_KEY_FLAGS = 27
SUBPKT_ISSUER_FINGERPRINT = 33


def dearmor(data):
    """Extract binary packet data from an ASCII-armored block, or pass through binary."""
    if not data.lstrip().startswith(b"-----BEGIN PGP"):
        return data

    lines = data.decode("ascii", "replace").splitlines()
    b64 = []
    in_body = False
    for line in lines:
        line = line.strip()
        if line.startswith("-----BEGIN PGP"):
            in_body = True
            continue
        if line.startswith("-----END PGP"):
            break
        if not in_body:
            continue
        if not line:
            # blank line separates armor headers from body
            b64 = []
            continue
        if line.startswith("="):
            # CRC24 line terminates the body
            break
        if ":" in line and not b64:
            # armor header (Version:, Comment:, ...)
            continue
        b64.append(line)

    return base64.b64decode("".join(b64))


def iter_packets(data):
    """Yield (tag, body) for each OpenPGP packet in data."""
    i = 0
    n = len(data)
    while i < n:
        ctb = data[i]
        if not ctb & 0x80:
            raise ValueError(f"invalid packet header byte {ctb:#x} at offset {i}")
        i += 1
        if ctb & 0x40:
            # New format
            tag = ctb & 0x3F
            first = data[i]
            i += 1
            if first < 192:
                length = first
            elif first < 224:
                length = ((first - 192) << 8) + data[i] + 192
                i += 1
            elif first == 255:
                length = struct.unpack(">I", data[i : i + 4])[0]
                i += 4
            else:
                raise ValueError("partial body lengths not supported")
        else:
            # Old format
            tag = (ctb >> 2) & 0x0F
            ltype = ctb & 0x03
            if ltype == 0:
                length = data[i]
                i += 1
            elif ltype == 1:
                length = struct.unpack(">H", data[i : i + 2])[0]
                i += 2
            elif ltype == 2:
                length = struct.unpack(">I", data[i : i + 4])[0]
                i += 4
            else:
                raise ValueError("indeterminate length packets not supported")
        yield tag, data[i : i + length]
        i += length


def read_mpi(body, offset):
    """Read an OpenPGP MPI; returns (int, new_offset)."""
    bits = struct.unpack(">H", body[offset : offset + 2])[0]
    nbytes = (bits + 7) // 8
    value = int.from_bytes(body[offset + 2 : offset + 2 + nbytes], "big")
    return value, offset + 2 + nbytes


def encode_mpi(value):
    """Encode an integer as an OpenPGP MPI."""
    bits = value.bit_length()
    return struct.pack(">H", bits) + value.to_bytes((bits + 7) // 8, "big")


class PublicKeyInfo:
    def __init__(self, body):
        if body[0] != 4:
            raise ValueError(f"only v4 keys supported (got v{body[0]})")
        algo = body[5]
        if algo not in (1, 3):
            raise ValueError(f"only RSA signing keys supported (algorithm {algo})")
        self.algorithm = algo
        self.n, off = read_mpi(body, 6)
        self.e, _ = read_mpi(body, off)
        self.fingerprint = hashlib.sha1(
            b"\x99" + struct.pack(">H", len(body)) + body
        ).digest()
        self.key_id = self.fingerprint[-8:]


def load_public_key(path):
    data = dearmor(open(path, "rb").read())
    for tag, body in iter_packets(data):
        if tag == PKT_PUBLIC_KEY:
            return PublicKeyInfo(body)
    raise ValueError(f"no public key packet found in {path}")


def encode_subpacket(sptype, body):
    data = bytes([sptype]) + body
    if len(data) < 192:
        return bytes([len(data)]) + data
    if len(data) < 8384:
        v = len(data) - 192
        return bytes([192 + (v >> 8), v & 0xFF]) + data
    return b"\xff" + struct.pack(">I", len(data)) + data


def encode_packet(tag, body):
    """Encode a packet with a new-format header."""
    if len(body) < 192:
        length = bytes([len(body)])
    elif len(body) < 8384:
        v = len(body) - 192
        length = bytes([192 + (v >> 8), v & 0xFF])
    else:
        length = b"\xff" + struct.pack(">I", len(body))
    return bytes([0xC0 | tag]) + length + body


def crc24(data):
    crc = 0xB704CE
    for byte in data:
        crc ^= byte << 16
        for _ in range(8):
            crc <<= 1
            if crc & 0x1000000:
                crc ^= 0x1864CFB
    return crc & 0xFFFFFF


def armor(packet_data, block_type="SIGNATURE"):
    b64 = base64.b64encode(packet_data).decode("ascii")
    lines = [b64[i : i + 64] for i in range(0, len(b64), 64)]
    crc = base64.b64encode(crc24(packet_data).to_bytes(3, "big")).decode("ascii")
    return (
        f"-----BEGIN PGP {block_type}-----\n\n"
        + "\n".join(lines)
        + f"\n={crc}\n-----END PGP {block_type}-----\n"
    )


class KmsSigner:
    """Sign SHA-256 digests with RSASSA_PKCS1_V1_5_SHA_256 via the AWS CLI."""

    def __init__(self, key_id):
        self.key_id = key_id

    def sign_digest(self, digest):
        with tempfile.NamedTemporaryFile(suffix=".bin", delete=False) as f:
            f.write(digest)
            digest_path = f.name
        try:
            out = subprocess.run(
                [
                    "aws", "kms", "sign",
                    "--key-id", self.key_id,
                    "--message", f"fileb://{digest_path}",
                    "--message-type", "DIGEST",
                    "--signing-algorithm", "RSASSA_PKCS1_V1_5_SHA_256",
                    "--output", "text",
                    "--query", "Signature",
                ],
                check=True,
                capture_output=True,
            )
        finally:
            os.unlink(digest_path)
        return base64.b64decode(out.stdout.strip())


class LocalOpensslSigner:
    """Sign SHA-256 digests with a local RSA key via openssl (for testing).

    Uses `openssl pkeyutl` in digest mode, which performs the same
    EMSA-PKCS1-v1_5 encoding of a caller-provided digest that KMS does.
    """

    def __init__(self, key_path):
        self.key_path = key_path

    def sign_digest(self, digest):
        out = subprocess.run(
            [
                "openssl", "pkeyutl", "-sign",
                "-inkey", self.key_path,
                "-pkeyopt", "digest:sha256",
                "-pkeyopt", "rsa_padding_mode:pkcs1",
            ],
            input=digest,
            check=True,
            capture_output=True,
        )
        return out.stdout


def build_signature_packet(signer, pubkey, data_hasher, sig_type=SIG_BINARY,
                           timestamp=None, extra_hashed_subpkts=b""):
    """Build a v4 signature packet.

    data_hasher is a hashlib object already updated with the data to be
    signed (document for binary sigs; key/uid data for certifications).
    """
    if timestamp is None:
        timestamp = int(time.time())

    hashed_subpkts = b"".join([
        encode_subpacket(SUBPKT_ISSUER_FINGERPRINT, b"\x04" + pubkey.fingerprint),
        encode_subpacket(SUBPKT_CREATION_TIME, struct.pack(">I", timestamp)),
    ]) + extra_hashed_subpkts
    unhashed_subpkts = encode_subpacket(SUBPKT_ISSUER_KEY_ID, pubkey.key_id)

    hashed_portion = (
        bytes([4, sig_type, ALGO_RSA, HASH_SHA256])
        + struct.pack(">H", len(hashed_subpkts))
        + hashed_subpkts
    )
    trailer = b"\x04\xff" + struct.pack(">I", len(hashed_portion))

    data_hasher.update(hashed_portion + trailer)
    digest = data_hasher.digest()

    raw_signature = signer.sign_digest(digest)

    # Sanity check the raw signature against the public key before publishing:
    # s^e mod n must be a valid EMSA-PKCS1-v1_5 encoding ending in our digest.
    decoded = pow(int.from_bytes(raw_signature, "big"), pubkey.e, pubkey.n)
    decoded_bytes = decoded.to_bytes((pubkey.n.bit_length() + 7) // 8, "big")
    if not decoded_bytes.endswith(digest):
        raise RuntimeError(
            "signature does not verify against the supplied public key; "
            "are --public-key and the KMS key the same key pair?"
        )

    body = (
        hashed_portion
        + struct.pack(">H", len(unhashed_subpkts))
        + unhashed_subpkts
        + digest[:2]
        + encode_mpi(int.from_bytes(raw_signature, "big"))
    )
    return encode_packet(PKT_SIGNATURE, body)


def build_rsa_key_body(n, e, timestamp):
    """Build a v4 public key packet body for an RSA key.

    The fingerprint (and thus key ID) covers the creation timestamp, so
    the same (n, e, timestamp) always yields the same key identity.
    """
    return (
        bytes([4])
        + struct.pack(">I", timestamp)
        + bytes([ALGO_RSA])
        + encode_mpi(n)
        + encode_mpi(e)
    )


# ---- Deriving the public-key identity from the KMS key's public half --------
# These let the signer reconstruct the OpenPGP public key (and thus the issuer
# fingerprint embedded in signatures) at runtime from `kms:GetPublicKey`,
# instead of reading a committed .asc -- useful for throwaway/test keys where
# publishing a public key block is pointless. ops/20_export_gpg_pubkey.py reuses
# these to build the full published certificate for the production key.

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
    """Fetch a KMS key's SubjectPublicKeyInfo DER via kms:GetPublicKey."""
    out = subprocess.run(
        ["aws", "kms", "get-public-key", "--key-id", key_id,
         "--output", "text", "--query", "PublicKey"],
        check=True, capture_output=True,
    )
    return base64.b64decode(out.stdout.strip())


def local_public_key(key_path):
    """SubjectPublicKeyInfo DER for a local RSA private key (testing only)."""
    out = subprocess.run(
        ["openssl", "rsa", "-in", key_path, "-pubout", "-outform", "DER"],
        check=True, capture_output=True,
    )
    return out.stdout


def kms_key_creation_date(key_id):
    """The KMS key's creation time as a unix timestamp (kms:DescribeKey)."""
    out = subprocess.run(
        ["aws", "kms", "describe-key", "--key-id", key_id,
         "--query", "KeyMetadata.CreationDate", "--output", "text"],
        check=True, capture_output=True,
    ).stdout.decode().strip()
    # AWS CLI prints this either as epoch seconds (possibly fractional) or as an
    # ISO-8601 string, depending on cli_timestamp_format; accept both.
    try:
        return int(float(out))
    except ValueError:
        return int(datetime.datetime.fromisoformat(out.replace("Z", "+00:00")).timestamp())


def parse_created(value):
    """A unix timestamp, or a YYYY-MM-DD date interpreted as UTC midnight."""
    try:
        return int(value)
    except ValueError:
        dt = datetime.datetime.strptime(value, "%Y-%m-%d")
        return int(dt.replace(tzinfo=datetime.timezone.utc).timestamp())


def public_key_info_from_kms(key_id, timestamp, local_key=None):
    """Reconstruct the PublicKeyInfo (fingerprint, n, e) from the KMS key's
    public half plus a pinned creation timestamp -- no committed file."""
    spki = local_public_key(local_key) if local_key else kms_public_key(key_id)
    n, e = rsa_components_from_spki(spki)
    return PublicKeyInfo(build_rsa_key_body(n, e, timestamp))


def build_certificate(signer, key_body, uid, timestamp):
    """Build a minimal transferable public key (certificate): public key
    packet + user ID packet + positive self-certification (RFC 4880
    section 5.2.4), signed via signer. Returns (PublicKeyInfo, binary
    certificate); wrap with armor(..., "PUBLIC KEY BLOCK") to publish.
    """
    pubkey = PublicKeyInfo(key_body)
    uid_body = uid.encode()

    hasher = hashlib.sha256()
    hasher.update(b"\x99" + struct.pack(">H", len(key_body)) + key_body)
    hasher.update(b"\xb4" + struct.pack(">I", len(uid_body)) + uid_body)

    # Key flags: certify + sign
    key_flags = encode_subpacket(SUBPKT_KEY_FLAGS, b"\x03")
    cert_sig = build_signature_packet(
        signer, pubkey, hasher, sig_type=SIG_POSITIVE_CERT,
        timestamp=timestamp, extra_hashed_subpkts=key_flags,
    )

    cert = (
        encode_packet(PKT_PUBLIC_KEY, key_body)
        + encode_packet(PKT_USER_ID, uid_body)
        + cert_sig
    )
    return pubkey, cert


def sign_file_detached(signer, pubkey, path, output_path=None):
    hasher = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            hasher.update(chunk)

    packet = build_signature_packet(signer, pubkey, hasher)

    if output_path is None:
        output_path = path + ".asc"
    with open(output_path, "w") as f:
        f.write(armor(packet))
    return output_path


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    pubgroup = parser.add_mutually_exclusive_group(required=True)
    pubgroup.add_argument("--public-key",
                          help="GPG public key file (armored or binary) of the signing key")
    pubgroup.add_argument("--public-key-from-kms", action="store_true",
                          help="derive the signer's OpenPGP public key identity from the "
                               "KMS key's public half (kms:GetPublicKey) at runtime instead "
                               "of a committed file; requires --created. Useful for throwaway "
                               "keys where publishing a public key block is pointless.")
    parser.add_argument("--created",
                        help="override the key creation time (unix timestamp or YYYY-MM-DD "
                             "UTC) for --public-key-from-kms. Part of the fingerprint; "
                             "defaults to the KMS key's own CreationDate. Pin it only to "
                             "match a separately-published pubkey.")
    parser.add_argument("--uid", default=None,
                        help="(unused for signing; accepted for symmetry with the exporter)")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--kms-key-id",
                       help="AWS KMS key ID/ARN/alias holding the signing key")
    group.add_argument("--local-key",
                       help="local RSA private key PEM (testing only)")
    parser.add_argument("files", nargs="+", help="files to sign (creates FILE.asc)")
    args = parser.parse_args()

    if args.public_key_from_kms:
        # The OpenPGP fingerprint covers the key creation timestamp. Default it
        # to the KMS key's own CreationDate (so the identity reflects the real
        # key); an explicit --created overrides. A local test key has no KMS
        # creation date, so fall back to 0 there.
        if args.created:
            created = parse_created(args.created)
        elif args.local_key:
            created = 0
        else:
            created = kms_key_creation_date(args.kms_key_id)
        pubkey = public_key_info_from_kms(
            args.kms_key_id, created, local_key=args.local_key)
    else:
        pubkey = load_public_key(args.public_key)
    print(f"Signing as key {pubkey.fingerprint.hex().upper()}")

    if args.kms_key_id:
        signer = KmsSigner(args.kms_key_id)
    else:
        signer = LocalOpensslSigner(args.local_key)

    for path in args.files:
        output = sign_file_detached(signer, pubkey, path)
        print(f"  {path} -> {output}")


if __name__ == "__main__":
    main()
