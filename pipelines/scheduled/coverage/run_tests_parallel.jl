# Important note: even if one or more tests fail, we will still exit with status code 0.
#
# The reason for this is that we always want to upload code coverage, even if some of the
# tests fail. Therefore, even if the `coverage_linux64` job passes, you should not
# assume that all of the tests passed. If you want to know if all of the tests are passing,
# please look at the status of the `tester_*` jobs (e.g. `tester_linux64`).

const ncores = Sys.CPU_THREADS
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
    `--code-coverage-exclude=$(join(coverage_exclude, Sys.iswindows() ? ';' : ':'))`

cmd = `$(Base.julia_cmd()) --code-coverage=lcov-%p.info $exclude_flag -e $(script)`

@info "Running command" cmd
p = run(pipeline(cmd; stdin, stdout, stderr); wait = false)
wait(p)
