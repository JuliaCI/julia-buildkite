#!/usr/bin/env bash
# Create / update the IAM roles assumed by Buildkite jobs via OIDC.
#
# Trust model:
#   * All roles trust only tokens issued by agent.buildkite.com for our
#     Buildkite organization, with audience sts.amazonaws.com.
#   * The `sub` claim pins pipeline + ref, so only release refs
#     (master / release-* / v* tags) can assume the release roles.
#   * Tokens carry AWS session tags (step_key, build_commit, ...);
#     trust policies require the expected step_key at assume time and
#     permission policies use ${aws:PrincipalTag/...} to scope resources.
#
# Roles:
#   julia-ci-upload      release uploads + signing (S3 put, kms:Sign)
#   julia-ci-upload-pr   PR uploads, write-once, only to a path containing
#                        the source git sha (bin/pr/<commit>/...)
#   julia-ci-docs-deploy kms:Sign with the SSH docs deploy key (SSH via
#                        the aws-kms-pkcs11 provider; key never leaves KMS)
#   julia-ci-tokens      read CI telemetry bearer tokens from SSM
#
# Overwrite protection: roles may only PutObject with the S3 conditional
# write header (If-None-Match: *), i.e. uploads fail if the object already
# exists. The only exception is `julia-latest-*` pointer objects, which are
# intentionally repointed by every release build.
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
source "${SCRIPT_DIR}/common.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

MACOS_KEY_ARN="$(kms_key_arn "${KMS_ALIAS_MACOS_CODESIGN}")"
NOTARY_KEY_ARN="$(kms_key_arn "${KMS_ALIAS_NOTARY_API}")"
TARBALL_KEY_ARN="$(kms_key_arn "${KMS_ALIAS_TARBALL_SIGNING}")"
DOCS_KEY_ARN="$(kms_key_arn "${KMS_ALIAS_DOCS_DEPLOY}")"

for arn in "${MACOS_KEY_ARN}" "${NOTARY_KEY_ARN}" "${TARBALL_KEY_ARN}" "${DOCS_KEY_ARN}"; do
    if [[ -z "${arn}" || "${arn}" == "None" ]]; then
        echo "ERROR: KMS keys missing; run 11_kms_keys.sh first" >&2
        exit 1
    fi
done

# trust_policy <output-file> <step-key-pattern> <sub-pattern>...
trust_policy() {
    local out="$1" step_pattern="$2"
    shift 2
    cat > "${out}" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Federated": "${OIDC_PROVIDER_ARN}" },
      "Action": ["sts:AssumeRoleWithWebIdentity", "sts:TagSession"],
      "Condition": {
        "StringEquals": {
          "${BK_OIDC_HOST}:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "${BK_OIDC_HOST}:sub": [ $(json_array "$@") ],
          "aws:RequestTag/step_key": "${step_pattern}"
        }
      }
    }
  ]
}
EOF
}

BUCKET_ARN="arn:aws:s3:::${S3_BUCKET}"
PREFIX="${S3_BUCKET_PREFIX}"
EPHEMERAL_ARN="arn:aws:s3:::${S3_EPHEMERAL_BUCKET}"
EPHEMERAL_PREFIX="${S3_EPHEMERAL_PREFIX}"
NOGPL_ARN="arn:aws:s3:::${S3_NOGPL_BUCKET}"
NOGPL_PREFIX="${S3_NOGPL_PREFIX}"

# ---- julia-ci-upload ---------------------------------------------------------

trust_policy "${WORK}/upload-trust.json" "upload_*" "${RELEASE_SUB_PATTERNS[@]}"
ensure_role "${ROLE_UPLOAD}" "${WORK}/upload-trust.json" \
    "Buildkite release upload + signing (via OIDC; managed by julia-buildkite/ops)"

cat > "${WORK}/upload-policy.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "WriteOncePuts",
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:PutObjectAcl"],
      "Resource": [
        "${BUCKET_ARN}/${PREFIX}/*",
        "${EPHEMERAL_ARN}/${EPHEMERAL_PREFIX}/*",
        "${NOGPL_ARN}/${NOGPL_PREFIX}/*"
      ],
      "Condition": { "StringEquals": { "s3:if-none-match": "*" } }
    },
    {
      "Sid": "LatestPointerPuts",
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:PutObjectAcl"],
      "Resource": [
        "${BUCKET_ARN}/${PREFIX}/*/julia-latest-*",
        "${BUCKET_ARN}/${PREFIX}/*/*/julia-latest-*",
        "${BUCKET_ARN}/${PREFIX}/*/*/*/julia-latest-*",
        "${EPHEMERAL_ARN}/${EPHEMERAL_PREFIX}/*/julia-latest-*",
        "${EPHEMERAL_ARN}/${EPHEMERAL_PREFIX}/*/*/julia-latest-*",
        "${EPHEMERAL_ARN}/${EPHEMERAL_PREFIX}/*/*/*/julia-latest-*",
        "${NOGPL_ARN}/${NOGPL_PREFIX}/*/julia-latest-*",
        "${NOGPL_ARN}/${NOGPL_PREFIX}/*/*/julia-latest-*",
        "${NOGPL_ARN}/${NOGPL_PREFIX}/*/*/*/julia-latest-*"
      ]
    },
    {
      "Sid": "ReadForRetryChecks",
      "Effect": "Allow",
      "Action": ["s3:GetObject"],
      "Resource": [
        "${BUCKET_ARN}/${PREFIX}/*",
        "${EPHEMERAL_ARN}/${EPHEMERAL_PREFIX}/*",
        "${NOGPL_ARN}/${NOGPL_PREFIX}/*"
      ]
    },
    {
      "Sid": "ReleaseSigning",
      "Effect": "Allow",
      "Action": ["kms:Sign", "kms:GetPublicKey"],
      "Resource": [
        "${MACOS_KEY_ARN}",
        "${NOTARY_KEY_ARN}",
        "${TARBALL_KEY_ARN}"
      ],
      "Condition": {
        "StringLike": { "aws:PrincipalTag/step_key": "upload_*" }
      }
    }
  ]
}
EOF
aws iam put-role-policy --role-name "${ROLE_UPLOAD}" \
    --policy-name upload --policy-document "file://${WORK}/upload-policy.json"

