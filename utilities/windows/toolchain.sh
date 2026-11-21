#!/usr/bin/env bash
# Usage: toolchain.sh --root DIR CMD [ARGS...]
#
# Run CMD in the Windows toolchain tree at DIR, a `package_windows.<arch>` image from
# rootfs-images as install_toolchain.jl installs it, the way the
# `juliapackaging/package-windows-*` containers used to run build steps. CMD runs under the
# tree's own MSYS2 bash, not a login shell, with:
#  - PATH: the tree's PATH_PREPEND entries (from DIR\toolchain.env), then the inherited PATH
#    without Git for Windows' own MSYS directories, so that a tool missing from the toolchain
#    fails instead of resolving to Git's;
#  - MSYSTEM and MSYS2_PATH_TYPE from toolchain.env;
#  - HOME, TMP, TEMP and TMPDIR outside the tree (the user profile and its temp directory),
#    so that the tree is never written to (it is an artifact, which Pkg verifies by hash).
# The exit code is CMD's.
#
# The agent's shell is Git for Windows bash, whose MSYS runtime is a different
# `msys-2.0.dll` from the toolchain's. When the toolchain's bash has a Git bash process
# anywhere up its process chain, it inherits only a handful of variables (no COMSPEC, TEMP
# or BUILDKITE_*), so it is started from PowerShell, and this script runs no tool of the
# toolchain itself. The values are handed over in Windows form, which Git's runtime passes
# through unchanged.
#
# The tree layout and toolchain.env are specified by rootfs-images (src/windows_rules.jl),
# whose test_rootfs.jl does the same as this script for local use.
set -euo pipefail

usage() {
    echo "usage: toolchain.sh --root DIR CMD [ARGS...]" >&2
    exit 2
}

die() {
    echo "toolchain.sh: $*" >&2
    exit 1
}

[[ $# -ge 3 && "$1" == "--root" && -n "$2" ]] || usage
root="$2"
shift 2

# Absolute, so that it still holds after CMD changes directory
root_win="$(cygpath -aw "${root}")"
root_win="${root_win%\\}"
root_unix="$(cygpath -u "${root_win}\\")"
env_file="${root_unix%/}/toolchain.env"
if [[ ! -f "${env_file}" ]]; then
    die "no toolchain at ${root_win}\\ (${env_file} is missing)"
fi

# KEY=VALUE lines (CRLF tolerated), as rootfs-images writes them (src/windows_rules.jl).
# The tree is verified by its hash, so the file is not checked beyond what is used here.
declare -A toolchain_env=()
while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%$'\r'}"
    if [[ "${line}" == *=* ]]; then
        toolchain_env["${line%%=*}"]="${line#*=}"
    fi
done < "${env_file}"
for key in PATH_PREPEND MSYSTEM MSYS2_PATH_TYPE; do
    [[ -n "${toolchain_env[${key}]:-}" ]] || die "${env_file}: no ${key}"
done

path_entries=()
IFS=';' read -ra prepend <<<"${toolchain_env[PATH_PREPEND]}"
for entry in "${prepend[@]}"; do
    path_entries+=( "${root_win}\\${entry}" )
done

# Git's own directories, in the form they take in a native process's PATH: /usr/bin (also
# /bin), /usr/local/bin, the Perl directories below /usr/bin, /mingw64/bin. Git's cmd\
# directory (git.exe, outside these) stays.
git_usr="$(cygpath -w /usr)"
git_mingw64="$(cygpath -w /mingw64)"
lower() { tr '[:upper:]' '[:lower:]' <<<"$1"; }
git_usr_lc="$(lower "${git_usr}")"
git_mingw64_lc="$(lower "${git_mingw64}")"
IFS=';' read -ra inherited <<<"$(cygpath -w -p "${PATH}")"
for entry in "${inherited[@]}"; do
    [[ -n "${entry}" ]] || continue
    entry_lc="$(lower "${entry%\\}")"
    if [[ "${entry_lc}" == "${git_usr_lc}" || "${entry_lc}" == "${git_usr_lc}\\"* ||
          "${entry_lc}" == "${git_mingw64_lc}" || "${entry_lc}" == "${git_mingw64_lc}\\"* ]]; then
        continue
    fi
    path_entries+=( "${entry}" )
done
toolchain_path="$(IFS=';'; echo "${path_entries[*]}")"

if [[ -f "${root_unix%/}/toolchain.json" ]]; then
    echo "toolchain.sh: using the toolchain at ${root_win}\\:"
    grep -E '^  "(image|arch|tag|source)":' "${root_unix%/}/toolchain.json" || true
fi

# The command line goes through a file, so that no argument has to survive PowerShell's
# quoting; %q quotes for bash, and both bashes read it the same way.
cmdfile="$(mktemp --suffix=.sh)"
trap 'rm -f "${cmdfile}"' EXIT
printf 'exec' > "${cmdfile}"
printf ' %q' "$@" >> "${cmdfile}"
printf '\n' >> "${cmdfile}"

temp_win="$(cygpath -w "${TEMP:-${TMP:-/tmp}}")"
status=0
# shellcheck disable=SC2016 # PowerShell code, expanded by PowerShell
TOOLCHAIN_BASH="${root_win}\\msys64\\usr\\bin\\bash.exe" \
TOOLCHAIN_CMDFILE="$(cygpath -w "${cmdfile}")" \
TOOLCHAIN_PATH="${toolchain_path}" \
TOOLCHAIN_MSYSTEM="${toolchain_env[MSYSTEM]}" \
TOOLCHAIN_MSYS2_PATH_TYPE="${toolchain_env[MSYS2_PATH_TYPE]}" \
TOOLCHAIN_HOME="$(cygpath -w "${USERPROFILE:-${HOME}}")" \
TOOLCHAIN_TEMP="${temp_win}" \
    "$(cygpath -u "${SYSTEMROOT:-C:\\Windows}")/System32/WindowsPowerShell/v1.0/powershell.exe" \
    -NoProfile -NonInteractive -Command '
        $ErrorActionPreference = "Stop"
        $bash = $env:TOOLCHAIN_BASH; $cmdfile = $env:TOOLCHAIN_CMDFILE
        $env:PATH = $env:TOOLCHAIN_PATH
        $env:MSYSTEM = $env:TOOLCHAIN_MSYSTEM
        $env:MSYS2_PATH_TYPE = $env:TOOLCHAIN_MSYS2_PATH_TYPE
        $env:HOME = $env:TOOLCHAIN_HOME
        $env:TMP = $env:TOOLCHAIN_TEMP; $env:TEMP = $env:TOOLCHAIN_TEMP; $env:TMPDIR = $env:TOOLCHAIN_TEMP
        Get-ChildItem env:TOOLCHAIN_* | Remove-Item
        & $bash $cmdfile
        exit $LASTEXITCODE
    ' || status=$?
exit "${status}"
