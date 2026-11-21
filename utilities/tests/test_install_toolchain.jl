# Tests of utilities/windows/install_toolchain.jl's choice of sources and handling of what
# they answer, with a fake download (the real one is exercised by the Windows build jobs).

using Test
using Downloads: RequestError, Response
using Base: SHA1

include(joinpath(@__DIR__, "..", "windows", "install_toolchain.jl"))

const HASH = "c05b25a4e8ce4cdfca1960f1c226368c7913dc82"
const SPEC = parse_args(["package_windows.x86_64.v8.10", HASH])
const GITHUB = "https://github.com/JuliaCI/rootfs-images/releases/download/v8.10/package_windows.x86_64.tar.gz"
const SERVER = "https://pkg.example.org/artifact/$(HASH)"

no_response() = Response(nothing, "", 0, "", Pair{String,String}[])
http_error(url, status) = RequestError(url, 0, "HTTP/1.1 $(status)",
                                       Response("https", url, status, "", Pair{String,String}[]))
transport_error(url) = RequestError(url, 7, "Failed to connect", no_response())
timeout_error(url) = RequestError(url, 28, "Operation too slow", no_response())
mismatch() = ErrorException("Tree Hash Mismatch!\n  Expected git-tree-sha1:   $(HASH)\n")
disk_full() = SystemError("write", 28)

struct Throw
    err::Exception
end

# Runs `f(depot)` with `depot` as the only depot.
function with_depot(f)
    mktempdir() do depot
        old = copy(DEPOT_PATH)
        empty!(DEPOT_PATH); push!(DEPOT_PATH, depot)
        try
            f(depot)
        finally
            empty!(DEPOT_PATH); append!(DEPOT_PATH, old)
        end
    end
end

# Runs `install` in an empty depot with a download that answers from `answers`, a list of
# `url => result`, consumed in order; `result === true` creates the tree, a `Throw` throws.
# Returns the result of `install` (or the exception it threw), the URLs that were tried and
# the backoff delays.
function run_install(answers; pkg_server="https://pkg.example.org")
    tried = String[]
    slept = Int[]
    with_depot() do depot
        download = function (tree, url; kwargs...)
            push!(tried, url)
            isempty(answers) && error("unexpected download of $(url)")
            expected, result = popfirst!(answers)
            @test url == expected
            result isa Throw && throw(result.err)
            result === true && mkpath(artifact_path(tree))
            return result
        end
        result = try
            install(SPEC; pkg_server, download, sleep=s -> push!(slept, s))
        catch err
            err
        end
        @test isempty(answers)
        return result, tried, slept
    end
end

