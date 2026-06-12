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

Each build step stages its unsigned tarball directly (write-once, no relay
jobs) to a commit-sha-gated path in its pipeline's own ephemeral staging
bucket: `julia-pr` builds go to `julialang-ephemeral-pr` (where juliaup
finds PR binaries) and stop there. Trusted-ref builds run in `julia-ci`,
stage to `julialang-ephemeral-ci`, and trigger `julia-publish`, which
signs and promotes — reading only the `julia-ci` bucket. `julia-publish`
does not build pull requests, so a PR can never reach the signing keys or
feed artifacts into publishing.
