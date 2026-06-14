# Isolated, NON-PRODUCTION publish test stack for `julia-publish-test-nosecrets`.
#
# This duplicates just enough of the real publish stack to exercise the full
# download -> KMS-sign -> promote flow end to end, but against THROWAWAY KMS
# keys (with self-signed certs) and a SEPARATE bucket -- so the publish flow
# can be debugged freely without touching any production key, bucket, or the
# public `julia-latest-*` pointers.
#
# Everything here is self-contained in this one file and gated on
# `var.buildkite_test_pipeline_id` being set: a normal `terraform apply`
# (test pipeline UUID unset) creates none of it. To tear the test stack down,
# delete this file (the keys have no prevent_destroy) -- production is untouched.
#
# Deliberately omitted (per design): Windows Authenticode signing (Azure) and
# macOS notarization (Apple ASC) have no non-production equivalent, so the test
# pipeline skips them (PUBLISH_SKIP_WINDOWS_SIGN / PUBLISH_SKIP_NOTARIZATION).
# Hence only two test keys: GPG tarball signing and macOS codesigning.

variable "buildkite_test_pipeline_id" {
  description = "UUID of the julia-publish-test-nosecrets Buildkite pipeline (set in buildkite_ids.auto.tfvars to enable the test stack)"
  type        = string
  default     = null

  validation {
    condition     = var.buildkite_test_pipeline_id == null ? true : can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", var.buildkite_test_pipeline_id)) && var.buildkite_test_pipeline_id != "00000000-0000-0000-0000-000000000000"
    error_message = "buildkite_test_pipeline_id must be the pipeline's UUID (or null to disable the test stack)."
  }
}

variable "buildkite_test_cluster_id" {
  description = "UUID of the cluster the julia-publish-test-nosecrets pipeline runs in (optional; omit for no cluster condition)"
  type        = string
  default     = null
}

variable "s3_test_publish_bucket" {
  description = "Bucket for the isolated publish test stack (staging input + promotion output)"
  type        = string
  default     = "julialang-test-publish"
}

locals {
  # The whole test stack materializes only once the pipeline UUID is supplied.
  enable_test_publish = var.buildkite_test_pipeline_id != null
  test_count          = local.enable_test_publish ? 1 : 0
  # Cluster condition only if a test cluster UUID was given.
  test_cluster_ids = compact([var.buildkite_test_cluster_id == null ? "" : var.buildkite_test_cluster_id])
}

# ---- Throwaway test signing keys (no prevent_destroy) -----------------------
# Same specs as production (kms.tf): RSA so kms_gpg_sign.py's OpenPGP assembly
# works, RSA_2048 for the macOS codesign key. Public halves become self-signed
# material committed to the repo (ops/20_export_gpg_pubkey.py and
# ops/32_gen_test_codesign_cert.sh).

resource "aws_kms_key" "tarball_signing_test" {
  count                    = local.test_count
  description              = "TEST (non-production) Julia release tarball GPG signing key"
  key_usage                = "SIGN_VERIFY"
  customer_master_key_spec = var.tarball_key_spec
  deletion_window_in_days  = 7
}

resource "aws_kms_alias" "tarball_signing_test" {
  count         = local.test_count
  name          = "alias/julia-tarball-signing-test"
  target_key_id = aws_kms_key.tarball_signing_test[0].key_id
}

resource "aws_kms_key" "macos_codesign_test" {
  count                    = local.test_count
  description              = "TEST (non-production) Julia macOS codesigning key (self-signed cert, used via rcodesign)"
  key_usage                = "SIGN_VERIFY"
  customer_master_key_spec = "RSA_2048"
  deletion_window_in_days  = 7
}

resource "aws_kms_alias" "macos_codesign_test" {
  count         = local.test_count
  name          = "alias/julia-macos-codesigning-test"
  target_key_id = aws_kms_key.macos_codesign_test[0].key_id
}

# ---- Test bucket (staging input + promotion output) -------------------------
# One bucket used for both: seeded staging at bin/<commit>/... and promotion at
# bin/<os>/<arch>/... (distinct key shapes). Mirrors the ephemeral-bucket setup
# (s3.tf): ACLs off, public-read via policy, short lifecycle expiry.

