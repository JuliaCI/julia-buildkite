#!/usr/bin/env bash
set -eou pipefail
shopt -s nullglob

# This script reads in an `.arches` file and, for each architecture defined within, exports
# the environment mappings produced by the brother script `arches_env.sh`, interpolates the
# given pipeline YAML file against them with `interpolate_from_env.py`, and uploads the
# result with `buildkite-agent pipeline upload`.

ARCHES_FILE="${1:-}"
if [[ ! -f "${ARCHES_FILE}" ]] ; then
    echo "Arches file does not exist: '${ARCHES_FILE}'"
    exit 1
fi

YAML_FILE="${2:-}"
if [[ ! -f "${YAML_FILE}" ]] ; then
    echo "YAML file does not exist: '${YAML_FILE}'"
    exit 1
fi

SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
RENDERED_FILE="$(mktemp --suffix=.yml)"
trap 'rm -f "${RENDERED_FILE}"' EXIT
"${BASH}" "${SCRIPT_DIR}/arches_env.sh" "${ARCHES_FILE}" | while read -r env_map; do
    # Export the environment mappings, then interpolate and launch the yaml file
    eval "export ${env_map}"
    python3 "${SCRIPT_DIR}/interpolate_from_env.py" "${YAML_FILE}" > "${RENDERED_FILE}"
    buildkite-agent pipeline upload "${RENDERED_FILE}"
done
