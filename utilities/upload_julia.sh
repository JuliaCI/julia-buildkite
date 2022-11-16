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
if [[ "${OS}" == "macos" || "${OS}" == "macosnogpl" ]]; then
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
elif [[ "${OS}" == "windows" || "${OS}" == "windowsnogpl" ]]; then
    echo "--- [windows] Extract pre-built Julia"
    mkdir -p "${JULIA_INSTALL_DIR}"
    tar zxf "${UPLOAD_FILENAME}.tar.gz" -C "${JULIA_INSTALL_DIR}" --strip-components 1

    echo "--- [windows] install innosetup"
    mkdir -p dist-extras
    curl --fail -L -o 'dist-extras/is.exe' 'https://cache.julialang.org/https://www.jrsoftware.org/download.php/is.exe' || curl --fail -L -o 'dist-extras/is.exe' 'https://www.jrsoftware.org/download.php/is.exe'
    chmod a+x dist-extras/is.exe
    MSYS2_ARG_CONV_EXCL='*' ./dist-extras/is.exe \
        /DIR="$(cygpath -w "$(pwd)/dist-extras/inno")" \
        /PORTABLE=1 \
        /CURRENTUSER \
        /VERYSILENT
    rm -f dist-extras/is.exe

    echo "--- [windows] make exe"
    codesign_script="$(pwd)/.buildkite/utilities/windows/codesign.sh"
    certificate="$(pwd)/.buildkite/secrets/windows_codesigning.pfx"
    iss_file="$(pwd)/.buildkite/utilities/windows/build-installer.iss"
    MSYS2_ARG_CONV_EXCL='*' ./dist-extras/inno/iscc.exe \
        /DAppVersion=${JULIA_VERSION} \
        /DSourceDir="$(cygpath -w "$(pwd)/${JULIA_INSTALL_DIR}")" \
        /DRepoDir="$(cygpath -w "$(pwd)")" \
        /F"${UPLOAD_FILENAME}" \
        /O"$(cygpath -w "$(pwd)")" \
        /Dsign=true \
        /Smysigntool="bash.exe '${codesign_script}' --certificate='${certificate}' \$f" \
        "$(cygpath -w "${iss_file}")"

    # Add the `.exe` to our upload targets
    UPLOAD_EXTENSIONS+=( "exe" )

    # Use powershell to create a `.zip` file to upload as well
    echo "--- [windows] make zip"
    powershell Compress-Archive "$(cygpath -w "$(pwd)/${JULIA_INSTALL_DIR}")" "${UPLOAD_FILENAME}.zip"
    UPLOAD_EXTENSIONS+=( "zip" )
fi

echo "--- GPG-sign the tarball"
.buildkite/utilities/sign_tarball.sh .buildkite/secrets/tarball_signing.gpg "${UPLOAD_FILENAME}.tar.gz"

# Helper function to explicitly `wait` on each given PID.
# Because `wait` returns the exit code of the waited-upon PID,
# this (in combination with `set -e` above) ends execution if
# any of the backgrounded tasks failed.
wait_pids() {
    for PID in $*; do
        wait "${PID}"
    done
}

# First, upload our signed products to buildkite, for easy downloading
echo "--- Upload signed products to buildkite"
PIDS=()
for EXT in "${UPLOAD_EXTENSIONS[@]}"; do
    buildkite-agent artifact upload "${UPLOAD_FILENAME}.${EXT}" &
    PIDS+=( "$!" )
done
wait_pids "${PIDS[@]}"

unset THIS_IS_TAG_AND_WE_ALREADY_UPLOADED_THIS_TAG
if [[ "${TAR_VERSION:?}" =~ ^\d*?\. ]]; do
    echo "INFO: this DOES look like a tag: ${TAR_VERSION:?}"
    URL="https://${S3_BUCKET:?}.s3.amazonaws.com/${UPLOAD_TARGETS[0]}.${UPLOAD_EXTENSIONS[0]}"
    STATUS_CODE=$(curl --location --head ${URL:?} | head -n 1 | cut -d' ' -f2)
    echo "INFO: received status ${STATUS_CODE:?} from HEAD to URL ${URL:?}"
    if [[ "${STATUS_CODE:?}" == "200" ]]; do
        THIS_IS_TAG_AND_WE_ALREADY_UPLOADED_THIS_TAG="true"
        # TODO: Rename `THIS_IS_TAG_AND_WE_ALREADY_UPLOADED_THIS_TAG` to a better variable name
    elif [[ "${STATUS_CODE:?}" == "404" ]]; do
        THIS_IS_TAG_AND_WE_ALREADY_UPLOADED_THIS_TAG="false"
    else
        echo "FATAL ERROR: received status ${STATUS_CODE:?} from HEAD to URL ${URL:?}"
        # Print some verbose output to the log, for debugging purposes
        curl --location --head --verbose ${URL:?}
        exit 1
    fi
else
    echo "INFO: this does NOT look like a tag: ${TAR_VERSION:?}"
    THIS_IS_TAG_AND_WE_ALREADY_UPLOADED_THIS_TAG="false"
fi

if [[ "${THIS_IS_TAG_AND_WE_ALREADY_UPLOADED_THIS_TAG:?}" == "true"]]; do
    echo "INFO: We will skip all uploads, because they already exist on S3"
    echo "+++ S3 targets that already existed"
else
    echo "--- Upload primary products to S3"
    PIDS=()
    for EXT in "${UPLOAD_EXTENSIONS[@]}"; do
        aws s3 cp --acl public-read "s3://${UPLOAD_TARGETS[0]}.${EXT}" "s3://${SECONDARY_TARGET}.${EXT}" &
        PIDS+=( "$!" )
    done
    wait_pids "${PIDS[@]}"

    echo "--- Copy to secondary upload targets"
    # The primary file has now been uploaded to S3.
    # Now, we will copy the primary file to each of the secondary upload targets.
    :
    PIDS=()
    # We'll do these in parallel, then wait on the background jobs
    for SECONDARY_TARGET in ${UPLOAD_TARGETS[@]:1}; do
        for EXT in "${UPLOAD_EXTENSIONS[@]}"; do
            aws s3 cp --acl public-read "s3://${S3_BUCKET:?}/${UPLOAD_TARGETS[0]}.${EXT}" "s3://${S3_BUCKET:?}/${SECONDARY_TARGET}.${EXT}" &
            PIDS+=( "$!" )
        done
    done
    wait_pids "${PIDS[@]}"
    echo "+++ S3 targets that we uploaded to"
fi

# Report to the user some URLs that they can use to download this from.
# We need to use the new "virtual hosted-style URLs" instead of the old "path-style URLs",
# because AWS has deprecated the latter in favor of the former.
# The old "path-style" format is: https://s3.amazonaws.com/mybucket/myfile.txt
# The new "virtual hosted-style" format is: https://mybucket.s3.amazonaws.com/myfile.txt
for UPLOAD_TARGET in ${UPLOAD_TARGETS[@]}; do
    for EXT in "${UPLOAD_EXTENSIONS[@]}"; do
        echo " -> https://${S3_BUCKET:?}.s3.amazonaws.com/${UPLOAD_TARGET}.${EXT}"
    done
done
