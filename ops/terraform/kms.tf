# The KMS keys used by Julia CI. No private key ever exists outside KMS
# (or, for the BYOK keys, outside the one-time trusted import machine).
#
# The two EXTERNAL-origin keys are created here *without* key material;
# import the existing material out-of-band (it must never enter the
# Terraform state) with:
#
#   ops/20_import_gpg_key.sh     -> alias/julia-tarball-signing
#   ops/21_import_notary_key.sh  -> alias/julia-notary-api
#
# Until then they sit in the PendingImport state and cannot sign.

# Fresh key; a new Developer ID certificate must be issued for it
# (see ops/22_generate_macos_csr.sh).
resource "aws_kms_key" "macos_codesign" {
  description              = "Julia macOS Developer ID codesigning key (used via rcodesign)"
  key_usage                = "SIGN_VERIFY"
  customer_master_key_spec = "RSA_2048"
}

resource "aws_kms_alias" "macos_codesign" {
  name          = "alias/julia-macos-codesigning"
  target_key_id = aws_kms_key.macos_codesign.key_id
}

# The existing App Store Connect API .p8 key is imported (Apple generates
# ASC API keys; we cannot register our own public key with Apple).
resource "aws_kms_external_key" "notary_api" {
  description = "Julia App Store Connect API key (notarization JWT signing)"
  key_usage   = "SIGN_VERIFY"
  key_spec    = "ECC_NIST_P256"
}

resource "aws_kms_alias" "notary_api" {
  name          = "alias/julia-notary-api"
  target_key_id = aws_kms_external_key.notary_api.id
}

# The existing GPG release signing key material is imported so published
# signatures keep verifying against https://julialang.org/juliareleases.asc.
resource "aws_kms_external_key" "tarball_signing" {
  description = "Julia release tarball GPG signing key (imported GPG key material)"
  key_usage   = "SIGN_VERIFY"
  key_spec    = var.tarball_key_spec
}

resource "aws_kms_alias" "tarball_signing" {
  name          = "alias/julia-tarball-signing"
  target_key_id = aws_kms_external_key.tarball_signing.id
}

# The SSH key used to push to docs.julialang.org. SSH signs via the
# aws-kms-pkcs11 provider, so the key never exists outside KMS. Register
# the public key (ops/24_docs_deploy_pubkey.sh) as a GitHub deploy key
# with write access.
resource "aws_kms_key" "docs_deploy" {
  description              = "Julia docs.julialang.org SSH deploy key (used via aws-kms-pkcs11)"
  key_usage                = "SIGN_VERIFY"
  customer_master_key_spec = "ECC_NIST_P256"
}

resource "aws_kms_alias" "docs_deploy" {
  name          = "alias/julia-docs-deploy"
  target_key_id = aws_kms_key.docs_deploy.key_id
}
