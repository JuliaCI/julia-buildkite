# Tests of utilities/windows/install_toolchain.jl's choice of sources, with a fake download
# (the real one is exercised by the Windows build jobs).

using Test
using Base: SHA1

include(joinpath(@__DIR__, "..", "windows", "install_toolchain.jl"))

const NAME = "package_windows.x86_64.v8.10"
const HASH = "c05b25a4e8ce4cdfca1960f1c226368c7913dc82"
const GITHUB = "https://github.com/JuliaCI/rootfs-images/releases/download/v8.10/package_windows.x86_64.tar.gz"
const SERVER = "https://pkg.example.org/artifact/$(HASH)"

# Runs `f()` with an empty depot as the only depot.
function with_depot(f)
    mktempdir() do depot
        old = copy(DEPOT_PATH)
        empty!(DEPOT_PATH); push!(DEPOT_PATH, depot)
        try
            f()
        finally
            empty!(DEPOT_PATH); append!(DEPOT_PATH, old)
        end
    end
end

# A download that answers `answers[url]`, creating the tree when that is `true`.
function fake_download(answers, tried)
    return function (tree, url; kwargs...)
        push!(tried, url)
        result = answers[url]
        result === true && mkpath(artifact_path(tree))
        return result
    end
end

@testset "install_toolchain.jl" begin
    @test sources(NAME, HASH, "https://pkg.example.org/") == [SERVER, GITHUB]
    @test sources(NAME, HASH, nothing) == [GITHUB]
    @test sources("package_windows.i686.v8.5", HASH, nothing) ==
          ["https://github.com/JuliaCI/rootfs-images/releases/download/v8.5/package_windows.i686.tar.gz"]
    for name in ("package_linux.x86_64.v8.10", "package_windows.aarch64.v8.10",
                 "package_windows.x86_64.v8", "package_windows.x86_64.v8.10/../x")
        @test_throws ErrorException sources(name, HASH, nothing)
    end

    # Not on the Pkg server: the release; then installed, nothing is downloaded
    with_depot() do
        tried = String[]
        download = fake_download(Dict(SERVER => ErrorException("HTTP 404"), GITHUB => true), tried)
        @test install(NAME, HASH; pkg_server="https://pkg.example.org", download) == artifact_path(SHA1(HASH))
        @test tried == [SERVER, GITHUB]
        @test install(NAME, HASH; download=(args...; kwargs...) -> error("downloaded")) == artifact_path(SHA1(HASH))
    end

    # Nobody has it: the error says what each source answered
    with_depot() do
        tried = String[]
        download = fake_download(Dict(SERVER => ErrorException("HTTP 404"), GITHUB => false), tried)
        err = try
            install(NAME, HASH; pkg_server="https://pkg.example.org", download)
        catch err
            err
        end
        @test err isa ErrorException
        @test occursin("$(SERVER): HTTP 404", err.msg)
        @test occursin("$(GITHUB): false", err.msg)
    end
end
