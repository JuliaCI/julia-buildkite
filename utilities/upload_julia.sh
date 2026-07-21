#!/usr/bin/env bash

# Publish a Julia build that was previously staged as an unsigned `.tar.gz`.
#
#   upload_julia.sh publish   (TRUSTED, runs in the julia-publish pipeline)
#       Verifies the commit is a real release commit, then signs (macOS
#       codesign + notarize, Windows Trusted Signing, GPG tarball) and
#       promotes the artifacts from the julia-ci staging bucket to the
#       canonical release locations using the `publish` role. Never runs
#       on pull requests.
#
# (The untrusted counterpart -- staging the unsigned tarball write-once to
# the per-pipeline ephemeral staging bucket -- happens directly in the
# build step, see build_julia.sh.)
#
# Requires TRIPLET to be defined.
set -euo pipefail

MODE="${1:?usage: upload_julia.sh publish}"

# First, get things like `SHORT_COMMIT`, `UPLOAD_TARGETS`, `STAGING_TARGET`, etc...
# shellcheck source=SCRIPTDIR/build_envs.sh
source .buildkite/utilities/build_envs.sh

THIS_DIR="$(realpath "$(dirname "${BASH_SOURCE[0]}")")"

# shellcheck source=SCRIPTDIR/upload_to_s3.sh
source .buildkite/utilities/upload_to_s3.sh

# KMS keys used for release signing (aliases resolve in the CI account).
# The non-production publish test stack overrides these with the throwaway
# *-test aliases and the matching test public key / self-signed cert.
MACOS_CODESIGN_KMS_KEY="${MACOS_CODESIGN_KMS_KEY:-alias/julia-macos-codesigning}"
TARBALL_SIGNING_KMS_KEY="${TARBALL_SIGNING_KMS_KEY:-alias/julia-tarball-signing}"
# OpenPGP public key matching TARBALL_SIGNING_KMS_KEY (used only to derive the
# issuer fingerprint embedded in the signature; see kms_gpg_sign.py). Defaults
# to the committed production key. Set it to EMPTY (with TARBALL_SIGNING_PUBKEY_CREATED)
# to instead derive the key identity from KMS (kms:GetPublicKey) at runtime --
# the throwaway test stack does this so it need not commit a test pubkey.
# (`-` not `:-` so an explicit empty value is honored.)
TARBALL_SIGNING_PUBKEY="${TARBALL_SIGNING_PUBKEY-.buildkite/signing-pubkeys/tarball_signing.pub.asc}"

# Because `wait` returns the exit code of the waited-upon PID, this (with
# `set -e`) ends execution if any backgrounded task failed.
wait_pids() {
    for PID in "$@"; do
        wait "${PID}"
    done
}

if [[ "${MODE}" != "publish" ]]; then
    echo "ERROR: unknown mode '${MODE}' (expected 'publish')" >&2
    exit 1
fi

# ============================================================================
# PUBLISH (trusted)
# ============================================================================

# When invoked in a loop by publish.sh, the trust guard and OIDC role have
# already been established once for the whole step; skip re-doing them per
# triplet. Otherwise (standalone invocation) do them here.
if [[ -z "${PUBLISH_PREAUTHED:-}" ]]; then
    # Defense in depth: refuse unless this commit is a genuine release commit
    # on the canonical upstream. The real boundary is that the julia-publish
    # pipeline does not build pull requests at all (see ops/README.md).
    echo "--- Verify this is a trusted release commit"
    bash .buildkite/utilities/verify_trusted_commit.sh

    # shellcheck source=SCRIPTDIR/aws_oidc.sh
    source .buildkite/utilities/aws_oidc.sh publish
fi

echo "--- Download unsigned tarball from s3://${STAGING_TARGET}.tar.gz"
aws s3 cp "s3://${STAGING_TARGET}.tar.gz" "${UPLOAD_FILENAME}.tar.gz"

# These are the extensions that we will always upload
UPLOAD_EXTENSIONS=( "tar.gz" )

