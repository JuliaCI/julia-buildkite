#!/bin/bash

set -euo pipefail

DMG_PATH="dmg"
mkdir -p "${DMG_PATH}"
APP_PATH="${DMG_PATH}/Julia-${MAJMIN?}.app"
DMG_NAME="${UPLOAD_FILENAME?}.dmg"

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
.buildkite/utilities/macos/codesign.sh \
    --keychain "${KEYCHAIN_PATH}" \
    --identity "${MACOS_CODESIGN_IDENTITY}" \
    "${APP_PATH}/Contents/MacOS/applet"

# Create `.dmg`.  We create it with 1TB size, but since that is
# a maximum, it has no effect on download or unpack size.
hdiutil create \
    "${DMG_NAME}" \
    -size 1t \
    -fs HFS+ \
    -volname "Julia-${TAR_VERSION?}" \
    -imagekey zlib-level=9 \
    -srcfolder "${DMG_PATH}"

# Sign the `.dmg` itself
.buildkite/utilities/macos/codesign.sh \
    --keychain "${KEYCHAIN_PATH}" \
    --identity "${MACOS_CODESIGN_IDENTITY}" \
    "${DMG_NAME}"

rm -rf "${DMG_PATH}"
