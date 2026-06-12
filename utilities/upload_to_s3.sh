# Shared write-once S3 upload helper. Source this file, then call
# `upload_to_s3 <local-file> <bucket/key>`; AWS credentials come from
# Buildkite OIDC (source aws_oidc.sh first).
#
# By default objects are uploaded with `--acl public-read` (the legacy
# release buckets are ACL-based). Set UPLOAD_TO_S3_ACL=none for buckets
# that disable ACLs and grant public read via bucket policy instead (the
# ephemeral staging buckets): there an ACL'd PUT would be rejected, and
# the stage roles deliberately lack s3:PutObjectAcl.
# (Sourced file: deliberately no `set` of shell options here -- they would
# leak into the calling script; strict mode belongs to the entrypoints.)

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

    local acl_args=( --acl public-read )
    if [[ "${UPLOAD_TO_S3_ACL:-public-read}" == "none" ]]; then
        acl_args=()
    fi

    if [[ "$(basename "${key}")" == julia-latest-* ]]; then
        aws s3api put-object \
            --bucket "${bucket}" --key "${key}" \
            --body "${file}" ${acl_args[@]+"${acl_args[@]}"} >/dev/null
        echo "uploaded (latest pointer): s3://${target}"
        return 0
    fi

    local output
    if output="$(aws s3api put-object \
            --bucket "${bucket}" --key "${key}" \
            --body "${file}" ${acl_args[@]+"${acl_args[@]}"} \
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
