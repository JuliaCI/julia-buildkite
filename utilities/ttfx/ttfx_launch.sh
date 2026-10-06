#!/usr/bin/env bash
# TTFX launcher: uploads the macOS TTFX job for this build, unless it is a pull request
# that touches none of the paths in paths.txt and has no `needs TTFX check` label. Master
# and release builds and the julia-buildkite self-test always measure their build. See
# README.md alongside this script.
set -euo pipefail

TTFX_UTILS=".buildkite/utilities/ttfx"
TTFX_PIPELINES=".buildkite/pipelines/main/misc/ttfx"
TTFX_LABEL="needs TTFX check"
TTFX_PATHS="${TTFX_PATHS:-${TTFX_UTILS}/paths.txt}"

launch() {
    GROUP="TTFX" bash .buildkite/utilities/arches_pipeline_upload.sh \
        "${TTFX_PIPELINES}/ttfx_macos.arches" \
        "${TTFX_PIPELINES}/ttfx_macos.yml"
}

if [[ "${BUILDKITE_PIPELINE_SLUG:-}" != "julia-pr" || "${BUILDKITE_PULL_REQUEST:-false}" == "false" ]]; then
    launch
    exit 0
fi

if [[ ",${BUILDKITE_PULL_REQUEST_LABELS:-}," == *",${TTFX_LABEL},"* ]]; then
    echo "The pull request has the '${TTFX_LABEL}' label"
    launch
    exit 0
fi

paths=()
while IFS= read -r line; do
    line="${line%%#*}"
    line="${line%"${line##*[![:space:]]}"}"
    if [[ -n "${line}" ]]; then
        paths+=("${line}")
    fi
done < "${TTFX_PATHS}"

# Fetching the target branch or finding the merge-base can fail (a shallow checkout, a
# network error); the job then runs rather than being skipped on a guess.
BASE_BRANCH="${BUILDKITE_PULL_REQUEST_BASE_BRANCH:-master}"
if ! git fetch --no-tags --quiet "${BUILDKITE_REPO}" "refs/heads/${BASE_BRANCH}" \
        || ! merge_base="$(git merge-base HEAD FETCH_HEAD)"; then
    echo "Could not find the merge-base with ${BASE_BRANCH}; launching the TTFX job regardless"
    launch
    exit 0
fi

changed="$(git diff --name-only "${merge_base}" HEAD -- "${paths[@]}")"
if [[ -n "${changed}" ]]; then
    echo "Relative to the merge-base ${merge_base:0:10} with ${BASE_BRANCH}, the pull request changes:"
    while IFS= read -r file; do echo "    ${file}"; done <<< "${changed}"
    launch
    exit 0
fi

echo "+++ TTFX job not launched"
echo "Relative to the merge-base ${merge_base:0:10} with ${BASE_BRANCH}, the pull request touches none of:"
printf '    %s\n' "${paths[@]}"
echo "and does not have the '${TTFX_LABEL}' label, so it is not measured; no TTFX commit status is posted."
