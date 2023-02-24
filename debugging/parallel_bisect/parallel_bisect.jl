include("../julia_checkout.jl")

if length(ARGS) < 3
    println("Usage: $(basename(@__FILE__)) <good sha> <bad sha> <script>")
    exit(1)
end

sha_good = parse(Base.SHA1, ARGS[1])
sha_bad = parse(Base.SHA1, ARGS[2])
script = ARGS[3]
if !isfile(script)
    @error("Unable to find script", script)
    exit(1)
end
script = abspath(script)

mkpath(joinpath(tempdir(), "parallel-bisect"))
workdir = mktempdir(joinpath(tempdir(), "parallel-bisect"))
julia_url = "https://github.com/JuliaLang/julia.git"

# Get the list of commits between the good and bad commits:
commits = get_commits_between(julia_url, sha_good, sha_bad)
if isempty(commits)
    @error("Unable to find any commits that satisfy the given range!", sha_good, sha_bad)
    exit(1)
end
@info("Got $(length(commits)) commits:")

# Always oversubscribe a little bit :)
if Threads.nthreads() < 2
    # We require at least two threads so that we can test the two edges of the
    # commit span in a single go.
    error("Must run with more than 1 thread!")
end

# If we have `ccache` available, let's for sure use it.
ccache_available = Sys.which("ccache") !== nothing
if !ccache_available
    @warn("ccache unavailable; highly recommend installing it!")
end

function build_and_test(sha::Base.SHA1; precompile::Bool = false,
                                        shared_srccache::Bool = true,
                                        use_ccache::Bool = ccache_available,
                                        keep_build_failures::Bool = true,
                                        cores_per_job = div(Sys.CPU_THREADS,Threads.nthreads()) + 1,
                                        depot::String = @get_scratch!("bisect-depot"))
    # Check it out
    checkout = GitCheckout(julia_url, sha, bytes2hex(sha.bytes))
    get_checkout(checkout, workdir)
    checkout_dir = joinpath(workdir, bytes2hex(sha.bytes))

    # Do some customizations
    make_user = String[
        "override VERBOSE := 1",
    ]
    if !precompile
        push!(make_user, "override JULIA_PRECOMPILE := 0")
    end
    if shared_srccache
        srccache = @get_scratch!("shared-srccache")
        push!(make_user, "override SRCCACHE := $(srccache)")
    end
    if use_ccache
        push!(make_user, "override USECCACHE := 1")
    end
    open(joinpath(checkout_dir, "Make.user"); write=true) do io
        for line in make_user
            println(io, line)
        end
    end

    # Start build
    build_log = joinpath(checkout_dir, "build.log")
    build_cmd = setenv(`make --output-sync -j$(cores_per_job)`, dir=checkout_dir)
    build_cmd = pipeline(build_cmd, stdout=build_log, stderr=build_log, append=true)
    if !success(build_cmd)
        @warn("Commit $(sha) failed to build", build_log)
        if keep_build_failures && haskey(Base.Filesystem.TEMP_CLEANUP, workdir)
            @warn(" -> Persisting build directory", workdir)
            delete!(Base.Filesystem.TEMP_CLEANUP, workdir)
        end
        return :build_fail
    end

    # If it passes, run the script
    mktempdir() do project_dir
        cmd = `$(joinpath(checkout_dir, "usr", "bin", "julia")) --project=$(project_dir) $(script)`
        cmd = setenv(cmd,
            "JULIA_DEPOT_PATH" => depot,
            "JULIA_NUM_PRECOMPILE_TASKS" => string(cores_per_job),
        )
        cmd = pipeline(cmd, stdout=build_log, stderr=build_log, append=true)
        if success(cmd)
            return :test_success
        else
            return :test_fail
        end
    end
end

