#!/bin/bash

set -euo pipefail

# Get the `.buildkite/utilities/docs` folder path
DOCS_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

echo "--- Download built docs"
buildkite-agent artifact download --step "doctest" "julia-*-htmldocs.tar.gz"

echo "--- Deploy docs"
export DOCUMENTER_KEY="$(cat .buildkite/secrets/ssh_docs_deploy)"
echo "Do something here!"
