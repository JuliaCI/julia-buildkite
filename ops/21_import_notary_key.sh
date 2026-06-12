#!/usr/bin/env bash
# Import the App Store Connect API private key (.p8, ECDSA P-256) into the
# alias/julia-notary-api KMS key (EXTERNAL origin), then emit the unified
# api key JSON used by rcodesign (contains no secret material).
#
# Usage: 21_import_notary_key.sh AuthKey_XXXXXXXXXX.p8 <issuer-id> <key-id>
#
# Apple generates ASC API keys, so the existing key must be imported (we
# cannot register our own public key with Apple). Run from a trusted
# machine; securely delete the .p8 afterwards.
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
source "${SCRIPT_DIR}/common.sh"

P8_FILE="${1:?usage: $0 AuthKey.p8 <issuer-id> <key-id>}"
ISSUER_ID="${2:?usage: $0 AuthKey.p8 <issuer-id> <key-id>}"
API_KEY_ID="${3:?usage: $0 AuthKey.p8 <issuer-id> <key-id>}"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

echo "--- Convert .p8 (PEM PKCS#8) to DER"
openssl pkcs8 -topk8 -nocrypt -in "${P8_FILE}" -outform DER -out "${WORK}/key.pkcs8.der"

echo "--- Get KMS import parameters"
aws kms get-parameters-for-import --region "${AWS_REGION}" \
    --key-id "${KMS_ALIAS_NOTARY_API}" \
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

echo "--- Import key material into ${KMS_ALIAS_NOTARY_API}"
aws kms import-key-material --region "${AWS_REGION}" \
    --key-id "${KMS_ALIAS_NOTARY_API}" \
    --encrypted-key-material "fileb://${WORK}/encrypted_material.bin" \
    --import-token "fileb://${WORK}/import_token.bin" \
    --expiration-model KEY_MATERIAL_DOES_NOT_EXPIRE

KEY_ARN="$(kms_key_arn "${KMS_ALIAS_NOTARY_API}")"
OUT_JSON="${SCRIPT_DIR}/../utilities/macos/notary_api_key.json"

echo "--- Write unified api key JSON (no secret material) to ${OUT_JSON}"
cat > "${OUT_JSON}" <<EOF
{
  "issuer_id": "${ISSUER_ID}",
  "key_id": "${API_KEY_ID}",
  "aws_kms_key": "${KEY_ARN}",
  "aws_kms_region": "${AWS_REGION}"
}
EOF
cat "${OUT_JSON}"

echo "Done. Commit ${OUT_JSON}; securely delete the .p8 file."
