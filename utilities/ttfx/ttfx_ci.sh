#!/usr/bin/env bash
# TTFX benchmark job: measures the julia this build produced on the Julia-TTFX-Snippets
# tasks (precompile, load, run). On a pull request the master build of the merge-base is
# fetched too, the two are measured interleaved (ABBA) and compared, and robust
# regressions fail the job. On master and release branches the build is measured alone
# and the data kept as Buildkite artifacts. See README.md alongside this script.
set -euo pipefail

# shellcheck source=SCRIPTDIR/../build_envs.sh
source .buildkite/utilities/build_envs.sh

if [[ "${OS}" != "macos" ]]; then
    echo "The TTFX job only knows how to re-sign and run macOS builds (got ${TRIPLET})" >&2
    exit 1
fi

TTFX_UTILS=".buildkite/utilities/ttfx"
TTFX_DIR="$(pwd)/ttfx"
TTFX_SNIPPETS_REPO="${TTFX_SNIPPETS_REPO:-https://github.com/tecosaur/Julia-TTFX-Snippets.git}"
TTFX_SNIPPETS_REF="${TTFX_SNIPPETS_REF:-main}"
TTFX_BLOCKS="${TTFX_BLOCKS:-2}"
TTFX_REPEATS="${TTFX_REPEATS:-3}"
# Tasks not to run; "none" runs every task in the snippets checkout
TTFX_EXCLUDE="${TTFX_EXCLUDE:-${TTFX_UTILS}/exclude.txt}"
# The base build comes from where julia-ci stages its tarballs, or from the promoted
# nightlies once the staged object has expired
TTFX_BASE_STAGING_BUCKET="${TTFX_BASE_STAGING_BUCKET:-julialang-ephemeral-ci}"
TTFX_NIGHTLIES_URL="${TTFX_NIGHTLIES_URL:-https://julialangnightlies-s3.julialang.org}"
# How long to wait for the merge-base's build (a macOS aarch64 build takes about 18
# minutes), and how many commits to step back past ones whose build failed, was never
# started, or is still not ready when the wait runs out
TTFX_BASE_WAIT_MINUTES="${TTFX_BASE_WAIT_MINUTES:-20}"
TTFX_BASE_LOOKBACK="${TTFX_BASE_LOOKBACK:-10}"

rm -rf "${TTFX_DIR}"
mkdir -p "${TTFX_DIR}"

# Whatever was measured is kept, even when the job fails part way
# shellcheck disable=SC2317,SC2329  # invoked by the EXIT trap
upload_results() {
    echo "--- Upload results"
    local pattern
    for pattern in "ttfx/*.json" "ttfx/*.md" "ttfx/*.log" "ttfx/logs/*.log"; do
        if compgen -G "${pattern}" >/dev/null; then
            buildkite-agent artifact upload "${pattern}" || true
        fi
    done
}
trap upload_results EXIT

# Extract a tarball to ${TTFX_DIR}/<name>, re-sign it and repair the stdlib pkgimage
# checksums the signing invalidated, exactly as test_julia.sh does for the build under
# test; both arms go through this so neither carries the cost of stale stdlib caches.
install_julia() {
    local tarball="$1" name="$2"
    local dir="${TTFX_DIR}/${name}"
    mkdir -p "${dir}"
    tar -C "${dir}" --strip-components=1 -zxf "${tarball}"
    .buildkite/utilities/macos/codesign.sh "${dir}"
    JULIA_DEBUG=all "${dir}/bin/julia" .buildkite/utilities/update_stdlib_pkgimage_checksums.jl
    echo "${name}: $("${dir}/bin/julia" --startup-file=no -e 'print(VERSION, "  ", Base.GIT_VERSION_INFO.commit)')"
}

# The base tarball of a commit: staged by julia-ci below the commit sha, or already promoted
# to the nightlies. Both are readable anonymously.
fetch_base_build() {
    local commit="$1" out="$2"
    local short="${commit:0:${SHORT_COMMIT_LENGTH}}"
    local name="julia-${short}-${OS}-${ARCH}.tar.gz"
    local url
    for url in "https://${TTFX_BASE_STAGING_BUCKET}.s3.amazonaws.com/${S3_BUCKET_PREFIX}/${commit}/${name}" \
               "${TTFX_NIGHTLIES_URL}/${S3_BUCKET_PREFIX}/${OS}/${ARCH}/${MAJMIN}/${name}"; do
        if curl -fsSL --retry 3 -o "${out}" "${url}"; then
            echo "downloaded ${url}"
            return 0
        fi
    done
    return 1
}

