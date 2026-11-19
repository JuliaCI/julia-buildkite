# Usage:    julia dump_descendants.jl PID CREATED FOLDER BUDGET RESERVE_GIB TOKEN
#
# Run by timeout.jl on 64-bit Windows when the tests time out, before it sends SIGQUIT to
# the test driver PID, created at CREATED (a FILETIME).  That SIGQUIT has libuv write a full dump of the driver alone (with
# the WER LocalDumps key set) and terminate it; its workers and their children then die
# with it, through libuv's job objects, undumped.  This writes full dumps of those
# descendants into FOLDER first, named `<image>.<pid>.dmp` as libuv and WER name theirs,
# and leaves them running.
#
# It writes at most BUDGET dumps: the driver's direct children (the workers) first, oldest
# first, then their children, and so on (see descendants.jl).  It stops when less than
# RESERVE_GIB GiB of disk space is free.  A dump is written to `<name>.<TOKEN>.partial`
# and renamed when complete, unless a file of that name exists by then, so the caller can
# delete what is left when it has to stop us.  Every failure is reported and skipped.

include(joinpath(@__DIR__, "descendants.jl"))

const PROCESS_QUERY_INFORMATION = 0x0400
const PROCESS_VM_READ = 0x0010
const STILL_ACTIVE = 259
const TH32CS_SNAPPROCESS = 0x00000002
const GENERIC_WRITE = 0x40000000
const CREATE_NEW = 1
const FILE_ATTRIBUTE_NORMAL = 0x80
const INVALID_HANDLE_VALUE = Ptr{Cvoid}(typemax(UInt))
# MiniDumpWithFullMemory | MiniDumpIgnoreInaccessibleMemory | MiniDumpWithAvxXStateContext,
# as libuv's SIGQUIT dump
const DUMP_TYPE = 0x00220002

# The Win32 calls below use the x64 calling convention; timeout.jl only runs this from a
# 64-bit Julia.
Sys.WORD_SIZE == 64 || error("dump_descendants.jl requires a 64-bit Julia")

struct ProcessEntry32W
    dwSize::UInt32
    cntUsage::UInt32
    th32ProcessID::UInt32
    th32DefaultHeapID::UInt
    th32ModuleID::UInt32
    cntThreads::UInt32
    th32ParentProcessID::UInt32
    pcPriClassBase::Int32
    dwFlags::UInt32
    szExeFile::NTuple{260,UInt16}
end

last_error() = strip(Libc.FormatMessage(Libc.GetLastError()))

close_handle(handle) = ccall((:CloseHandle, "kernel32"), Cint, (Ptr{Cvoid},), handle)

function filetime_now()
    now = Ref{UInt64}(0)
    ccall((:GetSystemTimeAsFileTime, "kernel32"), Cvoid, (Ref{UInt64},), now)
    return now[]
end

# The processes running now, as (pid, parent pid, image name), and a time before the listing
function list_processes()
    cutoff = filetime_now()
    snapshot = ccall((:CreateToolhelp32Snapshot, "kernel32"), Ptr{Cvoid}, (UInt32, UInt32),
                     TH32CS_SNAPPROCESS, 0)
    snapshot == INVALID_HANDLE_VALUE && error("CreateToolhelp32Snapshot failed: $(last_error())")
    procs = Tuple{UInt32,UInt32,String}[]
    try
        entry = Ref(ProcessEntry32W(sizeof(ProcessEntry32W), 0, 0, 0, 0, 0, 0, 0, 0, ntuple(_ -> 0x0000, 260)))
        more = ccall((:Process32FirstW, "kernel32"), Cint, (Ptr{Cvoid}, Ptr{ProcessEntry32W}), snapshot, entry)
        while more != 0
            name = collect(Iterators.takewhile(!iszero, entry[].szExeFile))
            push!(procs, (entry[].th32ProcessID, entry[].th32ParentProcessID, transcode(String, name)))
            more = ccall((:Process32NextW, "kernel32"), Cint, (Ptr{Cvoid}, Ptr{ProcessEntry32W}), snapshot, entry)
        end
    finally
        close_handle(snapshot)
    end
    return procs, cutoff
end

