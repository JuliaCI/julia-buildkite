# The compared metrics and their thresholds: a task's difference must clear `threshold`
# in every block and `floor` (seconds) in its medians, and the suite geomean `suite`
# (ttfx_compare.jl). The driver reads the precompile entry too, to decide which tasks
# precompile again in block 2 with --precompile-once (ttfx_bench.jl). Startup is measured
# once for the build rather than per task, so it has no suite geomean.
const METRICS = [
    (key = "startup",    name = "startup",         threshold = 0.05, suite = nothing, floor = 0.005),
    (key = "startup_repl", name = "startup to REPL prompt", threshold = 0.05, suite = nothing, floor = 0.005),
    (key = "precompile", name = "precompile",      threshold = 0.08, suite = 0.02, floor = 0.25),
    (key = "load",       name = "load (cold)",     threshold = 0.10, suite = 0.02, floor = 0.10),
    (key = "startup_load", name = "startup+load (cold)", threshold = 0.10, suite = 0.02, floor = 0.10),
    (key = "run",        name = "run (cold)",      threshold = 0.15, suite = 0.03, floor = 0.05),
    (key = "warm",       name = "load+run (warm)", threshold = 0.15, suite = 0.03, floor = 0.05),
    (key = "load_stdlibs", name = "load (stdlibs first)", threshold = 0.10, suite = 0.02, floor = 0.10),
    (key = "run_stdlibs",  name = "run (stdlibs first)",  threshold = 0.15, suite = 0.03, floor = 0.05),
]
