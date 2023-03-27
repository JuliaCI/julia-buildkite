using Scratch, ProgressMeter, DataFrames
using Base: UUID, SHA1

include("../buildkite_api.jl")

# Get the last N builds for the given branch
builds = get_buildkite_pipeline_builds("julialang", "julia-master", "master"; min_builds=100)

# Collect all jobs
jobs = parse_buildkite_build_jobs(builds)

# Collect all build lots for these jobs, caching in a scratch space:
job_log_path(job::Dict) = joinpath(@get_scratch!(string("job_logs-", job["uuid"])), "log.txt")
function get_job_log(job::Dict)
    if !haskey(job, "log_url") || !haskey(job, "uuid")
        return nothing
    end
    log_path = job_log_path(job)
    if !isfile(log_path)
        open(log_path, write=true) do log_io
            HTTP.get(
                job["log_url"];
                response_stream=log_io,
                headers=buildkite_headers(),
            )
        end
    end
    return log_path
end
read_log(job::Dict) = String(read(job_log_path(job)))

function get_logs_task(c::Channel)
    while isopen(c)
        local j
        try
            j = take!(c)
        catch e
            if isa(e, InvalidStateException) && e.state == :closed
                break
            end
            rethrow(e)
        end
        get_job_log(j)
    end
end

# Spin up a task pool to download logs
@sync begin
    @info("Downloading $(length(jobs)) logs...")
    job_channel = Channel()
    num_tasks = 10
    for tidx in 1:num_tasks
        @async get_logs_task(job_channel)
    end

    # Feed the tasks
    p = Progress(length(jobs); barglyphs=BarGlyphs("[=> ]"))
    for job in jobs
        put!(job_channel, job)
        next!(p)
    end
    close(job_channel)
end

# Next, start grepping through the logs:
function grep_logs(jobs::Vector, pattern::String)
    matching_jobs = Dict{String,Any}[]
    for job in jobs
        log_contents = read_log(job)
        if occursin(pattern, log_contents)
            push!(matching_jobs, job)
            @info("Found matching log!", url=job["web_url"])
        end
    end
    return matching_jobs
end

if !isempty(ARGS)
    matching_jobs = grep_logs(jobs, ARGS[1])
    if isempty(matching_jobs)
        @warn("No matching jobs!")
    else
        df = DataFrame(matching_jobs)
    end
end
