#!/usr/bin/env bash
# This file is a part of Julia. License is MIT: https://julialang.org/license

set -euo pipefail

usage() {
    echo "Usage: $0 [--kms-key=<arn>] [--certificate=<path>] <target>"
    echo
    echo "Parameter descriptions:"
    echo
    echo "        kms-key: AWS KMS key ID/ARN/alias holding the Developer ID private key."
    echo "                 If not given, performs ad-hoc signing with the system codesign."
    echo
    echo "    certificate: Path to the Developer ID certificate (PEM) paired with the"
    echo "                 KMS key. Defaults to developer_id.pem next to this script."
    echo
    echo "         target: A file or directory to codesign (must come last!)"
    echo
    echo "When a KMS key is used, signing is performed with rcodesign (apple-codesign"
    echo "with the AWS KMS backend; see utilities/macos/rcodesign/). AWS credentials"
    echo "must be available, e.g. via 'source utilities/aws_oidc.sh publish'."
}

THIS_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

if [ "$#" -lt 1 ]; then
    usage
    exit 1
fi

KMS_KEY=""
# The Developer ID certificate (PEM) paired with the KMS key. Defaults to the
# production developer_id.pem next to this script; the non-production publish
# test stack overrides it (a self-signed cert for the test KMS key) via
# MACOS_CODESIGN_CERT. An explicit --certificate still wins over both.
CERTIFICATE="${MACOS_CODESIGN_CERT:-${THIS_DIR}/developer_id.pem}"

while [ "$#" -gt 1 ]; do
    case "${1}" in
        --kms-key)
            KMS_KEY="$2"; shift; shift ;;
        --kms-key=*)
            KMS_KEY="${1#*=}"; shift ;;
        --certificate)
            CERTIFICATE="$2"; shift; shift ;;
        --certificate=*)
            CERTIFICATE="${1#*=}"; shift ;;
        *)
            echo "Unknown argument '$1'"
            usage
            exit 1 ;;
    esac
done
TARGET="${1}"

do_adhoc_codesign() {
    # Ad-hoc signing needs no key; use the system codesign as before.
    codesign --sign "-" \
             --option=runtime \
             --entitlements "${THIS_DIR}/Entitlements.plist" \
             --timestamp \
             --force \
             "${1}"
}

do_kms_codesign() {
    # Sign with the Developer ID key in AWS KMS via rcodesign. The hardened
    # runtime flag and entitlements match what we passed to Apple codesign.
    "${RCODESIGN_BIN}" sign \
        --aws-kms-key "${KMS_KEY}" \
        --aws-kms-certificate-file "${CERTIFICATE}" \
        --code-signature-flags runtime \
        --entitlements-xml-file "${THIS_DIR}/Entitlements.plist" \
        "${1}"
}

if [ -n "${KMS_KEY}" ]; then
    if [ ! -f "${CERTIFICATE}" ]; then
        echo "ERROR: certificate '${CERTIFICATE}' not found!" >&2
        exit 1
    fi
    RCODESIGN_BIN="$("${THIS_DIR}/get_rcodesign.sh")"

    # Each rcodesign process resolves AWS credentials independently. Signing a
    # whole bundle means hundreds of processes, and under Buildkite OIDC each
    # would run its own STS AssumeRoleWithWebIdentity. Even a small bounded pool
    # overwhelmed the (proxied) STS endpoint enough that ~8% of resolutions
    # exceeded the AWS SDK's 5s budget ("identity resolver timed out after 5s")
    # and the signature failed. Assume the role ONCE here and hand every signer
    # the resulting static session credentials via the SDK's first, network-free
    # environment provider -- credential resolution becomes a local lookup that
    # cannot time out, no matter how many signers run concurrently. (Only when
    # running under an OIDC web-identity token; a local run with static creds
    # already in the environment keeps them.)
    if [[ -z "${AWS_ACCESS_KEY_ID:-}" && -n "${AWS_WEB_IDENTITY_TOKEN_FILE:-}" ]]; then
        echo "Resolving shared AWS session credentials for rcodesign (one STS call for all signers)"
        _kms_creds="$(aws sts assume-role-with-web-identity \
            --role-arn "${AWS_ROLE_ARN:?}" \
            --role-session-name "${AWS_ROLE_SESSION_NAME:-rcodesign}" \
            --web-identity-token "$(cat "${AWS_WEB_IDENTITY_TOKEN_FILE}")" \
            --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
            --output text)"
        read -r AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN <<<"${_kms_creds}"
        export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
        unset _kms_creds
    fi

    do_codesign() { do_kms_codesign "$@"; }
    IDENTITY_DESC="KMS key ${KMS_KEY}"
