#!/usr/bin/env bash
# Create / update the IAM roles assumed by Buildkite jobs via OIDC.
#
# Trust is split into an untrusted tier and a trusted tier so that pull
# request builds can never reach signing keys or release locations:
#
#   julia-oidc-stage    UNTRUSTED. Assumable from any ref of the build
#                     pipelines (PRs included). May only write unsigned
#                     artifacts, write-once, to a path gated by the build's
#                     own commit sha (bin/staging/<commit>/...). No KMS, no
#                     final-location write. Because its permissions are
#                     harmless, the spoofable `ref` component of the sub
#                     claim does not matter here.
#   julia-oidc-publish  TRUSTED. kms:Sign with the signing keys, read the
#                     staging area, and write the final release locations.
#                     Assumable ONLY from the `julia-publish` pipeline slug.
#                     That pipeline must have pull-request builds DISABLED
#                     and be branch-limited to master/release-*/v* (see
#                     ops/README.md). Since a PR can never produce a build
#                     under that slug, the slug is the trust boundary -- not
#                     the (PR-spoofable) branch name.
#   julia-oidc-docs-deploy  TRUSTED. kms:Sign with the docs SSH key; publish
#                     pipeline only.
#   julia-oidc-tokens   Low-value telemetry bearer tokens from SSM; build
#                     pipelines.
#
# Defense in depth: trusted publish jobs additionally run
# utilities/verify_trusted_commit.sh before assuming this role, which
# refuses unless BUILDKITE_COMMIT is reachable from a protected ref of the
# canonical JuliaLang/julia repository.
#
# Overwrite protection: every PutObject must use the S3 conditional write
# header (s3:if-none-match = "*"), i.e. uploads fail if the object already
# exists. The only exception is `julia-latest-*` pointer objects, which the
# publish pipeline intentionally repoints.
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
STAGE="${S3_STAGING_SUBPREFIX}"

# ---- julia-oidc-stage (UNTRUSTED) ----------------------------------------------
# Write-once, to bin/staging/<own commit sha>/ only. The build_commit tag is
# attested by Buildkite (not settable by the job), so a build can only ever
# write under its own source commit.

trust_policy "${WORK}/stage-trust.json" "stage_*" "${BUILD_SUB_PATTERNS[@]}"
ensure_role "${ROLE_STAGE}" "${WORK}/stage-trust.json" \
    "Buildkite staging upload: write-once to <bucket>/staging/<commit>/ (via OIDC)"

cat > "${WORK}/stage-policy.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "WriteOnceToOwnCommitStagingPath",
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:PutObjectAcl"],
      "Resource": [
        "${BUCKET_ARN}/${PREFIX}/${STAGE}/\${aws:PrincipalTag/build_commit}/*",
        "${NOGPL_ARN}/${NOGPL_PREFIX}/${STAGE}/\${aws:PrincipalTag/build_commit}/*",
        "${EPHEMERAL_ARN}/${EPHEMERAL_PREFIX}/${STAGE}/\${aws:PrincipalTag/build_commit}/*"
      ],
      "Condition": { "StringEquals": { "s3:if-none-match": "*" } }
    },
    {
      "Sid": "ReadStagingForRetryChecks",
      "Effect": "Allow",
      "Action": ["s3:GetObject"],
      "Resource": [
        "${BUCKET_ARN}/${PREFIX}/${STAGE}/*",
        "${NOGPL_ARN}/${NOGPL_PREFIX}/${STAGE}/*",
        "${EPHEMERAL_ARN}/${EPHEMERAL_PREFIX}/${STAGE}/*"
      ]
    }
  ]
}
EOF
aws iam put-role-policy --role-name "${ROLE_STAGE}" \
    --policy-name stage --policy-document "file://${WORK}/stage-policy.json"

# ---- julia-oidc-publish (TRUSTED) ----------------------------------------------
# Sign + promote staged artifacts to the final release locations. Assumable
# only from the julia-publish pipeline slug (PR builds disabled there).

trust_policy "${WORK}/publish-trust.json" "publish_*" "${PUBLISH_SUB_PATTERNS[@]}"
ensure_role "${ROLE_PUBLISH}" "${WORK}/publish-trust.json" \
    "Buildkite publish: sign + promote staged artifacts to release (via OIDC)"

cat > "${WORK}/publish-policy.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ReadStagedArtifacts",
      "Effect": "Allow",
      "Action": ["s3:GetObject"],
      "Resource": [
        "${BUCKET_ARN}/${PREFIX}/${STAGE}/*",
        "${NOGPL_ARN}/${NOGPL_PREFIX}/${STAGE}/*",
        "${EPHEMERAL_ARN}/${EPHEMERAL_PREFIX}/${STAGE}/*"
      ]
    },
    {
      "Sid": "WriteOnceToFinalLocations",
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:PutObjectAcl"],
      "Resource": [
        "${BUCKET_ARN}/${PREFIX}/*",
        "${NOGPL_ARN}/${NOGPL_PREFIX}/*",
        "${EPHEMERAL_ARN}/${EPHEMERAL_PREFIX}/*"
      ],
      "Condition": { "StringEquals": { "s3:if-none-match": "*" } }
    },
    {
      "Sid": "RepointLatestPointers",
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:PutObjectAcl"],
      "Resource": [
        "${BUCKET_ARN}/${PREFIX}/*/julia-latest-*",
        "${BUCKET_ARN}/${PREFIX}/*/*/julia-latest-*",
        "${BUCKET_ARN}/${PREFIX}/*/*/*/julia-latest-*",
        "${NOGPL_ARN}/${NOGPL_PREFIX}/*/julia-latest-*",
        "${NOGPL_ARN}/${NOGPL_PREFIX}/*/*/julia-latest-*",
        "${NOGPL_ARN}/${NOGPL_PREFIX}/*/*/*/julia-latest-*",
        "${EPHEMERAL_ARN}/${EPHEMERAL_PREFIX}/*/julia-latest-*",
        "${EPHEMERAL_ARN}/${EPHEMERAL_PREFIX}/*/*/julia-latest-*",
        "${EPHEMERAL_ARN}/${EPHEMERAL_PREFIX}/*/*/*/julia-latest-*"
      ]
    },
    {
      "Sid": "ReadFinalForRetryChecks",
      "Effect": "Allow",
      "Action": ["s3:GetObject"],
      "Resource": [
        "${BUCKET_ARN}/${PREFIX}/*",
        "${NOGPL_ARN}/${NOGPL_PREFIX}/*",
        "${EPHEMERAL_ARN}/${EPHEMERAL_PREFIX}/*"
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
        "StringLike": { "aws:PrincipalTag/step_key": "publish_*" }
      }
    }
  ]
}
EOF
aws iam put-role-policy --role-name "${ROLE_PUBLISH}" \
    --policy-name publish --policy-document "file://${WORK}/publish-policy.json"

# ---- julia-oidc-docs-deploy (TRUSTED) ------------------------------------------

trust_policy "${WORK}/docs-trust.json" "deploy_docs" "${PUBLISH_SUB_PATTERNS[@]}"
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

# ---- julia-oidc-tokens ---------------------------------------------------------
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
for role in "${ROLE_STAGE}" "${ROLE_PUBLISH}" "${ROLE_DOCS_DEPLOY}" "${ROLE_TOKENS}"; do
    aws iam get-role --role-name "${role}" --query Role.Arn --output text
done
