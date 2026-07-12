#!/usr/bin/env bash
# Port the #544 OIDC/KMS trust architecture from `main` onto release-julia-1.13,
# reusing the shared julia-pr / julia-ci / julia-publish pipeline slugs.
#
# Principle: make the tree match `main` (the target architecture, already
# designed to serve `master` AND `release-*`) EXCEPT the genuinely
# release-specific build matrix (the *.arches files + launch_powerpc.jl),
# which are preserved from release-julia-1.13.
set -euo pipefail
cd "$(dirname "$0")"

BASE=origin/release-julia-1.13
MAIN=origin/main
BR=kf/port-oidc-release-1.13

git rev-parse --verify "$BR" >/dev/null 2>&1 && git branch -D "$BR"
git checkout -q -b "$BR" "$BASE"

# 1. Overlay main's tree wholesale (every path that exists in main): shared
#    files get main's version, main-only files are added. Paths that exist
#    only on release are left untouched here (removed in step 3).
git checkout -q "$MAIN" -- .

# 2. Restore the release-1.13 build matrix (rootfs v6.00/v7.10, mmtk on
#    package_linux, Windows CFLAGS) + the powerpc launcher.
mapfile -t KEEP < <(git ls-tree -r --name-only "$BASE" -- \
      pipelines/main/platforms pipelines/scheduled/platforms \
    | grep -E '\.arches$')
KEEP+=(pipelines/main/platforms/launch_powerpc.jl)
git checkout -q "$BASE" -- "${KEEP[@]}"

# 3. Retire the pre-#544 cryptic / signed-split / secrets infrastructure.
git rm -q -r --ignore-unmatch \
  cryptic_repo_keys secrets .buildkite/cryptic_repo_root \
  devdocs/sign.md \
  utilities/aws_config utilities/deploy_docs.sh utilities/sign_tarball.sh \
  pipelines/main/launch_signed_jobs.yml pipelines/main/launch_signed_jobs.yml.signature \
  pipelines/main/launch_unsigned_builders.yml pipelines/main/launch_unsigned_jobs.yml \
  pipelines/main/launch_upload_jobs.yml pipelines/main/launch_upload_jobs.yml.signature \
  pipelines/main/misc/upload_buildkite_results.yml \
  pipelines/main/platforms/upload_freebsd.yml pipelines/main/platforms/upload_linux.yml \
  pipelines/main/platforms/upload_macos.yml pipelines/main/platforms/upload_windows.yml \
  pipelines/scheduled/coverage/coverage.yml.signature \
  pipelines/scheduled/launch_signed_jobs.yml pipelines/scheduled/launch_signed_jobs.yml.signature \
  pipelines/scheduled/launch_unsigned_jobs.yml pipelines/scheduled/launch_upload_jobs.yml \
  pipelines/scheduled/launch_upload_jobs.yml.signature \
  pipelines/scheduled/platforms/upload_linux.no_gpl.yml \
  pipelines/scheduled/platforms/upload_macos.no_gpl.yml \
  pipelines/scheduled/platforms/upload_windows.no_gpl.yml \
  >/dev/null

echo "Port applied on branch $BR (renderer trim happens separately)."
