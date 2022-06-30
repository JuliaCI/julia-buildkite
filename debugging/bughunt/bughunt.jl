# Bring in our buildkite helpers and common code
include("common.jl")

if length(ARGS) < 1
    println("Usage: $(basename(@__FILE__)) <buildkite url>")
    exit(1)
end

# Get the job id
job = BuildkiteJob(ARGS[1])
@info("Found Job",
    organization=job.organization_slug,
    pipeline=job.pipeline_slug,
    build=job.build_number,
    id=string(job.id),
)

# Construct the build_info from this job
build_info = BughuntBuildInfo(job)
@info("Collected build info",
    platform=triplet(build_info.platform),
    julia_commit=bytes2hex(build_info.julia_commit.bytes),
    num_artifacts=length(build_info.artifacts),
)

# Download all the resources we need
prefix = mktempdir()
collect_resources(build_info, prefix)
@info("Collected build resources", prefix)

# Construct SandboxConfig off of our build info
config = SandboxConfig(build_info, prefix)
with_executor() do exe
    run(exe, config, `/bin/bash -l`)
end