# A handle of process `pid` and its creation time, or nothing if it is gone
function open_process(pid)
    handle = ccall((:OpenProcess, "kernel32"), Ptr{Cvoid}, (UInt32, Cint, UInt32),
                   PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, false, pid)
    handle == C_NULL && return nothing
    created, exited, kernel, user = Ref{UInt64}(0), Ref{UInt64}(0), Ref{UInt64}(0), Ref{UInt64}(0)
    if ccall((:GetProcessTimes, "kernel32"), Cint,
             (Ptr{Cvoid}, Ref{UInt64}, Ref{UInt64}, Ref{UInt64}, Ref{UInt64}),
             handle, created, exited, kernel, user) == 0
        close_handle(handle)
        return nothing
    end
    return handle, created[]
end

function list_descendants(root, root_created)
    procs, cutoff = list_processes()
    return descendants(root, root_created, procs, cutoff; open=open_process, close=close_handle)
end

function running(handle)
    code = Ref{UInt32}(0)
    ccall((:GetExitCodeProcess, "kernel32"), Cint, (Ptr{Cvoid}, Ref{UInt32}), handle, code) != 0 &&
        code[] == STILL_ACTIVE
end

function free_bytes(folder)
    free = Ref{UInt64}(0)
    ccall((:GetDiskFreeSpaceExW, "kernel32"), Cint, (Cwstring, Ref{UInt64}, Ptr{Cvoid}, Ptr{Cvoid}),
          folder, free, C_NULL, C_NULL) == 0 && error("GetDiskFreeSpaceExW failed: $(last_error())")
    return free[]
end

# Write a full dump of the process, unless there is a file of its name
function dump_process(proc, folder, token)
    path = joinpath(folder, "$(proc.name).$(proc.pid).dmp")
    ispath(path) && error("$(path) already exists")
    partial = "$(path).$(token).partial"
    file = ccall((:CreateFileW, "kernel32"), Ptr{Cvoid},
                 (Cwstring, UInt32, UInt32, Ptr{Cvoid}, UInt32, UInt32, Ptr{Cvoid}),
                 partial, GENERIC_WRITE, 0, C_NULL, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, C_NULL)
    file == INVALID_HANDLE_VALUE && error("cannot create $(partial): $(last_error())")
    dumped, err = try
        ccall((:MiniDumpWriteDump, "dbghelp"), Cint,
              (Ptr{Cvoid}, UInt32, Ptr{Cvoid}, UInt32, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}),
              proc.handle, proc.pid, file, DUMP_TYPE, C_NULL, C_NULL, C_NULL) != 0, last_error()
    finally
        close_handle(file)
    end
    if !dumped
        rm(partial; force=true)
        error("MiniDumpWriteDump failed: $(err)")
    end
    # unlike `mv`, fails when the destination exists, rather than replacing it
    if ccall((:MoveFileExW, "kernel32"), Cint, (Cwstring, Cwstring, UInt32),
             partial, path, 0) == 0
        err = last_error()
        rm(partial; force=true)
        error("cannot rename $(partial) to $(path): $(err)")
    end
    return path
end

function main(root, root_created, folder, budget, reserve_gib, token)
    procs = list_descendants(root, root_created)
    try
        println("Dumping up to $(budget) of the $(length(procs)) descendants of PID $(root) to $(folder).")
        for proc in procs
            budget > 0 || break
            what = "$(proc.name) (PID $(proc.pid))"
            try
                if !running(proc.handle)
                    println("Not dumping $(what): it has exited.")
                    continue
                end
                if free_bytes(folder) < reserve_gib * 2^30
                    println("Not dumping $(what) or later processes: less than $(reserve_gib) GiB of disk space left.")
                    break
                end
                start = time()
                path = dump_process(proc, folder, token)
                println("Dumped $(what) to $(path) in $(round(time() - start; digits=1))s.")
                budget -= 1
            catch err
                println("Unable to dump $(what): ", sprint(showerror, err))
            end
        end
    finally
        foreach(proc -> close_handle(proc.handle), procs)
    end
end

root, root_created, folder, budget, reserve_gib, token = ARGS
try
    main(parse(UInt32, root), parse(UInt64, root_created), folder, parse(Int, budget),
         parse(Int, reserve_gib), token)
catch err
    println("Unable to dump the descendants of PID $(root): ", sprint(showerror, err))
    exit(1)
end
