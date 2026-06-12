#!/usr/bin/env bash

# Publish a Julia build that was previously staged as an unsigned `.tar.gz`.
#
#   upload_julia.sh publish   (TRUSTED, runs in the julia-publish pipeline)
#       Verifies the commit is a real release commit, then signs (macOS
#       codesign + notarize, Windows Trusted Signing, GPG tarball) and
#       promotes the artifacts from the julia-ci staging bucket to the
#       canonical release locations using the `publish` role. Never runs
#       on pull requests.
#
# (The untrusted counterpart -- staging the unsigned tarball write-once to
# the per-pipeline ephemeral staging bucket -- happens directly in the
# build step, see build_julia.sh.)
#
# Requires TRIPLET to be defined.
set -euo pipefail

MODE="${1:?usage: upload_julia.sh publish}"

# First, get things like `SHORT_COMMIT`, `UPLOAD_TARGETS`, `STAGING_TARGET`, etc...
# shellcheck source=SCRIPTDIR/build_envs.sh
source .buildkite/utilities/build_envs.sh

THIS_DIR="$(realpath "$(dirname "${BASH_SOURCE[0]}")")"

# shellcheck source=SCRIPTDIR/upload_to_s3.sh
source .buildkite/utilities/upload_to_s3.sh

# KMS keys used for release signing (aliases resolve in the CI account)
MACOS_CODESIGN_KMS_KEY="${MACOS_CODESIGN_KMS_KEY:-alias/julia-macos-codesigning}"
TARBALL_SIGNING_KMS_KEY="${TARBALL_SIGNING_KMS_KEY:-alias/julia-tarball-signing}"

# Because `wait` returns the exit code of the waited-upon PID, this (with
# `set -e`) ends execution if any backgrounded task failed.
wait_pids() {
    for PID in "$@"; do
        wait "${PID}"
    done
}

if [[ "${MODE}" != "publish" ]]; then
    echo "ERROR: unknown mode '${MODE}' (expected 'publish')" >&2
    exit 1
fi

# ============================================================================
# PUBLISH (trusted)
# ============================================================================

# When invoked in a loop by publish.sh, the trust guard and OIDC role have
# already been established once for the whole step; skip re-doing them per
# triplet. Otherwise (standalone invocation) do them here.
if [[ -z "${PUBLISH_PREAUTHED:-}" ]]; then
    # Defense in depth: refuse unless this commit is a genuine release commit
    # on the canonical upstream. The real boundary is that the julia-publish
    # pipeline does not build pull requests at all (see ops/README.md).
    echo "--- Verify this is a trusted release commit"
    bash .buildkite/utilities/verify_trusted_commit.sh

    # shellcheck source=SCRIPTDIR/aws_oidc.sh
    source .buildkite/utilities/aws_oidc.sh publish
fi

echo "--- Download unsigned tarball from s3://${STAGING_TARGET}.tar.gz"
aws s3 cp "s3://${STAGING_TARGET}.tar.gz" "${UPLOAD_FILENAME}.tar.gz"

# These are the extensions that we will always upload
UPLOAD_EXTENSIONS=( "tar.gz" )

# If we're on macOS, we need to re-sign the tarball
if [[ "${OS}" == "macos" || "${OS}" == "macosnogpl" ]]; then
    echo "--- [mac] Codesign tarball contents"
    # The Developer ID private key lives in AWS KMS; every signature is
    # a kms:Sign call performed by rcodesign (no keychain, no key file).
    mkdir -p "${JULIA_INSTALL_DIR}"
    tar zxf "${UPLOAD_FILENAME}.tar.gz" -C "${JULIA_INSTALL_DIR}" --strip-components 1
    .buildkite/utilities/macos/codesign.sh \
        --kms-key "${MACOS_CODESIGN_KMS_KEY}" \
        "${JULIA_INSTALL_DIR}"

    echo "--- [mac] Update checksums for stdlib cachefiles"
    # Cross mode: the freshly signed macOS binaries cannot run on this
    # linux agent, so the host julia patches the target tree in place.
    julia .buildkite/utilities/update_stdlib_pkgimage_checksums.jl "${JULIA_INSTALL_DIR}" dylib

    # Immediately re-compress that tarball for upload
    echo "--- [mac] Re-compress codesigned tarball"
    rm -f "${UPLOAD_FILENAME}.tar.gz"
    tar zcf "${UPLOAD_FILENAME}.tar.gz" "${JULIA_INSTALL_DIR}"

    # Make a `.dmg` out of those files (signs + notarizes via KMS-held keys)
    echo "--- [mac] Build .dmg"
    MACOS_CODESIGN_KMS_KEY="${MACOS_CODESIGN_KMS_KEY}" \
        .buildkite/utilities/macos/build_dmg.sh

    # Add the `.dmg` to our upload targets
    UPLOAD_EXTENSIONS+=( "dmg" )
