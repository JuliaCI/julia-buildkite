#!/bin/bash

# Extract information from our triplet
# Here is an example of a triplet: `x86_64-linux-gnu`
export ARCH="$(cut -d- -f1 <<<"${TRIPLET}")"
case "${TRIPLET}" in
    # Linux
    *-gnu)
        OS="linux"
        ;;
    *-gnueabihf) # embedded ABI, hard-float
        OS="linux"
        ;;
    *-gnusrc) # "from source" builds (`USE_BINARYBUILDER=0`)
        OS="linuxsrc"
        ;;
    *-gnuassert) # assert builds (`FORCE_ASSERTIONS=1` and `LLVM_ASSERTIONS=1`)
        OS="linuxassert"
        ;;
    *-gnusrcassert) # both "from source" and assert
        OS="linuxsrcassert"
        ;;
    *-musl)
        OS="musl"
        ;;
    # Windows
    *-mingw)
        OS="windows"
        ;;
    # macOS
    *-apple-darwin)
        OS="macos"
        ;;
    # FreeBSD
    *-freebsd)
        OS="freebsd"
        ;;
    # fallback
    *)
        echo "Unknown triplet OS '${TRIPLET}'" >&2
        exit 1
        ;;
esac
export OS
