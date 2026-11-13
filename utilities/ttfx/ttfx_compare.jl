# Compare the arms of a ttfx_bench.jl run, or summarise a single arm. Writes a markdown
# report (the Buildkite annotation) and a JSON summary.
#
#   julia --startup-file=no ttfx_compare.jl --results FILE --head LABEL [--base LABEL]
#         [--startup FILE] [--meta FILE] [--report FILE] [--json FILE] [--title T] [--url U] [--perf-url U]
#         [--base-note N]
#
# Exit status: 0 nothing to report, 1 robust regression, 2 unusable data, 3 robust
# improvements only. The report lists only the differences (and, in summary mode, every
# task); with nothing to report it is a single line.
#
# A difference in a task's metric is robust when the samples of the two builds do not
# overlap and every ABBA block, each of which pairs a head sample with a base sample taken
# next to it in time, agrees beyond the metric's threshold; a floor on the absolute
# difference keeps sub-second startup jitter out. Beyond the tasks, each metric's
# geometric mean over the suite is judged per block with a tighter threshold, which is
# where a small regression spread over many packages shows up. A load or run difference
# that only shows with the GC on, and whose extra GC time was taken from the other phase,
# is a collection that moved between load and run; it is reported but not counted. For the
# suite, such a difference counts only when load and run added together changed the same way.
# The stdlibs-first suite counts with its GC time taken out only (see compare_suite).

include(joinpath(@__DIR__, "ttfx_json.jl"))
using .TTFXJSON
include(joinpath(@__DIR__, "ttfx_metrics.jl"))

function parse_args(args)
    opts = Dict{String,Any}("results" => nothing, "startup" => nothing, "meta" => nothing, "head" => nothing, "base" => nothing,
                            "report" => "report.md", "json" => "compare.json", "title" => "TTFX benchmarks",
                            "url" => "", "perf-url" => "", "base-note" => "")
    i = 1
    while i <= length(args)
        key = args[i][3:end]
        (startswith(args[i], "--") && haskey(opts, key)) || error("unknown option $(args[i])")
        i += 1
        i <= length(args) || error("--$key needs a value")
        opts[key] = args[i]
        i += 1
    end
    opts["results"] === nothing && error("--results is required")
    opts["head"] === nothing && error("--head is required")
    return opts
end

# One value per metric from a record; nothing when the sample has no such measurement.
# The startup records hold many runs of `julia -e ''` and of the REPL to its prompt per
# block, and their median is the sample. Startup+load runs from spawning the task's process to the end of its load phase.
function value(r, key)
    r["status"] == "error" && return nothing
    first_of(field) = (t = get(r, field, Any[]); isempty(t) ? nothing : Float64(t[1]))
    if key in ("startup", "startup_repl")
        t = get(r, key * "_times", Any[])
        return isempty(t) ? nothing : median(Float64.(t))
    elseif key == "precompile"
        return get(r, "precompile_time", nothing)
    elseif key in ("load", "run")
        return first_of(key * "_times")
    elseif key == "startup_load"
        p = first_of("preload_times"); l = first_of("load_times")
        return p === nothing || l === nothing ? nothing : p + l
    elseif key in ("load_stdlibs", "run_stdlibs")
        return first_of(key[1:end-8] * "_times_stdlibs")
    else
        t = get(r, "total_times", Any[])
        return length(t) >= 2 ? minimum(Float64.(t[2:end])) : nothing
    end
end

# The same phase measured with the GC disabled (see the driver), for load and run;
# nothing for records from before the driver recorded it. The stdlibs-first run has no
# GC-off repeat, so its GC time is taken out instead, which is close but not the same.
# The GC counters are read outside the phase's clocks (the third snapshot comes after
# `__t3`), so a collection that starts just after the clock stops is counted but not
# timed and can exceed the phase: such a sample has no GC-off value.
function value_gcoff(r, key)
    r["status"] == "error" && return nothing
    if key in ("load_stdlibs", "run_stdlibs")
        t = value(r, key); g = gc_time(r, key)
        return t === nothing || g === nothing || g >= t ? nothing : t - g
    end
    key in ("load", "run") || return nothing
    t = get(r, key * "_times_gcoff", Any[])
    return isempty(t) ? nothing : Float64(t[1])
end

