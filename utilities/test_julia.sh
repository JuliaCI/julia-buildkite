#!/usr/bin/env bash

# This script performs the basic steps needed to test Julia previously
# built and uploaded as a `.tar.gz`.
# It requires the following environment variables to be defined:
#  - TRIPLET
#  - USE_RR
set -euo pipefail

# First, get things like `SHORT_COMMIT`, `JULIA_CPU_TARGET`, `UPLOAD_TARGETS`, etc...
# shellcheck source=SCRIPTDIR/build_envs.sh
source .buildkite/utilities/build_envs.sh

echo "--- Print kernel version"
uname -a

# Usually, we download the build artifacts.  However, if we're running inside of the
# `bughunt` tool, for instance, we may already have a Julia unpacked for us.
if [[ ! -d "${JULIA_INSTALL_DIR}/bin" ]]; then
    # Note that we pass `--step` to prevent ambiguities between downloading the artifacts
    # uploaded by the `build_*` steps vs. the `upload_*` steps.  Normally, testing must occur
    # first, however in the event of a soft-fail test, we can re-run a test after a successful
    # upload has occured.
    echo "--- Download build artifacts"
    buildkite-agent artifact download --step "build_${TRIPLET}" "${UPLOAD_FILENAME}.tar.gz" .

    echo "--- Extract build artifacts"
    tar xzf "${UPLOAD_FILENAME}.tar.gz" "${JULIA_INSTALL_DIR}/"
fi

# If we're on macOS, we need to re-sign the downloaded tarball so it will
# execute on this machine
if [[ "${OS}" == "macos" ]]; then
    echo "--- [mac] Codesigning"
    .buildkite/utilities/macos/codesign.sh "${JULIA_INSTALL_DIR}"
    echo "--- [mac] Update checksums for stdlib cachefiles after codesigning"
    JULIA_DEBUG=all "${JULIA_INSTALL_DIR}/bin/julia" .buildkite/utilities/update_stdlib_pkgimage_checksums.jl
fi


echo "--- Print Julia version info"
${JULIA_BINARY} -e 'using InteractiveUtils; InteractiveUtils.versioninfo()'


echo "--- Set some environment variables"
# Prevent OpenBLAS from spinning up a large number of threads on our big machines
export OPENBLAS_NUM_THREADS="${JULIA_CPU_THREADS}"
export JULIA_TEST_IS_BASE_CI="true"
unset JULIA_DEPOT_PATH
unset JULIA_PKG_SERVER

if [[ "${OS}" != "windows" ]]; then
    # Tell timeout.jl to detach the process group, so we get core dumps from
    # each process.
    export JL_TERM_DETACH="true"
    # On timeout, SIGTERM the test driver before core-dumping it, so that it
    # can core-dump the (detached, otherwise unreachable) workers that are
    # still running tests.  See the escalation pipeline in timeout.jl.
    export JL_TERM_SIGTERM="true"
fi

# Make sure that temp files and temp directories are created in a location that is
# backed by real storage, and not by a tmpfs, as some tests don't like that on Linux
if [[ "${OS}" == "linux" ]]; then
    TMPDIR="$(pwd)/tmp"
    export TMPDIR
    mkdir -p "${TMPDIR}"
fi

#Always set the max rss so that if tests add large global variables (which they do) we don't make the GC's life too hard
export JULIA_TEST_MAXRSS_MB=3800

if [[ "${ARCH}" == "i686" ]]; then
    # Assume that we only have 3.5GB available to a single process, and that a single
    # test can take up to 2GB of RSS.  This means that we should instruct the test
    # framework to restart any worker that comes into a test set with 1.5GB of RSS.
    export JULIA_TEST_MAXRSS_MB=1536
fi

# By default, we'll run all tests and skip nothing
TESTS_TO_RUN=( "all" )
TESTS_TO_SKIP=()

# If we're running inside of `rr`, limit the number of threads and split our tests
if [[ "${USE_RR-}" == "rr" ]] || [[ "${USE_RR-}" == "rr-net" ]]; then
    export JULIA_CMD_FOR_TESTS="${JULIA_BINARY} .buildkite/utilities/rr/rr_capture.jl ${JULIA_BINARY}"
    export NCORES_FOR_TESTS="parse(Int, ENV[\"JULIA_RRCAPTURE_NUM_CORES\"])"
    export JULIA_NUM_THREADS=1

    # Do not run Pkg or JuliaLowering stdlib tests on rr.
    TESTS_TO_SKIP+=( Pkg JuliaLowering_stdlibs )

    # rr: all tests EXCEPT the network-related tests
    # rr-net: ONLY the network-related tests
    NETWORK_RELATED_TESTS=( Artifacts Downloads download LazyArtifacts LibGit2/online )
    if [[ "${USE_RR-}" == "rr" ]]; then
        TESTS_TO_SKIP+=( "${NETWORK_RELATED_TESTS[@]}" )
    elif [[ "${USE_RR-}" == "rr-net" ]]; then
        # Overwrite TESTS_TO_RUN, to get rid of default `"all"`
        TESTS_TO_RUN=( "${NETWORK_RELATED_TESTS[@]}" )
    fi
