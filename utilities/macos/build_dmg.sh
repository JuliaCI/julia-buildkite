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
    .buildkite/utilities/macos/codesign.sh \
        --keychain "${KEYCHAIN_PATH}" \
        --identity "${MACOS_CODESIGN_IDENTITY}" \
        "${DMG_NAME}"
}
create_dmg

# Upload the `.dmg` for notarization
xcrun altool \
    --notarize-app \
    --primary-bundle-id org.julialang.launcherapp \
    --username "${NOTARIZATION_APPLE_ID}" \
    --password "${NOTARIZATION_APPLE_KEY}" \
    -itc_provider A427R7F42H \
    --file "${DMG_NAME}" \
    --output-format xml > notarization.xml

# Get the upload UUID from the xml file
UUID="$(/usr/libexec/PlistBuddy -c "print notarization-upload:RequestUUID" notarization.xml 2>/dev/null)"
echo "Waiting until UUID ${UUID} is done processing...."

# Wait for apple's servers to give us a valid notarization
ALTOOL_FAILURES=0
while true; do
    if ! xcrun altool \
        --notarization-info "${UUID}" \
        --username "${NOTARIZATION_APPLE_ID}" \
        --password "${NOTARIZATION_APPLE_KEY}" \
        --output-format xml > notarization.xml; then

        ALTOOL_FAILURES=$((${ALTOOL_FAILURES} + 1))
        echo -n "altool has failed ${ALTOOL_FAILURES} times " >&2
        if [[ "${ALTOOL_FAILURES}" < 10 ]]; then
            echo "looping..."
            sleep 2
            continue
        else
            # If we've had more than 10 failures in a row, bail.
            # Something might be wrong with the servers right now,
            # and there's no sense in holding up the CI queue waiting.
            echo "bailing out!" >&2
            false
        fi
    else
        # If we got a good return value, forget about any previous altool failures.
        ALTOOL_FAILURES=0
    fi

    STATUS=$(/usr/libexec/PlistBuddy -c "print notarization-info:Status" notarization.xml 2>/dev/null)

    # Process loop exit conditions
    if [[ ${STATUS} == "success" ]]; then
        echo "Notarization finished"
        break
    elif [[ ${STATUS} == "in progress" ]]; then
        echo -n "."
        sleep 10
        continue
    elif [[ ${STATUS} == "invalid" ]]; then
        echo "invalid!  Looks like something got borked:"
        /usr/libexec/PlistBuddy -c "print notarization-info:LogFileURL" notarization.xml 2>/dev/null
        exit 1
    else
        echo "Notarization failed with status ${STATUS}"
        exit 1
    fi
done

# Staple the notarization to the app
xcrun stapler staple "${APP_PATH}"

# Re-build the .dmg from the app now that it's notarized
create_dmg

# Cleanup things we created here
rm -rf "${DMG_PATH}" notarization.xml
