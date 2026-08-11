#!/usr/bin/env bash

# julia-pr ONLY: assemble the unsigned macOS Julia.app from an already-built
# tree tarball and stage it, on a small Linux agent that sits OFF the
# build->test critical path.
#
# Why a separate builder: the macOS build jobs stage only the tree `.tar.gz`
# (they no longer build the .app, see build_julia.sh), and julia-pr has no
# trusted publish step to repackage it (that path is julia-ci-only). juliaup
# resolves PR builds out of the ephemeral-pr bucket, so PR .apps still need to
# land there -- but assembling them must not delay the test jobs, which depend
# only on the build. This job depends on the macOS build and runs in parallel
# with the tests.
#
# Requires TRIPLET (a *-apple-darwin triplet) to be defined.
set -euo pipefail

# Get UPLOAD_FILENAME, STAGING_TARGET, MAJMIN, MAKE, JULIA_BINARYDIST_FILENAME, ...
# shellcheck source=SCRIPTDIR/build_envs.sh
source .buildkite/utilities/build_envs.sh

echo "--- Download the staged tree tarball artifact from build_${TRIPLET}"
# The macOS build uploaded ${UPLOAD_FILENAME}.tar.gz as a buildkite artifact;
# depends_on build_${TRIPLET} guarantees it exists.
buildkite-agent artifact download "${UPLOAD_FILENAME}.tar.gz" . --step "build_${TRIPLET?}"

# Assemble contrib/mac/app/dmg/Julia-${MAJMIN}.app (unsigned) from the tarball.
# shellcheck source=SCRIPTDIR/macos/assemble_app.sh
.buildkite/utilities/macos/assemble_app.sh "${UPLOAD_FILENAME}.tar.gz"

echo "--- Pack the .app"
tar zcf "${UPLOAD_FILENAME}.app.tar.gz" -C contrib/mac/app/dmg "Julia-${MAJMIN?}.app"

echo "--- Stage the unsigned .app to s3://${STAGING_TARGET}.app.tar.gz"
# Same write-once staging as the build job: assume the untrusted `stage` role
# and upload under this build's commit-sha-gated path in the ephemeral-pr bucket.
# shellcheck source=SCRIPTDIR/aws_oidc.sh
source .buildkite/utilities/aws_oidc.sh stage
# shellcheck source=SCRIPTDIR/upload_to_s3.sh
source .buildkite/utilities/upload_to_s3.sh
UPLOAD_TO_S3_ACL=none upload_to_s3 "${UPLOAD_FILENAME}.app.tar.gz" "${STAGING_TARGET}.app.tar.gz"
