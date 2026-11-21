# Usage: julia install_toolchain.jl NAME HASH
#
# Install the Windows toolchain tree NAME (`package_windows.<arch>.<tag>`, a rootfs-images
# release asset) with git tree hash HASH as a Pkg artifact in the first depot of
# JULIA_DEPOT_PATH, and print its path on stdout (everything else goes to stderr). The
# build jobs run the julia plugin first, whose depot lives in the job's cache pool, so a
# pool downloads each toolchain once. A read-only depot later in JULIA_DEPOT_PATH that
# already holds the tree is used as is.
#
# Sources, in order: the Pkg server (`<pkg server>/artifact/<hash>`, unless there is none),
# then the rootfs-images release the name designates. A source that does not have the tree,
# refuses it, serves another one (tree hash mismatch) or is too slow is skipped; other
# transport errors are retried a few times; a local error (disk full, ...) ends the install.
# The tree hash is always checked, also on Windows hosts where Pkg would otherwise ignore a
# mismatch because the user cannot create symlinks.

using Pkg
using Pkg.Artifacts: artifact_exists, artifact_path, artifacts_dirs, download_artifact
using Downloads
using Downloads: RequestError
using Base: SHA1

const NAME_RE = r"^(package_windows)\.(x86_64|i686)\.(v[0-9]+\.[0-9]+)$"
const HASH_RE = r"^[0-9a-f]{40}$"
const RELEASES = "https://github.com/JuliaCI/rootfs-images/releases/download"
const ATTEMPTS = 3
const BACKOFF = (10, 30)  # seconds before the second and third attempt

# Limits for every request, on top of Downloads' defaults (which only abort below 1 B/s,
# and never on total time). A tree is ~700 MB, which a CI host fetches at 10-100 MB/s, so
# a source averaging under 100 kB/s for 30 s is stalled, not slow, and one that needs over
# 10 min is unusable. Pkg tries a download 3 times, so a stalled source is given up after
# about 1.5 min, and the next one is tried.
const CONNECT_TIMEOUT = 20      # s
const LOW_SPEED_LIMIT = 100_000 # bytes/s ...
const LOW_SPEED_TIME = 30       # ... averaged over this many seconds
const TOTAL_TIMEOUT = 600       # s
const CURLE_OPERATION_TIMEDOUT = 28

say(msg) = println(stderr, "install_toolchain: ", msg)

"""
    parse_args(args) -> (; image, arch, tag, hash)

Validate the command line; throws an `ArgumentError` naming the problem.
"""
function parse_args(args)
    length(args) == 2 || throw(ArgumentError("usage: install_toolchain.jl NAME HASH"))
    name, hash = args
    m = match(NAME_RE, name)
    m === nothing && throw(ArgumentError(
        "toolchain name $(repr(name)) is not of the form package_windows.<x86_64|i686>.v<major>.<minor>"))
    occursin(HASH_RE, hash) || throw(ArgumentError(
        "toolchain hash $(repr(hash)) is not a git tree hash (40 lowercase hexadecimal digits)"))
    return (; image=String(m[1]), arch=String(m[2]), tag=String(m[3]), hash)
end

"""
    sources(spec, pkg_server) -> Vector{String}

The URLs to try, in order. `pkg_server` is `Pkg.pkg_server()`: a URL, or `nothing`.
"""
function sources(spec, pkg_server)
    urls = String[]
    pkg_server === nothing || push!(urls, "$(rstrip(pkg_server, '/'))/artifact/$(spec.hash)")
    push!(urls, "$(RELEASES)/$(spec.tag)/$(spec.image).$(spec.arch).tar.gz")
    return urls
end

"""
    configure_downloads!()

Make the default downloader, which Pkg uses, apply the limits above to every request.
`Downloads.EASY_HOOK` would only reach downloaders created after it is set, and a startup
file or an earlier download may have created the default one already, so this installs a
new default downloader that has the hook.
"""
function configure_downloads!()
    downloader = Downloads.Downloader()
    downloader.easy_hook = (easy, info) -> begin
        Downloads.Curl.setopt(easy, Downloads.Curl.CURLOPT_CONNECTTIMEOUT, CONNECT_TIMEOUT)
        Downloads.Curl.setopt(easy, Downloads.Curl.CURLOPT_LOW_SPEED_LIMIT, LOW_SPEED_LIMIT)
        Downloads.Curl.setopt(easy, Downloads.Curl.CURLOPT_LOW_SPEED_TIME, LOW_SPEED_TIME)
        Downloads.Curl.setopt(easy, Downloads.Curl.CURLOPT_TIMEOUT, TOTAL_TIMEOUT)
    end
    Downloads.default_downloader!(downloader)
    return downloader
