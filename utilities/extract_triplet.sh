#!/usr/bin/env bash

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
    *-gnuprofiling) # profiling-enabled builds (`WITH_TRACY=1` and `WITH_ITTAPI=1` and `WITH_TIMING_COUNTS=1`)
        OS="linuxprofiling"
        ;;
    *-gnusrcassert) # both "from source" and assert
        OS="linuxsrcassert"
        ;;
    *-gnunogpl) # builds that use `USE_GPL_LIBS=0`
        OS="linuxnogpl"
        ;;
    *-musl)
        OS="musl"
        ;;
    # Windows
    *-mingw32)
        OS="windows"
        ;;
    *-mingw32nogpl) # builds that use `USE_GPL_LIBS=0`
        OS="windowsnogpl"
        ;;
    # macOS
    *-apple-darwin)
        OS="macos"
        ;;
    *-apple-darwinnogpl) # builds that use `USE_GPL_LIBS=0`
        OS="macosnogpl"
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
