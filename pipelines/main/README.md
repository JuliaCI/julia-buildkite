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

The scheduled nightlies are a Buildkite schedule on `julia-ci` (master,
daily). A schedule build does not repeat the per-commit Build/Check/Test
groups; `utilities/render_launch_pipeline.py` detects
`BUILDKITE_SOURCE == "schedule"` and instead launches the workloads that
are too expensive (or too special) for per-commit CI:

* **Coverage** — build + full test suite with coverage on linux/macOS/
  Windows, uploaded to Codecov/Coveralls
  (`pipelines/scheduled/coverage/coverage.yml`, gated on
  `build.source == "schedule"`; also runnable on PRs via the
  "needs full CI" label, without uploads).
* **Source Build / Source Tests** — a from-source (`USE_BINARYBUILDER=0`)
  assertion build, tested under rr
  (`pipelines/scheduled/platforms/*.schedule.arches`).
* **no_GPL** — `USE_GPL_LIBS=0` builds for linux/macOS/Windows
  (`pipelines/scheduled/platforms/*.no_gpl.arches`), staged under the
  `bin-nogpl` prefix and promoted to `julialang-nogpl` by a
  no-GPL-only `julia-publish` trigger (`PUBLISH_NOGPL`).

Each build step stages its unsigned tarball directly (write-once, no relay
jobs) to a commit-sha-gated path in its pipeline's own ephemeral staging
bucket: `julia-pr` builds go to `julialang-ephemeral-pr` (where juliaup
finds PR binaries) and stop there. Trusted-ref builds run in `julia-ci`,
stage to `julialang-ephemeral-ci`, and trigger `julia-publish`, which
signs and promotes — reading only the `julia-ci` bucket. `julia-publish`
does not build pull requests, so a PR can never reach the signing keys or
feed artifacts into publishing.
