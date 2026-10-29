# Runtime benchmarks

A macOS aarch64 job in the `Runtime benchmarks` group runs the
[julia-ci-benchmarks](https://github.com/JuliaCI/julia-ci-benchmarks) suite on the julia a
build produced: ~110 benchmarks of codegen, the runtime, the GC, the scheduler and the
compiler, judged on hardware counters (cycles, and instruction counts that are exact
across processes) rather than wall time where the work stays on one thread. The suite is
checked out from its `main` branch at job time (`RTB_SUITE_REF` pins another ref or a
commit); everything that runs it in CI lives here.

| file | role |
|---|---|
| `pipelines/main/misc/runtime_benchmarks/` | the group launcher (registered in `render_launch_pipeline.py`) and the macOS job |
| `runtime_benchmarks_launch.sh` | the launch step: decides whether this build is measured, uploads the job |
| `paths.txt` | the paths a pull request must touch to be measured without the label |
| `runtime_benchmarks_ci.sh` | the job: fetch the builds, check out the suite, benchmark, compare, report |

The base build lookup, the wait for the merge-base's build and the re-signing are the
TTFX job's (`utilities/ttfx/README.md`), and the build state comes from
`utilities/ttfx/ttfx_build_state.jl`.

## When it runs

| pipeline | measured | mode |
|---|---|---|
| `julia-pr` | only when the pull request touches a path in `paths.txt` (Base, the compiler, lowering, the runtime, LLVM), or has the `needs runtime benchmarks` label | comparison against the master build of the merge-base |
| `julia-ci` (master, release branches) | every build | absolute: the build alone, kept for perf.julialang.org |
| `julia-buildkite-ci` (self-test) | every build | comparison: the julia commit under test against its parent |

## How it measures

The suite's `bench.jl` runs every (block, category, arm) in a fresh process, the arms in
alternating order, `RTB_BLOCKS` (3) blocks; the `parallel` category gets `RTB_THREADS`
(4) threads, the others one. A pull request comparison takes about 6 minutes of
benchmarking, a master build about 3. `compare.jl` reports a benchmark only when every
block agrees beyond its tolerance (3% for cycles, 6% for time, wider where a benchmark
sets its own) and the arms do not overlap; a category's geometric mean moving 1.5% in
every block also counts. The job fails on a regression, and posts the report as an
annotation when there are differences or when it measured a build alone.

Hardware counters: without root the driver reads the calling thread's cycles and
instructions (`thread_selfcounts`); with root it also records branch and L1D misses
through kperf. `CIBENCH_COUNTERS` (`auto`, `kperf`, `thread`, `none`) overrides the
choice.

## Artifacts

| artifact | content |
|---|---|
| `runtime-benchmarks/out/results.json` | one record per benchmark, arm and block: every sample's time and counters, allocations, GC time (the suite README documents the fields) |
| `runtime-benchmarks/out/results-meta.json` | the builds, the machine, the settings, the suite commit, failed processes |
| `runtime-benchmarks/out/report.md`, `compare.json` | the report and, on pull requests, the per-benchmark and per-category verdicts |
| `runtime-benchmarks/out/logs/*.log` | the output of every benchmark process |
| `runtime-benchmarks/benchmark.log` | the orchestrator's log |
