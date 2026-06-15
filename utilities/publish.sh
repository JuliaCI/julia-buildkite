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
# A single LINUX step (rather than one job per platform) is feasible
# because all signing is remote-key (KMS / Trusted Signing) and every
# packaging tool is linux-capable: rcodesign signs/notarizes Apple
# artifacts cross-platform, the .dmg is built with mozilla/libdmg-hfsplus,
# the Windows installer is compiled by Inno Setup under Wine with
# Authenticode signatures from jsign, and pkgimage checksums are patched
# by a host julia. See "Publish image prerequisites" in ops/README.md.
set -euo pipefail

# This step runs inside the julia_publish sandbox, whose mount namespace can't
# reach the agent's Job API unix socket on the host. A set-but-unreachable
# BUILDKITE_AGENT_JOB_API_SOCKET makes every `buildkite-agent` CLI call abort
# on startup. The only agent calls here are `oidc request-token` (aws_oidc.sh,
# windows/codesign.sh), which use the agent's HTTPS API, not the Job API, so
# drop the socket vars to skip the unreachable Job API client.
unset BUILDKITE_AGENT_JOB_API_SOCKET BUILDKITE_AGENT_JOB_API_TOKEN

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

# The trust guard above runs once; the publish role is (re-)assumed inside
# the loop below, since Buildkite OIDC tokens live at most 2h and this
# step can run longer across all triplets.
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

# Which OIDC role to assume for signing+promotion. Defaults to the trusted
# production `publish` role; the non-production publish test stack sets
# PUBLISH_OIDC_MODE=publish-test to assume the throwaway test role instead.
PUBLISH_OIDC_MODE="${PUBLISH_OIDC_MODE:-publish}"

FAILED=()
for triplet in "${TRIPLETS[@]}"; do
    echo "+++ Publish ${triplet}"
    # Fresh OIDC token per triplet (2h max lifetime; see aws_oidc.sh)
    # shellcheck source=SCRIPTDIR/aws_oidc.sh
    source .buildkite/utilities/aws_oidc.sh "${PUBLISH_OIDC_MODE}"
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
