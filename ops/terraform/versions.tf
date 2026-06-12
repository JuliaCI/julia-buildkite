terraform {
  # aws >= 6.0 is needed for asymmetric (SIGN_VERIFY) key specs on
  # aws_kms_external_key (the BYOK notary key).
  required_version = ">= 1.5"
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
