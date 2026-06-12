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
CERTIFICATE="${THIS_DIR}/developer_id.pem"

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

    # This while loop reads in from the fifo, and invokes `do_codesign`,
    # but it does so in a background task, so that the codesigning can
    # happen in parallel.  This speeds things up by a few seconds.
    echo "Codesigning dir ${TARGET} with ${IDENTITY_DESC}"
    NUM_CODESIGNS=0
    while IFS= read -r -d '' exe_file; do
        do_codesign "${exe_file}" &
        NUM_CODESIGNS="$((NUM_CODESIGNS + 1))"
    done < "${TMPFIFODIR}/findpipe"
    wait
    echo "Codesigned ${NUM_CODESIGNS} files"
else
    echo "Given codesigning target '${TARGET}' not a file or directory!" >&2
    usage
    exit 1
fi
