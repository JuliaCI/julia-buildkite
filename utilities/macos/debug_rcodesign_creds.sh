#!/usr/bin/env bash
# DEBUG ONLY (not part of the publish flow). The real publish (#3) failed with
# rcodesign "identity resolver timed out after 5s" during codesign of the .app.
# A single rcodesign resolves the OIDC web-identity creds fine, so the suspect
# is codesign.sh's UNBOUNDED parallel signing: dozens of rcodesign processes
# each independently AssumeRoleWithWebIdentity against the one (proxied) STS
# endpoint, blowing the SDK's 5s credential-load budget.
#
# This isolates the variables: single vs parallel, IMDS-disabled or not, and
# tests the fix (resolve the role ONCE, share static creds with all processes).
#
# rcodesign's "specified path is not of a recognized type" on the throwaway
# file is the SUCCESS signal: it means GetPublicKey (=credential resolution)
# already succeeded. "identity resolver timed out" is the FAILURE signal.
set -uo pipefail

source .buildkite/utilities/aws_oidc.sh publish-test
RC="$(.buildkite/utilities/macos/get_rcodesign.sh)"
KEY="alias/julia-macos-codesigning-test"
CERT=".buildkite/utilities/macos/developer_id_test.pem"
echo "debug-only throwaway" > /tmp/_rc.txt
N=32

# Emit OK (creds resolved) / TIMEOUT (creds timed out) / OTHER for one sign.
run_one() {
    local out
    out="$("${RC}" sign --aws-kms-key "${KEY}" --aws-kms-certificate-file "${CERT}" /tmp/_rc.txt 2>&1)"
    if   grep -q "identity resolver timed out" <<<"${out}"; then echo "TIMEOUT"
    elif grep -q "not of a recognized type"    <<<"${out}"; then echo "OK"
    else echo "OTHER: $(tr '\n' '|' <<<"${out}" | tail -c 160)"; fi
}

batch() { # $1=label  (env for the children inherited from caller)
    local label="$1" tmp; tmp="$(mktemp -d)"
    local t0 t1; t0="$(date +%s)"
    for i in $(seq 1 "${N}"); do ( run_one ) > "${tmp}/${i}" & done
    wait
    t1="$(date +%s)"
    echo "+++ ${label}: ${N} parallel in $((t1-t0))s"
    sort "${tmp}"/* | uniq -c
    rm -rf "${tmp}"
}

echo "=== A: single, metadata default ==="; run_one
echo "=== B: single, AWS_EC2_METADATA_DISABLED=true (real-publish env) ==="; AWS_EC2_METADATA_DISABLED=true run_one

echo "=== C: parallel, default chain (each does its own STS AssumeRoleWithWebIdentity) ==="
batch "C default-chain"

echo "=== D: parallel, AWS_EC2_METADATA_DISABLED=true (EXACT real-publish repro) ==="
AWS_EC2_METADATA_DISABLED=true batch "D metadata-disabled"

echo "=== E: parallel, SHARED static creds resolved ONCE (proposed fix) ==="
read -r AKID SAK STOK < <(aws sts assume-role-with-web-identity \
    --role-arn "${AWS_ROLE_ARN}" --role-session-name fix \
    --web-identity-token "$(cat "${AWS_WEB_IDENTITY_TOKEN_FILE}")" \
    --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text)
export AWS_ACCESS_KEY_ID="${AKID}" AWS_SECRET_ACCESS_KEY="${SAK}" AWS_SESSION_TOKEN="${STOK}"
unset AWS_WEB_IDENTITY_TOKEN_FILE AWS_ROLE_ARN   # force the env-static provider
batch "E shared-static-creds"

echo "+++ [debug] done"
