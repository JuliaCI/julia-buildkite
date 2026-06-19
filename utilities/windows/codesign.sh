#!/usr/bin/env bash
# This file is a part of Julia. License is MIT: https://julialang.org/license
#
# Authenticode-sign Windows PE files with Azure Trusted Signing -- from
# LINUX. Signatures are produced by jsign (https://ebourg.github.io/jsign/,
# storetype TRUSTEDSIGNING); authentication is Buildkite OIDC exchanged for
# an Entra access token via workload identity federation (client_assertion
# grant, no AZURE_CLIENT_SECRET -- see ops/terraform/azure).
#
# Usage: codesign.sh <file-or-directory>
#
# Besides direct invocation from upload_julia.sh, this script is also the
# target of Inno Setup's compile-time SignTool: ISCC runs under Wine and
# bridges back to this host-side script via wine_signtool.cmd, passing a
# Windows-style path (translated back with winepath below).

set -euo pipefail

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

JSIGN="${JSIGN:-jsign}"
METADATA_JSON="${SCRIPT_DIR}/codesign_metadata.json"

usage() {
    echo "Usage: $0 <target>"
    echo
    echo "    target: A PE file or a directory to codesign (all *.exe / *.dll within)"
}

if [ "$#" -ne 1 ]; then
    usage
    exit 1
fi
TARGET="${1}"

# When invoked from the Wine-side Inno Setup hook, the argument is a
# Windows path; translate it back to a host path.
if [[ "${TARGET}" =~ ^[A-Za-z]: ]]; then
    TARGET="$(winepath -u "${TARGET}")"
fi

# The non-production publish test stack sets PUBLISH_SKIP_WINDOWS_SIGN=1:
# Windows Authenticode signing is Azure Trusted Signing, which has no
# KMS/self-signed equivalent. No-op (exit 0) so that ISCC's compile-time
# SignTool hook and the direct PE-signing pass both "succeed" while producing
# UNSIGNED binaries. (upload_julia.sh skips the check_signed.py tripwire in
# this mode, since the installer is intentionally unsigned.)
if [[ "${PUBLISH_SKIP_WINDOWS_SIGN:-0}" == "1" ]]; then
    echo "PUBLISH_SKIP_WINDOWS_SIGN=1: not Authenticode-signing ${TARGET}" >&2
    exit 0
fi

# AZURE_TENANT_ID / AZURE_CLIENT_ID identify the Trusted Signing app
# registration; they are not secrets and are set in the pipeline yml.
if [[ -z "${AZURE_TENANT_ID:-}" ]] ||
   [[ -z "${AZURE_CLIENT_ID:-}" ]]; then
    echo "ERROR: Missing AZURE_TENANT_ID / AZURE_CLIENT_ID variables!" >&2
    exit 1
fi

# Trusted Signing account coordinates (not secrets).
read -r TS_ENDPOINT TS_ALIAS < <(python3 - "${METADATA_JSON}" <<'EOF'
import json, sys
m = json.load(open(sys.argv[1]))
print(m["Endpoint"].rstrip("/"), f'{m["CodeSigningAccountName"]}/{m["CertificateProfileName"]}')
EOF
)

# Exchange a Buildkite OIDC token for an Entra access token scoped to the
# Trusted Signing service. Cached on disk so that the per-file invocations
# from the Inno Setup hook don't re-authenticate every time.
TOKEN_CACHE="${AZURE_TS_TOKEN_CACHE:-${TMPDIR:-/tmp}/azure-trusted-signing-token-$(id -u)}"
get_access_token() {
    if [[ -f "${TOKEN_CACHE}" ]] && [[ -n "$(find "${TOKEN_CACHE}" -mmin -45 2>/dev/null)" ]]; then
        cat "${TOKEN_CACHE}"
        return 0
    fi

    local oidc_token response
    oidc_token="$(buildkite-agent oidc request-token \
        --audience "api://AzureADTokenExchange" \
        --subject-claim pipeline_id \
        --skip-redaction \
        --lifetime 3600)"

    response="$(curl --fail --silent --show-error \
        -X POST "https://login.microsoftonline.com/${AZURE_TENANT_ID}/oauth2/v2.0/token" \
        --data-urlencode "grant_type=client_credentials" \
        --data-urlencode "client_id=${AZURE_CLIENT_ID}" \
        --data-urlencode "scope=https://codesigning.azure.net/.default" \
        --data-urlencode "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
        --data-urlencode "client_assertion=${oidc_token}")"

    python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])' \
        <<<"${response}" > "${TOKEN_CACHE}.tmp"
    chmod 600 "${TOKEN_CACHE}.tmp"
    mv "${TOKEN_CACHE}.tmp" "${TOKEN_CACHE}"
    cat "${TOKEN_CACHE}"
}

ACCESS_TOKEN="$(get_access_token)"

# We will try to codesign, using multiple timestamping servers in case one is down
SERVERS=(
    "http://timestamp.acs.microsoft.com"
    "http://timestamp.digicert.com"
    "http://tsa.starfieldtech.com"
)
NUM_RETRIES=3

# Sign a batch of files with one jsign invocation (one JVM start signs many
# files). --replace keeps retries idempotent.
do_codesign() {
    for _ in $(seq 1 ${NUM_RETRIES}); do
        for SERVER in "${SERVERS[@]}"; do
            if "${JSIGN}" \
                    --storetype TRUSTEDSIGNING \
                    --keystore "${TS_ENDPOINT}" \
                    --storepass "${ACCESS_TOKEN}" \
                    --alias "${TS_ALIAS}" \
                    --alg SHA-256 \
                    --tsmode RFC3161 \
                    --tsaurl "${SERVER}" \
                    --replace \
                    "$@"; then
                return 0
            fi
        done
    done

    # If we're unable to codesign, pass an error up the chain
    return 1
}

if [ -f "${TARGET}" ]; then
    echo "Codesigning file ${TARGET}"
    do_codesign "${TARGET}"
elif [ -d "${TARGET}" ]; then
    # Collect every PE file in the directory, then sign in batches.
    PE_FILES=()
    while IFS= read -r -d '' pe_file; do
        PE_FILES+=( "${pe_file}" )
    done < <(find "${TARGET}" -type f \( -iname '*.exe' -o -iname '*.dll' \) -print0)

    echo "Codesigning ${#PE_FILES[@]} files in dir ${TARGET}"
    BATCH=50
    for ((i = 0; i < ${#PE_FILES[@]}; i += BATCH)); do
        do_codesign "${PE_FILES[@]:i:BATCH}"
    done
    echo "Codesigned ${#PE_FILES[@]} files"
else
    echo "Given codesigning target '${TARGET}' not a file or directory!" >&2
    usage
    exit 1
fi
