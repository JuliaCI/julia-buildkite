#!/bin/sh
# This file is a part of Julia. License is MIT: https://julialang.org/license

set -euo pipefail

usage() {
    echo "Usage: $0 --certificate=<path> --password=<password> <target>"
    echo
    echo "Parameter descriptions:"
    echo
    echo "       key: A '.pfx' file that contains the codesigning certificate"
    echo
    echo "  password: The password to unlock the given '.pfx' file."
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
        --certificate)
            CERT_PATH="$2"
            shift
            shift
            ;;
        --certificate=*)
            CERT_PATH="${1#*=}"
            shift
            ;;
        --password)
            CERT_PASSWORD="$2"
            shift
            shift
            ;;
        --password=*)
            CERT_PASSWORD="${1#*=}"
            shift
            ;;
        *)
            echo "Unknown argument '$1'"
            usage
            exit 1
            ;;
    esac
done

# We tend to receive this via an environment variable on CI, so as to
# not print it out when `make` is run in verbose mode
CERT_PASSWORD="${CERT_PASSWORD:-${WINDOWS_CODESIGN_PASSWORD}}"

if [[ ! -f "${CERT_PATH}" ]]; then
    echo "ERROR: Certificate path '${CERT_PATH}' does not exist!" >&2
    exit 1
fi
CERT_PATH="$(cygpath -w "$(abspath "${CERT_PATH}")")"

# We will try to codesign, using multiple timestamping servers in case one is down
SERVERS=(
    "http://timestamp.digicert.com/?alg=sha1"
    "http://timestamp.globalsign.com/scripts/timstamp.dll"
    "http://timestamp.comodoca.com/authenticode"
    "http://tsa.starfieldtech.com"
)
NUM_RETRIES=3

function do_codesign() {
    for retry in $(seq 1 ${NUM_RETRIES}); do
        for SERVER in ${SERVERS[@]}; do
            # Note that we're using SHA1 signing here, because that's what our certificate supports.
            # In the future, we may be able to upgrade to SHA256.
            if signtool sign /debug /fd SHA1 /f "${CERT_PATH}" /p "${CERT_PASSWORD}" /t "${SERVER}" "$1"; then
                return 0
            fi
        done
    done

    # If we're unable to codesign, pass an error up the chain
    return 1
}

# This codesign script only works on files
if [ -f "${1}" ]; then
    if ! do_codesign "${1}"; then
        echo "Codesigning failed!" >&2
        exit 1
    fi
else
    echo "Don't know how to codesign '${1}'!" >&2
    exit 1
fi
