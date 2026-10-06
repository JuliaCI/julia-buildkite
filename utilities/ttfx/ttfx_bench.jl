# Benchmark driver for the TTFX CI job: runs Julia-TTFX-Snippets tasks under one or more
# julia builds ("arms"), interleaved, and writes one record per task, arm and block.
# Derived from analysis/benchmark.jl in IanButterworth/Julia-TTFX-Snippets, with juliaup
# channels replaced by install trees so it runs on an agent.
#
#   julia --startup-file=no ttfx_bench.jl [options] LABEL=/path/to/julia-tree ...
#
#   --tasks DIR          the snippets checkout's tasks/ directory (required)
#   --exclude FILE       Package/Task names to skip, one per line, # comments
#   --depot DIR          depot shared by every arm: packages and artifacts are reused,
#                        compiled code is cleared before every sample (default: temporary)
#   --workdir DIR        per-arm copies of the task projects go here (default: temporary)
#   --logdir DIR         full output of every failed subprocess is kept here
#   --tracedir DIR       keep the --trace-compile --trace-compile-timing output of one extra,
#                        untimed run of each task script per arm, after the timed repeats of
#                        block 1, as DIR/<Package>-<Task>-<arm>.log
#   --blocks N           ABBA blocks: every task is measured N times per arm, the arm order
#                        reversed on alternate blocks (default 2)
#   --repeats N          task script runs per sample; the first is the cold one, later ones
#                        may hit caches it populated (default 3)
#   --timeout S          wall-clock limit per subprocess, seconds (default 1800)
#   --results FILE       records (default results.json)
#   --meta FILE          provenance (default results-meta.json)
#   --snippets-commit X  recorded in the metadata
#
# Records: {arm, package, task, block, order, status, error, precompile_time, load_times,
# run_times, total_times, load_stats, run_stats, load_times_gcoff, run_times_gcoff,
# total_times_gcoff, load_stats_gcoff, run_stats_gcoff, gc_after_load, error_gcoff,
# packages_hash}. `order` is the arm's position within the block.
# A task that fails on any arm finishes the current block, so every arm gets its one try,
# and skips the remaining blocks: a broken package does not cost the whole ABBA.
# The task script prints "load, run, total seconds"; the `*_times` arrays keep every
# repeat in run order, and `*_stats` what `@time` would have added for the phase: gc time
# and pauses, allocation, compilation and recompilation time (see instrument_task). The
# `*_gcoff` fields are a second set of repeats with the GC disabled for both phases and
# one forced collection between them (`gc_after_load`, seconds, excluded from both), so
# load and run can be read without GC pauses landing in them; a failure there is kept in
# `error_gcoff` and does not affect `status`. `packages_hash` identifies the resolved
# package versions so a comparison can tell a build difference from a resolution
# difference.

using Dates, Printf, SHA, TOML
include(joinpath(@__DIR__, "ttfx_json.jl"))
using .TTFXJSON

struct Arm
    label::String
    root::String
    julia::String
end

struct TaskInfo
    dir::String
    package::String
    task::String
end

function parse_args(args)
    opts = Dict{String,Any}(
        "tasks" => nothing, "exclude" => nothing, "depot" => nothing, "workdir" => nothing, "logdir" => nothing,
        "tracedir" => nothing,
        "blocks" => "2", "repeats" => "3", "timeout" => "1800",
        "results" => "results.json", "meta" => "results-meta.json", "snippets-commit" => "")
    arms = Arm[]
    i = 1
    while i <= length(args)
        a = args[i]
        if startswith(a, "--")
            key = a[3:end]
            haskey(opts, key) || error("unknown option $a")
            i += 1
            i <= length(args) || error("$a needs a value")
            opts[key] = args[i]
        else
            m = match(r"^([A-Za-z0-9_.+-]+)=(.+)$", a)
            m === nothing && error("expected LABEL=/path/to/julia-tree, got $(repr(a))")
            root = abspath(m.captures[2])
            julia = joinpath(root, "bin", "julia")
            isfile(julia) || error("no julia at $julia")
            push!(arms, Arm(m.captures[1], root, julia))
        end
        i += 1
    end
    isempty(arms) && error("no arms given")
    opts["tasks"] === nothing && error("--tasks is required")
    return opts, arms
