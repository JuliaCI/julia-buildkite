#!/bin/bash

# This script performs the basic steps needed to test Julia previously
# built and uploaded as a `.tar.gz`.
# It requires the following environment variables to be defined:
#  - TRIPLET
#  - USE_RR
set -euo pipefail

# First, get things like `SHORT_COMMIT`, `JULIA_CPU_TARGET`, `UPLOAD_TARGETS`, etc...
source .buildkite/utilities/build_envs.sh

echo "--- Download build artifacts"
buildkite-agent artifact download "${UPLOAD_FILENAME}.tar.gz" .

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

    # Run all tests
    export TESTS="all --ci"
fi

echo "--- Print the list of test sets, and other useful environment variables"
echo "JULIA_CMD_FOR_TESTS is:    ${JULIA_CMD_FOR_TESTS:?}"
echo "JULIA_NUM_THREADS is:      ${JULIA_NUM_THREADS:?}"
echo "NCORES_FOR_TESTS is:       ${NCORES_FOR_TESTS:?}"
echo "OPENBLAS_NUM_THREADS is:   ${OPENBLAS_NUM_THREADS:?}"
echo "TESTS is:                  ${TESTS:?}"
echo "USE_RR is:                 ${USE_RR-}"

echo "--- Run the Julia test suite"
${JULIA_CMD_FOR_TESTS:?} -e "Base.runtests(\"${TESTS:?}\"; ncores = ${NCORES_FOR_TESTS:?})"
