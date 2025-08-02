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

# Check if --term option is passed
use_sigterm = false
args_to_pass = ARGS
if length(ARGS) > 0 && ARGS[1] == "--term"
    use_sigterm = true
    args_to_pass = ARGS[2:end]
end

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

verbose_logs_dir = mktempdir()
env2 = copy(ENV)
env2["JULIA_TEST_VERBOSE_LOGS_DIR"] = verbose_logs_dir
cmd = setenv(`$(args_to_pass)`, env2)

# Start our child process
proc = run(cmd, (stdin, stdout, stderr); wait=false)
proc_pid = try getpid(proc) catch; "<unknown>" end

# Start a watchdog task
timer_task = @async begin
    sleep(term_timeout)

    # If the process is still running, ask it nicely to terminate
    if isopen(proc)
        if use_sigterm
            println(stderr, "\n\nProcess failed to exit within $(term_timeout)s, requesting termination (SIGTERM) of PID $(proc_pid).")
            kill(proc, Base.SIGTERM)
            println(stderr, "\n\nSent SIGTERM to PID $(proc_pid).")
        else
            println(stderr, "\n\nProcess failed to exit within $(term_timeout)s, requesting termination and coredump (SIGQUIT) of PID $(proc_pid).")
            
            # On Linux, recursively find and signal all descendant processes
            if Sys.islinux()
                # Function to recursively find all descendant PIDs
                function get_all_descendants(pid)
                    descendants = Int[]
                    
                    # Check all task subdirectories (including the main thread)
                    task_dir = "/proc/$(pid)/task"
                    if isdir(task_dir)
                        for task in readdir(task_dir)
                            children_file = joinpath(task_dir, task, "children")
                            if isfile(children_file)
                                try
                                    children_str = read(children_file, String)
                                    if !isempty(strip(children_str))
                                        child_pids = parse.(Int, split(strip(children_str)))
                                        for child in child_pids
                                            if !(child in descendants)
                                                # Recursively get descendants of this child
                                                child_descendants = get_all_descendants(child)
                                                append!(descendants, child_descendants)
                                                push!(descendants, child)
                                            end
                                        end
                                    end
                                catch e
                                    # Process/thread might have exited, ignore
                                end
                            end
                        end
                    end
                    
                    return unique(descendants)
                end
                
                # Get all descendant PIDs
                all_pids = get_all_descendants(proc_pid)
                push!(all_pids, proc_pid)  # Add the root process at the end
                
                # Filter to only include actual processes (not threads)
                # In Linux, a process has PID == TGID, while threads have PID != TGID
                process_pids = filter(all_pids) do pid
                    try
                        status = read("/proc/$(pid)/status", String)
                        # Extract Tgid from status file
                        m = match(r"Tgid:\s*(\d+)", status)
                        if m !== nothing
                            tgid = parse(Int, m.captures[1])
                            return pid == tgid  # True for processes, false for threads
                        end
                        return true  # If we can't determine, assume it's a process
                    catch
                        # Process might have exited
                        return false
                    end
                end
                
                # Send SIGQUIT to all processes (leaf processes first, root last)
                println(stderr, "\n\nSending SIGQUIT to $(length(process_pids)) processes...")
                for pid in process_pids
                    try
                        ccall(:kill, Cint, (Cint, Cint), pid, Base.SIGQUIT)
                        println(stderr, "Sent SIGQUIT to PID $(pid).")
                    catch e
                        # Process might have already exited
                    end
                end
            else
                # For non-Linux systems, just send SIGQUIT to the main process
                kill(proc, Base.SIGQUIT)
                println(stderr, "\n\nSent SIGQUIT to PID $(proc_pid).")
            end
        end

        # If the process doesn't stop after a further `kill_timeout`, force-kill it
        sleep(kill_timeout)
        if isopen(proc)
            println(stderr, "\n\nProcess failed to cleanup within $(kill_timeout)s, force-killing (SIGKILL) PID $(proc_pid)!")
            kill(proc, Base.SIGKILL)
            println(stderr, "\n\nSent SIGKILL to PID $(proc_pid).")
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
