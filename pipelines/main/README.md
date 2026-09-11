## Main pipeline

This directory contains most of the builders. They are triggered by GitHub
webhook events (pushes and pull requests).

Builds are split across three Buildkite pipelines by trust level (see
`ops/README.md` for why):

| Pipeline        | Builds                                            | Trust                          |
| --------------- | ------------------------------------------------- | ------------------------------ |
| `julia-pr`      | pull requests                                     | untrusted (stage only)         |
| `julia-ci`      | `master`, `release-*`, tags, and scheduled nightlies | untrusted to sign; triggers publish |
| `julia-publish` | (triggered by `julia-ci`) signs + promotes        | trusted (KMS signing keys)     |

The daily `julia-ci` schedule runs coverage, a from-source assertion build
with rr tests, no-GPL builds for Linux, macOS, and Windows, and an x86-64
Linux PGO+LTO+BOLT build with allow-fail tests. It does not repeat the
per-commit groups. `julia-publish` promotes the scheduled artifacts; no-GPL
builds go to `julialang-nogpl`, while optimized builds use
`julialangnightlies/bin/linuxopt/`.

Pull requests with the `needs full CI` label also run the scheduled workloads.
Coverage data is collected but not uploaded to Codecov or Coveralls.

To check that a ref still builds from source on the whole platform matrix
(e.g. a release branch before tagging), create a manual "New Build" on
`julia-pr` or `julia-ci` with `SOURCE_BUILD=true` in the environment box.
That renders the standard Build / Test / Allow Fail groups with
`USE_BINARYBUILDER=0` on every build (bigger timeouts, Linux rows on the
full-toolchain `llvm_passes` rootfs) and never publishes; commit statuses
are posted under separate `... (source build)` contexts. See the
source-build mode section in `utilities/render_launch_pipeline.py`.

Each build step stages its unsigned tarball directly (write-once, no relay
jobs) to a commit-sha-gated path in its pipeline's own ephemeral staging
bucket: `julia-pr` builds go to `julialang-ephemeral-pr` (where juliaup
finds PR binaries) and stop there, so a PR's binaries are available as
soon as its build job finishes. Trusted-ref builds run in `julia-ci`, stage
to `julialang-ephemeral-ci`, and trigger `julia-publish` once per platform,
as soon as that platform's build and test jobs are green (plus once for the
docs), which signs and promotes — reading only the `julia-ci` bucket.
`julia-publish` does not build pull requests, so a PR can never reach the
signing keys or feed artifacts into publishing.
