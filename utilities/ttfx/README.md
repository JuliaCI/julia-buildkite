# TTFX benchmarks

A macOS aarch64 job in the `TTFX` group measures the julia a build produced on the
[Julia-TTFX-Snippets](https://github.com/tecosaur/Julia-TTFX-Snippets) tasks: for each
task, precompile time of its packages from a cleared cache, then the task script's load
time and run time, in fresh processes. The task definitions come from the snippets
repository's `main` branch at job time; everything that runs them lives here.

| file | role |
|---|---|
| `pipelines/main/misc/ttfx/` | the group launcher (registered in `render_launch_pipeline.py`) and the macOS job |
| `ttfx_launch.sh` | the launch step: decides whether this build is measured, uploads the job |
| `paths.txt` | the paths a pull request must touch to be measured without the label |
| `ttfx_ci.sh` | the job: fetch the builds, check out the snippets, benchmark, compare, report |
| `ttfx_bench.jl` | the driver: interleaved ABBA measurement, one record per task, arm and block, and the trace-compile runs |
| `ttfx_compare.jl` | the verdict and the markdown report |
| `ttfx_build_state.jl` | whether a commit's julia-ci build is pending, done, failed or absent |
| `exclude.txt` | tasks not measured; every other task in the checkout is |

## When it runs, and in which mode

| pipeline | measured | mode |
|---|---|---|
| `julia-pr` (pull requests) | only when the pull request touches a path in `paths.txt` (`src/`, `Compiler/`, `base/loading.jl`, `base/precompilation.jl`), or has the `needs TTFX check` label | comparison: the pull request's build against the master build of its merge-base |
| `julia-ci` (master, release branches, the nightly schedule) | every build | absolute: the build alone |
| `julia-buildkite-ci` (this repository's self-test) | every build | comparison: the julia master commit under test against its parent |

The group's launch step, `ttfx_launch.sh`, decides. On a pull request without the label it
fetches the target branch and diffs the merge-base against the head, restricted to the
paths in `paths.txt`; when nothing there changed it prints why and uploads no job. If the
target branch cannot be fetched or the merge-base found, the job runs rather than being
skipped on a guess. The `TTFX` commit status is the job's own, so a pull request that is
not measured shows none. Buildkite reads the labels when it creates the build, so a label
added later counts from the pull request's next build.

## Comparison mode: pull requests (julia-pr)

Two arms: `head`, the build of the pull request from this build's `build_<triplet>`
step, and `base`, the master build of the merge-base with the target branch. julia-ci
stages every build it makes below its commit sha, so the job fetches the base from
there (falling back to the promoted nightlies once the staged object has expired), and
waits for it if the merge-base's build is still running, up to
`TTFX_BASE_WAIT_MINUTES` (20 minutes, about one macOS aarch64 build; the job holds a
macOS agent while it waits). There is no substitute base: if the wait runs out, or that
build failed or was never started, the job fails and says why, and can be retried once
the build exists. Both arms are re-signed and their stdlib pkgimage checksums repaired
the same way the test jobs do.

Every task is measured `TTFX_BLOCKS` times per arm, the arm order reversed on alternate
blocks (`base head head base`), so drift over the hour lands on both arms alike. Each
sample clears compiled code and the JIT object cache, precompiles once, then runs the
task script `TTFX_REPEATS` times (three) in fresh processes: the first run is the cold
measurement, the later ones hit whatever caches the first populated. After the timed runs
of block 1 the script runs once more per arm, not timed, with `--trace-compile` and
`--trace-compile-timing`; those logs are the `trace-compile.tar.gz` artifact. The depot
holds packages and artifacts only; the agent user's own depot is not on the path.

A task's metric is a robust regression when the head samples are all slower than every
base sample, every block's head/base ratio exceeds the metric's threshold, and the
difference clears an absolute floor; improvements are the mirror image. Per metric,
the geometric mean of the ratios over the suite is judged per block against a tighter
threshold, which catches a small cost spread across every package. Thresholds are the
`METRICS` table in `ttfx_compare.jl`. A task that fails on head and passes on base is a
regression; one that fails on both is listed in `compare.json` and left out of the
verdict. A task stops at its first failed sample rather than finishing its blocks, and
its log group is expanded with the failure in red.

The job fails on any robust regression. The report is posted as a Buildkite annotation
only when it has differences to show; a clean comparison leaves the green status, the
report and the data as artifacts. Nothing is posted to GitHub beyond the commit status:
the job runs the pull request's own code, so it holds no GitHub token.

In this repository's own self-test pipeline the commit under test is a julia master
commit, and its parent stands in for the merge-base, so the same path runs there.

## Absolute mode: master and release branches (julia-ci)

One arm, `head`, measured `TTFX_BLOCKS` times per task; no comparison (`standalone` in
`ttfx_ci.sh`). The report is a per-task summary. The data is kept as Buildkite artifacts
of the job for [julia-ci-timing](https://github.com/JuliaCI/julia-ci-timing) or anyone
else:

| artifact | content |
|---|---|
| `ttfx/results.json` | records: `arm, package, task, block, order, status, error, precompile_time, load_times, run_times, total_times, packages_hash` |
| `ttfx/results-meta.json` | the builds (`arms.<label>`: version, commit, date, CPU threads seen), machine, settings, task list, snippets commit, Buildkite build |
| `ttfx/report.md`, `ttfx/compare.json` | the report and, on pull requests, the per-task and suite verdicts |
| `ttfx/benchmark.log` | the driver's log |
| `ttfx/logs/*.log` | full stdout and stderr of every subprocess that failed |
| `ttfx/trace-compile.tar.gz` | `trace/<Package>-<Task>-<arm>.log`: the `--trace-compile --trace-compile-timing` output of one extra run of the task script per task and arm, after the timed runs of block 1 and not timed itself |

`load_times[1]` and `run_times[1]` are the cold numbers; `precompile_time` is one
sample per record, take the minimum over blocks for a task.

## Knobs

Environment variables on the job: `TTFX_EXCLUDE` (default `exclude.txt`, or `none`),
`TTFX_BLOCKS` (2), `TTFX_REPEATS` (3), `TTFX_BASE_WAIT_MINUTES` (20),
`TTFX_SNIPPETS_REPO` and `TTFX_SNIPPETS_REF`; on the launch step, `TTFX_PATHS` (default
`paths.txt`). The job's budget is the sum of the tasks' precompile times, times two arms,
times the blocks, plus one untimed run of every task script per arm, plus package
downloads: exclude tasks before raising the timeout.
