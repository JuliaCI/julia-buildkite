#!/usr/bin/env bash
# Sourced by test_julia.sh; its strict mode applies.

# A test that crashes repeatedly can leave a core dump per crash, each as large as the
# process's address space (tens of GB on macOS), and fill the disk before the test run
# ends. Keep the first few cores, enough to debug each distinct crash in most runs, and
# delete later ones, as well as all but the first once free disk space drops below a
# reserve for the tests themselves. The coreupload plugin then backtraces and uploads
# what is left. This is best effort: a core being written still takes up space after it
# is deleted, until the kernel is done writing it.

# Number of core dumps to keep
MAX_CORE_DUMPS="${MAX_CORE_DUMPS:-4}"
# Free disk space, in GiB, to keep for the tests
CORE_DUMP_RESERVE_GIB="${CORE_DUMP_RESERVE_GIB:-20}"

free_space_kib() {
    df -Pk "${1}" | awk 'NR == 2 { print $4 }'
}

# Limit every core dump to its share of the disk space left over after the reserve, so
# that the cores we keep fit together. On macOS the kernel skips a core that would not
# fit; Linux truncates it.
limit_core_dumps() {
    local limit_kib=0
    if (( MAX_CORE_DUMPS > 0 )); then
        limit_kib=$(( ($(free_space_kib .) - CORE_DUMP_RESERVE_GIB * 1024 * 1024) / MAX_CORE_DUMPS ))
    fi
    ulimit -c "$(( limit_kib > 0 ? limit_kib : 0 ))"
}

# Run in the background while the tests run, on the cores below the current directory.
reap_core_dumps() {
    # Cores kept so far, in the order they appeared, one per line
    local kept="" core first
    local reserve_kib=$(( CORE_DUMP_RESERVE_GIB * 1024 * 1024 ))
    # Take our `sleep` along when killed, so that it cannot keep the job's output open.
    local sleep_pid=""
    trap 'kill ${sleep_pid} 2>/dev/null; exit 0' TERM
    # `$$` is the script that started us; stop if it is gone (e.g. a cancelled job).
    while kill -0 "$$" 2>/dev/null; do
        while IFS= read -r core; do
            [[ $'\n'"${kept}" == *$'\n'"${core}"$'\n'* ]] && continue
            if (( $(printf '%s' "${kept}" | grep -c '') >= MAX_CORE_DUMPS )); then
                echo "Deleting core dump ${core}: already kept ${MAX_CORE_DUMPS} (MAX_CORE_DUMPS)"
                rm -f "${core}"
            elif (( $(free_space_kib .) < reserve_kib )); then
                echo "Deleting core dump ${core}: less than ${CORE_DUMP_RESERVE_GIB} GiB of disk space left (CORE_DUMP_RESERVE_GIB)"
                rm -f "${core}"
            else
                kept+="${core}"$'\n'
            fi
        done < <(find . -name '*.core' -type f 2>/dev/null)

        # Cores keep growing after we first see them
        if (( $(free_space_kib .) < reserve_kib )) && [[ "${kept}" == *$'\n'?* ]]; then
            first="${kept%%$'\n'*}"
            while IFS= read -r core; do
                [[ -z "${core}" || "${core}" == "${first}" ]] && continue
                echo "Deleting core dump ${core}: less than ${CORE_DUMP_RESERVE_GIB} GiB of disk space left (CORE_DUMP_RESERVE_GIB)"
                rm -f "${core}"
            done <<< "${kept}"
            kept="${first}"$'\n'
        fi
        sleep 5 &
        sleep_pid="$!"
        wait "${sleep_pid}" || true
    done
}
