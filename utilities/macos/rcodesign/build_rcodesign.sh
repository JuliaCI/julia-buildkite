#!/usr/bin/env bash
# Build `rcodesign` (apple-codesign) with the AWS KMS signing backend.
#
# This produces the binary used by CI to codesign and notarize macOS builds
# without any signing secrets on the agent: the Developer ID private key and
# the App Store Connect API private key both live in AWS KMS, accessed via
# OIDC-federated credentials.
#
# The KMS backend lives on our fork of apple-platform-rs (branch
# `aws-kms-backend`, on top of the pinned upstream commit), so this just clones
# that fork and builds it -- there is no local patch to apply. To change the
# backend, push to KenoAIStaging/apple-platform-rs and bump the commit below.
#
# Usage: build_rcodesign.sh [output_dir]
set -euo pipefail

# Our apple-platform-rs fork carrying the AWS KMS signing backend.
APPLE_PLATFORM_RS_URL="https://github.com/KenoAIStaging/apple-platform-rs"
APPLE_PLATFORM_RS_COMMIT="78b02e9309b2f829748879df5e5a8237de41e380"

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
OUTPUT_DIR="${1:-${SCRIPT_DIR}}"

if ! command -v cargo >/dev/null; then
    echo "ERROR: cargo not found; install Rust (https://rustup.rs)" >&2
    exit 1
fi

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "${BUILD_DIR}"' EXIT

echo "--- Clone apple-platform-rs (KMS backend fork) @ ${APPLE_PLATFORM_RS_COMMIT}"
git -C "${BUILD_DIR}" init -q apple-platform-rs
cd "${BUILD_DIR}/apple-platform-rs"
git remote add origin "${APPLE_PLATFORM_RS_URL}"
git fetch -q --depth 1 origin "${APPLE_PLATFORM_RS_COMMIT}"
git checkout -q FETCH_HEAD

# Not --locked: the aws-kms feature pulls in aws-config/credentials-login (so a
# locally-built binary can use an SSO / `aws login` session), which may resolve
# dependencies beyond the committed Cargo.lock. CI auth uses OIDC web-identity,
# which needs none of this -- the feature is just inert there.
echo "--- Build rcodesign (release, feature: aws-kms)"
cargo build --release -p apple-codesign --bin rcodesign --features aws-kms

echo "--- Install to ${OUTPUT_DIR}/rcodesign"
install -m 755 target/release/rcodesign "${OUTPUT_DIR}/rcodesign"
"${OUTPUT_DIR}/rcodesign" --version
shasum -a 256 "${OUTPUT_DIR}/rcodesign" || sha256sum "${OUTPUT_DIR}/rcodesign"
