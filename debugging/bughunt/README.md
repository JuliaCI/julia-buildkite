# bughunt

To get the various pieces of state needed to debug a buildkite failure, simply run the following:

```
$ julia --project bughunt.jl ${BUILDKITE_WEB_URL}
```

Where `$BUILDKITE_WEB_URL` is the URL shown when a buildkite job is expanded in the web UI, e.g. something like `https://buildkite.com/julialang/julia-master/builds/13349#0181b36e-6ab1-4e9d-b9bd-5b642e16e761`.
You will also need to have decrypted the `buildkite_token` in this repository, or saved  your own.
To get your own buildkite token, navigate to https://buildkite.com/user/api-access-tokens, generate a new personal access token with all `read_*` permissinons, then save that value to the `buildkite_token` file in this directory.

Running the `bughunt.jl` script will drop you into a sandbox environment with the appropriate rootfs, a julia checkout of the correct gitsha in `/build/julia`, and all relevant artifacts from buildkite (such as `rr` traces, core dumps, and previously-build Julia binaries) in `/build/artifacts`.

Note that this currently only works on Linux, through `Sandbox.jl`.

## Building julia from source

You can build Julia from source within the sandbox environment by using the special command `build_julia`, which will use the same scripts as on CI to perform the build locally.

## Testing Julia

You can run the Julia test suite within the sandbox environment by using the special command `test_julia`, which will use the same scripts as on CI to perform the tests locally.  If you have previously built Julia via the `build_julia` command, the tests will use the from-source built Julia, otherwise if there was a binary artifact built on CI that was downloaded locally, the test will use those.  If neither are available, it will error out and tell you to build Julia first.

## Debugging corefiles

To launch a debugger on a corefile, simply run the `./debug-core_dump.sh` script in the root of the corefile artifacts directory and you'll get a `gdb` REPL with the corefile loaded, the julia source directories for the correct checkout automatically added to the search path, and the correct sysroot setup.