# macOS: the build_ step staged an assembled (unsigned) Julia.app. Unpack it,
# codesign everything in it (the launcher + the bundled julia tree), then derive
# both products from the signed bundle: the .tar.gz (the tree) and the .dmg.
if [[ "${OS}" == "macos" || "${OS}" == "macosnogpl" ]]; then
    APP_NAME="Julia-${MAJMIN?}.app"
    echo "--- [mac] Download + unpack the staged unsigned .app"
    aws s3 cp "s3://${STAGING_TARGET}.app.tar.gz" "${UPLOAD_FILENAME}.app.tar.gz"
    rm -rf "${APP_NAME}"
    tar zxf "${UPLOAD_FILENAME}.app.tar.gz"
    chmod -R u+w "${APP_NAME}"

    # Break the julia/julia-terminal hardlink before signing. contrib/mac/app
    # builds the launcher as a hardlink: bin/julia-terminal and bin/julia are ONE
    # inode with two names. The bundle's main executable is julia-terminal (via
    # the Contents/MacOS/julia-terminal symlink), so the seal signs that inode
    # with the MAIN-EXECUTABLE signature -- which lands on bin/julia too. Apple's
    # notary then validates bin/julia as an ordinary nested binary, finds the
    # main-executable signature, and rejects BOTH paths: "The signature of the
    # binary is invalid." Split the inode into two independent regular files so
    # each carries its own correct signature (nested for julia, main-executable
    # for julia-terminal). A full copy keeps the name-based loader dispatch (see
    # cli/loader_exe.c) and the bin/ rpath, exactly like the hardlink; bin/julia
    # is the small loader, so the extra copy is negligible.
    julia_bin="${APP_NAME}/Contents/Resources/julia/bin/julia"
    julia_terminal="${APP_NAME}/Contents/Resources/julia/bin/julia-terminal"
    if [[ -f "${julia_terminal}" && "${julia_terminal}" -ef "${julia_bin}" ]]; then
        echo "--- [mac] Break julia/julia-terminal hardlink (independent signatures for notarization)"
        rm -f "${julia_terminal}"
        cp -p "${julia_bin}" "${julia_terminal}"
    fi

    # Signing is split across three steps because the stdlib pkgimage checksum
    # fixup has to happen in the middle. Codesigning rewrites every pkgimage
    # Mach-O (.dylib), which changes its crc32c; the .ji caches embed that
    # crc32c, so they must be repatched AFTER signing -- otherwise julia rejects
    # the native code caches at load ("native code cache checksum is invalid")
    # and recompiles them. But the .ji files are also sealed into the bundle's
    # CodeResources, so the repatch must land BEFORE the bundle seal. Hence:
    # sign nested -> patch checksums -> seal.
    echo "--- [mac] Codesign nested Mach-Os (pre-seal)"
    # The Developer ID private key lives in AWS KMS; every signature is a
    # kms:Sign call performed by rcodesign (no keychain, no key file).
    .buildkite/utilities/macos/codesign.sh \
        --kms-key "${MACOS_CODESIGN_KMS_KEY}" \
        --no-seal \
        "${APP_NAME}"

    echo "--- [mac] Update checksums for stdlib cachefiles"
    # Cross mode: the host julia rewrites the (now signed) pkgimage checksums in
    # the bundled foreign-platform target tree in place.
    julia .buildkite/utilities/update_stdlib_pkgimage_checksums.jl \
        "${APP_NAME}/Contents/Resources/julia" dylib

    echo "--- [mac] Seal the .app bundle"
    # Seals Contents/_CodeSignature/CodeResources (over the checksum-corrected
    # tree) and signs the main executable (Contents/MacOS/applet) in bundle
    # context, so Apple's notary accepts the bundle signature.
    .buildkite/utilities/macos/codesign.sh \
        --kms-key "${MACOS_CODESIGN_KMS_KEY}" \
        --seal-only \
        "${APP_NAME}"

    echo "--- [mac] Repackage the signed tree as the .tar.gz product"
    rm -rf "${JULIA_INSTALL_DIR}"
    cp -aR "${APP_NAME}/Contents/Resources/julia" "${JULIA_INSTALL_DIR}"
    rm -f "${UPLOAD_FILENAME}.tar.gz"
    tar zcf "${UPLOAD_FILENAME}.tar.gz" "${JULIA_INSTALL_DIR}"

    # Build the `.dmg` from the signed .app (notarization gated by
    # PUBLISH_SKIP_NOTARIZATION inside build_dmg.sh).
    echo "--- [mac] Build .dmg"
    MACOS_CODESIGN_KMS_KEY="${MACOS_CODESIGN_KMS_KEY}" APP_PATH="${APP_NAME}" \
        .buildkite/utilities/macos/build_dmg.sh

    UPLOAD_EXTENSIONS+=( "dmg" )
