#!/usr/bin/env bash
set -eou pipefail

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

enforce_sanitized() {
    for value in "$@"; do
        if ! [[ "${value}" =~ ^[a-zA-Z0-9_\.[:space:]=,-]*$ ]]; then
            echo "Arches file '${ARCHES_FILE}' contains value '${value}' with non-alphanumeric characters; refusing to parse!" >&2
            exit 1
        fi
    done
}


# Determine variable names from the header of the .arches file:
readarray -d ' ' -s 1 -t var_names < <(head -1 "${ARCHES_FILE}" | tr -s ' ')

# Determine any embedded defaults
declare -A defaults_map
readarray -t default_mapping_lines < <(grep "^#default" "${ARCHES_FILE}" | tr -s ' ')
for idx in "${!default_mapping_lines[@]}"; do
    key="$(  cut -d' ' -f2 <<<"${default_mapping_lines[${idx}]}" | xargs)"
    value="$(cut -d' ' -f3 <<<"${default_mapping_lines[${idx}]}" | xargs)"
    enforce_sanitized "${key}" "${value}"
    defaults_map["${key}"]="${value}"
done

while read -r line; do
    # Remove whitespace from the beginning and end of each line
    line="$(tr -s ' ' <<<"${line}")"

    # Skip any line that begins with the `#` character
    if [[ $line == \#* ]]; then
        continue
    fi

    # Skip any empty line
    if [[ $line == "" ]]; then
        continue
    fi

    # Skip any line that contains suspicious characters, to prevent shell escaping bugs
    enforce_sanitized "${line}"

    # Convert line to array
    readarray -d ' ' -t line_array <<<"${line}"

    # Panic if we don't have the same number of items as our column names:
    if [[ "${#line_array[@]}" != "${#var_names[@]}" ]]; then
        echo "ERROR: The following line does not contain ${#var_names[@]} columns as we would expect from the header of ${ARCHES_FILE}" >&2
        echo "${line}"
        exit 1
    fi

    # Loop over columns, bind values to their column name
    for idx in "${!var_names[@]}"; do
        # Get the name and value
        name="$(xargs <<<"${var_names[${idx}]}")"
        value="$(xargs <<<"${line_array[${idx}]}")"

        # Apply default values to our special `.` token
        if [[ "${value}" == "." ]]; then
            value="${defaults_map[${name}]:-}"
        fi

        echo -n "${name}=\"${value}\" "
    done
    echo
done <"${ARCHES_FILE}"
