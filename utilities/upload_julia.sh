#!/bin/bash

# This script performs the basic steps needed to sign and upload a
# Julia previously built and uploaded as a `.tar.gz`.
# It requires the following environment variables to be defined:
#  - TRIPLET
set -euo pipefail

# First, get things like `SHORT_COMMIT`, `JULIA_CPU_TARGET`, `UPLOAD_TARGETS`, etc...
source .buildkite/utilities/build_envs.sh

echo "--- Download ${UPLOAD_FILENAME}.tar.gz to ."
buildkite-agent artifact download "${UPLOAD_FILENAME}.tar.gz" .

# These are the extensions that we will always upload
UPLOAD_EXTENSIONS=("tar.gz" "tar.gz.asc")

# If we're on macOS, we need to re-sign the tarball
if [[ "${OS}" == "macos" ]]; then
    echo "--- [mac] Unlock keychain"

    # This _must_ be an absolute path
    KEYCHAIN_PATH="$(pwd)/.buildkite/secrets/macos_codesigning.keychain"
    MACOS_CODESIGN_IDENTITY="2053E9292809B66582CA9F042B470C0929340362"

    # Add the keychain to the list of keychains to search, then unlock it
    security -v list-keychains -s -d user "${KEYCHAIN_PATH}"
    security unlock-keychain -p "keychainpassword" "${KEYCHAIN_PATH}"
    security find-identity -p codesigning "${KEYCHAIN_PATH}"

    echo "--- [mac] Codesign tarball contents"
    mkdir -p "${JULIA_INSTALL_DIR}"
    tar zxf "${UPLOAD_FILENAME}.tar.gz" -C "${JULIA_INSTALL_DIR}" --strip-components 1
    .buildkite/utilities/macos/codesign.sh \
        --keychain "${KEYCHAIN_PATH}" \
        --identity "${MACOS_CODESIGN_IDENTITY}" \
        "${JULIA_INSTALL_DIR}"

    # Immediately re-compress that tarball for upload
    echo "--- [mac] Re-compress codesigned tarball"
    rm -f "${UPLOAD_FILENAME}.tar.gz"
    tar zcf "${UPLOAD_FILENAME}.tar.gz" "${JULIA_INSTALL_DIR}"

    # Make a `.dmg` out of those files
    echo "--- [mac] Build .dmg"
    KEYCHAIN_PATH="${KEYCHAIN_PATH}" MACOS_CODESIGN_IDENTITY="${MACOS_CODESIGN_IDENTITY}" \
        .buildkite/utilities/macos/build_dmg.sh

    # Add the `.dmg` to our upload targets
    UPLOAD_EXTENSIONS+=( "dmg" )
fi

echo "--- GPG-sign the tarball"
.buildkite/utilities/sign_tarball.sh .buildkite/secrets/tarball_signing.gpg "${UPLOAD_FILENAME}.tar.gz"

# First, upload our signed products to buildkite, for easy downloading
echo "--- Upload signed products to buildkite"
for EXT in "${UPLOAD_EXTENSIONS[@]}"; do
    buildkite-agent artifact upload "${UPLOAD_FILENAME}.${EXT}" &
done
wait

# Next, upload primary files to S3
echo "--- Upload primary products to S3"
for EXT in "${UPLOAD_EXTENSIONS[@]}"; do
    aws s3 cp --acl public-read "${UPLOAD_FILENAME}.${EXT}" "s3://${UPLOAD_TARGETS[0]}.${EXT}" &
done
wait

echo "--- Copy to secondary upload targets"
# We'll do these in parallel, then wait on the background jobs
for SECONDARY_TARGET in ${UPLOAD_TARGETS[@]:1}; do
    for EXT in "${UPLOAD_EXTENSIONS[@]}"; do
        aws s3 cp --acl public-read "s3://${UPLOAD_TARGETS[0]}.${EXT}" "s3://${SECONDARY_TARGET}.${EXT}" &
    done
done
wait

# Report to the user some URLs that they can use to download this from
echo "+++ Uploaded to targets"
for UPLOAD_TARGET in ${UPLOAD_TARGETS[@]}; do
    for EXT in "${UPLOAD_EXTENSIONS[@]}"; do
        echo " -> s3://${UPLOAD_TARGET}.${EXT}"
    done
done
