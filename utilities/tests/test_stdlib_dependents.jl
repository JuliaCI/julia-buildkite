# Check which stdlibs utilities/stdlib_dependents.jl selects for testing.
#
#   julia utilities/tests/test_stdlib_dependents.jl

using Test

include(joinpath(@__DIR__, "..", "stdlib_dependents.jl"))

@testset "stdlib dependents" begin
    deps = Dict("LinearAlgebra" => ["Libdl", "OpenBLAS_jll"],
                "SparseArrays" => ["LinearAlgebra", "Libdl"],
                "SuiteSparse" => ["SparseArrays"],
                "Statistics" => ["LinearAlgebra"],
                "Tar" => ["ArgTools"],
                "Libdl" => String[])

    @testset "direct and transitive dependents" begin
        @test dependents(deps, ["LinearAlgebra"]) ==
              ["LinearAlgebra", "SparseArrays", "Statistics", "SuiteSparse"]
        @test dependents(deps, ["SparseArrays"]) == ["SparseArrays", "SuiteSparse"]
    end

    @testset "a leaf only selects itself" begin
        @test dependents(deps, ["SuiteSparse"]) == ["SuiteSparse"]
        # including a stdlib that is not installed, such as one a PR removes
        @test dependents(deps, ["Gone"]) == ["Gone"]
    end

    @testset "a dependency outside the stdlibs" begin
        @test dependents(deps, ["ArgTools"]) == ["ArgTools", "Tar"]
    end

    @testset "deps and weakdeps are read from Project.toml" begin
        mktempdir() do dir
            for (name, toml) in ("A" => "[deps]\nB = \"$(Base.UUID(1))\"\n",
                                 "C" => "[weakdeps]\nA = \"$(Base.UUID(2))\"\n",
                                 "D" => "name = \"D\"\n")
                mkpath(joinpath(dir, name))
                write(joinpath(dir, name, "Project.toml"), toml)
            end
            mkpath(joinpath(dir, "notastdlib"))
            @test stdlib_deps(dir) == Dict("A" => ["B"], "C" => ["A"], "D" => String[])
            @test dependents(stdlib_deps(dir), ["B"]) == ["A", "B", "C"]
        end
    end
end