else
    do_codesign() { do_adhoc_codesign "$@"; }
    IDENTITY_DESC="ad-hoc identity"
fi

if [ -f "${TARGET}" ]; then
    # If we're codesigning a single file, directly invoke codesign on that file
    echo "Codesigning file ${TARGET} with ${IDENTITY_DESC}"
    do_codesign "${TARGET}"
elif [ -d "${TARGET}" ]; then
    # Create a fifo to communicate from `find` to `while`
    trap 'rm -rf $TMPFIFODIR' EXIT
    TMPFIFODIR="$(mktemp -d)"
    mkfifo "$TMPFIFODIR/findpipe"

    # If we're codesigning a whole directory, use `find` to discover every
    # executable file within the directory, then pass that off to a while
    # read loop.  This safely handles whitespace in filenames.
    find "${TARGET}" -type f -perm -0111 -print0 > "$TMPFIFODIR/findpipe" &

    # Sign the discovered files with a BOUNDED pool of background workers so the
    # codesigning happens in parallel without an unbounded fan-out. A full bundle
    # (e.g. the Julia tree) holds hundreds of mach-o files; backgrounding a
    # signer for *every* one at once spawned hundreds of simultaneous rcodesign
    # processes, each independently assuming the KMS-signing OIDC role via STS
    # and holding KMS / Apple-timestamp connections open for the duration of the
    # signature. That much concurrent pressure pushed some credential
    # resolutions past the AWS SDK's 5s budget ("identity resolver timed out
    # after 5s"), failing the signature. Cap the concurrency (MACOS_CODESIGN_JOBS).
    MAX_JOBS="${MACOS_CODESIGN_JOBS:-8}"
    echo "Codesigning dir ${TARGET} with ${IDENTITY_DESC} (up to ${MAX_JOBS} concurrent)"
    # A non-empty STATUS_DIR after the run means at least one signer failed: the
    # trailing `wait` returns 0 regardless, so failures are recorded out-of-band
    # rather than silently swallowed (never ship a partially-signed bundle).
    STATUS_DIR="$(mktemp -d)"
    NUM_CODESIGNS=0
    while IFS= read -r -d '' exe_file; do
        # Block until a worker slot frees up before launching the next signer.
        while (( "$(jobs -rp | wc -l)" >= MAX_JOBS )); do wait -n 2>/dev/null || true; done
        { do_codesign "${exe_file}" || touch "${STATUS_DIR}/fail.${NUM_CODESIGNS}"; } &
        NUM_CODESIGNS="$((NUM_CODESIGNS + 1))"
    done < "${TMPFIFODIR}/findpipe"
    wait

    NUM_FAILED="$(find "${STATUS_DIR}" -type f | wc -l)"
    rm -rf "${STATUS_DIR}"
    if [ "${NUM_FAILED}" -ne 0 ]; then
        echo "ERROR: ${NUM_FAILED} of ${NUM_CODESIGNS} codesign operations failed" >&2
        exit 1
    fi
    echo "Codesigned ${NUM_CODESIGNS} files"
else
    echo "Given codesigning target '${TARGET}' not a file or directory!" >&2
    usage
    exit 1
fi
