#!/usr/bin/env bash

# This script performs the basic steps needed to sign and upload a
# Julia previously built and uploaded as a `.tar.gz`.
# It requires the following environment variables to be defined:
#  - TRIPLET
set -euo pipefail

# First, get things like `SHORT_COMMIT`, `JULIA_CPU_TARGET`, `UPLOAD_TARGETS`, etc...
# shellcheck source=SCRIPTDIR/build_envs.sh
source .buildkite/utilities/build_envs.sh

# Obtain AWS credentials via Buildkite OIDC. There are no static AWS
# secrets: IAM trusts this job's identity (pipeline/ref/step) directly.
#  - Release builds: `upload` role (write-once S3 puts, latest pointer
#    repoints, kms:Sign for code/tarball signing).
#  - PR builds: `upload-pr` role (write-once puts to bin/pr/<commit>/ only;
#    no signing, no other access).
# shellcheck source=SCRIPTDIR/aws_oidc.sh
if [[ "${BUILDKITE_PULL_REQUEST}" == "false" ]]; then
    source .buildkite/utilities/aws_oidc.sh upload
else
    source .buildkite/utilities/aws_oidc.sh upload-pr
fi

# KMS keys used for release signing (aliases resolve in the CI account)
MACOS_CODESIGN_KMS_KEY="${MACOS_CODESIGN_KMS_KEY:-alias/julia-macos-codesigning}"
TARBALL_SIGNING_KMS_KEY="${TARBALL_SIGNING_KMS_KEY:-alias/julia-tarball-signing}"

echo "--- Download ${UPLOAD_FILENAME}.tar.gz to ."
buildkite-agent artifact download "${UPLOAD_FILENAME}.tar.gz" .

# These are the extensions that we will always upload
UPLOAD_EXTENSIONS=( "tar.gz" )
THIS_DIR="$(realpath "$(dirname "${BASH_SOURCE[0]}")")"

# Only codesign if we are not on a pull request build.
# Pull request builds only upload unsigned tarballs.
if [[ "${BUILDKITE_PULL_REQUEST}" == "false" ]]; then
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
        "${JULIA_INSTALL_DIR}/bin/julia" .buildkite/utilities/update_stdlib_pkgimage_checksums.jl

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
        # Codesigning happens in Azure Trusted Signing, authenticated via
        # Buildkite OIDC workload identity federation (no client secret);
        # see utilities/windows/codesign.sh.
        codesign_script="$THIS_DIR/windows/codesign.sh"
        iss_file="$THIS_DIR/windows/build-installer.iss"

        MSYS2_ARG_CONV_EXCL='*' ./dist-extras/inno/iscc.exe \
            /DAppVersion="${JULIA_VERSION}" \
            /DSourceDir="$(cygpath -w "$(pwd)/${JULIA_INSTALL_DIR}")" \
            /DRepoDir="$(cygpath -w "$(pwd)")" \
            /F"${UPLOAD_FILENAME}" \
            /O"$(cygpath -w "$(pwd)")" \
            /Dsign=true \
            /Smysigntool="bash.exe '${codesign_script}' \$f" \
            "$(cygpath -w "${iss_file}")"

        # Add the `.exe` to our upload targets
        UPLOAD_EXTENSIONS+=( "exe" )

        # Next, directly codesign every executable file in the install dir
        echo "--- [windows] Codesign everything in the install directory"
        "${codesign_script}" "${JULIA_INSTALL_DIR}"

        echo "--- [windows] Update checksums for stdlib cachefiles"
        "${JULIA_INSTALL_DIR}/bin/julia" .buildkite/utilities/update_stdlib_pkgimage_checksums.jl

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
    # The OpenPGP signature is assembled locally but the raw RSA signature
    # comes from AWS KMS, which holds the (imported) release signing key.
    # Signatures verify against the long-published juliareleases.asc.
    python3 .buildkite/utilities/kms_gpg_sign.py \
        --public-key .buildkite/secrets/tarball_signing.pub.asc \
        --kms-key-id "${TARBALL_SIGNING_KMS_KEY}" \
        "${UPLOAD_FILENAME}.tar.gz"
    UPLOAD_EXTENSIONS+=( "tar.gz.asc" )
