using Base: SHA1
using Base.BinaryPlatforms, JSON3, Sandbox, Pkg, JLLPrefixes
import Sandbox: SandboxConfig

include("../buildkite_api.jl")
include("../julia_checkout.jl")

struct BughuntBuildInfo
    platform::Platform
    env::Dict{String,String}

    rootfs_data::Dict{String,Any}

    # Which version of Julia was being built/tested
    julia_checkout::GitCheckout

    # Which version of julia-buildkite was used during the build
    julia_buildkite_checkout::GitCheckout

    # Any relevant artifacts that should be downloaded
    artifacts::Vector{BuildkiteArtifact}
end

function get_rootfs_data(env)
    plugins = JSON3.read(env["BUILDKITE_PLUGINS"])
    for plugin in plugins
        for (plugin_name, plugin_values) in plugin
            # If we find a `sandbox` plugin, extract that information here
            if occursin("staticfloat/sandbox-buildkite-plugin", String(plugin_name))
                rootfs_url = get(plugin_values, "rootfs_url", nothing)
                rootfs_treehash = get(plugin_values, "rootfs_treehash", nothing)
                rootfs_uid = get(plugin_values, "uid", Sandbox.getuid())
                rootfs_gid = get(plugin_values, "gid", Sandbox.getgid())

                if rootfs_url === nothing || rootfs_treehash === nothing
                    @error("Plugin values:", plugin_values)
                    throw(ArgumentError("Invalid sandbox plugin values!"))
                end

                return Dict{String,Any}(
                    "type" => "sandbox",
                    "url" => rootfs_url,
                    "treehash" => rootfs_treehash,
                    "uid" => rootfs_uid,
                    "gid" => rootfs_gid,
                )
            end
            if occursin("docker", String(plugin_name))
                image = get(plugin_values, "image", nothing)
                if image === nothing
                    @error("Plugin values:", plugin_values)
                    throw(ArgumentError("Invalid docker plugin values!"))
                end
                return Dict{String,Any}(
                    "type" => "docker",
                    "image" => image,
                )
            end
        end
    end
    return Dict{String,Any}()
end



# Ensure that the given step is something we can load up in Sandbox.jl,
# and extract the necessary information
function BughuntBuildInfo(job::BuildkiteJob; prefer_build_rootfs::Bool = true)
    # Collect the environment variables from this job
    env = get_buildkite_job_env(job)

    # We need to special-case the following variables, so that `build_julia.sh` and `test_julia.sh`
    # always have the environment variables that they expect from our `.arches` files:
    env["USE_RR"] = get(env, "USE_RR", "")
    env["MAKE_FLAGS"] = get(env, "MAKE_FLAGS", "")

    triplet = env["TRIPLET"]
    platform = parse(Platform, replace(triplet, "gnuassert" => "gnu", "gnuprofiling" => "gnu", "gnummtk" => "gnu"))
    if !Sandbox.natively_runnable(platform)
        throw(ArgumentError("Cannot natively run triplet '$(triplet)'!"))
    end

    step_key = env["BUILDKITE_STEP_KEY"]
    if !startswith(step_key, "test_") && !startswith(step_key, "build_")
        throw(ArgumentError("Cannot bughunt step with key '$(step_key)'; non build/test step!"))
    end

    # Collect the artifacts we should download (such as prebuilt versions of Julia)
    artifacts = BuildkiteArtifact[]

    # If this was a build within sandbox or docker, extract its information here.
    rootfs_data = get_rootfs_data(env)

    if startswith(step_key, "test_")
        # If we're a `test_*` step, search for the corresponding `build_` step,
        # and download its artifacts:
        build_job = find_sibling_buildkite_job(job, string("build_", triplet))
        append!(artifacts, get_buildkite_job_artifacts(build_job))

        # Also use the build's rootfs, since we want the ability to build Julia,
        # even if we're bughunting inside of a `test` job.  But allow this to be disabled.
        if prefer_build_rootfs
            rootfs_data = get_rootfs_data(get_buildkite_job_env(build_job))
        end
    end
    append!(artifacts, get_buildkite_job_artifacts(job))

    # If this is a PR, we'll have a pull request repo field, to track 3rd party PR repo urls
    # If it's not a PR, this will be empty, so we should just use the typical repo url
    julia_repo_url = env["BUILDKITE_PULL_REQUEST_REPO"]
    if isempty(julia_repo_url)
        julia_repo_url = env["BUILDKITE_REPO"]
    end

    # Collect the julia-buildkite repo information
    metadata = get_buildkite_job_metadata(job)
    julia_buildkite_repo_url = metadata["BUILDKITE_PLUGIN_EXTERNAL_BUILDKITE_REPO_URL"]
    julia_buildkite_commit = metadata["BUILDKITE_PLUGIN_EXTERNAL_BUILDKITE_VERSION"]
    julia_buildkite_checkout_dir = metadata["BUILDKITE_PLUGIN_EXTERNAL_BUILDKITE_FOLDER"]

    return BughuntBuildInfo(
        platform,
        Dict(string(k) => string(v) for (k, v) in env),
        rootfs_data,
        GitCheckout(julia_repo_url, env["BUILDKITE_COMMIT"], "."),
        GitCheckout(julia_buildkite_repo_url, julia_buildkite_commit, julia_buildkite_checkout_dir),
        artifacts,
    )
