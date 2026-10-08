#!/usr/bin/env bash
# Upload one test job's results*.json files to Buildkite Test Engine.
#
# Runs in the julia-test-engine pipeline, which the build pipelines trigger
# once per test job (the "Test Engine" group rendered by
# render_launch_pipeline.py). The test job only stores results.tar.gz as a
# build artifact: a pull request runs attacker-controlled code inside the
# test job, so the suite token never reaches it. This job fetches that
# artifact and uploads it, attributing the results to the test job
# (run_env[job_id]) rather than to itself, as the pre-OIDC relay job did.
#
# Pull requests trigger this pipeline, so everything a trigger can set
# (branch, commit, message, env, meta-data) is untrusted; see
# pipelines/test-engine/0_webui.yml for the agent settings that keep that
# out of this job. The BUILDKITE_TRIGGERED_FROM_* values are set by
# Buildkite on the triggered build; the TEST_* values are display metadata
# for the Test Engine run and nothing else.
#
# Needs only buildkite-agent, curl (7.86+) and tar: the suite token is read
# from SSM with the julia-oidc-test-engine role, assumed through two plain
# HTTPS calls (STS needs no signature for AssumeRoleWithWebIdentity; curl
# signs the SSM request itself). No AWS CLI, sandbox or julia.
set -euo pipefail

# The AWS account that holds the Julia CI roles (not a secret; the same
# as utilities/aws_oidc.sh). Fixed here on purpose: the job's environment
# is trigger-chosen, so nothing that selects an endpoint may come from it.
JULIA_CI_AWS_ACCOUNT_ID="873569884612"
JULIA_CI_AWS_REGION="us-east-1"

# -q keeps curl from reading a .curlrc (the environment could point it at
# one). Secrets and the OIDC token go through files, never argv.
curl() { command curl -q --fail-with-body --silent --show-error "$@"; }

BUILD_ID="${BUILDKITE_TRIGGERED_FROM_BUILD_ID:?this pipeline is only triggered by the build pipelines}"
BUILD_NUMBER="${BUILDKITE_TRIGGERED_FROM_BUILD_NUMBER:?}"
BUILD_PIPELINE="${BUILDKITE_TRIGGERED_FROM_BUILD_PIPELINE_SLUG:?}"
STEP_KEY="${TEST_STEP_KEY:?}"
case "${BUILD_PIPELINE}" in
    julia-pr|julia-ci) ;;
    *) echo "ERROR: triggered from pipeline '${BUILD_PIPELINE}'; only julia-pr and julia-ci results are uploaded" >&2; exit 1 ;;
esac

SCRATCH="$(mktemp -d)"
trap 'rm -rf "${SCRATCH}"' EXIT
cd "${SCRATCH}"

echo "--- Locate the results of ${STEP_KEY} in ${BUILD_PIPELINE} build ${BUILD_NUMBER}"
# Scoped to the test step; retried jobs are excluded by default, so this is
# the latest attempt. %j is the id of the job that uploaded the artifact.
# A search error (not an empty result) fails this job: a silent skip is
# how the previous upload path went unnoticed.
JOB_ID="$(buildkite-agent artifact search --build "${BUILD_ID}" --step "${STEP_KEY}" \
    --allow-empty-results --format '%j\n' results.tar.gz | head -n1)"
if [[ -z "${JOB_ID}" ]]; then
    echo "No results.tar.gz from ${STEP_KEY}: the test job produced no results (it may have crashed or been cancelled). Nothing to upload."
    exit 0
fi
echo "Test job: ${JOB_ID}"

echo "--- Download results.tar.gz"
buildkite-agent artifact download --build "${BUILD_ID}" --step "${JOB_ID}" results.tar.gz .
mkdir results
tar -xzf results.tar.gz --no-same-owner -C results
# The archive comes from the test job: upload only plain files, so a
# symlink or directory in it cannot make curl post something else.
RESULTS=()
for file in results/results*.json; do
    if [[ -f "${file}" && ! -L "${file}" ]]; then
        RESULTS+=("${file}")
    fi
done
if [[ "${#RESULTS[@]}" -eq 0 ]]; then
    echo "results.tar.gz contains no results*.json files; nothing to upload"
    exit 0
fi

