#!/usr/bin/env bash
# Fetch (and cache) the pinned rcodesign binary; prints its path.
#
# rcodesign is apple-codesign with the AWS KMS backend patch applied (see
# utilities/macos/rcodesign/), built by build_rcodesign.sh and published
# to S3 by ops/30_upload_tools.sh. The sha256 below pins the exact binary.
# It runs on the LINUX publish agent: rcodesign signs, notarizes and
# staples Apple artifacts cross-platform.
#
# Set RCODESIGN to override (e.g. a locally built binary).
set -euo pipefail

RCODESIGN_VERSION="0.29.0-kms1"
RCODESIGN_SHA256_x86_64_linux_gnu="0000000000000000000000000000000000000000000000000000000000000000"
RCODESIGN_BASE_URL="https://julialangnightlies.s3.amazonaws.com/tools"

if [ -n "${RCODESIGN:-}" ]; then
    echo "${RCODESIGN}"
    exit 0
fi

case "$(uname -sm)" in
    "Linux x86_64") TRIPLET="x86_64-linux-gnu" ;;
    *)
        echo "ERROR: no pinned rcodesign build for '$(uname -sm)'; set RCODESIGN" >&2
        exit 1
        ;;
esac

SHA_VAR="RCODESIGN_SHA256_${TRIPLET//-/_}"
EXPECTED_SHA="${!SHA_VAR}"
CACHE_DIR="${HOME}/.cache/julia-buildkite"
BINARY="${CACHE_DIR}/rcodesign-${RCODESIGN_VERSION}-${TRIPLET}"

if [ ! -x "${BINARY}" ]; then
    mkdir -p "${CACHE_DIR}"
    curl --fail -sSL -o "${BINARY}.tmp" \
        "${RCODESIGN_BASE_URL}/rcodesign-${RCODESIGN_VERSION}-${TRIPLET}" >&2
    ACTUAL_SHA="$(sha256sum "${BINARY}.tmp" | cut -d' ' -f1)"
    if [ "${ACTUAL_SHA}" != "${EXPECTED_SHA}" ]; then
        echo "ERROR: rcodesign sha256 mismatch (got ${ACTUAL_SHA}, expected ${EXPECTED_SHA})" >&2
        rm -f "${BINARY}.tmp"
        exit 1
    fi
    chmod +x "${BINARY}.tmp"
    mv "${BINARY}.tmp" "${BINARY}"
fi

echo "${BINARY}"
