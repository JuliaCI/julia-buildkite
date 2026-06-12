#!/bin/bash

set -euo pipefail

THIS_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

DMG_PATH="dmg"
mkdir -p "${DMG_PATH}"
APP_PATH="${DMG_PATH}/Julia-${MAJMIN?}.app"
DMG_NAME="${UPLOAD_FILENAME?}.dmg"

# The Developer ID private key lives in AWS KMS; signing + notarization
# happen via rcodesign (see utilities/macos/rcodesign/). AWS credentials
# must already be available (source utilities/aws_oidc.sh upload).
MACOS_CODESIGN_KMS_KEY="${MACOS_CODESIGN_KMS_KEY:?}"
NOTARY_API_KEY_FILE="${THIS_DIR}/notary_api_key.json"

# Start by compiling an applescript into a `.app`, which creates the skeleton, which we will fill out
osacompile -o "${APP_PATH}" "contrib/mac/app/startup.applescript"

# Use `plutil` to fill out the `Info.plist` appropriately
plutil -replace CFBundleDevelopmentRegion  -string "en" "${APP_PATH}/Contents/Info.plist"
plutil -insert  CFBundleDisplayName        -string "Julia" "${APP_PATH}/Contents/Info.plist"
plutil -replace CFBundleIconFile           -string "julia.icns" "${APP_PATH}/Contents/Info.plist"
plutil -insert  CFBundleIdentifier         -string "org.julialang.launcherapp" "${APP_PATH}/Contents/Info.plist"
plutil -replace CFBundleName               -string "Julia" "${APP_PATH}/Contents/Info.plist"
plutil -insert  CFBundleShortVersionString -string "${MAJMINPAT?}" "${APP_PATH}/Contents/Info.plist"
plutil -insert  CFBundleVersion            -string "${JULIA_VERSION?}-${SHORT_COMMIT?}" "${APP_PATH}/Contents/Info.plist"
plutil -insert  NSHumanReadableCopyright   -string "$(date '+%Y') The Julia Project" "${APP_PATH}/Contents/Info.plist"

# Add icon file for the application and the .dmg
cp "contrib/mac/app/julia.icns" "${APP_PATH}/Contents/Resources/"
cp "contrib/mac/app/julia.icns" "${DMG_PATH}/.VolumeIcon.icns"

# Add link to `/Applications`
ln -s /Applications "${DMG_PATH}/Applications"

# Copy our signed tarball into the `.dmg`
cp -aR "${JULIA_INSTALL_DIR?}" "${APP_PATH}/Contents/Resources/julia"

# Sign the `.app` launcher
"${THIS_DIR}/codesign.sh" \
    --kms-key "${MACOS_CODESIGN_KMS_KEY}" \
    "${APP_PATH}/Contents/MacOS/applet"

# Create `.dmg`.  We create it with 1TB size, but since that is
# a maximum, it has no effect on download or unpack size.
# We define this in a function because we need to do it again later.
function create_dmg() {
    rm -f "${DMG_NAME}"

    hdiutil create \
        "${DMG_NAME}" \
        -size 1t \
        -fs HFS+ \
        -volname "Julia-${TAR_VERSION?}" \
        -imagekey zlib-level=9 \
        -srcfolder "${DMG_PATH}"

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
