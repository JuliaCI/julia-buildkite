using Dates, DataFrames
using Base: UUID, SHA1

include("../buildkite_api.jl")

# Get the last N builds for the given branch
branch = get(ARGS, 1, "master")
min_builds = parse(Int, get(ARGS, 2, "1000"))
builds = get_buildkite_pipeline_builds("julialang", "julia-master", branch; min_builds)

# Collect all jobs
jobs = parse_buildkite_build_jobs(builds)
df = DataFrame(jobs)
