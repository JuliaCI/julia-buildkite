#!/usr/bin/env bash

# Assemble the UNSIGNED Julia.app from a julia binary-dist `.tar.gz`, WITHOUT
# rebuilding julia and WITHOUT a Mac.
#
# The macOS build jobs no longer build the .app (see build_julia.sh); they only
# stage the tree `.tar.gz`. The .app is now a pure repackage of that tarball --
# contrib/mac/app's rule needs no osacompile/plutil and runs anywhere -- so both
# consumers assemble it from the staged .tar on a Linux agent:
#   * julia-pr  -> stage_macos_app.sh (a separate off-critical-path builder)
#   * julia-ci  -> upload_julia.sh    (the trusted publish step, before signing)
# Sharing one script keeps the bundle layout defined in exactly one place (the
# julia repo's contrib/mac/app/Makefile).
#
# Usage:  assemble_app.sh <julia-tree.tar.gz>
# Leaves the bundle at  contrib/mac/app/dmg/Julia-${MAJMIN}.app  (unsigned).
#
# Requires (exported by build_envs.sh, which the caller sources):
#   MAKE, MAJMIN, JULIA_BINARYDIST_FILENAME
# and a julia checkout as the current directory (JULIAHOME).
set -euo pipefail

SRC_TARBALL="${1:?usage: assemble_app.sh <julia-tree.tar.gz>}"

: "${MAKE:?}" "${MAJMIN:?}" "${JULIA_BINARYDIST_FILENAME:?}"

# The .app rule extracts $(JULIAHOME)/$(JULIA_BINARYDIST_FILENAME).tar.gz. Put the
# tarball there under exactly that name; the name is only how the rule locates it
# (the content is the macOS tree, regardless of the host that computed the name).
if [[ "${SRC_TARBALL}" != "${JULIA_BINARYDIST_FILENAME}.tar.gz" ]]; then
    cp -f "${SRC_TARBALL}" "${JULIA_BINARYDIST_FILENAME}.tar.gz"
fi

echo "--- [mac] Assemble the unsigned Julia-${MAJMIN}.app from ${SRC_TARBALL}"
# MAKE=true rewrites the rule's `$(MAKE) -C $(JULIAHOME) binary-dist` into a no-op
# `true ...`: we already hold the tarball and there is no built tree to re-dist
# (a real `make binary-dist` on this fresh checkout would trigger a full build).
# Empty MACOS_CODESIGN_IDENTITY leaves the bundle unsigned -- signing happens
# later in julia-publish, or never for PR .apps.
MACOS_CODESIGN_IDENTITY="" ${MAKE} -C contrib/mac/app MAKE=true "dmg/Julia-${MAJMIN}.app"
