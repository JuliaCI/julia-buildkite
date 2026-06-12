# Shared configuration for the julia-buildkite AWS ops scripts.
# Source this from the numbered scripts; do not run directly.
#
# These scripts cover the imperative one-time operations (key material
# import, secret entry, CSR generation) that deliberately do NOT live in
# Terraform: their inputs are secrets that must never enter the Terraform
# state. The declarative infrastructure (OIDC provider, KMS keys, IAM
# roles, Azure federated credentials) is managed in ops/terraform/.
#
# All scripts are idempotent: safe to re-run after partial failures.

set -euo pipefail

# --- Configuration (override via environment) --------------------------------
# Must match the corresponding Terraform variables (ops/terraform/variables.tf).

export AWS_REGION="${AWS_REGION:-us-east-1}"

# S3 bucket that release binaries (and prebuilt CI tools) are uploaded to
export S3_BUCKET="${S3_BUCKET:-julialangnightlies}"

# KMS key aliases (created by ops/terraform)
export KMS_ALIAS_MACOS_CODESIGN="alias/julia-macos-codesigning"
export KMS_ALIAS_NOTARY_API="alias/julia-notary-api"
export KMS_ALIAS_TARBALL_SIGNING="alias/julia-tarball-signing"
export KMS_ALIAS_DOCS_DEPLOY="alias/julia-docs-deploy"

# SSM Parameter Store prefix for CI telemetry bearer tokens (codecov,
# coveralls, buildkite analytics). These cannot be public-key operations,
# so they live in the AWS secrets store, fetched at runtime via OIDC.
export SSM_TOKEN_PREFIX="/julia-ci/tokens"

# --- Helpers ------------------------------------------------------------------

# kms_key_arn <alias> -> key ARN (empty if alias doesn't exist)
kms_key_arn() {
    aws kms describe-key --key-id "$1" --region "${AWS_REGION}" \
        --query KeyMetadata.Arn --output text 2>/dev/null || true
}
