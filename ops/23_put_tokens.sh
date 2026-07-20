#!/usr/bin/env bash
# Store a CI telemetry bearer token in SSM Parameter Store.
#
# Bearer tokens (codecov, coveralls, buildkite analytics) are inherently
# symmetric secrets and cannot be turned into KMS signing operations, so
# they live in the AWS secrets store and are fetched at job runtime by
# the julia-oidc-tokens-ci role (julia-ci only; PR builds get no
# tokens). Nothing secret is stored in the repository.
#
# Usage:
#   23_put_tokens.sh codecov_token             # prompts for the value
#   23_put_tokens.sh coveralls_token
#   23_put_tokens.sh buildkite_analytics_token
set -euo pipefail
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
# shellcheck source=SCRIPTDIR/common.sh
source "${SCRIPT_DIR}/common.sh"

NAME="${1:?usage: $0 <token-name>}"

if [[ ! "${NAME}" =~ ^[a-z0-9_]+$ ]]; then
    echo "ERROR: token name must be lowercase [a-z0-9_]" >&2
    exit 1
fi

read -r -s -p "Value for ${SSM_TOKEN_PREFIX}/${NAME}: " VALUE
echo

aws ssm put-parameter --region "${AWS_REGION}" \
    --name "${SSM_TOKEN_PREFIX}/${NAME}" \
    --type SecureString \
    --value "${VALUE}" \
    --overwrite

echo "Stored ${SSM_TOKEN_PREFIX}/${NAME}"
