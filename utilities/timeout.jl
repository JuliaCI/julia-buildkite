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
#                         teardown escalation pipeline (SIGTERM, then dumping the detached
#                         descendants, -> SIGQUIT -> SIGKILL).
#                         Defaults to 2 hours.
#  - JL_TEARDOWN_TIMEOUT: How long to wait for the process group to exit after SIGTERM
#                         before escalating, and for the detached descendants to exit after
#                         their SIGQUIT (JL_DUMP_DETACHED).  This covers graceful teardown
#                         work, e.g. `rr` finishing off its recording, or the test workers
#                         writing their core dumps, which can take a long time.
#                         Defaults to 10 minutes.
#  - JL_KILL_TIMEOUT:     How long to wait for the process group to exit after SIGQUIT
#                         (including time spent writing core dumps) before escalating
#                         to SIGKILL.  Defaults to 10 minutes.
#  - JL_TERM_SIGTERM:     Whether to start the escalation with SIGTERM to the wrapped
#                         process alone, never its group, which asks it to finish up: `rr`
#                         then completes its recording.  Not for the Julia test suite: the
#                         wrapped process there is the `Base.runtests` wrapper, which exits
#                         without passing it on, and the test driver below it would react
#                         by signalling its workers from an `atexit` hook, where it no longer
#                         relays their output (see JL_DUMP_DETACHED).  Defaults to false.
#  - JL_TERM_SIGQUIT:     Whether to include the SIGQUIT (coredump) stage.  Defaults to
#                         true.
#  - JL_DUMP_DETACHED:    Unix only: before the SIGQUIT stage, SIGQUIT the descendants of the
#                         wrapped process that are outside its process group, deepest first,
#                         and wait up to JL_TEARDOWN_TIMEOUT for them to exit.  These are the
#                         test workers, which Distributed starts in sessions of their own,
#                         and their children: a group-wide signal cannot reach them.  Doing
#                         this while the test driver still runs lets it relay what they
#                         print (the backtraces of all their tasks) into the log; once the
#                         driver has been signalled it stops reading their output, and a
#                         worker that fills its pipe blocks before it can dump core.  Only
#                         with JL_TERM_SIGQUIT.  Defaults to false.
#  - JL_TEARDOWN_MARKER:  A file to create when the watchdog fires, so that the core dump
#                         reaper of test_julia.sh keeps the cores of the hung processes.
#                         Optional.
#  - JL_DUMP_FOLDER:      64-bit Windows only: before the SIGQUIT stage, write full dumps of
#                         the descendants of the wrapped process (the test workers and their
#                         children) to this folder; see windows/dump_descendants.jl.  It also
#                         has the Julia processes among them print their task backtraces.  The
#                         SIGQUIT there dumps (libuv, with WER LocalDumps configured) and
#                         ends the wrapped process alone, and the rest die with it.  Takes
#                         at most JL_KILL_TIMEOUT or 3 minutes, whichever is shorter.
#                         Optional.
#  - JL_DUMP_COUNT:       How many dumps of the folder are uploaded, oldest first; at most
#                         this many minus those already there minus one for the wrapped
#                         process are written.  Defaults to 1, as the coreupload plugin.
#  - JL_DUMP_RESERVE_GIB: Free disk space, in GiB, below which no more dumps are written.
#                         Defaults to 20.
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
do_dump_detached = parse_bool(get(ENV, "JL_DUMP_DETACHED", "false"))
do_detach = parse_bool(get(ENV, "JL_TERM_DETACH", "false"))
dump_folder = get(ENV, "JL_DUMP_FOLDER", "")
dump_count = parse(Int, get(ENV, "JL_DUMP_COUNT", "1"))
dump_reserve_gib = parse(Int, get(ENV, "JL_DUMP_RESERVE_GIB", "20"))

if Sys.iswindows() && do_detach
    error("JL_TERM_DETACH is not available on windows")
end
if Sys.iswindows() && do_dump_detached
    error("JL_DUMP_DETACHED is not available on windows")
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

