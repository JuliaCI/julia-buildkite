# Usage:    julia timeout.jl [args...]
#
# Wraps an execution within a timer that will kill the command after the given time period.
# We accept timeout arguments via environment variables to avoid having to implement argument
# parsing in CI scripts.  Note that all time periods are expressed as compound values with
# suffixes, e.g. "2h30m".  All suffixes are required.
#
# Relevant environment variables:
#
#  - JL_TEST_TIMEOUT:     How long to wait for the task to complete before starting the
#                         teardown escalation pipeline (SIGTERM -> SIGQUIT -> SIGKILL).
#                         Defaults to 2 hours.
#  - JL_TEARDOWN_TIMEOUT: How long to wait for the process group to exit after SIGTERM
#                         before escalating.  This covers graceful teardown work, e.g.
#                         the test driver core-dumping its stuck workers, or `rr`
#                         finishing off its recording, which can take a long time.
#                         Defaults to 10 minutes.
#  - JL_KILL_TIMEOUT:     How long to wait for the process group to exit after SIGQUIT
#                         (including time spent writing core dumps) before escalating
#                         to SIGKILL.  Defaults to 10 minutes.
#  - JL_TERM_SIGTERM:     Whether to start the escalation with SIGTERM, which asks the
#                         test driver to core-dump its stuck workers (they run in
#                         detached sessions, out of reach of our process-group signals;
#                         see test/runtests.jl in JuliaLang/julia).  Defaults to false.
#  - JL_TERM_SIGQUIT:     Whether to include the SIGQUIT (coredump) stage.  Defaults to
#                         true.
#
# Example:
#   - JL_TEST_TIMEOUT=2h30m JL_KILL_TIMEOUT=600s julia timeout.jl cmd...

include(joinpath(@__DIR__, "proc_utils.jl"))

# Parse a time period such as "2h30m"
function parse_time_period(period::AbstractString)
    unit_to_seconds = Dict(
        'h' => 60*60,
        'm' => 60,
        's' => 1,
    )

    m = match(r"^(\d+(?:h|m|s))(\d+(?:m|s))?(\d+s)?$", period)
    total_secs = 0
    if m === nothing
        throw(ArgumentError("Invalid time period string '$(period)'"))
    end
    for capture in m.captures
        if capture === nothing
            continue
        end
        value = parse(Int, capture[1:end-1])
        total_secs += value * unit_to_seconds[capture[end]]
    end
    return total_secs
end

parse_bool(str) = str == "true" ? true :
                  str == "false" ? false :
                  error("Expected `true` or `false`, got `$str`")

# Parse our timeouts
test_timeout = parse_time_period(get(ENV, "JL_TEST_TIMEOUT", "2h"))
teardown_timeout = parse_time_period(get(ENV, "JL_TEARDOWN_TIMEOUT", "10m"))
kill_timeout = parse_time_period(get(ENV, "JL_KILL_TIMEOUT", "10m"))
do_term = parse_bool(get(ENV, "JL_TERM_SIGTERM", "false"))
do_quit = parse_bool(get(ENV, "JL_TERM_SIGQUIT", "true"))
do_detach = parse_bool(get(ENV, "JL_TERM_DETACH", "false"))

if Sys.iswindows() && do_detach
    error("JL_TERM_DETACH is not available on windows")
end

# Setup logs dir
verbose_logs_dir = mktempdir()
env2 = copy(ENV)
env2["JULIA_TEST_VERBOSE_LOGS_DIR"] = verbose_logs_dir
cmd = setenv(`$(ARGS)`, env2)

# Prepare detach
if do_detach
    # TODO: Should this setpgid only rather than a full setsid?
    cmd = detach(cmd)
end

proc = run(cmd, (stdin, stdout, stderr); wait=false)
proc_pid = try getpid(proc) catch e;
    global do_detach = false
    "<unknown>"
end

kill_proc_or_pgid(sig) = do_detach ? ccall(:kill, Cint, (Cpid_t, Cint), -proc_pid, sig) : kill(proc, sig)

# Set when the watchdog fires, so we know to wait for the teardown of the
# wrapped process' children before exiting
timed_out = Ref(false)

# Whether any process in the wrapped process' group is still alive.
function pg_alive()
    do_detach || return isopen(proc)
    return ccall(:kill, Cint, (Cpid_t, Cint), -proc_pid, 0) == 0
end

# Wait (up to `timeout` seconds) for every process in the group to exit.
# Returns true if the group emptied out, false if the timeout elapsed.
function await_group_exit(timeout)
    deadline = time() + timeout
    while pg_alive() && time() < deadline
        sleep(1)
    end
    return !pg_alive()
end

# Start a watchdog task
timer_task = @async begin
    sleep(test_timeout)

    # If the process is still running, run the escalation pipeline:
    #   SIGTERM -> SIGQUIT -> SIGKILL
    if isopen(proc)
        timed_out[] = true
        pid_or_pgid = do_detach ? "PGID" : "PID"

        # SIGTERM: ask nicely.  The test driver will respond by SIGQUIT-ing the
        # workers that are still running tests, so that we collect core dumps
        # of the processes that are actually stuck (the workers run in detached
        # sessions out of reach of our signals).
        if pg_alive() && do_term
            println(stderr, "\n\nProcess group still alive after $(test_timeout)s; sending SIGTERM to $(pid_or_pgid) $(proc_pid) so the test driver can tear down and core-dump its stuck workers.")
            kill_proc_or_pgid(Base.SIGTERM)
            await_group_exit(teardown_timeout)
        end

        # SIGQUIT: anything that could not tear itself down in response to
        # SIGTERM is wedged (or SIGTERM was skipped); core-dump it.
        if pg_alive() && do_quit
            println(stderr, "\n\nProcess group still alive; sending SIGQUIT to $(pid_or_pgid) $(proc_pid) to core-dump the processes that could not tear themselves down.")
            kill_proc_or_pgid(Base.SIGQUIT)
            await_group_exit(kill_timeout)
        end

        # SIGKILL: if the group still isn't gone (e.g. a core dump is truly
        # stuck), force-kill it.  (The group cannot refuse SIGKILL; this wait
        # just bounds the time until the last member is reaped.)
        if pg_alive()
            println(stderr, "\n\nProcess group still alive; sending SIGKILL to $(pid_or_pgid) $(proc_pid) to force-kill the remaining processes.")
            kill_proc_or_pgid(Base.SIGKILL)
            await_group_exit(kill_timeout)
        end
    end
end

if Base.VERSION >= v"1.7-"
    errormonitor(timer_task)
end

# Wait for the process to finish
wait(proc)

# Wait also for the whole process group to finish, in case anyone is dumping cores, etc.
timed_out[] && wait(timer_task)

# Upload all log files in the `JULIA_TEST_VERBOSE_LOGS_DIR` directory
if is_buildkite
    cd(verbose_logs_dir) do
        for (root, dirs, files) in walkdir(".")
            for file in files
                full_file_path = joinpath(root, file)
                run(`buildkite-agent artifact upload $(full_file_path)`)
            end
        end
    end
end

# Pass the exit code back up, including signals
if proc.termsignal != 0
    ccall(:raise, Cvoid, (Cint,), proc.termsignal)

    # If for some reason the signal did not cause an exit, we'll exit manually.
    # We need to make sure that we exit with a non-zero exit code.
    if proc.exitcode != 0
        exit(proc.exitcode)
    else
        exit(1)
    end
end
exit(proc.exitcode)
