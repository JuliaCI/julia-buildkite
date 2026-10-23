# Compare the arms of a ttfx_bench.jl run, or summarise a single arm. Writes a markdown
# report (the Buildkite annotation) and a JSON summary.
#
#   julia --startup-file=no ttfx_compare.jl --results FILE --head LABEL [--base LABEL]
#         [--meta FILE] [--report FILE] [--json FILE] [--title T] [--url U] [--perf-url U]
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
# is a collection that moved between load and run; it is reported but not counted.

include(joinpath(@__DIR__, "ttfx_json.jl"))
using .TTFXJSON

const METRICS = [
    (key = "precompile", name = "precompile",      threshold = 0.08, suite = 0.02, floor = 0.25),
    (key = "load",       name = "load (cold)",     threshold = 0.10, suite = 0.02, floor = 0.10),
    (key = "run",        name = "run (cold)",      threshold = 0.15, suite = 0.03, floor = 0.05),
    (key = "warm",       name = "load+run (warm)", threshold = 0.15, suite = 0.03, floor = 0.05),
    (key = "load_stdlibs", name = "load (stdlibs first)", threshold = 0.10, suite = 0.02, floor = 0.10),
    (key = "run_stdlibs",  name = "run (stdlibs first)",  threshold = 0.15, suite = 0.03, floor = 0.05),
]

function parse_args(args)
    opts = Dict{String,Any}("results" => nothing, "meta" => nothing, "head" => nothing, "base" => nothing,
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
function value(r, key)
    r["status"] == "error" && return nothing
    if key == "precompile"
        return r["precompile_time"]
    elseif key == "load"
        return isempty(r["load_times"]) ? nothing : Float64(r["load_times"][1])
    elseif key == "run"
        return isempty(r["run_times"]) ? nothing : Float64(r["run_times"][1])
    elseif key in ("load_stdlibs", "run_stdlibs")
        t = get(r, key[1:end-8] * "_times_stdlibs", Any[])
        return isempty(t) ? nothing : Float64(t[1])
    else
        t = r["total_times"]
        return length(t) >= 2 ? minimum(Float64.(t[2:end])) : nothing
    end
end

# The same phase measured with the GC disabled (see the driver), for load and run;
# nothing for records from before the driver recorded it. The stdlibs-first run has no
# GC-off repeat, so its GC time is taken out instead, which is close but not the same.
function value_gcoff(r, key)
    r["status"] == "error" && return nothing
    if key in ("load_stdlibs", "run_stdlibs")
        t = value(r, key); g = gc_time(r, key)
        return t === nothing || g === nothing ? nothing : t - g
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

median(x) = (s = sort(x); n = length(s); isodd(n) ? s[(n + 1) ÷ 2] : (s[n ÷ 2] + s[n ÷ 2 + 1]) / 2)
geomean(x) = exp(sum(log, x) / length(x))
fmt(x) = x === nothing ? "–" : x >= 100 ? string(round(Int, x)) : x >= 10 ? string(round(x; digits = 1)) : string(round(x; digits = 2))
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
                           "regressions" => String[], "improvements" => String[], "gc_moved" => String[])
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
        # A run that precompiles in block 1 only (--precompile-once) has no precompile
        # time in the later blocks; the blocks that measured both arms are judged.
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
        if gverdict == "same" && verdict != "same" && haskey(out["metrics"][m.key], "gcoff_verdict") && gc_moved(b, h, m.key)
            out["metrics"][m.key]["gc_moved"] = true
            push!(out["gc_moved"], m.key)
        elseif verdict == "regression" || gverdict == "regression"
            push!(out["regressions"], m.key)
        elseif verdict == "improvement" || gverdict == "improvement"
            push!(out["improvements"], m.key)
        end
    end
    return out
end

