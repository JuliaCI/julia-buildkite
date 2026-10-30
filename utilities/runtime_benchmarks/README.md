# Runtime benchmarks

A job per platform in the `Runtime benchmarks` group (today macOS aarch64) runs the
[julia-ci-benchmarks](https://github.com/JuliaCI/julia-ci-benchmarks) suite on the julia a
build produced: about 160 benchmarks of codegen, the runtime, the GC, the scheduler and
the compiler, judged on hardware counters (cycles, and instruction counts that are exact
across processes) rather than wall time where the work stays on one thread. The suite
reads them through `thread_selfcounts` on macOS and `perf_event_open` on Linux (which needs
`kernel.perf_event_paranoid` <= 2 and a sandbox that allows the syscall); elsewhere it
judges wall time. A platform is added with a `runtime_benchmarks_<os>.arches` and a
`runtime_benchmarks_<os>.yml` for its agents; the launcher uploads every such pair. The
suite is checked out from its `main` branch at job time (`RTB_SUITE_REF` pins another ref or a
commit); everything that runs it in CI lives here.

| file | role |
|---|---|
| `pipelines/main/misc/runtime_benchmarks/` | the group launcher (registered in `render_launch_pipeline.py`) and a job per platform |
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
| `julia-buildkite-ci` (self-test) | every build | comparison: the build against itself (A/A), so any flag is a harness bug |

## How it measures

The suite's `bench.jl` runs every (block, category, arm) in a fresh process, the arms in
alternating order, `RTB_BLOCKS` (3) blocks; the `parallel` category gets `RTB_THREADS`
(4) threads, the others one. A pull request comparison takes about 6 minutes of
benchmarking, a master build about 3. `compare.jl` reports a benchmark only when every
block agrees beyond its tolerance (3% for cycles, 6% for time, wider where a benchmark
sets its own) and the arms do not overlap; a category's geometric mean moving 1.5% in
every block also counts. A cycles change that the instruction counts do not explain must
exceed 15%: two builds place code differently even when nothing the benchmarks run has
changed, and that alone moves some benchmarks by up to 12%.

On a pull request, regressions are measured again with a third arm, the master build
before the merge-base (`tools/flagged.jl` in the suite picks the flagged benchmarks and
the whole of any flagged category). A regression stands only when head also differs that
way from this control; otherwise two master builds differ as much and the report lists it
as dropped. The job fails on a regression, and posts the report as an annotation when
there are differences or when it measured a build alone.

Hardware counters: without root the driver reads the calling thread's cycles and
instructions (`thread_selfcounts`); with root it also records branch and L1D misses
through kperf. `CIBENCH_COUNTERS` (`auto`, `kperf`, `thread`, `none`) overrides the
choice.

The report ends with a link to the run page on perf.julialang.org
(`/runtime-run?pipeline=...&build=...&job=...`), which reads this job's artifacts from
Buildkite when first opened and draws every benchmark's change against its tolerance, the
categories, instructions against cycles, allocations, and each benchmark's samples per arm
and block (with the control arm of a confirmation run). The job prints the link too.

## Artifacts

| artifact | content |
|---|---|
| `runtime-benchmarks/out/results.json` | one record per benchmark, arm and block: every sample's time and counters, allocations, GC time (the suite README documents the fields) |
| `runtime-benchmarks/out/results-meta.json` | the builds, the machine, the settings, the suite commit, failed processes |
| `runtime-benchmarks/out/report.md`, `compare.json` | the report and, on pull requests, the per-benchmark and per-category verdicts |
| `runtime-benchmarks/out/logs/*.log` | the output of every benchmark process |
| `runtime-benchmarks/out/confirm/` | the same for the confirmation run with the control arm, when there was one; `out/report-first.md` is the report of the first comparison |
| `runtime-benchmarks/benchmark.log` | the orchestrator's log |
