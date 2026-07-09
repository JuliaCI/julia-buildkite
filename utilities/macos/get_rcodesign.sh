#!/usr/bin/env bash
# Fetch (and cache) the pinned rcodesign binary; prints its path.
#
# rcodesign is apple-codesign with the AWS KMS signing backend, built from
# JuliaCI/apple-platform-rs by Yggdrasil (R/rcodesign) and published as a
# rcodesign_jll release asset (see utilities/macos/rcodesign/README.md).
# The sha256 below pins the exact tarball. It runs on the LINUX publish
# agent: rcodesign signs, notarizes and staples Apple artifacts
# cross-platform.
#
# Set RCODESIGN to override (e.g. a locally built binary).
set -euo pipefail

RCODESIGN_VERSION="0.29.0+1"
RCODESIGN_CRATE_VERSION="0.29.0"
# shellcheck disable=SC2034  # read via ${!SHA_VAR} indirection below
RCODESIGN_SHA256_x86_64_linux_gnu="9756d1cf93358e3bfcd12457450950d538c858325550cb8589f397beffbbaa06"
RCODESIGN_BASE_URL="${RCODESIGN_BASE_URL:-https://github.com/JuliaBinaryWrappers/rcodesign_jll.jl/releases/download/rcodesign-v0.29.0%2B1}"

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
    TARBALL="${BINARY}.tar.gz.tmp"
    curl --fail -sSL -o "${TARBALL}" \
        "${RCODESIGN_BASE_URL}/rcodesign.v${RCODESIGN_CRATE_VERSION}.${TRIPLET}.tar.gz" >&2
    ACTUAL_SHA="$(sha256sum "${TARBALL}" | cut -d' ' -f1)"
    if [ "${ACTUAL_SHA}" != "${EXPECTED_SHA}" ]; then
        echo "ERROR: rcodesign sha256 mismatch (got ${ACTUAL_SHA}, expected ${EXPECTED_SHA})" >&2
        rm -f "${TARBALL}"
        exit 1
    fi
    EXTRACT_DIR="$(mktemp -d "${CACHE_DIR}/rcodesign-extract-XXXXXX")"
    tar -xzf "${TARBALL}" -C "${EXTRACT_DIR}" bin/rcodesign
    mv "${EXTRACT_DIR}/bin/rcodesign" "${BINARY}"
    rm -rf "${EXTRACT_DIR}" "${TARBALL}"
fi

echo "${BINARY}"
