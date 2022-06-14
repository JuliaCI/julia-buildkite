import Dates, Pkg, Tar
include(joinpath(dirname(@__DIR__), "proc_utils.jl"))

function get_bool_from_env(name::AbstractString, default_value::Bool)
    value = get(ENV, name, "$(default_value)") |> strip |> lowercase
    result = parse(Bool, value)::Bool
    return result
end

const is_buildkite         = get_bool_from_env("BUILDKITE",                  false)
const always_save_rr_trace = get_bool_from_env("JULIA_ALWAYS_SAVE_RR_TRACE", false)

function get_from_env(name::AbstractString)
    if is_buildkite
        value = ENV[name]
    else
        value = get(ENV, name, "")
    end
    result = convert(String, strip(value))::String
    return result
end

if length(ARGS) < 1
    throw(ErrorException("Usage: julia $(basename(@__FILE__)) [command...]"))
end

@info "We will run the command under rr"

const build_number                      = get_from_env("BUILDKITE_BUILD_NUMBER")
const job_name                          = get_from_env("BUILDKITE_STEP_KEY")
const commit_full                       = get_from_env("BUILDKITE_COMMIT")
const commit_short                      = first(commit_full, 10)
const JULIA_TEST_NUM_CORES              = get(ENV,  "JULIA_TEST_NUM_CORES", "$(Sys.CPU_THREADS)")
const julia_test_num_cores_int          = parse(Int, JULIA_TEST_NUM_CORES)
const num_cores = min(
    # We'll limit `rr` to a maximum of 16 cores.
    16,
    Sys.CPU_THREADS,
    julia_test_num_cores_int + 1,
)
ENV["JULIA_RRCAPTURE_NUM_CORES"] = "$(num_cores)"

@info(
    "",
    is_buildkite,
    build_number,
    job_name,
    commit_full,
    commit_short,
    num_cores,
)

if is_buildkite
    @info(
        "Buildkite-specific details:",
        is_buildkite,
    )
end

const dumps_dir       = joinpath(pwd(), "dumps")
const temp_parent_dir = joinpath(pwd(), "temp_for_rr")

mkpath(dumps_dir)
mkpath(temp_parent_dir)

proc = nothing

mktempdir(temp_parent_dir) do dir
    Pkg.activate(dir)
    # Note: Pkg does not currently support build numbers. Therefore, if you provide a
    # version number, Pkg will always install the latest build number. If you need to
    # install a build number that is not the latest build number, you must provide the
    # commit instead of providing the version number.
    Pkg.add(Pkg.PackageSpec(name = "rr_jll", version = "5.5.0", uuid = "e86bdf43-55f7-5ea2-9fd0-e7daa2c0f2b4"))
    Pkg.add(Pkg.PackageSpec(name = "Zstd_jll", version = "1.5.0", uuid = "3161d3a3-bdf6-5164-811a-617609db77b4"))
    rr_jll = Base.require(Base.PkgId(Base.UUID("e86bdf43-55f7-5ea2-9fd0-e7daa2c0f2b4"), "rr_jll"))
    zstd_jll = Base.require(Base.PkgId(Base.UUID("3161d3a3-bdf6-5164-811a-617609db77b4"), "Zstd_jll"))
    rr(func) = Base.invokelatest(rr_jll.rr, func; adjust_LIBPATH=false)

    rr() do rr_path
        capture_script_path = joinpath(dir, "capture_output.sh")
        open(capture_script_path, "w") do io
            write(io, """
            #!/bin/bash

            $(rr_path) record --nested=detach "\$@" > >(tee -a $(dir)/stdout.log) 2> >(tee -a $(dir)/stderr.log >&2)
            """)
        end
        chmod(capture_script_path, 0o755)
        timeout_script_path = joinpath(dirname(@__DIR__), "timeout.jl")

        new_env = copy(ENV)
        new_env["_RR_TRACE_DIR"] = joinpath(dir, "rr_traces")
        new_env["RR_LOG"]          = "all:debug"
        new_env["RR_UNDER_RR_LOG"] = "all:debug"
        new_env["RR_LOG_BUFFER"] = "100000"
        new_env["JULIA_RR"] = capture_script_path
        t_start = time()

        global proc = run(setenv(`$(Base.julia_cmd()) $(timeout_script_path) $(rr_path) record --num-cores=$(num_cores) $ARGS`, new_env))
        # Wait for `rr` to finish, either through naturally finishing its run, or `SIGTERM`.
        process_failed = !success(proc)

        if process_failed || always_save_rr_trace || is_buildkite
            println(stderr, "`rr` returned $(proc.exitcode), packing and uploading traces...")

            if !isdir(joinpath(dir, "rr_traces"))
                println(stderr, "No `rr_traces` directory!  Did `rr` itself fail?")
                exit(1)
            end

            # Clean up non-traces
            rm(joinpath(dir, "rr_traces", "latest-trace"))
            rm(joinpath(dir, "rr_traces", "cpu_lock"))

            # Create a directory for the pack files to go
            pack_dir = joinpath(dir, "pack")
            mkdir(pack_dir)

            # Pack all traces
            trace_dirs = [joinpath(dir, "rr_traces", f) for f in readdir(joinpath(dir, "rr_traces"))]
            filter!(isdir, trace_dirs)
            run(ignorestatus(`$(rr_path) pack --pack-dir=$pack_dir $(trace_dirs)`))

            # Tar it up
            mkpath(dumps_dir)
            date_str = Dates.format(Dates.now(), Dates.dateformat"yyyy_mm_dd_HH_MM_SS")
            dst_file_name = string(
                "rr",
                "--build_$(build_number)",
                "--$(job_name)",
                "--commit_$(commit_short)",
                "--$(date_str)",
                ".tar.zst",
            )
            dst_full_path = joinpath(dumps_dir, dst_file_name)
            zstd_jll.zstdmt() do zstdp
                tarproc = open(`$(zstdp) -o $(dst_full_path)`, "w")
                Tar.create(dir, tarproc)
                close(tarproc.in)
            end

            @info "The `rr` trace file has been saved to: $(dst_full_path)"
            size_bytes = Base.filesize(dst_full_path)
            size_string = Base.format_bytes(size_bytes)
            @info "The size of the `rr` trace file is: $(size_string)"
            max_part_size_bytes = 4_900_000_000 # 4.9 GB, or 4.563 GiB
            if is_buildkite
                if size_bytes < max_part_size_bytes
                    files_to_upload = [dst_file_name]
                else
                    cmd = `split`
                    push!(cmd.exec, "--bytes=$(max_part_size_bytes)")
                    push!(cmd.exec, "$(dst_file_name)")
                    prefix = "$(dst_file_name).part."
                    push!(cmd.exec, prefix)
                    run(setenv(cmd; dir = dumps_dir))
                    files_to_upload = readdir(dumps_dir)
                    filter!(startswith(prefix), files_to_upload)
                    unique!(files_to_upload)
                    sort!(files_to_upload)
                end
            end
            if is_buildkite
                @info "Since this is a Buildkite run, we will upload the `rr` trace file."
                for file_to_upload in files_to_upload
                    cmd = `buildkite-agent artifact upload $(file_to_upload)`
                    run(setenv(cmd; dir = dumps_dir))
                end
            end
        end
    end
end

@info "Finished running the command under rr"
mirror_exit_code(proc)