# GC time of the cold sample's phase (`load`, `run`, `load_stdlibs` or `run_stdlibs`);
# nothing when the task has no phase markers.
function gc_time(r, key)
    phase, suffix = key in ("load_stdlibs", "run_stdlibs") ? (key[1:end-8], "_stdlibs") : (key, "")
    st = get(r, phase * "_stats" * suffix, Any[])
    g = isempty(st) || !(st[1] isa AbstractDict) ? nothing : get(st[1], "gc_time", nothing)
    return g === nothing ? nothing : Float64(g)
end

const STARTUP = "julia/startup"

median(x) = (s = sort(x); n = length(s); isodd(n) ? s[(n + 1) ÷ 2] : (s[n ÷ 2] + s[n ÷ 2 + 1]) / 2)
geomean(x) = exp(sum(log, x) / length(x))
fmt(x) = x === nothing ? "–" : x >= 100 ? string(round(Int, x)) : x >= 10 ? string(round(x; digits = 1)) :
         x >= 1 ? string(round(x; digits = 2)) : string(round(x; digits = 3))
fmtr(x) = string(round(x; digits = 3))
pct(x) = string(round(Int, 100x)) * "%"
# A head/base ratio as a signed percentage change
change(x) = (x >= 1 ? "+" : "") * string(round(100 * (x - 1); digits = 1)) * "%"
code(s) = "`" * s * "`"

# recs[task][arm] => records sorted by block
function group(records, arms)
    g = Dict{String,Dict{String,Vector{Any}}}()
    for r in records
        r["arm"] in arms || continue
        name = r["package"] * "/" * r["task"]
        push!(get!(get!(g, name, Dict{String,Vector{Any}}()), r["arm"], Any[]), r)
    end
    for d in values(g), v in values(d)
        sort!(v; by = r -> r["block"])
    end
    return g
end

function compare_task(name, byarm, base, head, nblocks)
    b = get(byarm, base, Any[]); h = get(byarm, head, Any[])
    out = Dict{String,Any}("name" => name, "metrics" => Dict{String,Any}(), "note" => nothing,
                           "regressions" => String[], "improvements" => String[], "gc_moved" => String[],
                           "startup_moved" => String[])
    # The driver stops a task at its first failure, so a failed task has fewer samples than
    # blocks and possibly none for the arm that never got its turn.
    berrs = [r for r in b if r["status"] != "ok"]; herrs = [r for r in h if r["status"] != "ok"]
    bok = any(r -> r["status"] == "ok", b); hok = any(r -> r["status"] == "ok", h)
    if !isempty(berrs) && !isempty(herrs)
        out["note"] = "fails on both: " * something(herrs[1]["error"], "")
        return out
    elseif !isempty(herrs)
        out["note"] = "fails on head: " * something(herrs[1]["error"], "")
        bok && push!(out["regressions"], "fails")
        return out
    elseif !isempty(berrs)
        if hok
            out["note"] = "fixed on head (fails on base: " * something(berrs[1]["error"], "") * ")"
            push!(out["improvements"], "fixed")
        else
            out["note"] = "fails on base, head not measured: " * something(berrs[1]["error"], "")
        end
        return out
    end
    if length(b) != nblocks || length(h) != nblocks
        out["note"] = "incomplete: $(length(b)) base and $(length(h)) head samples"
        return out
    end
    hashes = unique(something.(vcat([r["packages_hash"] for r in b], [r["packages_hash"] for r in h]), ""))
    length(hashes) > 1 && (out["note"] = "the arms resolved different package versions")
    for m in METRICS
        bv = [value(r, m.key) for r in b]; hv = [value(r, m.key) for r in h]
        # With --precompile-once most tasks have a precompile time in block 1 only; the
        # blocks that measured both arms are judged.
        blocks = [k for k in 1:nblocks if bv[k] !== nothing && hv[k] !== nothing]
        (isempty(blocks) || (m.key != "precompile" && length(blocks) != nblocks)) && continue
        bv = Float64.(bv[blocks]); hv = Float64.(hv[blocks])
        verdict = judge(bv, hv, m)
        out["metrics"][m.key] = Dict("base" => bv, "head" => hv, "ratios" => hv ./ bv, "blocks" => blocks, "verdict" => verdict)
        # Load and run are also judged with the GC off, and either measurement counts: a
        # difference that only shows with the GC on was GC pauses, one that only shows with
        # it off was hidden by them.
        gb = [value_gcoff(r, m.key) for r in b]; gh = [value_gcoff(r, m.key) for r in h]
        gverdict = "same"
        if !any(isnothing, gb) && !any(isnothing, gh)
            gb = Float64.(gb); gh = Float64.(gh)
            gverdict = judge(gb, gh, m)
            merge!(out["metrics"][m.key], Dict("gcoff_base" => gb, "gcoff_head" => gh,
                                                "gcoff_ratios" => gh ./ gb, "gcoff_verdict" => gverdict))
        end
        if haskey(OTHER_PHASE, m.key)
            d = gc_delta(b, h, m.key)
            d === nothing || (out["metrics"][m.key]["gc_delta"] = d)
        end
        if gverdict == "same" && verdict != "same" && haskey(out["metrics"][m.key], "gcoff_verdict") && gc_moved(b, h, m.key)
            out["metrics"][m.key]["gc_moved"] = true
            push!(out["gc_moved"], m.key)
        elseif verdict == "regression" || gverdict == "regression"
            push!(out["regressions"], m.key)
        elseif verdict == "improvement" || gverdict == "improvement"
            push!(out["improvements"], m.key)
        end
    end
    # A build can move work from startup into the first package load, for example by
    # faulting in system image pages on first use. Load then looks slower although the
    # user waits no longer. A load difference counts only if the time before the first
    # marker did not offset at least half of it, or startup and load together changed the
    # same way.
    if haskey(out["metrics"], "load") && haskey(out["metrics"], "startup_load")
        d = phase_delta(b, h, "load_times"); p = phase_delta(b, h, "preload_times")
        lm = out["metrics"]["load"]
        lm["load_delta"] = d; lm["preload_delta"] = p
        for (field, v) in (("regressions", "regression"), ("improvements", "improvement"))
            "load" in out[field] || continue
            if out["metrics"]["startup_load"]["verdict"] != v && d * p < 0 && abs(d + p) <= abs(d) / 2
                filter!(!=("load"), out[field])
                lm["startup_moved"] = true
                push!(out["startup_moved"], "load")
            end
        end
    end
    return out
