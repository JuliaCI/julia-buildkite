# IAM roles assumed by Buildkite jobs via OIDC.
#
# Trust is split into an untrusted tier and a trusted tier so that pull
# request builds can never reach signing keys or release locations:
#
#   julia-oidc-stage    UNTRUSTED. Assumable from any job of the build
#                     pipelines (PRs included; the build step assumes it to
#                     stage its tarball directly). May only write unsigned
#                     artifacts, write-once, to a path gated by the build's
#                     own commit sha, inside the calling pipeline's OWN
#                     ephemeral staging bucket (julia-pr and julia-ci have
#                     separate ones; publish only reads julia-ci's). No
#                     KMS, no final-location write. Because its permissions
#                     are harmless, the spoofable `ref` component of the
#                     sub claim does not matter here.
#   julia-oidc-publish  TRUSTED. kms:Sign with the signing keys, read the
#                     staging area, and write the final release locations.
#                     Assumable ONLY from the `julia-publish` pipeline slug.
#                     That pipeline must have pull-request builds DISABLED
#                     and be branch-limited to master/release-*/v* (see
#                     ops/README.md). Since a PR can never produce a build
#                     under that slug, the slug is the trust boundary -- not
#                     the (PR-spoofable) branch name.
#   julia-oidc-docs-deploy  TRUSTED. kms:Sign with the docs SSH key; publish
#                     pipeline only.
#   julia-oidc-tokens   Low-value telemetry bearer tokens from SSM; build
#                     pipelines.
#
# Defense in depth: trusted publish jobs additionally run
# utilities/verify_trusted_commit.sh before assuming their role, which
# refuses unless BUILDKITE_COMMIT is reachable from a protected ref of the
# canonical JuliaLang/julia repository.
#
# Overwrite protection: every PutObject must use the S3 conditional write
# header (s3:if-none-match = "*"), i.e. uploads fail if the object already
# exists. The only exception is `julia-latest-*` pointer objects, which the
# publish pipeline intentionally repoints.

data "aws_caller_identity" "current" {}

locals {
  # `sub` format: organization:ORG:pipeline:PIPELINE:ref:REF:commit:SHA:step:STEP

  # The UNTRUSTED build pipelines:
  #   julia-pr  builds pull requests
  #   julia-ci  builds trusted refs (master / release-* / tags), incl. scheduled
  # Any ref is allowed: the stage/token roles these map to are deliberately
  # harmless, so we do not (and must not) rely on the ref component for trust.
  build_sub_patterns = [
    "organization:${var.bk_org}:pipeline:julia-pr:*",
    "organization:${var.bk_org}:pipeline:julia-ci:*",
  ]

  # The TRUSTED publish pipeline. julia-publish MUST be configured in
  # Buildkite with pull-request builds disabled and branch-limited to the
  # protected refs (see ops/README.md), and is triggered only by julia-ci.
  # A PR can then never produce a build under this slug, so the slug itself
  # is the trust boundary; the ref patterns below are belt-and-braces only.
  publish_sub_patterns = [
    "organization:${var.bk_org}:pipeline:julia-publish:ref:refs/heads/master:*",
    "organization:${var.bk_org}:pipeline:julia-publish:ref:refs/heads/release-*:*",
    "organization:${var.bk_org}:pipeline:julia-publish:ref:refs/tags/v*:*",
  ]

  # Per-role trust: which pipelines (by slug pattern in `sub` AND by
  # unforgeable UUID session tag) and -- for the trusted roles -- which
  # steps (aws:RequestTag/step_key, attested by the agent) may assume it.
  # The untrusted roles have no step restriction (null): build steps stage
  # artifacts directly, test steps post results directly, and the
  # permissions are deliberately harmless anyway.
  oidc_trust = {
    stage = {
      pipelines         = ["julia-pr", "julia-ci"]
      sub_patterns      = local.build_sub_patterns
      step_key_patterns = null
    }
    publish = {
      pipelines         = ["julia-publish"]
      sub_patterns      = local.publish_sub_patterns
      step_key_patterns = ["publish_*"]
    }
    docs-deploy = {
      pipelines         = ["julia-publish"]
      sub_patterns      = local.publish_sub_patterns
      step_key_patterns = ["deploy_docs"]
    }
    tokens = {
      pipelines         = ["julia-pr", "julia-ci"]
      sub_patterns      = local.build_sub_patterns
      step_key_patterns = null
    }
  }

  # Allowed cluster UUIDs per role, from the per-pipeline cluster map;
  # roles whose pipelines have no configured cluster get no condition.
  trust_cluster_ids = {
    for role, t in local.oidc_trust :
    role => distinct(compact([for p in t.pipelines : lookup(var.buildkite_cluster_ids, p, "")]))
  }

  # Artifact-family prefixes inside each staging bucket (normal release /
  # no-GPL / julia-buildkite self-test; see S3_BUCKET_PREFIX selection in
  # utilities/build_envs.sh) and the final release locations.
  staging_prefixes = [
    var.s3_bucket_prefix,
    var.s3_nogpl_prefix,
    var.s3_ephemeral_prefix,
  ]
  staging_bucket_arns = {
    for slug, bucket in var.s3_staging_buckets : slug => "arn:aws:s3:::${bucket}"
  }
  final_paths = [
    "arn:aws:s3:::${var.s3_bucket}/${var.s3_bucket_prefix}",
    "arn:aws:s3:::${var.s3_nogpl_bucket}/${var.s3_nogpl_prefix}",
    "arn:aws:s3:::${var.s3_ephemeral_bucket}/${var.s3_ephemeral_prefix}",
  ]
}

