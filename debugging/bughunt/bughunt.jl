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
rootfs_type = get(build_info.rootfs_data, "type", "")
if rootfs_type == "sandbox"
    url = build_info.rootfs_data["url"]
    rootfs_summary = joinpath(basename(dirname(url)), basename(url))
elseif rootfs_type == "docker"
    rootfs_summary = build_info.rootfs_data["image"]
else
    rootfs_summary = "<none>"
end
@info("Collected build info",
    platform=triplet(build_info.platform),
    julia_commit=bytes2hex(build_info.julia_checkout.commit.bytes),
    buildkite_commit=bytes2hex(build_info.julia_buildkite_checkout.commit.bytes),
    num_artifacts=length(build_info.artifacts),
    rootfs=rootfs_summary,
)

# Download all the resources we need
prefix = mktempdir()
collect_resources(build_info, prefix)
@info("Collected build resources", prefix)

if Sys.islinux(build_info.platform)
    # Construct SandboxConfig off of our build info
    config = SandboxConfig(build_info, prefix)
    with_executor() do exe
        # Use `ignorestatus()` so that when we CTRL-D out of `bash`, Julia doesn't
        # slap us in the face with an error because `bash` exited with a nonzero exit code.
        # Use `-l` because otherwise bash starts up with a weird `PATH` that contains `.`
        run(exe, config, ignorestatus(`/bin/bash -l`))
    end
elseif Sys.iswindows(build_info.platform)
    # Launch job within windows docker container
    config = DockerConfig(build_info, prefix)
    run(config, ignorestatus(`bash`))
end
