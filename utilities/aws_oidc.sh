#!/usr/bin/env bash
# Obtain AWS credentials for this Buildkite job via OIDC web identity
# federation. No static AWS secrets are involved: the job's identity
# (pipeline, ref, commit, step) is attested by Buildkite and verified by
# AWS IAM, which scopes what the job may do (see ops/ in this repo).
#
# Source this script with the desired role:
#
#     source .buildkite/utilities/aws_oidc.sh stage       # untrusted: write-once to own pipeline's staging bucket, <sha>/ path
#     source .buildkite/utilities/aws_oidc.sh publish     # trusted: sign + promote to final (publish pipeline only)
#     source .buildkite/utilities/aws_oidc.sh docs-deploy # trusted: docs deploy SSH signing via KMS
#     source .buildkite/utilities/aws_oidc.sh tokens      # CI telemetry tokens from SSM (julia-ci only)
#
# The untrusted roles exist once per build pipeline (julia-oidc-stage-pr /
# julia-oidc-stage-ci, ...): `stage` resolves to this pipeline's role.
# `tokens` resolves to julia-oidc-tokens-ci and is refused on pull request
# builds -- a PR runs attacker-controlled code inside the job, so PR
# builds get no bearer tokens at all.
#
# The `publish` and `docs-deploy` roles are only assumable from the
# `julia-publish` pipeline (PR builds disabled there); callers should also
# run verify_trusted_commit.sh first as defense in depth.
#
# It exports AWS_WEB_IDENTITY_TOKEN_FILE / AWS_ROLE_ARN, which every AWS
# SDK and the AWS CLI use to assume the role automatically (and refresh
# as needed). The token carries AWS session tags (step_key, build_commit,
# ...) that IAM policies match against.

# AWS account that holds the Julia CI roles (not a secret).
# TODO: fill in after applying ops/terraform (output julia_ci_aws_account_id).
JULIA_CI_AWS_ACCOUNT_ID="${JULIA_CI_AWS_ACCOUNT_ID:-000000000000}"
JULIA_CI_AWS_REGION="${JULIA_CI_AWS_REGION:-us-east-1}"

if [[ "${JULIA_CI_AWS_ACCOUNT_ID}" == "000000000000" ]]; then
    echo "ERROR: JULIA_CI_AWS_ACCOUNT_ID placeholder not configured" >&2
    return 1 2>/dev/null || exit 1
fi

_OIDC_ROLE_SUFFIX="${1:?usage: source aws_oidc.sh <stage|publish|docs-deploy|tokens>}"

# The trusted roles must only ever be requested from the dedicated publish
# pipeline. The IAM trust policy already enforces this (it only trusts the
# julia-publish* slug), but refuse early here too so a misconfiguration
# surfaces loudly rather than as a confusing AccessDenied. Pull request
# builds never run in a publish pipeline.
case "${_OIDC_ROLE_SUFFIX}" in
    publish|docs-deploy)
        if [[ "${BUILDKITE_PIPELINE_SLUG:-}" != *publish* ]]; then
            echo "ERROR: ${_OIDC_ROLE_SUFFIX} role requested from non-publish pipeline '${BUILDKITE_PIPELINE_SLUG:-}'" >&2
            return 1 2>/dev/null || exit 1
        fi
        if [[ "${BUILDKITE_PULL_REQUEST:-false}" != "false" ]]; then
            echo "ERROR: ${_OIDC_ROLE_SUFFIX} role must not be requested on a pull request build" >&2
            return 1 2>/dev/null || exit 1
        fi
        ;;
esac

# The untrusted roles exist once per build pipeline; resolve to ours.
case "${_OIDC_ROLE_SUFFIX}" in
    stage)
        if [[ "${BUILDKITE_PIPELINE_SLUG:-}" == "julia-pr" ]]; then
            _OIDC_ROLE_SUFFIX="stage-pr"
        else
            _OIDC_ROLE_SUFFIX="stage-ci"
        fi
        ;;
    tokens)
        # There is no tokens-pr role on purpose (see ops/terraform/iam.tf).
        if [[ "${BUILDKITE_PIPELINE_SLUG:-}" == "julia-pr" || "${BUILDKITE_PULL_REQUEST:-false}" != "false" ]]; then
            echo "ERROR: bearer tokens are not available on pull request builds" >&2
            return 1 2>/dev/null || exit 1
        fi
        _OIDC_ROLE_SUFFIX="tokens-ci"
        ;;
esac

# The *_id tags carry the Buildkite UUIDs (not the renameable slugs); the
# IAM trust policies pin organization_id / pipeline_id / cluster_id so a
# recreated or renamed pipeline with a matching slug cannot assume a role.
_OIDC_TOKEN_FILE="$(mktemp)"
buildkite-agent oidc request-token \
    --audience "sts.amazonaws.com" \
    --lifetime 43200 \
    --aws-session-tag "organization_slug,organization_id,pipeline_slug,pipeline_id,cluster_id,build_branch,build_number,build_commit,step_key,job_id,agent_id" \
    > "${_OIDC_TOKEN_FILE}"

export AWS_WEB_IDENTITY_TOKEN_FILE="${_OIDC_TOKEN_FILE}"
export AWS_ROLE_ARN="arn:aws:iam::${JULIA_CI_AWS_ACCOUNT_ID}:role/julia-oidc-${_OIDC_ROLE_SUFFIX}"
export AWS_ROLE_SESSION_NAME="bk-$(tr -dc 'a-zA-Z0-9=,.@-' <<<"${BUILDKITE_STEP_KEY:-job}" | cut -c1-48)-${BUILDKITE_BUILD_NUMBER:-0}"
export AWS_DEFAULT_REGION="${JULIA_CI_AWS_REGION}"
export AWS_REGION="${JULIA_CI_AWS_REGION}"

# Make sure stale static credentials can never shadow the role.
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

echo "AWS credentials: ${AWS_ROLE_ARN} (via Buildkite OIDC)"
