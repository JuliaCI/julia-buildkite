#!/usr/bin/env bash
# Single trusted publish step.
#
# Runs once in the julia-publish pipeline and promotes every staged build
# to its final release location: it verifies the release commit, assumes the
# trusted `publish` role once, then iterates over every triplet, signing
# (macOS via rcodesign, Windows via Azure Trusted Signing, GPG tarball via
# KMS) and promoting each from the commit-sha-gated staging path to the
# canonical locations.
#
# A single step (rather than one job per platform) is feasible because all
# signing is now remote-key (KMS / Trusted Signing) and rcodesign signs
# Apple artifacts cross-platform. This step must therefore run on an agent
# whose image carries the full signing/packaging toolchain (rcodesign;
# InnoSetup + a cross-platform Authenticode signer for Windows; gpg-via-KMS
# python; the AWS CLI). See ops/README.md.
set -euo pipefail

# The set of arches to publish. Mirrors what the build pipeline staged.
# Each file's rows define TRIPLET (and TIMEOUT); see utilities/arches_env.sh.
ARCHES_FILES=(
    .buildkite/pipelines/main/platforms/upload_linux.arches
    .buildkite/pipelines/main/platforms/upload_macos.arches
    .buildkite/pipelines/main/platforms/upload_windows.arches
    .buildkite/pipelines/main/platforms/upload_freebsd.arches
)
# Allow callers (e.g. the scheduled no-GPL publish) to override the list.
if [[ -n "${PUBLISH_ARCHES_FILES:-}" ]]; then
    # shellcheck disable=SC2206
    ARCHES_FILES=( ${PUBLISH_ARCHES_FILES} )
fi

# Defense in depth: refuse unless this commit is a genuine release commit on
# the canonical upstream. The real boundary is that the julia-publish
# pipeline does not build pull requests at all (see ops/README.md).
echo "--- Verify this is a trusted release commit"
bash .buildkite/utilities/verify_trusted_commit.sh

# Assume the trusted publish role once for the whole step.
# shellcheck source=SCRIPTDIR/aws_oidc.sh
source .buildkite/utilities/aws_oidc.sh publish
export PUBLISH_PREAUTHED=1

# Collect all triplets from the arches files.
TRIPLETS=()
for arches in "${ARCHES_FILES[@]}"; do
    [[ -f "${arches}" ]] || { echo "WARN: missing arches file ${arches}, skipping" >&2; continue; }
    while read -r env_line; do
        [[ -n "${env_line}" ]] || continue
        # env_line looks like: TRIPLET="x86_64-linux-gnu" TIMEOUT="30"
        # shellcheck disable=SC2086
        eval "${env_line}"
        [[ -n "${TRIPLET:-}" ]] && TRIPLETS+=( "${TRIPLET}" )
    done < <(bash .buildkite/utilities/arches_env.sh "${arches}")
done

echo "--- Publishing ${#TRIPLETS[@]} triplets: ${TRIPLETS[*]}"

FAILED=()
for triplet in "${TRIPLETS[@]}"; do
    echo "+++ Publish ${triplet}"
    if ! TRIPLET="${triplet}" bash .buildkite/utilities/upload_julia.sh publish; then
        echo "ERROR: publishing ${triplet} failed" >&2
        FAILED+=( "${triplet}" )
    fi
done

if [[ "${#FAILED[@]}" -gt 0 ]]; then
    echo "--- ${#FAILED[@]} triplet(s) failed to publish: ${FAILED[*]}" >&2
    exit 1
fi

echo "+++ All triplets published"