end

# Head minus base median of a cold timing field.
phase_delta(b, h, field) = median(Float64[r[field][1] for r in h]) - median(Float64[r[field][1] for r in b])

# Whether the change in a phase's GC time is mostly offset by the opposite change in the
# other phase, so the same collections ran but on the other side of the load/run boundary.
function gc_moved(b, h, key)
    d = gc_delta(b, h, key); o = gc_delta(b, h, OTHER_PHASE[key])
    (d === nothing || o === nothing) && return false
    return d * o < 0 && abs(d + o) <= abs(d) / 2
end

const OTHER_PHASE = Dict("load" => "run", "run" => "load", "load_stdlibs" => "run_stdlibs", "run_stdlibs" => "load_stdlibs")

# Head minus base median GC time of a phase; nothing when a sample has no phase stats.
function gc_delta(b, h, key)
    any(r -> gc_time(r, key) === nothing, vcat(b, h)) && return nothing
    return median(Float64[gc_time(r, key) for r in h]) - median(Float64[gc_time(r, key) for r in b])
end

# Robust: the two builds' samples do not overlap, every block agrees beyond the threshold,
# and the medians differ by at least the floor.
function judge(bv, hv, m)
    ratios = hv ./ bv
    if all(>(1 + m.threshold), ratios) && minimum(hv) > maximum(bv) && median(hv) - median(bv) >= m.floor
        "regression"
    elseif all(<(1 - m.threshold), ratios) && maximum(hv) < minimum(bv) && median(bv) - median(hv) >= m.floor
        "improvement"
    else
        "same"
    end
end