# JuliaLang/julia, from https://github.com/JuliaLang/julia.git or git@github.com:JuliaLang/julia.git.
# The self-test pipeline's BUILDKITE_REPO is this repository while the commits it builds
# are julia's, so anything that is not a julia repository falls back to upstream.
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
TTFX_GITHUB_REPO="${TTFX_GITHUB_REPO:-$(github_repo)}"

echo "--- Download the julia build under test (${SHORT_COMMIT})"
buildkite-agent artifact download --step "build_${TRIPLET}" "${UPLOAD_FILENAME}.tar.gz" .
install_julia "${UPLOAD_FILENAME}.tar.gz" head
HEAD_JULIA="${TTFX_DIR}/head/bin/julia"

MODE="standalone"
ARMS=( "head=${TTFX_DIR}/head" )
BASE_NOTE=""
# Only julia-pr builds a pull request of julia itself. The self-test pipeline's builds are
# pull requests of this repository measuring a julia master commit; there the parent
# commit stands in for the merge-base, so the comparison path is exercised too.
MERGE_BASE=""
if [[ "${BUILDKITE_PIPELINE_SLUG:-}" == "julia-pr" && "${BUILDKITE_PULL_REQUEST:-false}" != "false" ]]; then
    BASE_BRANCH="${BUILDKITE_PULL_REQUEST_BASE_BRANCH:-master}"
    echo "--- Find the merge-base with ${BASE_BRANCH}"
    git fetch --no-tags --quiet "${BUILDKITE_REPO}" "refs/heads/${BASE_BRANCH}"
    MERGE_BASE="$(git merge-base HEAD FETCH_HEAD)"
    echo "merge-base: ${MERGE_BASE}"
elif [[ "${BUILDKITE_PIPELINE_SLUG:-}" == julia-buildkite* ]]; then
    BASE_BRANCH="master"
    MERGE_BASE="$(git rev-parse HEAD^)"
    echo "--- Self-test: comparing against the parent commit ${MERGE_BASE}"
fi
if [[ -n "${MERGE_BASE}" ]]; then
    MODE="compare"

    echo "--- Fetch the ${BASE_BRANCH} build of the merge-base"
    # julia-ci stages the tarball as soon as the merge-base's build job finishes, so a
    # merge-base pushed recently may still be building: wait for it, up to
    # TTFX_BASE_WAIT_MINUTES, since this job holds a macOS agent the whole time. When
    # that commit's build failed, was never started, or is still not ready when the
    # wait runs out, the previous commit on the branch is tried instead. The build state
    # comes from the commit statuses on GitHub, asked every fifth minute to stay well
    # inside the anonymous API rate limit.
    commit="${MERGE_BASE}"
    steps_back=0
    poll=0
    state="pending"
    reason=""
    deadline=$(( $(date +%s) + TTFX_BASE_WAIT_MINUTES * 60 ))
    BASE_COMMIT=""
    while [[ -z "${BASE_COMMIT}" ]]; do
        if fetch_base_build "${commit}" "${TTFX_DIR}/base.tar.gz"; then
            BASE_COMMIT="${commit}"
            break
        fi
        if (( poll % 5 == 0 )); then
            state="$("${HEAD_JULIA}" --startup-file=no "${TTFX_UTILS}/ttfx_build_state.jl" "${TTFX_GITHUB_REPO}" "${commit}")"
        fi
        poll=$(( poll + 1 ))
        case "${state}" in
            pending|unknown)
                if (( $(date +%s) < deadline )); then
                    echo "$(date -u +%H:%M:%S)  build of ${commit:0:10} not staged yet (${state}); waiting"
                    sleep 60
                    continue
                fi
                why="its build was not ready after ${TTFX_BASE_WAIT_MINUTES} minutes"
                ;;
            *)
                # success with nothing to fetch: expired from both locations; failure or
                # none: not coming
                why="its build: ${state}"
                ;;
        esac
        steps_back=$(( steps_back + 1 ))
        if (( steps_back > TTFX_BASE_LOOKBACK )); then
            echo "^^^ +++"
            echo "No ${BASE_BRANCH} build within ${TTFX_BASE_LOOKBACK} commits before the merge-base ${MERGE_BASE:0:10}; rebase the pull request" >&2
            exit 1
        fi
        [[ -n "${reason}" ]] || reason="${why}"
        echo "build of ${commit:0:10}: ${why}; trying its parent"
        commit="$(git rev-parse "${commit}^")"
        poll=0
    done
    if [[ "${BASE_COMMIT}" == "${MERGE_BASE}" ]]; then
        BASE_NOTE="the ${BASE_BRANCH} build of the merge-base"
    else
        BASE_NOTE="${steps_back} commit(s) before the merge-base ${MERGE_BASE:0:10} on ${BASE_BRANCH} (${reason})"
    fi
    install_julia "${TTFX_DIR}/base.tar.gz" base
    ARMS=( "base=${TTFX_DIR}/base" "head=${TTFX_DIR}/head" )
