# Orchestrates a stdlib precompile/load-time regression comparison between two
# Julia binaries:
#
#   A = the Julia built by this CI pipeline (the "candidate")
#   B = the Julia nightly associated with the merge-base commit (the "baseline")
#
# For each binary, across several rounds, we:
#   1. Force a fresh re-precompilation of every loadable stdlib into an isolated,
#      writable depot (so we never reuse the bundled pkgimages), timing the whole
#      precompile.
#   2. Measure the time to load each stdlib from that freshly-populated depot.
#
# The work runs entirely against a throwaway depot via `Base.compilecache` /
# `Base.require`, so it needs no registry, manifest, or network.
#
# To control for machine noise we run the rounds in an A/B/B/A/B/A order and take
# the per-binary minimum of each metric (the least noise-perturbed sample) before
# comparing.
#
# We flag two kinds of "clear regression", each requiring the candidate to be both
# relatively and absolutely slower than the baseline:
#   * total precompile time -- relative `PRECOMPILE_REL_THRESHOLD` (default 1.5x)
#     and absolute `PRECOMPILE_ABS_THRESHOLD_S` (default 10s).
#   * per-stdlib (or aggregate) load time -- relative `LOADTIME_REL_THRESHOLD`
#     (default 1.5x) and absolute `LOADTIME_ABS_THRESHOLD_MS` (default 100ms).
# If any regression is found, the script exits non-zero.
#
# Usage: julia compare_stdlib_load_times.jl --a <juliaA> --b <juliaB>

const MEASURE_SCRIPT = joinpath(@__DIR__, "measure_stdlib_load_times.jl")

function parse_args(args)
    a = b = nothing
    i = 1
    while i <= length(args)
        if args[i] == "--a"
            a = args[i + 1]; i += 2
        elseif args[i] == "--b"
            b = args[i + 1]; i += 2
        else
            error("Unknown argument: $(args[i])")
        end
    end
    (a === nothing || b === nothing) && error("Both --a and --b must be provided")
    return abspath(a), abspath(b)
end

# Read a TSV of `name<TAB>seconds` into a Dict.
function read_timings(path)
    timings = Dict{String,Float64}()
    for line in eachline(path)
        isempty(strip(line)) && continue
        name, t = split(line, '\t')
        timings[String(name)] = parse(Float64, t)
    end
    return timings
end

# Create an isolated, initially-empty depot for `julia`. It contains no compiled
# cache, so stdlibs are forced to (re)precompile into it; we symlink the binary's
# bundled `artifacts` directory so JLL stdlibs can still resolve their artifacts.
function setup_depot(julia::String)
    depot = mktempdir(; prefix = "stdlib-loadtime-")
    bundled = readchomp(`$(julia) --startup-file=no -e 'print(DEPOT_PATH[end])'`)
    artifacts = joinpath(bundled, "artifacts")
    if isdir(artifacts)
        symlink(artifacts, joinpath(depot, "artifacts"))
    end
    return depot
end

# Run the measure helper with `julia` against the isolated `depot` as the *only*
# depot (a single path, no trailing `:`), so cache lookups never fall through to
# the bundled pkgimages. Returns the path of the output file it wrote.
function run_measure(julia::String, depot::String, mode::String, args...)
    out = tempname()
    env = copy(ENV)
    env["JULIA_DEPOT_PATH"] = depot
    run(setenv(`$(julia) --startup-file=no $(MEASURE_SCRIPT) $(mode) $(out) $(args...)`, env))
    return out
end

# Per-key minimum across repeated samples (each a Dict). The min is the least
# noise-perturbed sample, so it's the most robust estimate of true load time.
function min_load(samples)
    keysets = (Set(keys(s)) for s in samples)
    common = reduce(intersect, keysets)
    return Dict(k => minimum(s[k] for s in samples) for k in common)
end

# Load time of every stdlib in `names`, each in its own fresh process (loading one
# stdlib pulls in its deps, so a shared session would report later ones as already
# resident). Returns a `name => seconds` Dict for this sample.
function measure_sample(julia::String, depot::String, names)
    timings = Dict{String,Float64}()
    for name in names
        merge!(timings, read_timings(run_measure(julia, depot, "measure", name)))
    end
    return timings
end

# One measurement round for `julia`: create a fresh, isolated depot, precompile
# every stdlib into it (timing it), then measure each stdlib's warm-cache load
# time. The depot is removed afterward so repeated rounds don't pile up compiled
# caches. Returns `(precompile_seconds, name => load_seconds Dict)`.
function measure_round(julia::String)
    depot = setup_depot(julia)
    try
        lines = readlines(run_measure(julia, depot, "precompile"))
        precompile_s = parse(Float64, lines[1])
        names = lines[2:end]
        return precompile_s, measure_sample(julia, depot, names)
    finally
        rm(depot; recursive = true, force = true)
    end
end

