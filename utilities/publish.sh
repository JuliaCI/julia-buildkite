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

# The set of arches to publish. Mirrors what the build pipeline staged.
# Each file's rows define TRIPLET (and TIMEOUT); see utilities/arches_env.sh.
if [[ "${PUBLISH_SCHEDULED:-}" == "true" ]]; then
    ARCHES_FILES=(
        .buildkite/pipelines/scheduled/platforms/upload_linux.no_gpl.arches
        .buildkite/pipelines/scheduled/platforms/upload_macos.no_gpl.arches
        .buildkite/pipelines/scheduled/platforms/upload_windows.no_gpl.arches
        .buildkite/pipelines/scheduled/platforms/upload_linux.opt.arches
    )
elif [[ -n "${PUBLISH_ARCHES_FILES:-}" ]]; then
    # shellcheck disable=SC2206
    ARCHES_FILES=( ${PUBLISH_ARCHES_FILES} )
else
    ARCHES_FILES=(
        .buildkite/pipelines/main/platforms/upload_linux.arches
        .buildkite/pipelines/main/platforms/upload_macos.arches
        .buildkite/pipelines/main/platforms/upload_windows.arches
        .buildkite/pipelines/main/platforms/upload_freebsd.arches
    )
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

# macOS notarization is deferred: build_dmg.sh only submits each dmg to
# Apple and records the submission here, so Apple's processing overlaps the
# remaining triplets. ALL of a macOS triplet's products (.tar.gz, .tar.gz.asc,
# .dmg -- they share the signed tree Apple is judging) are withheld until the
# final phase below, which waits, staples and only then promotes.
NOTARY_DEFER_DIR="$(mktemp -d)"
export NOTARY_DEFER_DIR
trap 'rm -rf "${NOTARY_DEFER_DIR}"' EXIT

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

echo "+++ Publish source dists"
# shellcheck source=SCRIPTDIR/aws_oidc.sh
source .buildkite/utilities/aws_oidc.sh "${PUBLISH_OIDC_MODE}"
if ! bash .buildkite/utilities/publish_srcdist.sh; then
    echo "ERROR: publishing source dists failed" >&2
    FAILED+=( "srcdist" )
fi

# Deferred macOS triplets: collect Apple's verdicts, staple, and promote.
# Each .deferinfo (written by upload_julia.sh) is: submission ID, then one
# "<local path>\t<s3 target>" pair per line covering EVERY product of the
# triplet (.tar.gz, .tar.gz.asc, .dmg) -- nothing macOS was promoted before
# this point, so a rejected notarization publishes nothing (the final
# locations are write-once and could not be repaired by a retry).
shopt -s nullglob
DEFERRED_MACOS=( "${NOTARY_DEFER_DIR}"/*.deferinfo )
shopt -u nullglob
if [[ "${#DEFERRED_MACOS[@]}" -gt 0 ]]; then
    echo "+++ Notarize + publish ${#DEFERRED_MACOS[@]} deferred macOS triplet(s)"
    # Fresh credentials: the previous token may be near its lifetime limit.
    # shellcheck source=SCRIPTDIR/aws_oidc.sh
    source .buildkite/utilities/aws_oidc.sh "${PUBLISH_OIDC_MODE}"
    # shellcheck source=SCRIPTDIR/upload_to_s3.sh
    source .buildkite/utilities/upload_to_s3.sh
    RCODESIGN="$(bash .buildkite/utilities/macos/get_rcodesign.sh)"
    NOTARY_API_KEY_FILE=".buildkite/utilities/macos/notary_api_key.json"
    for info in "${DEFERRED_MACOS[@]}"; do
        mapfile -t rec < "${info}"
        submission_id="${rec[0]}"
        files=()
        targets=()
        dmg_path=""
        for line in "${rec[@]:1}"; do
            files+=( "${line%%$'\t'*}" )
            targets+=( "${line#*$'\t'}" )
            [[ "${line%%$'\t'*}" == *.dmg ]] && dmg_path="${line%%$'\t'*}"
        done
        name="$(basename "${info}" .deferinfo)"
        echo "--- Notarize + staple + publish ${name}"
        # notary-wait exits 0 even for a rejected submission; the staple is
        # the success gate (a rejected submission has no ticket to staple).
        if ! "${RCODESIGN}" notary-wait --max-wait-seconds 1800 \
                --api-key-file "${NOTARY_API_KEY_FILE}" "${submission_id}" \
            || ! "${RCODESIGN}" staple "${dmg_path}"; then
            echo "ERROR: notarizing/stapling ${name} failed; withholding all its products" >&2
            FAILED+=( "${name}" )
            continue
        fi
        upload_ok=1
        PIDS=()
        for i in "${!files[@]}"; do
            upload_to_s3 "${files[$i]}" "${targets[$i]}" &
            PIDS+=( "$!" )
        done
        for pid in "${PIDS[@]}"; do
            wait "${pid}" || upload_ok=0
        done
        if [[ "${upload_ok}" -ne 1 ]]; then
            echo "ERROR: publishing ${name} failed" >&2
            FAILED+=( "${name}" )
        fi
    done
fi

if [[ "${#FAILED[@]}" -gt 0 ]]; then
    echo "--- ${#FAILED[@]} item(s) failed to publish: ${FAILED[*]}" >&2
    exit 1
fi

echo "+++ All triplets published"
