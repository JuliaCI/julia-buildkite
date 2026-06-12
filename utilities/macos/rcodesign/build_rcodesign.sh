#!/usr/bin/env bash
# Build `rcodesign` (apple-codesign) with the AWS KMS signing backend patch.
#
# This produces the binary used by CI to codesign and notarize macOS builds
# without any signing secrets on the agent: the Developer ID private key and
# the App Store Connect API private key both live in AWS KMS, accessed via
# OIDC-federated credentials.
#
# Usage: build_rcodesign.sh [output_dir]
set -euo pipefail

# Upstream commit the patch was developed against.
APPLE_PLATFORM_RS_URL="https://github.com/indygreg/apple-platform-rs"
APPLE_PLATFORM_RS_COMMIT="1aef8f7f467fe241f6a24cf2b07afb477f448a50"

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
OUTPUT_DIR="${1:-${SCRIPT_DIR}}"
PATCH_FILE="${SCRIPT_DIR}/0001-aws-kms-backend.patch"

if ! command -v cargo >/dev/null; then
    echo "ERROR: cargo not found; install Rust (https://rustup.rs)" >&2
    exit 1
fi

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "${BUILD_DIR}"' EXIT

echo "--- Clone apple-platform-rs @ ${APPLE_PLATFORM_RS_COMMIT}"
git -C "${BUILD_DIR}" init -q apple-platform-rs
cd "${BUILD_DIR}/apple-platform-rs"
git remote add origin "${APPLE_PLATFORM_RS_URL}"
git fetch -q --depth 1 origin "${APPLE_PLATFORM_RS_COMMIT}"
git checkout -q FETCH_HEAD

echo "--- Apply AWS KMS backend patch"
git apply --index "${PATCH_FILE}"

echo "--- Build rcodesign (release, features: aws-kms, notarize)"
cargo build --locked --release -p apple-codesign --bin rcodesign \
    --features aws-kms

echo "--- Install to ${OUTPUT_DIR}/rcodesign"
install -m 755 target/release/rcodesign "${OUTPUT_DIR}/rcodesign"
"${OUTPUT_DIR}/rcodesign" --version
shasum -a 256 "${OUTPUT_DIR}/rcodesign" || sha256sum "${OUTPUT_DIR}/rcodesign"