# Whether the change in a phase's GC time is mostly offset by the opposite change in the
# other phase, so the same collections ran but on the other side of the load/run boundary.
function gc_moved(b, h, key)
    other = Dict("load" => "run", "run" => "load", "load_stdlibs" => "run_stdlibs", "run_stdlibs" => "load_stdlibs")[key]
    gcs = [gc_time(r, k) for r in vcat(b, h), k in (key, other)]
    any(isnothing, gcs) && return false
    delta(k) = median(Float64[gc_time(r, k) for r in h]) - median(Float64[gc_time(r, k) for r in b])
    d, o = delta(key), delta(other)
    return d * o < 0 && abs(d + o) <= abs(d) / 2
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
# from the GC-off repeats (suite keys `load_gcoff`, `run_gcoff`). Precompile has one
# geomean per block that measured it.
function compare_suite(tasks, nblocks)
    suite = Dict{String,Any}()
    for m in METRICS, field in ("ratios", "gcoff_ratios")
        has(t) = haskey(t["metrics"], m.key) && haskey(t["metrics"][m.key], field)
        gs = Float64[]
        for k in 1:nblocks
            rs = [t["metrics"][m.key][field][i] for t in tasks if has(t) for (i, bk) in enumerate(t["metrics"][m.key]["blocks"]) if bk == k]
            isempty(rs) || push!(gs, geomean(rs))
        end
        isempty(gs) && continue
        verdict = all(>(1 + m.suite), gs) ? "regression" : all(<(1 - m.suite), gs) ? "improvement" : "same"
        suite[field == "ratios" ? m.key : m.key * "_gcoff"] = Dict("geomeans" => gs, "verdict" => verdict, "n_tasks" => count(has, tasks))
    end
    return suite
end

arm_desc(meta, label) = begin
    a = meta === nothing ? nothing : get(get(meta, "arms", Dict()), label, nothing)
    a === nothing ? code(label) : code(label) * " " * a["version"] * " (" * a["commit_short"] * ")"
end

# A pull request precompiles each task once per arm (ttfx_bench.jl --precompile-once), so
# the report says how to get the precision master builds have.
function precompile_note(meta)
    settings = meta === nothing ? nothing : get(meta, "settings", nothing)
    (settings === nothing || get(settings, "precompile_once", false) !== true) && return ""
    return "Precompile was measured once per arm, in block 1; master builds measure it in every block. " *
           "For a more precise precompile comparison, add the `needs TTFX check` label; " *
           "Buildkite reads labels when it creates a build, so it applies from the next push."
end

links(opts) = (isempty(opts["url"]) ? "" : " · [job](" * opts["url"] * ")") *
              (isempty(opts["perf-url"]) ? "" : " · [perf.julialang.org](" * opts["perf-url"] * ")")

function write_comparison(io, opts, meta, tasks, suite, nblocks)
    base, head = opts["base"], opts["head"]
    nreg = sum(t -> length(t["regressions"]), tasks; init = 0) + count(s -> s["verdict"] == "regression", values(suite))
    nimp = sum(t -> length(t["improvements"]), tasks; init = 0) + count(s -> s["verdict"] == "improvement", values(suite))
    note = isempty(opts["base-note"]) ? "" : ", " * opts["base-note"]
    link = links(opts)
    header = arm_desc(meta, head) * " vs " * arm_desc(meta, base) * note * " · " * string(length(tasks)) *
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
            "except a difference that shows with the GC on only and whose GC time moved from the other phase.\n")
    isempty(pnote) || println(io, pnote, "\n")
    println(io, "| suite (geomean over tasks) | change per block | with GC off | threshold |")
    println(io, "|---|---|---|---|")
    for m in METRICS
        haskey(suite, m.key) || continue
        s = suite[m.key]
        marked(s) = (v = s["verdict"]; c = join(change.(s["geomeans"]), ", "); v == "same" ? c : "**" * c * " " * v * "**")
        g = get(suite, m.key * "_gcoff", nothing)
        println(io, "| ", m.name, " (", s["n_tasks"], s["n_tasks"] == 1 ? " task) | " : " tasks) | ", marked(s), " | ",
                g === nothing ? "–" : marked(g), " | ±", pct(m.suite), " |")
    end
    for (title, field) in (("Regressions", "regressions"), ("Improvements", "improvements"),
                           ("GC moved between load and run (not counted)", "gc_moved"))
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
                bold(s, v) = v == "same" ? s : "**" * s * "**"
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
    println(io, arm_desc(meta, head), " · ", length(grouped), " tasks · ", nblocks, " samples", link, "\n")
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
    suite = compare_suite(tasks, nblocks)
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