fi

echo "--- Check out the TTFX snippets (${TTFX_SNIPPETS_REPO} @ ${TTFX_SNIPPETS_REF})"
git clone --quiet --depth 1 --branch "${TTFX_SNIPPETS_REF}" "${TTFX_SNIPPETS_REPO}" "${TTFX_DIR}/snippets"
SNIPPETS_COMMIT="$(git -C "${TTFX_DIR}/snippets" rev-parse HEAD)"
echo "snippets commit: ${SNIPPETS_COMMIT}"

echo "--- Benchmark (${MODE})"
exclude_args=()
if [[ "${TTFX_EXCLUDE}" != "none" ]]; then
    exclude_args=( --exclude "${TTFX_EXCLUDE}" )
fi
"${HEAD_JULIA}" --startup-file=no "${TTFX_UTILS}/ttfx_bench.jl" \
    --tasks "${TTFX_DIR}/snippets/tasks" ${exclude_args[@]+"${exclude_args[@]}"} \
    --depot "${TTFX_DIR}/depot" --workdir "${TTFX_DIR}/work" --logdir "${TTFX_DIR}/logs" \
    --blocks "${TTFX_BLOCKS}" --repeats "${TTFX_REPEATS}" \
    --results "${TTFX_DIR}/results.json" --meta "${TTFX_DIR}/results-meta.json" \
    --snippets-commit "${SNIPPETS_COMMIT}" \
    "${ARMS[@]}" 2>&1 | tee "${TTFX_DIR}/benchmark.log"

echo "+++ Report"
compare_args=( --results "${TTFX_DIR}/results.json" --meta "${TTFX_DIR}/results-meta.json"
               --head head --report "${TTFX_DIR}/report.md" --json "${TTFX_DIR}/compare.json"
               --title "TTFX benchmarks: ${TRIPLET}" --url "${BUILDKITE_BUILD_URL:-}#${BUILDKITE_JOB_ID:-}" )
if [[ "${MODE}" == "compare" ]]; then
    compare_args+=( --base base --base-note "${BASE_NOTE}" )
fi
set +e
"${HEAD_JULIA}" --startup-file=no "${TTFX_UTILS}/ttfx_compare.jl" "${compare_args[@]}"
verdict=$?
set -e
# A comparison is annotated only when it has differences to show (exit 3: improvements,
# exit 1: regressions); a clean comparison leaves only the green status and the report
# artifact. The standalone summary is always shown.
annotate() {
    buildkite-agent annotate --context "ttfx-${TRIPLET}" --style "$1" < "${TTFX_DIR}/report.md" || true
}
case "${verdict}" in
    0)
        if [[ "${MODE}" == "standalone" ]]; then
            annotate "info"
        fi
        exit 0
        ;;
    3)
        annotate "success"
        exit 0
        ;;
    1)
        annotate "error"
        exit 1
        ;;
    *)
        annotate "warning"
        exit "${verdict}"
        ;;
esac
