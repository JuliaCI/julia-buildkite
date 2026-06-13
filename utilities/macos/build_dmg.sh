#!/bin/bash
# Build, sign and notarize the Julia .dmg -- on LINUX.
#
# Apple-only tooling is replaced as follows (the same approach Mozilla uses
# to package Firefox DMGs on linux):
#   osacompile  ->  a pre-built .app skeleton tarball, committed at
#                   utilities/macos/julia-app-skeleton.tar.gz (built once on
#                   a Mac by ops/31_build_app_skeleton.sh; AppleScript can
#                   only be compiled there)
#   plutil      ->  python3 plistlib (stdlib)
#   hdiutil     ->  newfs_hfs (the `mkfs.hfsplus` from hfsprogs/diskdev_cmds)
#                   to create the HFS+ filesystem, plus the `hfsplus` and `dmg`
#                   tools from mozilla/libdmg-hfsplus to populate and convert it
# Code signing and notarization were already linux-capable: rcodesign signs
# cross-platform with the Developer ID key in AWS KMS, and notarization is
# an App Store Connect API call (key also in KMS).

set -euo pipefail

THIS_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

DMG_PATH="dmg"
mkdir -p "${DMG_PATH}"
APP_PATH="${DMG_PATH}/Julia-${MAJMIN?}.app"
DMG_NAME="${UPLOAD_FILENAME?}.dmg"
VOLUME_NAME="Julia-${TAR_VERSION?}"
HFS_IMAGE="$(mktemp -u "${TMPDIR:-/tmp}/julia-dmg-XXXXXX.hfs")"

# The Developer ID private key lives in AWS KMS; signing + notarization
# happen via rcodesign (see utilities/macos/rcodesign/). AWS credentials
# must already be available (source utilities/aws_oidc.sh publish).
MACOS_CODESIGN_KMS_KEY="${MACOS_CODESIGN_KMS_KEY:?}"
NOTARY_API_KEY_FILE="${THIS_DIR}/notary_api_key.json"

# HFS+/DMG tools (must be in the publish image). `newfs_hfs` creates the HFS+
# filesystem -- it is the `mkfs.hfsplus` from hfsprogs/diskdev_cmds, built from
# source in the image because hfsprogs was dropped from Debian after bullseye.
# `hfsplus` (populate) and `dmg` (convert to UDIF) come from libdmg-hfsplus.
MKFSHFS_TOOL="${MKFSHFS_TOOL:-newfs_hfs}"
HFSPLUS_TOOL="${HFSPLUS_TOOL:-hfsplus}"
DMG_TOOL="${DMG_TOOL:-dmg}"

APP_SKELETON="${THIS_DIR}/julia-app-skeleton.tar.gz"
if [[ ! -f "${APP_SKELETON}" ]]; then
    echo "ERROR: ${APP_SKELETON} not found." >&2
    echo "Build it once on a Mac with ops/31_build_app_skeleton.sh and commit it." >&2
    exit 1
fi

# Unpack the pre-compiled .app launcher skeleton (Contents/MacOS/applet +
# the compiled AppleScript), then fill out its Info.plist for this release.
tar -xzf "${APP_SKELETON}" -C "${DMG_PATH}"
mv "${DMG_PATH}/Julia.app" "${APP_PATH}"

python3 - "${APP_PATH}/Contents/Info.plist" <<EOF
import plistlib, sys
path = sys.argv[1]
with open(path, "rb") as f:
    plist = plistlib.load(f)
plist["CFBundleDevelopmentRegion"] = "en"
plist["CFBundleDisplayName"] = "Julia"
plist["CFBundleIconFile"] = "julia.icns"
plist["CFBundleIdentifier"] = "org.julialang.launcherapp"
plist["CFBundleName"] = "Julia"
plist["CFBundleShortVersionString"] = "${MAJMINPAT?}"
plist["CFBundleVersion"] = "${JULIA_VERSION?}-${SHORT_COMMIT?}"
plist["NSHumanReadableCopyright"] = "$(date '+%Y') The Julia Project"
with open(path, "wb") as f:
    plistlib.dump(plist, f)
EOF

# Add icon file for the application and the .dmg
cp "contrib/mac/app/julia.icns" "${APP_PATH}/Contents/Resources/"
cp "contrib/mac/app/julia.icns" "${DMG_PATH}/.VolumeIcon.icns"

# Copy our signed tarball into the `.dmg`
cp -aR "${JULIA_INSTALL_DIR?}" "${APP_PATH}/Contents/Resources/julia"

# Sign the `.app` launcher
"${THIS_DIR}/codesign.sh" \
    --kms-key "${MACOS_CODESIGN_KMS_KEY}" \
    "${APP_PATH}/Contents/MacOS/applet"

# Create the `.dmg`: an HFS+ filesystem image filled with the staged
# directory (plus the /Applications symlink, which `addall` cannot carry),
# converted to a compressed UDIF. We define this in a function because we
# need to do it again after stapling.
function create_dmg() {
    rm -f "${DMG_NAME}" "${HFS_IMAGE}"

    # Size the filesystem to the contents plus some breathing room; this
    # only affects the uncompressed filesystem, not the download size.
    local size_mb
    size_mb="$(( $(du -sm "${DMG_PATH}" | cut -f1) * 11 / 10 + 64 ))"
    truncate -s "${size_mb}M" "${HFS_IMAGE}"
    "${MKFSHFS_TOOL}" -v "${VOLUME_NAME}" "${HFS_IMAGE}"

    "${HFSPLUS_TOOL}" "${HFS_IMAGE}" addall "${DMG_PATH}"
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
# notary_api_key.json contains no secret material (see ops/21_import_notary_key.sh),
# so it is committed in this repository in plaintext.
RCODESIGN="$("${THIS_DIR}/get_rcodesign.sh")"

"${RCODESIGN}" notary-submit \
    --api-key-file "${NOTARY_API_KEY_FILE}" \
    --wait \
    "${DMG_NAME}"

# Staple the notarization ticket to the app
"${RCODESIGN}" staple "${APP_PATH}"

# Re-build the .dmg from the app now that it's notarized
create_dmg

# Cleanup things we created here
rm -rf "${DMG_PATH}"
