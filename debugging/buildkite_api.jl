using HTTP, JSON3, Scratch, Dates
import HTTP: download
using Base: UUID, SHA1

const buildkite_token_path = joinpath(@__DIR__, "buildkite_token")
if !isfile(buildkite_token_path)
    error("You must decrypt the current repository to gain access to the buildkite token!")
end
const buildkite_token = strip(String(read(buildkite_token_path)))
const buildkite_api = "https://api.buildkite.com/v2"

function buildkite_headers()
    return ["Authorization" => "Bearer $(buildkite_token)"]
end
function buildkite_get(path::String; kwargs...)
    return HTTP.get("$(path)"; headers=buildkite_headers(), kwargs...)
end

struct BuildkiteJob
    organization_slug::String
    pipeline_slug::String
    build_number::Int
    id::UUID
end

function BuildkiteJob(url::String)
    m = match(r"(https://)?buildkite.com/(?<org_slug>[^/]+)/(?<pipeline_slug>[^/]+)/builds/(?<build_number>\d+)#(?<job_id>[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12})(/.*)?$", url)
    if m === nothing
        throw(ArgumentError("Invalid Buildkite Job URL!"))
    end
    return BuildkiteJob(
        m[:org_slug],
        m[:pipeline_slug],
        parse(Int, m[:build_number]),
        parse(UUID, m[:job_id]),
    )
end



struct BuildkiteArtifact
    url::String
    path::String
    hash::SHA1
end

function BuildkiteArtifact(d::AbstractDict)
    return BuildkiteArtifact(
        d["download_url"],
        d["filename"],
        SHA1(d["sha1sum"]),
    )
end

function download(ba::BuildkiteArtifact, prefix::String; downloads_dir::String = @get_scratch!("artifact-downloads"), update_period=Inf)
    cache_path = joinpath(downloads_dir, bytes2hex(ba.hash.bytes))
    if !isfile(cache_path)
        HTTP.download(ba.url, cache_path; headers=buildkite_headers(), update_period)
    end
    final_path = joinpath(prefix, ba.path)
    cp(cache_path, final_path)
    return final_path
end



function get_buildkite_job_env(job::BuildkiteJob)
    r = buildkite_get(joinpath(
        buildkite_api,
        "organizations",
        job.organization_slug,
        "pipelines",
        job.pipeline_slug,
        "builds",
        string(job.build_number),
        "jobs",
        string(job.id),
        "env",
    ))
    return JSON3.read(String(r.body)).env
end

function get_buildkite_job_artifacts(job::BuildkiteJob)
    r = buildkite_get(joinpath(
        buildkite_api,
        "organizations",
        job.organization_slug,
        "pipelines",
        job.pipeline_slug,
        "builds",
        string(job.build_number),
        "jobs",
        string(job.id),
        "artifacts",
    ))
    return BuildkiteArtifact.(JSON3.read(String(r.body)))
end

function find_sibling_buildkite_job(job::BuildkiteJob, sibling_key::String)
    # First, get all jobs for the job's build:
    r = buildkite_get(joinpath(
        buildkite_api,
        "organizations",
        job.organization_slug,
        "pipelines",
        job.pipeline_slug,
        "builds",
        string(job.build_number),
    ))
    jobs = JSON3.read(String(r.body)).jobs

    # Search through the list of jobs, looking for one with a matching step_key
    for j in jobs
        if j.step_key == sibling_key
            return BuildkiteJob(
                job.organization_slug,
                job.pipeline_slug,
                job.build_number,
                parse(UUID, j.id),
            )
        end
    end
    return nothing
end

function get_buildkite_pipeline_builds(organization_slug::String,
                                       pipeline_slug::String,
                                       branch::String;
                                       state::String = "finished",
                                       min_builds::Int = 50)
    page_idx = 1
    builds = []
    while length(builds) < min_builds
        @info("Requesting page $(page_idx)")
        # Fetch first list of builds
        builds_url = joinpath(
            buildkite_api,
            "organizations",
            organization_slug,
            "pipelines",
            pipeline_slug,
            "builds",
        )
        builds_params = [
            "branch" => branch,
            "state" => state,
            "page" => page_idx
        ]
        r = buildkite_get(builds_url; query=builds_params)
        append!(builds, JSON3.read(String(r.body)))
        page_idx += 1
    end
    return builds
end

# Given a bunch of builds (from `get_buildkite_pipeline_builds()`), parse out each
# individual job into a flat list of usable `Dict` objects.
function parse_buildkite_build_jobs(builds::Vector)
    jobs = Dict{String,Any}[]
    dt_format = dateformat"y-m-dTH:M:S.sZ"
    @info("Parsing $(length(builds)) builds...")
    for build in builds
        for job in build.jobs
            # Skip jobs without a step key
            if get(job, :step_key, nothing) === nothing
                continue
            end

            # Skip jobs that never ran or finished
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
                "log_url" => job.raw_log_url,
                "web_url" => job.web_url,
            ))
        end
    end
    return jobs
end

using DataFrames: DataFrame
DataFrame(v::Vector{<:Dict}) = DataFrame(Dict(k => [j[k] for j in v] for k in keys(v[1])))