elif [[ "${OS}" == "windows" || "${OS}" == "windowsnogpl" ]]; then
    echo "--- [windows] Extract pre-built Julia"
    # JULIA_INSTALL_DIR is shared across the triplets published sequentially
    # by publish.sh; clear out the previous triplet's tree (e.g. the signed
    # macOS one, .dylibs and all) so it cannot leak into the Windows products.
    rm -rf "${JULIA_INSTALL_DIR}"
    mkdir -p "${JULIA_INSTALL_DIR}"
    tar zxf "${UPLOAD_FILENAME}.tar.gz" -C "${JULIA_INSTALL_DIR}" --strip-components 1

    echo "--- [windows] make exe (Inno Setup under Wine)"
    # The whole Windows packaging path runs on this linux agent: Inno Setup
    # is preinstalled in the publish image's Wine prefix (no installer
    # download at publish time), and Authenticode signing happens host-side
    # via jsign + Azure Trusted Signing (Buildkite OIDC workload identity
    # federation, no client secret; see utilities/windows/codesign.sh).
    # ISCC's compile-time SignTool (installer + embedded uninstaller)
    # bridges back to the host signer through wine_signtool.cmd.
    codesign_script="$THIS_DIR/windows/codesign.sh"
    iss_file="$THIS_DIR/windows/build-installer.iss"
    WINE="${WINE:-wine}"
    ISCC_EXE="${ISCC_EXE:-C:\\Program Files (x86)\\Inno Setup 6\\ISCC.exe}"
    export CODESIGN_SH="${codesign_script}"

    # Wine needs a valid XDG_RUNTIME_DIR for the wineserver runtime socket.
    # The sandbox leaves it unset/invalid, which makes wineserver service
    # startup fail and `winepath` page-fault. Point it at a private 0700 dir.
    if [[ -z "${XDG_RUNTIME_DIR:-}" ]] || [[ ! -w "${XDG_RUNTIME_DIR:-/nonexistent}" ]]; then
        XDG_RUNTIME_DIR="${TMPDIR:-/tmp}/xdg-runtime-$(id -u)"
        mkdir -p "${XDG_RUNTIME_DIR}"
        chmod 700 "${XDG_RUNTIME_DIR}"
        export XDG_RUNTIME_DIR
    fi

    # Marker file the SignTool hook (wine_signtool.cmd) uses to block until
    # codesign.sh has actually finished: Wine's `start /wait /unix` does not
    # wait for the launched Unix process, so without this the hook returns
    # before signing happens and ISCC reaps the transient uninstaller temp
    # out from under jsign. The hook needs both the Unix path (the signer
    # writes it) and its Windows form (the sandbox maps Wine's Z: drive to /).
    CODESIGN_HOOK_DONE="${XDG_RUNTIME_DIR}/codesign-hook.done"
    export CODESIGN_HOOK_DONE
    CODESIGN_HOOK_DONE_WIN="Z:${CODESIGN_HOOK_DONE//\//\\}"
    export CODESIGN_HOOK_DONE_WIN

    "${WINE}" "${ISCC_EXE}" \
        /DAppVersion="${JULIA_VERSION}" \
        /DSourceDir="$("${WINE}" winepath -w "$(pwd)/${JULIA_INSTALL_DIR}")" \
        /DRepoDir="$("${WINE}" winepath -w "$(pwd)")" \
        /F"${UPLOAD_FILENAME}" \
        /O"$("${WINE}" winepath -w "$(pwd)")" \
        /Dsign=true \
        /Smysigntool="cmd.exe /c $("${WINE}" winepath -w "${THIS_DIR}/windows/wine_signtool.cmd") \$f" \
        "$("${WINE}" winepath -w "${iss_file}")"

    # Tripwire: if the Wine->host signing bridge failed silently, the
    # installer would come out unsigned; refuse to publish it. (Skipped when
    # PUBLISH_SKIP_WINDOWS_SIGN=1, where the installer is intentionally
    # unsigned -- see windows/codesign.sh.)
    if [[ "${PUBLISH_SKIP_WINDOWS_SIGN:-0}" != "1" ]]; then
        echo "--- [windows] Verify the installer is Authenticode-signed"
        python3 "$THIS_DIR/windows/check_signed.py" "${UPLOAD_FILENAME}.exe"
    fi

    # Add the `.exe` to our upload targets
    UPLOAD_EXTENSIONS+=( "exe" )

    # Next, directly codesign every PE file in the install dir
    echo "--- [windows] Codesign everything in the install directory"
    "${codesign_script}" "${JULIA_INSTALL_DIR}"

    echo "--- [windows] Update checksums for stdlib cachefiles"
    # Cross mode: the signed Windows binaries cannot run on this linux
    # agent, so the host julia patches the target tree in place.
    julia .buildkite/utilities/update_stdlib_pkgimage_checksums.jl "${JULIA_INSTALL_DIR}" dll

    # Immediately re-compress that tarball for upload
    echo "--- [windows] Re-compress codesigned tarball"
    rm -f "${UPLOAD_FILENAME}.tar.gz"
    tar zcf "${UPLOAD_FILENAME}.tar.gz" "${JULIA_INSTALL_DIR}"

    # Use 7z (p7zip) to create a `.zip` file to upload as well
    echo "--- [windows] make zip"
    # `7z a` merges into an existing archive; start fresh so a leftover zip
    # from an earlier run in the same workdir can't contribute stale entries.
    rm -f "${UPLOAD_FILENAME}.zip"
    7z a "${UPLOAD_FILENAME}.zip" "${JULIA_INSTALL_DIR}"
    UPLOAD_EXTENSIONS+=( "zip" )