elif [[ "${USE_RR-}" == "" ]]; then
    # Run inside of a timeout
    export JULIA_CMD_FOR_TESTS="${JULIA_BINARY} .buildkite/utilities/timeout.jl ${JULIA_BINARY}"
    export NCORES_FOR_TESTS="${JULIA_CPU_THREADS}"
    export JULIA_NUM_THREADS="${JULIA_CPU_THREADS}"
    export JULIA_NUM_THREADS=1 # TODO: delete this line once we support running CI with threads

    # We don't run `Pkg` on any 32-bit platforms, since it uses too much memory
    if [[ "${ARCH}" == i686 ]] || [[ "${ARCH}" == "armv7l" ]]; then
        TESTS_TO_SKIP+=( Pkg )
    fi

    if [[ "${i686_GROUP-}" == "no-net" ]]; then
        # We skip running Downloads on the `no-net` runner`
        TESTS_TO_SKIP+=( Downloads )
    elif [[ "${i686_GROUP-}" == "net" ]]; then
        # We run only Downloads on the `net` runner
        TESTS_TO_RUN=( "Downloads" )
        TESTS_TO_SKIP=()
    elif [[ "${i686_GROUP-}" == "" ]]; then
        :
    fi

    # Disable `Profile` on win32, as our backtraces are extremely slow.
    if [[ "${OS} ${ARCH}" == "windows i686" ]]; then
        TESTS_TO_SKIP+=( "Profile" )
    fi
else
    echo "ERROR: invalid value for USE_RR: ${USE_RR-}"
    exit 1
fi

# Determine which external stdlib tests to skip based on branch and version file changes
EXTERNAL_STDLIB_SKIP_LIST=()

branch="${BUILDKITE_BRANCH:-unknown}"
pipeline="${BUILDKITE_PIPELINE_SLUG:-unknown}"
echo "Branch is: ${branch}"
echo "Pipeline is: ${pipeline}"
# We test all external stdlibs in the following cases:
if [[ "${branch}" == release-* ]] || \
   [[ "${branch}" == backports-release-* ]] || \
   [[ "${BUILDKITE_SOURCE:-}" == "schedule" ]]; then
    echo "On important branch '${branch}' or pipeline '${pipeline}': running all external stdlib tests"
else
    # Skip all external stdlibs that aren't in CHANGED_STDLIB_VERSIONS
    for stdlib_name in ${EXTERNAL_STDLIB_NAMES}; do
        if [[ "${CHANGED_STDLIB_VERSIONS:-}" != *"$stdlib_name"* ]]; then
            EXTERNAL_STDLIB_SKIP_LIST+=("$stdlib_name")
        fi
    done

    if [[ -n "${CHANGED_STDLIB_VERSIONS:-}" ]]; then
        echo "Skipping external stdlib tests for: ${EXTERNAL_STDLIB_SKIP_LIST[*]}"
    fi
fi

# Add external stdlibs to skip to the main skip list
TESTS_TO_SKIP+=("${EXTERNAL_STDLIB_SKIP_LIST[@]}")

# Build our `TESTS` string
# `--ci` asserts that networking is available
if [[ "${#TESTS_TO_SKIP[@]}" -gt 0 ]]; then
    export TESTS="${TESTS_TO_RUN[*]} --ci --skip ${TESTS_TO_SKIP[*]}"
else
    export TESTS="${TESTS_TO_RUN[*]} --ci"
fi

# Auto-set timeout to buildkite timeout minus 45m for most users
export JL_TEST_TIMEOUT="$((${BUILDKITE_TIMEOUT:?}-45))m"

echo "--- Print the list of test sets, and other useful environment variables"
echo "JULIA_CMD_FOR_TESTS is:    ${JULIA_CMD_FOR_TESTS:?}"
echo "JULIA_NUM_THREADS is:      ${JULIA_NUM_THREADS:?}"
echo "JULIA_IMAGE_THREADS is:    ${JULIA_IMAGE_THREADS:-<unset>}"
echo "NCORES_FOR_TESTS is:       ${NCORES_FOR_TESTS:?}"
echo "OPENBLAS_NUM_THREADS is:   ${OPENBLAS_NUM_THREADS:?}"
echo "TESTS is:                  ${TESTS:?}"
echo "USE_RR is:                 ${USE_RR-}"
echo "JL_TEST_TIMEOUT is:        ${JL_TEST_TIMEOUT}"
if [[ "${#EXTERNAL_STDLIB_SKIP_LIST[@]}" -gt 0 ]]; then
    echo "EXTERNAL_STDLIBS_SKIPPED:  ${EXTERNAL_STDLIB_SKIP_LIST[*]}"
