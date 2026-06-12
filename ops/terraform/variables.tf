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

# Sub-path (under each bucket prefix) that unsigned, commit-sha-gated
# artifacts are staged to. The publish pipeline reads from here; PR
# consumers (juliaup) also read from here.
variable "staging_subprefix" {
  description = "Sub-path for unsigned commit-sha-gated staging artifacts"
  type        = string
  default     = "staging"
}

# Key spec of the existing GPG release signing key (RSA_4096 for the Julia
# release key; check with `gpg --list-packets` if unsure).
variable "tarball_key_spec" {
  description = "KMS key spec matching the imported GPG release signing key"
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