echo "--- Assume the julia-oidc-test-engine role"
# The IAM trust policy matches the org / pipeline / cluster UUIDs and the
# step key, which travel as session tags inside the OIDC token
# (ops/terraform/test_engine.tf).
buildkite-agent oidc request-token \
    --audience "sts.amazonaws.com" \
    --lifetime 600 \
    --aws-session-tag "organization_id,pipeline_id,cluster_id,step_key" \
    > oidc.jwt
curl --max-time 60 \
    --data "Action=AssumeRoleWithWebIdentity" \
    --data "Version=2011-06-15" \
    --data "RoleArn=arn:aws:iam::${JULIA_CI_AWS_ACCOUNT_ID}:role/julia-oidc-test-engine" \
    --data "RoleSessionName=bk-upload_test_results-${BUILDKITE_BUILD_NUMBER:-0}" \
    --data-urlencode "WebIdentityToken@oidc.jwt" \
    "https://sts.${JULIA_CI_AWS_REGION}.amazonaws.com/" > sts.xml \
    || { echo "AssumeRoleWithWebIdentity failed:" >&2; cat sts.xml >&2; exit 1; }
xml_field() { sed -n "s|.*<$1>\([^<]*\)</$1>.*|\1|p" sts.xml | head -n1; }
{
    echo "user = \"$(xml_field AccessKeyId):$(xml_field SecretAccessKey)\""
    echo "header = \"x-amz-security-token: $(xml_field SessionToken)\""
} > aws.curlrc
grep -q 'user = "[^:"]*:[^"]' aws.curlrc || { echo "AssumeRoleWithWebIdentity returned no credentials" >&2; exit 1; }

echo "--- Obtain the Test Engine suite token"
# curl signs every header it sends, as SigV4 requires for x-amz-* ones.
curl --max-time 60 \
    --config aws.curlrc \
    --aws-sigv4 "aws:amz:${JULIA_CI_AWS_REGION}:ssm" \
    --header "X-Amz-Target: AmazonSSM.GetParameter" \
    --header "Content-Type: application/x-amz-json-1.1" \
    --data '{"Name":"/julia-ci/tokens/buildkite_analytics_token","WithDecryption":true}' \
    "https://ssm.${JULIA_CI_AWS_REGION}.amazonaws.com/" > ssm.json \
    || { echo "SSM GetParameter failed:" >&2; cat ssm.json >&2; exit 1; }
TOKEN="$(sed -n 's/.*"Value":"\([^"]*\)".*/\1/p' ssm.json)"
[[ -n "${TOKEN}" ]] || { echo "SSM returned no token value" >&2; exit 1; }
echo "header = \"Authorization: Token token=\\\"${TOKEN}\\\"\"" > upload.curlrc
unset TOKEN

echo "--- Upload ${#RESULTS[@]} results files to Test Engine"
TEST_BUILD_URL="https://buildkite.com/${BUILDKITE_ORGANIZATION_SLUG:?}/${BUILD_PIPELINE}/builds/${BUILD_NUMBER}"
# Flaky-test monitors filter on the branch, by default the suite's default
# branch. The branch value comes from the trigger step, which a pull
# request authors, so a PR build's results are labelled so that they can
# never pass for a master run. julia-ci builds trusted refs only, and its
# trigger steps come from a pinned julia-buildkite, so its value stands.
BRANCH="${TEST_BRANCH:-}"
if [[ "${BUILD_PIPELINE}" == "julia-pr" ]]; then
    BRANCH="pr/${BRANCH}"
fi
for file in "${RESULTS[@]}"; do
    echo "Uploading ${file#results/}..."
    # Not the test-collector plugin: it uploads a single file per job and
    # cannot attribute the results to another job. --form-string sends the
    # metadata verbatim (a commit message may contain `;` or `@`).
    curl --max-time 300 \
      --config upload.curlrc \
      -F "data=@${file}" \
      --form-string "format=json" \
      --form-string "run_env[CI]=buildkite" \
      --form-string "run_env[key]=${BUILD_ID}" \
      --form-string "run_env[url]=${TEST_BUILD_URL}" \
      --form-string "run_env[branch]=${BRANCH}" \
      --form-string "tags[pipeline]=${BUILD_PIPELINE}" \
      --form-string "run_env[commit_sha]=${TEST_COMMIT:-}" \
      --form-string "run_env[number]=${BUILD_NUMBER}" \
      --form-string "run_env[job_id]=${JOB_ID}" \
      --form-string "run_env[message]=${TEST_MESSAGE:-}" \
      https://analytics-api.buildkite.com/v1/uploads
    echo ""
done
