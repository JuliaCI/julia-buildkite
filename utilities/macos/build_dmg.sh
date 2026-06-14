#!/bin/bash
# Build, sign and notarize the Julia .dmg -- on LINUX -- from a PRE-ASSEMBLED,
# already-codesigned Julia.app.
#
# Separation of concerns: the build_ step (on a Mac) assembles the Julia.app
# with all of contrib/mac/app's tooling, and upload_julia.sh codesigns every
# mach-o in it (launcher + bundled julia tree) before this runs. So this step
# only wraps the signed .app in a signed, notarized .dmg -- it needs no
# app-building tooling and no Mac.
#
# Apple-only packaging is replaced as follows (the same approach Mozilla uses to
# package Firefox DMGs on linux):
#   hdiutil  ->  newfs_hfs (the mkfs.hfsplus from hfsprogs/diskdev_cmds) to
#                create the HFS+ filesystem, plus the `hfsplus` (populate) and
#                `dmg` (compressed UDIF) tools from mozilla/libdmg-hfsplus.
# Code signing and notarization are linux-capable: rcodesign signs with the
# Developer ID key in AWS KMS, and notarization is an App Store Connect API
# call (key also in KMS).

set -euo pipefail

THIS_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

# The already-codesigned Julia.app to package (see upload_julia.sh).
APP_PATH="${APP_PATH:?APP_PATH must point at the (codesigned) Julia.app}"

DMG_PATH="dmg"
DMG_NAME="${UPLOAD_FILENAME?}.dmg"
VOLUME_NAME="Julia-${TAR_VERSION?}"
HFS_IMAGE="$(mktemp -u "${TMPDIR:-/tmp}/julia-dmg-XXXXXX.hfs")"

# The Developer ID private key lives in AWS KMS; the .dmg itself is signed via
# rcodesign (see utilities/macos/rcodesign/). AWS credentials must already be
# available (source utilities/aws_oidc.sh publish).
MACOS_CODESIGN_KMS_KEY="${MACOS_CODESIGN_KMS_KEY:?}"
NOTARY_API_KEY_FILE="${THIS_DIR}/notary_api_key.json"

# HFS+/DMG tools. newfs_hfs creates the HFS+ filesystem (the mkfs.hfsplus from
# hfsprogs/diskdev_cmds, built from source in the publish image because hfsprogs
# was dropped from Debian after bullseye); hfsplus (populate) and dmg (convert
# to UDIF) come from libdmg-hfsplus.
MKFSHFS_TOOL="${MKFSHFS_TOOL:-newfs_hfs}"
HFSPLUS_TOOL="${HFSPLUS_TOOL:-hfsplus}"
DMG_TOOL="${DMG_TOOL:-dmg}"

# Lay out the .dmg contents: the signed .app, the /Applications symlink (added
# below; addall cannot carry it) and the volume icon (taken from inside the .app).
rm -rf "${DMG_PATH}"
mkdir -p "${DMG_PATH}"
cp -aR "${APP_PATH}" "${DMG_PATH}/"
if [[ -f "${APP_PATH}/Contents/Resources/julia.icns" ]]; then
    cp "${APP_PATH}/Contents/Resources/julia.icns" "${DMG_PATH}/.VolumeIcon.icns"
fi

# Create the `.dmg`: an HFS+ filesystem image filled with the staged directory,
# converted to a compressed UDIF, then signed. We define this in a function
# because we need to do it again after stapling.
function create_dmg() {
    rm -f "${DMG_NAME}" "${HFS_IMAGE}"

    # Size the filesystem well above the measured tree size. HFS+ catalog/extents
    # metadata and per-file allocation rounding over the thousands of files in the
    # Julia tree need far more than a few percent of slack -- an under-sized volume
    # fails mid-populate ("rawFileWrite ... allocate"). This only affects the
    # *uncompressed* image (the final UDIF dmg is compressed), so a generous 50% +
    # 256 MB margin is free.
    local size_mb
    size_mb="$(( $(du -sm "${DMG_PATH}" | cut -f1) * 3 / 2 + 256 ))"
    truncate -s "${size_mb}M" "${HFS_IMAGE}"
    "${MKFSHFS_TOOL}" -v "${VOLUME_NAME}" "${HFS_IMAGE}"

    # `addall` logs every file and directory it copies (thousands of lines), which
    # both floods the build log and slows the step (all of it streams to the
    # agent). Capture it and only surface the tail on failure.
    local addall_log
    addall_log="$(mktemp)"
    if ! "${HFSPLUS_TOOL}" "${HFS_IMAGE}" addall "${DMG_PATH}" > "${addall_log}" 2>&1; then
        echo "ERROR: hfsplus addall failed; tail of its output:" >&2
        tail -30 "${addall_log}" >&2
        rm -f "${addall_log}"
        return 1
    fi
    rm -f "${addall_log}"
    "${HFSPLUS_TOOL}" "${HFS_IMAGE}" symlink "/Applications" "/Applications"
    # Mark the volume root as having a custom icon (.VolumeIcon.icns)
    "${HFSPLUS_TOOL}" "${HFS_IMAGE}" attr "/" C

    "${DMG_TOOL}" build "${HFS_IMAGE}" "${DMG_NAME}"
    rm -f "${HFS_IMAGE}"

    # Sign the `.dmg` itself
    "${THIS_DIR}/codesign.sh" \
        --kms-key "${MACOS_CODESIGN_KMS_KEY}" \
        "${DMG_NAME}"
}
create_dmg

# Notarize the `.dmg`. The App Store Connect API key also lives in KMS;
# notary_api_key.json contains no secret material (see ops/21_import_notary_key.sh).
#
# The non-production publish test stack sets PUBLISH_SKIP_NOTARIZATION=1:
# notarization is a hosted Apple round-trip with no self-signable equivalent, so
# the test pipeline skips it. The .dmg is still KMS-signed; only the Apple
# notarize + staple (and the post-staple rebuild) are skipped.
if [[ "${PUBLISH_SKIP_NOTARIZATION:-0}" != "1" ]]; then
    RCODESIGN="$("${THIS_DIR}/get_rcodesign.sh")"

    "${RCODESIGN}" notary-submit \
        --api-key-file "${NOTARY_API_KEY_FILE}" \
        --wait \
        "${DMG_NAME}"

    # Staple the notarization ticket to the app, then re-build the .dmg.
    "${RCODESIGN}" staple "${DMG_PATH}/$(basename "${APP_PATH}")"
    create_dmg
else
    echo "Skipping notarization (PUBLISH_SKIP_NOTARIZATION=1): .dmg is KMS-signed but not notarized/stapled." >&2
fi

# Cleanup things we created here
rm -rf "${DMG_PATH}"
