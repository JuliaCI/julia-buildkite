#!/usr/bin/env bash
# Resolve and download a published julia: the weekly reference runs of the TTFX and runtime
# benchmark jobs. Sourced after build_envs.sh (OS, ARCH, TRIPLET, S3_BUCKET_PREFIX). A spec
# is "latest" (the newest stable release), a series such as "1.10" (its newest patch
# release), "1.14-nightly" (the newest nightly of that release branch), "branch-nightly"
# (that of the next release's branch) or a version such as "1.13.1".

PUBLISHED_RELEASES_URL="${PUBLISHED_RELEASES_URL:-https://julialang-s3.julialang.org/bin}"
PUBLISHED_LATEST_RELEASE_API="${PUBLISHED_LATEST_RELEASE_API:-https://api.github.com/repos/JuliaLang/julia/releases/latest}"
PUBLISHED_VERSIONS_URL="${PUBLISHED_VERSIONS_URL:-${PUBLISHED_RELEASES_URL}/versions.json}"
PUBLISHED_NIGHTLIES_URL="${PUBLISHED_NIGHTLIES_URL:-https://julialangnightlies-s3.julialang.org}"
PUBLISHED_GITHUB_REPO="${PUBLISHED_GITHUB_REPO:-JuliaLang/julia}"

# The newest stable release: GitHub's "latest" release of JuliaLang/julia, which is
# never a prerelease
latest_release() {
    curl -fsSL --retry 3 -H "Accept: application/vnd.github+json" "${PUBLISHED_LATEST_RELEASE_API}" \
        | sed -n 's/^ *"tag_name": *"v\([0-9][0-9.]*\)".*/\1/p' | head -n1
}

# The newest patch release of a series such as 1.10, from the list of published versions.
# Prereleases carry a suffix (1.10.0-rc1), so the pattern leaves them out.
newest_patch_release() {
    local series="${1//./\\.}"
    curl -fsSL --retry 3 "${PUBLISHED_VERSIONS_URL}" \
        | sed -n "s/^ *\"\(${series}\.[0-9][0-9]*\)\": *{.*/\1/p" \
        | sort -t. -k3,3n | tail -n1
}

# The release branch of the next release: the oldest release-x.y branch whose series has
# no stable release yet. Empty when no such branch exists, e.g. after a release and before
# the next branch is cut. Only later minors of the current major, or the next major's
# x.0, count, which keeps out placeholder branches such as release-9.999.
upcoming_release_branch() {
    local stable
    stable="$(curl -fsSL --retry 3 "${PUBLISHED_VERSIONS_URL}" \
        | sed -n 's/^ *"\([0-9][0-9]*\.[0-9][0-9]*\)\.[0-9][0-9]*": *{.*/\1/p' \
        | sort -u -t. -k1,1n -k2,2n | tail -n1)"
    [[ -n "${stable}" ]] || { echo "Could not find a stable release in ${PUBLISHED_VERSIONS_URL}" >&2; return 1; }
    git ls-remote --heads "https://github.com/${PUBLISHED_GITHUB_REPO}.git" 'refs/heads/release-*' \
        | sed -n 's|.*refs/heads/release-\([0-9][0-9]*\.[0-9][0-9]*\)$|\1|p' \
        | awk -F. -v s="${stable}" 'BEGIN { split(s, v, ".") }
              ($1 == v[1] && $2 > v[2]) || ($1 == v[1] + 1 && $2 == 0)' \
        | sort -t. -k1,1n -k2,2n | head -n1
}

# Resolve the spec $1 and download it to $2. Sets PUBLISHED_VERSION to what was resolved
# (a version, or "x.y-nightly"). Returns 0 when downloaded, 2 when there is nothing to
# measure (no release branch ahead of the latest release, or its nightly not out yet),
# 1 on failure.
download_published_julia() {
    local spec="$1" out="$2" optional="" url status
    local os="${OS%opt}"
    PUBLISHED_VERSION="${spec}"
    if [[ "${spec}" == "latest" ]]; then
        echo "--- Find the latest release"
        PUBLISHED_VERSION="$(latest_release)"
        [[ -n "${PUBLISHED_VERSION}" ]] || { echo "Could not find the latest release from ${PUBLISHED_LATEST_RELEASE_API}" >&2; return 1; }
    elif [[ "${spec}" =~ ^[0-9]+\.[0-9]+$ ]]; then
        echo "--- Find the newest ${spec} release"
        PUBLISHED_VERSION="$(newest_patch_release "${spec}")"
        [[ -n "${PUBLISHED_VERSION}" ]] || { echo "Could not find a ${spec} release in ${PUBLISHED_VERSIONS_URL}" >&2; return 1; }
    elif [[ "${spec}" == "branch-nightly" ]]; then
        echo "--- Find the release branch of the next release"
        local branch
        branch="$(upcoming_release_branch)" || return 1
        if [[ -z "${branch}" ]]; then
            echo "No release branch is ahead of the latest release; nothing to measure"
            return 2
        fi
        PUBLISHED_VERSION="${branch}-nightly"
        optional=1
    fi
    echo "--- Download julia ${PUBLISHED_VERSION}"
    if [[ "${PUBLISHED_VERSION}" =~ ^([0-9]+\.[0-9]+)-nightly$ ]]; then
        # The newest nightly that the release branch has published
        url="${PUBLISHED_NIGHTLIES_URL}/${S3_BUCKET_PREFIX}/${os}/${ARCH}/${BASH_REMATCH[1]}/julia-latest-${os}-${ARCH}.tar.gz"
    else
        # The releases bucket has its own platform names (the nightlies say "macos")
        local path name
        case "${TRIPLET%opt}" in
            aarch64-apple-darwin)    path="mac/aarch64"   name="macaarch64" ;;
            x86_64-apple-darwin)     path="mac/x64"       name="mac64" ;;
            x86_64-linux-gnu)        path="linux/x64"     name="linux-x86_64" ;;
            aarch64-linux-gnu)       path="linux/aarch64" name="linux-aarch64" ;;
            *) echo "No release download path known for ${TRIPLET}" >&2; return 1 ;;
        esac
        url="${PUBLISHED_RELEASES_URL}/${path}/$(cut -d. -f1-2 <<<"${PUBLISHED_VERSION}")/julia-${PUBLISHED_VERSION}-${name}.tar.gz"
    fi
    status="$(curl -sSL --retry 3 -o "${out}" -w '%{http_code}' "${url}")"
    # A branch cut in the last day may have no nightly yet; next week's run picks it up
    if [[ "${status}" == "404" && -n "${optional}" ]]; then
        echo "No nightly at ${url} yet; nothing to measure"
        return 2
    elif [[ "${status}" != "200" ]]; then
        echo "Could not download ${url} (HTTP ${status})" >&2
        return 1
    fi
    echo "downloaded ${url}"
}
