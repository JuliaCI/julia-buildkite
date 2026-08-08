# shellcheck shell=bash
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

# Tell the AWS CLI not to contact the EC2 metadata service; credentials come
# from OIDC web identity (AWS_WEB_IDENTITY_TOKEN_FILE / AWS_ROLE_ARN).
export AWS_EC2_METADATA_DISABLED=true

# Upload a local file to `s3://${BUCKET}/${KEY}`, write-once per commit.
#
# IAM denies unconditional puts, so a build can never overwrite an existing
# object (S3 conditional write, If-None-Match: *). If the object already
# exists we accept it iff its content matches what we have locally (a
# retried job re-uploading the same bytes), OR iff it was uploaded by
# another build of the same commit (see below). `julia-latest-*` pointer
# objects are intentionally overwritten (and only the publish role is
# allowed to do so).
upload_to_s3() {
    local file="$1" target="$2"
    local bucket="${target%%/*}"
    local key="${target#*/}"

    local acl_args=( --acl public-read )
    if [[ "${UPLOAD_TO_S3_ACL:-public-read}" == "none" ]]; then
        acl_args=()
    fi

    # Stamp every object with the commit that produced it. BUILDKITE_COMMIT
    # is the same Buildkite-attested value that gates the staging paths and
    # that verify_trusted_commit.sh checks before a publish, so the stamp is
    # trustworthy provenance -- and it is what lets a second build of the
    # SAME commit be treated as idempotent below.
    local s3_metadata_args=()
    if [[ "${BUILDKITE_COMMIT:-}" =~ ^[0-9a-f]{40}$ ]]; then
        s3_metadata_args=( --metadata "build-commit=${BUILDKITE_COMMIT}" )
    fi

    # Debug/test stacks (UPLOAD_TO_S3_OVERWRITE=1) re-publish the same commit
    # repeatedly, so they overwrite unconditionally. This can only ever succeed
    # against a bucket whose role permits an unconditional PutObject -- the
    # production roles' IAM denies it (write-once), so the flag is inert on the
    # real publish path even if accidentally set.
    if [[ "${UPLOAD_TO_S3_OVERWRITE:-0}" == "1" || "$(basename "${key}")" == julia-latest-* ]]; then
        aws s3api put-object \
            --bucket "${bucket}" --key "${key}" \
            --body "${file}" ${acl_args[@]+"${acl_args[@]}"} \
            ${s3_metadata_args[@]+"${s3_metadata_args[@]}"} >/dev/null
        echo "uploaded (overwrite): s3://${target}"
        return 0
    fi

    local output
    if output="$(aws s3api put-object \
            --bucket "${bucket}" --key "${key}" \
            --body "${file}" ${acl_args[@]+"${acl_args[@]}"} \
            ${s3_metadata_args[@]+"${s3_metadata_args[@]}"} \
            --if-none-match '*' 2>&1)"; then
        echo "uploaded (write-once): s3://${target}"
        return 0
    fi

    if [[ "${output}" == *"PreconditionFailed"* || "${output}" == *"412"* ]]; then
        local remote_info local_md5 remote_etag remote_commit
        local_md5="$(openssl dgst -md5 -r "${file}" | cut -d' ' -f1)"
        remote_info="$(aws s3api head-object --bucket "${bucket}" --key "${key}" \
            --query '[ETag, Metadata."build-commit"]' --output text)"
        remote_etag="$(cut -f1 <<<"${remote_info}" | tr -d '"')"
        remote_commit="$(cut -f2 <<<"${remote_info}")"
        # `--output text` renders a missing S3 metadata entry as literal "None"
        [[ "${remote_commit}" == "None" ]] && remote_commit=""
        if [[ "${local_md5}" == "${remote_etag}" ]]; then
            echo "already exists with identical content, skipping: s3://${target}"
            return 0
        fi
        # Julia builds are not byte-reproducible, so two builds of the same
        # commit legitimately produce different bytes for the same object.
        # That happens in normal operation: a rebuild of a commit whose
        # artifacts are already staged, a build that shares a staging key
        # with a concurrent sibling of the same commit (the doctest
        # htmldocs archive during a release-branch + tag double build), or
        # a re-run publish re-signing artifacts whose predecessors were
        # already promoted. Every writer of a given location is equally
        # trusted for a given commit -- staging paths are IAM-gated to the
        # attested build commit, and the final locations are writable only by
        # the publish role after the trusted-commit check -- so if the
        # existing object came from this same commit, keep it and succeed:
        # first upload wins. Anything else (in particular a repointed release
        # tag, where a version name suddenly maps to a different commit)
        # stays a hard error: replacing a published object is a deliberate
        # manual operation.
        if [[ "${BUILDKITE_COMMIT:-}" =~ ^[0-9a-f]{40}$ && "${remote_commit}" == "${BUILDKITE_COMMIT}" ]]; then
            echo "already uploaded by another build of commit ${BUILDKITE_COMMIT:0:10}, keeping the existing object: s3://${target}"
            return 0
        fi
        echo "ERROR: s3://${target} already exists with DIFFERENT content (from build-commit: ${remote_commit:-unknown}); refusing to overwrite" >&2
        return 1
    fi

    echo "${output}" >&2
    return 1
}
