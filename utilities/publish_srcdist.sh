#!/usr/bin/env bash
# Sign and publish the source distribution tarballs (release tag flow only).
#
# The build pipeline's source_dist step staged the light and full source
# dists under this commit's tag/ staging path. Download them, GPG-sign via
# KMS (same key and mechanism as the binary tarballs, see upload_julia.sh),
# and upload to bin/src/<majmin>/ in the nightlies bucket. julia-promote
# then copies them to the release bucket alongside the binaries.
#
# Invoked by publish.sh after the per-triplet loop, with the publish role
# already assumed. Standalone invocation also works (it re-establishes the
# guard + role itself, like upload_julia.sh).
set -euo pipefail

# build_envs.sh derives per-platform variables from TRIPLET; the source
# dists are platform-independent, so pin any valid triplet -- only the
# version / flow / bucket variables are used here.
export TRIPLET="${TRIPLET:-x86_64-linux-gnu}"
# shellcheck source=SCRIPTDIR/build_envs.sh
source .buildkite/utilities/build_envs.sh
# shellcheck source=SCRIPTDIR/upload_to_s3.sh
source .buildkite/utilities/upload_to_s3.sh

if [[ "${RELEASE_TAG_FLOW}" != "true" ]]; then
    echo "Not a release tag build; no source dists to publish."
    exit 0
fi

if [[ -z "${PUBLISH_PREAUTHED:-}" ]]; then
    echo "--- Verify this is a trusted release commit"
    bash .buildkite/utilities/verify_trusted_commit.sh
    # shellcheck source=SCRIPTDIR/aws_oidc.sh
    source .buildkite/utilities/aws_oidc.sh "${PUBLISH_OIDC_MODE:-publish}"
fi

# Same KMS key / pubkey selection as upload_julia.sh (the non-production
# publish test stack overrides these).
TARBALL_SIGNING_KMS_KEY="${TARBALL_SIGNING_KMS_KEY:-alias/julia-tarball-signing}"
TARBALL_SIGNING_PUBKEY="${TARBALL_SIGNING_PUBKEY-.buildkite/signing-pubkeys/tarball_signing.pub.asc}"
if [[ -n "${TARBALL_SIGNING_PUBKEY}" ]]; then
    GPG_PUBKEY_ARGS=( --public-key "${TARBALL_SIGNING_PUBKEY}" )
else
    GPG_PUBKEY_ARGS=( --public-key-from-kms )
    [[ -n "${TARBALL_SIGNING_PUBKEY_CREATED:-}" ]] && GPG_PUBKEY_ARGS+=( --created "${TARBALL_SIGNING_PUBKEY_CREATED}" )
fi

STAGING_PREFIX="${STAGING_BUCKET}/${S3_BUCKET_PREFIX}/${BUILDKITE_COMMIT?}/${STAGING_FLAVOR}"

# Tag builds from before the source_dist step exist(ed) have nothing
# staged; a re-publish of such a tag must not fail on that.
if ! aws s3api head-object --bucket "${STAGING_BUCKET}" \
        --key "${S3_BUCKET_PREFIX}/${BUILDKITE_COMMIT}/${STAGING_FLAVOR}julia-srcdist.tar.gz" >/dev/null 2>&1; then
    echo "WARN: no staged source dists at s3://${STAGING_PREFIX}julia-srcdist.tar.gz; skipping." >&2
    exit 0
fi

for SUFFIX in "" "-full"; do
    STAGED="julia-srcdist${SUFFIX}.tar.gz"
    FINAL="julia-${JULIA_VERSION}${SUFFIX}.tar.gz"

    echo "--- Download staged ${STAGED} from s3://${STAGING_PREFIX}${STAGED}"
    aws s3 cp --only-show-errors "s3://${STAGING_PREFIX}${STAGED}" "${FINAL}"

    # The in-tarball prefix is part of the published interface: releases
    # extract to julia-<version>/ (source_dist.yml pins JULIA_COMMIT).
    # head closing the pipe SIGPIPEs tar (silent exit 141 under pipefail);
    # mask tar's status -- a bad tarball yields an empty/garbage FIRST_ENTRY
    # that the prefix check below rejects.
    FIRST_ENTRY="$( (tar -tzf "${FINAL}" || true) | head -1)"
    if [[ "${FIRST_ENTRY}" != "julia-${JULIA_VERSION}/"* ]]; then
        echo "ERROR: ${FINAL} does not extract to julia-${JULIA_VERSION}/ (first entry: ${FIRST_ENTRY})" >&2
        exit 1
    fi

    echo "--- GPG-sign ${FINAL}"
    python3 .buildkite/utilities/kms_gpg_sign.py \
        "${GPG_PUBKEY_ARGS[@]}" \
        --kms-key-id "${TARBALL_SIGNING_KMS_KEY}" \
        "${FINAL}"

    echo "--- Upload ${FINAL} to s3://${S3_BUCKET}/${S3_BUCKET_PREFIX}/src/${MAJMIN}/"
    upload_to_s3 "${FINAL}" "${S3_BUCKET}/${S3_BUCKET_PREFIX}/src/${MAJMIN}/${FINAL}"
    upload_to_s3 "${FINAL}.asc" "${S3_BUCKET}/${S3_BUCKET_PREFIX}/src/${MAJMIN}/${FINAL}.asc"
done

echo "+++ Published source dists"
for SUFFIX in "" "-full"; do
    echo " -> s3://${S3_BUCKET}/${S3_BUCKET_PREFIX}/src/${MAJMIN}/julia-${JULIA_VERSION}${SUFFIX}.tar.gz"
done
