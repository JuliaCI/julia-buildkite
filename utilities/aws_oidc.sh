#!/usr/bin/env bash
# Obtain AWS credentials for this Buildkite job via OIDC web identity
# federation. No static AWS secrets are involved: the job's identity
# (pipeline, ref, commit, step) is attested by Buildkite and verified by
# AWS IAM, which scopes what the job may do (see ops/ in this repo).
#
# Source this script with the desired role:
#
#     source .buildkite/utilities/aws_oidc.sh upload      # release uploads + signing
#     source .buildkite/utilities/aws_oidc.sh upload-pr   # PR uploads (write-once, sha path)
#     source .buildkite/utilities/aws_oidc.sh docs-deploy # docs deploy SSH signing via KMS
#     source .buildkite/utilities/aws_oidc.sh tokens      # CI telemetry tokens from SSM
#
# It exports AWS_WEB_IDENTITY_TOKEN_FILE / AWS_ROLE_ARN, which every AWS
# SDK and the AWS CLI use to assume the role automatically (and refresh
# as needed). The token carries AWS session tags (step_key, build_commit,
# ...) that IAM policies match against.

# AWS account that holds the Julia CI roles (not a secret).
# TODO: fill in after running ops/12_iam_roles.sh.
JULIA_CI_AWS_ACCOUNT_ID="${JULIA_CI_AWS_ACCOUNT_ID:-000000000000}"
JULIA_CI_AWS_REGION="${JULIA_CI_AWS_REGION:-us-east-1}"

if [[ "${JULIA_CI_AWS_ACCOUNT_ID}" == "000000000000" ]]; then
    echo "ERROR: JULIA_CI_AWS_ACCOUNT_ID placeholder not configured" >&2
    return 1 2>/dev/null || exit 1
fi

_OIDC_ROLE_SUFFIX="${1:?usage: source aws_oidc.sh <upload|upload-pr|docs-deploy|tokens>}"

_OIDC_TOKEN_FILE="$(mktemp)"
buildkite-agent oidc request-token \
    --audience "sts.amazonaws.com" \
    --lifetime 43200 \
    --aws-session-tag "organization_slug,pipeline_slug,build_branch,build_number,build_commit,step_key,job_id,agent_id" \
    > "${_OIDC_TOKEN_FILE}"

export AWS_WEB_IDENTITY_TOKEN_FILE="${_OIDC_TOKEN_FILE}"
export AWS_ROLE_ARN="arn:aws:iam::${JULIA_CI_AWS_ACCOUNT_ID}:role/julia-ci-${_OIDC_ROLE_SUFFIX}"
export AWS_ROLE_SESSION_NAME="bk-$(tr -dc 'a-zA-Z0-9=,.@-' <<<"${BUILDKITE_STEP_KEY:-job}" | cut -c1-48)-${BUILDKITE_BUILD_NUMBER:-0}"
export AWS_DEFAULT_REGION="${JULIA_CI_AWS_REGION}"
export AWS_REGION="${JULIA_CI_AWS_REGION}"

# Make sure stale static credentials can never shadow the role.
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

echo "AWS credentials: ${AWS_ROLE_ARN} (via Buildkite OIDC)"