end

function find_tasks(tasks_dir::String)::Vector{TaskInfo}
    tasks = TaskInfo[]
    for (root, _, files) in walkdir(tasks_dir)
        if "task.jl" ∈ files && "Project.toml" ∈ files
            parts = splitpath(relpath(root, tasks_dir))
            length(parts) == 3 || continue  # letter/package/task-name
            push!(tasks, TaskInfo(root, parts[2], parts[3]))
        end
    end
    return sort!(tasks, by = t -> (t.package, t.task))
end

# Every task but the excluded ones; also returns excluded names the checkout no longer has.
function select_tasks(all::Vector{TaskInfo}, excludefile::Union{Nothing,String})
    excludefile === nothing && return all, String[]
    excluded = String[]
    for line in eachline(excludefile)
        name = strip(first(split(line, '#')))
        isempty(name) || push!(excluded, name)
    end
    names = Set(t.package * "/" * t.task for t in all)
    return filter(t -> (t.package * "/" * t.task) ∉ excluded, all), filter(n -> n ∉ names, excluded)
end

# Compiled code and the JIT object cache go before every sample, so every sample of every
# arm starts from the same cold state; packages and artifacts stay.
function clear_compiled!(depot::String)
    for sub in ("compiled", "cache")
        d = joinpath(depot, sub)
        isdir(d) && rm(d; recursive = true)
    end
end

# Only the JIT object cache, so a second set of repeats starts as cold as the first did
# without precompiling again.
function clear_objcache!(depot::String)
    d = joinpath(depot, "cache")
    isdir(d) && rm(d; recursive = true)
end

# The depot goes first, followed by the arm's own stdlib caches. The default depot path
# is deliberately not appended: the agent user's ~/.julia could otherwise supply
# packages and compiled code from earlier jobs to one arm and not the other.
function arm_env(arm::Arm, depot::String)
    sep = Sys.iswindows() ? ';' : ':'
    depot_path = join([depot, joinpath(arm.root, "local", "share", "julia"),
                       joinpath(arm.root, "share", "julia")], sep)
    return ("JULIA_DEPOT_PATH" => depot_path,)
end

# Run a subprocess capturing stdout and stderr under `timeout` seconds. Returns
# (stdout, stderr, succeeded, timed_out). SIGINT first so a precompile driver can stop
# its workers, SIGTERM 30s later.
function run_timed(cmd::Cmd, timeout::Float64)
    err = IOBuffer()
    proc = open(pipeline(cmd; stderr = err), "r")
    timed_out = Ref(false)
    interrupt = Timer(timeout) do _
        timed_out[] = true
        process_running(proc) && kill(proc, Base.SIGINT)
    end
    terminate = Timer(timeout + 30) do _
        process_running(proc) && kill(proc)
    end
    out = try
        read(proc, String)
    finally
        close(interrupt); close(terminate)
    end
    wait(proc)
    return out, String(take!(err)), success(proc) && !timed_out[], timed_out[]
end

# Where the full output of failed subprocesses goes; the record keeps only a summary.
const LOGDIR = Ref{Union{Nothing,String}}(nothing)

function failure_message(what, out, err, timed_out, timeout; logname = nothing)
    why = timed_out ? "$what timed out after $(timeout)s" : "$what failed"
    lines = filter(!isempty, strip.(split(err, '\n')))
    msg = isempty(lines) ? why : why * ": " * join(last(lines, min(5, length(lines))), " | ")
    if LOGDIR[] !== nothing && logname !== nothing
        mkpath(LOGDIR[])
        path = joinpath(LOGDIR[], logname * ".log")
        write(path, "--- stdout ---\n" * out * "\n--- stderr ---\n" * err)
        msg *= " (full output in $(basename(path)))"
    end
    return msg
