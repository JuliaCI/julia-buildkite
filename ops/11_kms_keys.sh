#!/usr/bin/env bash
# Create the KMS keys used by Julia CI.
#
#   alias/julia-macos-codesigning  RSA_2048 sign/verify (fresh key; a new
#                                  Developer ID certificate must be issued
#                                  for it -- see 22_generate_macos_csr.sh)
#   alias/julia-notary-api         ECC_NIST_P256 sign/verify, EXTERNAL origin
#                                  (existing App Store Connect API .p8 key is
#                                  imported -- see 21_import_notary_key.sh)
#   alias/julia-tarball-signing    RSA sign/verify, EXTERNAL origin (existing
#                                  GPG release signing key material is
#                                  imported so published signatures keep
#                                  verifying -- see 20_import_gpg_key.sh)
#   alias/julia-docs-deploy        ECC_NIST_P256 sign/verify; the SSH key
#                                  used to push to docs.julialang.org. SSH
#                                  signs via the aws-kms-pkcs11 provider, so
#                                  the key never exists outside KMS. Register
#                                  the public key (24_docs_deploy_pubkey.sh)
#                                  as a GitHub deploy key with write access.
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
source "${SCRIPT_DIR}/common.sh"

# Key spec of the existing GPG release signing key (RSA_4096 for the Julia
# release key; check with `gpg --list-packets` if unsure).
TARBALL_KEY_SPEC="${TARBALL_KEY_SPEC:-RSA_4096}"

create_key() {
    local alias="$1" spec="$2" usage="$3" origin="$4" desc="$5"

    local arn
    arn="$(kms_key_arn "${alias}")"
    if [[ -n "${arn}" && "${arn}" != "None" ]]; then
        echo "${alias} already exists: ${arn}"
        return 0
    fi

    echo "Creating ${alias} (${spec}, ${usage}, origin ${origin})"
    local key_id
    key_id="$(aws kms create-key --region "${AWS_REGION}" \
        --key-spec "${spec}" \
        --key-usage "${usage}" \
        --origin "${origin}" \
        --description "${desc}" \
        --tags TagKey=project,TagValue=julia-ci \
        --query KeyMetadata.KeyId --output text)"
    ensure_alias "${alias}" "${key_id}"
    echo "Created ${alias}: ${key_id}"
}

create_key "${KMS_ALIAS_MACOS_CODESIGN}" RSA_2048 SIGN_VERIFY AWS_KMS \
    "Julia macOS Developer ID codesigning key (used via rcodesign)"

create_key "${KMS_ALIAS_NOTARY_API}" ECC_NIST_P256 SIGN_VERIFY EXTERNAL \
    "Julia App Store Connect API key (notarization JWT signing)"

create_key "${KMS_ALIAS_TARBALL_SIGNING}" "${TARBALL_KEY_SPEC}" SIGN_VERIFY EXTERNAL \
    "Julia release tarball GPG signing key (imported GPG key material)"

create_key "${KMS_ALIAS_DOCS_DEPLOY}" ECC_NIST_P256 SIGN_VERIFY AWS_KMS \
    "Julia docs.julialang.org SSH deploy key (used via aws-kms-pkcs11)"
