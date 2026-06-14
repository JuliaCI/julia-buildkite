# Buildkite UUIDs pinned by the IAM trust policies (see variables.tf).
# Not secrets; fetched 2026-06-12 from the Buildkite REST API. These are
# static -- refetch only if a pipeline is ever recreated or moved between
# clusters (and re-apply).
#
# julia-publish runs in its own cluster, separate from the build
# pipelines: the cluster_id condition then also stops a compromised
# build-pool agent from minting publish-shaped tokens.

buildkite_organization_id = "d409823c-5fa7-41c8-9033-7269c5fde4f3"

buildkite_pipeline_ids = {
  "julia-pr"      = "019ebd61-5b1f-428e-b08c-1b5a2111e001"
  "julia-ci"      = "019ebd63-635e-4155-b60a-9d2815900786"
  "julia-publish" = "019ebd63-df36-4f53-a07f-4b31064df0f8"
}

buildkite_cluster_ids = {
  "julia-pr"      = "ae7e6bd1-fde8-433d-bac7-9d2d01108ed6"
  "julia-ci"      = "ae7e6bd1-fde8-433d-bac7-9d2d01108ed6"
  "julia-publish" = "fd6c2af4-60c1-40ee-bdd5-88ecb6698fbc"
}

# Isolated NON-PRODUCTION publish test stack (ops/terraform/test_publish.tf).
# Set to the real UUIDs to enable the throwaway test keys/bucket/role; comment
# out (or set null) to disable. julia-publish-test-nosecrets lives in the same
# Secure cluster as julia-publish.
buildkite_test_pipeline_id = "019ec73b-f8df-428a-a256-745eff852687"
buildkite_test_cluster_id  = "fd6c2af4-60c1-40ee-bdd5-88ecb6698fbc"
