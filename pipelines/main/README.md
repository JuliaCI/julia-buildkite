## Main pipeline

This directory contains most of the builders. They are triggered by GitHub
webhook events (pushes and pull requests).

Builds are split across three Buildkite pipelines by trust level (see
`ops/README.md` for why):

| Pipeline        | Builds                                            | Trust                          |
| --------------- | ------------------------------------------------- | ------------------------------ |
| `julia-pr`      | pull requests                                     | untrusted (stage only)         |
| `julia-ci`      | `master`, `release-*`, tags, and scheduled nightlies | untrusted to sign; triggers publish |
| `julia-publish` | (triggered by `julia-ci`) signs + promotes        | trusted (KMS signing keys)     |

The daily `julia-ci` schedule runs coverage, a from-source assertion build
with rr tests, no-GPL builds for Linux, macOS, and Windows, and optimized
builds for x86-64, i686 and aarch64 Linux, for x86-64 and aarch64 macOS, and
for x86-64 Windows. The optimized builds use `JULIA_CI_BUILD_MODE=opt` to run Julia's
`contrib/optimized` flow: PGO and ThinLTO everywhere, plus BOLT on Linux
x86-64 and aarch64. They have allow-fail tests, and the macOS aarch64 one is
measured on the TTFX tasks against the regular build of the same commit
(`utilities/ttfx/README.md`). The schedule does not repeat
the per-commit groups. `julia-publish` promotes the scheduled artifacts;
no-GPL builds go to `julialang-nogpl`, while optimized builds use
`julialangnightlies/bin/linuxopt/`, `.../macosopt/` and `.../windowsopt/`.

Release tag and `release-*` branch builds also build the no-GPL binaries and
publish them to `julialang-nogpl`, so each release series gets no-GPL nightlies
on every push without a schedule of its own.

They build and publish the optimized binaries too, to the same `linuxopt/`,
`macosopt/` and `windowsopt/` folders: as the release series' nightlies for
`release-*` pushes, under their version names for tags. On a tag, each
optimized platform publishes only once its tests pass; create the build with
`OPT_TESTS_ALLOW_FAIL=true` to publish despite a failure that is understood.
Nightlies, from `release-*` pushes and the master schedule alike, publish
regardless. A failing optimized test never holds back
the standard binaries. Variant installers are named after the variant
(`Julia-1.14-opt.app`; `Julia-1.14.0-opt` and "Julia 1.14.0 (opt)" on Windows)
so they install next to the standard build.

The schedule, release tags and `release-*` pushes also cross-compile Julia for
riscv64 Linux on x86-64 hosts that run riscv64 code with qemu-user (agent tag
`binfmt_riscv64`), and publish it to `julialangnightlies/bin/linux/riscv64/`.
There is no riscv64 hardware in the fleet, so it has no test job, and the
build is allowed to fail.

A second `julia-ci` schedule, Saturday nights with `TTFX_RELEASE=latest`, builds
nothing and measures the newest stable release, the LTS and the next release's nightly on the
TTFX tasks instead, as references for the master series (see `utilities/ttfx/README.md`).

Pull requests with the `needs full CI` label also run the scheduled workloads.
Coverage data is collected but not uploaded to Codecov or Coveralls.

The x86-64 Linux assertion build is tested under rr (with the `rr` and
`rr-net` jobs) only in `julia-ci`; pull requests test it without rr.

Each build step stages its unsigned tarball directly (write-once, no relay
jobs) to a commit-sha-gated path in its pipeline's own ephemeral staging
bucket: `julia-pr` builds go to `julialang-ephemeral-pr` (where juliaup
finds PR binaries) and stop there, so a PR's binaries are available as
soon as its build job finishes. Trusted-ref builds run in `julia-ci`, stage
to `julialang-ephemeral-ci`, and trigger `julia-publish` once per platform,
as soon as that platform's build and test jobs are green (plus once for the
docs), which signs and promotes — reading only the `julia-ci` bucket.
`julia-publish` does not build pull requests, so a PR can never reach the
signing keys or feed artifacts into publishing.

## Bounds-checked stdlib package images

For Julia trees with `make checkbounds-pkgimages`, each build produces a normal
Julia tarball and a `.checkbounds.tar.gz` companion. Test jobs install the
companion from the same build before running the suite. Older Julia trees retain
their bundled images and need no extra download. Coverage jobs continue to build
and use their own instrumented images.

The publish pipeline signs and publishes both archives for nightlies and releases;
release promotion also carries the companion and its signature into the release
bucket and checksum manifests. The companion contains `share/julia/compiled/...`
and can be used as an additional depot, without modifying the Julia installation:

```sh
mkdir -p ~/julia-checkbounds
tar -xzf julia-VERSION-PLATFORM.checkbounds.tar.gz -C ~/julia-checkbounds
export JULIA_DEPOT_PATH=":$HOME/julia-checkbounds/share/julia"
```

Keep the default depots (the leading `:`); they provide the stdlib sources. For
installations the user owns, such as an extracted tarball, the companion can
instead be extracted into the installation root. Test jobs do this, since they
use the unsigned tarball from the same build. Without a companion, Julia
precompiles the stdlibs on first use with `--check-bounds=yes`.

Use the companion from the same build, platform and variant as the Julia binary.
It is published next to the matching tarball, with `.tar.gz` replaced by
`.checkbounds.tar.gz`, together with a `.checkbounds.tar.gz.asc` signature:

- Releases (`julialang-s3.julialang.org`, also listed in
  `bin/checksums/julia-<version>.sha256`), for example
  `https://julialang-s3.julialang.org/bin/linux/x64/1.14/julia-1.14.0-linux-x86_64.checkbounds.tar.gz`
  or `https://julialang-s3.julialang.org/bin/mac/aarch64/1.14/julia-1.14.0-macaarch64.checkbounds.tar.gz`.
- Nightlies and release-branch builds (`julialangnightlies-s3.julialang.org`), by
  the first 10 characters of the build's commit, for example
  `https://julialangnightlies-s3.julialang.org/bin/linux/x86_64/1.14/julia-e05d3ffe66-linux-x86_64.checkbounds.tar.gz`.
  For an installed nightly, get them with
  `julia -e 'print(first(Base.GIT_VERSION_INFO.commit, 10))'`. The
  `julia-latest-*.checkbounds.tar.gz` objects also exist, but downloading them
  independently of the binary can race a new build.

No companion files are included in ordinary tarballs or installers.
