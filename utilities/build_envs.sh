#!/bin/bash

# Extract information from our triplet
export ARCH="$(cut -d- -f1 <<<"${TRIPLET}")"
case "${TRIPLET}" in
    *-apple-*)
        OS="macos"
        ;;
    *-freebsd*)
        OS="freebsd"
        ;;
    *-mingw*)
        OS="windows"
        ;;
    *-gnuassert)
        OS="linuxassert"
        ;;
    *-gnu*)
        OS="linux"
        ;;
    *-musl*)
        OS="musl"
        ;;
    *)
        echo "Unknown triplet OS '${TRIPLET}'" >&2
        exit 1
        ;;
esac
export OS

# Determine JULIA_CPU_TARGETS for different architectures
JUlIA_CPU_TARGETS=()
case "${ARCH?}" in
    x86_64)
        JULIA_CPU_TARGETS+=(
            # Absolute base x86_64 feature set
            "generic"
            # Add sandybridge level (without xsaveopt) and that clones all functions
            "sandybridge,-xsaveopt,clone_all"
            # Add haswell level (without rdrnd) that is a diff of the sandybridge level
            "haswell,-rdrnd,base(1)"
        )
        ;;
    i686)
        JULIA_CPU_TARGETS+=(
            # We require SSE2, etc.. so `pentium4` is our base i686 feature set
            "pentium4"
            # Add sandybridge level similar to x86_64 above
            "sandybridge,-xsaveopt,clone_all"
        )
        ;;
    armv7l)
        JULIA_CPU_TARGETS+=(
            # Absolute base armv7-a feature set
            "armv7-a"
            # Add NEON level on top of that
            "armv7-a,neon"
            # Add NEON with VFP4 on top of that
            "armv7-a,neon,vfp4"
        )
        ;;
    aarch64)
        JULIA_CPU_TARGETS+=(
            # Absolute base aarch64 feature set
            "generic"
            # Cortex A57, Example: NVIDIA Jetson TX1, Jetson Nano
            "cortex-a57"
            # Cavium ThunderX2T99, a common server architecture
            "thunderx2t99"
            # NVidia Carmel, e.g. Jetson AGX Xavier
            "carmel"
        )
        ;;
    powerpc64le)
        JULIA_CPU_TARGETS+=(
            # Absolute base POWER-8 feature set
            "pwr8"
        )
        ;;
    *)
        echo "Unknown target processor architecture '${ARCH}'" >&2
        exit 1
        ;;
esac

# Join and output
JULIA_CPU_TARGET="$(printf ";%s" "${JULIA_CPU_TARGETS[@]}")"
export JULIA_CPU_TARGET="${JULIA_CPU_TARGET:1}"



# Extract git information
SHORT_COMMIT_LENGTH=10
export LONG_COMMIT="$(git rev-parse HEAD)"
export SHORT_COMMIT="$(echo ${LONG_COMMIT} | cut -c1-${SHORT_COMMIT_LENGTH})"

# Extract information about the current julia version number
export JULIA_VERSION="$(cat VERSION)"
export MAJMIN="$(cut -d. -f1-2 <<<"${JULIA_VERSION}")"
export MAJMINPAT="$(cut -d- -f1 <<<"${JULIA_VERSION}")"
# If we're on a tag, then our "tar version" will be the julia version.
# Otherwise, it's the short commit.
if git describe --tags --exact-match >/dev/null 2>/dev/null; then
    TAR_VERSION="${JULIA_VERSION}"
else
    TAR_VERSION="${SHORT_COMMIT}"
fi
export TAR_VERSION



# Build the filename that we'll upload as, and get the filename that will be built
# These are not the same in situations such as `musl`, where the build system doesn't
# differentiate but we need to give it a different name.
export JULIA_BINARYDIST_FILENAME="$(make print-JULIA_BINARYDIST_FILENAME | cut -c27- | tr -s ' ')"