# Per metric, the geometric mean of the per-task ratios, per block; load and run once more
# from the GC-off repeats (suite keys `load_gcoff`, `run_gcoff`). With --precompile-once
# the tasks have one or two precompile samples, so precompile gets a single geomean of
# each task's fastest head sample over its fastest base sample.
function compare_suite(tasks, nblocks; precompile_once::Bool = false)
    suite = Dict{String,Any}()
    for m in METRICS, field in ("ratios", "gcoff_ratios")
        m.suite === nothing && continue
        has(t) = haskey(t["metrics"], m.key) && haskey(t["metrics"][m.key], field)
        gs = Float64[]
        if precompile_once && m.key == "precompile"
            rs = [minimum(t["metrics"][m.key]["head"]) / minimum(t["metrics"][m.key]["base"]) for t in tasks if has(t)]
            isempty(rs) || push!(gs, geomean(rs))
        else
            for k in 1:nblocks
                rs = [t["metrics"][m.key][field][k] for t in tasks if has(t)]
                isempty(rs) && break
                push!(gs, geomean(rs))
            end
            length(gs) == nblocks || continue
        end
        isempty(gs) && continue
        verdict = all(>(1 + m.suite), gs) ? "regression" : all(<(1 - m.suite), gs) ? "improvement" : "same"
        suite[field == "ratios" ? m.key : m.key * "_gcoff"] = Dict("geomeans" => gs, "verdict" => verdict, "n_tasks" => count(has, tasks))
    end
    # A suite difference that shows with the GC on only, while the GC time moved the other
    # way in the other phase, is collections moving between load and run. It counts only
    # when load and run added together changed the same way.
    both = [t for t in tasks if haskey(t["metrics"], "load") && haskey(t["metrics"], "run")]
    if !isempty(both)
        sum_ratio(t, k) = (t["metrics"]["load"]["head"][k] + t["metrics"]["run"]["head"][k]) /
                          (t["metrics"]["load"]["base"][k] + t["metrics"]["run"]["base"][k])
        gs = [geomean([sum_ratio(t, k) for t in both]) for k in 1:nblocks]
        thr = only(m.suite for m in METRICS if m.key == "load")
        combined = all(>(1 + thr), gs) ? "regression" : all(<(1 - thr), gs) ? "improvement" : "same"
        gc_change(k) = sum(t -> get(t["metrics"][k], "gc_delta", 0.0), both)
        for (k, o) in (("load", "run"), ("run", "load"))
            s = get(suite, k, nothing); g = get(suite, k * "_gcoff", nothing)
            (s === nothing || g === nothing) && continue
            if s["verdict"] != "same" && g["verdict"] == "same" && combined != s["verdict"] && gc_change(k) * gc_change(o) < 0
                s["gc_moved"] = true
                s["combined_geomeans"] = gs
            end
        end
    end
    # The stdlibs-first suite is judged with the GC time taken out only. With every stdlib
    # loaded the heap sits near a collection trigger, so a small allocation difference moves
    # one ~25 ms collection into or out of a few-millisecond phase, the same way in every
    # block, and the geomean weighs that 2-3x ratio like any other task's. The GC-on
    # geomeans are reported but do not count.
    for k in ("load_stdlibs", "run_stdlibs")
        s = get(suite, k, nothing)
        s === nothing || (s["diagnostic"] = true)
    end
    # The suite's load likewise, when the time before the first marker moved the other way
    # over the suite and startup+load did not change the same way.
    sl = get(suite, "startup_load", nothing)
    moved = [t["metrics"]["load"] for t in tasks if haskey(t["metrics"], "load") && haskey(t["metrics"]["load"], "preload_delta")]
    if sl !== nothing && !isempty(moved) && sum(m -> m["load_delta"], moved) * sum(m -> m["preload_delta"], moved) < 0
        for k in ("load", "load_gcoff")
            s = get(suite, k, nothing)
            if s !== nothing && s["verdict"] != "same" && !get(s, "gc_moved", false) && sl["verdict"] != s["verdict"]
                s["startup_moved"] = true
                s["startup_load_geomeans"] = sl["geomeans"]
            end
        end
    end
    return suite
end

counts(s, verdict) = s["verdict"] == verdict && !get(s, "gc_moved", false) && !get(s, "startup_moved", false) &&
                     !get(s, "diagnostic", false)

arm_desc(meta, label) = begin
    a = meta === nothing ? nothing : get(get(meta, "arms", Dict()), label, nothing)
    a === nothing ? code(label) : code(label) * " " * a["version"] * " (" * a["commit_short"] * ")"
end

precompile_once(meta) = meta !== nothing && get(get(meta, "settings", Dict()), "precompile_once", false) === true

