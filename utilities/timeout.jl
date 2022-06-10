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


# Parse our timeouts
term_timeout = parse_time_period(get(ENV, "JL_TERM_TIMEOUT", "2h"))
kill_timeout = parse_time_period(get(ENV, "JL_KILL_TIMEOUT", "30m"))

# Start our child process
proc = run(`$(ARGS)`, (stdin, stdout, stderr); wait=false)

# Start a watchdog task
timer_task = @async begin
    sleep(term_timeout)
    
    # If the process is still running, ask it nicely to terminate
    if isopen(proc)
        println(stderr, "\n\nProcess failed to exit within $(term_timeout)s, requesting termination.")
        kill(proc, Base.SIGTERM)

        # If the process doesn't stop after a further `kill_timeout`, force-kill it
        sleep(kill_timeout)
        if isopen(proc)
            println(stderr, "\n\nProcess failed to cleanup within $(kill_timeout)s, force-killing!")
            kill(proc, Base.SIGKILL)
            exit(1)
        end
    end
end

if Base.VERSION >= v"1.7-"
    errormonitor(timer_task)
end

# Wait for the process to finish
wait(proc)

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
