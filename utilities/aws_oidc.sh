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
# as needed). The token carries only the AWS session tags that the selected
# role's trust and permission policies match against.
# (Sourced file: deliberately no `set -euo pipefail` here -- shell options
# set in a sourced file leak into the calling script; strict mode belongs
# to the entrypoints.)

# AWS account that holds the Julia CI roles (not a secret).
JULIA_CI_AWS_ACCOUNT_ID="${JULIA_CI_AWS_ACCOUNT_ID:-873569884612}"
JULIA_CI_AWS_REGION="${JULIA_CI_AWS_REGION:-us-east-1}"

_OIDC_ROLE_SUFFIX="${1:?usage: source aws_oidc.sh <stage|publish|docs-deploy|tokens|publish-test>}"

# The trusted roles must only ever be requested from the dedicated publish
# pipeline. The IAM trust policy already enforces this (it only trusts the
# julia-publish* slug), but refuse early here too so a misconfiguration
# surfaces loudly rather than as a confusing AccessDenied. Pull request
# builds never run in a publish pipeline.
# publish-test resolves to the throwaway, non-production test role
# (julia-oidc-publish-test): it can only sign with the *-test KMS keys and
# read/write the test bucket. Like the production trusted roles it must come
# from a *publish* pipeline slug, but -- being harmless -- it is NOT refused on
# pull-request builds, so the test publish flow can be exercised from anywhere.
case "${_OIDC_ROLE_SUFFIX}" in
    publish|docs-deploy|publish-test)
        if [[ "${BUILDKITE_PIPELINE_SLUG:-}" != *publish* ]]; then
            echo "ERROR: ${_OIDC_ROLE_SUFFIX} role requested from non-publish pipeline '${BUILDKITE_PIPELINE_SLUG:-}'" >&2
            return 1 2>/dev/null || exit 1
        fi
        ;;&
    publish|docs-deploy)
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
        elif [[ "${BUILDKITE_PIPELINE_SLUG:-}" == julia-buildkite* ]]; then
            # The julia-buildkite repository's own self-test CI.
            _OIDC_ROLE_SUFFIX="stage-buildkite"
        else
            _OIDC_ROLE_SUFFIX="stage-ci"
        fi
        ;;
    tokens)
        # Only julia-ci has a tokens role (see ops/terraform/iam.tf): PR
        # builds and the julia-buildkite self-test run untrusted code that
        # could exfiltrate any bearer token available to the job.
        if [[ "${BUILDKITE_PIPELINE_SLUG:-}" != "julia-ci" || "${BUILDKITE_PULL_REQUEST:-false}" != "false" ]]; then
            echo "ERROR: bearer tokens are only available to julia-ci branch builds" >&2
            return 1 2>/dev/null || exit 1
        fi
        _OIDC_ROLE_SUFFIX="tokens-ci"
        ;;
esac

# The *_id tags carry the Buildkite UUIDs (not the renameable slugs); the
# IAM trust policies pin organization_id / pipeline_id / cluster_id so a
# recreated or renamed pipeline with a matching slug cannot assume a role.
case "${_OIDC_ROLE_SUFFIX}" in
    stage-pr|stage-ci|stage-buildkite)
        # Trust: org/pipeline/cluster IDs. Permission policy: own commit path.
        _OIDC_AWS_SESSION_TAGS="organization_id,pipeline_id,cluster_id,build_commit"
        ;;
    publish|docs-deploy)
        # Trust: org/pipeline/cluster IDs and step key. KMS policies also gate
        # the trusted roles by step_key.
        _OIDC_AWS_SESSION_TAGS="organization_id,pipeline_id,cluster_id,step_key"
        ;;
    tokens-ci|publish-test)
        # Trust only needs the immutable Buildkite IDs.
        _OIDC_AWS_SESSION_TAGS="organization_id,pipeline_id,cluster_id"
        ;;
    *)
        echo "ERROR: unknown OIDC role suffix '${_OIDC_ROLE_SUFFIX}'" >&2
        return 1 2>/dev/null || exit 1
        ;;
esac

# Buildkite caps the OIDC token lifetime at 7200s (2h). The AWS SDK/CLI
# re-assumes the role from the token file whenever the (1h) STS session
# expires, so jobs whose AWS usage spans more than ~2h must re-source
# this script to mint a fresh token (publish.sh does so per triplet).
_OIDC_TOKEN_FILE="$(mktemp)"
# Agent v3.104+ redacts the token from logs via the Job API (a unix socket),
# which is unreachable inside the publish sandbox and aborts the request. We
# write the token to a file and never echo it, so skip redaction -- but only
# on agents new enough to know the flag (older build-cluster agents reject it
# and aren't sandbox-broken). Detect by version: `--help` can't be probed,
# since on affected agents it too needs the Job API and aborts.
_OIDC_SKIP_REDACTION=()
_BK_VER="$(buildkite-agent --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)"
if [ -n "${_BK_VER}" ] && { [ "${_BK_VER%%.*}" -gt 3 ] || { [ "${_BK_VER%%.*}" -eq 3 ] && [ "${_BK_VER#*.}" -ge 104 ]; }; }; then
    _OIDC_SKIP_REDACTION=( --skip-redaction )
fi
buildkite-agent oidc request-token \
    --audience "sts.amazonaws.com" \
    --lifetime 7200 \
    "${_OIDC_SKIP_REDACTION[@]}" \
    --aws-session-tag "${_OIDC_AWS_SESSION_TAGS}" \
    > "${_OIDC_TOKEN_FILE}"

export AWS_WEB_IDENTITY_TOKEN_FILE="${_OIDC_TOKEN_FILE}"
export AWS_ROLE_ARN="arn:aws:iam::${JULIA_CI_AWS_ACCOUNT_ID}:role/julia-oidc-${_OIDC_ROLE_SUFFIX}"
export AWS_ROLE_SESSION_NAME="bk-$(tr -dc 'a-zA-Z0-9=,.@-' <<<"${BUILDKITE_STEP_KEY:-job}" | cut -c1-48)-${BUILDKITE_BUILD_NUMBER:-0}"
export AWS_DEFAULT_REGION="${JULIA_CI_AWS_REGION}"
export AWS_REGION="${JULIA_CI_AWS_REGION}"

# Make sure stale static credentials can never shadow the role.
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

echo "AWS credentials: ${AWS_ROLE_ARN} (via Buildkite OIDC)"
echo "AWS CLI: $(aws --version 2>&1 || true)"
