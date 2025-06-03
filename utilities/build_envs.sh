#!/usr/bin/env bash

# First, extract information from our triplet
# shellcheck source=SCRIPTDIR/extract_triplet.sh
source .buildkite/utilities/extract_triplet.sh

# Figure out what GNU Make is on this system
if [[ "${OS}" == "freebsd" ]]; then
    MAKE="gmake"
else
    MAKE="make"
fi
export MAKE

# Apply fixups to our environment for when we're running on julia-buildkite pipeline
if buildkite-agent meta-data exists BUILDKITE_JULIA_BRANCH; then
    # `BUILDKITE_BRANCH` should refer to `julia.git`, not `julia-buildkite.git`
    BUILDKITE_BRANCH=$(buildkite-agent meta-data get BUILDKITE_JULIA_BRANCH)
    export BUILDKITE_BRANCH
fi

# Determine JULIA_CPU_TARGETS for different architectures
JULIA_CPU_TARGETS=()
case "${ARCH?}" in
    x86_64)
        JULIA_CPU_TARGETS+=(
            # Absolute base x86_64 feature set
            "generic"
            # Add sandybridge level (without xsaveopt) and that clones all functions
            "sandybridge,-xsaveopt,clone_all"
            # Add haswell level (without rdrnd) that is a diff of the sandybridge level
            "haswell,-rdrnd,base(1)"
            # A common baseline for modern x86-64 server CPUs
            "x86-64-v4,-rdrnd,base(1)"
        )
        ;;
    i686)
        JULIA_CPU_TARGETS+=(
            # We require SSE2, etc.. so `pentium4` is our base i686 feature set
            # We used to also target `sandybridge`, but sadly we run out of memory
            # when linking so much code, so we're temporarily restricting to only
            # the base set for now.  :(
            # Please, if you are using Julia for performance-critical work, use
            # a 64-bit processor!
            "pentium4"
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
        case "${OS?}" in
            macos)
                JULIA_CPU_TARGETS+=(
                    # Absolute base aarch64 feature set
                    "generic"
                    # Apple M1
                    "apple-m1,clone_all"
                )
                ;;
            *)
                JULIA_CPU_TARGETS+=(
                    # Absolute base aarch64 feature set
                    "generic"
                    # Cortex A57, Example: NVIDIA Jetson TX1, Jetson Nano
                    "cortex-a57"
                    # Cavium ThunderX2T99, a common server architecture
                    "thunderx2t99"
                    # NVidia Carmel, e.g. Jetson AGX Xavier; serves as a baseline for later architectures
                    "carmel,clone_all"
                    # Apple M1
                    "apple-m1,base(3)"
                    # Vector-length-agnostic common denominator between Neoverse V1 and V2, recent Arm server architectures
                    "neoverse-512tvb,base(3)"
                )
                ;;
        esac
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

# Determine if we need to add `.exe` onto the end of our executables
EXE=""
if [[ "${OS}" == "windows" ]]; then
    EXE=".exe"
fi

# Join and output
JULIA_CPU_TARGET="$(printf ";%s" "${JULIA_CPU_TARGETS[@]}")"
export JULIA_CPU_TARGET="${JULIA_CPU_TARGET:1}"

export JULIA_IMAGE_THREADS="$JULIA_CPU_THREADS"


# Extract git information
SHORT_COMMIT_LENGTH=10
LONG_COMMIT="$(git rev-parse HEAD)"
SHORT_COMMIT="$(echo "${LONG_COMMIT}" | cut -c1-${SHORT_COMMIT_LENGTH})"
export LONG_COMMIT SHORT_COMMIT

# Extract information about the current julia version number
JULIA_VERSION="$(cat VERSION)"
MAJMIN="$(cut -d. -f1-2 <<<"${JULIA_VERSION}")"
MAJMINPAT="$(cut -d- -f1 <<<"${JULIA_VERSION}")"
export JULIA_VERSION MAJMIN MAJMINPAT

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
# Note that `make print-` can fail in environments without a compiler. This varible is only
# used in build_julia.sh (where we obviously have a compiler) so if `make print-` fails we
# simply leave the variable undefined.
if BINARYDIST_FILENAME="$(${MAKE} print-JULIA_BINARYDIST_FILENAME 2>/dev/null)"; then
    JULIA_BINARYDIST_FILENAME="$(echo -n "${BINARYDIST_FILENAME}" | cut -c27- | tr -s ' ')"
    export JULIA_BINARYDIST_FILENAME
fi

export JULIA_INSTALL_DIR="julia-${TAR_VERSION}"
JULIA_BINARY="${JULIA_INSTALL_DIR}/bin/julia${EXE}"

