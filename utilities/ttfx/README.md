# TTFX benchmarks

A macOS aarch64 job in the `TTFX` group measures the julia a build produced on the
[Julia-TTFX-Snippets](https://github.com/tecosaur/Julia-TTFX-Snippets) tasks: for each
task, precompile time of its packages from a cleared cache, then the task script's load
time and run time, in fresh processes. The task definitions come from the snippets
repository's `main` branch at job time; everything that runs them lives here.

| file | role |
|---|---|
| `pipelines/main/misc/ttfx/` | the group launcher (registered in `render_launch_pipeline.py`), the macOS job, and its release and optimized-build variants |
| `ttfx_launch.sh` | the launch step: decides whether this build is measured, uploads the job |
| `paths.txt` | the paths a pull request must touch to be measured without the label |
| `ttfx_ci.sh` | the job: fetch the builds, check out the snippets, benchmark, compare, report |
| `ttfx_bench.jl` | the driver: interleaved ABBA measurement, one record per task, arm and block, and the untimed trace and invalidation run |
| `ttfx_invalidations.jl` | loaded by a task script in the untimed trace run: summarizes the invalidations of its load and run phases |
| `ttfx_compare.jl` | the verdict and the markdown report |
| `ttfx_metrics.jl` | the compared metrics and their thresholds, shared by the driver and the comparison |
| `ttfx_build_state.jl` | whether a commit's julia-ci build is pending, done, failed or absent |
| `exclude.txt` | tasks not measured; every other task in the checkout is |

## When it runs, and in which mode

| pipeline | measured | mode |
|---|---|---|
| `julia-pr` (pull requests) | only when the pull request touches a path in `paths.txt` (`src/`, `Compiler/`, `base/loading.jl`, `base/precompilation.jl`), or has the `needs TTFX check` label | comparison: the pull request's build against the build of its merge-base (master's, or the base pull request's when stacked) |
| `julia-ci` (master, release branches) | every build | absolute: the build alone |
| `julia-ci` (the daily schedule) | the optimized macOS aarch64 build | comparison: the optimized build against the regular build of the same commit |
| `julia-ci` (the weekly `TTFX_RELEASE` schedule) | the newest stable release, the LTS, and the next release's nightly | absolute: each release alone, as a reference |
| `julia-buildkite-ci` (this repository's self-test) | every build | comparison: the julia master commit under test against its parent |

The group's launch step, `ttfx_launch.sh`, decides. On a pull request without the label it
fetches the target branch and diffs the merge-base against the head, restricted to the
paths in `paths.txt`; when nothing there changed it prints why and uploads no job. If the
target branch cannot be fetched or the merge-base found, the job runs rather than being
skipped on a guess. The `TTFX` commit status is the job's own, so a pull request that is
not measured shows none. Buildkite records the labels when it creates a build, and a rebuild
from the Buildkite UI keeps those of the build it repeats, so when the label is not among
them the launch step asks GitHub for the pull request's current labels. Adding the label and
rebuilding is therefore enough. If GitHub cannot be reached, the paths decide.

## Comparison mode: pull requests (julia-pr)

Two arms: `head`, the build of the pull request from this build's `build_<triplet>`
step, and `base`, the master build of the merge-base with the target branch. julia-ci
stages every build it makes below its commit sha, so the job fetches the base from
there (falling back to the promoted nightlies once the staged object has expired), and
waits for it if the merge-base's build is still running, up to
`TTFX_BASE_WAIT_MINUTES` (20 minutes, about one macOS aarch64 build; the job holds a
macOS agent while it waits). A pull request stacked on another one targets that pull
request's branch, so its merge-base was built by julia-pr instead; the job then fetches
it from julia-pr's staging bucket. Buildkite ignores a push whose commit message says
`[ci skip]` or `[skip ci]`, so when the merge-base is such a commit the job walks back
along the target branch to the nearest one that was built, and compares against that.
Otherwise there is no substitute base: if the wait runs out, or that build failed or
was never started, the job fails and says why, and can be retried once the build
exists. Both arms are re-signed and their stdlib pkgimage checksums repaired the same
way the test jobs do.

Every task is measured `TTFX_BLOCKS` times per arm, the arm order reversed on alternate
blocks (`base head head base`), so drift over the hour lands on both arms alike. Each
sample clears compiled code and the JIT object cache, precompiles once, loads the
project's packages once in an untimed process (and clears the object cache again), then runs the
task script `TTFX_REPEATS` times (three) in fresh processes: the first run is the cold
measurement, the later ones hit whatever caches the first populated. The script then runs
`TTFX_REPEATS` more times with the GC disabled (see the artifact table below), and once
in a copy of the project that has every stdlib added and loaded first (below). After the timed runs
of block 1 the script runs once more per arm, not timed, tracing compilation from its
first marker to its last as `@trace_compile` does (every method compiled, and how long
it took; Julia 1.12 and later) and logging invalidations over the same span (below);
the traces are the `trace-compile.tar.gz` artifact. The depot
holds packages and artifacts only; the agent user's own depot is not on the path.

Precompiling is most of the job's time, and on a pull request each task is precompiled
once per arm, in block 1 (`TTFX_PRECOMPILE_ONCE`, ttfx_bench.jl `--precompile-once`).
The arm's package images are moved aside after that sample and back into the depot for
its sample in block 2, which measures load and run from them and records no precompile
time. A task whose block-1 precompile times differ by more than the precompile threshold
and floor is precompiled again in block 2: only those could be judged a regression or an
improvement, which needs every block to agree. So that neither arm always precompiles
first, the arm order also alternates from task to task (`base head head base`, then
`head base base head`). The first precompile of a task in a job can be slow (GMT's is
about 8% slower), and the second block keeps that from becoming a verdict. Master and release
builds keep a precompile in every block, since their series is read commit to commit,
and so does a pull request with the `needs TTFX check` label; the report says so when
precompile was measured once.

A task's metric is a robust regression when the head samples are all slower than every
base sample, every block's head/base ratio exceeds the metric's threshold, and the
difference clears an absolute floor; improvements are the mirror image. Load and run are
judged twice, as measured and from the repeats with the GC off (the stdlibs-first load
and run with their GC time subtracted), and either counts: a difference that only shows with the
GC on was GC pauses, one that only shows with it off was hidden by them. The exception is a collection that moved between the phases: when
a load or run difference shows with the GC on only, and that phase's change in GC time
is at least half offset by the opposite change in the other phase, the report lists it
under "GC moved between load and run" and it does not count. Per metric,
the geometric mean of the ratios over the suite is judged per block against a tighter
threshold, which catches a small cost spread across every package. Precompile is judged
on the blocks that measured it; on a pull request its suite geomean is a single one, of
each task's fastest head sample over its fastest base sample. Thresholds are the
`METRICS` table in `ttfx_compare.jl`. A task that fails on head and passes on base is a
regression; one that fails on both is listed in `compare.json` and left out of the
verdict. A task stops at its first failed sample rather than finishing its blocks, and
its log group is expanded with the failure in red.

The job fails on any robust regression. The report is posted as a Buildkite annotation
only when it has differences to show; a clean comparison leaves the green status, the
report and the data as artifacts. Nothing is posted to GitHub beyond the commit status:
the job runs the pull request's own code, so it holds no GitHub token.

In this repository's own self-test pipeline the commit under test is a julia master
commit, and its parent stands in for the merge-base (or, past `[ci skip]` commits, its
nearest built ancestor), so the same path runs there.

## Absolute mode: master and release branches (julia-ci)

One arm, `head`, measured `TTFX_BLOCKS` times per task; no comparison (`standalone` in
`ttfx_ci.sh`). The report is a per-task summary. The data is kept as Buildkite artifacts
of the job for [julia-ci-timing](https://github.com/JuliaCI/julia-ci-timing) or anyone
else:

| artifact | content |
|---|---|
| `ttfx/results.json` | records: `arm, package, task, block, order, status, error, precompile_time, load_times, run_times, total_times, load_stats, run_stats, load_times_gcoff, run_times_gcoff, total_times_gcoff, load_stats_gcoff, run_stats_gcoff, gc_after_load, error_gcoff, invalidations, packages_hash, precompile_time_stdlibs, load_times_stdlibs, run_times_stdlibs, total_times_stdlibs, load_stats_stdlibs, run_stats_stdlibs, error_stdlibs` |
| `ttfx/results-meta.json` | the builds (`arms.<label>`: version, commit, date, CPU threads seen), machine, settings, task list, snippets commit, Buildkite build |
| `ttfx/report.md`, `ttfx/compare.json` | the report and, on pull requests, the per-task and suite verdicts |
| `ttfx/benchmark.log` | the driver's log |
| `ttfx/logs/*.log` | full stdout and stderr of every subprocess that failed |
| `ttfx/trace-compile.tar.gz` | `trace/<Package>-<Task>-<arm>.log`: the `--trace-compile --trace-compile-timing` lines of one extra run of the task script per task and arm, from its first marker to its last, after the timed runs of block 1 and not timed itself |

`load_times[1]` and `run_times[1]` are the cold numbers; `precompile_time` is one
sample per record, take the minimum over blocks for a task. On a pull request it is null
after block 1, as is `precompile_time_stdlibs`, unless the task precompiled again.
`load_stats` and `run_stats` hold, per repeat, what `@time` reports besides wall time for
that phase: `gc_time`, `gc_pauses`, `gc_full`, `allocd` (bytes), `compile_time` and
`recompile_time` (seconds). The driver gets them by running an instrumented copy of the
task script (`task_ttfx.jl`, written next to `task.jl` in the arm's project copy) that
snapshots the GC and compile-time counters at the script's `__t1`/`__t2`/`__t3` markers,
with `Base.cumulative_compile_timing(true)` enabled as `@time` does. A script without
those markers runs as it is and records no stats. They tell a GC pause or a
recompilation apart from a genuinely slower load or first call.

After the normal repeats the instrumented script runs the same number of times again with
`TTFX_GC=off`, with the JIT object cache cleared first so the first of them is as cold as
the first normal repeat: the GC is disabled before the first marker, one full collection is forced
right after the load phase (its time is `gc_after_load` and is excluded from both phases),
and the GC stays off through the run phase. `load_times_gcoff` and `run_times_gcoff` are
therefore the phases without any GC pause in them, and the difference to the normal repeats
is what the GC cost. The operating system's first-load cost of the freshly written
pkgimages (sizeable on macOS), which only the first process after precompiling pays and
clearing the object cache does not bring back, is taken by one untimed process that loads
the project's packages right after precompiling, so it is in neither set's cold load. These runs
do not affect `status`; if one fails (a task that allocates
too much to run without collection, say) the message is kept in `error_gcoff` and the
normal numbers stand.

The same untimed run logs invalidations from the script's first marker to its last (the logs
`SnoopCompileCore.@snoop_invalidations` reads, without the package). `invalidations` in
the block 1 record holds, for the `load` and `run` phases: `invalidated`, the
MethodInstances whose compiled code was dropped; `by_definition`, those invalidated by a
method definition, and `definitions`, how many definitions invalidated anything;
`rejected_at_load`, package-image code not reinstated on load because an edge no longer
holds; and `top_definitions` and `top_rejected`, the five causes with the most, as
`[method, count]`. Logging slows loading by up to a sixth, so it is kept out of the timed
runs; the summary is compiled after tracing stops, so it stays out of the trace. The
counts are deterministic for a given build and set of package versions.

Each task also runs in a second copy of its project, with every stdlib of the build added as
a dependency and imported before the first marker (`TTFX_STDLIBS`, on by default). Each
task alone loads few methods from outside its own dependencies, so it rarely takes the
slower path a package image's edges and activations take when other packages have added
methods to the functions they use. A user who loads several unrelated packages hits that
path, and this run reproduces it cheaply: the stdlibs are already precompiled. They are
added to the project rather than loaded from the stdlib directory, so the extensions they
trigger are precompiled with everything else and each stdlib loads at its resolved
version. After the normal and GC-off repeats, the copy is precompiled and loaded once,
untimed, and the task runs once, cold: `load_times_stdlibs`, `run_times_stdlibs` and
their stats. They are compared as `load (stdlibs first)` and `run (stdlibs first)`, with
the thresholds of the normal load and run. There is no GC-off repeat of this run, so each
phase's GC time is subtracted to stand in for one; they are judged like the GC-off load
and run, including the check for a collection that moved between them.
`precompile_time_stdlibs` is recorded but not compared: it follows the task's own
precompile in the same depot, so it is mostly the extensions the stdlibs trigger, and a
large value means adding them changed the resolved versions. A failure here is kept in `error_stdlibs` and does not
affect `status`.

## Release reference: the weekly schedule (julia-ci)

A second `julia-ci` schedule runs on Saturday nights (`0 4 * * 0` UTC) with
`TTFX_RELEASE=latest` in its environment. The renderer then emits nothing but the
`TTFX release` group (`pipelines/main/misc/ttfx/ttfx_release.yml`), and the job
measures the newest stable release of Julia instead of a build: it asks GitHub for the
latest release of JuliaLang/julia (never a prerelease), downloads that version's macOS
aarch64 tarball from the releases bucket, and runs the absolute mode on it. The result
is one more `results.json` and `results-meta.json` per week, on the same machines and
task set as the master runs, with the release's version in `arms.head.version`; it
goes next to the master series on perf.julialang.org, labelled with the version. Weekly
rather than once per release because the machines, the task set and the packages a task
resolves all move, so last month's number would not be comparable to this week's master.

A second job in the same group measures the newest patch release of the LTS series
(`TTFX_RELEASE=1.10`, set in `ttfx_release.yml`; move it on when a new LTS is named). A
series such as `1.10` resolves through the releases bucket's `versions.json`, leaving out
prereleases.

A third job measures the newest nightly of the next release's branch
(`TTFX_RELEASE=branch-nightly`): the oldest `release-x.y` branch of JuliaLang/julia whose
series has no stable release in `versions.json`. Only later minors of the current major,
or the next major's `x.0`, count, which keeps out placeholders such as `release-9.999`.
So it moves from 1.14 to 1.15 once 1.14.0 is out and `release-1.15` is cut. Between the
two, and in the day or so before a new branch has a nightly, the job measures nothing and
passes. The nightly is the `julia-latest` tarball below the series in the nightlies
bucket; `TTFX_RELEASE=1.14-nightly` names a branch directly.

The jobs' labels and keys (`:macos: TTFX release <triplet>`, `ttfx_release_<triplet>`;
`:macos: TTFX lts <triplet>`, `ttfx_lts_<triplet>`; `:macos: TTFX branch nightly <triplet>`,
`ttfx_branch_nightly_<triplet>`) differ from the master job's, which is how julia-ci-timing
tells them apart. To measure a specific release, create a julia-ci build on `master` with
`TTFX_RELEASE=1.13.1` (say) in its environment; the LTS and nightly jobs run only when
`TTFX_RELEASE` is `latest`.

## Optimized builds: the daily schedule (julia-ci)

The daily `julia-ci` schedule builds Julia with `JULIA_CI_BUILD_MODE=opt` (PGO and
ThinLTO, `contrib/optimized`), which no per-commit build measures. After the
`build_aarch64-apple-darwinopt` step, the `TTFX opt` group
(`pipelines/main/misc/ttfx/ttfx_opt.yml`) runs the comparison mode with
`TTFX_BASE=commit`: `head` is the optimized build and `base` the regular master build
of the same commit, fetched (and waited for) as a pull request's merge-base is. Both are
measured interleaved in the same job, so the difference is what the optimizations buy,
free of the drift between two separate jobs. The renderer emits it on the schedule
itself only, not for pull requests labelled `needs extended CI`.

A "regression" in this job is the optimized build being slower than the regular one;
the job is `soft_fail`, so it never fails the nightly, and it posts no commit status
(the master job's `TTFX` status is on the same commit). Its label and key
(`:macos: TTFX opt <triplet>`, `ttfx_opt_<triplet>`) keep it apart for julia-ci-timing,
which draws the optimized build next to the master series with the paired difference.

## Knobs

Environment variables on the job: `TTFX_EXCLUDE` (default `exclude.txt`, or `none`),
`TTFX_BLOCKS` (2), `TTFX_REPEATS` (3), `TTFX_STDLIBS` (`on`, or `off`), `TTFX_PRECOMPILE_ONCE`
(`on` on pull requests without the `needs TTFX check` label and on the self-test, `off`
elsewhere), `TTFX_BASE_WAIT_MINUTES` (20),
`TTFX_SNIPPETS_REPO` and `TTFX_SNIPPETS_REF`, `TTFX_RELEASE` (`latest`, a series such as
`1.10`, a release branch's nightly such as `1.14-nightly`, `branch-nightly`, or a version; unset measures the build), `TTFX_BASE` (`commit` compares with the regular build of the
same commit; unset uses the merge-base on pull requests), `TTFX_RELEASES_URL` and
`TTFX_LATEST_RELEASE_API`, `TTFX_VERSIONS_URL`; on the
launch step, `TTFX_PATHS` (default `paths.txt`). The job's budget is the sum of the tasks' precompile times, times two arms,
times the blocks (one block with `TTFX_PRECOMPILE_ONCE=on`), plus one untimed run of every task script per arm, plus the stdlibs-first
run of every sample, plus package
downloads: exclude tasks before raising the timeout.
