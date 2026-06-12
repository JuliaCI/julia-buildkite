# Shared configuration for the julia-buildkite AWS ops scripts.
# Source this from the numbered scripts; do not run directly.
#
# All scripts are idempotent: safe to re-run after partial failures.

set -euo pipefail

# --- Configuration (override via environment) --------------------------------

export AWS_REGION="${AWS_REGION:-us-east-1}"

# Buildkite organization slug
export BK_ORG="${BK_ORG:-julialang}"

# S3 bucket + prefix that release binaries are uploaded to
export S3_BUCKET="${S3_BUCKET:-julialangnightlies}"
export S3_BUCKET_PREFIX="${S3_BUCKET_PREFIX:-bin}"

# Bucket + prefix the julia-buildkite repo's own CI uploads to
# (see .buildkite/hooks/post-checkout)
export S3_EPHEMERAL_BUCKET="${S3_EPHEMERAL_BUCKET:-julialang-ephemeral}"
export S3_EPHEMERAL_PREFIX="${S3_EPHEMERAL_PREFIX:-julia-buildkite-uploads/bin}"

# Bucket + prefix for the scheduled no-GPL builds
# (see pipelines/scheduled/platforms/upload_*.no_gpl.yml)
export S3_NOGPL_BUCKET="${S3_NOGPL_BUCKET:-julialang-nogpl}"
export S3_NOGPL_PREFIX="${S3_NOGPL_PREFIX:-bin-nogpl}"

# KMS key aliases
export KMS_ALIAS_MACOS_CODESIGN="alias/julia-macos-codesigning"
export KMS_ALIAS_NOTARY_API="alias/julia-notary-api"
export KMS_ALIAS_TARBALL_SIGNING="alias/julia-tarball-signing"
export KMS_ALIAS_DOCS_DEPLOY="alias/julia-docs-deploy"

# SSM Parameter Store prefix for CI telemetry bearer tokens (codecov,
# coveralls, buildkite analytics). These cannot be public-key operations,
# so they live in the AWS secrets store, fetched at runtime via OIDC.
export SSM_TOKEN_PREFIX="/julia-ci/tokens"

# IAM role names
#
# Trust is split into an UNTRUSTED tier (anything that runs on PR builds)
# and a TRUSTED tier (only the dedicated publish pipeline, which never
# builds pull requests):
#   julia-ci-stage    untrusted: write unsigned artifacts to a commit-sha
#                     gated staging path only. No KMS, no final-location
#                     write. Runs on every build, PRs included.
#   julia-ci-publish  trusted: kms:Sign + read staging + write final
#                     location. Assumable ONLY from the julia-publish
#                     pipeline slug, which is not connected to PR builds.
#   julia-ci-docs-deploy trusted docs SSH signing (publish pipeline only).
#   julia-ci-tokens   low-value telemetry tokens (build pipelines).
export ROLE_STAGE="julia-ci-stage"
export ROLE_PUBLISH="julia-ci-publish"
export ROLE_DOCS_DEPLOY="julia-ci-docs-deploy"
export ROLE_TOKENS="julia-ci-tokens"

# Sub-path (under each bucket prefix) that unsigned, commit-sha-gated
# artifacts are staged to. The publish pipeline reads from here; PR
# consumers (juliaup) also read from here.
export S3_STAGING_SUBPREFIX="staging"

# Buildkite OIDC issuer host
export BK_OIDC_HOST="agent.buildkite.com"

# `sub` patterns for the UNTRUSTED build pipelines. Any ref (PRs included);
# the stage/token roles these map to are deliberately harmless, so we do
# not (and must not) rely on the ref component for trust here.
# sub format: organization:ORG:pipeline:PIPELINE:ref:REF:commit:SHA:step:STEP
BUILD_SUB_PATTERNS=(
    "organization:${BK_ORG}:pipeline:julia-master:*"
    "organization:${BK_ORG}:pipeline:julia-master-scheduled:*"
    "organization:${BK_ORG}:pipeline:julia-release-*:*"
    "organization:${BK_ORG}:pipeline:julia-buildkite:*"
    "organization:${BK_ORG}:pipeline:julia-buildkite-scheduled:*"
)

# `sub` patterns for the TRUSTED publish pipelines. These pipeline slugs
# MUST be configured in Buildkite with pull-request builds disabled and
# branch-limited to the protected refs (see ops/README.md); a PR can then
# never produce a build under these slugs, so the slug itself is the trust
# boundary. The ref patterns below are belt-and-braces only.
PUBLISH_SUB_PATTERNS=(
    "organization:${BK_ORG}:pipeline:julia-publish:ref:refs/heads/master:*"
    "organization:${BK_ORG}:pipeline:julia-publish:ref:refs/heads/release-*:*"
    "organization:${BK_ORG}:pipeline:julia-publish:ref:refs/tags/v*:*"
    # julia-buildkite's own end-to-end publish test (ephemeral bucket only)
    "organization:${BK_ORG}:pipeline:julia-buildkite-publish:ref:refs/heads/main:*"
)

# Pipelines whose jobs may read CI telemetry tokens (coverage uploads,
# buildkite test analytics). These steps also run on "needs full CI"-labeled
# PRs (as they always have), so this includes any ref of the build
# pipelines; the tokens are deliberately low-value.
TOKEN_SUB_PATTERNS=(
    "organization:${BK_ORG}:pipeline:julia-master:*"
    "organization:${BK_ORG}:pipeline:julia-master-scheduled:*"
    "organization:${BK_ORG}:pipeline:julia-buildkite-scheduled:*"
)

# --- Helpers ------------------------------------------------------------------

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
export ACCOUNT_ID
export OIDC_PROVIDER_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${BK_OIDC_HOST}"

# json_array "a" "b" -> "a", "b"  (for splicing bash arrays into JSON)
json_array() {
    local out="" first=1
    for item in "$@"; do
        if [[ $first -eq 1 ]]; then first=0; else out+=", "; fi
        out+="\"${item}\""
    done
    echo "${out}"
}

# kms_key_arn <alias> -> key ARN (empty if alias doesn't exist)
kms_key_arn() {
    aws kms describe-key --key-id "$1" --region "${AWS_REGION}" \
        --query KeyMetadata.Arn --output text 2>/dev/null || true
}

# ensure_alias <alias> <key-id>
ensure_alias() {
    if ! aws kms list-aliases --region "${AWS_REGION}" \
            --query "Aliases[?AliasName=='$1']" --output text | grep -q .; then
        aws kms create-alias --region "${AWS_REGION}" \
            --alias-name "$1" --target-key-id "$2"
    fi
}

# ensure_role <name> <trust-policy-file> <description>
ensure_role() {
    local name="$1" trust="$2" desc="$3"
    if aws iam get-role --role-name "${name}" >/dev/null 2>&1; then
        echo "Updating trust policy for existing role ${name}"
        aws iam update-assume-role-policy --role-name "${name}" \
            --policy-document "file://${trust}"
    else
        echo "Creating role ${name}"
        aws iam create-role --role-name "${name}" \
            --assume-role-policy-document "file://${trust}" \
            --description "${desc}" \
            --max-session-duration 3600 >/dev/null
    fi
}
