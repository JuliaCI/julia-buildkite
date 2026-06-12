#!/usr/bin/env bash
# Import the existing GPG release tarball signing key material into the
# alias/julia-tarball-signing KMS key (EXTERNAL origin).
#
# Because the key *material* is imported (BYOK), signatures produced by KMS
# verify against the long-published Julia releases public key
# (https://julialang.org/juliareleases.asc); nothing changes for users.
#
# Usage: 20_import_gpg_key.sh /path/to/tarball_signing.gpg
#
# The input is the decrypted secrets/tarball_signing.gpg from this repo
# (decrypt once with the legacy cryptic agent key: `make decrypt`).
# Run this from a trusted machine; shred inputs afterwards.
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
source "${SCRIPT_DIR}/common.sh"

GPG_KEY_FILE="${1:?usage: $0 /path/to/tarball_signing.gpg}"

KEY_ARN="$(kms_key_arn "${KMS_ALIAS_TARBALL_SIGNING}")"
if [[ -z "${KEY_ARN}" || "${KEY_ARN}" == "None" ]]; then
    echo "ERROR: ${KMS_ALIAS_TARBALL_SIGNING} does not exist; apply ops/terraform first" >&2
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

echo "--- Convert GPG secret key to PKCS#8"
python3 "${SCRIPT_DIR}/gpg_to_pkcs8.py" "${GPG_KEY_FILE}" "${WORK}/key.pkcs8.der"

echo "--- Get KMS import parameters (RSA_AES_KEY_WRAP_SHA_256)"
aws kms get-parameters-for-import --region "${AWS_REGION}" \
    --key-id "${KMS_ALIAS_TARBALL_SIGNING}" \
    --wrapping-algorithm RSA_AES_KEY_WRAP_SHA_256 \
    --wrapping-key-spec RSA_4096 \
    --output json > "${WORK}/import-params.json"

python3 - "${WORK}" <<'EOF'
import base64, json, sys
work = sys.argv[1]
params = json.load(open(f"{work}/import-params.json"))
open(f"{work}/wrapping_key.der", "wb").write(base64.b64decode(params["PublicKey"]))
open(f"{work}/import_token.bin", "wb").write(base64.b64decode(params["ImportToken"]))
EOF

echo "--- Wrap key material"
# RSA_AES_KEY_WRAP_SHA_256: an ephemeral AES-256 key is wrapped with the KMS
# wrapping key (RSA-OAEP-SHA256), and the target key is wrapped with the AES
# key using AES-KWP (RFC 5649). Concatenate both.
openssl rand 32 > "${WORK}/aes.key"
openssl pkeyutl -encrypt \
    -pubin -inkey "${WORK}/wrapping_key.der" -keyform DER \
    -pkeyopt rsa_padding_mode:oaep \
    -pkeyopt rsa_oaep_md:sha256 \
    -pkeyopt rsa_mgf1_md:sha256 \
    -in "${WORK}/aes.key" -out "${WORK}/wrapped_aes.bin"
openssl enc -id-aes256-wrap-pad \
    -K "$(xxd -p "${WORK}/aes.key" | tr -d '\n')" \
    -iv A65959A6 \
    -in "${WORK}/key.pkcs8.der" -out "${WORK}/wrapped_key.bin"
cat "${WORK}/wrapped_aes.bin" "${WORK}/wrapped_key.bin" > "${WORK}/encrypted_material.bin"

echo "--- Import key material into ${KMS_ALIAS_TARBALL_SIGNING}"
aws kms import-key-material --region "${AWS_REGION}" \
    --key-id "${KMS_ALIAS_TARBALL_SIGNING}" \
    --encrypted-key-material "fileb://${WORK}/encrypted_material.bin" \
    --import-token "fileb://${WORK}/import_token.bin" \
    --expiration-model KEY_MATERIAL_DOES_NOT_EXPIRE

echo "--- Verify: sign + verify a test digest"
echo -n "kms import self-test" | openssl dgst -sha256 -binary > "${WORK}/digest.bin"
SIG_B64="$(aws kms sign --region "${AWS_REGION}" \
    --key-id "${KMS_ALIAS_TARBALL_SIGNING}" \
    --message "fileb://${WORK}/digest.bin" --message-type DIGEST \
    --signing-algorithm RSASSA_PKCS1_V1_5_SHA_256 \
    --query Signature --output text)"
echo "${SIG_B64}" | base64 -d > "${WORK}/sig.bin"

aws kms verify --region "${AWS_REGION}" \
    --key-id "${KMS_ALIAS_TARBALL_SIGNING}" \
    --message "fileb://${WORK}/digest.bin" --message-type DIGEST \
    --signing-algorithm RSASSA_PKCS1_V1_5_SHA_256 \
    --signature "fileb://${WORK}/sig.bin" \
    --query SignatureValid --output text

echo "Done. Remember to securely delete the plaintext GPG key file."
