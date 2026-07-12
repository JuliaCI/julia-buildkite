# Azure workload identity federation so Windows codesigning (Azure Trusted
# Signing via signtool dlib) authenticates with Buildkite OIDC tokens
# instead of an AZURE_CLIENT_SECRET.
#
# This is a separate root module from ../ because it authenticates against
# a different control plane (Microsoft Graph, not AWS); apply it with
# credentials that may manage the Trusted Signing app registration.
#
# Buildkite `sub` claims embed the commit sha, so exact-match federated
# credentials cannot work. Use flexible federated identity credentials
# (claims matching expressions) to wildcard-match protected refs of the
# julia-publish pipeline (Windows codesigning happens in the trusted
# publish step). Requires Microsoft Graph support for flexible FIC on the
# tenant; if unavailable, fall back to `--subject-claim organization_id`
# tokens (exact-match credential on the Buildkite organization UUID) at
# the cost of org-level granularity -- see ops/README.md.

locals {
  bk_oidc_host = "agent.buildkite.com"

  # Must stay in sync with publish_sub_patterns in ../iam.tf.
  publish_sub_patterns = {
    master  = "organization:${var.bk_org}:pipeline:julia-publish:ref:refs/heads/master:*"
    release = "organization:${var.bk_org}:pipeline:julia-publish:ref:refs/heads/release-*:*"
    tags    = "organization:${var.bk_org}:pipeline:julia-publish:ref:refs/tags/v*:*"
  }
}

data "azuread_application" "trusted_signing" {
  client_id = var.azure_app_id
}

resource "azuread_application_flexible_federated_identity_credential" "buildkite" {
  for_each = local.publish_sub_patterns

  application_id             = data.azuread_application.trusted_signing.id
  display_name               = "buildkite-julia-publish-${each.key}"
  description                = "Buildkite julia-publish (${each.key}) Windows Trusted Signing"
  audience                   = "api://AzureADTokenExchange"
  issuer                     = "https://${local.bk_oidc_host}"
  claims_matching_expression = "claims['sub'] matches '${each.value}'"
}

# Publish jobs authenticate via:
#   buildkite-agent oidc request-token --audience api://AzureADTokenExchange
# with AZURE_CLIENT_ID=<azure_app_id>, AZURE_TENANT_ID, and
# AZURE_FEDERATED_TOKEN_FILE set by utilities/windows/codesign.sh.
# Remove any AZURE_CLIENT_SECRET from the app once this works.
