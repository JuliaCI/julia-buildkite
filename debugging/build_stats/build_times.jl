using Dates, DataFrames
using Base: UUID, SHA1

include("../buildkite_api.jl")

# Get the last N builds for the given branch
branch = get(ARGS, 1, "master")
builds = get_buildkite_pipeline_builds("julialang", "julia-master", branch; min_builds=1000)

# Collect all jobs
@info("Parsing $(length(builds)) builds...")
jobs = Dict[]
dt_format = dateformat"y-m-dTH:M:S.sZ"
for build in builds
    for job in build.jobs
        # Skip jobs without a step key
        if get(job, :step_key, nothing) === nothing
            continue
        end

        # Skip jobs that never ran
        if get(job, :started_at, nothing) === nothing || get(job, :finished_at, nothing) === nothing
            continue
        end

        push!(jobs, Dict(
            "uuid" => UUID(job.id),
            "key" => job.step_key,
            "date" => DateTime(build.created_at, dt_format),
            "elapsed" => (DateTime(job.finished_at, dt_format) - DateTime(job.started_at, dt_format)).value/1000,
            "agent" => job.agent.name,
            "state" => job.state,
            "commit" => build.commit,
        ))
    end
end

# Invert our datastructure and turn into a DataFrame:
df = DataFrame(Dict(k => [j[k] for j in jobs] for k in keys(jobs[1])))
