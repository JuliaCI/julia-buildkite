ENV["JULIA_PKG_AUTO_PRECOMPILE"] = "false"
using Pkg
Pkg.add(;name="ConstructionBase", version=v"1.4.1")
Pkg.add(;name="LinearSolve")
Pkg.precompile()
