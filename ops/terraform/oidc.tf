# IAM OIDC identity provider for Buildkite agents.
#
# Once this exists, Buildkite jobs can exchange `buildkite-agent oidc
# request-token --audience sts.amazonaws.com` tokens for temporary AWS
# credentials via sts:AssumeRoleWithWebIdentity (no static secrets).

locals {
  bk_oidc_host = "agent.buildkite.com"
}

# AWS now validates most OIDC issuers against trusted root CAs and ignores
# the thumbprint, but the API still requires one: use the root certificate
# of the issuer's chain.
data "tls_certificate" "buildkite" {
  url = "https://${local.bk_oidc_host}"
}

resource "aws_iam_openid_connect_provider" "buildkite" {
  url             = "https://${local.bk_oidc_host}"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.buildkite.certificates[0].sha1_fingerprint]
}
