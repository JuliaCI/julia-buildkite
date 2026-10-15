#!/usr/bin/env bash
# Promote a published Julia release from the nightlies bucket to the
# release bucket (the "bucket dance"): julialangnightlies -> julialang2,
# served at https://julialang-s3.julialang.org, which is where
# versions.json, juliaup, setup-julia and the website point.
#
# Runs as the single trusted step of the julia-promote pipeline. Builds
# are created MANUALLY (New Build with branch = v<version>) after the
# julia-publish run for that tag has completed; the version identity is
# taken from the branch, never from checkout state, mirroring the publish
# flow's naming (see TAR_VERSION in build_envs.sh).
#
# The release bucket keeps the historical buildbot-era layout (folder
# x86_64->x64, i686->x86; short mac64/win64 file names), which is what
# VersionsJSONUtil.jl constructs URLs against. This script re-maps the
# published objects into that layout, repoints the julia-<majmin>-latest
# pointers, generates the bin/checksums/julia-<version> files, purges the
# Fastly cache, and verifies everything is reachable via the CDN.
set -euo pipefail

if [[ ! "${BUILDKITE_BRANCH:-}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]]; then
    echo "ERROR: BUILDKITE_BRANCH='${BUILDKITE_BRANCH:-}' is not a release tag; create this build with branch = v<version>" >&2
    exit 1
fi
VERSION="${BUILDKITE_BRANCH#v}"
MAJMIN="$(cut -d. -f1-2 <<<"${VERSION}")"

# Defense in depth, as in publish.sh: refuse unless this commit is a
# genuine release commit on the canonical upstream. (Buildkite resolves
# branch = v<version> to the tag's commit, so BUILDKITE_COMMIT is the
# release commit.)
bash .buildkite/utilities/verify_trusted_commit.sh

# shellcheck source=SCRIPTDIR/aws_oidc.sh
source .buildkite/utilities/aws_oidc.sh promote
# shellcheck source=SCRIPTDIR/upload_to_s3.sh
source .buildkite/utilities/upload_to_s3.sh

# The non-production test stack may override these.
SRC_BUCKET="${SRC_BUCKET:-julialangnightlies}"
DEST_BUCKET="${DEST_BUCKET:-julialang2}"
CDN_URL="${CDN_URL:-https://julialang-s3.julialang.org}"
DEST_S3_URL="${DEST_S3_URL:-https://${DEST_BUCKET}.s3.amazonaws.com}"
TARBALL_SIGNING_PUBKEY="$(realpath "${TARBALL_SIGNING_PUBKEY:-.buildkite/signing-pubkeys/tarball_signing.pub.asc}")"
VERIFY_SIGNATURES="$(realpath .buildkite/utilities/verify_tarball_signatures.py)"

# "<file basename> <source dir> <destination dir>", dirs relative to bin/.
# Sources are what upload_julia.sh published for a v* tag; destinations
# are the release-bucket layout (verified against v1.13.0-rc1).
MAPPINGS=(
    "julia-${VERSION}-linux-x86_64.tar.gz    linux/x86_64/${MAJMIN}   linux/x64/${MAJMIN}"
    "julia-${VERSION}-linux-i686.tar.gz      linux/i686/${MAJMIN}     linux/x86/${MAJMIN}"
    "julia-${VERSION}-linux-aarch64.tar.gz   linux/aarch64/${MAJMIN}  linux/aarch64/${MAJMIN}"
    "julia-${VERSION}-mac64.tar.gz           mac/x64/${MAJMIN}        mac/x64/${MAJMIN}"
    "julia-${VERSION}-mac64.dmg              mac/x64/${MAJMIN}        mac/x64/${MAJMIN}"
    "julia-${VERSION}-macaarch64.tar.gz      mac/aarch64/${MAJMIN}    mac/aarch64/${MAJMIN}"
    "julia-${VERSION}-macaarch64.dmg         mac/aarch64/${MAJMIN}    mac/aarch64/${MAJMIN}"
    "julia-${VERSION}-win64.exe              winnt/x64/${MAJMIN}      winnt/x64/${MAJMIN}"
    "julia-${VERSION}-win64.zip              winnt/x64/${MAJMIN}      winnt/x64/${MAJMIN}"
    "julia-${VERSION}-win64.tar.gz           winnt/x64/${MAJMIN}      winnt/x64/${MAJMIN}"
    "julia-${VERSION}-win32.exe              winnt/x86/${MAJMIN}      winnt/x86/${MAJMIN}"
    "julia-${VERSION}-win32.zip              winnt/x86/${MAJMIN}      winnt/x86/${MAJMIN}"
    "julia-${VERSION}-win32.tar.gz           winnt/x86/${MAJMIN}      winnt/x86/${MAJMIN}"
    "julia-${VERSION}-freebsd-x86_64.tar.gz  freebsd/x86_64/${MAJMIN} freebsd/x64/${MAJMIN}"
)

# Source dists (KMS-signed by publish_srcdist.sh) live at bin/src/ in both
# buckets. Releases published before the source_dist step existed have
# none; promote what there is rather than failing.
if aws s3api head-object --bucket "${SRC_BUCKET}" \
        --key "bin/src/${MAJMIN}/julia-${VERSION}.tar.gz" >/dev/null 2>&1; then
    MAPPINGS+=(
        "julia-${VERSION}.tar.gz       src/${MAJMIN}  src/${MAJMIN}"
        "julia-${VERSION}-full.tar.gz  src/${MAJMIN}  src/${MAJMIN}"
    )
else
    echo "WARN: no source dists at s3://${SRC_BUCKET}/bin/src/${MAJMIN}/julia-${VERSION}.tar.gz; promoting binaries only" >&2
fi

# Every .tar.gz has a KMS-GPG detached signature alongside it.
with_asc() {
    echo "$1"
    [[ "$1" == *.tar.gz ]] && echo "$1.asc"
    return 0
}

# What to do with the julia-<majmin>-latest pointer at bin/<key>: prints
# "keep" when it points to a newer release than VERSION, going by the
# julia-version stamp a promotion leaves on it, and "repoint" otherwise: when it
# is absent, points to this or an older release, or is unstamped (made before
# promote stamped pointers). Fails when that cannot be determined. Promoting an
# older patch again, e.g. to add optimized builds that finished late, must not
# move the pointers back to it.
#
# This reads the bucket's own endpoint anonymously (the release bucket is
# public; the CDN could serve a stale copy). The promote role cannot tell an
# absent object from a forbidden one, as it has no s3:ListBucket.
pointer_action() {
    local headers code pointed
    headers="$(curl -sS -I --retry 3 "${DEST_S3_URL}/bin/$1" | tr -d '\r')" || return 1
    code="$(awk 'NR == 1 {print $2}' <<<"${headers}")"
    case "${code}" in
        404) echo repoint; return 0 ;;
        200) ;;
        *) echo "ERROR: HEAD ${DEST_S3_URL}/bin/$1 returned '${code}'" >&2; return 1 ;;
    esac
    pointed="$(awk -F': ' 'tolower($1) == "x-amz-meta-julia-version" {print $2}' <<<"${headers}")"
    if [[ -z "${pointed}" ]]; then
        echo repoint
    elif [[ ! "${pointed}" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]]; then
        echo "ERROR: ${DEST_S3_URL}/bin/$1 has an invalid julia-version stamp '${pointed}'" >&2
        return 1
    elif [[ "${pointed}" != "${VERSION}" && "$(printf '%s\n' "${pointed//-/\~}" "${VERSION//-/\~}" | sort -V | tail -n 1)" == "${pointed//-/\~}" ]]; then
        # (`~` sorts a prerelease before its release)
        echo keep
    else
        echo repoint
    fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
cd "${WORK}"

echo "--- Download published ${VERSION} artifacts from s3://${SRC_BUCKET}"
for m in "${MAPPINGS[@]}"; do
    read -r base srcdir _ <<<"${m}"
    for f in $(with_asc "${base}"); do
        # Provenance: the publish role stamped every object with the
        # commit of the build that produced it. Refuse to promote an
        # object from a different commit under this version's name (e.g.
        # a repointed tag whose artifacts were never re-published).
        remote_commit="$(aws s3api head-object --bucket "${SRC_BUCKET}" --key "bin/${srcdir}/${f}" \
            --query 'Metadata."build-commit"' --output text)"
        if [[ "${remote_commit}" != "${BUILDKITE_COMMIT}" ]]; then
            echo "ERROR: s3://${SRC_BUCKET}/bin/${srcdir}/${f} was built from commit '${remote_commit}', not ${BUILDKITE_COMMIT}" >&2
            exit 1
        fi
        aws s3 cp --only-show-errors "s3://${SRC_BUCKET}/bin/${srcdir}/${f}" "${f}"
    done
done

echo "--- Verify the tarball signatures"
# A signature and its tarball are separate objects, published independently.
# shellcheck disable=SC2046
python3 "${VERIFY_SIGNATURES}" "${TARBALL_SIGNING_PUBKEY}" \
    $(printf '%s\n' "${MAPPINGS[@]}" | awk '$1 ~ /\.tar\.gz$/ {print $1}')

echo "--- Check the julia-${MAJMIN}-latest pointers"
# All decided before anything is uploaded, so an unknown pointer state stops the
# promotion rather than leaving it half done.
declare -A POINTER_ACTION=()
for m in "${MAPPINGS[@]}"; do
    read -r base _ destdir <<<"${m}"
    [[ "${destdir}" == src/* ]] && continue
    key="${destdir}/julia-${MAJMIN}-latest-${base#julia-"${VERSION}"-}"
    if ! POINTER_ACTION["${key}"]="$(pointer_action "${key}")"; then
        echo "ERROR: cannot tell which release ${key} points to; not promoting" >&2
        exit 1
    fi
    echo "${key}: ${POINTER_ACTION[${key}]}"
done

echo "--- Generate checksum files"
# Binaries only (no .asc), sorted by name -- the historical format of
# bin/checksums/julia-<version>.{sha256,md5}.
BINARIES="$(printf '%s\n' "${MAPPINGS[@]}" | awk '{print $1}' | sort)"
# shellcheck disable=SC2086
sha256sum ${BINARIES} > "julia-${VERSION}.sha256"
# shellcheck disable=SC2086
md5sum ${BINARIES} > "julia-${VERSION}.md5"
cat "julia-${VERSION}.sha256"

echo "--- Promote to s3://${DEST_BUCKET}"
PURGE_KEYS=()
for m in "${MAPPINGS[@]}"; do
    read -r base _ destdir <<<"${m}"
    latest="julia-${MAJMIN}-latest-${base#julia-"${VERSION}"-}"
    repoint=1
    if [[ "${destdir}" == src/* ]]; then
        repoint=0
    elif [[ "${POINTER_ACTION[${destdir}/${latest}]}" == keep ]]; then
        echo "${destdir}/${latest} points to a newer release; leaving it alone"
        repoint=0
    fi
    for f in $(with_asc "${base}"); do
        upload_to_s3 "${f}" "${DEST_BUCKET}/bin/${destdir}/${f}"
        PURGE_KEYS+=( "bin/${destdir}/${f}" )
        # Repoint the majmin-latest copy (upload_to_s3 overwrites
        # julia-*-latest-* names; write-once applies to everything else).
        # Source dists have no latest-pointer convention (and the promote
        # role's repoint grant covers only the binary layout).
        if [[ "${repoint}" -eq 0 ]]; then
            continue
        fi
        latest_name="${latest}${f#"${base}"}"
        UPLOAD_TO_S3_METADATA="julia-version=${VERSION}" \
            upload_to_s3 "${f}" "${DEST_BUCKET}/bin/${destdir}/${latest_name}"
        PURGE_KEYS+=( "bin/${destdir}/${latest_name}" )
    done
done
for ext in sha256 md5; do
    upload_to_s3 "julia-${VERSION}.${ext}" "${DEST_BUCKET}/bin/checksums/julia-${VERSION}.${ext}"
    PURGE_KEYS+=( "bin/checksums/julia-${VERSION}.${ext}" )
done

echo "--- Purge the Fastly cache"
for key in "${PURGE_KEYS[@]}"; do
    curl -fsS -o /dev/null -X PURGE "${CDN_URL}/${key}" \
        || echo "WARN: cache purge failed for ${CDN_URL}/${key}" >&2
done

echo "--- Verify everything is reachable via ${CDN_URL}"
FAILED=()
for key in "${PURGE_KEYS[@]}"; do
    code="$(curl -s -o /dev/null -w '%{http_code}' -I "${CDN_URL}/${key}")"
    [[ "${code}" == "200" ]] || FAILED+=( "${code} ${CDN_URL}/${key}" )
done
if [[ "${#FAILED[@]}" -gt 0 ]]; then
    printf '%s\n' "${FAILED[@]}" >&2
    echo "ERROR: ${#FAILED[@]} object(s) not reachable via the CDN" >&2
    exit 1
fi

echo "+++ Promoted ${VERSION}: ${#PURGE_KEYS[@]} objects live on ${CDN_URL}"
echo "Next: dispatch the CI workflow on JuliaLang/VersionsJSONUtil.jl to regenerate versions.json."
