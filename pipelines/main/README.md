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
x86-64 and aarch64. They have allow-fail tests. The schedule does not repeat
the per-commit groups. `julia-publish` promotes the scheduled artifacts;
no-GPL builds go to `julialang-nogpl`, while optimized builds use
`julialangnightlies/bin/linuxopt/`, `.../macosopt/` and `.../windowsopt/`.

Release tag and `release-*` branch builds also build the no-GPL binaries and
publish them to `julialang-nogpl`, so each release series gets no-GPL nightlies
on every push without a schedule of its own.

A second `julia-ci` schedule, Saturday nights with `TTFX_RELEASE=latest`, builds
nothing and measures the newest stable release on the TTFX tasks instead, as a
reference for the master series (see `utilities/ttfx/README.md`).

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
and can be extracted into the root of the matching Julia installation:

```sh
tar -xzf julia-VERSION-PLATFORM.checkbounds.tar.gz -C /path/to/julia
```

Use the companion from the same build, platform and variant as the Julia binary.
Its URL is the matching Julia tarball URL with `.tar.gz` replaced by
`.checkbounds.tar.gz`. For nightlies, resolve the installed build's commit rather
than independently downloading two `latest` objects, which can race a new build.
No companion files are included in ordinary tarballs or installers.
