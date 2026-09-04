# Compare the arms of a ttfx_bench.jl run, or summarise a single arm. Writes a markdown
# report (the Buildkite annotation) and a JSON summary.
#
#   julia --startup-file=no ttfx_compare.jl --results FILE --head LABEL [--base LABEL]
#         [--meta FILE] [--report FILE] [--json FILE] [--title T] [--url U] [--base-note N]
#
# Exit status: 0 no robust regression, 1 robust regression, 2 unusable data.
#
# A difference in a task's metric is robust when the samples of the two builds do not
# overlap and every ABBA block, each of which pairs a head sample with a base sample taken
# next to it in time, agrees beyond the metric's threshold; a floor on the absolute
# difference keeps sub-second startup jitter out. Beyond the tasks, each metric's
# geometric mean over the suite is judged per block with a tighter threshold, which is
# where a small regression spread over many packages shows up.

include(joinpath(@__DIR__, "ttfx_json.jl"))
using .TTFXJSON

const METRICS = [
    (key = "precompile", name = "precompile",      threshold = 0.08, suite = 0.02, floor = 0.25),
    (key = "load",       name = "load (cold)",     threshold = 0.10, suite = 0.02, floor = 0.05),
    (key = "run",        name = "run (cold)",      threshold = 0.15, suite = 0.03, floor = 0.05),
    (key = "warm",       name = "load+run (warm)", threshold = 0.15, suite = 0.03, floor = 0.05),
]

function parse_args(args)
    opts = Dict{String,Any}("results" => nothing, "meta" => nothing, "head" => nothing, "base" => nothing,
                            "report" => "report.md", "json" => "compare.json", "title" => "TTFX benchmarks",
                            "url" => "", "base-note" => "")
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
    else
        t = r["total_times"]
        return length(t) >= 2 ? minimum(Float64.(t[2:end])) : nothing
    end
end

median(x) = (s = sort(x); n = length(s); isodd(n) ? s[(n + 1) ÷ 2] : (s[n ÷ 2] + s[n ÷ 2 + 1]) / 2)
geomean(x) = exp(sum(log, x) / length(x))
fmt(x) = x === nothing ? "–" : x >= 100 ? string(round(Int, x)) : x >= 10 ? string(round(x; digits = 1)) : string(round(x; digits = 2))
fmtr(x) = string(round(x; digits = 3))
pct(x) = string(round(Int, 100x)) * "%"
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
                           "regressions" => String[], "improvements" => String[])
    if length(b) != nblocks || length(h) != nblocks
        out["note"] = "incomplete: $(length(b)) base and $(length(h)) head samples"
        return out
    end
    berr = all(r -> r["status"] == "error", b); herr = all(r -> r["status"] == "error", h)
    if berr && herr
        out["note"] = "fails on both: " * something(h[1]["error"], "")
        return out
    elseif herr
        out["note"] = "fails on head: " * something(h[1]["error"], "")
        push!(out["regressions"], "fails")
        return out
    elseif berr
        out["note"] = "fixed on head (fails on base: " * something(b[1]["error"], "") * ")"
        push!(out["improvements"], "fixed")
        return out
    end
    hashes = unique(something.(vcat([r["packages_hash"] for r in b], [r["packages_hash"] for r in h]), ""))
    length(hashes) > 1 && (out["note"] = "the arms resolved different package versions")
    for m in METRICS
        bv = [value(r, m.key) for r in b]; hv = [value(r, m.key) for r in h]
        (any(isnothing, bv) || any(isnothing, hv)) && continue
        bv = Float64.(bv); hv = Float64.(hv)
        ratios = hv ./ bv
        verdict = if all(>(1 + m.threshold), ratios) && minimum(hv) > maximum(bv) && median(hv) - median(bv) >= m.floor
            "regression"
        elseif all(<(1 - m.threshold), ratios) && maximum(hv) < minimum(bv) && median(bv) - median(hv) >= m.floor
            "improvement"
        else
            "same"
        end
        verdict == "regression" && push!(out["regressions"], m.key)
        verdict == "improvement" && push!(out["improvements"], m.key)
        out["metrics"][m.key] = Dict("base" => bv, "head" => hv, "ratios" => ratios, "verdict" => verdict)
    end
    return out
end

