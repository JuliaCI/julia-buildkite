using Git, Scratch, SHA
using Base: SHA1

Base.SHA1(x::SHA1) = x
struct GitCheckout
    repo_url::String
    commit::SHA1
    checkout_path::String

    function GitCheckout(repo_url, commit, checkout_path)
        return new(
            string(repo_url),
            SHA1(commit),
            string(checkout_path)
        )
    end
end

iscommit(repo::String, commit::String) = success(git(["-C", repo, "cat-file", "-e", commit]))
default_clones_dir() = @get_scratch!("git_clones")

"""
    cached_git_clone(url::String; hash = nothing, verbose = false)

Return the path to a local git clone of the given `url`.  If `hash` is given,
then a cached git repository will not be updated if the commit already exists locally.
"""
function cached_git_clone(url::String;
                          hash::Union{Nothing,String} = nothing,
                          clones_dir::String = default_clones_dir(),
                          verbose::Bool = false)
    quiet_args = String[]
    if !verbose
        push!(quiet_args, "-q")
    end

    repo_path = joinpath(clones_dir, string(basename(url), "-", bytes2hex(sha256(url))))
    if isdir(repo_path)
        if verbose
            @info("Using cached git repository", url, repo_path)
        end

        # If we didn't just mercilessly obliterate the cached git repo, use it!
        # In some cases, we know the hash we're looking for, so only fetch() if
        # this git repository doesn't contain the hash we're seeking.
        # this is not only faster, it avoids race conditions when we have
        # multiple builders on the same machine all fetching at once.
        if hash === nothing || !iscommit(repo_path, hash)
            run(git(["-C", repo_path, "fetch", "-a", quiet_args...]))
        end
    else
        if verbose
            @info("Cloning git repository", url, repo_path)
        end
        # If there is no repo_path yet, clone it down into a bare repository
        run(git(["clone", "--mirror", url, repo_path, quiet_args...]))
    end
    return repo_path
end

function get_checkout(repo_url::String,
                      hash::SHA1,
                      checkout_dir::String;
                      clones_dir::String = default_clones_dir())
    # Clone down (or verify that we've cached) a repository that contains the requested commit
    repo_path = cached_git_clone(repo_url; hash=bytes2hex(hash.bytes), clones_dir)

    run(git(["clone", "--shared", repo_path, checkout_dir, "-q"]))
    run(git(["-C", checkout_dir, "checkout", bytes2hex(hash.bytes), "-q"]))
end

function get_checkout(gc::GitCheckout, checkout_prefix::String; kwargs...)
    return get_checkout(gc.repo_url, gc.commit, joinpath(checkout_prefix, gc.checkout_path); kwargs...)
end

function get_commits_between(repo_url::String, before::SHA1, after::SHA1;
                             clones_dir::String = default_clones_dir())
    repo_path = cached_git_clone(repo_url; hash=bytes2hex(after.bytes), clones_dir)
    lines = readchomp(git(["-C", repo_path, "log", "--reverse", "--pretty=format:%H", string(bytes2hex(before.bytes), "^!"), bytes2hex(after.bytes)]))
    return [parse(SHA1, line) for line in split(lines)]
end
