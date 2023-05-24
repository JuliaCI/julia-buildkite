#!/bin/bash

# This script does the following:
# 1. make -C deps USE_BINARYBUILDER=0
# 2. Make sure that the working directory is clean.
#
# The purpose of this script is to make sure that the from-source (non-BinaryBuilder)
# checksums are all up to date.

set -euo pipefail

make -C deps USE_BINARYBUILDER=0

source .buildkite/utilities/check_clean_wd.sh