fi

# Helper function to explicitly `wait` on each given PID.
# Because `wait` returns the exit code of the waited-upon PID,
# this (in combination with `set -e` above) ends execution if
# any of the backgrounded tasks failed.
wait_pids() {
    for PID in "$@"; do
        wait "${PID}"
    done
}

# Tell the AWS CLI not to contact the metadata service; credentials come
# from OIDC web identity (AWS_WEB_IDENTITY_TOKEN_FILE / AWS_ROLE_ARN).
export AWS_EC2_METADATA_DISABLED=true

# Upload a file to `s3://${BUCKET}/${KEY}`.
#
# Versioned artifacts are uploaded write-once (S3 conditional write,
# `If-None-Match: *`): IAM denies unconditional puts, so a release can
# never overwrite an existing object. If the object already exists (e.g.
# a retried job), we accept it iff its content matches what we built.
# `julia-latest-*` pointer objects are intentionally overwritten.
upload_to_s3() {
    local file="$1" target="$2"
    local bucket="${target%%/*}"
    local key="${target#*/}"

    if [[ "$(basename "${key}")" == julia-latest-* ]]; then
        aws s3api put-object \
            --bucket "${bucket}" --key "${key}" \
            --body "${file}" --acl public-read >/dev/null
        echo "uploaded (latest pointer): s3://${target}"
        return 0
    fi

    local output
    if output="$(aws s3api put-object \
            --bucket "${bucket}" --key "${key}" \
            --body "${file}" --acl public-read \
            --if-none-match '*' 2>&1)"; then
        echo "uploaded (write-once): s3://${target}"
        return 0
    fi

    if [[ "${output}" == *"PreconditionFailed"* || "${output}" == *"412"* ]]; then
        # Object already exists. Accept iff content is identical (single
        # PUT objects have md5 ETags), so job retries are safe.
        local local_md5 remote_etag
        local_md5="$(openssl dgst -md5 -r "${file}" | cut -d' ' -f1)"
        remote_etag="$(aws s3api head-object --bucket "${bucket}" --key "${key}" \
            --query ETag --output text | tr -d '"')"
        if [[ "${local_md5}" == "${remote_etag}" ]]; then
            echo "already exists with identical content, skipping: s3://${target}"
            return 0
        fi
        echo "ERROR: s3://${target} already exists with DIFFERENT content; refusing to overwrite" >&2
        return 1
    fi

    echo "${output}" >&2
    return 1
}

# First, upload our signed products to buildkite, for easy downloading
echo "--- Upload products to buildkite"
PIDS=()
for EXT in "${UPLOAD_EXTENSIONS[@]}"; do
    buildkite-agent artifact upload "${UPLOAD_FILENAME}.${EXT}" &
    PIDS+=( "$!" )
done
wait_pids "${PIDS[@]}"

# Next, upload to all S3 targets (each target gets a direct upload of the
# local file; we no longer perform bucket-to-bucket copies, since
# write-once enforcement only applies to PutObject).
echo "--- Upload to S3"
PIDS=()
for UPLOAD_TARGET in "${UPLOAD_TARGETS[@]}"; do
    for EXT in "${UPLOAD_EXTENSIONS[@]}"; do
        upload_to_s3 "${UPLOAD_FILENAME}.${EXT}" "${UPLOAD_TARGET}.${EXT}" &
        PIDS+=( "$!" )
    done
done
wait_pids "${PIDS[@]}"

# Report to the user some URLs that they can use to download this from
echo "+++ Uploaded to targets"
for UPLOAD_TARGET in "${UPLOAD_TARGETS[@]}"; do
    for EXT in "${UPLOAD_EXTENSIONS[@]}"; do
        echo " -> s3://${UPLOAD_TARGET}.${EXT}"
    done
done
