#!/usr/bin/env bash
# Build Julia with coverage enabled, run its tests in parallel, and upload the coverage:
# the Windows job of the scheduled coverage group (pipelines/scheduled/coverage/coverage.yml),
# which runs this under the build toolchain (utilities/windows/toolchain.sh).
set -euo pipefail

echo "--- Obtain coverage tokens"
if [[ "${BUILDKITE_PIPELINE_SLUG}" == "julia-pr" ]]; then
    echo "PR build: no coverage tokens; coverage uploads will be skipped"
else
    # shellcheck source=SCRIPTDIR/aws_oidc.sh
    source .buildkite/utilities/aws_oidc.sh tokens
    CODECOV_TOKEN="$(aws ssm get-parameter --with-decryption --name /julia-ci/tokens/codecov_token --query Parameter.Value --output text)"
    COVERALLS_TOKEN="$(aws ssm get-parameter --with-decryption --name /julia-ci/tokens/coveralls_token --query Parameter.Value --output text)"
    export CODECOV_TOKEN COVERALLS_TOKEN
fi

echo "--- Build Julia from source"
make -j"${JULIA_NUM_THREADS}" VERBOSE=1

echo "--- Print Julia version info"
./usr/bin/julia.exe --color=yes -e 'using InteractiveUtils; InteractiveUtils.versioninfo()'
./usr/bin/julia.exe --color=yes -e '@info "" Sys.CPU_THREADS'
# The LibGit2 tests need this
git config --global init.defaultBranch master

echo "--- Run Julia tests in parallel with code coverage enabled"
export JULIA_NUM_THREADS=1
export JULIA_WORKER_TIMEOUT=1200
./usr/bin/julia.exe --color=yes -e 'import Distributed; @info "" Distributed.worker_timeout()'
./usr/bin/julia.exe --color=yes .buildkite/pipelines/scheduled/coverage/run_tests_parallel.jl

echo "--- Move the lcov files into the ./lcov_files directory"
ls ./*.info
mkdir -p lcov_files
mv ./*.info lcov_files
ls lcov_files

echo "--- Upload lcov files"
tar -zcf lcov_files.tar.gz lcov_files/
buildkite-agent artifact upload lcov_files.tar.gz

echo "--- Process and upload coverage information"
if [[ -n "${CODECOV_TOKEN:-}" ]]; then
    ./usr/bin/julia.exe --color=yes .buildkite/pipelines/scheduled/coverage/upload_coverage.jl
else
    echo "No coverage tokens (PR build); skipping upload"
fi
