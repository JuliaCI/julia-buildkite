#!/usr/bin/env bash
# Seed the isolated test bucket with "staged" tarballs so the
# julia-publish-test-nosecrets pipeline has input to download -> KMS-sign ->
# promote. We just copy real Julia nightlies into the staging key shape the
# publish flow expects:
#
#   s3://<test-bucket>/bin/<commit>/julia-<commit:0:10>-<os>-<arch>.tar.gz
#
# (matching STAGING_TARGET in utilities/build_envs.sh). The tarball CONTENTS are
# irrelevant to the test -- only that a valid Julia tarball sits at the exact
# key the publish step requests. Use a real master commit so the publish's
# verify_trusted_commit.sh passes unchanged.
#
# Usage:
#   ops/seed_test_staging.sh <full-40-char-commit> [os-arch ...]
#
# Default os-arch list is the Linux + macOS tokens the test pipeline covers:
#   linux-x86_64 linux-i686 linux-aarch64 macos-x86_64 macos-aarch64
# Linux exercises the GPG-sign path (content-agnostic); macOS exercises the
# rcodesign codesigning of the mach-o binaries AND the .dmg build with the test
# KMS key (notarization skipped). The macOS .dmg needs the committed .app
# skeleton (ops/31_build_app_skeleton.sh). Windows is not part of the test.
#
# Needs AWS credentials that can write the test bucket (e.g. a developer
# profile); the source nightlies are read anonymously (--no-sign-request).
set -euo pipefail
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
source "${SCRIPT_DIR}/common.sh"

COMMIT="${1:?usage: seed_test_staging.sh <full-40-char-commit> [os-arch ...]}"
shift || true
TARGETS=( "$@" )
# Default: the Linux + macOS arches, matching the test pipeline's default
# PUBLISH_ARCHES_FILES (upload_linux.arches + upload_macos.arches) so a default
# seed + default build goes fully green (Linux GPG-signs, macOS rcodesign-signs).
[ "${#TARGETS[@]}" -eq 0 ] && TARGETS=( "linux-x86_64" "linux-i686" "linux-aarch64" "macos-x86_64" "macos-aarch64" )

if ! [[ "${COMMIT}" =~ ^[0-9a-f]{40}$ ]]; then
    echo "ERROR: commit must be a full 40-char sha (verify_trusted_commit.sh requires it)" >&2
    exit 1
fi

BUCKET="${S3_TEST_PUBLISH_BUCKET:-julialang-test-publish}"
NIGHTLIES="${NIGHTLIES_BUCKET:-julialangnightlies}"
SHORT="${COMMIT:0:10}"
WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT

# The staged token is "<OS>-<ARCH>" (utilities/extract_triplet.sh), which is
# also the destination filename suffix. The PUBLIC nightly path/name diverges
# (different folder + filename for macOS), so map each supported token to its
# source key under <nightlies>/bin/ explicitly.
nightly_src() {
    case "$1" in
        linux-x86_64)   echo "linux/x64/julia-latest-linux-x86_64.tar.gz" ;;
        linux-i686)     echo "linux/x86/julia-latest-linux-i686.tar.gz" ;;
        linux-aarch64)  echo "linux/aarch64/julia-latest-linux-aarch64.tar.gz" ;;
        macos-x86_64)   echo "mac/x64/julia-latest-mac64.tar.gz" ;;
        macos-aarch64)  echo "mac/aarch64/julia-latest-macaarch64.tar.gz" ;;
        *)              echo "" ;;
    esac
}

for ta in "${TARGETS[@]}"; do
    rel="$(nightly_src "${ta}")"
    if [ -z "${rel}" ]; then
        echo "ERROR: unsupported os-arch token '${ta}' (known: linux-x86_64 linux-i686 linux-aarch64 macos-x86_64 macos-aarch64)" >&2
        exit 1
    fi
    src="s3://${NIGHTLIES}/bin/${rel}"
    dstkey="bin/${COMMIT}/julia-${SHORT}-${ta}.tar.gz"

    echo "--- ${ta}: ${src}"
    aws s3 cp --no-sign-request "${src}" "${WORK}/${ta}.tar.gz"
    aws s3 cp "${WORK}/${ta}.tar.gz" "s3://${BUCKET}/${dstkey}"
    echo "    seeded -> s3://${BUCKET}/${dstkey}"
done

echo
echo "Seeded ${#TARGETS[@]} tarball(s) for commit ${SHORT} into s3://${BUCKET}/bin/${COMMIT}/"
echo "Now trigger a julia-publish-test-nosecrets build on commit ${COMMIT}."
