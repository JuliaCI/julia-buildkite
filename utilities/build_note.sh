#!/usr/bin/env bash
# (Sourced file: deliberately no `set` of shell options here -- they would
# leak into the calling script; strict mode belongs to the entrypoints.)

# The build a benchmark job measures, for the title of its report: the triplet, and how the
# build differs from a regular one, so that the reports of the jobs on one build differ
build_note() {
    case "${OS}" in
        *src) echo "${TRIPLET%src}, built from source" ;;
        *opt) echo "${TRIPLET%opt}, optimized with PGO and ThinLTO" ;;
        *) echo "${TRIPLET}" ;;
    esac
}