function main()
    julia_a, julia_b = parse_args(ARGS)

    rel_threshold = parse(Float64, get(ENV, "LOADTIME_REL_THRESHOLD", "1.5"))
    abs_threshold = parse(Float64, get(ENV, "LOADTIME_ABS_THRESHOLD_MS", "100")) / 1000
    pre_rel_threshold = parse(Float64, get(ENV, "PRECOMPILE_REL_THRESHOLD", "1.5"))
    pre_abs_threshold = parse(Float64, get(ENV, "PRECOMPILE_ABS_THRESHOLD_S", "10"))

    # Run the precompile+load rounds in A/B/B/A/B/A order so machine drift/noise is
    # spread across both binaries, then take the per-binary minimum of each metric.
    println("--- Round 1: precompile + load (A)"); pa1, a1 = measure_round(julia_a)
    println("--- Round 1: precompile + load (B)"); pb1, b1 = measure_round(julia_b)
    println("--- Round 2: precompile + load (B)"); pb2, b2 = measure_round(julia_b)
    println("--- Round 2: precompile + load (A)"); pa2, a2 = measure_round(julia_a)
    println("--- Round 3: precompile + load (B)"); pb3, b3 = measure_round(julia_b)
    println("--- Round 3: precompile + load (A)"); pa3, a3 = measure_round(julia_a)

    pre_a = minimum((pa1, pa2, pa3))
    pre_b = minimum((pb1, pb2, pb3))
    a_load = min_load((a1, a2, a3))
    b_load = min_load((b1, b2, b3))

    common = sort!(collect(intersect(keys(a_load), keys(b_load))))

    regressions = Tuple{String,Float64,Float64,Float64}[]
    rows = Tuple{String,Float64,Float64,Float64,Bool}[]
    total_a = total_b = 0.0
    for name in common
        ta, tb = a_load[name], b_load[name]
        total_a += ta
        total_b += tb
        ratio = tb > 0 ? ta / tb : 1.0
        is_reg = (ta > tb * rel_threshold) && (ta - tb > abs_threshold)
        push!(rows, (name, ta, tb, ratio, is_reg))
        is_reg && push!(regressions, (name, ta, tb, ratio))
    end

    sort!(rows; by = r -> r[4], rev = true)

    println("+++ Stdlib load-time comparison (A = candidate, B = merge-base nightly)")
    println(rpad("stdlib", 32), lpad("A (ms)", 12), lpad("B (ms)", 12), lpad("A/B", 10))
    for (name, ta, tb, ratio, is_reg) in rows
        println(
            rpad(name, 32),
            lpad(round(ta * 1000; digits = 2), 12),
            lpad(round(tb * 1000; digits = 2), 12),
            lpad(round(ratio; digits = 3), 10),
            is_reg ? "  <-- REGRESSION" : "",
        )
    end

    total_ratio = total_b > 0 ? total_a / total_b : 1.0
    pre_ratio = pre_b > 0 ? pre_a / pre_b : 1.0
    precompile_regression = (pre_a > pre_b * pre_rel_threshold) &&
                            (pre_a - pre_b > pre_abs_threshold)
    total_regression = (total_a > total_b * rel_threshold) &&
                       (total_a - total_b > abs_threshold)

    println()
    println("Precompile total: A = ", round(pre_a; digits = 2), "s, ",
            "B = ", round(pre_b; digits = 2), "s, ",
            "A/B = ", round(pre_ratio; digits = 3),
            precompile_regression ? "  <-- REGRESSION" : "")
    println("Load total:       A = ", round(total_a * 1000; digits = 2), "ms, ",
            "B = ", round(total_b * 1000; digits = 2), "ms, ",
            "A/B = ", round(total_ratio; digits = 3),
            total_regression ? "  <-- REGRESSION" : "")
    println("Precompile thresholds: relative > ", pre_rel_threshold,
            "x and absolute > ", round(pre_abs_threshold; digits = 1), "s")
    println("Load thresholds:       relative > ", rel_threshold,
            "x and absolute > ", round(abs_threshold * 1000; digits = 1), "ms")

    if isempty(regressions) && !total_regression && !precompile_regression
        println("\n✓ No clear stdlib precompile- or load-time regressions detected.")
        return 0
    end

    println("\n✗ Clear stdlib precompile/load-time regression(s) detected:")
    if precompile_regression
        println("  - total precompile time: ", round(pre_a; digits = 2), "s vs ",
                round(pre_b; digits = 2), "s (", round(pre_ratio; digits = 3), "x)")
    end
    for (name, ta, tb, ratio) in regressions
        println("  - ", name, ": ", round(ta * 1000; digits = 2), "ms vs ",
                round(tb * 1000; digits = 2), "ms (", round(ratio; digits = 3), "x)")
    end
    if total_regression
        println("  - aggregate load time: ", round(total_a * 1000; digits = 2),
                "ms vs ", round(total_b * 1000; digits = 2), "ms (",
                round(total_ratio; digits = 3), "x)")
    end
    return 1
end

exit(main())
