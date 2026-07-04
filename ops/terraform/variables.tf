variable "aws_region" {
  description = "Region holding the KMS keys and SSM parameters"
  type        = string
  default     = "us-east-1"
}

variable "bk_org" {
  description = "Buildkite organization slug"
  type        = string
  default     = "julialang"
}

# The Buildkite UUIDs pinned by the IAM trust policies, alongside the
# slug-based `sub` patterns. Slugs are renameable and can be re-minted by
# deleting + recreating a pipeline; UUIDs cannot, so a recreated pipeline
# with a matching slug does not regain role access. The jobs pass these as
# AWS session tags (see utilities/aws_oidc.sh) because IAM can only
# condition on aud/sub from the raw token. Values live in
# buildkite_ids.auto.tfvars (fetched once from the Buildkite REST API:
# GET /v2/organizations/<org> and /v2/organizations/<org>/pipelines/<slug>;
# re-fetch only if a pipeline is ever recreated or moved between clusters).
# No defaults and nullable = false: an apply without real, well-formed
# UUIDs (set in buildkite_ids.auto.tfvars) must be impossible -- a trust
# policy missing these conditions would fall back to slug-only pinning.
variable "buildkite_organization_id" {
  description = "UUID of the Buildkite organization"
  type        = string
  nullable    = false

  validation {
    # The null guard keeps `terraform validate` (which leaves required
    # variables unset) happy; nullable = false rejects null at plan time.
    condition     = var.buildkite_organization_id == null ? true : can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", var.buildkite_organization_id)) && var.buildkite_organization_id != "00000000-0000-0000-0000-000000000000"
    error_message = "Set buildkite_organization_id to the organization UUID (see buildkite_ids.auto.tfvars)."
  }
}

variable "buildkite_pipeline_ids" {
  description = "UUIDs of the three Buildkite pipelines, keyed by slug"
  type        = map(string)
  nullable    = false

  validation {
    condition     = var.buildkite_pipeline_ids == null ? true : keys(var.buildkite_pipeline_ids) == tolist(["julia-ci", "julia-pr", "julia-publish"])
    error_message = "buildkite_pipeline_ids must have exactly the keys julia-ci, julia-pr, julia-publish."
  }
  validation {
    condition = var.buildkite_pipeline_ids == null ? true : alltrue([
      for id in values(var.buildkite_pipeline_ids) :
      can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", id)) && id != "00000000-0000-0000-0000-000000000000"
    ])
    error_message = "Set every pipeline UUID (see buildkite_ids.auto.tfvars)."
  }
}

# Cluster UUID each pipeline runs in, keyed by pipeline slug. Optional:
# pipelines without an entry get no cluster condition (e.g. unclustered
# agents, where the cluster_id claim is empty).
variable "buildkite_cluster_ids" {
  description = "UUIDs of the Buildkite cluster each pipeline belongs to, keyed by pipeline slug"
  type        = map(string)
  default     = {}
}

variable "s3_bucket" {
  description = "S3 bucket that release binaries are uploaded to"
  type        = string
  default     = "julialangnightlies"
}

variable "s3_bucket_prefix" {
  description = "Prefix under s3_bucket for release binaries"
  type        = string
  default     = "bin"
}

# Bucket + prefix the julia-buildkite repo's own CI uploads to
# (see .buildkite/hooks/post-checkout)
variable "s3_ephemeral_bucket" {
  description = "S3 bucket used by julia-buildkite's own self-test CI"
  type        = string
  default     = "julialang-ephemeral"
}

variable "s3_ephemeral_prefix" {
  description = "Prefix under s3_ephemeral_bucket"
  type        = string
  default     = "julia-buildkite-uploads/bin"
}

# Bucket + prefix for the scheduled no-GPL builds
# (see pipelines/scheduled/platforms/upload_*.no_gpl.yml)
variable "s3_nogpl_bucket" {
  description = "S3 bucket for the scheduled no-GPL builds"
  type        = string
  default     = "julialang-nogpl"
}

variable "s3_nogpl_prefix" {
  description = "Prefix under s3_nogpl_bucket"
  type        = string
  default     = "bin-nogpl"
}

# Per-pipeline EPHEMERAL staging buckets (created by this module, with
# lifecycle expiry). The build step of each untrusted pipeline writes its
# unsigned artifacts write-once to <bucket>/<prefix>/<commit-sha>/...
# julia-pr and julia-ci get SEPARATE buckets: the trusted publish pipeline
# only reads the julia-ci bucket, so a pull-request build can never place
# (or, since paths are write-once, pre-claim) anything publish would
# consume. PR consumers (juliaup) read from the julia-pr bucket.
variable "s3_staging_buckets" {
  description = "Ephemeral staging bucket per untrusted pipeline, keyed by pipeline slug"
  type        = map(string)
  default = {
    "julia-pr" = "julialang-ephemeral-pr"
    "julia-ci" = "julialang-ephemeral-ci"
  }
}

variable "staging_expiry_days" {
  description = "Days before staged objects expire, keyed by pipeline slug"
  type        = map(number)
  default = {
    # PR binaries are consumed by juliaup while the PR is open
    "julia-pr" = 90
    # publish promotes within hours of staging
    "julia-ci" = 30
  }
}

# RSA matching the strength of the previous (pre-KMS) release signing key.
# Must be an RSA spec: the OpenPGP signature assembly in
# utilities/kms_gpg_sign.py only supports RSA.
variable "tarball_key_spec" {
  description = "KMS key spec for the GPG release tarball signing key"
  type        = string
  default     = "RSA_4096"
}

# Bearer tokens (codecov, coveralls, buildkite analytics) are inherently
# symmetric secrets, so they live in SSM Parameter Store. The parameter
# *values* are deliberately not managed here (they would end up in the
# Terraform state); store them with ops/23_put_tokens.sh.
variable "ssm_token_prefix" {
  description = "SSM Parameter Store prefix for CI telemetry bearer tokens"
  type        = string
  default     = "/julia-ci/tokens"
}