# A pull request precompiles most tasks once per arm (ttfx_bench.jl --precompile-once), so
# the report says how to get the precision master builds have.
function precompile_note(meta)
    precompile_once(meta) || return ""
    return "Precompile was measured once per arm, in block 1, and again in block 2 only for the tasks " *
           "whose block-1 difference cleared the threshold; the suite geomean compares each task's fastest samples. " *
           "Master builds precompile in every block. " *
           "For a more precise precompile comparison, add the `needs TTFX check` label; " *
           "Buildkite reads labels when it creates a build, so it applies from the next push."
end

links(opts) = (isempty(opts["url"]) ? "" : " · [job](" * opts["url"] * ")") *
              (isempty(opts["perf-url"]) ? "" : " · [perf.julialang.org](" * opts["perf-url"] * ")")

function write_comparison(io, opts, meta, tasks, suite, nblocks)
    base, head = opts["base"], opts["head"]
    nreg = sum(t -> length(t["regressions"]), tasks; init = 0) + count(s -> counts(s, "regression"), values(suite))
    nimp = sum(t -> length(t["improvements"]), tasks; init = 0) + count(s -> counts(s, "improvement"), values(suite))
    note = isempty(opts["base-note"]) ? "" : ", " * opts["base-note"]
    link = links(opts)
    header = arm_desc(meta, head) * " vs " * arm_desc(meta, base) * note * " · " * string(count(t -> t["name"] != STARTUP, tasks)) *
             " tasks · " * string(nblocks) * " blocks (ABBA)" * link
    pnote = precompile_note(meta)
    if nreg + nimp == 0
        println(io, opts["title"], ": no robust regressions or improvements. ", header)
        isempty(pnote) || println(io, "\n", pnote)
        return nreg, nimp
    end
    println(io, "## ", opts["title"])
    println(io, header, "\n")
    println(io, "**", nreg == 0 ? "No robust regressions" : "$nreg robust regression" * (nreg == 1 ? "" : "s"),
            ", ", nimp, " improvement", nimp == 1 ? "" : "s", ".** ",
            "Robust: samples do not overlap and every block clears the threshold (",
            join([m.name * " " * pct(m.threshold) for m in METRICS], ", "),
            "); load and run are also judged from the repeats with the GC off (the stdlibs-first load and run with their GC time ",
            "taken out), and either counts (bold marks which), ",
            "except a difference that shows with the GC on only and whose GC time moved from the other phase ",
            "(for the suite: unless load and run added together changed the same way), ",
            "and a load difference offset by the opposite change in startup (unless startup+load changed the same way). ",
            "The stdlibs-first suite counts with the GC time taken out only.\n")
    isempty(pnote) || println(io, pnote, "\n")
    println(io, "| suite (geomean over tasks) | change per block | with GC off | threshold |")
    println(io, "|---|---|---|---|")
    for m in METRICS
        haskey(suite, m.key) || continue
        s = suite[m.key]
        function marked(s)
            v = s["verdict"]; c = join(change.(s["geomeans"]), ", ")
            v == "same" && return c
            get(s, "gc_moved", false) &&
                return c * " (GC moved between load and run, not counted; load+run " * join(change.(s["combined_geomeans"]), ", ") * ")"
            get(s, "startup_moved", false) &&
                return c * " (moved between startup and load, not counted; startup+load " * join(change.(s["startup_load_geomeans"]), ", ") * ")"
            get(s, "diagnostic", false) && return c * " " * v * " with the GC on, not counted"
            return "**" * c * " " * v * "**"
        end
        g = get(suite, m.key * "_gcoff", nothing)
        println(io, "| ", m.name, " (", s["n_tasks"], s["n_tasks"] == 1 ? " task) | " : " tasks) | ", marked(s), " | ",
                g === nothing ? "–" : marked(g) * (g["n_tasks"] == s["n_tasks"] ? "" : " (" * string(g["n_tasks"]) * (g["n_tasks"] == 1 ? " task)" : " tasks)")),
                " | ±", pct(m.suite), " |")
    end
    for (title, field) in (("Regressions", "regressions"), ("Improvements", "improvements"),
                           ("GC moved between load and run (not counted)", "gc_moved"),
                           ("Moved between startup and load (not counted)", "startup_moved"))
        rows = [(t, k) for t in tasks for k in t[field]]
        isempty(rows) && continue
        println(io, "\n### ", title, "\n")
        println(io, "| task | metric | base (s) | head (s) | change per block | with GC off |")
        println(io, "|---|---|---|---|---|---|")
        for (t, k) in rows
            if k in ("fails", "fixed")
                println(io, "| ", t["name"], " | | | | ", t["note"], " | |")
            else
                m = t["metrics"][k]
                moved = get(m, "startup_moved", false)
                bold(s, v) = v == "same" || moved ? s : "**" * s * "**"
                normal = bold(join(change.(m["ratios"]), ", "), get(m, "gc_moved", false) ? "same" : m["verdict"])
                gcoff = haskey(m, "gcoff_ratios") ? bold(join(change.(m["gcoff_ratios"]), ", "), m["gcoff_verdict"]) : "–"
                println(io, "| ", t["name"], " | ", k, " | ", join(fmt.(m["base"]), ", "), " | ", join(fmt.(m["head"]), ", "),
                        " | ", normal, " | ", gcoff, " |")
            end
        end
    end
    return nreg, nimp
