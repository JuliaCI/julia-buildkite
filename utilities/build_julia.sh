#!/usr/bin/env bash

# This script performs the basic steps needed to build Julia from source
# It requires the following environment variables to be defined:
#  - TRIPLET
#  - MAKE_FLAGS
set -euo pipefail

# First, get things like `SHORT_COMMIT`, `JULIA_CPU_TARGET`, `UPLOAD_TARGETS`, etc...
source .buildkite/utilities/build_envs.sh
source .buildkite/utilities/word.sh

echo "--- Print software versions"
uname -a
echo
cc -v
echo
ld -v
echo
buildkite-agent --version

if [[ "${ROOTFS_IMAGE_NAME-}" == "llvm_passes" ]]; then
    echo "--- Update CMake"
    contrib/download_cmake.sh
fi

# These are the flags we'll provide to `make`
MFLAGS=()

# If we have the option, let's use `--output-sync`
if ${MAKE} --help | grep output-sync >/dev/null 2>/dev/null; then
    MFLAGS+=( "--output-sync" )
fi

# Always use this much parallelism
MFLAGS+=( "-j${JULIA_CPU_THREADS}")

# Add a few default flags to our make flags:
MFLAGS+=( "VERBOSE=1" )
# Taken from https://stackoverflow.com/a/4024263
verlte() {
    printf '%s\n' "$1" "$2" | sort -C -V
}
verlt() {
    ! verlte "$2" "$1"
}
if verlt "1.12" "$(cat VERSION)"; then
    MFLAGS+=( "TAGGED_RELEASE_BANNER=Official https://julialang.org release" )
else
    # Keep trailing slash for compatability. The slash was removed in 1.12 with https://github.com/JuliaLang/julia/pull/53978
    MFLAGS+=( "TAGGED_RELEASE_BANNER=Official https://julialang.org/ release" )
fi
MFLAGS+=( "JULIA_CPU_TARGET=${JULIA_CPU_TARGET}" )

if [[ ! -z "${USE_JULIA_PGO_LTO-}" ]]; then
    MFLAGS+=( "STAGE2_BUILD=$PWD" )
    MFLAGS+= ( "SANITIZE_OPTS=-m64 " )

    echo "--- Collect make options"
    echo "Make Options:"
    for FLAG in "${MFLAGS[@]}"; do
        echo " -> ${FLAG}"
    done

    echo "--- Build Julia Stage 1 - with instrumentation"

    cd contrib/pgo-lto
    ${MAKE} "${MFLAGS[@]}" stage1 || cat $PWD/stage1.build/deps/patchelf-0.18.0/config.log && exit $?

    # We use profile from building stage1
    # echo "--- Collecting Profile"
    # ${MAKE} clean-profiles
    # ./stage1.build/julia .buildkite/utilities/pgo_script.jl
fi

# Finish off with any extra make flags from the `.arches` file
MFLAGS+=( $(tr "," " " <<<"${MAKE_FLAGS}") )

echo "--- Collect make options"
echo "Make Options:"
for FLAG in "${MFLAGS[@]}"; do
    echo " -> ${FLAG}"
done

if [[ ! -z "${USE_JULIA_PGO_LTO-}" ]]; then
    echo "--- Build Julia Stage 2 - optimised"
    ${MAKE} "${MFLAGS[@]}" stage2

    cd ../..
else
    echo "--- Build Julia"
    ${MAKE} "${MFLAGS[@]}"
fi

echo "--- Check that the working directory is clean"
if [ -n "$(git status --short)" ]; then
    echo "ERROR: The working directory is dirty." >&2
    echo "Output of git status:" >&2
    git status
    exit 1
fi

echo "--- Print Julia version info"
# use `JULIA_BINARY` since it has the `.exe` extension already determined,
# but strip off the first directory and replace it with `usr` since we haven't installed yet.
JULIA_EXE="./usr/${JULIA_BINARY#*/}"
${JULIA_EXE} -e 'using InteractiveUtils; InteractiveUtils.versioninfo()'

echo "--- Quick consistency checks"
${JULIA_EXE} -e "import Test; Test.@test Sys.ARCH == :${ARCH:?}"
${JULIA_EXE} -e "import Test; Test.@test Sys.WORD_SIZE == ${EXPECTED_WORD_SIZE:?}"

echo "--- Show build stats"
${MAKE} "${MFLAGS[@]}" build-stats

echo "--- Create build artifacts"
${MAKE} "${MFLAGS[@]}" binary-dist

# Rename the build artifact in case we want to name it differently, as is the case on `musl`.
if [[ "${JULIA_BINARYDIST_FILENAME}.tar.gz" != "${UPLOAD_FILENAME}.tar.gz" ]]; then
    mv "${JULIA_BINARYDIST_FILENAME}.tar.gz" "${UPLOAD_FILENAME}.tar.gz"
fi

echo "--- Upload build artifacts to buildkite"
buildkite-agent artifact upload "${UPLOAD_FILENAME}.tar.gz"
