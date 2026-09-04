# TTFX benchmarks

A macOS aarch64 job in the `TTFX` group measures the julia a build produced on the
[Julia-TTFX-Snippets](https://github.com/tecosaur/Julia-TTFX-Snippets) tasks: for each
task, precompile time of its packages from a cleared cache, then the task script's load
time and run time, in fresh processes. The task definitions come from the snippets
repository's `main` branch at job time; everything that runs them lives here.

| file | role |
|---|---|
| `pipelines/main/misc/ttfx/` | the group launcher (registered in `render_launch_pipeline.py`) and the macOS job |
| `ttfx_ci.sh` | the job: fetch the builds, check out the snippets, benchmark, compare, report |
| `ttfx_bench.jl` | the driver: interleaved ABBA measurement, one record per task, arm and block |
| `ttfx_compare.jl` | the verdict and the markdown report |
| `ttfx_build_state.jl` | whether a commit's julia-ci build is pending, done, failed or absent |
| `exclude.txt` | tasks not measured; every other task in the checkout is |

## Pull requests (julia-pr)

Two arms: `head`, the build of the pull request from this build's `build_<triplet>`
step, and `base`, the master build of the merge-base with the target branch. julia-ci
stages every build it makes below its commit sha, so the job fetches the base from
there (falling back to the promoted nightlies once the staged object has expired), and
waits for it if the merge-base's build is still running, up to
`TTFX_BASE_WAIT_MINUTES`. If that build failed or Buildkite never started one, the job
steps back one commit at a time along the branch, up to `TTFX_BASE_LOOKBACK`, and says
so in the report. Both arms are re-signed and their stdlib pkgimage checksums repaired
the same way the test jobs do.

Every task is measured `TTFX_BLOCKS` times per arm, the arm order reversed on alternate
blocks (`base head head base`), so drift over the hour lands on both arms alike. Each
sample clears compiled code and the JIT object cache, precompiles, then runs the task
script `TTFX_REPEATS` times: the first run is the cold measurement, the later ones hit
whatever caches the first populated. The depot holds packages and artifacts only; the
agent user's own depot is not on the path.

A task's metric is a robust regression when the head samples are all slower than every
base sample, every block's head/base ratio exceeds the metric's threshold, and the
difference clears an absolute floor; improvements are the mirror image. Per metric,
the geometric mean of the ratios over the suite is judged per block against a tighter
threshold, which catches a small cost spread across every package. Thresholds are the
`METRICS` table in `ttfx_compare.jl`. A task that fails on head and passes on base is a
regression. The job fails on any robust regression and, either way, posts the report as
a Buildkite annotation and uploads the data as artifacts. Nothing is posted to GitHub
beyond the commit status: the job runs the pull request's own code, so it holds no
GitHub token.

## Master and release branches (julia-ci)

One arm, `head`, measured `TTFX_BLOCKS` times per task; no comparison. The report is
a per-task summary. The data is kept as Buildkite artifacts of the job for
[julia-ci-timing](https://github.com/JuliaCI/julia-ci-timing) or anyone else:

| artifact | content |
|---|---|
| `ttfx/results.json` | records: `arm, package, task, block, order, status, error, precompile_time, load_times, run_times, total_times, packages_hash` |
| `ttfx/results-meta.json` | the builds (`arms.<label>`: version, commit, date, CPU threads seen), machine, settings, task list, snippets commit, Buildkite build |
| `ttfx/report.md`, `ttfx/compare.json` | the report and, on pull requests, the per-task and suite verdicts |
| `ttfx/benchmark.log` | the driver's log |

`load_times[1]` and `run_times[1]` are the cold numbers; `precompile_time` is one
sample per record, take the minimum over blocks for a task.

## Knobs

Environment variables on the job: `TTFX_EXCLUDE` (default `exclude.txt`, or `none`),
`TTFX_BLOCKS` (2), `TTFX_REPEATS` (2), `TTFX_BASE_WAIT_MINUTES` (90),
`TTFX_BASE_LOOKBACK` (10), `TTFX_SNIPPETS_REPO` and `TTFX_SNIPPETS_REF`. The job's budget
is the sum of the tasks' precompile times, times two arms, times the blocks, plus package
downloads: exclude tasks before raising the timeout.