end

# Download `rr` for the given platform, into the given prefix
function download_rr(platform::Platform, prefix::String)
    if !isfile(joinpath(prefix, "bin", "rr"))
        jlls = [
            Pkg.PackageSpec(;name = "rr_jll", version = v"5.5.0+7"),
            # Manually work around bad artifact selection with MSAN tags
            Pkg.PackageSpec(;name = "Zlib_jll", version = v"1.2.11+18"),
        ]
        paths = collect_artifact_paths(jlls; platform)
        deploy_artifact_paths(prefix, paths)
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

            To build it, use the `build_julia` command.

            To run tests, use the `test_julia` command.  By default, the `test_julia` command will
            test a downloaded binary version of Julia if available, however if invoked from within
            the source checkout directory, it will use that build of Julia instead.
            """)
        end

        if "binary_tarball" in sections
            println(io, """
            In `/build/artifacts/` are all relevant buildkite artifacts, such as the Julia binaries used
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
            # If we're a sandbox build, collect the rootfs:
            if build_info.rootfs_data["type"] == "sandbox"
                Base.errormonitor(@async begin
                    treehash = Base.SHA1(build_info.rootfs_data["treehash"])
                    if !Pkg.Artifacts.artifact_exists(treehash)
                        Pkg.Artifacts.download_artifact(treehash, build_info.rootfs_data["url"], nothing; verbose=true)
                    end
                end)
            end

            # Collect buildkite artifacts into `prefix/artifacts`
            mkpath(joinpath(prefix, "artifacts"))
            for artifact in build_info.artifacts
                Base.errormonitor(@async begin
                    apath = download(artifact, joinpath(prefix, "artifacts"))

                    # If the artifact is a `.tar.xxx` file, try to auto-extract it:
                    if match(r"\.tar\.\w+$", basename(apath)) !== nothing
                        unpack_dir = joinpath(prefix, "artifacts", first(split(basename(apath), ".tar")))
                        mkpath(unpack_dir)
                        p = run(ignorestatus(`tar -C $(unpack_dir) -xf $(apath)`))
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
                checkout_prefix = joinpath(prefix, "julia.git")
                get_checkout(build_info.julia_checkout, checkout_prefix)
                generate_gdb_sourcedir_init(prefix, joinpath(checkout_prefix, build_info.julia_checkout.checkout_path))

                # Clone the julia-buildkite repository at the appropriate configuration SHA
                get_checkout(build_info.julia_buildkite_checkout, checkout_prefix)

                # Tell the README generator that we have a source checkout
                put!(readme_channel, "source_checkout")
            end)
        end
        close(readme_channel)
    end

    # Write out a README.md file with relevant sections
    generate_readme(prefix, readme_sections)
