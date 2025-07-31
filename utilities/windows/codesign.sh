#!/usr/bin/env bash
# This file is a part of Julia. License is MIT: https://julialang.org/license

set -euo pipefail

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

DLIB_DEFAULT_PATH='C:\Program Files\TrustedSigning\bin\x64\Azure.CodeSigning.Dlib.dll'
DLIB_PATH="${DLIB_DEFAULT_PATH}"
METADATA_JSON_PATH="$(cygpath -w "${SCRIPT_DIR}/codesign_metadata.json")"

usage() {
    echo "Usage: $0 [--dlib-path=<path>] <target>"
    echo
    echo "Parameter descriptions:"
    echo
    echo "  dlib-path: The path to the Trusted Signing .dlib file (defaults to ${DLIB_DEFAULT_PATH})."
    echo
    echo "    target: A file or directory to codesign (must come last!)"
}

abspath() {
    echo "$(cd "$(dirname "$1")"; pwd -P)/$(basename "$1")"
}

if [ "$#" -lt 1 ]; then
    usage
    exit 1
fi

while [ "$#" -gt 1 ]; do
    case "${1}" in
        --dlib-path)
            DLIB_PATH="$2"
            shift
            shift
            ;;
        --dlib-path=*)
            DLIB_PATH="${1#*=}"
            shift
            ;;
        *)
            echo "Unknown argument '$1'"
            usage
            exit 1
            ;;
    esac
done
DLIB_PATH="$(cygpath -w "${DLIB_PATH}")"

if [[ -z "${AZURE_TENANT_ID:-}" ]] ||
   [[ -z "${AZURE_CLIENT_ID:-}" ]] ||
   [[ -z "${AZURE_CLIENT_SECRET:-}" ]]; then
    echo "ERROR: Missing AZURE_* secret variables!" >&2
    exit 1
fi

if [[ ! -f "${DLIB_PATH}" ]]; then
    echo "ERROR: No Trusted Signing dlib found at '${DLIB_PATH}'" >&2
    exit 1
fi


# We will try to codesign, using multiple timestamping servers in case one is down
SERVERS=(
    "http://timestamp.acs.microsoft.com"
    "http://timestamp.digicert.com"
    "http://tsa.starfieldtech.com"
)
NUM_RETRIES=3

function do_codesign() {
    for _ in $(seq 1 ${NUM_RETRIES}); do
        for SERVER in "${SERVERS[@]}"; do
            if MSYS2_ARG_CONV_EXCL='*' signtool sign /q /fd SHA256 /tr "${SERVER}" /td SHA256 /dlib "${DLIB_PATH}" /dmdf "${METADATA_JSON_PATH}" "$1"; then
                return 0
            fi
        done
    done

    # If we're unable to codesign, pass an error up the chain
    return 1
}

# This codesign script only works on files
if [ -f "${1}" ]; then
    # If we're codesigning a single file, directly invoke codesign on that file
    echo "Codesigning file ${1}"
    do_codesign "${1}"
elif [ -d "${1}" ]; then
    # Create a fifo to communicate from `find` to `while`
    trap 'rm -rf $TMPFIFODIR' EXIT
    TMPFIFODIR="$(mktemp -d)"
    mkfifo "$TMPFIFODIR/findpipe"

    # If we're codesigning a whole directory, use `find` to discover every
    # executable file within the directory, then pass that off to a while
    # read loop.  This safely handles whitespace in filenames.
    find "${1}" -type f -perm -0111 -print0 > "$TMPFIFODIR/findpipe" &

    # This while loop reads in from the fifo, and invokes `do_codesign`,
    # but it does so in a background task, so that the codesigning can
    # happen in parallel.  This speeds things up by a few seconds.
    echo "Codesigning dir ${1}"
    NUM_CODESIGNS=0
    while IFS= read -r -d '' exe_file; do
        do_codesign "${exe_file}" &
        NUM_CODESIGNS="$((NUM_CODESIGNS + 1))"
    done < "${TMPFIFODIR}/findpipe"
    wait
    echo "Codesigned ${NUM_CODESIGNS} files"
else
    echo "Given codesigning target '${1}' not a file or directory!" >&2
    usage
    exit 1
fi
