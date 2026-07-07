variable "azure_app_id" {
  description = "Client ID of the existing app registration that holds the Trusted Signing 'Code Signing Certificate Profile Signer' role assignment"
  type        = string
}

variable "bk_org" {
  description = "Buildkite organization slug"
  type        = string
  default     = "julialang"
}
