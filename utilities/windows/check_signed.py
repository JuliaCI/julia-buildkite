#!/usr/bin/env python3
# This file is a part of Julia. License is MIT: https://julialang.org/license
"""Check that PE files carry an Authenticode signature (stdlib only).

Reads the PE optional header's Certificate Table data directory entry; a
zero size means the file is unsigned. This deliberately does not validate
the signature chain -- it is a tripwire for the Wine->host signing bridge
silently failing during the Inno Setup build (in which case the installer
would come out unsigned but the build would otherwise succeed).

Usage: check_signed.py FILE [FILE...]   (exits non-zero if any is unsigned)
"""

import struct
import sys


def certificate_table_size(path):
    with open(path, "rb") as f:
        mz = f.read(64)
        if mz[:2] != b"MZ":
            raise ValueError(f"{path}: not a PE file (no MZ header)")
        (pe_offset,) = struct.unpack_from("<I", mz, 0x3C)
        f.seek(pe_offset)
        if f.read(4) != b"PE\0\0":
            raise ValueError(f"{path}: not a PE file (no PE signature)")
        f.seek(pe_offset + 24)  # skip COFF header
        (magic,) = struct.unpack("<H", f.read(2))
        if magic == 0x10B:      # PE32
            dir_offset = pe_offset + 24 + 96
        elif magic == 0x20B:    # PE32+
            dir_offset = pe_offset + 24 + 112
        else:
            raise ValueError(f"{path}: unknown optional header magic {magic:#x}")
        # Certificate Table is data directory entry 4 (8 bytes each)
        f.seek(dir_offset + 4 * 8)
        _va, size = struct.unpack("<II", f.read(8))
        return size


def main():
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    unsigned = []
    for path in sys.argv[1:]:
        size = certificate_table_size(path)
        if size == 0:
            print(f"UNSIGNED: {path}")
            unsigned.append(path)
        else:
            print(f"signed ({size} bytes of certificate data): {path}")
    if unsigned:
        print(f"ERROR: {len(unsigned)} file(s) lack an Authenticode signature",
              file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