data "aws_iam_policy_document" "trust" {
  for_each = local.oidc_trust

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
      values   = each.value.sub_patterns
    }
    dynamic "condition" {
      for_each = each.value.step_key_patterns != null ? [1] : []
      content {
        test     = "StringLike"
        variable = "aws:RequestTag/step_key"
        values   = each.value.step_key_patterns
      }
    }

    # Pin the Buildkite UUIDs, not just the slugs in `sub`: slugs are
    # renameable/re-mintable, UUIDs are not. These arrive as session tags
    # (utilities/aws_oidc.sh) since IAM cannot condition on other claims.
    # A token requested without these tags fails the conditions outright.
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/organization_id"
      values   = [var.buildkite_organization_id]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/pipeline_id"
      values   = [for p in each.value.pipelines : var.buildkite_pipeline_ids[p]]
    }
    dynamic "condition" {
      for_each = length(local.trust_cluster_ids[each.key]) > 0 ? [1] : []
      content {
        test     = "StringEquals"
        variable = "aws:RequestTag/cluster_id"
        values   = local.trust_cluster_ids[each.key]
      }
    }
  }
}

# ---- julia-oidc-stage (UNTRUSTED) -------------------------------------------
# Write-once, to <own pipeline's staging bucket>/<prefix>/<own commit sha>/
# only. The build_commit and pipeline_id tags are attested by Buildkite
# (not settable by the job), so a build can only ever write under its own
# source commit, and only inside its own pipeline's bucket -- julia-pr can
# never touch the julia-ci bucket that publish reads from.

