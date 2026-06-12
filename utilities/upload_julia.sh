#!/usr/bin/env bash

# Stage or publish a Julia build that was previously produced as a `.tar.gz`.
#
# Two modes, matching the trusted/untrusted pipeline split:
#
#   upload_julia.sh stage     (UNTRUSTED, runs in the build pipeline)
#       Uploads the UNSIGNED tarball to a commit-sha-gated staging path
#       using the `stage` role. No signing, no secrets, no final-location
#       write. For pull requests this is the end of the line (the staged
#       artifact is the consumable PR binary).
#
#   upload_julia.sh publish   (TRUSTED, runs in the julia-publish pipeline)
#       Verifies the commit is a real release commit, then signs (macOS
#       codesign + notarize, Windows Trusted Signing, GPG tarball) and
#       promotes the artifacts to the canonical release locations using the
#       `publish` role. Never runs on pull requests.
#
# Requires TRIPLET to be defined.
set -euo pipefail

MODE="${1:?usage: upload_julia.sh <stage|publish>}"

# First, get things like `SHORT_COMMIT`, `UPLOAD_TARGETS`, `STAGING_TARGET`, etc...
# shellcheck source=SCRIPTDIR/build_envs.sh
source .buildkite/utilities/build_envs.sh

THIS_DIR="$(realpath "$(dirname "${BASH_SOURCE[0]}")")"

# Tell the AWS CLI not to contact the metadata service; credentials come
# from OIDC web identity (AWS_WEB_IDENTITY_TOKEN_FILE / AWS_ROLE_ARN).
export AWS_EC2_METADATA_DISABLED=true

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

# Upload a local file to `s3://${BUCKET}/${KEY}`, write-once.
#
# IAM denies unconditional puts, so a build can never overwrite an existing
# object (S3 conditional write, If-None-Match: *). If the object already
# exists (e.g. a retried job) we accept it iff its content matches what we
# have locally. `julia-latest-*` pointer objects are intentionally
# overwritten (and only the publish role is allowed to do so).
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

# ============================================================================
# STAGE (untrusted)
# ============================================================================
if [[ "${MODE}" == "stage" ]]; then
    # shellcheck source=SCRIPTDIR/aws_oidc.sh
    source .buildkite/utilities/aws_oidc.sh stage

    echo "--- Download ${UPLOAD_FILENAME}.tar.gz from the build step"
    buildkite-agent artifact download "${UPLOAD_FILENAME}.tar.gz" .

    echo "--- Stage unsigned tarball to s3://${STAGING_TARGET}.tar.gz"
    upload_to_s3 "${UPLOAD_FILENAME}.tar.gz" "${STAGING_TARGET}.tar.gz"

    echo "+++ Staged"
    echo " -> s3://${STAGING_TARGET}.tar.gz"
    exit 0
fi

if [[ "${MODE}" != "publish" ]]; then
    echo "ERROR: unknown mode '${MODE}' (expected 'stage' or 'publish')" >&2
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
