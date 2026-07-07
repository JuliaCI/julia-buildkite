terraform {
  # azuread >= 3.7 is needed for
  # azuread_application_flexible_federated_identity_credential.
  required_version = ">= 1.5"
  required_providers {
    azuread = {
      source  = "hashicorp/azuread"
      version = ">= 3.7"
    }
  }
}

provider "azuread" {}
