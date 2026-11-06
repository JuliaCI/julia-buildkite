#!/usr/bin/env bash
# Sourced by build_julia.sh and test_julia.sh; their strict mode applies.

# The job's width (JULIA_CPU_THREADS) comes from the scheduler's CPU grant. A step whose
# memory grows with its width declares MEM_PER_THREAD_GIB, and then runs only as many
# threads as the job's memory grant (SBA_MEM_GIB) holds, after DRIVER_GIB for the process
# that drives them. Source this before anything derives a value from JULIA_CPU_THREADS.

DRIVER_GIB=1

if [[ -n "${MEM_PER_THREAD_GIB:-}" ]]; then
    if [[ -z "${SBA_MEM_GIB:-}" ]]; then
        echo "ERROR: this step sets MEM_PER_THREAD_GIB, but the job has no memory grant (SBA_MEM_GIB)" >&2
        exit 1
    fi
    # Compare in integer tenths of a GiB, so that e.g. (4.3 - 1) / 1.1 is exactly 3.
    MEM_WIDTH="$(awk -v mem="${SBA_MEM_GIB}" -v per="${MEM_PER_THREAD_GIB}" -v driver="${DRIVER_GIB}" \
        'function tenths(x) { return int(x * 10 + 0.5) }
         BEGIN { w = int((tenths(mem) - tenths(driver)) / tenths(per)); print (w > 0 ? w : 0) }')"
    echo "Width: JULIA_CPU_THREADS=${JULIA_CPU_THREADS:?} SBA_MEM_GIB=${SBA_MEM_GIB}" \
         "MEM_PER_THREAD_GIB=${MEM_PER_THREAD_GIB} DRIVER_GIB=${DRIVER_GIB}" \
         "-> JULIA_CPU_THREADS=$(( MEM_WIDTH < JULIA_CPU_THREADS ? MEM_WIDTH : JULIA_CPU_THREADS ))"
    if [[ "${MEM_WIDTH}" -eq 0 ]]; then
        echo "ERROR: this host's memory grant (${SBA_MEM_GIB} GiB) is too small for this step" >&2
        exit 1
    fi
    if [[ "${MEM_WIDTH}" -lt "${JULIA_CPU_THREADS}" ]]; then
        export JULIA_CPU_THREADS="${MEM_WIDTH}"
    fi
fi
