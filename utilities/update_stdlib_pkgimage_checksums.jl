using Libdl
import Base: _sizeof_uv_fs, uv_error

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
        if iszero(Base.isvalid_cache_header(f))
            error("Invalid header in cache file $(repr(ji_file)).")
        end

        # This is not fatal, but it is weird.
        if Base.isvalid_pkgimage_crc(f, pkgimg_file)
            @error "pkgimage checksum already correct in $(repr(ji_file))"
            return
        end

        seekend(f)
        seek(f, filesize(f) - 8)
        write(f, crc_so) # overwrites 4 bytes

        seekstart(f)
        crc = Base._crc32c(read(f, filesize(f) - 4))
        write(f, crc) # overwrites last 4 bytes

        seekstart(f)
        if iszero(Base.isvalid_cache_header(f))
            error("After update: Invalid header in cache file $(repr(ji_file)).")
        end
        if !Base.isvalid_pkgimage_crc(f, pkgimg_file)
            error("After update: Incorrect pkgimage checksum in cache file $(repr(ji_file))")
        end
        @info "pkgimage checksum updated in $(repr(ji_file)) for $(repr(pkgimg_file))"
    end
    return nothing
end

julia_root = abspath(dirname(dirname(Base.julia_cmd()[1])))
stdlib_cache_dir = abspath(joinpath(julia_root, "share", "julia", "compiled", "v$(VERSION.major).$(VERSION.minor)"))

for dir in readdir(stdlib_cache_dir, join = true)
    if !isdir(dir)
        continue
    end

    pkgimg_files = filter(readdir(dir, join=true)) do f
        return endswith(f, ".$(Libdl.dlext)")
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

# check stdlibs caches are valid
Base.isprecompiled(Base.PkgId(Base.UUID("8bb1440f-4735-579b-a4ab-409b98df4dab"), "DelimitedFiles")) || error()
