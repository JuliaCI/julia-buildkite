# Usage:    julia rr_invoke.jl [args...]
#
# Instead of running `rr foo bar baz ...`, you would run `julia rr_invoke.jl foo bar baz ...`
# instead.
# 
# Examples: julia rr_invoke.jl --version
#           julia rr_invoke.jl --help
#           julia rr_invoke.jl replay ...

import Pkg

# We add `rr_jll` to a temporary project.
#
# Note: we still use the user's default depot paths. This is important; it means that if the
# user runs the `rr_invoke.jl` script multiple times, we don't have to redownload `rr_jll`
# every time.
#
# If the user does not want to use their default depot paths, they should do e.g.
# `export JULIA_DEPOT_PATH=$(mktemp -d)` before running the `rr_invoke.jl` script.
Pkg.activate(mktempdir(; cleanup = true))

Pkg.add(Pkg.PackageSpec(name = "rr_jll", version = v"5.5.0"))

import rr_jll

rr_jll.rr() do rr_path
    run(`$(rr_path) $ARGS`)
end
