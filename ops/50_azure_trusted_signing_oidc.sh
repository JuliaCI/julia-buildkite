#!/usr/bin/env bash
# Configure Azure workload identity federation so Windows codesigning
# (Azure Trusted Signing via signtool dlib) authenticates with Buildkite
# OIDC tokens instead of an AZURE_CLIENT_SECRET.
#
# Requires: az CLI, logged in with permissions on the app registration
# that holds the Trusted Signing "Code Signing Certificate Profile Signer"
# role assignment.
#
# Usage: AZURE_APP_ID=<existing-app-client-id> 50_azure_trusted_signing_oidc.sh
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
source "${SCRIPT_DIR}/common.sh"

: "${AZURE_APP_ID:?set AZURE_APP_ID to the app registration (client) ID used for Trusted Signing}"

# Buildkite `sub` claims embed the commit sha, so exact-match federated
# credentials cannot work. Use a flexible federated identity credential
# (claimsMatchingExpression) to wildcard-match protected refs of the
# julia-publish pipeline (Windows codesigning now happens in the trusted
# publish step). Requires Microsoft.Graph API support for flexible FIC.
for entry in \
    "buildkite-julia-publish-master|organization:${BK_ORG}:pipeline:julia-publish:ref:refs/heads/master:*" \
    "buildkite-julia-publish-release|organization:${BK_ORG}:pipeline:julia-publish:ref:refs/heads/release-*:*" \
    "buildkite-julia-publish-tags|organization:${BK_ORG}:pipeline:julia-publish:ref:refs/tags/v*:*" \
; do
    name="${entry%%|*}"
    pattern="${entry#*|}"

    echo "--- Federated credential: ${name} (${pattern})"
    az ad app federated-credential create --id "${AZURE_APP_ID}" --parameters "{
        \"name\": \"${name}\",
        \"issuer\": \"https://${BK_OIDC_HOST}\",
        \"audiences\": [\"api://AzureADTokenExchange\"],
        \"claimsMatchingExpression\": {
            \"value\": \"claims['sub'] matches '${pattern}'\",
            \"languageVersion\": 1
        }
    }" || echo "    (already exists or flexible FIC unsupported -- see ops/README.md)"
done

echo
echo "Windows upload jobs now authenticate via:"
echo "  buildkite-agent oidc request-token --audience api://AzureADTokenExchange"
echo "with AZURE_CLIENT_ID=${AZURE_APP_ID}, AZURE_TENANT_ID, and"
echo "AZURE_FEDERATED_TOKEN_FILE set by utilities/windows/codesign.sh."
echo "Remove any AZURE_CLIENT_SECRET from the app once this works."