end

# Identify the build behind an arm. Read through the binary itself, so what is recorded is
# what ran.
function build_info(arm::Arm, timeout::Float64)
    code = """
    let g = Base.GIT_VERSION_INFO
        join(stdout, [string(VERSION), g.commit, g.commit_short, g.date_string, g.branch,
                      Sys.MACHINE, string(Sys.CPU_THREADS)], '\\n')
    end"""
    out, err, ok, timed_out = run_timed(`$(arm.julia) --startup-file=no -e $code`, timeout)
    ok || error("$(arm.label): " * failure_message("probing $(arm.julia)", out, err, timed_out, timeout))
    f = split(out, '\n')
    length(f) == 7 || error("$(arm.label): unexpected probe output $(repr(out))")
    return (; label = arm.label, root = arm.root, version = f[1], commit = f[2],
              commit_short = f[3], commit_date = f[4], branch = f[5], machine = f[6],
              # What this build sees, and so how many precompile workers it uses by default
              cpu_threads = parse(Int, f[7]))
end

function try_read(cmd::Cmd)
    out, _, ok, _ = run_timed(cmd, 60.0)
    return ok ? strip(out) : ""
end

function system_info()
    cpus = Sys.cpu_info()
    return (; hostname = gethostname(),
              cpu = isempty(cpus) ? "unknown" : strip(cpus[1].model),
              cpu_threads = Sys.CPU_THREADS,
              total_memory_gb = round(Sys.total_memory() / 2^30; digits = 1),
              machine = Sys.MACHINE,
              uname = try_read(`uname -sr`),
              load_avg = try_read(`uptime`),
              driver_julia = string(VERSION))
end

# The job that produced the data, for whoever fetches the artifact later.
buildkite_info() = Dict(lowercase(k[11:end]) => v for (k, v) in ENV
    if k in ("BUILDKITE_PIPELINE_SLUG", "BUILDKITE_BUILD_NUMBER", "BUILDKITE_BUILD_URL",
             "BUILDKITE_JOB_ID", "BUILDKITE_COMMIT", "BUILDKITE_BRANCH",
             "BUILDKITE_PULL_REQUEST", "BUILDKITE_PULL_REQUEST_BASE_BRANCH", "BUILDKITE_AGENT_NAME"))

# Hash of the resolved (non-stdlib) package versions, so a comparison can tell a build
# difference from a resolution difference between arms.
function packages_hash(project_dir::String)
    mf = joinpath(project_dir, "Manifest.toml")
    isfile(mf) || return nothing
    deps = get(TOML.parsefile(mf), "deps", Dict{String,Any}())
    entries = String[]
    for (name, list) in deps, e in list
        haskey(e, "git-tree-sha1") && push!(entries, name * "@" * get(e, "version", "") * "#" * e["git-tree-sha1"])
    end
    return bytes2hex(sha256(join(sort!(entries), '\n')))[1:12]
end

# Resolve and download the task's packages for one arm, without precompiling. Each arm
# gets its own copy of the project, so each resolves as a user of that build would.
function instantiate(arm::Arm, depot::String, proj::String, timeout::Float64, logname::String)
    code = "using Pkg; Pkg.instantiate()"
    cmd = addenv(`$(arm.julia) --startup-file=no --project=$proj -e $code`,
                 arm_env(arm, depot)..., "JULIA_PKG_PRECOMPILE_AUTO" => "0")
    out, err, ok, timed_out = run_timed(cmd, timeout)
    ok || return failure_message("instantiate", out, err, timed_out, timeout; logname = logname * "-instantiate")
    return nothing
end

