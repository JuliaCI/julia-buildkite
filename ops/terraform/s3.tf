# The per-pipeline ephemeral staging buckets. Everything in them is
# unsigned, write-once (enforced by IAM, see iam.tf), keyed by source
# commit sha, publicly readable (juliaup fetches PR binaries from the
# julia-pr bucket anonymously), and expired by lifecycle policy.
#
# The release buckets (julialangnightlies, julialang-nogpl, and the
# julialang-ephemeral self-test bucket) predate this module and are not
# managed here.

resource "aws_s3_bucket" "staging" {
  for_each = var.s3_staging_buckets

  bucket = each.value
}

# Object ACLs are disabled entirely (the modern S3 arrangement): public
# readability comes from the bucket policy below, and uploads must NOT
# send --acl (an ACL'd PUT would both fail under BucketOwnerEnforced and
# require s3:PutObjectAcl, which the stage roles do not have -- the
# s3:if-none-match condition key only exists for the PutObject action).
resource "aws_s3_bucket_ownership_controls" "staging" {
  for_each = aws_s3_bucket.staging

  bucket = each.value.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "staging" {
  for_each = aws_s3_bucket.staging

  bucket                  = each.value.id
  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

# Everything staged is world-readable: PR binaries are consumed by juliaup
# anonymously, and the artifacts are public release candidates anyway.
resource "aws_s3_bucket_policy" "staging_public_read" {
  for_each = aws_s3_bucket.staging

  bucket     = each.value.id
  depends_on = [aws_s3_bucket_public_access_block.staging]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "PublicReadStagedArtifacts"
      Effect    = "Allow"
      Principal = "*"
      Action    = "s3:GetObject"
      Resource  = "${each.value.arn}/*"
    }]
  })
}

resource "aws_s3_bucket_lifecycle_configuration" "staging" {
  for_each = aws_s3_bucket.staging

  bucket = each.value.id
  rule {
    id     = "expire-staged-artifacts"
    status = "Enabled"
    filter {
      prefix = ""
    }
    expiration {
      days = var.staging_expiry_days[each.key]
    }
  }
}
