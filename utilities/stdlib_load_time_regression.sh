#!/usr/bin/env bash

# This script runs a stdlib precompile/load-time regression check, comparing:
#
#   A = the Julia built by this CI pipeline (the "candidate")
#   B = the Julia nightly associated with the merge-base commit (the "baseline")
#
# It downloads/extracts both binaries (building the baseline from source if the
# merge-base nightly is missing), then hands them to
# `compare_stdlib_load_times.jl`, which re-precompiles every stdlib for both
# (timing the precompile) and measures their load times across several A/B/B/A/B/A
# rounds (to control for noise), then flags clear precompile- or load-time
# regressions.
#
# This check is only meaningful on macOS aarch64.

set -euo pipefail

# First, get things like `OS`, `ARCH`, `TRIPLET`, `JULIA_INSTALL_DIR`,
# `UPLOAD_FILENAME`, `JULIA_BINARY`, `JULIA_CPU_TARGET`, etc...
# shellcheck source=SCRIPTDIR/build_envs.sh
source .buildkite/utilities/build_envs.sh

if [[ "${OS}" != "macos" ]] || [[ "${ARCH}" != "aarch64" ]]; then
    echo "This check only runs on macOS aarch64 (got ${OS} ${ARCH}); skipping."
    exit 0
fi

# Default the number of build threads if the agent did not provide it.
: "${JULIA_CPU_THREADS:=$(sysctl -n hw.ncpu)}"

# --- Candidate (A): the Julia built by this pipeline -------------------------

echo "--- Download candidate build artifact"
buildkite-agent artifact download --step "build_${TRIPLET}" "${UPLOAD_FILENAME}.tar.gz" .

echo "--- Extract candidate build artifact"
tar xzf "${UPLOAD_FILENAME}.tar.gz" "${JULIA_INSTALL_DIR}/"

# Codesign so the binary runs and JLL artifact dylibs load on aarch64. We don't
# update the bundled pkgimage checksums here: this check recompiles every stdlib
# into a throwaway depot, so the bundled pkgimages are never loaded.
echo "--- [mac] Codesign candidate"
.buildkite/utilities/macos/codesign.sh "${JULIA_INSTALL_DIR}"

JULIA_A="$(pwd)/${JULIA_BINARY}"

# --- Baseline (B): the merge-base nightly -----------------------------------

MERGE_BASE="$(git merge-base HEAD origin/master)"
SHORT_MERGE_BASE="$(echo "${MERGE_BASE}" | cut -c1-10)"
# The baseline may live on a different version line than HEAD, so read its VERSION.
BASE_VERSION="$(git show "${MERGE_BASE}:VERSION")"
BASE_MAJMIN="$(cut -d. -f1-2 <<<"${BASE_VERSION}")"

echo "--- Resolve merge-base nightly"
echo "Merge base: ${MERGE_BASE} (julia ${BASE_VERSION})"

NIGHTLY_HOST="https://julialangnightlies-s3.julialang.org"
NIGHTLY_URL="${NIGHTLY_HOST}/bin/${OS}/${ARCH}/${BASE_MAJMIN}/julia-${SHORT_MERGE_BASE}-${OS}-${ARCH}.tar.gz"

BASELINE_DIR="$(pwd)/baseline"
rm -rf "${BASELINE_DIR}"
mkdir -p "${BASELINE_DIR}"

BASELINE_WORKTREE="$(pwd)/.stdlib-loadtime-baseline-src"
cleanup() {
    if [[ -d "${BASELINE_WORKTREE}" ]]; then
        git worktree remove --force "${BASELINE_WORKTREE}" || true
    fi
}
trap cleanup EXIT

if curl -fL --retry 3 -o baseline.tar.gz "${NIGHTLY_URL}"; then
    echo "--- Extract merge-base nightly"
    tar -C "${BASELINE_DIR}" --strip-components=1 -xzf baseline.tar.gz

    echo "--- [mac] Codesign baseline nightly"
    .buildkite/utilities/macos/codesign.sh "${BASELINE_DIR}"

    JULIA_B="${BASELINE_DIR}/bin/julia"
else
    echo "--- Merge-base nightly not found; building julia from source at ${SHORT_MERGE_BASE}"
    rm -rf "${BASELINE_WORKTREE}"
    git worktree add --detach "${BASELINE_WORKTREE}" "${MERGE_BASE}"
    (
        cd "${BASELINE_WORKTREE}"
        make -j"${JULIA_CPU_THREADS}" \
            VERBOSE=1 \
            "JULIA_CPU_TARGET=${JULIA_CPU_TARGET}"
    )
    JULIA_B="${BASELINE_WORKTREE}/usr/bin/julia"
fi

# --- Compare ----------------------------------------------------------------

echo "--- Compare stdlib load times"
"${JULIA_A}" .buildkite/utilities/stdlib_load_time_regression/compare_stdlib_load_times.jl \
    --a "${JULIA_A}" \
    --b "${JULIA_B}"
