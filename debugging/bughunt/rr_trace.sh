#!/bin/bash
set -euo pipefail
shopt -s nullglob

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
SCRIPT=$(basename "$0")
RR=/build/artifacts/.rr_jll/bin/rr

function print_usage() {
    echo "Usage: ${SCRIPT} list"
    echo "Usage: ${SCRIPT} ps <trace>"
    echo "Usage: ${SCRIPT} replay <trace>"
}

if [[ "$#" == "0" ]]; then
    print_usage
    exit 1
fi

function echo_red() {
    tput setaf 1
    echo "$@"
    tput sgr0
}

function fixup_trace_path() {
    if [[ -d "${SCRIPT_DIR}/rr_traces/${1}" ]]; then
        echo -n "${SCRIPT_DIR}/rr_traces/${1}"
    else
        echo -n "${1}"
    fi
}

function any_failures_in_ps() {
    [[ $("${RR}" ps "$(fixup_trace_path "${1}")" | awk "{sum+=\$3} END {print sum;}") > 0 ]]
}

function grep_ps() {
    # Use process substitution to avoid SIGPIPE
    # X-ref: https://stackoverflow.com/questions/19120263/why-exit-code-141-with-grep-q
    grep -q "${2}" < <("${RR}" ps "$(fixup_trace_path "${1}")")
}


if [[ "$1" == "list" ]]; then
    for trace in $(ls ${SCRIPT_DIR}/rr_traces | sort -V); do
        if any_failures_in_ps "${trace}"; then
            echo_red "$(basename "${trace}")"
        else
            echo "$(basename "${trace}")"
        fi
    done
    exit 0
fi

if [[ "$1" == "grep" ]]; then
    if [[ -z "${2:-}" ]]; then
        echo "Usage: ${SCRIPT} grep <pattern>" >&2
        exit 1
    fi
    shift 1

    for trace in $(ls ${SCRIPT_DIR}/rr_traces | sort -V); do
        if grep_ps "${trace}" "$@"; then
            if any_failures_in_ps "${trace}"; then
                echo_red "$(basename "${trace}")"
            else
                echo "$(basename "${trace}")"
            fi
        fi
    done
    exit 0
fi

if [[ "$1" == "ps" ]]; then
    if [[ -z "${2:-}" ]]; then
        echo "Usage: ${SCRIPT} ps <trace>" >&2
        exit 1
    fi
    TRACE_PATH="$(fixup_trace_path ${2})"
    shift 2
    exec "${RR}" ps "${TRACE_PATH}" "$@"
fi

if [[ "$1" == "replay" ]]; then
    if [[ -z "${2:-}" ]]; then
        echo "Usage: ${SCRIPT} replay <trace>" >&2
        exit 1
    fi
    TRACE_PATH="$(fixup_trace_path ${2})"
    shift 2
    exec "${RR}" replay -x /build/.gdbinit.src --serve-files "${TRACE_PATH}" "$@"
fi

echo "Unknown command: $@"
print_usage
exit 1