resource "aws_iam_role" "stage" {
  name                 = "julia-oidc-stage"
  description          = "Buildkite staging upload: write-once to own pipeline's staging bucket, own commit path (via OIDC)"
  assume_role_policy   = data.aws_iam_policy_document.trust["stage"].json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "stage" {
  dynamic "statement" {
    for_each = var.s3_staging_buckets

    content {
      sid     = "WriteOnceToOwnCommitPath${replace(title(statement.key), "-", "")}"
      actions = ["s3:PutObject", "s3:PutObjectAcl"]
      # $${...} is the literal IAM policy variable, not Terraform interpolation.
      resources = [
        for p in local.staging_prefixes :
        "${local.staging_bucket_arns[statement.key]}/${p}/$${aws:PrincipalTag/build_commit}/*"
      ]

      condition {
        test     = "StringEquals"
        variable = "s3:if-none-match"
        values   = ["*"]
      }
      condition {
        test     = "StringEquals"
        variable = "aws:PrincipalTag/pipeline_id"
        values   = [var.buildkite_pipeline_ids[statement.key]]
      }
    }
  }

  statement {
    sid       = "ReadStagingForRetryChecks"
    actions   = ["s3:GetObject"]
    resources = [for arn in values(local.staging_bucket_arns) : "${arn}/*"]
  }
}

resource "aws_iam_role_policy" "stage" {
  name   = "stage"
  role   = aws_iam_role.stage.id
  policy = data.aws_iam_policy_document.stage.json
}

# ---- julia-oidc-publish (TRUSTED) -------------------------------------------
# Sign + promote staged artifacts to the final release locations. Assumable
# only from the julia-publish pipeline slug (PR builds disabled there).

resource "aws_iam_role" "publish" {
  name                 = "julia-oidc-publish"
  description          = "Buildkite publish: sign + promote staged artifacts to release (via OIDC)"
  assume_role_policy   = data.aws_iam_policy_document.trust["publish"].json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "publish" {
  statement {
    sid     = "ReadStagedArtifacts"
    actions = ["s3:GetObject"]
    # Only the julia-ci staging bucket: artifacts staged by pull-request
    # builds (julia-pr's bucket) are not publishable inputs.
    resources = ["${local.staging_bucket_arns["julia-ci"]}/*"]
  }

  statement {
    sid       = "WriteOnceToFinalLocations"
    actions   = ["s3:PutObject", "s3:PutObjectAcl"]
    resources = [for p in local.final_paths : "${p}/*"]

    condition {
      test     = "StringEquals"
      variable = "s3:if-none-match"
      values   = ["*"]
    }
  }

  statement {
    sid     = "RepointLatestPointers"
    actions = ["s3:PutObject", "s3:PutObjectAcl"]
    resources = flatten([for p in local.final_paths : [
      "${p}/*/julia-latest-*",
      "${p}/*/*/julia-latest-*",
      "${p}/*/*/*/julia-latest-*",
    ]])
  }

  statement {
    sid       = "ReadFinalForRetryChecks"
    actions   = ["s3:GetObject"]
    resources = [for p in local.final_paths : "${p}/*"]
  }

  statement {
    sid     = "ReleaseSigning"
    actions = ["kms:Sign", "kms:GetPublicKey"]
    resources = [
      aws_kms_key.macos_codesign.arn,
      aws_kms_external_key.notary_api.arn,
      aws_kms_key.tarball_signing.arn,
    ]

    condition {
      test     = "StringLike"
      variable = "aws:PrincipalTag/step_key"
      values   = ["publish_*"]
    }
  }
}

resource "aws_iam_role_policy" "publish" {
  name   = "publish"
  role   = aws_iam_role.publish.id
  policy = data.aws_iam_policy_document.publish.json
}

# ---- julia-oidc-docs-deploy (TRUSTED) ---------------------------------------

resource "aws_iam_role" "docs_deploy" {
  name                 = "julia-oidc-docs-deploy"
  description          = "Buildkite docs deploy: SSH signing via KMS (aws-kms-pkcs11, via OIDC)"
  assume_role_policy   = data.aws_iam_policy_document.trust["docs-deploy"].json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "docs_deploy" {
  statement {
    sid       = "SshSignViaDocsDeployKey"
    actions   = ["kms:Sign", "kms:GetPublicKey"]
    resources = [aws_kms_key.docs_deploy.arn]

    condition {
      test     = "StringEquals"
      variable = "aws:PrincipalTag/step_key"
      values   = ["deploy_docs"]
    }
  }
}

resource "aws_iam_role_policy" "docs_deploy" {
  name   = "docs-deploy"
  role   = aws_iam_role.docs_deploy.id
  policy = data.aws_iam_policy_document.docs_deploy.json
}

# ---- julia-oidc-tokens -------------------------------------------------------
# CI telemetry bearer tokens (codecov, coveralls, buildkite analytics) are
# inherently symmetric secrets, so they live in SSM Parameter Store
# (SecureString, see ops/23_put_tokens.sh) and are fetched at runtime by
# this role. Nothing secret is stored in the repository or this state.

resource "aws_iam_role" "tokens" {
  name                 = "julia-oidc-tokens"
  description          = "Buildkite CI telemetry: read coverage/analytics tokens from SSM (via OIDC)"
  assume_role_policy   = data.aws_iam_policy_document.trust["tokens"].json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "tokens" {
  statement {
    sid       = "ReadTelemetryTokens"
    actions   = ["ssm:GetParameter"]
    resources = ["arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${var.ssm_token_prefix}/*"]
  }
}

resource "aws_iam_role_policy" "tokens" {
  name   = "tokens"
  role   = aws_iam_role.tokens.id
  policy = data.aws_iam_policy_document.tokens.json
}
