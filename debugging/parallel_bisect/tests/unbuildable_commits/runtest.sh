#!/bin/bash

SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

# Build with 3 threads
julia -t3 --project "${SCRIPT_DIR}/../../parallel_bisect.jl" b75ddb787ff1838deb46b624ce8c8470aa75e85c e01aa58f3d02251cb0654ab477788cd70ac42626 "${SCRIPT_DIR}/test_download_exists.jl"

echo "Output should show that 84dee79d04526c270cb068ad4de298fc3a815e95 is the first bad commit"
