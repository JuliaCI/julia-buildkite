#!/usr/bin/env bash
# Print the SSH public key of the KMS-held docs deploy key, in OpenSSH
# format. Register this as a deploy key (with write access) on
# github.com/JuliaLang/docs.julialang.org.
#
# The private half never leaves KMS: the docs deploy job's ssh uses the
# aws-kms-pkcs11 provider (https://github.com/JackOfMostTrades/aws-kms-pkcs11)
# so each SSH authentication is a kms:Sign call gated by the
# julia-oidc-docs-deploy role.
set -euo pipefail
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
# shellcheck source=SCRIPTDIR/common.sh
source "${SCRIPT_DIR}/common.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

aws kms get-public-key --region "${AWS_REGION}" \
    --key-id "${KMS_ALIAS_DOCS_DEPLOY}" \
    --query PublicKey --output text | base64 -d > "${WORK}/spki.der"

openssl pkey -pubin -inform DER -in "${WORK}/spki.der" -out "${WORK}/pub.pem"
ssh-keygen -i -m PKCS8 -f "${WORK}/pub.pem" > "${WORK}/id.pub"

echo "$(cat "${WORK}/id.pub") julia-docs-deploy@kms"