end

function SandboxConfig(build_info::BughuntBuildInfo, prefix::String)
    if build_info.rootfs_data["type"] != "sandbox"
        throw(ArgumentError("Invalid job rootfs; no sandbox rootfs data found!"))
    end

    # Add the bughunt commands to our PATH
    return SandboxConfig(
        Dict(
             "/" => Pkg.Artifacts.artifact_path(Base.SHA1(build_info.rootfs_data["treehash"])),
             # We have some debugging commands that we want on the PATH
             "/usr/local/libexec/bughunt_commands" => joinpath(@__DIR__, "commands"),
             # mount the `.bash_profile` into our home directory as well
             # We use `.bash_profile` here because we launch `bash` with `-l`
             "/home/juliaci/.bash_profile" => joinpath(@__DIR__, "bashrc.sh"),
        ),
        Dict(
             "/build" => prefix,
        ),
        Dict(
            "TERM" => "xterm-256color",
            # Provide all the environment variables that the build itself had
            "HOME" => "/home/juliaci",
            "USER" => "juliaci",
            "JULIA_CPU_THREADS" => string(Sys.CPU_THREADS),
            build_info.env...,
        );
        pwd="/build",
        uid=build_info.rootfs_data["uid"],
        gid=build_info.rootfs_data["gid"],
        stdin,
        stdout,
        stderr,
        verbose=true,
    )
end

struct DockerConfig
    image::String

    mounts::Dict{String,String}
    env::Dict{String,String}
end

function DockerConfig(build_info::BughuntBuildInfo, prefix::String)
    if build_info.rootfs_data["type"] != "docker"
        throw(ArgumentError("Invalid job rootfs; no docker rootfs data found!"))
    end

    # Docker on windows doesn't do file mounts, so we create a fake home directory here
    # with `.bash_profile` in it:
    fake_home = mktempdir()
    cp(joinpath(@__DIR__, "bashrc.sh"), joinpath(fake_home, ".bashrc"))

    # Build mount and env maps:
    return DockerConfig(
        build_info.rootfs_data["image"],

        # We have some debugging commands that we want on the PATH, store them
        # in the msys64 equivalent of `/usr/local/libexec/bughunt_commands`,
        # so that our `.bashrc` works everywhere...
        Dict(
            "C:\\msys64\\build" => prefix,
            "C:\\Users\\ContainerUser" => fake_home,
            "C:\\msys64\\usr\\local\\libexec\\bughunt_commands" => joinpath(@__DIR__, "commands"),
        ),
        Dict(
            "TERM" => "xterm-256color",
            "JULIA_CPU_THREADS" => string(Sys.CPU_THREADS),
            build_info.env...,
        );
    )
end

function Base.run(dc::DockerConfig, cmd::Cmd)
    docker_cmd_line = String[
        "docker",
        "run",

        # Give us an interactive session
        "-ti",

        # Start in `/build`
        "-wC:\\msys64\\build",
    ]

    # Build mount flags
    for (target, host) in dc.mounts
        push!(docker_cmd_line, "-v$(host):$(target)")
    end

    # Inherit environment (we'll use `setenv` to actually communicate them to docker)
    for (name, _) in dc.env
        push!(docker_cmd_line, "-e$(name)")
    end

    # Finally, pass the image and command
    push!(docker_cmd_line, dc.image)
    append!(docker_cmd_line, cmd.exec)
    docker_cmd = setenv(Cmd(docker_cmd_line), dc.env)

    if cmd.ignorestatus
        docker_cmd = ignorestatus(docker_cmd)
    end
    run(docker_cmd)
end
