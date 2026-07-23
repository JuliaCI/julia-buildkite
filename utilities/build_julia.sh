#!/usr/bin/env bash

# This script performs the basic steps needed to build Julia from source
# It requires the following environment variables to be defined:
#  - TRIPLET
#  - MAKE_FLAGS
set -euo pipefail

# First, get things like `SHORT_COMMIT`, `JULIA_CPU_TARGET`, `UPLOAD_TARGETS`, etc...
# shellcheck source=SCRIPTDIR/build_envs.sh
source .buildkite/utilities/build_envs.sh
# shellcheck source=SCRIPTDIR/word.sh
source .buildkite/utilities/word.sh

# Build jobs emit the sysimage from one process, so use the full CPU budget.
export JULIA_IMAGE_THREADS="${JULIA_CPU_THREADS}"
# Julia 1.14+ shares a single CPU-thread budget across the parallel precompile
# workers of the stdlib pkgimage phase via a jobserver (JuliaLang/julia#61958);
# size it to this runner's allotment so the workers don't oversubscribe the
# machine.  It takes precedence over `JULIA_IMAGE_THREADS` for those workers
# (JuliaLang/julia#62495), so the sysimage steps above still get the full
# thread count.  Older Julia versions ignore this variable.
export JULIA_PRECOMPILE_THREADS="${JULIA_CPU_THREADS}"

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

echo "--- Collect make options"
# These are the flags we'll provide to `make`
MFLAGS=()

# If we have the option, let's use `--output-sync`
#if ${MAKE} --help | grep output-sync >/dev/null 2>/dev/null; then
#    MFLAGS+=( "--output-sync" )
#fi

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

# Finish off with any extra make flags from the `.arches` file
IFS=',' read -ra ARCHES_FLAGS <<<"${MAKE_FLAGS}"
MFLAGS+=( "${ARCHES_FLAGS[@]}" )

echo "Make Options:"
for FLAG in "${MFLAGS[@]}"; do
    echo " -> ${FLAG}"
done

# Stream-filter the build log, rewriting the build dir to [buildroot].  On Windows
# the buildkite agent has no PTY, so this pipe is block-buffered: a long, nearly
# silent step (e.g. the ~25 min libjulia-codegen.dll link) produces no visible
# output until the buffer fills, making the build look hung.  GNU sed -u flushes
# per line so the log streams live.  (BSD sed on macOS has no -u, and unix jobs run
# under a PTY anyway, so only Windows needs this.)
filter_buildroot() {
    if [[ "${TRIPLET}" == *mingw* ]]; then
        sed -u "s|$(pwd)|[buildroot]|g"
    else
        sed "s|$(pwd)|[buildroot]|g"
    fi
}

echo "--- Build Julia"
echo "Note: The log stream is filtered. [buildroot] replaces pwd $(pwd)"
${MAKE} "${MFLAGS[@]}" 2>&1 | filter_buildroot


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
echo "Note: The log stream is filtered. [buildroot] replaces pwd $(pwd)"
${MAKE} "${MFLAGS[@]}" build-stats 2>&1 | filter_buildroot

echo "--- Create build artifacts"
${MAKE} "${MFLAGS[@]}" binary-dist

# Rename the build artifact in case we want to name it differently, as is the case on `musl`.
if [[ "${JULIA_BINARYDIST_FILENAME}.tar.gz" != "${UPLOAD_FILENAME}.tar.gz" ]]; then
    mv "${JULIA_BINARYDIST_FILENAME}.tar.gz" "${UPLOAD_FILENAME}.tar.gz"
fi

echo "--- Upload build artifacts to buildkite"
# Other jobs in this build (tests, misc checks) consume the tarball as a
# buildkite artifact.
buildkite-agent artifact upload "${UPLOAD_FILENAME}.tar.gz"

echo "--- Stage unsigned tarball to s3://${STAGING_TARGET}.tar.gz"
# Stage straight from the build job (no relay through buildkite artifacts):
# a write-once upload to this pipeline's ephemeral staging bucket, gated by
# this build's commit sha. The untrusted `stage` role can do nothing else.
# shellcheck source=SCRIPTDIR/aws_oidc.sh
source .buildkite/utilities/aws_oidc.sh stage
# shellcheck source=SCRIPTDIR/upload_to_s3.sh
source .buildkite/utilities/upload_to_s3.sh
# The staging buckets disable object ACLs (public read via bucket policy)
UPLOAD_TO_S3_ACL=none upload_to_s3 "${UPLOAD_FILENAME}.tar.gz" "${STAGING_TARGET}.tar.gz"

# macOS: assemble the Julia.app here and stage it too. The build runs on a Mac,
# so contrib/mac/app's tooling (osacompile, etc.) is available; the trusted
# publish step then only has to codesign + repackage the .app into the signed
# .dmg -- it needs no app-building tools and no Mac. The .app is staged
# UNSIGNED (MACOS_CODESIGN_IDENTITY is unset) under a separate key; the tree
# tarball above is unchanged (test jobs still consume it).
if [[ "${OS}" == "macos" || "${OS}" == "macosnogpl" ]]; then
    echo "--- [mac] Assemble the unsigned Julia.app"
    # Pass the same MFLAGS as the main build (esp. TAGGED_RELEASE_BANNER): the
    # contrib/mac/app rule re-runs binary-dist, and without the matching flags
    # build_h.jl regenerates with a different banner, going stale and forcing a
    # full system-image rebuild. With them it collapses to a fast re-install+re-tar.
    MACOS_CODESIGN_IDENTITY="" ${MAKE} "${MFLAGS[@]}" -C contrib/mac/app "dmg/Julia-${MAJMIN?}.app"
    tar zcf "${UPLOAD_FILENAME}.app.tar.gz" -C contrib/mac/app/dmg "Julia-${MAJMIN?}.app"
    echo "--- [mac] Stage the unsigned .app to s3://${STAGING_TARGET}.app.tar.gz"
    UPLOAD_TO_S3_ACL=none upload_to_s3 "${UPLOAD_FILENAME}.app.tar.gz" "${STAGING_TARGET}.app.tar.gz"
fi
