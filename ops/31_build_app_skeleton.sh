#!/usr/bin/env bash
# Build the Julia.app launcher skeleton -- the ONE remaining step that needs
# a Mac, because AppleScript can only be compiled by osacompile. Everything
# downstream (filling the plist, inserting the julia tree, signing,
# notarizing, building the .dmg) happens on the linux publish agent
# (utilities/macos/build_dmg.sh).
#
# Run this on any Mac from a JuliaLang/julia checkout, then commit the
# resulting utilities/macos/julia-app-skeleton.tar.gz to julia-buildkite
# (it contains no secrets and no julia version specifics; it only needs
# rebuilding if contrib/mac/app/startup.applescript changes).
#
# Usage: 31_build_app_skeleton.sh /path/to/julia-checkout
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
set -euo pipefail

JULIA_CHECKOUT="${1:?usage: $0 /path/to/julia-checkout}"
STARTUP_SCRIPT="${JULIA_CHECKOUT}/contrib/mac/app/startup.applescript"
[[ -f "${STARTUP_SCRIPT}" ]] || { echo "ERROR: ${STARTUP_SCRIPT} not found" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# Compile the applescript into a generically-named .app; build_dmg.sh
# renames it to Julia-<majmin>.app and rewrites the Info.plist per release.
osacompile -o "${WORK}/Julia.app" "${STARTUP_SCRIPT}"

OUT="${SCRIPT_DIR}/../utilities/macos/julia-app-skeleton.tar.gz"
tar -czf "${OUT}" -C "${WORK}" Julia.app

echo "Wrote $(du -h "${OUT}" | cut -f1) skeleton to ${OUT}"
echo "sha256: $(shasum -a 256 "${OUT}" | cut -d' ' -f1)"
echo "Commit this file."