function compare_suite(tasks, nblocks)
    suite = Dict{String,Any}()
    for m in METRICS
        gs = Float64[]
        for k in 1:nblocks
            rs = [t["metrics"][m.key]["ratios"][k] for t in tasks if haskey(t["metrics"], m.key)]
            isempty(rs) && break
            push!(gs, geomean(rs))
        end
        length(gs) == nblocks || continue
        verdict = all(>(1 + m.suite), gs) ? "regression" : all(<(1 - m.suite), gs) ? "improvement" : "same"
        n = count(t -> haskey(t["metrics"], m.key), tasks)
        suite[m.key] = Dict("geomeans" => gs, "verdict" => verdict, "n_tasks" => n)
    end
    return suite
end

arm_desc(meta, label) = begin
    a = meta === nothing ? nothing : get(get(meta, "arms", Dict()), label, nothing)
    a === nothing ? code(label) : code(label) * " " * a["version"] * " (" * a["commit_short"] * ")"
end

function write_comparison(io, opts, meta, tasks, suite, nblocks)
    base, head = opts["base"], opts["head"]
    nreg = sum(t -> length(t["regressions"]), tasks; init = 0) + count(s -> s["verdict"] == "regression", values(suite))
    nimp = sum(t -> length(t["improvements"]), tasks; init = 0) + count(s -> s["verdict"] == "improvement", values(suite))
    println(io, "## ", opts["title"])
    note = isempty(opts["base-note"]) ? "" : ", " * opts["base-note"]
    link = isempty(opts["url"]) ? "" : " · [job](" * opts["url"] * ")"
    println(io, arm_desc(meta, head), " vs ", arm_desc(meta, base), note, " · ", length(tasks), " tasks · ",
            nblocks, " blocks (ABBA)", link, "\n")
    println(io, "**", nreg == 0 ? "No robust regressions" : "$nreg robust regression" * (nreg == 1 ? "" : "s"),
            ", ", nimp, " improvement", nimp == 1 ? "" : "s", ".** ",
            "Robust: the two builds' samples do not overlap and every block agrees beyond the threshold (",
            join([m.name * " " * pct(m.threshold) for m in METRICS], ", "), "); the suite row uses the geometric mean over tasks.\n")
    println(io, "| suite (geomean head/base) | per block | threshold | |")
    println(io, "|---|---|---|---|")
    for m in METRICS
        haskey(suite, m.key) || continue
        s = suite[m.key]
        mark = s["verdict"] == "regression" ? "**regression**" : s["verdict"] == "improvement" ? "improvement" : ""
        println(io, "| ", m.name, " (", s["n_tasks"], s["n_tasks"] == 1 ? " task) | " : " tasks) | ", join(fmtr.(s["geomeans"]), ", "), " | ±", pct(m.suite), " | ", mark, " |")
    end
    for (title, field) in (("Regressions", "regressions"), ("Improvements", "improvements"))
        rows = [(t, k) for t in tasks for k in t[field]]
        isempty(rows) && continue
        println(io, "\n### ", title, "\n")
        println(io, "| task | metric | base (s) | head (s) | head/base per block |")
        println(io, "|---|---|---|---|---|")
        for (t, k) in rows
            if k in ("fails", "fixed")
                println(io, "| ", t["name"], " | | | | ", t["note"], " |")
            else
                m = t["metrics"][k]
                println(io, "| ", t["name"], " | ", k, " | ", join(fmt.(m["base"]), ", "), " | ", join(fmt.(m["head"]), ", "),
                        " | ", join(fmtr.(m["ratios"]), ", "), " |")
            end
        end
    end
    println(io, "\n<details><summary>All tasks (median head/base per metric)</summary>\n")
    println(io, "| task | ", join([m.name for m in METRICS], " | "), " | note |")
    println(io, "|---|", "---|"^length(METRICS), "---|")
    for t in tasks
        cells = map(METRICS) do m
            haskey(t["metrics"], m.key) || return "–"
            v = t["metrics"][m.key]
            s = fmtr(median(v["ratios"]))
            v["verdict"] == "regression" ? "**" * s * "**" : v["verdict"] == "improvement" ? "_" * s * "_" : s
        end
        println(io, "| ", t["name"], " | ", join(cells, " | "), " | ", something(t["note"], ""), " |")
    end
    println(io, "\n</details>")
    return nreg, nimp
end

function write_summary(io, opts, meta, grouped, head, nblocks)
    println(io, "## ", opts["title"])
    link = isempty(opts["url"]) ? "" : " · [job](" * opts["url"] * ")"
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
    return nreg > 0 ? 1 : 0
end

exit(main())
