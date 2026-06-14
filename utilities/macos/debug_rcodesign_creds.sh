#!/usr/bin/env bash
# DEBUG ONLY. Reproduce the real-publish rcodesign "identity resolver timed out
# after 5s" at realistic scale and test the candidate fixes.
#
# codesign.sh signs every executable in the bundled Julia tree (HUNDREDS of
# dylibs) with an UNBOUNDED `rcodesign &` fan-out; each process independently
# AssumeRoleWithWebIdentity against the single proxied STS hop. 32-way didn't
# reproduce it, so push to a realistic count and compare fixes:
#   C  uncapped, default chain   -> expected: some TIMEOUT (repro)
#   F  capped at 8, default chain -> expected: all OK (fix = bound concurrency)
#   E  uncapped, shared creds     -> expected: all OK (fix = one STS call, env creds)
#
# rcodesign "not of a recognized type" on the throwaway file == creds resolved
# OK (got past GetPublicKey). "identity resolver timed out" == creds failed.
set -uo pipefail

source .buildkite/utilities/aws_oidc.sh publish-test
RC="$(.buildkite/utilities/macos/get_rcodesign.sh)"
KEY="alias/julia-macos-codesigning-test"
CERT=".buildkite/utilities/macos/developer_id_test.pem"
echo "debug-only throwaway" > /tmp/_rc.txt
export RC KEY CERT
N=200

# Run $1 signs with up to $2 concurrent (xargs -P), tally OK/TIMEOUT/OTHER.
run_batch() { # $1=total $2=cap $3=label
    local t0 t1; t0="$(date +%s)"
    local res
    res="$(seq 1 "$1" | xargs -P "$2" -I{} bash -c '
        out="$("$RC" sign --aws-kms-key "$KEY" --aws-kms-certificate-file "$CERT" /tmp/_rc.txt 2>&1)"
        if   grep -q "identity resolver timed out" <<<"$out"; then echo TIMEOUT
        elif grep -q "not of a recognized type"    <<<"$out"; then echo OK
        else echo "OTHER:$(tr "\n" "|" <<<"$out" | tail -c 100)"; fi')"
    t1="$(date +%s)"
    echo "+++ ${3}: total=$1 cap=$2 in $((t1-t0))s"
    sort <<<"${res}" | uniq -c
}

echo "=== C: ${N} signs UNCAPPED, default chain (reproduce) ==="
run_batch "${N}" "${N}" "C uncapped default-chain"

echo "=== F: ${N} signs CAPPED at 8, default chain (fix A: bound concurrency) ==="
run_batch "${N}" 8 "F capped-8 default-chain"

echo "=== E: ${N} signs UNCAPPED, SHARED static creds resolved ONCE (fix B: share creds) ==="
read -r AKID SAK STOK < <(aws sts assume-role-with-web-identity \
    --role-arn "${AWS_ROLE_ARN}" --role-session-name fix \
    --web-identity-token "$(cat "${AWS_WEB_IDENTITY_TOKEN_FILE}")" \
    --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text)
export AWS_ACCESS_KEY_ID="${AKID}" AWS_SECRET_ACCESS_KEY="${SAK}" AWS_SESSION_TOKEN="${STOK}"
unset AWS_WEB_IDENTITY_TOKEN_FILE AWS_ROLE_ARN
run_batch "${N}" "${N}" "E uncapped shared-creds"

echo "+++ [debug] done"
