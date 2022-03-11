#!/bin/bash

set -euo pipefail

# Determine JULIA_CPU_TARGETS for different architectures
JUlIA_CPU_TARGETS=()
case "${ARCH?}" in
    x86_64)
        JULIA_CPU_TARGETS+=(
            # Absolute base x86_64 feature set
            "generic"
            # Add sandybridge level (without xsaveopt) and that clones all functions
            "sandybridge,-xsaveopt,clone_all"
            # Add haswell level (without rdrnd) that is a diff of the sandybridge level
            "haswell,-rdrnd,base(1)"
        )
        ;;
    i686)
        JULIA_CPU_TARGETS+=(
            # We require SSE2, etc.. so `pentium4` is our base i686 feature set
            "pentium4"
            # Add sandybridge level similar to x86_64 above
            "sandybridge,-xsaveopt,clone_all"
        )
        ;;
    armv7l)
        JULIA_CPU_TARGETS+=(
            # Absolute base armv7-a feature set
            "armv7-a"
            # Add NEON level on top of that
            "armv7-a,neon"
            # Add NEON with VFP4 on top of that
            "armv7-a,neon,vfp4"
        )
        ;;
    aarch64)
        JULIA_CPU_TARGETS+=(
            # Absolute base aarch64 feature set
            "generic"
            # Cortex A57, Example: NVIDIA Jetson TX1, Jetson Nano
            "cortex-a57"
            # Cavium ThunderX2T99, a common server architecture
            "thunderx2t99"
            # NVidia Carmel, e.g. Jetson AGX Xavier
            "carmel"
        )
        ;;
    powerpc64le)
        JULIA_CPU_TARGETS+=(
            # Absolute base POWER-8 feature set
            "pwr8"
        )
        ;;
    *)
        echo "Unknown target processor architecture '${ARCH}'" >&2
        exit 1
        ;;
esac

# Join and output
JULIA_CPU_TARGET="$(printf ";%s" "${JULIA_CPU_TARGETS[@]}")"
export JULIA_CPU_TARGET="${JULIA_CPU_TARGET:1}"