# The creation time of process `pid` (a FILETIME), which tells it apart from a later process
# with its PID, or nothing
function process_created(pid)
    handle = ccall((:OpenProcess, "kernel32"), Ptr{Cvoid}, (UInt32, Cint, UInt32),
                   0x1000 #= PROCESS_QUERY_LIMITED_INFORMATION =#, false, pid)
    handle == C_NULL && return nothing
    try
        created, other = Ref{UInt64}(0), Ref{UInt64}(0)
        ccall((:GetProcessTimes, "kernel32"), Cint,
              (Ptr{Cvoid}, Ref{UInt64}, Ref{UInt64}, Ref{UInt64}, Ref{UInt64}),
              handle, created, other, other, other) == 0 && return nothing
        return created[]
    finally
        ccall((:CloseHandle, "kernel32"), Cint, (Ptr{Cvoid},), handle)
    end
end

# The wrapped process' identity for windows/dump_descendants.jl, taken while its PID is
# certainly its own: libuv holds a handle of it until we have seen it exit.
proc_created = Sys.iswindows() && Sys.WORD_SIZE == 64 && !isempty(dump_folder) && proc_pid isa Integer ?
               process_created(proc_pid) : nothing

kill_proc_or_pgid(sig) = do_detach ? ccall(:kill, Cint, (Cpid_t, Cint), -proc_pid, sig) : kill(proc, sig)

# Signal the wrapped process alone, never its group.
kill_proc(sig) = kill(proc, sig)

# Set when the watchdog fires, so we know to wait for the teardown of the
# wrapped process' children before exiting
timed_out = Ref(false)

# Whether any process in the wrapped process' group is still alive.
function pg_alive()
    do_detach || return process_running(proc)
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

# The direct children of `pid`, best effort: it may exit while we look.
function child_pids(pid)
    children = Int[]
    try
        if Sys.islinux()
            for tid in readdir("/proc/$pid/task")
                append!(children, parse.(Int, split(read("/proc/$pid/task/$tid/children", String))))
            end
        else
            # `pgrep -P` exits non-zero when there are no matches
            append!(children, parse.(Int, split(read(ignorestatus(`pgrep -P $pid`), String))))
        end
    catch
    end
    return children
end

getpgid(pid) = ccall(:getpgid, Cpid_t, (Cpid_t,), pid)

# The live descendants of `root` outside its process group, and everything below them,
# deepest first: the processes that a signal to the group misses.
function detached_descendants(root)
    group = getpgid(root)
    found = Int[]
    queue = [(root, false)]
    while !isempty(queue)
        pid, detached = popfirst!(queue)
        for child in child_pids(pid)
            child_group = getpgid(child)
            child_group == -1 && continue   # gone
            child_detached = detached || child_group != group
            child_detached && push!(found, child)
            push!(queue, (child, child_detached))
        end
    end
    return reverse!(found)
end

# Whether `pid` is still running.  A process that has exited is a zombie until its parent
# reaps it, and signal 0 still reaches a zombie; on Linux, check its state instead.
function running(pid)
    if Sys.islinux()
        stat = try
            read("/proc/$pid/stat", String)
        catch
            return false
        end
        # the state is the field after the parenthesised command name
        return split(stat[something(findlast(')', stat), 0)+1:end])[1] != "Z"
    end
    return ccall(:kill, Cint, (Cpid_t, Cint), pid, 0) == 0
end

# SIGQUIT the descendants that our group signals cannot reach, while the test driver is
# still alive to relay their output, and wait up to `timeout` seconds for them to exit.  A
# wedged process can swallow a SIGQUIT without dumping: a repeated SIGQUIT makes Julia
# raise it for a kernel core dump, and SIGABRT covers processes that ignore SIGQUIT.
function dump_detached(timeout)
    pids = filter(pid -> ccall(:kill, Cint, (Cpid_t, Cint), pid, Base.SIGQUIT) == 0,
                  detached_descendants(proc_pid))
    isempty(pids) && return
    println(stderr, "\n\nSent SIGQUIT to the $(length(pids)) process(es) outside the process group of PID $(proc_pid), deepest first (the test workers and their children: PIDs $(join(pids, ", "))), so that they print their backtraces and core-dump while the test driver still relays their output.")
    SIGABRT = 6
    resignal = [(30, Base.SIGQUIT), (60, SIGABRT), (90, SIGABRT)]
    start = time()
    while any(running, pids) && time() - start < timeout
        sleep(1)
        if !isempty(resignal) && time() - start >= resignal[1][1]
            after, sig = popfirst!(resignal)
            for pid in filter(running, pids)
                ccall(:kill, Cint, (Cpid_t, Cint), pid, sig) == 0 || continue
                println(stderr, "Process $(pid) is still running $(after)s after SIGQUIT; re-signalling it with signal $(sig) to force a core dump.")
            end
        end
    end
    left = filter(running, pids)
    isempty(left) || println(stderr, "Processes still running after $(timeout)s: $(join(left, ", ")).")
end

# Dump the descendants of the wrapped process on Windows, in a helper process that we stop
# after `timeout` seconds, so that a stuck dump cannot hold up the escalation.  The uploader
# takes the oldest `dump_count` dumps of the folder; the last of those is the wrapped
# process' own.
function dump_descendants(timeout)
    # names the helper's incomplete dumps
    token = "timeout-$(getpid())"
    helper = joinpath(@__DIR__, "windows", "dump_descendants.jl")
    try
        existing = count(name -> endswith(name, ".dmp"), readdir(dump_folder))
        budget = max(0, dump_count - 1 - existing)
        cmd = `$(Base.julia_cmd()) --startup-file=no $(helper) $(proc_pid) $(proc_created) $(dump_folder) $(budget) $(dump_reserve_gib) $(token)`
        if budget == 0
            println(stderr, "\n\nProcess still alive; not dumping its descendants, no upload slot is left for them (the uploader takes $(dump_count) dumps, $(existing) are there, and PID $(proc_pid)'s comes next).  Having them print their task backtraces first, for at most $(timeout)s.")
        else
            println(stderr, "\n\nProcess still alive; dumping up to $(budget) of its descendants and having them print their task backtraces first, for at most $(timeout)s.")
        end
        helper_proc = run(pipeline(cmd; stdin=devnull, stdout=stderr, stderr=stderr); wait=false)
        if timedwait(() -> !process_running(helper_proc), timeout) != :ok
            println(stderr, "Dumping the descendants took longer than $(timeout)s; stopping.")
            kill(helper_proc, Base.SIGKILL)
            wait(helper_proc)
            for name in readdir(dump_folder)
                endswith(name, ".$(token).partial") && rm(joinpath(dump_folder, name); force=true)
            end
        end
    catch err
        @warn "Unable to dump the descendants of PID $(proc_pid)" exception=err
    end
end

# Start a watchdog task
timer_task = @async begin
    sleep(test_timeout)

    # If the process is still running, run the escalation pipeline:
    #   SIGTERM -> SIGQUIT of the detached descendants -> SIGQUIT -> SIGKILL
    if process_running(proc)
        timed_out[] = true
        pid_or_pgid = do_detach ? "PGID" : "PID"
        # best effort: the escalation below must run regardless
        marker = get(ENV, "JL_TEARDOWN_MARKER", "")
        try
            isempty(marker) || touch(marker)
        catch err
            @warn "Unable to create the teardown marker; core dumps beyond the first few may be deleted" marker exception=err
        end

        # SIGTERM: ask nicely.
        if pg_alive() && do_term
            println(stderr, "\n\nProcess group still alive after $(test_timeout)s; sending SIGTERM to PID $(proc_pid) so that it can finish up.")
            kill_proc(Base.SIGTERM)
            await_group_exit(teardown_timeout)
        end

        # The test workers, out of reach of the group signals below; first, so that the
        # test driver relays their backtraces.
        if do_dump_detached && do_quit && pg_alive()
            dump_detached(teardown_timeout)
        end

        # Windows has no SIGTERM stage or process groups, and SIGQUIT dumps the test
        # driver alone.
        if proc_created !== nothing && pg_alive() && do_quit
            dump_descendants(min(kill_timeout, 180))
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
