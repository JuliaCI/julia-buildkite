# Print the stdlibs that a change to the given stdlibs can break: the stdlibs themselves and
# every stdlib that depends on one of them, directly or through other stdlibs. A weak
# dependency counts, since the extension it triggers loads the changed stdlib.
#
#   julia stdlib_dependents.jl LinearAlgebra [...]
#
# The dependencies are read from the `Project.toml` files of the running julia's stdlibs.

import TOML

# The stdlibs in `dir` mapped to the names of the packages they depend on.
function stdlib_deps(dir::AbstractString)
    deps = Dict{String,Vector{String}}()
    for name in readdir(dir)
        project = joinpath(dir, name, "Project.toml")
        isfile(project) || continue
        toml = TOML.parsefile(project)
        deps[name] = [collect(keys(get(toml, "deps", Dict())));
                      collect(keys(get(toml, "weakdeps", Dict())))]
    end
    return deps
end

function dependents(deps::Dict{String,Vector{String}}, changed)
    affected = Set{String}(changed)
    grown = true
    while grown
        grown = false
        for (name, uses) in deps
            if !(name in affected) && any(in(affected), uses)
                push!(affected, name)
                grown = true
            end
        end
    end
    return sort!(collect(affected))
end

if abspath(PROGRAM_FILE) == @__FILE__
    foreach(println, dependents(stdlib_deps(Sys.STDLIB), ARGS))
end