# The snippets mark their phases with `__t1 = time()` (before `using`), `__t2 = time()`
# (after it) and `__t3 = time()` (after the work). Write a copy of the script that also
# snapshots the GC and compile-time counters at each marker and prints the per-phase
# differences as one JSON line, so every timed run records what `@time` reports besides
# wall time: gc time and pauses, allocation, compilation and recompilation time.
# `Base.cumulative_compile_timing(true)` is what `@time` enables too.
#
# With `TTFX_GC=off` in the environment the same script disables the GC before the first
# marker and forces one full collection right after the second, so load runs without GC
# pauses and run starts from a collected heap without any; the collection's time is
# reported as `gc_after_load` and kept out of both phases by shifting `__t1` by as much
# as `__t2` moves.
#
# Nothing may be added inside a timed window. Every toplevel expression of a script is
# lowered and evaluated on its own, a fraction of a millisecond each, so a statement of
# its own between the markers is a fixed cost on every task and a 10 to 25 percent
# regression on the tasks whose run is a few milliseconds. Each addition is therefore
# part of its marker's own expression, before the clock that opens a window or after the
# one that closes it. Nothing may be compiled before `__t1` either: the first native
# compile initializes the JIT, a cost a user's `using` pays and load must keep. What
# remains is the second marker's block being lowered inside the load window, about a
# quarter of a millisecond against loads of tens of milliseconds and up.
#
# The original `task.jl` is left alone, and a script without exactly these markers runs
# as it is.
const PHASE_MARKERS = ("__t1 = time()", "__t2 = time()", "__t3 = time()")
const STATS_PREFIX = "__TTFX_STATS__:"

function instrument_task(proj::String)
    script = joinpath(proj, "task.jl")
    src = read(script, String)
    all(m -> count(m, src) == 1, PHASE_MARKERS) || return script, false
    snapshot(name) = "$name = (Base.gc_num(), Base.cumulative_compile_time_ns())"
    src = replace(src,
        PHASE_MARKERS[1] => "begin " * snapshot("__ttfx_s1") * "; " * PHASE_MARKERS[1] * " end",
        PHASE_MARKERS[2] => """
        begin
            $(snapshot("__ttfx_s2"))
            __ttfx_gc_after_load = 0.0
            __ttfx_s2r = __ttfx_s2
            if __ttfx_gc_off
                __ttfx_t = time()
                GC.enable(true); GC.gc(); GC.enable(false)
                __ttfx_gc_after_load = time() - __ttfx_t
                __t1 += __ttfx_gc_after_load
                $(snapshot("__ttfx_s2r"))
            end
            $(PHASE_MARKERS[2])
        end""",
        PHASE_MARKERS[3] => PHASE_MARKERS[3] * "\n" * snapshot("__ttfx_s3"))
    src = "const __ttfx_gc_off = get(ENV, \"TTFX_GC\", \"\") == \"off\"\n" *
          "Base.cumulative_compile_timing(true)\n__ttfx_gc_off && GC.enable(false)\n" * src * "\n" * """
    __ttfx_gc_off && GC.enable(true)
    let stats(a, b) = (d = Base.GC_Diff(b[1], a[1]);
            "{\\"gc_time\\":\$(d.total_time / 1e9),\\"gc_pauses\\":\$(d.pause),\\"gc_full\\":\$(d.full_sweep),\\"allocd\\":\$(d.allocd)," *
            "\\"compile_time\\":\$((b[2][1] - a[2][1]) / 1e9),\\"recompile_time\\":\$((b[2][2] - a[2][2]) / 1e9)}")
        println(stdout, "$STATS_PREFIX{\\"gc_off\\":\$__ttfx_gc_off,\\"gc_after_load\\":\$__ttfx_gc_after_load,\\"load\\":",
                stats(__ttfx_s1, __ttfx_s2), ",\\"run\\":", stats(__ttfx_s2r, __ttfx_s3), "}")
    end
    """
    instrumented = joinpath(proj, "task_ttfx.jl")
    write(instrumented, src)
    return instrumented, true
end

