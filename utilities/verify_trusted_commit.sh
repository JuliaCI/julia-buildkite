#!/usr/bin/env bash
# Defense-in-depth guard for the trusted publish pipeline.
#
# Before any signing/promotion happens, verify that the commit we are about
# to publish is genuinely part of the canonical upstream repository on a
# protected ref (master, a release-* branch, or a v* tag). This makes the
# publish role safe even if the publish pipeline were ever misconfigured to
# accept a pull-request-originated or attacker-triggered build: such a build
# carries a commit that is NOT reachable from any protected upstream ref, so
# this check aborts before the privileged role is assumed.
#
# The real trust boundary is that the julia-publish pipeline does not build
# pull requests at all (see ops/README.md); this is the backstop.
#
# Honors BUILDKITE_COMMIT and (for julia-buildkite's own e2e publish test)
# the UPSTREAM_URL override.
set -euo pipefail

CANONICAL_URL="${CANONICAL_URL:-https://github.com/JuliaLang/julia.git}"
COMMIT="${BUILDKITE_COMMIT:?BUILDKITE_COMMIT must be set}"

if ! [[ "${COMMIT}" =~ ^[0-9a-f]{40}$ ]]; then
    echo "ERROR: BUILDKITE_COMMIT='${COMMIT}' is not a full 40-char sha" >&2
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
export GIT_DIR="${WORK}/repo.git"
git init -q --bare "${GIT_DIR}"

echo "--- Verify ${COMMIT:0:12} is on a protected ref of ${CANONICAL_URL}"

# Fetch only the protected refs from the canonical upstream. A commit that
# only exists on a fork / PR branch will not be reachable from any of these.
git fetch -q --no-tags "${CANONICAL_URL}" \
    "refs/heads/master:refs/remotes/up/master" \
    "refs/heads/release-*:refs/remotes/up/release/*" || true
# Tags separately (release builds), into refs/tags/
git fetch -q "${CANONICAL_URL}" "refs/tags/v*:refs/tags/v*" || true

# Make sure we actually have the commit object locally (fetch it directly if
# the ref fetch above did not bring it in, e.g. very fresh master tip).
if ! git cat-file -e "${COMMIT}^{commit}" 2>/dev/null; then
    git fetch -q "${CANONICAL_URL}" "${COMMIT}" 2>/dev/null || true
fi

is_reachable() {
    # True if ${COMMIT} is an ancestor of, or equal to, ref $1.
    git merge-base --is-ancestor "${COMMIT}" "$1" 2>/dev/null
}

MATCH=""
# master
if git rev-parse -q --verify refs/remotes/up/master >/dev/null && is_reachable refs/remotes/up/master; then
    MATCH="refs/heads/master"
fi
# release-* branches
if [[ -z "${MATCH}" ]]; then
    while IFS= read -r ref; do
        [[ -n "${ref}" ]] || continue
        if is_reachable "${ref}"; then
            MATCH="${ref#refs/remotes/up/}"
            break
        fi
    done < <(git for-each-ref --format='%(refname)' 'refs/remotes/up/release/*')
fi
# v* tags (exact tag commit)
if [[ -z "${MATCH}" ]]; then
    while IFS= read -r ref; do
        [[ -n "${ref}" ]] || continue
        if [[ "$(git rev-parse "${ref}^{commit}")" == "${COMMIT}" ]]; then
            MATCH="${ref}"
            break
        fi
    done < <(git for-each-ref --format='%(refname)' 'refs/tags/v*')
fi

if [[ -z "${MATCH}" ]]; then
    echo "ERROR: refusing to publish: commit ${COMMIT} is not reachable from any" >&2
    echo "       protected ref (master / release-* / v*) of ${CANONICAL_URL}." >&2
    echo "       This build is not a legitimate release build." >&2
    exit 1
fi

echo "OK: ${COMMIT:0:12} is on protected ref ${MATCH}"