end

"""
    classify(result) -> Symbol

What a `download_artifact` result (or the exception it threw) means for this source:

- `:ok`;
- `:missing` (HTTP 404/410), `:refused` (another HTTP 4xx), `:mismatch` (another tree) and
  `:slow` (a timeout: stalled, too slow or unreachable): skip the source;
- `:transient` (HTTP 408, 429, 5xx, other transport errors): retry it;
- `:local` (an error writing the tree here): give up.

Pkg 1.10 returns the error instead of throwing it, so only `true` is success.
"""
function classify(result)
    result === true && return :ok
    result = innermost(result)
    if result isa RequestError
        status = result.response.status
        status in (404, 410) && return :missing
        (status in (408, 429) || status >= 500) && return :transient
        400 <= status < 500 && return :refused
        result.code == CURLE_OPERATION_TIMEDOUT && return :slow
        return :transient
    end
    if result isa ErrorException && occursin("Tree Hash Mismatch", result.msg)
        return :mismatch
    end
    (result isa SystemError || result isa Base.IOError) && return :local
    return :transient
end

# Downloads writes the response in a task, so an error writing the tarball (e.g. a full
# disk) arrives wrapped in `CompositeException`/`TaskFailedException`
function innermost(err)
    while true
        if err isa CompositeException && !isempty(err.exceptions)
            err = first(err.exceptions)
        elseif err isa TaskFailedException
            err = err.task.exception
        else
            return err
        end
    end
end

describe(result) = result isa Exception ? sprint(showerror, result) : repr(result)

function summary(outcome, result)
    outcome === :missing && return "not found (HTTP $(result.response.status))"
    outcome === :refused && return "refused (HTTP $(result.response.status))"
    outcome === :mismatch && return "serves another tree (tree hash mismatch)"
    outcome === :slow && return "too slow or unreachable: $(describe(result))"
    return "failed $(ATTEMPTS) times, last: $(describe(result))"
end

# A killed install leaves Pkg's temporary directory (`jl_*`) behind in the artifacts
# directory. A cache pool runs one job at a time, so nothing else can be using one.
function remove_stale_temporaries(dir)
    isdir(dir) || return
    for entry in readdir(dir)
        path = joinpath(dir, entry)
        if occursin(r"^jl_[A-Za-z0-9]+$", entry) && isdir(path) && !islink(path)
            say("removing $(path), left behind by an interrupted install")
            rm(path; recursive=true, force=true)
        end
    end
end

"""
    install(spec; pkg_server, download=download_artifact, sleep=sleep) -> path

Install the tree from the first source that has it and return its path; throws an
`ErrorException` listing what the sources answered if none does.
"""
function install(spec; pkg_server=Pkg.pkg_server(), download=download_artifact, sleep=sleep)
    tree = SHA1(spec.hash)
    name = "$(spec.image).$(spec.arch).$(spec.tag)"
    remove_stale_temporaries(first(artifacts_dirs()))
    if artifact_exists(tree)
        say("$(name) is installed already")
        return artifact_path(tree)
    end
    failures = String[]
    for url in sources(spec, pkg_server)
        for attempt in 1:ATTEMPTS
            say("downloading $(name) from $(url)" * (attempt > 1 ? " (attempt $(attempt))" : ""))
            t0 = time()
            result = try
                download(tree, url; quiet_download=true)
            catch err
                err isa InterruptException && rethrow()
                err
            end
            outcome = classify(result)
            if outcome === :ok
                say("installed $(name) in $(round(time() - t0; digits=1)) s")
                return artifact_path(tree)
            end
            say("$(url): $(describe(result)) (after $(round(time() - t0; digits=1)) s)")
            if outcome === :local
                error("could not install $(name): $(describe(result))")
            end
            if outcome === :transient && attempt < ATTEMPTS
                sleep(BACKOFF[attempt])
                continue
            end
            push!(failures, "$(url): $(summary(outcome, result))")
            break
        end
    end
    error("could not install $(name) with tree hash $(spec.hash):\n  " * join(failures, "\n  "))
end

function main(args)
    spec = try
        parse_args(args)
    catch err
        err isa ArgumentError || rethrow()
        say(err.msg)
        return 2
    end
    # Pkg ignores a tree hash mismatch on Windows when the user cannot create symlinks,
    # unless told otherwise.
    ENV["JULIA_PKG_IGNORE_HASHES"] = "false"
    configure_downloads!()
    path = try
        install(spec)
    catch err
        err isa ErrorException || rethrow()
        say(err.msg)
        return 1
    end
    println(path)
    return 0
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main(ARGS))
end
