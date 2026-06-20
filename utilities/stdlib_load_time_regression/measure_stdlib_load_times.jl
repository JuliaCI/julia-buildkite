# Helper invoked (in separate processes) by the orchestrator
# `compare_stdlib_load_times.jl`, once per Julia binary, against a fresh isolated
# depot. It has two modes:
#
#   precompile  Precompile every loadable stdlib (dependencies first, so each is
#               compiled exactly once) into the depot with `Base.compilecache`, and
#               record the total elapsed time. No Pkg/registry/manifest is involved,
#               so this never touches the network or the agent's depot. Writes the
#               elapsed seconds on the first line of <out_file>, then the names of
#               the stdlibs that were compiled, one per line.
#
#   measure     Load the single named stdlib with `Base.require` (from the warm
#               cache the precompile mode just built) and record its time. A
#               separate process per stdlib is required because loading one stdlib
#               pulls in its dependencies, so a shared session would report later
#               stdlibs as already-resident (~0s). Writes a `name<TAB>seconds` line.
#
# Usage:
#   julia measure_stdlib_load_times.jl precompile <out_file>
#   julia measure_stdlib_load_times.jl measure    <out_file> <stdlib>

# Parse a stdlib's `Project.toml` for its uuid and the names listed under `[deps]`.
# We scan the TOML by hand to avoid loading the `TOML` stdlib (which would itself
# perturb the timings).
function read_project(proj)
    uuid = nothing
    deps = String[]
    in_deps = false
    for line in eachline(proj)
        s = strip(line)
        if s == "[deps]"
            in_deps = true
        elseif startswith(s, "[")
            in_deps = false
        elseif in_deps
            m = match(r"^(\S+)\s*=", s)
            m === nothing || push!(deps, String(m.captures[1]))
        else
            m = match(r"^uuid\s*=\s*\"([^\"]+)\"", s)
            m === nothing || (uuid = String(m.captures[1]))
        end
    end
    return uuid, deps
end

# Every loadable stdlib (one that exposes a uuid) as `name => (uuid, dep_names)`.
function loadable_stdlibs()
    stdlibs = Dict{String,Tuple{String,Vector{String}}}()
    for name in readdir(Sys.STDLIB)
        proj = joinpath(Sys.STDLIB, name, "Project.toml")
        isfile(proj) || continue
        uuid, deps = read_project(proj)
        uuid === nothing || (stdlibs[name] = (uuid, deps))
    end
    return stdlibs
end

# Precompile every stdlib into the (fresh) depot, dependencies first so that each
# is compiled exactly once. Returns `(elapsed_seconds, sorted_names)`.
function precompile_all()
    stdlibs = loadable_stdlibs()
    done = Set{String}()
    function precompile_one(name)
        (name in done || !haskey(stdlibs, name)) && return
        push!(done, name)
        uuid, deps = stdlibs[name]
        foreach(precompile_one, deps)
        Base.compilecache(Base.PkgId(Base.UUID(uuid), name), devnull, devnull)
    end
    names = sort!(collect(keys(stdlibs)))
    elapsed = @elapsed foreach(precompile_one, names)
    return elapsed, names
end

# Load the single named stdlib, timing it from the warm cache.
function measure_one(name)
    stdlibs = loadable_stdlibs()
    haskey(stdlibs, name) || error("Unknown stdlib: $(name)")
    uuid, _ = stdlibs[name]
    return @elapsed Base.require(Base.PkgId(Base.UUID(uuid), name))
end

function usage_error()
    println(stderr, """
        Usage:
          julia measure_stdlib_load_times.jl precompile <out_file>
          julia measure_stdlib_load_times.jl measure    <out_file> <stdlib>""")
    exit(2)
end

function main()
    length(ARGS) >= 2 || usage_error()
    mode, out_file = ARGS[1], ARGS[2]

    if mode == "precompile"
        elapsed, names = precompile_all()
        open(out_file, "w") do io
            println(io, elapsed)
            foreach(n -> println(io, n), names)
        end
    elseif mode == "measure"
        length(ARGS) == 3 || usage_error()
        t = measure_one(ARGS[3])
        open(out_file, "w") do io
            println(io, ARGS[3], '\t', t)
        end
    else
        usage_error()
    end
end

main()