# The task script once more, after the timed runs so it warms nothing they measure, with
# --trace-compile --trace-compile-timing writing every method the process compiles, and
# how long each took, to `tracefile`. A failed run (a build without --trace-compile-timing,
# say) is noted at the end of the file and does not touch the record.
function trace_compile(arm::Arm, env, proj::String, script::String, timeout::Float64, tracefile::String, logname::String)
    mkpath(dirname(tracefile))
    rm(tracefile; force = true)
    cmd = addenv(`$(arm.julia) --startup-file=no --project=$proj --trace-compile=$tracefile --trace-compile-timing $script`, env...)
    out, err, ok, timed_out = run_timed(cmd, timeout)
    ok || open(io -> println(io, "# ", failure_message("trace run", out, err, timed_out, timeout; logname = logname * "-trace")), tracefile, "a")
    statements = isfile(tracefile) ? count(contains("precompile("), eachline(tracefile)) : 0
    return (; file = tracefile, statements, ok)
end

# One sample: clear the caches, precompile the project, then run the task script
# `repeats` times in fresh processes. With `tracefile`, the script runs once more after
# them, untimed and instrumented (trace_compile).
function measure(arm::Arm, depot::String, proj::String, script::String, repeats::Int, timeout::Float64, logname::String;
                 tracefile::Union{Nothing,String} = nothing)
    clear_compiled!(depot)
    env = arm_env(arm, depot)
    precomp_code = "using Pkg; t = @elapsed Pkg.precompile(); print(\"__TTFX_T__:\", t)"
    out, err, ok, timed_out = run_timed(
        addenv(`$(arm.julia) --startup-file=no --project=$proj -e $precomp_code`,
               env..., "JULIA_PKG_PRECOMPILE_AUTO" => "0"), timeout)
    ok || return (; status = "error", error = failure_message("precompile", out, err, timed_out, timeout; logname = logname * "-precompile"))
    pm = match(r"__TTFX_T__:([\d.eE+-]+)", out)
    pm === nothing && return (; status = "error", error = "could not parse precompile time from $(repr(out))")
    precompile_time = parse(Float64, pm.captures[1])

    task_cmd = addenv(`$(arm.julia) --startup-file=no --project=$proj $script`, env...)
    r = run_repeats(task_cmd, repeats, timeout, logname * "-task")
    status = length(r.load) == repeats ? "ok" : isempty(r.load) ? "error" : "partial"
    # The GC-off repeats only exist for an instrumented script (the env var does nothing
    # to a plain task.jl), and are skipped once the normal ones failed. The object cache
    # the normal repeats filled goes first, so their first repeat is as cold as the
    # normal first repeat was.
    g = nothing
    if script != joinpath(proj, "task.jl") && status != "error"
        clear_objcache!(depot)
        g = run_repeats(addenv(task_cmd, "TTFX_GC" => "off"), repeats, timeout, logname * "-gcoff")
    end
    trace = tracefile === nothing || isempty(r.load) ? nothing :
        trace_compile(arm, env, proj, script, timeout, tracefile, logname)
    return (; status, error = status == "ok" ? nothing : r.err, precompile_time,
              load_times = r.load, run_times = r.run, total_times = r.total,
              load_stats = r.load_stats, run_stats = r.run_stats,
              load_times_gcoff = g === nothing ? Float64[] : g.load,
              run_times_gcoff = g === nothing ? Float64[] : g.run,
              total_times_gcoff = g === nothing ? Float64[] : g.total,
              load_stats_gcoff = g === nothing ? Any[] : g.load_stats,
              run_stats_gcoff = g === nothing ? Any[] : g.run_stats,
              gc_after_load = g === nothing ? Float64[] : g.gc_after_load,
              error_gcoff = g === nothing || length(g.load) == repeats ? nothing : g.err,
              trace)
end

