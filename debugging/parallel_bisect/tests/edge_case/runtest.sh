#!/bin/bash

SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

# Build with 5 threads
julia -t5 --project "${SCRIPT_DIR}/../../parallel_bisect.jl" 95e0da1421efa35bbf5092ac065050fdbe34aaea e3d366f1966595ba737220df49e220610823b331 "${SCRIPT_DIR}/linear_solve_example.jl"

echo "Output should show that e3d366f1966595ba737220df49e220610823b331 is the first bad commit"