export JULIA_INSTALL_DIR="julia-${TAR_VERSION}"
JULIA_BINARY="${JULIA_INSTALL_DIR}/bin/julia"

# By default, we upload to `julialangnightlies/bin`, but we allow this to be overridden
S3_BUCKET="${S3_BUCKET:-julialangnightlies}"
S3_BUCKET_PREFIX="${S3_BUCKET_PREFIX:-bin}"

# We generally upload to multiple upload targets
UPLOAD_TARGETS=(
    # First, we have the canonical fully-specified upload target
    "${S3_BUCKET}/${S3_BUCKET_PREFIX}/${OS?}/${ARCH?}/${MAJMIN?}/julia-${TAR_VERSION?}-${OS?}-${ARCH?}"

    # Next, we have the "majmin/latest" upload target
    "${S3_BUCKET}/${S3_BUCKET_PREFIX}/${OS?}/${ARCH?}/${MAJMIN?}/julia-latest-${OS?}-${ARCH?}"
)

# The absolute latest upload target is only for if we're on the `master` branch
if [[ "${BUILDKITE_BRANCH}" == "master" ]]; then
    UPLOAD_TARGETS+=( "${S3_BUCKET}/${S3_BUCKET_PREFIX}/${OS?}/${ARCH?}/julia-latest-${OS?}-${ARCH?}" )
fi


# Finally, for compatibility, we keep on uploading x86_64 and i686 targets to folders called `x64`
# and `x86`, and ending in `-linux64` and `-linux32`, although I would very much like to stop doing that.
if [[ "${ARCH}" == "x86_64" ]]; then
    UPLOAD_TARGETS+=( "${S3_BUCKET}/${S3_BUCKET_PREFIX}/${OS?}/x64/${MAJMIN?}/julia-${TAR_VERSION?}-${OS?}64" )
    UPLOAD_TARGETS+=( "${S3_BUCKET}/${S3_BUCKET_PREFIX}/${OS?}/x64/${MAJMIN?}/julia-latest-${OS?}64" )
    
    # Only upload to absolute latest if we're on `master`
    if [[ "${BUILDKITE_BRANCH}" == "master" ]]; then
        UPLOAD_TARGETS+=( "${S3_BUCKET}/${S3_BUCKET_PREFIX}/${OS?}/x64/julia-latest-${OS?}64" )
    fi
elif [[ "${ARCH}" == "i686" ]]; then
    UPLOAD_TARGETS+=( "${S3_BUCKET}/${S3_BUCKET_PREFIX}/${OS?}/x86/${MAJMIN?}/julia-${TAR_VERSION?}-${OS?}32" )
    UPLOAD_TARGETS+=( "${S3_BUCKET}/${S3_BUCKET_PREFIX}/${OS?}/x86/${MAJMIN?}/julia-latest-${OS?}32" )

    # Only upload to absolute latest if we're on `master`
    if [[ "${BUILDKITE_BRANCH}" == "master" ]]; then
        UPLOAD_TARGETS+=( "${S3_BUCKET}/${S3_BUCKET_PREFIX}/${OS?}/x86/julia-latest-${OS?}32" )
    fi
fi

export UPLOAD_FILENAME="julia-${TAR_VERSION?}-${OS?}-${ARCH?}"

echo "--- Print the full and short commit hashes"
echo "The full commit is:                      ${LONG_COMMIT}"
echo "The short commit is:                     ${SHORT_COMMIT}"
echo "Julia will be installed to:        ${JULIA_BINARY}"
echo "Detected Julia version:            ${MAJMIN}  (${JULIA_VERSION})"
echo "Detected build platform:           ${TRIPLET}  (${ARCH}, ${OS})"
echo "Julia will be uploaded to:         s3://${UPLOAD_TARGETS[0]}.tar.gz"
echo "With additional upload targets:"
for UPLOAD_TARGET in ${UPLOAD_TARGETS[@]:1}; do
    echo " -> s3://${UPLOAD_TARGET}.tar.gz"
done
