# Print the state of the julia-ci build of a commit, read from the commit statuses that
# Buildkite posts to GitHub (public, no credentials): "pending", "success", "failure",
# "none" when no julia-ci status exists (Buildkite skipped the commit), or "unknown" when
# GitHub could not be reached (rate limit, network).
#
#   julia ttfx_build_state.jl OWNER/REPO SHA

using Downloads
include(joinpath(@__DIR__, "ttfx_json.jl"))
using .TTFXJSON

# The julia-ci launch posts per-group statuses; the Build group is the one whose macOS
# aarch64 job stages the tarball. Older pipeline settings post the pipeline status too.
const BUILD_CONTEXTS = ("Build", "buildkite/julia-ci")

function build_state(repo::String, sha::String)
    url = "https://api.github.com/repos/$repo/commits/$sha/status"
    io = IOBuffer()
    try
        Downloads.download(url, io; headers = ["Accept" => "application/vnd.github+json",
                                               "User-Agent" => "julia-buildkite-ttfx"])
    catch err
        println(stderr, "GitHub status lookup failed: ", sprint(showerror, err))
        return "unknown"
    end
    statuses = json_parse(take!(io))["statuses"]
    for ctx in BUILD_CONTEXTS, st in statuses
        st["context"] == ctx && return st["state"] == "error" ? "failure" : st["state"]
    end
    return "none"
end

length(ARGS) == 2 || (println(stderr, "usage: ttfx_build_state.jl OWNER/REPO SHA"); exit(2))
println(build_state(ARGS[1], ARGS[2]))
