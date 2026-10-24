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

# BUILDKITE_PULL_REQUEST_LABELS holds the labels as they were when the build was created,
# and a rebuild from the Buildkite UI keeps those of the build it repeats. So when the
# label is not there, ask GitHub for the pull request's labels as they are now.
github_repo() {
    local r="${BUILDKITE_REPO:-}"
    r="${r#*github.com}"
    r="${r#[:/]}"
    r="${r%.git}"
    r="${r%/}"
    if [[ "${r}" != */julia ]]; then
        r="JuliaLang/julia"
    fi
    echo "${r}"
}

has_label() {
    if [[ ",${BUILDKITE_PULL_REQUEST_LABELS:-}," == *",${TTFX_LABEL},"* ]]; then
        return 0
    fi
    local url="https://api.github.com/repos/$(github_repo)/issues/${BUILDKITE_PULL_REQUEST}/labels?per_page=100"
    local auth=()
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        auth=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
    fi
    local labels
    if ! labels="$(curl -fsSL --max-time 30 -H "Accept: application/vnd.github+json" ${auth[@]+"${auth[@]}"} "${url}")"; then
        echo "Could not read the pull request's labels from GitHub; deciding by the paths it touches"
        return 1
    fi
    grep -Eq "\"name\": *\"${TTFX_LABEL}\"" <<< "${labels}"
}

if has_label; then
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
