using LibGit2, Scratch, SHA
using Base: SHA1

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

function cached_git_clone(url::AbstractString;
                          hash::Union{Nothing, SHA1} = nothing,
                          downloads_dir::String = @get_scratch!("git-clones"))
    repo_path = joinpath(downloads_dir, string(basename(url), "-", bytes2hex(sha256(url))))
    if isdir(repo_path)
        LibGit2.with(LibGit2.GitRepo(repo_path)) do repo
            # In some cases, we know the hash we're looking for, so only fetch() if
            # this git repository doesn't contain the hash we're seeking
            # this is not only faster, it avoids race conditions when we have
            # multiple builders on the same machine all fetching at once.
            if hash === nothing || !LibGit2.iscommit(bytes2hex(hash.bytes), repo)
                LibGit2.fetch(repo)
            end
        end
    else
        # If there is no repo_path yet, clone it down into a bare repository
        LibGit2.clone(url, repo_path; isbare=true)
    end
    return repo_path
end

function get_checkout(repo_url::String,
                      hash::SHA1,
                      checkout_dir::String;
                      downloads_dir::String = @get_scratch!("git-clones"))
    # Clone down (or verify that we've cached) a repository that contains the requested commit
    repo_path = cached_git_clone(repo_url; hash, downloads_dir)

    # Checkout the desired commit to a temporary directory that `reman` will clean up:
    LibGit2.with(LibGit2.clone(repo_path, checkout_dir)) do cloned_repo
        LibGit2.checkout!(cloned_repo, bytes2hex(hash.bytes))
    end
    return checkout_dir
end

function get_checkout(gc::GitCheckout, checkout_prefix::String; kwargs...)
    return get_checkout(gc.repo_url, gc.commit, joinpath(checkout_prefix, gc.checkout_path); kwargs...)
end
