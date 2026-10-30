#!/usr/bin/env bash
# Runtime benchmark job: runs the julia-ci-benchmarks suite (SIMD, scheduler, GC, compiler,
# ...) on the julia this build produced. On a pull request the master build of the
# merge-base is fetched too, the two are measured interleaved (ABBA, one process per
# block, category and arm) and compared, and robust regressions fail the job. On master
# and release branches the build is measured alone and the data kept as Buildkite
# artifacts for perf.julialang.org. See README.md alongside this script.
set -euo pipefail

# shellcheck source=SCRIPTDIR/../build_envs.sh
source .buildkite/utilities/build_envs.sh

if [[ "${OS%opt}" != "macos" ]]; then
    echo "The runtime benchmark job only knows how to re-sign and run macOS builds (got ${TRIPLET})" >&2
    exit 1
fi

RTB_DIR="$(pwd)/runtime-benchmarks"
# The suite is checked out at job time; RTB_SUITE_REF may be a branch, tag or commit sha
RTB_SUITE_REPO="${RTB_SUITE_REPO:-https://github.com/JuliaCI/julia-ci-benchmarks.git}"
RTB_SUITE_REF="${RTB_SUITE_REF:-main}"
RTB_BLOCKS="${RTB_BLOCKS:-3}"
RTB_THREADS="${RTB_THREADS:-4}"
# Restrict to some categories (space separated); empty runs them all
RTB_CATEGORIES="${RTB_CATEGORIES:-}"
# Where julia-ci stages its tarballs, the promoted nightlies, and julia-pr's staging for
# stacked pull requests; the same lookup as the TTFX job
RTB_BASE_STAGING_BUCKET="${RTB_BASE_STAGING_BUCKET:-julialang-ephemeral-ci}"
RTB_BASE_PR_STAGING_BUCKET="${RTB_BASE_PR_STAGING_BUCKET:-julialang-ephemeral-pr}"
RTB_NIGHTLIES_URL="${RTB_NIGHTLIES_URL:-https://julialangnightlies-s3.julialang.org}"
RTB_BASE_WAIT_MINUTES="${RTB_BASE_WAIT_MINUTES:-20}"
# Hardware counters: auto picks kperf when the agent runs as root, else thread_selfcounts
export CIBENCH_COUNTERS="${CIBENCH_COUNTERS:-auto}"

rm -rf "${RTB_DIR}"
mkdir -p "${RTB_DIR}"

# Whatever was measured is kept, even when the job fails part way
# shellcheck disable=SC2317,SC2329  # invoked by the EXIT trap
upload_results() {
    echo "--- Upload results"
    local pattern
    for pattern in "runtime-benchmarks/out/*.json" "runtime-benchmarks/out/*.md" "runtime-benchmarks/out/logs/*.log" \
                   "runtime-benchmarks/out/confirm/*.json" "runtime-benchmarks/out/confirm/*.md" "runtime-benchmarks/out/confirm/logs/*.log" \
                   "runtime-benchmarks/*.log"; do
        if compgen -G "${pattern}" >/dev/null; then
            buildkite-agent artifact upload "${pattern}" || true
        fi
    done
}
trap upload_results EXIT

ARMS_DIR="${RTB_DIR}/arms"

# Extract a tarball to ${ARMS_DIR}/<name>, re-sign it and repair the stdlib pkgimage
# checksums the signing invalidated, as test_julia.sh and the TTFX job do
install_julia() {
    local tarball="$1" name="$2"
    local dir="${ARMS_DIR}/${name}"
    mkdir -p "${dir}"
    tar -C "${dir}" --strip-components=1 -zxf "${tarball}"
    .buildkite/utilities/macos/codesign.sh "${dir}"
    JULIA_DEBUG=all "${dir}/bin/julia" .buildkite/utilities/update_stdlib_pkgimage_checksums.jl
    echo "${name}: $("${dir}/bin/julia" --startup-file=no -e 'print(VERSION, "  ", Base.GIT_VERSION_INFO.commit)')"
}

BASE_OS="${OS%opt}"
fetch_base_build() {
    local commit="$1" out="$2"
    local short="${commit:0:${SHORT_COMMIT_LENGTH}}"
    local name="julia-${short}-${BASE_OS}-${ARCH}.tar.gz"
    local url
    for url in "https://${RTB_BASE_STAGING_BUCKET}.s3.amazonaws.com/${S3_BUCKET_PREFIX}/${commit}/${name}" \
               "${RTB_NIGHTLIES_URL}/${S3_BUCKET_PREFIX}/${BASE_OS}/${ARCH}/${MAJMIN}/${name}" \
               "https://${RTB_BASE_PR_STAGING_BUCKET}.s3.amazonaws.com/${S3_BUCKET_PREFIX}/${commit}/${name}"; do
        if curl -fsSL --retry 3 -o "${out}" "${url}"; then
            echo "downloaded ${url}"
            return 0
        fi
    done
    return 1
}

