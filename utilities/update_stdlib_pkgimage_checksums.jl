# Update the pkgimage checksums embedded in the stdlib .ji cache files
# after codesigning modified the pkgimages.
#
# Two modes:
#   update_stdlib_pkgimage_checksums.jl
#       In-target: operates on the running julia's own installation
#       (requires running the julia from the install tree being fixed up).
#   update_stdlib_pkgimage_checksums.jl <julia_root> <dlext>
#       Cross: operates on a foreign install tree (e.g. a macOS or Windows
#       tree on a linux publish agent) under any host julia. <dlext> is the
#       TARGET's dynamic library extension (dylib / dll / so). Validation
#       uses the version-independent trailing checksum of the cache files
#       instead of the (version-bound) cache header.
using Libdl
import Base: _sizeof_uv_fs, uv_error

cross_mode = !isempty(ARGS)

# This should be in Julia base, I feel
function setmtime(path::AbstractString, mtime::Real, atime::Real=mtime; follow_symlinks::Bool=true)
    req = Libc.malloc(_sizeof_uv_fs)
    try
        if follow_symlinks
            ret = ccall(:uv_fs_utime, Cint,
                (Ptr{Cvoid}, Ptr{Cvoid}, Cstring, Cdouble, Cdouble, Ptr{Cvoid}),
                C_NULL, req, path, atime, mtime, C_NULL)
        else
            ret = ccall(:uv_fs_lutime, Cint,
                (Ptr{Cvoid}, Ptr{Cvoid}, Cstring, Cdouble, Cdouble, Ptr{Cvoid}),
                C_NULL, req, path, atime, mtime, C_NULL)
        end
        ccall(:uv_fs_req_cleanup, Cvoid, (Ptr{Cvoid},), req)
        ret < 0 && uv_error("utime($(repr(path)))", ret)
    finally
        Libc.free(req)
    end
end

function preserve_mtimes(f::Function, files::Vector{String})
    mtimes = mtime.(files)
    try
        f()
    finally
        for (file, mtime) in zip(files, mtimes)
            try
                setmtime(file, mtime)
            catch e
                @error("Unable to set mtime", file, exception=e)
            end
        end
    end
end

# The trailing layout of a .ji cache file is version-independent:
#   [ ... body ... | pkgimage crc32c (4 bytes) | whole-file crc32c (4 bytes) ]
# where the whole-file checksum covers everything except itself. This is
# what lets us validate and patch foreign-version cache files.
function trailing_file_crc_valid(f::IO)
    seekstart(f)
    crc = Base._crc32c(read(f, filesize(f) - 4))
    seek(f, filesize(f) - 4)
    stored = read(f, UInt32)
    return crc == stored
end

# Updates cache file checksum for pkgimg i.e. after codesigning pkgimages
function update_cache_pkgimg_checksum!(ji_file::String, pkgimg_file::String)
    if !isfile(ji_file)
        throw(ArgumentError("Precompile cache file does not exist at '$(ji_file)'"))
    end
    if !isfile(pkgimg_file)
        throw(ArgumentError("Package image file does not exist at '$(pkgimg_file)'"))
    end
    crc_so = open(Base._crc32c, pkgimg_file, "r")
    open(ji_file, "r+") do f
        if cross_mode
            # The version-bound header check is unavailable for a foreign
            # tree; the trailing whole-file checksum catches truncation or
            # format drift just as well before we patch fixed offsets.
            if !trailing_file_crc_valid(f)
                error("Invalid trailing checksum in cache file $(repr(ji_file)).")
            end
        else
            if iszero(Base.isvalid_cache_header(f))
                error("Invalid header in cache file $(repr(ji_file)).")
            end

            # This is not fatal, but it is weird.
            if Base.isvalid_pkgimage_crc(f, pkgimg_file)
                @error "pkgimage checksum already correct in $(repr(ji_file))"
                return
            end
        end

        seekend(f)
        seek(f, filesize(f) - 8)
        write(f, crc_so) # overwrites 4 bytes

        seekstart(f)
        crc = Base._crc32c(read(f, filesize(f) - 4))
        write(f, crc) # overwrites last 4 bytes

        if cross_mode
            if !trailing_file_crc_valid(f)
                error("After update: invalid trailing checksum in cache file $(repr(ji_file)).")
            end
            seek(f, filesize(f) - 8)
            if read(f, UInt32) != crc_so
                error("After update: incorrect pkgimage checksum in cache file $(repr(ji_file))")
            end
        else
            seekstart(f)
            if iszero(Base.isvalid_cache_header(f))
                error("After update: Invalid header in cache file $(repr(ji_file)).")
            end
            if !Base.isvalid_pkgimage_crc(f, pkgimg_file)
                error("After update: Incorrect pkgimage checksum in cache file $(repr(ji_file))")
            end
        end
        @info "pkgimage checksum updated in $(repr(ji_file)) for $(repr(pkgimg_file))"
    end
    return nothing
end

if cross_mode
    julia_root = abspath(ARGS[1])
    dlext = ARGS[2]
    # The (single) v<major>.<minor> directory of the TARGET tree; we cannot
    # use the host VERSION, which may differ.
    compiled_dir = joinpath(julia_root, "share", "julia", "compiled")
    version_dirs = filter(d -> isdir(joinpath(compiled_dir, d)), readdir(compiled_dir))
    length(version_dirs) == 1 ||
        error("expected exactly one version directory in $(compiled_dir), got $(version_dirs)")
    stdlib_cache_dir = abspath(joinpath(compiled_dir, version_dirs[1]))
else
    julia_root = abspath(dirname(dirname(Base.julia_cmd()[1])))
    dlext = Libdl.dlext
    stdlib_cache_dir = abspath(joinpath(julia_root, "share", "julia", "compiled", "v$(VERSION.major).$(VERSION.minor)"))
end

for dir in readdir(stdlib_cache_dir, join = true)
    if !isdir(dir)
        continue
    end

    pkgimg_files = filter(readdir(dir, join=true)) do f
        return endswith(f, ".$(dlext)")
    end

    # respect mtime order of caches, so that if one cache depends on another, we end up
    sort!(pkgimg_files, by=mtime)
    for pkgimg_file in pkgimg_files
        ji_file = string(splitext(pkgimg_file)[1], ".ji")
        preserve_mtimes([ji_file, pkgimg_file]) do
            update_cache_pkgimg_checksum!(ji_file, pkgimg_file)
        end
    end
end

# check stdlibs caches are valid (only possible when running the target
# julia itself; a host julia cannot load a foreign tree's caches)
if !cross_mode
    Base.isprecompiled(Base.PkgId(Base.UUID("8bb1440f-4735-579b-a4ab-409b98df4dab"), "DelimitedFiles")) || error()
end