elif [[ "${OS}" == "windows" || "${OS}" == "windowsnogpl" ]]; then
    echo "--- [windows] Extract pre-built Julia"
    mkdir -p "${JULIA_INSTALL_DIR}"
    tar zxf "${UPLOAD_FILENAME}.tar.gz" -C "${JULIA_INSTALL_DIR}" --strip-components 1

    echo "--- [windows] make exe (Inno Setup under Wine)"
    # The whole Windows packaging path runs on this linux agent: Inno Setup
    # is preinstalled in the publish image's Wine prefix (no installer
    # download at publish time), and Authenticode signing happens host-side
    # via jsign + Azure Trusted Signing (Buildkite OIDC workload identity
    # federation, no client secret; see utilities/windows/codesign.sh).
    # ISCC's compile-time SignTool (installer + embedded uninstaller)
    # bridges back to the host signer through wine_signtool.cmd.
    codesign_script="$THIS_DIR/windows/codesign.sh"
    iss_file="$THIS_DIR/windows/build-installer.iss"
    WINE="${WINE:-wine}"
    ISCC_EXE="${ISCC_EXE:-C:\\Program Files (x86)\\Inno Setup 6\\ISCC.exe}"
    export CODESIGN_SH="${codesign_script}"

    "${WINE}" "${ISCC_EXE}" \
        /DAppVersion="${JULIA_VERSION}" \
        /DSourceDir="$("${WINE}" winepath -w "$(pwd)/${JULIA_INSTALL_DIR}")" \
        /DRepoDir="$("${WINE}" winepath -w "$(pwd)")" \
        /F"${UPLOAD_FILENAME}" \
        /O"$("${WINE}" winepath -w "$(pwd)")" \
        /Dsign=true \
        /Smysigntool="cmd.exe /c $("${WINE}" winepath -w "${THIS_DIR}/windows/wine_signtool.cmd") \$f" \
        "$("${WINE}" winepath -w "${iss_file}")"

    # Tripwire: if the Wine->host signing bridge failed silently, the
    # installer would come out unsigned; refuse to publish it.
    echo "--- [windows] Verify the installer is Authenticode-signed"
    python3 "$THIS_DIR/windows/check_signed.py" "${UPLOAD_FILENAME}.exe"

    # Add the `.exe` to our upload targets
    UPLOAD_EXTENSIONS+=( "exe" )

    # Next, directly codesign every PE file in the install dir
    echo "--- [windows] Codesign everything in the install directory"
    "${codesign_script}" "${JULIA_INSTALL_DIR}"

    echo "--- [windows] Update checksums for stdlib cachefiles"
    # Cross mode: the signed Windows binaries cannot run on this linux
    # agent, so the host julia patches the target tree in place.
    julia .buildkite/utilities/update_stdlib_pkgimage_checksums.jl "${JULIA_INSTALL_DIR}" dll

    # Immediately re-compress that tarball for upload
    echo "--- [windows] Re-compress codesigned tarball"
    rm -f "${UPLOAD_FILENAME}.tar.gz"
    tar zcf "${UPLOAD_FILENAME}.tar.gz" "${JULIA_INSTALL_DIR}"

    # Use 7z (p7zip) to create a `.zip` file to upload as well
    echo "--- [windows] make zip"
    7z a "${UPLOAD_FILENAME}.zip" "${JULIA_INSTALL_DIR}"
    UPLOAD_EXTENSIONS+=( "zip" )
fi

echo "--- GPG-sign the tarball"
# The OpenPGP signature is assembled locally but the raw RSA signature
# comes from AWS KMS, where the release signing key was generated and
# never leaves. Signatures verify against the committed public key,
# exported from KMS with ops/20_export_gpg_pubkey.py.
python3 .buildkite/utilities/kms_gpg_sign.py \
    --public-key .buildkite/secrets/tarball_signing.pub.asc \
    --kms-key-id "${TARBALL_SIGNING_KMS_KEY}" \
    "${UPLOAD_FILENAME}.tar.gz"
UPLOAD_EXTENSIONS+=( "tar.gz.asc" )

# Upload signed products to buildkite, for easy downloading
echo "--- Upload products to buildkite"
PIDS=()
for EXT in "${UPLOAD_EXTENSIONS[@]}"; do
    buildkite-agent artifact upload "${UPLOAD_FILENAME}.${EXT}" &
    PIDS+=( "$!" )
done
wait_pids "${PIDS[@]}"

# Promote to all final S3 targets (each target gets a direct upload of the
# local file; no bucket-to-bucket copies, since write-once enforcement only
# applies to PutObject).
echo "--- Promote to final S3 locations"
PIDS=()
for UPLOAD_TARGET in "${UPLOAD_TARGETS[@]}"; do
    for EXT in "${UPLOAD_EXTENSIONS[@]}"; do
        upload_to_s3 "${UPLOAD_FILENAME}.${EXT}" "${UPLOAD_TARGET}.${EXT}" &
        PIDS+=( "$!" )
    done
done
wait_pids "${PIDS[@]}"

echo "+++ Published to targets"
for UPLOAD_TARGET in "${UPLOAD_TARGETS[@]}"; do
    for EXT in "${UPLOAD_EXTENSIONS[@]}"; do
        echo " -> s3://${UPLOAD_TARGET}.${EXT}"
    done
done