# ---- julia-ci-upload-pr ------------------------------------------------------

trust_policy "${WORK}/upload-pr-trust.json" "upload_*" "${PR_SUB_PATTERNS[@]}"
ensure_role "${ROLE_UPLOAD_PR}" "${WORK}/upload-pr-trust.json" \
    "Buildkite PR upload: write-once to bin/pr/<commit>/ only (via OIDC)"

cat > "${WORK}/upload-pr-policy.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "WriteOncePutsToOwnCommitPath",
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:PutObjectAcl"],
      "Resource": [
        "${BUCKET_ARN}/${PREFIX}/pr/\${aws:PrincipalTag/build_commit}/*",
        "${NOGPL_ARN}/${NOGPL_PREFIX}/pr/\${aws:PrincipalTag/build_commit}/*"
      ],
      "Condition": { "StringEquals": { "s3:if-none-match": "*" } }
    },
    {
      "Sid": "WriteOncePutsToEphemeralTestBucket",
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:PutObjectAcl"],
      "Resource": "${EPHEMERAL_ARN}/${EPHEMERAL_PREFIX}/*",
      "Condition": { "StringEquals": { "s3:if-none-match": "*" } }
    },
    {
      "Sid": "EphemeralLatestPointerPuts",
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:PutObjectAcl"],
      "Resource": [
        "${EPHEMERAL_ARN}/${EPHEMERAL_PREFIX}/*/julia-latest-*",
        "${EPHEMERAL_ARN}/${EPHEMERAL_PREFIX}/*/*/julia-latest-*",
        "${EPHEMERAL_ARN}/${EPHEMERAL_PREFIX}/*/*/*/julia-latest-*"
      ]
    },
    {
      "Sid": "ReadForRetryChecks",
      "Effect": "Allow",
      "Action": ["s3:GetObject"],
      "Resource": [
        "${BUCKET_ARN}/${PREFIX}/pr/*",
        "${NOGPL_ARN}/${NOGPL_PREFIX}/pr/*",
        "${EPHEMERAL_ARN}/${EPHEMERAL_PREFIX}/*"
      ]
    }
  ]
}
EOF
aws iam put-role-policy --role-name "${ROLE_UPLOAD_PR}" \
    --policy-name upload-pr --policy-document "file://${WORK}/upload-pr-policy.json"

# ---- julia-ci-docs-deploy ----------------------------------------------------

trust_policy "${WORK}/docs-trust.json" "deploy_docs" "${RELEASE_SUB_PATTERNS[@]}"
ensure_role "${ROLE_DOCS_DEPLOY}" "${WORK}/docs-trust.json" \
    "Buildkite docs deploy: SSH signing via KMS (aws-kms-pkcs11, via OIDC)"

cat > "${WORK}/docs-policy.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "SshSignViaDocsDeployKey",
      "Effect": "Allow",
      "Action": ["kms:Sign", "kms:GetPublicKey"],
      "Resource": "${DOCS_KEY_ARN}",
      "Condition": {
        "StringEquals": { "aws:PrincipalTag/step_key": "deploy_docs" }
      }
    }
  ]
}
EOF
aws iam put-role-policy --role-name "${ROLE_DOCS_DEPLOY}" \
    --policy-name docs-deploy --policy-document "file://${WORK}/docs-policy.json"

# ---- julia-ci-tokens ---------------------------------------------------------
# CI telemetry bearer tokens (codecov, coveralls, buildkite analytics) are
# inherently symmetric secrets, so they live in SSM Parameter Store
# (SecureString, see 23_put_tokens.sh) and are fetched at runtime by this
# role. Nothing secret is stored in the repository.

trust_policy "${WORK}/tokens-trust.json" "ignored" "${TOKEN_SUB_PATTERNS[@]}"
# Two step families may read tokens: coverage-* and upload_results_*
python3 - "${WORK}/tokens-trust.json" <<'PYEOF'
import json, sys
path = sys.argv[1]
doc = json.load(open(path))
cond = doc["Statement"][0]["Condition"]["StringLike"]
cond["aws:RequestTag/step_key"] = ["coverage-*", "upload_results_*"]
json.dump(doc, open(path, "w"), indent=2)
PYEOF
ensure_role "${ROLE_TOKENS}" "${WORK}/tokens-trust.json" \
    "Buildkite CI telemetry: read coverage/analytics tokens from SSM (via OIDC)"

cat > "${WORK}/tokens-policy.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ReadTelemetryTokens",
      "Effect": "Allow",
      "Action": ["ssm:GetParameter"],
      "Resource": "arn:aws:ssm:${AWS_REGION}:${ACCOUNT_ID}:parameter${SSM_TOKEN_PREFIX}/*"
    }
  ]
}
EOF
aws iam put-role-policy --role-name "${ROLE_TOKENS}" \
    --policy-name tokens --policy-document "file://${WORK}/tokens-policy.json"

echo
echo "Roles configured:"
for role in "${ROLE_UPLOAD}" "${ROLE_UPLOAD_PR}" "${ROLE_DOCS_DEPLOY}" "${ROLE_TOKENS}"; do
    aws iam get-role --role-name "${role}" --query Role.Arn --output text
done
