# Usage: julia install_toolchain.jl NAME HASH
#
# Install the Windows toolchain tree NAME (`package_windows.<arch>.<tag>`, a rootfs-images
# release asset) with git tree hash HASH as a Pkg artifact, and print its path on stdout.
# The build jobs run the julia plugin first, whose depot lives in the job's cache pool, so a
# pool downloads each toolchain once. Like the sandbox plugin does for Linux images, this
# tries the Pkg server first (it serves the trees RootfsImages lists), then the release.

using Pkg
using Pkg.Artifacts: artifact_exists, artifact_path, download_artifact
using Base: SHA1

const RELEASES = "https://github.com/JuliaCI/rootfs-images/releases/download"

function sources(name, hash, pkg_server)
    m = match(r"^(package_windows\.(?:x86_64|i686))\.(v[0-9]+\.[0-9]+)$", name)
    m === nothing && error("toolchain name $(repr(name)) is not of the form package_windows.<x86_64|i686>.v<major>.<minor>")
    urls = ["$(RELEASES)/$(m[2])/$(m[1]).tar.gz"]
    pkg_server === nothing || pushfirst!(urls, "$(rstrip(pkg_server, '/'))/artifact/$(hash)")
    return urls
end

function install(name, hash; pkg_server=Pkg.pkg_server(), download=download_artifact)
    tree = SHA1(hash)
    artifact_exists(tree) && return artifact_path(tree)
    errors = String[]
    for url in sources(name, hash, pkg_server)
        println(stderr, "Downloading $(name) from $(url)")
        # returns the error instead of throwing it
        result = download(tree, url; quiet_download=true)
        result === true && return artifact_path(tree)
        push!(errors, "$(url): $(result isa Exception ? sprint(showerror, result) : repr(result))")
    end
    error("could not install $(name) with tree hash $(hash):\n" * join(errors, "\n"))
end

if abspath(PROGRAM_FILE) == @__FILE__
    length(ARGS) == 2 || error("usage: install_toolchain.jl NAME HASH")
    # Pkg ignores a tree hash mismatch on Windows when the user cannot create symlinks
    ENV["JULIA_PKG_IGNORE_HASHES"] = "false"
    println(install(ARGS...))
end
