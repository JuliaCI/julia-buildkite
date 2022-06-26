#!/bin/bash
set -eou pipefail
shopt -s nullglob

# This script reads in an `.arches` file, processes the columns and default value mappings
# within it, and outputs an environment block (e.g. a line of the form "X=a B= C=123") for
# each architecture defined within, to be used by other tools such as the brother script
# `arches_pipeline_upload.sh`, which uses those environment mappings to template pipeline
# YAML files that are being uploaded by `buildkite-agent pipeline upload`.

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
"${BASH}" "${SCRIPT_DIR}/arches_env.sh" "${ARCHES_FILE}" | while read env_map; do
    # 1. Export the environment mappings,
    eval "export ${env_map}"

    # 2. Enable automatic retries if and only if this is not a pull request build.
    if [[ "${BUILDKITE_PULL_REQUEST:?}" == "false" ]] ; then
        export AUTOMATIC_RETRY_LIMIT=1
    else
        export AUTOMATIC_RETRY_LIMIT=0
    fi

    # 3. Launch the yaml file
    buildkite-agent pipeline upload "${YAML_FILE}"
done
