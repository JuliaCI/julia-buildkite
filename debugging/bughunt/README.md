# bughunt

To get the various pieces of state needed to debug a buildkite failure, simply run the following:

```
$ julia --project bughunt.jl ${BUILDKITE_WEB_URL}
```

Where `$BUILDKITE_WEB_URL` is the URL shown when a buildkite job is expanded in the web UI, e.g. something like `https://buildkite.com/julialang/julia-master/builds/13349#0181b36e-6ab1-4e9d-b9bd-5b642e16e761`.
You will also need to have decrypted the `buildkite_token` in this repository, or saved  your own.

Running the `bughunt.jl` script will drop you into a sandbox environment with the appropriate rootfs, a julia checkout of the correct gitsha in `/build/julia`, and all relevant artifacts from buildkite (such as `rr` traces, core dumps, and previously-build Julia binaries) in `/build/artifacts`.

Note that this currently only works on Linux, through `Sandbox.jl`.

## Debugging corefiles

To launch a debugger on a corefile, simply run the `./debug-core_dump.sh` script in the root of the corefile artifacts directory and you'll get a `gdb` REPL with the corefile loaded, the julia source directories for the correct checkout automatically added to the search path, and the correct sysroot setup.