# The nearest first-parent ancestor of a commit (itself included) that julia-ci built;
# Buildkite ignores [ci skip] commits
nearest_built_commit() {
    git rev-list --first-parent --max-count=1 --invert-grep -E \
        --grep='\[(ci[ -]skip|skip[ -]ci)\]' "$1"
}

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
RTB_GITHUB_REPO="${RTB_GITHUB_REPO:-$(github_repo)}"

echo "--- Download the julia build under test (${SHORT_COMMIT})"
buildkite-agent artifact download --step "build_${TRIPLET}" "${UPLOAD_FILENAME}.tar.gz" .
install_julia "${UPLOAD_FILENAME}.tar.gz" head
HEAD_JULIA="${ARMS_DIR}/head/bin/julia"

MODE="standalone"
ARMS=( "--arm=head=${HEAD_JULIA}" )
MERGE_BASE=""
if [[ "${BUILDKITE_PIPELINE_SLUG:-}" == "julia-pr" && "${BUILDKITE_PULL_REQUEST:-false}" != "false" ]]; then
    BASE_BRANCH="${BUILDKITE_PULL_REQUEST_BASE_BRANCH:-master}"
    echo "--- Find the merge-base with ${BASE_BRANCH}"
    git fetch --no-tags --quiet "${BUILDKITE_REPO}" "refs/heads/${BASE_BRANCH}"
    MERGE_BASE="$(git merge-base HEAD FETCH_HEAD)"
    echo "merge-base: ${MERGE_BASE}"
elif [[ "${BUILDKITE_PIPELINE_SLUG:-}" == julia-buildkite* ]]; then
    # Self-test: the build against itself. Two builds differ in code placement even when
    # nothing they run changed (and this pipeline's builds differ from julia-ci's), so any
    # verdict here would not be about the harness. Against itself, every flag is a bug.
    echo "--- Self-test: comparing the build against itself"
    MODE="compare"
    ARMS=( "--arm=base=${HEAD_JULIA}" "--arm=head=${HEAD_JULIA}" )
fi
if [[ -n "${MERGE_BASE}" ]]; then
    MODE="compare"
    built="$(nearest_built_commit "${MERGE_BASE}")"
    if [[ -n "${built}" && "${built}" != "${MERGE_BASE}" ]]; then
        echo "${MERGE_BASE:0:10} is a [ci skip] commit, never built; comparing against ${built}"
        MERGE_BASE="${built}"
    fi
    echo "--- Fetch the ${BASE_BRANCH} build of the merge-base"
    # The merge-base may still be building; wait for it as the TTFX job does, asking
    # GitHub for its build state every fifth minute
    poll=0
    state="pending"
    deadline=$(( $(date +%s) + RTB_BASE_WAIT_MINUTES * 60 ))
    until fetch_base_build "${MERGE_BASE}" "${RTB_DIR}/base.tar.gz"; do
        if (( poll % 5 == 0 )); then
            state="$("${HEAD_JULIA}" --startup-file=no .buildkite/utilities/ttfx/ttfx_build_state.jl "${RTB_GITHUB_REPO}" "${MERGE_BASE}")"
        fi
        poll=$(( poll + 1 ))
        case "${state}" in
            pending|unknown)
                if (( $(date +%s) >= deadline )); then
                    echo "^^^ +++"
                    echo "The ${BASE_BRANCH} build of the merge-base ${MERGE_BASE:0:10} was not ready after ${RTB_BASE_WAIT_MINUTES} minutes (state: ${state}); retry this job once it is" >&2
                    exit 1
                fi
                echo "$(date -u +%H:%M:%S)  build of ${MERGE_BASE:0:10} not staged yet (${state}); waiting"
                sleep 60
                ;;
            *)
                echo "^^^ +++"
                echo "No ${BASE_BRANCH} build of the merge-base ${MERGE_BASE:0:10} to compare against (its build: ${state})" >&2
                exit 1
                ;;
        esac
    done
    install_julia "${RTB_DIR}/base.tar.gz" base
    ARMS=( "--arm=base=${ARMS_DIR}/base/bin/julia" "--arm=head=${HEAD_JULIA}" )
fi

echo "--- Check out the benchmark suite (${RTB_SUITE_REPO} @ ${RTB_SUITE_REF})"
# init + fetch rather than clone --branch, so the ref may also be a commit sha
git init --quiet "${RTB_DIR}/suite"
git -C "${RTB_DIR}/suite" fetch --quiet --depth 1 "${RTB_SUITE_REPO}" "${RTB_SUITE_REF}"
git -C "${RTB_DIR}/suite" checkout --quiet FETCH_HEAD
echo "suite commit: $(git -C "${RTB_DIR}/suite" rev-parse HEAD)"

echo "--- Benchmark (${MODE})"
bench_args=( --blocks="${RTB_BLOCKS}" --threads="${RTB_THREADS}" --out="${RTB_DIR}/out" )
for c in ${RTB_CATEGORIES}; do
    bench_args+=( --category="${c}" )
