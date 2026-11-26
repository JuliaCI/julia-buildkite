#!/usr/bin/env bash
# (Sourced file: deliberately no `set` of shell options here -- they would
# leak into the calling script; strict mode belongs to the entrypoints.)
#
# The merge-base that a pull request's from-source build is compared with, and its own
# from-source build. build_julia_merge_base.sh finds and builds it; the TTFX and runtime
# benchmark jobs of the from-source build measure it (TTFX_BASE=src, RTB_BASE=src).

# Set MERGE_BASE and BASE_BRANCH: the merge-base of a julia-pr pull request with its target
# branch, or, on the julia-buildkite self-test, which builds a julia master commit, its
# parent, as the TTFX job does.
find_src_merge_base() {
    if [[ "${BUILDKITE_PIPELINE_SLUG:-}" == julia-buildkite* ]]; then
        BASE_BRANCH="master"
        MERGE_BASE="$(git rev-parse HEAD^)"
    else
        BASE_BRANCH="${BUILDKITE_PULL_REQUEST_BASE_BRANCH:-master}"
        git fetch --no-tags --quiet "${BUILDKITE_REPO}" "refs/heads/${BASE_BRANCH}"
        MERGE_BASE="$(git merge-base HEAD FETCH_HEAD)"
    fi
}

# Where the nightly schedule stages its from-source build of a commit, readable anonymously
src_staged_url() {
    local commit="$1"
    echo "https://julialang-ephemeral-ci.s3.amazonaws.com/bin/${commit}/julia-${commit:0:10}-${OS}-${ARCH}.tar.gz"
}

# Download the from-source build of the merge-base to $1, and set MERGE_BASE and
# BASE_BRANCH: the nightly's build of that commit, or else the one this build's merge-base
# job built
fetch_src_merge_base() {
    local out="$1" dir
    MERGE_BASE="$(buildkite-agent meta-data get src-merge-base)"
    BASE_BRANCH="$(buildkite-agent meta-data get src-merge-base-branch)"
    if curl -fsSL --retry 3 -o "${out}" "$(src_staged_url "${MERGE_BASE}")"; then
        echo "downloaded the nightly from-source build of ${MERGE_BASE:0:10}"
        return 0
    fi
    # A tagged merge-base's tarball is named by its version rather than its commit
    dir="$(mktemp -d)"
    buildkite-agent artifact download --step "build_${TRIPLET}_merge_base" "julia-*-${OS}-${ARCH}.tar.gz" "${dir}" || return 1
    mv "${dir}"/julia-*-"${OS}-${ARCH}".tar.gz "${out}"
    echo "downloaded this build's from-source build of ${MERGE_BASE:0:10}"
}
