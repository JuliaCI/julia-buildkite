# This directory not used by base Julia!

This directory is for performing CI on the `julia-buildkite` repository
itself!  It does not get used at all during the actual build for Julia
itself.

## How the self-test works

The `julia-buildkite-ci` Buildkite pipeline (untrusted; same cluster as
`julia-pr` / `julia-ci`) builds this repository's pull requests and
`main`.  Its webUI configuration is the same "Launch pipelines" step as
the julia build pipelines (see `pipelines/main/0_webui.yml`), but the
pipeline's *repository* is `JuliaCI/julia-buildkite` -- so every job of
the build checks out this repository and runs `hooks/post-checkout`,
which:

1. replaces the working directory with a `JuliaLang/julia` checkout
   (`UPSTREAM_BRANCH`, default `master`; pinned once per build via
   meta-data so all jobs test the same julia commit), and
2. pins the external-buildkite plugin's build meta-data to
   `${BUILDKITE_COMMIT}` (this build's julia-buildkite commit), so every
   launched job runs the proposed pipeline code.

Trust model (see `ops/README.md`): the self-test pipeline holds no
secrets, tokens, or signing rights.  Build jobs stage their artifacts
write-once to the pipeline's own ephemeral bucket
(`julialang-ephemeral-buildkite`) via its own OIDC role
(`julia-oidc-stage-buildkite`) -- separate from the buckets juliaup and
julia-publish consume, so a self-test build can never place anything a
production consumer would read.  The julia-publish trigger is gated on
`pipeline.slug == "julia-ci"` and so never fires here.