fi

# Show our core dump file pattern and size limit if we're going to be recording them
if [[ -z "${USE_RR-}" ]]; then
    ulimit -c unlimited
    if [[ "${OS}" == linux* || "${OS}" == "musl" ]]; then
        echo "Core dump pattern:         $(cat /proc/sys/kernel/core_pattern)"
    elif [[ "${OS}" == "macos" || "${OS}" == "freebsd" ]]; then
        echo "Core dump pattern:         $(sysctl -n kern.corefile)"
    fi
    echo "Core dump size limit:      $(ulimit -c)"
fi

# Begin with "+++" => Expand test group by default
echo "+++ Run the Julia test suite"
# set -e; requires us using if to check the exit status
if ${JULIA_CMD_FOR_TESTS:?} --color=yes -e "Base.runtests(\"${TESTS:?}\"; ncores = ${NCORES_FOR_TESTS:?})"; then
  exitVal=0
else
  exitVal=1
fi

echo "--- Upload results.json report"
if compgen -G "${JULIA_INSTALL_DIR}/share/julia/test/results*.json"; then
    # Keep the raw results around as a buildkite artifact (for humans).
    (cd "${JULIA_INSTALL_DIR}/share/julia/test"; tar -czf results.tar.gz results*.json && buildkite-agent artifact upload "results.tar.gz")

    # Push the results to Buildkite Test Analytics directly from this job
    # (no relay job, no artifact handoff). The bearer token is fetched from
    # SSM Parameter Store with this job's OIDC identity; no static secrets
    # exist in CI config. Best-effort: never fail the test job over it.
    # Only julia-ci holds bearer tokens: PR builds and the julia-buildkite
    # self-test run attacker-controlled code in this very job, so skip there.
    if [[ "${BUILDKITE_PIPELINE_SLUG:-}" != "julia-ci" ]]; then
        echo "No analytics token available to this pipeline, skipping Test Analytics upload"
    elif command -v aws >/dev/null 2>&1; then
        (
            # Subshell so the OIDC credential env doesn't outlive the upload.
            # shellcheck source=SCRIPTDIR/aws_oidc.sh
            source .buildkite/utilities/aws_oidc.sh tokens
            export AWS_EC2_METADATA_DISABLED=true
            BUILDKITE_ANALYTICS_TOKEN="$(aws ssm get-parameter --with-decryption \
                --name /julia-ci/tokens/buildkite_analytics_token \
                --query Parameter.Value --output text)"

            shopt -s nullglob
            for file in "${JULIA_INSTALL_DIR}"/share/julia/test/results*.json; do
                echo "Uploading ${file} to Test Analytics..."
                # We can't use the test-collector plugin because it doesn't
                # let us attach more than one results file to a job.
                curl \
                  -X POST \
                  --silent \
                  --show-error \
                  --max-time 300 \
                  -H "Authorization: Token token=\"${BUILDKITE_ANALYTICS_TOKEN}\"" \
                  -F "data=@\"${file}\"" \
                  -F "format=json" \
                  -F "run_env[CI]=buildkite" \
                  -F "run_env[key]=\"${BUILDKITE_BUILD_ID}\"" \
                  -F "run_env[url]=\"${BUILDKITE_BUILD_URL}\"" \
                  -F "run_env[branch]=\"${BUILDKITE_BRANCH}\"" \
                  -F "run_env[commit_sha]=\"${BUILDKITE_COMMIT}\"" \
                  -F "run_env[number]=\"${BUILDKITE_BUILD_NUMBER}\"" \
                  -F "run_env[job_id]=\"${BUILDKITE_JOB_ID}\"" \
                  -F "run_env[message]=\"${BUILDKITE_MESSAGE}\"" \
                  https://analytics-api.buildkite.com/v1/uploads
                echo ""
            done
        ) || echo "WARNING: Test Analytics upload failed (non-fatal)"
    else
        echo "aws CLI not available; skipping Test Analytics upload"
    fi
else
    echo "no JSON results files found"
fi
echo "--- Done"

if [[ "${exitVal}" -ne 0 ]] && [[ "${OS}" == linux* || "${OS}" == "musl" || "${OS}" == "freebsd" ]]; then
    echo "--- Upload dmesg to diagnose potential OOM killer activity"
    dmesg > dmesg.log || true
    if [[ -s dmesg.log ]]; then
        buildkite-agent artifact upload dmesg.log || true
    fi
fi

exit $exitVal
