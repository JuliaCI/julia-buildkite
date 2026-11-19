# Check which processes utilities/windows/dump_descendants.jl dumps, on any platform.
#
#   julia utilities/tests/test_descendants.jl

using Test

include(joinpath(@__DIR__, "..", "windows", "descendants.jl"))

# Runs `descendants` on a listing `procs` of (pid, parent pid, name), with `created` mapping
# each running process id to its current process' creation time, and returns the pids
# selected and the handles closed, but the root's.
function select(root, procs, created, cutoff; root_created=created[root])
    closed = []
    found = descendants(root, root_created, procs, cutoff;
                        open=pid -> haskey(created, pid) ? (pid, created[pid]) : nothing,
                        close=handle -> push!(closed, handle))
    @test all(proc -> proc.handle == proc.pid, found)
    @test root in closed
    return [proc.pid for proc in found], sort(filter(!=(root), closed))
end

@testset "descendants" begin
    procs = [(1, 0, "driver"), (2, 1, "worker"), (3, 1, "worker"), (4, 2, "child"),
             (5, 3, "child"), (6, 99, "other")]
    created = Dict(1 => 10, 2 => 30, 3 => 20, 4 => 40, 5 => 35, 6 => 5)

    @testset "workers first, oldest first, then their children" begin
        @test select(1, procs, created, 100) == ([3, 2, 5, 4], [])
    end

    @testset "a process that exited is skipped" begin
        @test select(1, procs, delete!(copy(created), 3), 100) == ([2, 4], [])
    end

    @testset "a PID reused after the listing is not dumped" begin
        # Worker 3 exited and its PID went to a process created after the cutoff
        @test select(1, procs, merge(created, Dict(3 => 150)), 100) == ([2, 4], [3])
        # nor at the cutoff itself
        @test select(1, procs, merge(created, Dict(3 => 100)), 100) == ([2, 4], [3])
    end

    @testset "a process older than its listed parent is not its child" begin
        # Worker 2 exited and its PID went to a process created before the driver; its
        # child 4 then has no parent among the descendants
        @test select(1, procs, merge(created, Dict(2 => 5)), 100) == ([3, 5], [2])
        # nor one created at the same time
        @test select(1, procs, merge(created, Dict(2 => 10)), 100) == ([3, 5], [2])
        # Child 4 is older than worker 2
        @test select(1, procs, merge(created, Dict(4 => 25)), 100) == ([3, 2, 5], [4])
    end

    @testset "the root must still be the process it was" begin
        # The driver exited and its PID went to a process that started children
        @test_throws ErrorException select(1, procs, merge(created, Dict(1 => 12)), 100;
                                           root_created=10)
        @test_throws ErrorException select(1, procs, delete!(copy(created), 1), 100;
                                           root_created=10)
    end

    @testset "the root is not its own child" begin
        @test select(1, [(1, 1, "driver"), (2, 1, "worker")], Dict(1 => 10, 2 => 20), 100) ==
              ([2], [])
    end
end
