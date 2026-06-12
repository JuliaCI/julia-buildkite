#!/usr/bin/env bash
# Upload prebuilt CI tool binaries (rcodesign with the AWS KMS backend) to
# S3 so the publish job can fetch them instead of building Rust from source.
#
# The publish job runs on linux, so build the binary there (any x86_64
# linux machine, or the publish agent image itself):
#     utilities/macos/rcodesign/build_rcodesign.sh /tmp/rcodesign-build
#
# Usage: 30_upload_tools.sh <rcodesign-binary> [triplet]   # default: x86_64-linux-gnu
#
# After uploading, update RCODESIGN_VERSION / RCODESIGN_SHA256_<triplet> in
# utilities/macos/get_rcodesign.sh with the printed values.
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
source "${SCRIPT_DIR}/common.sh"

BINARY="${1:?usage: $0 <rcodesign-binary> [triplet]}"
TRIPLET="${2:-x86_64-linux-gnu}"

VERSION="$("${BINARY}" --version 2>/dev/null | awk '{print $2}' || echo unknown)"
DEST="s3://${S3_BUCKET}/tools/rcodesign-${VERSION}-kms1-${TRIPLET}"

aws s3 cp --acl public-read "${BINARY}" "${DEST}"

echo
echo "Uploaded: ${DEST}"
echo "URL:      https://${S3_BUCKET}.s3.amazonaws.com/tools/rcodesign-${VERSION}-kms1-${TRIPLET}"
SHA256="$(sha256sum "${BINARY}" 2>/dev/null | awk '{print $1}' || shasum -a 256 "${BINARY}" | awk '{print $1}')"
echo "sha256:   ${SHA256}"
echo
echo "Update RCODESIGN_VERSION/RCODESIGN_SHA256_${TRIPLET//-/_} in utilities/macos/get_rcodesign.sh"
