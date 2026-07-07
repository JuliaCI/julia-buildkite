#!/usr/bin/env bash
# Generate a certificate signing request for the macOS codesigning KMS key.
#
# Submit the resulting CSR at https://developer.apple.com/account/resources/certificates
# (type: "Developer ID Application"), download the issued certificate,
# convert to PEM, and commit it as utilities/macos/developer_id.pem:
#
#     openssl x509 -inform DER -in developerID_application.cer -out developer_id.pem
#
# Requires the AWS-KMS-backend rcodesign (utilities/macos/get_rcodesign.sh)
# and AWS credentials with kms:GetPublicKey + kms:Sign on the key.
set -euo pipefail
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
source "${SCRIPT_DIR}/common.sh"

RCODESIGN="${RCODESIGN:-rcodesign}"

"${RCODESIGN}" generate-certificate-signing-request \
    --aws-kms-key "${KMS_ALIAS_MACOS_CODESIGN}" \
    --aws-kms-region "${AWS_REGION}" \
    --csr-pem-file julia-macos-codesigning.csr.pem

echo "CSR written to julia-macos-codesigning.csr.pem"