done
# The orchestrator only spawns processes, so the build under test can run it; the suite
# needs no packages
set +e
"${HEAD_JULIA}" --startup-file=no "${RTB_DIR}/suite/bench.jl" "${ARMS[@]}" "${bench_args[@]}" 2>&1 | tee "${RTB_DIR}/benchmark.log"
bench_status="${PIPESTATUS[0]}"
set -e

echo "+++ Report"
PERF_REF=""
if [[ "${BUILDKITE_PIPELINE_SLUG:-}" == "julia-pr" && "${BUILDKITE_PULL_REQUEST:-false}" != "false" ]]; then
    PERF_REF="${BUILDKITE_PULL_REQUEST}"
elif [[ "${BUILDKITE_PIPELINE_SLUG:-}" == "julia-ci" ]]; then
    PERF_REF="$(git rev-parse HEAD)"
fi
compare_args=( "${RTB_DIR}/out" )
if [[ -n "${PERF_REF}" ]]; then
    compare_args+=( --perf-url="https://perf.julialang.org/?tab=commit&c=${PERF_REF}" )
fi
set +e
"${HEAD_JULIA}" --startup-file=no "${RTB_DIR}/suite/compare.jl" "${compare_args[@]}"
verdict=$?
set -e

# A regression on a pull request is measured again with a control arm: the master build
# before the merge-base. Two master builds differ in code placement as well, so a change
# stands only when head also differs that way from the control.
if [[ "${verdict}" == 1 && "${BUILDKITE_PIPELINE_SLUG:-}" == "julia-pr" && -n "${MERGE_BASE}" ]]; then
    echo "--- Confirm the regressions against the master build before the merge-base"
    flagged="$("${HEAD_JULIA}" --startup-file=no "${RTB_DIR}/suite/tools/flagged.jl" "${RTB_DIR}/out")"
    flagged_categories="$(sed -n 1p <<< "${flagged}")"
    flagged_filter="$(sed -n 2p <<< "${flagged}")"
    control="$(nearest_built_commit "${MERGE_BASE}^" 2>/dev/null || true)"
    if [[ -z "${flagged_filter}" || -z "${control}" ]] || ! fetch_base_build "${control}" "${RTB_DIR}/control.tar.gz"; then
        echo "No control build to confirm against; keeping the verdict"
    else
        install_julia "${RTB_DIR}/control.tar.gz" control
        confirm_args=( --blocks="${RTB_BLOCKS}" --threads="${RTB_THREADS}" --out="${RTB_DIR}/out/confirm" --filter="${flagged_filter}" )
        for c in ${flagged_categories}; do
            confirm_args+=( --category="${c}" )
        done
        set +e
        "${HEAD_JULIA}" --startup-file=no "${RTB_DIR}/suite/bench.jl" "${ARMS[0]}" "--arm=control=${ARMS_DIR}/control/bin/julia" "${ARMS[1]}" \
            "${confirm_args[@]}" 2>&1 | tee -a "${RTB_DIR}/benchmark.log"
        "${HEAD_JULIA}" --startup-file=no "${RTB_DIR}/suite/compare.jl" "${RTB_DIR}/out/confirm" --control=control "${compare_args[@]:1}"
        confirmed=$?
        set -e
        # An incomplete confirmation confirms nothing; the first verdict stands
        if [[ "${confirmed}" != 2 ]]; then
            verdict="${confirmed}"
            mv "${RTB_DIR}/out/report.md" "${RTB_DIR}/out/report-first.md"
            {
                cat "${RTB_DIR}/out/confirm/report.md"
                printf '\n<details><summary>The comparison that flagged them</summary>\n\n'
                cat "${RTB_DIR}/out/report-first.md"
                printf '\n</details>\n'
            } > "${RTB_DIR}/out/report.md"
        fi
    fi
fi
# The run page draws this job's artifacts (every benchmark's change, its samples,
# instructions and allocations); the site reads them from Buildkite when first opened
RUN_URL="https://perf.julialang.org/runtime-run?pipeline=${BUILDKITE_PIPELINE_SLUG:-}&build=${BUILDKITE_BUILD_NUMBER:-}&job=${BUILDKITE_JOB_ID:-}"
if [[ -f "${RTB_DIR}/out/report.md" ]]; then
    printf '\n[Every benchmark of this run, with its samples, on perf.julialang.org](%s)\n' "${RUN_URL}" >> "${RTB_DIR}/out/report.md"
fi
echo "Run page: ${RUN_URL}"
annotate() {
    buildkite-agent annotate --context "runtime-benchmarks-${TRIPLET}" --style "$1" < "${RTB_DIR}/out/report.md" || true
}
# A failed benchmark process (bench.jl exit 2) fails the job after the report is shown
case "${verdict}" in
    0)
        if [[ "${MODE}" == "standalone" || "${bench_status}" != 0 ]]; then
            annotate "info"
        fi
        ;;
    3)
        annotate "success"
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
if [[ "${bench_status}" != 0 ]]; then
    echo "Some benchmark processes failed (see the report and runtime-benchmarks/out/logs)" >&2
    exit "${bench_status}"
fi
