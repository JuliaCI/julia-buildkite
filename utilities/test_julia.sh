#!/bin/bash

# This script performs the basic steps needed to test Julia previously
# built and uploaded as a `.tar.gz`.
# It requires the following environment variables to be defined:
#  - TRIPLET
#  - USE_RR
set -euo pipefail

# First, get things like `SHORT_COMMIT`, `JULIA_CPU_TARGET`, `UPLOAD_TARGETS`, etc...
source .buildkite/utilities/build_envs.sh

# Note that we pass `--step` to prevent ambiguities between downloading the artifacts
# uploaded by the `build_*` steps vs. the `upload_*` steps.  Normally, testing must occur
# first, however in the event of a soft-fail test, we can re-run a test after a successful
# upload has occured.
echo "--- Download build artifacts"
buildkite-agent artifact download --step "build_${TRIPLET}" "${UPLOAD_FILENAME}.tar.gz" .

echo "--- Extract build artifacts"
tar xzf "${UPLOAD_FILENAME}.tar.gz" "${JULIA_INSTALL_DIR}/"

# If we're on macOS, we need to re-sign the downloaded tarball so it will
# execute on this machine
if [[ "${OS}" == "macos" ]]; then
    .buildkite/utilities/macos/codesign.sh "${JULIA_INSTALL_DIR}"
fi


echo "--- Print Julia version info"
${JULIA_BINARY} -e 'using InteractiveUtils; InteractiveUtils.versioninfo()'


echo "--- Set some environment variables"
# Prevent OpenBLAS from spinning up a large number of threads on our big machines
export OPENBLAS_NUM_THREADS="${JULIA_CPU_THREADS}"
unset JULIA_DEPOT_PATH
unset JULIA_PKG_SERVER

# Make sure that temp files and temp directories are created in a location that is
# backed by real storage, and not by a tmpfs, as some tests don't like that on Linux
if [[ "${OS}" == "linux" ]]; then
    export TMPDIR="$(pwd)/tmp"
    mkdir -p ${TMPDIR}
fi

# If we're in a 32-bit userland, try not to use too much memory in a single process,
# as we can (and do) exhaust the address space over the course of our tests.
# Note that we do this here because we run our `i686` tests on `x86_64` hardware.
# Other machines that might benefit from setting an RSS limit unconditionally (such
# as our `armv7l` boards) should set it in their sandboxed-buildkite-agent
# `environment.local.d` directory.
if [[ "${ARCH}" == "i686" ]]; then
    # Assume that we only have 3.5GB available to a single process, and that a single
    # test can take up to 2GB of RSS.  This means that we should instruct the test
    # framework to restart any worker that comes into a test set with 1.5GB of RSS.
    # export JULIA_TEST_MAXRSS_MB=1536
    export JULIA_TEST_MAXRSS_MB=500
fi

# If we're running inside of `rr`, limit the number of threads
if [[ "${USE_RR-}" == "rr" ]] || [[ "${USE_RR-}" == "rr-net" ]]; then
    export JULIA_CMD_FOR_TESTS="${JULIA_BINARY} .buildkite/utilities/rr/rr_capture.jl ${JULIA_BINARY}"
    export NCORES_FOR_TESTS="parse(Int, ENV[\"JULIA_RRCAPTURE_NUM_CORES\"])"
    export JULIA_NUM_THREADS=1

    # rr: all tests EXCEPT the network-related tests
    # rr-net: ONLY the network-related tests
    export NETWORK_RELATED_TESTS="Artifacts Downloads download LazyArtifacts LibGit2/online Pkg"
    if [[ "${USE_RR-}" == "rr" ]]; then
        export TESTS="all --ci --skip ${NETWORK_RELATED_TESTS:?}"
    else
        export TESTS="${NETWORK_RELATED_TESTS:?} --ci"
    fi
else
    export JULIA_CMD_FOR_TESTS="${JULIA_BINARY}"
    export NCORES_FOR_TESTS="${JULIA_CPU_THREADS}"
    export JULIA_NUM_THREADS="${JULIA_CPU_THREADS}"

    # Run all tests; `--ci` asserts that networking is available
    export TESTS="all --ci"
fi

# Auto-set timeout to buildkite timeout minus 45m for most users
echo BUILDKITE_TIMEOUT is ${BUILDKITE_TIMEOUT:?} # TODO: delete this line
export JL_TERM_TIMEOUT="$((${BUILDKITE_TIMEOUT:?}-45))m"
echo JL_TERM_TIMEOUT is ${JL_TERM_TIMEOUT:?} # TODO: delete this line

echo "--- Print the list of test sets, and other useful environment variables"
echo "JULIA_CMD_FOR_TESTS is:    ${JULIA_CMD_FOR_TESTS:?}"
echo "JULIA_NUM_THREADS is:      ${JULIA_NUM_THREADS:?}"
echo "NCORES_FOR_TESTS is:       ${NCORES_FOR_TESTS:?}"
echo "OPENBLAS_NUM_THREADS is:   ${OPENBLAS_NUM_THREADS:?}"
echo "TESTS is:                  ${TESTS:?}"
echo "USE_RR is:                 ${USE_RR-}"
echo "JL_TERM_TIMEOUT is:        ${JL_TERM_TIMEOUT}"

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

echo "--- Run the Julia test suite"
"${JULIA_BINARY}" ".buildkite/utilities/timeout.jl" ${JULIA_CMD_FOR_TESTS:?} -e "Base.runtests(\"${TESTS:?}\"; ncores = ${NCORES_FOR_TESTS:?})"
