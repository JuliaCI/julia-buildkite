terraform {
  # aws >= 6.0 is needed for asymmetric (SIGN_VERIFY) key specs on
  # aws_kms_external_key (the BYOK notary key).
  required_version = ">= 1.10"

  # Shared state, so anyone with admin access to the account can apply. The
  # bucket is versioned and also holds the Pkg servers' and PkgEvalFarm's
  # state. S3 native locking (use_lockfile) needs Terraform/OpenTofu 1.10+.
  backend "s3" {
    bucket       = "julialang-terraform"
    key          = "julia-buildkite.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      project = "julia-ci"
    }
  }
}