# By default, we upload to `julialangnightlies/bin`, but we allow this to be overridden
S3_BUCKET="${S3_BUCKET:-julialangnightlies}"
S3_BUCKET_PREFIX="${S3_BUCKET_PREFIX:-bin}"

# We generally upload to multiple upload targets
UPLOAD_TARGETS=()

if [[ "${BUILDKITE_BRANCH}" == master ]] || [[ "${BUILDKITE_BRANCH}" == release-* ]] || [[ "${BUILDKITE_TAG:-}" == v* ]] || [[ "${BUILDKITE_PIPELINE_SLUG}" == "julia-buildkite" ]]; then
    # First, we have the canonical fully-specified upload target
    UPLOAD_TARGETS+=( "${S3_BUCKET}/${S3_BUCKET_PREFIX}/${OS?}/${ARCH?}/${MAJMIN?}/julia-${TAR_VERSION?}-${OS?}-${ARCH?}" )

    # Next, we have the "majmin/latest" upload target
    UPLOAD_TARGETS+=( "${S3_BUCKET}/${S3_BUCKET_PREFIX}/${OS?}/${ARCH?}/${MAJMIN?}/julia-latest-${OS?}-${ARCH?}" )

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

    # We used to name our darwin builds as `julia-*-mac64.tar.gz`, instead of `julia-*-macos-x86_64.tar.gz`.
    # Let's copy things over to the `mac` OS name for backwards compatibility:
    if [[ "${OS?}" == "macos" ]] || [[ "${OS?}" == "windows" ]]; then
        if [[ "${OS?}" == "macos" ]]; then
            FOLDER_OS="mac"
            SHORT_OS="mac"
        elif [[ "${OS?}" == "windows" ]]; then
            FOLDER_OS="winnt"
            SHORT_OS="win"
        else
            FOLDER_OS="${OS}"
            SHORT_OS="${OS}"
        fi

        if [[ "${ARCH}" == "x86_64" ]]; then
            FOLDER_ARCH="x64"
            SHORT_ARCH="64"
        elif [[ "${ARCH}" == "i686" ]]; then
            FOLDER_ARCH="x86"
            SHORT_ARCH="32"
        else
            FOLDER_ARCH="${ARCH}"
            SHORT_ARCH="${ARCH}"
        fi

        # First, we have the canonical fully-specified upload target
        UPLOAD_TARGETS+=( "${S3_BUCKET}/${S3_BUCKET_PREFIX}/${FOLDER_OS}/${FOLDER_ARCH}/${MAJMIN?}/julia-${TAR_VERSION?}-${SHORT_OS}${SHORT_ARCH}" )

        # Next, we have the "majmin/latest" upload target
        UPLOAD_TARGETS+=( "${S3_BUCKET}/${S3_BUCKET_PREFIX}/${FOLDER_OS}/${FOLDER_ARCH}/${MAJMIN?}/julia-latest-${SHORT_OS}${SHORT_ARCH}" )

        # If we're on `master` and we're uploading, we consider ourselves "absolute latest"
        if [[ "${BUILDKITE_BRANCH}" == "master" ]]; then
            UPLOAD_TARGETS+=( "${S3_BUCKET}/${S3_BUCKET_PREFIX}/${FOLDER_OS}/${FOLDER_ARCH}/julia-latest-${SHORT_OS}${SHORT_ARCH}" )
        fi
    fi
fi

# If we're a pull request build, upload to a special `-prXXXX` location
if [[ "${BUILDKITE_PULL_REQUEST}" != "false" ]]; then
    UPLOAD_TARGETS+=( "${S3_BUCKET}/${S3_BUCKET_PREFIX}/${OS?}/${ARCH?}/julia-pr${BUILDKITE_PULL_REQUEST}-${OS?}-${ARCH?}" )
fi

# This is the "main" filename that is used.  We technically don't need this for uploading,
# but it's very convenient for shuttling binaries between buildkite steps.
export UPLOAD_FILENAME="julia-${TAR_VERSION?}-${OS?}-${ARCH?}"

echo "--- Print the full and short commit hashes"
echo "The full commit is:                      ${LONG_COMMIT}"
echo "The short commit is:                     ${SHORT_COMMIT}"
echo "Julia will be installed to:        ${JULIA_BINARY}"
echo "Detected Julia version:            ${MAJMIN}  (${JULIA_VERSION})"
echo "Detected build platform:           ${TRIPLET}  (${ARCH}, ${OS})"
echo "Julia will be uploaded to:         s3://${UPLOAD_TARGETS[0]}.tar.gz"
echo "With additional upload targets:"
for UPLOAD_TARGET in "${UPLOAD_TARGETS[@]:1}"; do
    echo " -> s3://${UPLOAD_TARGET}.tar.gz"
done
