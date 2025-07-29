#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
COREFILE="$(corefile)"

# Read in all directories under `src/` and `base/` in the julia checkout;
# we'll add these as source search paths in `gdb`
# readarray -t -d '' JULIA_SRC_DIRS < <(find /build/julia.git/src /build/julia.git/base -type d -print0)

# Try `gdb` first, as it is less likely to freeze on us for some reason
if [[ -n "$(which gdb)" ]]; then
    # Use `file` to figure out the executable from the core file
    EXE="$(file "${SCRIPT_DIR}/${COREFILE}" | tr ',' '\n' | grep execfn | cut -d':' -f2 | tr -d "'" | xargs)"

    # Import our source directory search paths
    GDB_ARGS+=( "-x" "/build/.gdbinit.src" )

    # Set the sysroot to . so that `gdb` finds all the necessary libraries
    GDB_ARGS+=( "-ex" "set sysroot ${SCRIPT_DIR}" )

    # Target the julia executable and the corefile
    GDB_ARGS+=( "${SCRIPT_DIR}/${EXE}" "${SCRIPT_DIR}/${COREFILE}" )

    # Launch `gdb`
    gdb "${GDB_ARGS[@]}"
elif [[ -n "$(which lldb)" ]]; then
    # TODO: Can't figure out how to get `lldb` to use the right sysroot.
    lldb -c "${SCRIPT_DIR}/${COREFILE}"
else
    echo "No debuggers?!" >&2
    exit 1
fi
