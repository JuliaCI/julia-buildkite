#!/usr/bin/env bash
# Validate the OIDC/IAM trust boundaries from inside a build pipeline job,
# without building julia. Run it as the only step of a julia-pr (or
# julia-ci) build -- see ops/README.md "Validation" -- on a plain linux
# agent with the AWS CLI.
#
# Positive checks: assume this pipeline's stage role; write-once upload to
# this build's own staging path.
# Negative checks (must FAIL): overwrite; other pipeline's bucket; foreign
# commit path; bearer tokens on julia-pr; the trusted publish role.
# No -e: this is a check harness -- failures are counted and reported, not
# fatal; -u and pipefail still catch genuine script bugs.
set -uo pipefail

PASS=0
FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

command -v aws >/dev/null || { echo "ERROR: aws CLI not on this agent"; exit 1; }

SLUG="${BUILDKITE_PIPELINE_SLUG:?}"
case "${SLUG}" in
    julia-pr) MY_BUCKET="julialang-ephemeral-pr"; OTHER_BUCKET="julialang-ephemeral-ci"; MY_ROLE="julia-oidc-stage-pr" ;;
    julia-ci) MY_BUCKET="julialang-ephemeral-ci"; OTHER_BUCKET="julialang-ephemeral-pr"; MY_ROLE="julia-oidc-stage-ci" ;;
    *) echo "ERROR: run this from julia-pr or julia-ci (got '${SLUG}')"; exit 1 ;;
esac
PREFIX="${S3_BUCKET_PREFIX:-bin}"
KEY="${PREFIX}/${BUILDKITE_COMMIT:?}/oidc-smoke-${BUILDKITE_BUILD_NUMBER:?}.txt"
BODY="$(mktemp)"; echo "oidc smoke test build ${BUILDKITE_BUILD_NUMBER}" > "${BODY}"

put() { # put <bucket> <key> -> 0 on success
    # No --acl: the staging buckets disable object ACLs; public read comes
    # from the bucket policy (verified below).
    aws s3api put-object --bucket "$1" --key "$2" \
        --body "${BODY}" --if-none-match '*' 2>&1
}

echo "--- Assume the stage role"
echo "  agent: $(buildkite-agent --version 2>/dev/null || echo unknown)"
# shellcheck source=SCRIPTDIR/../aws_oidc.sh
source .buildkite/utilities/aws_oidc.sh stage
export AWS_EC2_METADATA_DISABLED=true
IDENTITY="$(aws sts get-caller-identity --query Arn --output text)" || IDENTITY=""
echo "  caller identity: ${IDENTITY}"
if [[ "${IDENTITY}" == *"${MY_ROLE}"* ]]; then
    ok "assumed ${MY_ROLE}"
else
    # Without credentials every later check is vacuous; abort hard rather
    # than report misleading PASSes on the denial checks.
    bad "expected to assume ${MY_ROLE}, got '${IDENTITY}'"
    echo "+++ aborting: no credentials, the remaining checks would be meaningless"
    exit 1
fi

echo "--- Write-once upload to own staging path"
if OUT="$(put "${MY_BUCKET}" "${KEY}")"; then
    ok "wrote s3://${MY_BUCKET}/${KEY}"
else
    bad "could not write own staging path: ${OUT}"
fi

echo "--- Anonymous public read of the staged object (the juliaup contract)"
if curl -sf -o /dev/null "https://${MY_BUCKET}.s3.amazonaws.com/${KEY}"; then
    ok "anonymous GET of s3://${MY_BUCKET}/${KEY}"
else
    bad "staged object is not publicly readable"
fi

echo "--- Negative: overwrite of an existing object"
if OUT="$(put "${MY_BUCKET}" "${KEY}")"; then
    bad "overwrite unexpectedly succeeded"
else
    [[ "${OUT}" == *"PreconditionFailed"* || "${OUT}" == *"412"* || "${OUT}" == *"AccessDenied"* ]] \
        && ok "overwrite refused" \
        || bad "overwrite failed with unexpected error: ${OUT}"
fi

echo "--- Negative: other pipeline's staging bucket"
if OUT="$(put "${OTHER_BUCKET}" "${KEY}")"; then
    bad "wrote to ${OTHER_BUCKET} -- cross-pipeline isolation broken!"
else
    ok "denied on ${OTHER_BUCKET}"
fi

echo "--- Negative: foreign commit path in own bucket"
FOREIGN_KEY="${PREFIX}/0000000000000000000000000000000000000000/oidc-smoke.txt"
if OUT="$(put "${MY_BUCKET}" "${FOREIGN_KEY}")"; then
    bad "wrote under a foreign commit sha -- commit gating broken!"
else
    ok "denied under foreign commit sha"
fi

echo "--- Negative: release bucket"
if OUT="$(put "julialangnightlies" "bin/oidc-smoke.txt")"; then
    bad "wrote to the release bucket -- this must never happen!"
else
    ok "denied on the release bucket"
fi

echo "--- Bearer tokens"
if [[ "${SLUG}" == "julia-pr" ]]; then
    if (source .buildkite/utilities/aws_oidc.sh tokens) 2>/dev/null; then
        bad "tokens role obtainable on julia-pr"
    else
        ok "tokens refused on julia-pr (by aws_oidc.sh)"
    fi
else
    if (source .buildkite/utilities/aws_oidc.sh tokens \
            && aws sts get-caller-identity --query Arn --output text | grep -q tokens-ci); then
        ok "tokens-ci role assumable from julia-ci"
    else
        bad "tokens-ci role not assumable from julia-ci"
    fi
fi

echo "--- Negative: the trusted publish role (raw STS, bypassing aws_oidc.sh guards)"
_PUB_TOKEN="$(mktemp)"
buildkite-agent oidc request-token \
    --audience "sts.amazonaws.com" \
    --lifetime 600 \
    --aws-session-tag "organization_slug,organization_id,pipeline_slug,pipeline_id,cluster_id,build_branch,build_number,build_commit,step_key,job_id,agent_id" \
    > "${_PUB_TOKEN}"
PUBLISH_ROLE_ARN="${AWS_ROLE_ARN%/*}/julia-oidc-publish"
if OUT="$(aws sts assume-role-with-web-identity \
        --role-arn "${PUBLISH_ROLE_ARN}" \
        --role-session-name smoke-test \
        --web-identity-token "file://${_PUB_TOKEN}" 2>&1)"; then
    bad "assumed the PUBLISH role from a build pipeline -- trust policy broken!"
else
    ok "publish role refused by STS"
fi
rm -f "${_PUB_TOKEN}" "${BODY}"

echo
echo "+++ ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
