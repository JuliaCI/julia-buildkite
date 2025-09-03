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

echo "--- Run trimming tests"
${MAKE} --output-sync -j"${JULIA_CPU_THREADS:?}" -C test/trimming check JULIA="${JULIA_BINARY:?}" BIN="$(dirname "${JULIA_BINARY:?}")"
