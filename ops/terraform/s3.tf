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

# Uploads set `--acl public-read` per object (the same helper used for the
# release buckets), which requires ACLs to be honored.
resource "aws_s3_bucket_ownership_controls" "staging" {
  for_each = aws_s3_bucket.staging

  bucket = each.value.id
  rule {
    object_ownership = "ObjectWriter"
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
