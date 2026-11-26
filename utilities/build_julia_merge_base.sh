#!/usr/bin/env bash
# Builds a pull request's merge-base from source, with the flags of the pull request's own
# from-source build, for that build's TTFX and runtime benchmark jobs to compare against:
# measured against a regular build, the difference would also be how the dependencies were
# built. When the nightly schedule has staged a from-source build of the merge-base, that is
# used and nothing is built. The build is a Buildkite artifact only, as staging is keyed by
# the pull request's commit.
set -euo pipefail

# shellcheck source=SCRIPTDIR/extract_triplet.sh
source .buildkite/utilities/extract_triplet.sh
# shellcheck source=SCRIPTDIR/src_merge_base.sh
source .buildkite/utilities/src_merge_base.sh

echo "--- Find the merge-base"
find_src_merge_base
echo "merge-base with ${BASE_BRANCH}: ${MERGE_BASE}"
buildkite-agent meta-data set src-merge-base "${MERGE_BASE}"
buildkite-agent meta-data set src-merge-base-branch "${BASE_BRANCH}"

url="$(src_staged_url "${MERGE_BASE}")"
if curl -fsIL --retry 3 -o /dev/null "${url}"; then
    echo "The nightly schedule built ${MERGE_BASE:0:10} from source already: ${url}"
    exit 0
fi

echo "--- Check out the merge-base"
git checkout --quiet --detach "${MERGE_BASE}"
SKIP_STAGING=true exec bash .buildkite/utilities/build_julia.sh
