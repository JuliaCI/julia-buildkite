using Base: SHA1
using Base.BinaryPlatforms, JSON3, Sandbox, Pkg, JLLPrefixes
import Sandbox: SandboxConfig

include("../buildkite_api.jl")
include("../julia_checkout.jl")

struct BughuntBuildInfo
    platform::Platform

    rootfs_url::String
    rootfs_treehash::SHA1
    rootfs_uid::Int
    rootfs_gid::Int

    # Which version of Julia was being built/tested
    julia_commit::SHA1

    # Any relevant artifacts that should be downloaded
    artifacts::Vector{BuildkiteArtifact}
end

# Ensure that the given step is something we can load up in Sandbox.jl,
# and extract the necessary information
function BughuntBuildInfo(job::BuildkiteJob)
    # Collect the environment variables from this job
    env = get_buildkite_job_env(job)

    triplet = env["TRIPLET"]
    platform = parse(Platform, replace(triplet, "gnuassert" => "gnu"))
    if !Sandbox.natively_runnable(platform)
        throw(ArgumentError("Cannot natively run triplet '$(triplet)'!"))
    end

    step_key = env["BUILDKITE_STEP_KEY"]
    if !startswith(step_key, "test_") && !startswith(step_key, "build_")
        throw(ArgumentError("Cannot bughunt step with key '$(step_key)'; non build/test step!"))
    end

    # Collect the artifacts we should download (such as prebuilt versions of Julia)
    artifacts = BuildkiteArtifact[]
    if startswith(step_key, "test_")
        # If we're a `test_*` step, search for the corresponding `build_` step,
        # and download its artifacts:
        build_job = find_sibling_buildkite_job(job, string("build_", triplet))
        append!(artifacts, get_buildkite_job_artifacts(build_job))
    end
    append!(artifacts, get_buildkite_job_artifacts(job))

    plugins = JSON3.read(env["BUILDKITE_PLUGINS"])
    rootfs_url = nothing
    rootfs_treehash = nothing
    rootfs_uid = Sandbox.getuid()
    rootfs_gid = Sandbox.getgid()
    for plugin in plugins
        for (plugin_name, plugin_values) in plugin
            if occursin("staticfloat/sandbox-buildkite-plugin", String(plugin_name))
                rootfs_url = get(plugin_values, "rootfs_url", rootfs_url)
                rootfs_treehash = get(plugin_values, "rootfs_treehash", rootfs_treehash)
                rootfs_uid = get(plugin_values, "uid", rootfs_uid)
                rootfs_gid = get(plugin_values, "gid", rootfs_gid)
            end
        end
    end
    if rootfs_url === nothing || rootfs_treehash === nothing
        throw(ArgumentError("Cannot bughunt step without sandbox plugin!"))
    end


    return BughuntBuildInfo(
        platform,
        rootfs_url,
        SHA1(rootfs_treehash),
        rootfs_uid,
        rootfs_gid,
        SHA1(env["BUILDKITE_COMMIT"]),
        artifacts,
    )
end

# Download `rr` for the given platform, into the given prefix
function download_rr(platform::Platform, prefix::String)
    if !isfile(joinpath(prefix, "bin", "rr"))
        paths = collect_artifact_paths(["rr_jll"]; platform)
        copy_artifact_paths(prefix, paths)
    end
end

function generate_debug_script(prefix::AbstractString, script_name::String, vars::Dict = Dict())
    script_path = joinpath(prefix, string("debug-", script_name))
    script_content = String(read(joinpath(@__DIR__, script_name)))
    for (name, value) in vars
        script_content = replace(script_content, "\$($(name))" => value)
    end
    open(script_path, write=true) do io
        write(io, script_content)
    end
    chmod(script_path, 0o755)
    return script_path
end

function collect_dirs(root)
    dirs = String[root]
    for (r, ds, fs) in walkdir(root)
        for d in ds
            push!(dirs, joinpath(r, d))
        end
    end
    return dirs
end

function generate_gdb_sourcedir_init(prefix::AbstractString, julia_checkout_dir::String)
    julia_src_dirs = Set{String}()
    # Collect all directories in `src` and `base` to add onto `gdb`'s source search path
    push!.(Ref(julia_src_dirs), collect_dirs(joinpath(julia_checkout_dir, "src")))
    push!.(Ref(julia_src_dirs), collect_dirs(joinpath(julia_checkout_dir, "base")))
    push!.(Ref(julia_src_dirs), collect_dirs(joinpath(julia_checkout_dir, "cli")))
    julia_src_dirs = sort(collect(julia_src_dirs))

    # Adapt to the paths in the sandbox
    julia_src_dirs = replace.(julia_src_dirs, julia_checkout_dir => "/build/julia.git")

    open(joinpath(prefix, ".gdbinit.src"), write=true) do io
        for d in julia_src_dirs
            println(io, "dir $(d)")
        end
    end
end

