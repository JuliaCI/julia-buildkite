terraform {
  # azuread >= 3.7 is needed for
  # azuread_application_flexible_federated_identity_credential.
  required_version = ">= 1.10"

  # Shared state next to the AWS module's (../versions.tf), so `init` needs
  # AWS credentials for the julia-ci account as well as the Azure ones.
  backend "s3" {
    bucket       = "julialang-terraform"
    key          = "julia-buildkite-azure.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }

  required_providers {
    azuread = {
      source  = "hashicorp/azuread"
      version = ">= 3.7"
    }
  }
}

provider "azuread" {}
