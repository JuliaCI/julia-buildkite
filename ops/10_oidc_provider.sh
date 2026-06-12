#!/usr/bin/env bash
# Create the IAM OIDC identity provider for Buildkite agents.
#
# After this exists, Buildkite jobs can exchange `buildkite-agent oidc
# request-token --audience sts.amazonaws.com` tokens for temporary AWS
# credentials via sts:AssumeRoleWithWebIdentity (no static secrets).
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
source "${SCRIPT_DIR}/common.sh"

if aws iam get-open-id-connect-provider \
        --open-id-connect-provider-arn "${OIDC_PROVIDER_ARN}" >/dev/null 2>&1; then
    echo "OIDC provider ${OIDC_PROVIDER_ARN} already exists"
    exit 0
fi

# AWS now validates most OIDC issuers against trusted root CAs and ignores
# the thumbprint, but the API still requires one. Compute the SHA-1
# fingerprint of the last certificate in the issuer's chain (the CA).
echo "--- Compute ${BK_OIDC_HOST} certificate thumbprint"
CHAIN_DIR="$(mktemp -d)"
trap 'rm -rf "${CHAIN_DIR}"' EXIT
openssl s_client -servername "${BK_OIDC_HOST}" -showcerts \
        -connect "${BK_OIDC_HOST}:443" </dev/null 2>/dev/null \
    | awk -v dir="${CHAIN_DIR}" \
        '/BEGIN CERTIFICATE/{i++} i{print > (dir "/cert_" i ".pem")} /END CERTIFICATE/{ }'
LAST_CERT="$(ls "${CHAIN_DIR}"/cert_*.pem | sort -V | tail -1)"
THUMBPRINT="$(openssl x509 -in "${LAST_CERT}" -noout -fingerprint -sha1 \
    | cut -d= -f2 | tr -d ':' | tr '[:upper:]' '[:lower:]')"

if [[ -z "${THUMBPRINT}" ]]; then
    echo "ERROR: could not compute thumbprint for ${BK_OIDC_HOST}" >&2
    exit 1
fi

echo "--- Create OIDC provider"
aws iam create-open-id-connect-provider \
    --url "https://${BK_OIDC_HOST}" \
    --client-id-list "sts.amazonaws.com" \
    --thumbprint-list "${THUMBPRINT}"

echo "Created ${OIDC_PROVIDER_ARN}"