function build_and_test(shas::Vector{Base.SHA1}; kwargs...)
    # Holds our results in the same order given
    results = Symbol[:unbuilt for _ in 1:length(shas)]

    Threads.@sync begin
        # Parallelism-gating channel and task setup
        c = Channel{Tuple{Int,Base.SHA1}}()
        Threads.@spawn begin
            for (idx, sha) in enumerate(shas)
                put!(c, (idx,sha))
            end
            close(c)
        end

        # Clear out our precompilation directory
        depot = @get_scratch!("bisect-depot")
        rm(joinpath(depot, "compiled"); recursive=true, force=true)

        for _ in 1:Threads.nthreads()
            Threads.@spawn begin
                while isopen(c)
                    local idx, sha
                    try
                        (idx, sha) = take!(c)
                    catch e
                        if isa(e, InvalidStateException) && e.state == :closed
                            continue
                        end
                        rethrow(e)
                    end
                    results[idx] = build_and_test(sha; depot, kwargs...)
                end
            end
        end
    end
    return results
end

function select_builds(num_commits::Int, num_builds::Int = Threads.nthreads())
    num_builds = min(num_builds, num_commits)
    idxs = 1 .+ ((0:(num_builds-1)) .+ .5).*((num_commits-1)/num_builds)
    idxs = unique(round.(Int, idxs, Base.RoundNearestTiesAway))
    return idxs
end

function select_builds(results::Vector{Symbol}, min::Int, max::Int, num_builds::Int = Threads.nthreads())
    # Filter out all `:unbuilt` builds from the results within the given bounds
    unbuilt_idxs = [idx for idx in min:max if results[idx] == :unbuilt]
    selected_unbuilt_idxs = select_builds(length(unbuilt_idxs), num_builds)
    return unbuilt_idxs[selected_unbuilt_idxs]
end

# Now that we know we have appropriate bounds, we chop up our commit range
# Use the number of threads to determine how many parallel builds we should embark upon
function parallel_bisect(commits::Vector{Base.SHA1})
    results = Symbol[:unbuilt for _ in 1:length(commits)]

    highest_good_idx = 0
    lowest_bad_idx = length(commits) + 1
    iterations = 0
    while true
        idxs = select_builds(results, highest_good_idx + 1, lowest_bad_idx - 1)

        # If we're on our first iteration, ensure that the first and last idxs are selected
        if highest_good_idx == 0 && lowest_bad_idx == length(commits) + 1
            idxs[1] = 1
            idxs[end] = length(commits)
        end

        if isempty(idxs)
            @info("First bad commit found", first_bad_commit=commits[lowest_bad_idx], lowest_bad_idx, results)
            break
        end
        @info("About to build:", commits[idxs], idxs)

        # Run build/test, fill out the results for each build:
        sub_results = build_and_test(commits[idxs])
        for (sub_idx, idx) in enumerate(idxs)
            results[idx] = sub_results[sub_idx]
        end
        iterations += 1

        # If we're on our first iteration, ensure that the first and last idxs came out as expected
        if highest_good_idx == 0 && lowest_bad_idx == length(commits) + 1
            if results[1] != :test_success
                build_log = joinpath(workdir, bytes2hex(commits[1].bytes), "build.log")
                @error("Good commit not actually good?!", results[1], build_log)
                break
            end
            if results[end] != :test_fail
                build_log = joinpath(workdir, bytes2hex(commits[end].bytes), "build.log")
                @error("Bad commit not actually bad?!", results[end], build_log)
                break
            end
        end

        lowest_bad_idx = findfirst(==(:test_fail), results)
        highest_good_idx = findlast(==(:test_success), results)
    end
    open(joinpath(workdir, "build_results.txt"); write=true) do io
        println(io, "Bisection from $(bytes2hex(commits[1].bytes)) -> $(bytes2hex(commits[end].bytes)) ($(length(commits)) commits) done in $(iterations) iterations")
        println(io, "Commit status:")
        for idx in 1:length(commits)
            println(io, "[", string(idx; pad=ceil(Int, log10(length(commits)))), "]: ", bytes2hex(commits[idx].bytes), " - ", results[idx])
        end
    end
    return commits[lowest_bad_idx]
end

parallel_bisect(commits)