end

function write_summary(io, opts, meta, grouped, head, nblocks)
    println(io, "## ", opts["title"])
    link = links(opts)
    println(io, arm_desc(meta, head), " · ", count(!=(STARTUP), keys(grouped)), " tasks · ", nblocks, " samples", link, "\n")
    println(io, "| task | ", join([m.name * " (s)" for m in METRICS], " | "), " | note |")
    println(io, "|---|", "---|"^length(METRICS), "---|")
    for name in sort!(collect(keys(grouped)))
        recs = get(grouped[name], head, Any[])
        cells = map(METRICS) do m
            vs = filter(!isnothing, [value(r, m.key) for r in recs])
            isempty(vs) ? "–" : length(vs) == 1 ? fmt(vs[1]) : fmt(minimum(vs)) * " – " * fmt(maximum(vs))
        end
        errs = [r["error"] for r in recs if r["status"] != "ok"]
        println(io, "| ", name, " | ", join(cells, " | "), " | ", isempty(errs) ? "" : first(errs), " |")
    end
end

function main()
    opts = parse_args(ARGS)
    records = json_parse(read(opts["results"]))
    # The startup records are compared as one more task
    opts["startup"] === nothing || !isfile(opts["startup"]) || append!(records, json_parse(read(opts["startup"])))
    meta = opts["meta"] === nothing || !isfile(opts["meta"]) ? nothing : json_parse(read(opts["meta"]))
    head, base = opts["head"], opts["base"]
    nblocks = meta === nothing ? maximum(r["block"] for r in records; init = 1) : meta["settings"]["blocks"]
    grouped = group(records, base === nothing ? (head,) : (base, head))
    if isempty(grouped)
        println(stderr, "no records for the requested arms in ", opts["results"])
        exit(2)
    end

    if base === nothing
        open(opts["report"], "w") do io
            write_summary(io, opts, meta, grouped, head, nblocks)
        end
        write(opts["json"], json_write(Dict("head" => head, "tasks" => sort!(collect(keys(grouped))))) * "\n")
        print(read(opts["report"], String))
        return 0
    end

    tasks = [compare_task(name, grouped[name], base, head, nblocks) for name in sort!(collect(keys(grouped)))]
    suite = compare_suite(tasks, nblocks; precompile_once = precompile_once(meta))
    nreg, nimp = open(opts["report"], "w") do io
        write_comparison(io, opts, meta, tasks, suite, nblocks)
    end
    summary = Dict("base" => base, "head" => head, "blocks" => nblocks,
                   "verdict" => nreg > 0 ? "regression" : nimp > 0 ? "improvement" : "same",
                   "n_regressions" => nreg, "n_improvements" => nimp, "suite" => suite,
                   "tasks" => Dict(t["name"] => t for t in tasks))
    write(opts["json"], json_write(summary) * "\n")
    print(read(opts["report"], String))
    usable = count(t -> !isempty(t["metrics"]) || !isempty(t["regressions"]) || !isempty(t["improvements"]), tasks)
    if usable == 0
        println(stderr, "no task has samples for both arms")
        return 2
    end
    return nreg > 0 ? 1 : nimp > 0 ? 3 : 0
end

exit(main())
