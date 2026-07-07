#!/usr/bin/env bash
# (Sourced file: deliberately no `set` of shell options here -- they would
# leak into the calling script; strict mode belongs to the entrypoints.)

case "${ARCH}" in
    x86_64)
        EXPECTED_WORD_SIZE="64"
        ;;
    i686)
        EXPECTED_WORD_SIZE="32"
        ;;
    aarch64)
        EXPECTED_WORD_SIZE="64"
        ;;
    armv7l)
        EXPECTED_WORD_SIZE="32"
        ;;
    powerpc64le)
        EXPECTED_WORD_SIZE="64"
        ;;
    # fallback
    *)
        echo "Unknown arch '${ARCH}'" >&2
        exit 1
        ;;
esac
export EXPECTED_WORD_SIZE
