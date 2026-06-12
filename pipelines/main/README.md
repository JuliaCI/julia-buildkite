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

Pull requests run only in `julia-pr` and stop after staging unsigned
artifacts to a commit-sha-gated path. Trusted-ref builds run in `julia-ci`,
which triggers `julia-publish` to sign and publish. `julia-publish` does not
build pull requests, so a PR can never reach the signing keys.