# The task script `repeats` times in fresh processes, stopping at the first failure.
function run_repeats(task_cmd::Cmd, repeats::Int, timeout::Float64, logname::String)
    load, run, total, gc_after_load = Float64[], Float64[], Float64[], Float64[]
    load_stats, run_stats = Any[], Any[]
    err_msg = ""
    for _ in 1:repeats
        out, err, ok, timed_out = run_timed(task_cmd, timeout)
        m = match(r"([\d.]+),\s*([\d.]+),\s*([\d.]+)\s+seconds", out)
        if m === nothing || !ok
            err_msg = failure_message("task", out, err, timed_out, timeout; logname = logname * "$(length(load) + 1)")
            break
        end
        lt, rt, tt = parse.(Float64, m.captures)
        push!(load, lt); push!(run, rt); push!(total, tt)
        sm = match(Regex("^" * STATS_PREFIX * raw"(\{.*\})$", "m"), out)
        if sm !== nothing
            st = json_parse(sm.captures[1])
            push!(load_stats, st["load"]); push!(run_stats, st["run"])
            push!(gc_after_load, Float64(st["gc_after_load"]))
        end
    end
    return (; load, run, total, load_stats, run_stats, gc_after_load, err = err_msg)
end

function main()
    opts, arms = parse_args(ARGS)
    blocks = parse(Int, opts["blocks"])
    repeats = parse(Int, opts["repeats"])
    timeout = parse(Float64, opts["timeout"])
    depot = something(opts["depot"], mktempdir(; prefix = "ttfx-depot-"))
    workdir = something(opts["workdir"], mktempdir(; prefix = "ttfx-work-"))
    mkpath(depot); mkpath(workdir)
    LOGDIR[] = opts["logdir"]
    tracedir = opts["tracedir"]

    all_tasks = find_tasks(abspath(opts["tasks"]))
    tasks, stale = select_tasks(all_tasks, opts["exclude"])
    for n in stale
        println("NOTE: excluded task $n is not in the snippets checkout")
    end
    isempty(tasks) && error("no tasks to run")

    builds = Dict(arm.label => build_info(arm, timeout) for arm in arms)
    meta = (; timestamp = string(Dates.now(Dates.UTC)) * "Z",
              arms = builds,
              arm_order = [arm.label for arm in arms],
              system = system_info(),
              settings = (; blocks, repeats, timeout_s = timeout, depot, n_tasks = length(tasks),
                            tasks = [t.package * "/" * t.task for t in tasks],
                            excluded = filter(∉(stale), opts["exclude"] === nothing ? String[] :
                                              [strip(first(split(l, '#'))) for l in eachline(opts["exclude"])])),
              snippets = (; commit = opts["snippets-commit"]),
              buildkite = buildkite_info())
    write(opts["meta"], json_write(meta) * "\n")

    sys = meta.system
    println("Machine: $(sys.hostname)  $(sys.cpu)  $(sys.cpu_threads) threads  $(sys.total_memory_gb) GiB  $(sys.uname)")
    for arm in arms
        b = builds[arm.label]
        println("  $(rpad(arm.label, 8)) $(b.version)  $(b.commit_short)  $(b.commit_date)  sees $(b.cpu_threads) CPU threads")
    end
    println("$(length(tasks)) tasks, $blocks blocks (ABBA), $repeats repeats, timeout $(timeout)s")
    println("Load at start: $(sys.load_avg)")
    flush(stdout)

    records = Any[]
    write_results() = write(opts["results"], json_write(records) * "\n")

    for task in tasks
        label = task.package * "/" * task.task
        println("--- $label")
        flush(stdout)
        projs = Dict{String,String}()
        scripts = Dict{String,String}()
        failed = Dict{String,String}()
        for arm in arms
            proj = joinpath(workdir, "tasks", arm.label, task.package, task.task)
            rm(proj; recursive = true, force = true)
            mkpath(dirname(proj))
            cp(task.dir, proj)
            projs[arm.label] = proj
            msg = instantiate(arm, depot, proj, timeout, "$(task.package)-$(task.task)-$(arm.label)")
            msg === nothing || (failed[arm.label] = "instantiate: " * msg)
            scripts[arm.label], instrumented = instrument_task(proj)
            instrumented || arm !== first(arms) ||
                println("  note: task.jl does not use the standard phase markers, so no per-phase gc/compile stats")
        end
        stop = false
        for block in 1:blocks
            stop && break
            order = isodd(block) ? arms : reverse(arms)
            for (pos, arm) in enumerate(order)
                result = if haskey(failed, arm.label)
                    (; status = "error", error = failed[arm.label])
                else
                    try
                        measure(arm, depot, projs[arm.label], scripts[arm.label], repeats, timeout, "$(task.package)-$(task.task)-$(arm.label)-b$block";
                                tracefile = tracedir === nothing || block != 1 ? nothing :
                                    joinpath(tracedir, "$(task.package)-$(task.task)-$(arm.label).log"))
                    catch e
                        (; status = "error", error = sprint(showerror, e))
                    end
                end
                rec = (; arm = arm.label, package = task.package, task = task.task, block, order = pos,
                         status = result.status, error = get(result, :error, nothing),
                         precompile_time = get(result, :precompile_time, nothing),
                         load_times = get(result, :load_times, Float64[]),
                         run_times = get(result, :run_times, Float64[]),
                         total_times = get(result, :total_times, Float64[]),
                         load_stats = get(result, :load_stats, Any[]),
                         run_stats = get(result, :run_stats, Any[]),
                         load_times_gcoff = get(result, :load_times_gcoff, Float64[]),
                         run_times_gcoff = get(result, :run_times_gcoff, Float64[]),
                         total_times_gcoff = get(result, :total_times_gcoff, Float64[]),
                         load_stats_gcoff = get(result, :load_stats_gcoff, Any[]),
                         run_stats_gcoff = get(result, :run_stats_gcoff, Any[]),
                         gc_after_load = get(result, :gc_after_load, Float64[]),
                         error_gcoff = get(result, :error_gcoff, nothing),
                         packages_hash = packages_hash(projs[arm.label]))
                push!(records, rec)
                write_results()
                if rec.status == "ok"
                    @printf("  block %d  %-8s precompile=%7.2fs  load=%6.2fs  run=%6.2fs\n", block, arm.label,
                            rec.precompile_time, rec.load_times[1], rec.run_times[1])
                    if !isempty(rec.run_stats)
                        l, r = rec.load_stats[1], rec.run_stats[1]
                        @printf("           %-8s load: gc %5.2fs (%d pauses) compile %5.2fs   run: gc %6.3fs (%d) compile %6.3fs recompile %6.3fs\n",
                                "", l["gc_time"], l["gc_pauses"], l["compile_time"],
                                r["gc_time"], r["gc_pauses"], r["compile_time"], r["recompile_time"])
                    end
                    if !isempty(rec.load_times_gcoff)
                        @printf("           %-8s gc off: load=%6.2fs  run=%6.2fs  (forced gc after load %5.2fs)\n", "",
                                rec.load_times_gcoff[1], rec.run_times_gcoff[1], rec.gc_after_load[1])
                    end
                    rec.error_gcoff === nothing || println("           gc-off runs failed: $(rec.error_gcoff)")
                else
                    # Red, and `^^^ +++` makes Buildkite expand this task's log group
                    println("  block $block  $(rpad(arm.label, 8)) \e[31mFAILED\e[0m ($(rec.status)): $(rec.error)")
                    println("^^^ +++")
                    stop = true
                end
                trace = get(result, :trace, nothing)
                if trace !== nothing
                    println("  trace    $(rpad(arm.label, 8)) $(trace.statements) precompile statements in $(basename(trace.file))",
                            trace.ok ? "" : " (the instrumented run failed, see the end of the file)")
                end
                flush(stdout)
            end
            stop && block < blocks && println("  skipping the remaining blocks of $label")
        end
    end
    println("--- Done: $(length(records)) records in $(opts["results"])")
end

main()
