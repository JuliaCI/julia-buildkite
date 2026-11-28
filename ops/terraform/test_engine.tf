# The julia-test-engine pipeline: uploads the build pipelines' test results
# to Buildkite Test Engine on their behalf (pipelines/test-engine/,
# utilities/upload_test_results.sh).
#
# Test jobs in julia-pr run attacker-controlled code, so they hold no bearer
# token (there is no tokens-pr role). Instead every test job's results go up
# as a build artifact, and the build pipeline triggers one julia-test-engine
# build per test job, which fetches the artifact and posts it with the suite
# token. Only that one token is readable here, and only from the
# `upload_test_results` step of this one pipeline (UUID-pinned).
#
# Gated on `var.buildkite_test_engine_pipeline_id`, so a `terraform apply`
# before the pipeline exists creates none of it.

variable "buildkite_test_engine_pipeline_id" {
  description = "UUID of the julia-test-engine Buildkite pipeline (set in buildkite_ids.auto.tfvars once it exists)"
  type        = string
  default     = null

  validation {
    condition     = var.buildkite_test_engine_pipeline_id == null ? true : can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", var.buildkite_test_engine_pipeline_id)) && var.buildkite_test_engine_pipeline_id != "00000000-0000-0000-0000-000000000000"
    error_message = "buildkite_test_engine_pipeline_id must be the pipeline's UUID (or null until the pipeline exists)."
  }
}

variable "buildkite_test_engine_cluster_id" {
  description = "UUID of the cluster the julia-test-engine pipeline runs in (required with the pipeline UUID)"
  type        = string
  default     = null
}

locals {
  enable_test_engine      = var.buildkite_test_engine_pipeline_id != null
  test_engine_count       = local.enable_test_engine ? 1 : 0
  test_engine_cluster_ids = compact([var.buildkite_test_engine_cluster_id == null ? "" : var.buildkite_test_engine_cluster_id])
}

# ---- julia-oidc-test-engine --------------------------------------------------
# Trust is loose on ref (the trigger step chooses the branch, so it means
# nothing here) and pinned to the unforgeable org / pipeline / cluster
# UUIDs plus the upload step's key.

data "aws_iam_policy_document" "test_engine_trust" {
  count = local.test_engine_count

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity", "sts:TagSession"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.buildkite.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.bk_oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "${local.bk_oidc_host}:sub"
      values   = ["organization:${var.bk_org}:pipeline:julia-test-engine:*"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/step_key"
      values   = ["upload_test_results"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/organization_id"
      values   = [var.buildkite_organization_id]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/pipeline_id"
      values   = [var.buildkite_test_engine_pipeline_id]
    }
    dynamic "condition" {
      for_each = length(local.test_engine_cluster_ids) > 0 ? [1] : []
      content {
        test     = "StringEquals"
        variable = "aws:RequestTag/cluster_id"
        values   = local.test_engine_cluster_ids
      }
    }
  }
}

resource "aws_iam_role" "test_engine" {
  count                = local.test_engine_count
  name                 = "julia-oidc-test-engine"
  description          = "Buildkite julia-test-engine: read the Test Engine suite token from SSM (via OIDC)"
  assume_role_policy   = data.aws_iam_policy_document.test_engine_trust[0].json
  max_session_duration = 3600

  lifecycle {
    # Pull requests trigger this pipeline: the cluster pin is part of what
    # keeps the role on the dedicated agents, so it is not optional here.
    precondition {
      condition     = length(local.test_engine_cluster_ids) > 0
      error_message = "buildkite_test_engine_cluster_id must be set together with buildkite_test_engine_pipeline_id."
    }
  }
}

data "aws_iam_policy_document" "test_engine" {
  count = local.test_engine_count

  statement {
    sid       = "ReadTestEngineToken"
    actions   = ["ssm:GetParameter"]
    resources = ["arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${var.ssm_token_prefix}/buildkite_analytics_token"]
  }
}

resource "aws_iam_role_policy" "test_engine" {
  count  = local.test_engine_count
  name   = "read-test-engine-token-from-ssm"
  role   = aws_iam_role.test_engine[0].id
  policy = data.aws_iam_policy_document.test_engine[0].json
}

output "test_engine_role_arn" {
  description = "ARN of the julia-test-engine role (null until the pipeline UUID is set)"
  value       = local.enable_test_engine ? aws_iam_role.test_engine[0].arn : null
}