@testset "install_toolchain.jl" begin
    @testset "arguments" begin
        @test SPEC == (; image="package_windows", arch="x86_64", tag="v8.10", hash=HASH)
        @test parse_args(["package_windows.i686.v8.5", HASH]).arch == "i686"
        for args in (["package_windows.x86_64.v8.10"],
                     ["package_linux.x86_64.v8.10", HASH],
                     ["package_windows.aarch64.v8.10", HASH],
                     ["package_windows.x86_64.v8", HASH],
                     ["package_windows.x86_64.v8.10/../x", HASH],
                     ["package_windows.x86_64.v8.10", uppercase(HASH)],
                     ["package_windows.x86_64.v8.10", HASH[1:39]])
            @test_throws ArgumentError parse_args(args)
        end
        @test main(["package_windows.x86_64.v8.10", "nothex"]) == 2
    end

    @testset "sources" begin
        @test sources(SPEC, "https://pkg.example.org") == [SERVER, GITHUB]
        @test sources(SPEC, "https://pkg.example.org/") == [SERVER, GITHUB]
        @test sources(SPEC, nothing) == [GITHUB]
    end

    @testset "classify" begin
        @test classify(true) === :ok
        @test classify(http_error(GITHUB, 404)) === :missing
        @test classify(http_error(GITHUB, 410)) === :missing
        @test classify(http_error(GITHUB, 401)) === :refused
        @test classify(http_error(GITHUB, 403)) === :refused
        @test classify(http_error(GITHUB, 408)) === :transient
        @test classify(http_error(GITHUB, 429)) === :transient
        @test classify(http_error(GITHUB, 500)) === :transient
        @test classify(http_error(GITHUB, 503)) === :transient
        @test classify(transport_error(GITHUB)) === :transient
        @test classify(timeout_error(GITHUB)) === :slow
        @test classify(mismatch()) === :mismatch
        @test classify(disk_full()) === :local
        @test classify(Base.IOError("mkdir: permission denied (EACCES)", -13)) === :local
        @test classify(ErrorException("something else")) === :transient
        @test classify(false) === :transient
    end

    @testset "install" begin
        # The Pkg server has it
        result, tried, slept = run_install([SERVER => true])
        @test endswith(result, HASH)
        # Not on the Pkg server: the release
        result, tried, slept = run_install([SERVER => http_error(SERVER, 404), GITHUB => true])
        @test endswith(result, HASH)
        @test tried == [SERVER, GITHUB]
        @test isempty(slept)
        # No Pkg server
        result, tried, slept = run_install([GITHUB => true]; pkg_server=nothing)
        @test tried == [GITHUB]
        # Transient errors are retried after a backoff, a bounded number of times
        result, tried, slept = run_install([SERVER => http_error(SERVER, 404),
                                            GITHUB => transport_error(GITHUB), GITHUB => true])
        @test endswith(result, HASH)
        @test slept == [10]
        for status in (408, 429, 503)
            result, tried, slept = run_install([SERVER => http_error(SERVER, status),
                                                SERVER => http_error(SERVER, status),
                                                SERVER => http_error(SERVER, status), GITHUB => true])
            @test endswith(result, HASH)
            @test slept == [10, 30]
        end
        # Thrown errors are handled like returned ones
        result, tried, slept = run_install([SERVER => Throw(transport_error(SERVER)), SERVER => true])
        @test endswith(result, HASH)
        @test slept == [10]
        # A source that refuses, serves another tree or is too slow is skipped at once
        for answer in (http_error(SERVER, 403), mismatch(), timeout_error(SERVER))
            result, tried, slept = run_install([SERVER => answer, GITHUB => true])
            @test endswith(result, HASH)
            @test isempty(slept)
        end
        # Nobody has it: the error says what each source answered
        result, tried, slept = run_install([SERVER => http_error(SERVER, 403), GITHUB => mismatch()])
        @test result isa ErrorException
        @test occursin("$(SERVER): refused (HTTP 403)", result.msg)
        @test occursin("$(GITHUB): serves another tree", result.msg)
        result, tried, slept = run_install([SERVER => timeout_error(SERVER), GITHUB => http_error(GITHUB, 404)])
        @test occursin("$(SERVER): too slow or unreachable", result.msg)
        @test occursin("$(GITHUB): not found (HTTP 404)", result.msg)
        result, tried, slept = run_install([GITHUB => transport_error(GITHUB), GITHUB => transport_error(GITHUB),
                                            GITHUB => transport_error(GITHUB)]; pkg_server=nothing)
        @test occursin("failed 3 times", result.msg)
        # A local error ends the install: no retry, no other source
        result, tried, slept = run_install([SERVER => Throw(disk_full())])
        @test result isa ErrorException && occursin("could not install", result.msg)
        @test tried == [SERVER] && isempty(slept)
        # Also when it surfaces from Downloads' writer task
        writer = Task(() -> throw(disk_full()))
        schedule(writer)
        try wait(writer) catch end
        wrapped = CompositeException([TaskFailedException(writer)])
        result, tried, slept = run_install([SERVER => Throw(wrapped)])
        @test result isa ErrorException && occursin("could not install", result.msg)
        @test tried == [SERVER] && isempty(slept)
        # An interrupt is not swallowed
        result, tried, slept = run_install([SERVER => Throw(InterruptException())])
        @test result isa InterruptException
        # Installed already: nothing is downloaded, but leftovers are removed
        with_depot() do depot
            mkpath(artifact_path(SHA1(HASH)))
            stale = mkpath(joinpath(depot, "artifacts", "jl_AbC123", "msys64"))
            @test install(SPEC; download=(args...; kwargs...) -> error("downloaded")) == artifact_path(SHA1(HASH))
            @test !ispath(dirname(stale))
        end
        # Leftovers of an interrupted install are removed, and nothing else
        with_depot() do depot
            stale = mkpath(joinpath(depot, "artifacts", "jl_AbC123", "msys64"))
            other = mkpath(joinpath(depot, "artifacts", "0123456789abcdef0123456789abcdef01234567"))
            install(SPEC; pkg_server=nothing, download=(tree, url; kw...) -> (mkpath(artifact_path(tree)); true))
            @test !ispath(dirname(stale))
            @test isdir(other)
        end
    end

    @testset "download limits" begin
        # The limits reach the requests Pkg makes through the default downloader
        downloader = configure_downloads!()
        try
            @test Downloads.DOWNLOADER[] === downloader
            @test downloader.easy_hook !== nothing
        finally
            Downloads.default_downloader!(nothing)
        end
    end
end
