#!/usr/bin/env bash

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
UPLOAD_EXTENSIONS=( "tar.gz" )

# Only codesign if we are not on a pull request build.
# Pull request builds only upload unsigned tarballs.
if [[ "${BUILDKITE_PULL_REQUEST}" == "false" ]]; then
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

        echo "--- [mac] Update checksums for stdlib cachefiles"
        ${JULIA_INSTALL_DIR}/bin/julia .buildkite/utilities/macos/update_stdlib_pkgimage_checksums.jl

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

        # Next, directly codesign every executable file in the install dir
        echo "--- [windows] Codesign everything in the install directory"
        "${codesign_script}" --certificate="${certificate}" "${JULIA_INSTALL_DIR}"

        # Immediately re-compress that tarball for upload
        echo "--- [windows] Re-compress codesigned tarball"
        rm -f "${UPLOAD_FILENAME}.tar.gz"
        tar zcf "${UPLOAD_FILENAME}.tar.gz" "${JULIA_INSTALL_DIR}"

        # Use 7z to create a `.zip` file to upload as well
        echo "--- [windows] make zip"
        PATH="${JULIA_INSTALL_DIR}/libexec:${JULIA_INSTALL_DIR}/libexec/julia:${PATH}" \
        7z.exe a "${UPLOAD_FILENAME}.zip" "$(cygpath -w "$(pwd)/${JULIA_INSTALL_DIR}")"
        UPLOAD_EXTENSIONS+=( "zip" )
    fi

    echo "--- GPG-sign the tarball"
    .buildkite/utilities/sign_tarball.sh .buildkite/secrets/tarball_signing.gpg "${UPLOAD_FILENAME}.tar.gz"
    UPLOAD_EXTENSIONS+=( "tar.gz.asc" )
fi

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
echo "--- Upload products to buildkite"
PIDS=()
for EXT in "${UPLOAD_EXTENSIONS[@]}"; do
    buildkite-agent artifact upload "${UPLOAD_FILENAME}.${EXT}" &
    PIDS+=( "$!" )
done
wait_pids "${PIDS[@]}"

# Next, upload primary files to S3
echo "--- Upload primary products to S3"
PIDS=()
for EXT in "${UPLOAD_EXTENSIONS[@]}"; do
    aws s3 cp --acl public-read "${UPLOAD_FILENAME}.${EXT}" "s3://${UPLOAD_TARGETS[0]}.${EXT}" &
    PIDS+=( "$!" )
done
wait_pids "${PIDS[@]}"

echo "--- Copy to secondary upload targets"
PIDS=()
# We'll do these in parallel, then wait on the background jobs
for SECONDARY_TARGET in ${UPLOAD_TARGETS[@]:1}; do
    for EXT in "${UPLOAD_EXTENSIONS[@]}"; do
        aws s3 cp --acl public-read "s3://${UPLOAD_TARGETS[0]}.${EXT}" "s3://${SECONDARY_TARGET}.${EXT}" &
        PIDS+=( "$!" )
    done
done
wait_pids "${PIDS[@]}"

# Report to the user some URLs that they can use to download this from
echo "+++ Uploaded to targets"
for UPLOAD_TARGET in ${UPLOAD_TARGETS[@]}; do
    for EXT in "${UPLOAD_EXTENSIONS[@]}"; do
        echo " -> s3://${UPLOAD_TARGET}.${EXT}"
    done
done
