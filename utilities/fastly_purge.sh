# shellcheck shell=bash
# Shared Fastly purge helpers for the publish and promote pipelines. Source
# this file after aws_oidc.sh (the token is read from SSM with the job's
# role).
#
# The Fastly services in front of the public buckets require authenticated
# purges. Every uploaded object is purged: the julia-latest-* /
# julia-<majmin>-latest-* pointers are overwritten, and Fastly may hold a
# cached 404 (60 s) for a new write-once key that was requested before the
# upload. Purging a URL that is not cached is a no-op.
#
# Purges are hard, not soft: after a soft purge Fastly was seen to keep
# serving the old copy with its old headers, which defeats the purpose for
# objects that have just been replaced.
#
# A missing token or a failed purge only warns: the upload itself succeeded,
# and the latest pointers then update when their Fastly TTL expires.
# (Sourced file: deliberately no `set` of shell options here.)

# Set FASTLY_PURGE_TOKEN from the SSM parameter $1, unless it is already set
# or a previous call already tried. Exported, so that child scripts (publish.sh
# runs upload_julia.sh per triplet) do not read it again.
load_fastly_purge_token() {
    local parameter="$1"
    if [[ -n "${FASTLY_PURGE_TOKEN_LOADED:-}" ]]; then
        return 0
    fi
    export FASTLY_PURGE_TOKEN_LOADED=1
    if [[ -z "${FASTLY_PURGE_TOKEN:-}" ]]; then
        FASTLY_PURGE_TOKEN="$(aws ssm get-parameter --with-decryption --name "${parameter}" \
            --query Parameter.Value --output text)" \
            || { echo "WARN: could not read ${parameter}; nothing will be purged" >&2; FASTLY_PURGE_TOKEN=""; }
    fi
    export FASTLY_PURGE_TOKEN
}

# The CDN URL in front of bucket $1, or nothing for buckets without one (the
# test stacks' buckets, and the nogpl bucket, whose Fastly service is inactive).
fastly_cdn_url() {
    case "$1" in
        julialang2)         echo "https://julialang-s3.julialang.org" ;;
        julialangnightlies) echo "https://julialangnightlies-s3.julialang.org" ;;
    esac
}

# Purge the keys $2... from the CDN at $1.
fastly_purge() {
    local cdn_url="$1"; shift
    [[ "$#" -gt 0 ]] || return 0
    if [[ -z "${FASTLY_PURGE_TOKEN:-}" ]]; then
        echo "WARN: no Fastly purge token; not purging $# object(s) on ${cdn_url}, the latest pointers update when their Fastly TTL expires" >&2
        return 0
    fi
    local key
    for key in "$@"; do
        curl -fsS -o /dev/null -X PURGE -H "Fastly-Key: ${FASTLY_PURGE_TOKEN}" "${cdn_url}/${key}" \
            || echo "WARN: cache purge failed for ${cdn_url}/${key}" >&2
    done
}

# Purge the "<bucket>/<key>" targets $@, each from the CDN in front of its
# bucket. Targets in buckets without a CDN are skipped.
fastly_purge_targets() {
    local bucket target cdn_url keys
    for bucket in julialang2 julialangnightlies; do
        cdn_url="$(fastly_cdn_url "${bucket}")"
        keys=()
        for target in "$@"; do
            [[ "${target%%/*}" == "${bucket}" ]] && keys+=( "${target#*/}" )
        done
        fastly_purge "${cdn_url}" ${keys[@]+"${keys[@]}"}
    done
}