function generate_readme(prefix::String, sections::Set{String})
    open(joinpath(prefix, "README.md"), write=true) do io
        println(io, """
        # bughunt environment

        This environment provides a convenient way to hunt down issues that appear on JuliaLang CI.
        You are currently operating within a Sandbox setup with the same configuration as was used
        on CI to either build or test Julia.
        """)

        if "source_checkout" in sections
            println(io, """
            In `/build/julia.git` is a Julia source checkout of the appropriate commit.
            """)
        end

        if "binary_tarball" in sections
            println(io, """
            In `/build/artifacts/` are all relevent buildkite artifacts, such as the Julia binaries used
            when running Julia tests, core dumps, rr traces, etc...
            """)
        end

        if "core_dump" in sections
            println(io, """
            Core dumps have been downloaded to `/build/artifacts/` and helper debug scripts have been placed
            in the artifact directory to ease setting up `gdb` properly.
            """)
        end

        if "rr_trace" in sections
            println(io, """
            `rr` traces have been downloaded to `/build/artifacts/` and helper debug scripts have been placed
            in the artifact directory to ease setting up `rr` properly.
            """)
        end
    end
end

function collect_resources(build_info::BughuntBuildInfo, prefix::String;
                           downloads_dir = @get_scratch!("downloads-cache"))
    # We'll collect the sections we need to generate in a readme here.
    readme_sections = Set{String}()
    @sync begin
        readme_channel = Channel(10)
        # Collect all readme sections and deduplicate them into a Set
        Base.errormonitor(@async begin
            while isopen(readme_channel)
                try
                    push!(readme_sections, take!(readme_channel))
                catch
                end
            end
        end)

        @sync begin
            # Collect rootfs artifact
            Base.errormonitor(@async begin
                if !Pkg.Artifacts.artifact_exists(build_info.rootfs_treehash)
                    Pkg.Artifacts.download_artifact(build_info.rootfs_treehash, build_info.rootfs_url, nothing; verbose=true)
                end
            end)

            # Collect buildkite artifacts into `prefix/artifacts`
            mkpath(joinpath(prefix, "artifacts"))
            for artifact in build_info.artifacts
                Base.errormonitor(@async begin
                    apath = download(artifact, joinpath(prefix, "artifacts"))

                    # If the artifact is a `.tar.xxx` file, try to auto-extract it:
                    if match(r"\.tar\.\w+$", basename(apath)) !== nothing
                        unpack_dir = joinpath(prefix, "artifacts", first(split(basename(apath), ".tar")))
                        mkpath(unpack_dir)
                        p = run(ignorestatus(`tar -I unzstd -C $(unpack_dir) -xf $(apath)`))
                        if success(p)
                            # If the artifact is a coredump, generate a core launch script:
                            if match(r"\.core\.tar\.\w+$", basename(apath)) !== nothing
                                corefile = filter(f -> endswith(f, ".core"), split(String(read(`tar -tf $(apath)`))))
                                if length(corefile) != 1
                                    @warn("Unable to automatically determine corefile path in $(apath)", corefile)
                                end
                                generate_debug_script(unpack_dir, "core_dump.sh", Dict("corefile" => only(corefile)))
                                @info("Unpacked coredump and generated helper script", name=basename(unpack_dir))
                                put!(readme_channel, "core_dump")
                            end
                            # If the artifact is an rr trace, download rr and generate an rr launch script
                            if match(r"^rr-.*\.tar\.\w+$", basename(apath)) !== nothing
                                download_rr(build_info.platform, joinpath(prefix, "artifacts", ".rr_jll"))
                                generate_debug_script(unpack_dir, "rr_trace.sh")
                                @info("Unpacked rr trace and generated helper script", name=basename(unpack_dir))
                                put!(readme_channel, "rr_trace")
                            end
                            put!(readme_channel, "binary_tarball")
                            rm(apath)
                        end
                    end
                end)
            end

            # Collect julia checkout
            Base.errormonitor(@async begin
                julia_checkout_dir = joinpath(prefix, "julia.git")
                get_julia_checkout(build_info.julia_commit, julia_checkout_dir)
                generate_gdb_sourcedir_init(prefix, julia_checkout_dir)
                put!(readme_channel, "source_checkout")
            end)
        end
        close(readme_channel)
    end

    # Write out a README.md file with relevant sections
    generate_readme(prefix, readme_sections)
end


function SandboxConfig(build_info::BughuntBuildInfo, prefix::String)
    ro_maps = Dict("/" => Pkg.Artifacts.artifact_path(build_info.rootfs_treehash))

    return SandboxConfig(
        ro_maps,
        Dict("/build" => prefix),
        Dict(
            "TERM" => "xterm",
            "HOME" => "/home/juliaci",
            "USER" => "juliaci",
        );
        pwd="/build",
        uid=build_info.rootfs_uid,
        gid=build_info.rootfs_gid,
        stdin,
        stdout,
        stderr,
        verbose=true,
    )
end
