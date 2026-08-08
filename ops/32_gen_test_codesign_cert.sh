#!/usr/bin/env bash
# Generate a SELF-ISSUED (throwaway) macOS codesigning certificate for the
# NON-PRODUCTION test KMS key alias/julia-macos-codesigning-test, and commit it
# as utilities/macos/developer_id_test.pem.
#
# This is the test-stack counterpart of ops/22_generate_macos_csr.sh. Unlike
# production -- where the CSR is submitted to Apple and the issued Developer ID
# certificate is committed as developer_id.pem -- here we never involve Apple:
# we mint a CSR from the test KMS key (which carries the key's PUBLIC half,
# self-signed by KMS to prove possession), then issue a leaf certificate for it
# from a throwaway local CA. The resulting cert therefore contains the test KMS
# key's public key, so rcodesign signatures made with that KMS key verify
# against it. It does NOT chain to Apple and Gatekeeper would reject it -- but
# the test stack only exercises the SIGNING mechanics (rcodesign -> kms:Sign),
# not Gatekeeper acceptance, and macOS notarization is skipped entirely
# (PUBLISH_SKIP_NOTARIZATION=1).
#
# One-time: run with AWS credentials that have kms:GetPublicKey + kms:Sign on
# the test key (e.g. after `terraform apply` with buildkite_test_pipeline_id
# set), then commit the output. Requires the patched rcodesign and openssl.
set -euo pipefail
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
# shellcheck source=SCRIPTDIR/common.sh
source "${SCRIPT_DIR}/common.sh"

RCODESIGN="${RCODESIGN:-rcodesign}"
OUT="${SCRIPT_DIR}/../utilities/macos/developer_id_test.pem"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# 1. CSR from the test KMS key (carries its public key; signed by KMS).
"${RCODESIGN}" generate-certificate-signing-request \
    --aws-kms-key "${KMS_ALIAS_MACOS_CODESIGN_TEST}" \
    --aws-kms-region "${AWS_REGION}" \
    --csr-pem-file "${WORK}/kms.csr"

# 2. Throwaway local CA (its private key is discarded with $WORK).
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "${WORK}/ca.key" -out "${WORK}/ca.pem" -days 3650 -sha256 \
    -subj "/CN=Julia TEST codesigning CA (NOT FOR PRODUCTION)/O=The Julia Project (TEST)/C=US"

# 3. Issue the leaf cert for the KMS public key, with the codesigning EKU.
cat > "${WORK}/leaf.ext" <<'EOF'
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:FALSE
EOF
openssl x509 -req -in "${WORK}/kms.csr" \
    -CA "${WORK}/ca.pem" -CAkey "${WORK}/ca.key" -CAcreateserial \
    -days 3650 -sha256 -extfile "${WORK}/leaf.ext" \
    -out "${OUT}"

echo "Wrote self-issued test codesigning certificate to ${OUT}"
openssl x509 -in "${OUT}" -noout -subject -issuer -dates
echo
echo "Commit ${OUT} (a public, non-secret, non-production certificate)."
