# Important note: even if one or more tests fail, we will still exit with status code 0.
#
# The reason for this is that we always want to upload code coverage, even if some of the
# tests fail. Therefore, even if the `coverage_linux64` job passes, you should not
# assume that all of the tests passed. If you want to know if all of the tests are passing,
# please look at the status of the `tester_*` jobs (e.g. `tester_linux64`).

const ncores = Sys.CPU_THREADS
@info "" Sys.CPU_THREADS
@info "" ncores

script = """
    Base.runtests(["all", "--skip", "Pkg"]; ncores = $(ncores))
"""

cmd = `$(Base.julia_cmd()) --code-coverage=lcov-%p.info -e $(script)`

@info "Running command" cmd
p = run(pipeline(cmd; stdin, stdout, stderr); wait = false)
wait(p)
