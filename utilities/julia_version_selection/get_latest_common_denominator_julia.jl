using Downloads, JSON3, Base.BinaryPlatforms

json_buff = IOBuffer()
Downloads.download("https://julialang-s3.julialang.org/bin/versions.json", json_buff)
versions_json = JSON3.read(String(take!(json_buff)))

root_dir = dirname(dirname(@__DIR__))

# Read the set of triplets from our .arches files:
function read_arches_file(arches_file)
    triplets_script = """
    bash $(root_dir)/utilities/arches_env.sh $(arches_file) | while read env_map; do
        eval "export \${env_map}"
        echo "\${TRIPLET}"
    done
    """
    platforms = Platform[]
    for line in split(readchomp(`bash -c $triplets_script`), "\n")
        if isempty(line) || endswith(line, "gnuassert") || endswith(line, "gnummtk") || endswith(line, "gnuprofiling")
            continue
        end
        try
            push!(platforms, parse(Platform, line))
        catch
            @warn("Couldn't parse $(line) as a platform!")
        end
    end
    return platforms
end

arches_files = filter(readdir(joinpath(root_dir, "pipelines", "main", "platforms"); join=true)) do fname
    return endswith(fname, ".arches")
end
platforms = unique(vcat(read_arches_file.(arches_files)...))

# Only care about Linux versions, since those are the ones we use to launch jobs
platforms = filter(Sys.islinux, platforms)

# Collect all versions that have 
versions = filter(versions_json) do (v, d)
    if !d["stable"]
        return false
    end
    version_platforms = [parse(Platform, f.triplet) for f in d.files]
    if any(p ∉ version_platforms for p in platforms)
        return false
    end
    return true
end
latest_common_version = maximum(VersionNumber.(String.(collect(keys(versions)))))
@show latest_common_version
