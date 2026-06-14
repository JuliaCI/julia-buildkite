#!/usr/bin/env bash
# DEBUG ONLY (not part of the publish flow). Diagnoses why rcodesign's Rust AWS
# SDK fails to resolve the Buildkite OIDC web-identity credentials with
# "identity resolver timed out after 5s", while the aws CLI / boto3 resolve the
# same token fine. Runs in the julia_publish sandbox via launch_debug.yml.
set -uo pipefail

echo "+++ [debug] host / environment"
uname -a
echo "AWS_* env keys present:"; env | grep -oE '^AWS_[A-Z0-9_]+' | sort || true

echo "+++ [debug] assume the throwaway test OIDC role"
# shellcheck source=SCRIPTDIR/../aws_oidc.sh
source .buildkite/utilities/aws_oidc.sh publish-test
echo "AWS_ROLE_ARN=${AWS_ROLE_ARN:-<unset>}"
echo "AWS_REGION=${AWS_REGION:-<unset>} AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION:-<unset>}"
echo "AWS_EC2_METADATA_DISABLED=${AWS_EC2_METADATA_DISABLED:-<unset>}"
_tok="${AWS_WEB_IDENTITY_TOKEN_FILE:-/nonexistent}"
echo "AWS_WEB_IDENTITY_TOKEN_FILE=${_tok} (exists: $([ -f "${_tok}" ] && echo yes || echo NO), bytes: $(wc -c <"${_tok}" 2>/dev/null || echo 0))"

echo "+++ [debug] DNS records for STS / KMS regional endpoints (any AAAA / IPv6?)"
getent ahosts sts.us-east-1.amazonaws.com || true
echo "  --- kms ---"
getent ahosts kms.us-east-1.amazonaws.com || true

echo "+++ [debug] raw IPv4 vs IPv6 reachability to STS (the credential endpoint)"
curl -4 -s -o /dev/null -w 'curl -4 sts: code=%{http_code} connect=%{time_connect}s total=%{time_total}s\n' --max-time 10 https://sts.us-east-1.amazonaws.com/ || echo 'curl -4 sts FAILED'
curl -6 -s -o /dev/null -w 'curl -6 sts: code=%{http_code} connect=%{time_connect}s total=%{time_total}s\n' --max-time 10 https://sts.us-east-1.amazonaws.com/ || echo 'curl -6 sts FAILED/none'

echo "+++ [debug] aws CLI sts get-caller-identity (known-good resolution path)"
time aws sts get-caller-identity || echo 'aws CLI FAILED'

RC="$(.buildkite/utilities/macos/get_rcodesign.sh)"
echo "+++ [debug] rcodesign = ${RC}"
"${RC}" --version 2>&1 || true
echo "debug-only throwaway file" > /tmp/_rc_dbg.txt

echo "+++ [debug] rcodesign GetPublicKey with FULL AWS SDK trace (expected to reproduce the timeout)"
( set -x
  RUST_LOG="aws_config=trace,aws_runtime=debug,aws_smithy_runtime=debug,aws_smithy_runtime_api=debug,aws_credential_types=trace,aws_sdk_sts=debug" \
    "${RC}" sign \
      --aws-kms-key alias/julia-macos-codesigning-test \
      --aws-kms-certificate-file .buildkite/utilities/macos/developer_id_test.pem \
      /tmp/_rc_dbg.txt 2>&1 | tail -150
) || true

echo "+++ [debug] control: rcodesign with EXPLICIT static creds minted by the CLI"
echo "(if this succeeds where the above failed, the bug is purely SDK credential resolution)"
if creds="$(aws sts assume-role-with-web-identity \
      --role-arn "${AWS_ROLE_ARN}" --role-session-name dbg \
      --web-identity-token "$(cat "${AWS_WEB_IDENTITY_TOKEN_FILE}")" \
      --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text)"; then
  read -r _AKID _SAK _STOK <<<"${creds}"
  ( set -x
    AWS_ACCESS_KEY_ID="${_AKID}" AWS_SECRET_ACCESS_KEY="${_SAK}" AWS_SESSION_TOKEN="${_STOK}" \
      "${RC}" sign \
        --aws-kms-key alias/julia-macos-codesigning-test \
        --aws-kms-certificate-file .buildkite/utilities/macos/developer_id_test.pem \
        /tmp/_rc_dbg.txt 2>&1 | tail -40
  ) || true
else
  echo "could not mint static creds via CLI"
fi

echo "+++ [debug] done"
