
Sys.isapple() || error("This tool only exists to update caches after MacOS codesigning")

# Updates cache file checksum for pkgimg i.e. after codesigning pkgimages
function update_cache_pkgimg_checksum!(ji_file::String, pkgimg_file::String)
    isfile(ji_file) || error("ji file does not exist at $(repr(ji_file))")
    isfile(pkgimg_file) || return # if no pkgimage file it should be a --pkgimage=no cache
    crc_so = open(Base._crc32c, pkgimg_file, "r")
    open(ji_file, "r+") do f
        if iszero(Base.isvalid_cache_header(f))
            error("Invalid header in cache file $(repr(ji_file)).")
        end
        if Base.isvalid_pkgimage_crc(f, pkgimg_file)
            @error "pkgimage checksum already correct in $(repr(ji_file))"
        else
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
    end
    return nothing
end

julia_root = abspath(joinpath(dirname(Base.julia_cmd()[1]), ".."))

stdlib_cache_dir = abspath(joinpath(julia_root, "share", "julia", "compiled", "v$(VERSION.major).$(VERSION.minor)"))

for dir in readdir(stdlib_cache_dir, join = true)
    isdir(dir) || continue
    files = readdir(dir, join=true)
    sort!(files, by=mtime) # respect mtime order of caches
    slugs = unique(first.(splitext.(files)))
    for slug in slugs
        endswith(slug, ".dylib") && continue # happens because of .dSYM files
        ji_file = slug * ".ji"
        pkgimg_file = slug * ".dylib"
        update_cache_pkgimg_checksum!(ji_file, pkgimg_file)
        touch(ji_file) # for case where file was already correct
        slug == slugs[end] || sleep(1) # ensure cache files have different mtime second values to preserve order through tar compression
    end
end