fi

echo "--- GPG-sign the tarball"
# The OpenPGP signature is assembled locally but the raw RSA signature
# comes from AWS KMS, where the release signing key was generated and
# never leaves. Signatures verify against the committed public key,
# exported from KMS with ops/20_export_gpg_pubkey.py.
if [[ -n "${TARBALL_SIGNING_PUBKEY}" ]]; then
    GPG_PUBKEY_ARGS=( --public-key "${TARBALL_SIGNING_PUBKEY}" )
else
    # Derive the key identity from KMS at runtime (no committed pubkey); the
    # creation timestamp defaults to the KMS key's own CreationDate. Set
    # TARBALL_SIGNING_PUBKEY_CREATED only to pin it to a published pubkey.
    GPG_PUBKEY_ARGS=( --public-key-from-kms )
    [[ -n "${TARBALL_SIGNING_PUBKEY_CREATED:-}" ]] && GPG_PUBKEY_ARGS+=( --created "${TARBALL_SIGNING_PUBKEY_CREATED}" )
fi
python3 .buildkite/utilities/kms_gpg_sign.py \
    "${GPG_PUBKEY_ARGS[@]}" \
    --kms-key-id "${TARBALL_SIGNING_KMS_KEY}" \
    "${UPLOAD_FILENAME}.tar.gz"
UPLOAD_EXTENSIONS+=( "tar.gz.asc" )

# Promote to all final S3 targets (each target gets a direct upload of the
# local file; no bucket-to-bucket copies, since write-once enforcement only
# applies to PutObject). The signed products are NOT also uploaded to buildkite
# artifacts -- the final S3 locations are the canonical output.
echo "--- Promote to final S3 locations"
PIDS=()
for UPLOAD_TARGET in "${UPLOAD_TARGETS[@]}"; do
    for EXT in "${UPLOAD_EXTENSIONS[@]}"; do
        upload_to_s3 "${UPLOAD_FILENAME}.${EXT}" "${UPLOAD_TARGET}.${EXT}" &
        PIDS+=( "$!" )
    done
done
wait_pids "${PIDS[@]}"

echo "+++ Published to targets"
for UPLOAD_TARGET in "${UPLOAD_TARGETS[@]}"; do
    for EXT in "${UPLOAD_EXTENSIONS[@]}"; do
        echo " -> s3://${UPLOAD_TARGET}.${EXT}"
    done
done
