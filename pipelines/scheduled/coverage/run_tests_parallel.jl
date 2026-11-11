# Important note: even if one or more tests fail, we will still exit with status code 0.
#
# The reason for this is that we always want to upload code coverage, even if some of the
# tests fail. Therefore, even if the `coverage_linux64` job passes, you should not
# assume that all of the tests passed. If you want to know if all of the tests are passing,
# please look at the status of the `tester_*` jobs (e.g. `tester_linux64`).

# Every worker carries coverage instrumentation; COVERAGE_MAX_WORKERS caps the
# width on hosts whose memory doesn't fit one worker per CPU thread.
const ncores = min(Sys.CPU_THREADS,
                   parse(Int, get(ENV, "COVERAGE_MAX_WORKERS", string(Sys.CPU_THREADS))))
@info "" Sys.CPU_THREADS
@info "" ncores

script = if Sys.iswindows()
    """
        Base.runtests(["all", "--skip", "Pkg", "Profile", "cmdlineargs"]; ncores = $(ncores))
    """
else
    """
        Base.runtests(["all", "--skip", "Pkg"]; ncores = $(ncores))
    """
end

# Leave the test suites' own files uninstrumented: instrumented code is optimized
# differently, so tests of inference and inlining would see other code than in
# normal CI. Julia versions without the option instrument everything.
coverage_exclude = String[]
if hasfield(Base.JLOptions, :coverage_exclude)
    share = normpath(Sys.BINDIR, "..", "share", "julia")
    for root in (pwd(), share), dir in (["test"], ["Compiler", "test"], ["JuliaSyntax", "test"], ["JuliaLowering", "test"])
        push!(coverage_exclude, joinpath(root, dir...))
    end
    stdlib_dir = joinpath(share, "stdlib", "v$(VERSION.major).$(VERSION.minor)")
    for name in readdir(stdlib_dir)
        push!(coverage_exclude, joinpath(stdlib_dir, name, "test"))
    end
    filter!(isdir, coverage_exclude)
end
exclude_flag = isempty(coverage_exclude) ? `` :
    `--code-coverage=-$(join(coverage_exclude, Sys.iswindows() ? ';' : ':'))`

cmd = `$(Base.julia_cmd()) --code-coverage=all --code-coverage=lcov-%p.info $exclude_flag -e $(script)`

@info "Running command" cmd
p = run(pipeline(cmd; stdin, stdout, stderr); wait = false)
wait(p)

# With Base instrumented, the optimizer sees coverage markers in every Base function it
# inlines, so the Compiler tests miss the passes they target (finalizer inlining, for
# one). Run them again with only the compiler's own source instrumented.
compiler_src = normpath(Sys.BINDIR, "..", "share", "julia", "Compiler", "src")
if hasfield(Base.JLOptions, :coverage_exclude) && isdir(compiler_src)
    compiler_script = "Base.runtests([\"compiler\"]; ncores = $(ncores))"
    cmd = `$(Base.julia_cmd()) --code-coverage=@$(compiler_src) --code-coverage=lcov-compiler-%p.info $exclude_flag -e $(compiler_script)`
    @info "Running command" cmd
    p = run(pipeline(cmd; stdin, stdout, stderr); wait = false)
    wait(p)
end
