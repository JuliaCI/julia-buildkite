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

# Extract git information
SHORT_COMMIT_LENGTH=10
LONG_COMMIT="$(git rev-parse HEAD)"
SHORT_COMMIT="$(echo ${LONG_COMMIT} | cut -c1-${SHORT_COMMIT_LENGTH})"

# Extract information about the current julia version number
JULIA_VERSION="$(cat VERSION)"
MAJMIN="${JULIA_VERSION:0:3}"

# If we're on a tag, then our "tar version" will be the julia version.
# Otherwise, it's the short commit.
if git describe --tags --exact-match >/dev/null 2>/dev/null; then
    TAR_VERSION="${JULIA_VERSION}"
else
    TAR_VERSION="${SHORT_COMMIT}"
fi

# Build the filename that we'll upload as, and get the filename that will be built
# These are not the same in situations such as `musl`, where the build system doesn't
# differentiate but we need to give it a different name.
JULIA_BINARYDIST_FILENAME="$(make print-JULIA_BINARYDIST_FILENAME | cut -c27- | tr -s ' ').tar.gz"

JULIA_INSTALL_DIR="julia-${TAR_VERSION}"
JULIA_BINARY="${JULIA_INSTALL_DIR}/bin/julia"

# We generally upload to multiple upload targets
UPLOAD_TARGETS=(
    # First, we have the canonical fully-specified upload target
    "julialangnightlies/bin/${OS?}/${ARCH?}/${MAJMIN?}/julia-${TAR_VERSION?}-${OS?}-${ARCH?}.tar.gz"

    # Next, we have the "majmin/latest" upload target
    "julialangnightlies/bin/${OS?}/${ARCH?}/${MAJMIN?}/julia-latest-${OS?}-${ARCH?}.tar.gz"
    
    # And then the general "latest" upload target
    "julialangnightlies/bin/${OS?}/${ARCH?}/julia-latest-${OS?}-${ARCH?}.tar.gz"
)
UPLOAD_FILENAME="julia-${TAR_VERSION?}-${OS?}-${ARCH?}.tar.gz"

# Finally, for compatibility, we keep on uploading x86_64 and i686 targets to folders called `x64`
# and `x86`, and ending in `-linux64` and `-linux32`, although I would very much like to stop doing that.
if [[ "${ARCH}" == "x86_64" ]]; then
    UPLOAD_TARGETS+=( "julialangnightlies/bin/${OS?}/x64/${MAJMIN?}/julia-${TAR_VERSION?}-${OS?}64.tar.gz" )
    UPLOAD_TARGETS+=( "julialangnightlies/bin/${OS?}/x64/${MAJMIN?}/julia-latest-${OS?}64.tar.gz" )
    UPLOAD_TARGETS+=( "julialangnightlies/bin/${OS?}/x64/julia-latest-${OS?}64.tar.gz" )
elif [[ "${ARCH}" == "i686" ]]; then
    UPLOAD_TARGETS+=( "julialangnightlies/bin/${OS?}/x86/${MAJMIN?}/julia-${TAR_VERSION?}-${OS?}32.tar.gz" )
    UPLOAD_TARGETS+=( "julialangnightlies/bin/${OS?}/x86/${MAJMIN?}/julia-latest-${OS?}32.tar.gz" )
    UPLOAD_TARGETS+=( "julialangnightlies/bin/${OS?}/x86/julia-latest-${OS?}32.tar.gz" )
fi

echo "--- Print the full and short commit hashes"
echo "The full commit is:                      ${LONG_COMMIT}"
echo "The short commit is:                     ${SHORT_COMMIT}"
echo "Julia will be installed to:        ${JULIA_BINARY}"
echo "Detected Julia version:            ${MAJMIN}  (${JULIA_VERSION})"
echo "Detected build platform:           ${TRIPLET}  (${ARCH}, ${OS})"
echo "Julia will be uploaded to:         s3://${UPLOAD_TARGETS[0]}"
echo "With additional upload targets:"
for UPLOAD_TARGET in ${UPLOAD_TARGETS[@]:1}; do
    echo " -> s3://${UPLOAD_TARGET}"
done
