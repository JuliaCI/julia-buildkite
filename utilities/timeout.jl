# Usage:    julia timeout.jl [args...]
#
# Wraps an execution within a timer that will kill the command after the given time period.
# We accept timeout arguments via environment variables to avoid having to implement argument
# parsing in CI scripts.  Note that all time periods are expressed as compound values with
# suffixes, e.g. "2h30m".  All suffixes are required.
#
# Relevant environment variables:
#
#  - JL_TERM_TIMEOUT: How long to wait for a task to complete before sending a SIGTERM signal.
#                     Defaults to 2 hours.
#  - JL_KILL_TIMEOUT: How long to wait (after the JL_TERM_TIMEOUT) before sending SIGKILL.
#                     Defaults to 30 minutes.
#
# Example:
#   - JL_TERM_TIMEOUT=2h30m JL_KILL_TIMEOUT=600s julia timeout.jl cmd...

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
                  errror("Expected `true` or `false`, got `$str`")

# Parse our timeouts
term_timeout = parse_time_period(get(ENV, "JL_TERM_TIMEOUT", "2h"))
kill_timeout = parse_time_period(get(ENV, "JL_KILL_TIMEOUT", "30m"))
do_term = parse_bool(get(ENV, "JL_TERM_SIGTERM", "false"))
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

# Start a watchdog task
timer_task = @async begin
    sleep(term_timeout)

    # If the process is still running, ask it nicely to terminate
    if isopen(proc)
        pid_or_pgid = do_detach ? "PGID" : "PID"
        signame = do_term ? "(SIGTERM)" : "and coredump (SIGQUIT)"
        println(stderr, "\n\nProcess failed to exit within $(term_timeout)s, requesting termination $signame of $pid_or_pgid $(proc_pid).")
        kill_proc_or_pgid(do_term ? Base.SIGTERM : Base.SIGQUIT)
        println(stderr, "\n\nSent termination signal to $pid_or_pgid $(proc_pid).")

        # If the process doesn't stop after a further `kill_timeout`, force-kill it
        sleep(kill_timeout)
        if isopen(proc)
            println(stderr, "\n\nProcess failed to cleanup within $(kill_timeout)s, force-killing (SIGKILL) $pid_or_pgid $(proc_pid)!")
            kill_proc_or_pgid(Base.SIGKILL)
            println(stderr, "\n\nSent SIGKILL to $pid_or_pgid $(proc_pid).")
            exit(1)
        end
    end
end

if Base.VERSION >= v"1.7-"
    errormonitor(timer_task)
end

# Wait for the process to finish
wait(proc)

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
