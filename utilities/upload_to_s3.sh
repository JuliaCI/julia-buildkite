# Shared write-once S3 upload helper. Source this file, then call
# `upload_to_s3 <local-file> <bucket/key>`; AWS credentials come from
# Buildkite OIDC (source aws_oidc.sh first).

# Tell the AWS CLI not to contact the metadata service; credentials come
# from OIDC web identity (AWS_WEB_IDENTITY_TOKEN_FILE / AWS_ROLE_ARN).
export AWS_EC2_METADATA_DISABLED=true

# Upload a local file to `s3://${BUCKET}/${KEY}`, write-once.
#
# IAM denies unconditional puts, so a build can never overwrite an existing
# object (S3 conditional write, If-None-Match: *). If the object already
# exists (e.g. a retried job) we accept it iff its content matches what we
# have locally. `julia-latest-*` pointer objects are intentionally
# overwritten (and only the publish role is allowed to do so).
upload_to_s3() {
    local file="$1" target="$2"
    local bucket="${target%%/*}"
    local key="${target#*/}"

    if [[ "$(basename "${key}")" == julia-latest-* ]]; then
        aws s3api put-object \
            --bucket "${bucket}" --key "${key}" \
            --body "${file}" --acl public-read >/dev/null
        echo "uploaded (latest pointer): s3://${target}"
        return 0
    fi

    local output
    if output="$(aws s3api put-object \
            --bucket "${bucket}" --key "${key}" \
            --body "${file}" --acl public-read \
            --if-none-match '*' 2>&1)"; then
        echo "uploaded (write-once): s3://${target}"
        return 0
    fi

    if [[ "${output}" == *"PreconditionFailed"* || "${output}" == *"412"* ]]; then
        local local_md5 remote_etag
        local_md5="$(openssl dgst -md5 -r "${file}" | cut -d' ' -f1)"
        remote_etag="$(aws s3api head-object --bucket "${bucket}" --key "${key}" \
            --query ETag --output text | tr -d '"')"
        if [[ "${local_md5}" == "${remote_etag}" ]]; then
            echo "already exists with identical content, skipping: s3://${target}"
            return 0
        fi
        echo "ERROR: s3://${target} already exists with DIFFERENT content; refusing to overwrite" >&2
        return 1
    fi

    echo "${output}" >&2
    return 1
}