resource "aws_s3_bucket" "test_publish" {
  count  = local.test_count
  bucket = var.s3_test_publish_bucket
}

resource "aws_s3_bucket_ownership_controls" "test_publish" {
  count  = local.test_count
  bucket = aws_s3_bucket.test_publish[0].id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "test_publish" {
  count                   = local.test_count
  bucket                  = aws_s3_bucket.test_publish[0].id
  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_policy" "test_publish_public_read" {
  count      = local.test_count
  bucket     = aws_s3_bucket.test_publish[0].id
  depends_on = [aws_s3_bucket_public_access_block.test_publish]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "PublicReadTestArtifacts"
      Effect    = "Allow"
      Principal = "*"
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.test_publish[0].arn}/*"
    }]
  })
}

resource "aws_s3_bucket_lifecycle_configuration" "test_publish" {
  count  = local.test_count
  bucket = aws_s3_bucket.test_publish[0].id
  rule {
    id     = "expire-test-artifacts"
    status = "Enabled"
    filter {
      prefix = ""
    }
    expiration {
      days = 7
    }
  }
}

# ---- Test OIDC role + standalone trust --------------------------------------
# Trust is intentionally LOOSE on ref (any ref of the test pipeline slug) so we
# can test from any branch -- but still pinned to the unforgeable org_id + test
# pipeline_id (+ optional cluster_id) session tags, so ONLY the real test
# pipeline can assume it. The role can sign with the test keys and read/write
# ONLY the test bucket. No write-once condition, so the same commit can be
# re-published repeatedly while debugging.

data "aws_iam_policy_document" "publish_test_trust" {
  count = local.test_count

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
      values   = ["organization:${var.bk_org}:pipeline:julia-publish-test-nosecrets:*"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/organization_id"
      values   = [var.buildkite_organization_id]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/pipeline_id"
      values   = [var.buildkite_test_pipeline_id]
    }
    dynamic "condition" {
      for_each = length(local.test_cluster_ids) > 0 ? [1] : []
      content {
        test     = "StringEquals"
        variable = "aws:RequestTag/cluster_id"
        values   = local.test_cluster_ids
      }
    }
  }
}

resource "aws_iam_role" "publish_test" {
  count                = local.test_count
  name                 = "julia-oidc-publish-test"
  description          = "NON-PRODUCTION publish test: sign with test KMS keys + read/write the test bucket (via OIDC)"
  assume_role_policy   = data.aws_iam_policy_document.publish_test_trust[0].json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "publish_test" {
  count = local.test_count

  # Read seeded staging input AND read-back for retry checks; write promoted
  # artifacts. No s3:if-none-match: overwrites are allowed so the same build
  # can be re-run freely. Scoped to the test bucket only.
  statement {
    sid       = "ReadTestBucket"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.test_publish[0].arn}/*"]
  }
  statement {
    sid       = "WriteTestBucket"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.test_publish[0].arn}/*"]
  }

  statement {
    sid = "TestReleaseSigning"
    # DescribeKey: kms_gpg_sign.py --public-key-from-kms reads the GPG key's
    # CreationDate (part of the OpenPGP fingerprint) so the test pipeline need
    # not commit a pubkey. GetPublicKey: fetch the RSA public half.
    actions = ["kms:Sign", "kms:GetPublicKey", "kms:DescribeKey"]
    resources = [
      aws_kms_key.macos_codesign_test[0].arn,
      aws_kms_key.tarball_signing_test[0].arn,
    ]
  }
}

resource "aws_iam_role_policy" "publish_test" {
  count  = local.test_count
  name   = "test-sign-and-promote-to-test-bucket"
  role   = aws_iam_role.publish_test[0].id
  policy = data.aws_iam_policy_document.publish_test[0].json
}

output "test_publish_role_arn" {
  description = "ARN of the non-production publish test role (null until the test pipeline UUID is set)"
  value       = local.enable_test_publish ? aws_iam_role.publish_test[0].arn : null
}
