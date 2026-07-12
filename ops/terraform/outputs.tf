output "oidc_provider_arn" {
  description = "IAM OIDC provider for agent.buildkite.com"
  value       = aws_iam_openid_connect_provider.buildkite.arn
}

output "role_arns" {
  description = "IAM roles assumed by Buildkite jobs"
  value = {
    stage-pr    = aws_iam_role.stage["julia-pr"].arn
    stage-ci    = aws_iam_role.stage["julia-ci"].arn
    tokens-ci   = aws_iam_role.tokens.arn
    publish     = aws_iam_role.publish.arn
    docs-deploy = aws_iam_role.docs_deploy.arn
  }
}

output "kms_key_arns" {
  description = "KMS signing keys (the EXTERNAL notary key needs material imported)"
  value = {
    macos_codesign  = aws_kms_key.macos_codesign.arn
    notary_api      = aws_kms_external_key.notary_api.arn
    tarball_signing = aws_kms_key.tarball_signing.arn
    docs_deploy     = aws_kms_key.docs_deploy.arn
  }
}

output "staging_buckets" {
  description = "Per-pipeline ephemeral staging buckets (PR consumers like juliaup read the julia-pr one)"
  value       = { for slug, b in aws_s3_bucket.staging : slug => b.bucket }
}

output "julia_ci_aws_account_id" {
  description = "Fill this into JULIA_CI_AWS_ACCOUNT_ID in utilities/aws_oidc.sh"
  value       = data.aws_caller_identity.current.account_id
}
