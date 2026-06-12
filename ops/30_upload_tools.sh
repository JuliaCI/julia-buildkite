#!/usr/bin/env bash
# Upload prebuilt CI tool binaries (rcodesign with the AWS KMS backend) to
# S3 so upload jobs can fetch them instead of building Rust from source.
#
# Build the binaries first on a macOS machine (both architectures):
#     utilities/macos/rcodesign/build_rcodesign.sh /tmp/rcodesign-aarch64
#     (and again with `cargo build --target x86_64-apple-darwin` or on an
#      x86_64 machine for the other architecture)
#
# Usage: 30_upload_tools.sh <rcodesign-binary> <arch>   # arch: aarch64|x86_64
#
# After uploading, update RCODESIGN_SHA256_<arch> in
# utilities/macos/codesign.sh with the printed sha256.
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
source "${SCRIPT_DIR}/common.sh"

BINARY="${1:?usage: $0 <rcodesign-binary> <aarch64|x86_64>}"
ARCH="${2:?usage: $0 <rcodesign-binary> <aarch64|x86_64>}"

VERSION="$("${BINARY}" --version 2>/dev/null | awk '{print $2}' || echo unknown)"
DEST="s3://${S3_BUCKET}/tools/rcodesign-${VERSION}-kms1-${ARCH}-apple-darwin"

aws s3 cp --acl public-read "${BINARY}" "${DEST}"

echo
echo "Uploaded: ${DEST}"
echo "URL:      https://${S3_BUCKET}.s3.amazonaws.com/tools/rcodesign-${VERSION}-kms1-${ARCH}-apple-darwin"
SHA256="$(shasum -a 256 "${BINARY}" 2>/dev/null | awk '{print $1}' || sha256sum "${BINARY}" | awk '{print $1}')"
echo "sha256:   ${SHA256}"
echo
echo "Update RCODESIGN_VERSION/RCODESIGN_SHA256_${ARCH} in utilities/macos/codesign.sh"
