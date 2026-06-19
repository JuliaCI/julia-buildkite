# Helper invoked (in separate processes) by the orchestrator
# `compare_stdlib_load_times.jl` for one Julia binary at a time. It has three
# modes, run in this order:
#
#   generate    Run with the binary's *standard* depot. Write a `Project.toml`
#               that lists every loadable stdlib as a dependency and `Pkg.resolve`
#               it to a `Manifest.toml`. Resolution needs the standard depot (it
#               may consult the registry), which is why this is its own phase.
#
#   precompile  Run with a *fresh, isolated* depot (a single, writable path with
#               no compiled cache). With the manifest already present, precompile
#               the *entire* environment in one parallel batch via
#               `Base.Precompilation.precompilepkgs`, building every stdlib's
#               pkgimage into the fresh depot. No resolve happens here, so no
#               registry is needed. The aggregate precompile time is recorded.
#
#   measure     Run with the same fresh depot, *one stdlib per process*. Load the
#               single named stdlib with `Base.require` and record its time. A
#               separate process per stdlib is required because loading one
#               stdlib pulls in its dependencies, so measuring many in a single
#               session would report later ones as already-resident (≈0s).
#
# Generating the Project/Manifest with the standard depot but precompiling and
# loading against the fresh depot is what forces real (re)precompilation instead
# of reusing the binary's bundled pkgimages.
#
# The measured time is written to the output file as a tab-separated
# `name<TAB>seconds` line (`generate` writes nothing).
#
# Usage:
#   julia measure_stdlib_load_times.jl generate   <out_file> <project_dir>
#   julia measure_stdlib_load_times.jl precompile <out_file> <project_dir>
#   julia measure_stdlib_load_times.jl measure    <out_file> <project_dir> <stdlib>

const PKG_UUID = Base.UUID("44cfe95a-1eb2-52ea-b672-e2afdf69b78f")


# Return `name => uuid` for a stdlib that can be added as a project dependency,
# or `nothing` if it has no `Project.toml`/`uuid` (and so can't be precompiled as
# an ordinary package). We scan the TOML by hand to avoid loading the `TOML`
# stdlib (which would itself perturb the timings).
function stdlib_name_uuid(dir, name)
    proj = joinpath(dir, name, "Project.toml")
    isfile(proj) || return nothing
    uuid = nothing
    for line in eachline(proj)
        m = match(r"^\s*uuid\s*=\s*\"([^\"]+)\"", line)
        m === nothing || (uuid = m.captures[1])
    end
    uuid === nothing && return nothing
    return name => uuid
end

# All stdlibs (sorted) that expose a `uuid`, as `name => uuid` pairs.
function loadable_stdlibs()
    dir = Sys.STDLIB
    deps = Pair{String,String}[]
    for name in sort(readdir(dir))
        isdir(joinpath(dir, name)) || continue
        nu = stdlib_name_uuid(dir, name)
        nu === nothing || push!(deps, nu)
    end
    return deps
end

# Write a `Project.toml` whose `[deps]` lists every loadable stdlib, so that
# activating it turns the stdlibs into ordinary, precompilable dependencies.
function write_project(project_dir, deps)
    mkpath(project_dir)
    open(joinpath(project_dir, "Project.toml"), "w") do io
        println(io, "[deps]")
        for (name, uuid) in deps
            println(io, name, " = \"", uuid, "\"")
        end
    end
    return joinpath(project_dir, "Project.toml")
end

# generate phase: write the Project.toml and resolve it to a Manifest.toml using
# the (standard) depot this process was started with.
function generate(project_dir)
    deps = loadable_stdlibs()
    write_project(project_dir, deps)
    Pkg = Base.require(Base.PkgId(PKG_UUID, "Pkg"))
    Base.invokelatest(Pkg.activate, project_dir; io = devnull)
    Base.invokelatest(Pkg.resolve; io = devnull)
    return nothing
end

# precompile phase: with the Manifest already present, precompile the whole
# environment at once (parallel batch) into the fresh depot.
function precompile_all(project_file)
    Base.set_active_project(project_file)
    return @elapsed Base.Precompilation.precompilepkgs(; warn_loaded = false)
end

# measure phase: load the single named stdlib (in this fresh process), timing it
# from the warm cache.
function measure_one(name)
    uuid = nothing
    for (n, u) in loadable_stdlibs()
        n == name && (uuid = u; break)
    end
    uuid === nothing && error("Unknown stdlib: $(name)")
    return @elapsed Base.require(Base.PkgId(Base.UUID(uuid), name))
end

function main()
    length(ARGS) >= 3 || usage_error()
    mode, out_file, project_dir = ARGS[1], ARGS[2], ARGS[3]
    project_file = joinpath(project_dir, "Project.toml")

    if mode == "generate"
        generate(project_dir)
        return
    elseif mode == "precompile"
        timings = ["__precompile__" => precompile_all(project_file)]
    elseif mode == "measure"
        length(ARGS) == 4 || usage_error()
        name = ARGS[4]
        Base.set_active_project(project_file)
        timings = [name => measure_one(name)]
    else
        usage_error()
    end

    open(out_file, "w") do io
        for (name, t) in timings
            println(io, name, '\t', t)
        end
    end
end

function usage_error()
    println(stderr, """
        Usage:
          julia measure_stdlib_load_times.jl generate   <out_file> <project_dir>
          julia measure_stdlib_load_times.jl precompile <out_file> <project_dir>
          julia measure_stdlib_load_times.jl measure    <out_file> <project_dir> <stdlib>""")
    exit(2)
end

main()
