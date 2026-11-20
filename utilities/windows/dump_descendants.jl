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
#
# Then it has PID and each Julia process among its descendants print the backtraces of all
# its tasks to its own stderr, which the test driver relays into the log: a dump shows the
# threads only, not the tasks parked on them, and names no JIT-compiled frames.  On
# Windows the test processes have no signal handler that would print them, so we start a
# thread at `jl_print_task_backtraces` in each (as one would `call` it from a debugger),
# but only in a process that has loaded the same libjulia-internal file as we have, so
# that the function is at the same offset in it, and only from Julia 1.14 on, which can
# record a backtrace from a thread it does not know.

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

const PROCESS_CREATE_THREAD = 0x0002
const PROCESS_VM_OPERATION = 0x0008
const PROCESS_VM_WRITE = 0x0020
const LIST_MODULES_ALL = 0x03
const GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS = 0x4
const GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT = 0x2
const WAIT_OBJECT_0 = 0x0
# how long a process may take to print its backtraces
const PRINT_TIMEOUT_MS = 20_000

# The file mapped at module `mod` of `process`, as an NT path with every drive letter, subst
# and junction resolved: the same file can be loaded under different names (the test
# processes see the Julia install through a substituted drive, those started from PATH
# through the directory it stands for).
function module_file(process, mod)
    buf = Vector{UInt16}(undef, 32768)
    n = ccall((:K32GetMappedFileNameW, "kernel32"), UInt32,
              (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{UInt16}, UInt32), process, mod, buf, length(buf))
    n == 0 && error("GetMappedFileName failed: $(last_error())")
    return lowercase(transcode(String, buf[1:n]))
end

# Our libjulia-internal: its file, and the offset of jl_print_task_backtraces in it
function local_printer()
    fn = cglobal(:jl_print_task_backtraces)
    mod = Ref{Ptr{Cvoid}}(C_NULL)
    ccall((:GetModuleHandleExW, "kernel32"), Cint, (UInt32, Ptr{Cvoid}, Ref{Ptr{Cvoid}}),
          GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
          fn, mod) == 0 && error("GetModuleHandleExW failed: $(last_error())")
    self = ccall((:GetCurrentProcess, "kernel32"), Ptr{Cvoid}, ())
    return module_file(self, mod[]), UInt(fn) - UInt(mod[])
end

# The base address of the module of file `file` in `process`, or nothing
function remote_module(process, file)
    mods = Vector{Ptr{Cvoid}}(undef, 4096)
    needed = Ref{UInt32}(0)
    ccall((:K32EnumProcessModulesEx, "kernel32"), Cint,
          (Ptr{Cvoid}, Ptr{Ptr{Cvoid}}, UInt32, Ref{UInt32}, UInt32),
          process, mods, sizeof(mods), needed, LIST_MODULES_ALL) == 0 &&
        error("EnumProcessModulesEx failed: $(last_error())")
    for mod in mods[1:min(length(mods), needed[] ÷ sizeof(Ptr{Cvoid}))]
        module_file(process, mod) == file && return mod
    end
    return nothing
end

# Have process `pid` print its task backtraces to its stderr, waiting at most
# PRINT_TIMEOUT_MS.  Returns a description of what happened.
function print_backtraces(pid, printer)
    file, offset = printer
    process = ccall((:OpenProcess, "kernel32"), Ptr{Cvoid}, (UInt32, Cint, UInt32),
                    PROCESS_CREATE_THREAD | PROCESS_QUERY_INFORMATION | PROCESS_VM_OPERATION |
                    PROCESS_VM_WRITE | PROCESS_VM_READ, false, pid)
    process == C_NULL && error("OpenProcess failed: $(last_error())")
    try
        base = remote_module(process, file)
        base === nothing && return "it has not loaded $(file)"
        thread = ccall((:CreateRemoteThread, "kernel32"), Ptr{Cvoid},
                       (Ptr{Cvoid}, Ptr{Cvoid}, Csize_t, Ptr{Cvoid}, Ptr{Cvoid}, UInt32, Ptr{UInt32}),
                       process, C_NULL, 0, Ptr{Cvoid}(UInt(base) + offset), C_NULL, 0, C_NULL)
        thread == C_NULL && error("CreateRemoteThread failed: $(last_error())")
        start = time()
        result = ccall((:WaitForSingleObject, "kernel32"), UInt32, (Ptr{Cvoid}, UInt32),
                       thread, PRINT_TIMEOUT_MS)
        close_handle(thread)
        result == WAIT_OBJECT_0 || return "still printing after $(PRINT_TIMEOUT_MS ÷ 1000)s; going on"
        return "printed in $(round(time() - start; digits=1))s"
    finally
        close_handle(process)
    end
end

function print_all_backtraces(root, procs)
    # Before 1.14 (JuliaLang/julia#62288), recording the backtrace of another task on a
    # thread Julia does not know, as ours, dereferences its null current task, which
    # crashes the process.
    if VERSION < v"1.14.0-alpha1"
        println("Not printing the task backtraces of the Julia processes: Julia $(VERSION) crashes when asked from a foreign thread.")
        return
    end
    julias = filter(proc -> lowercase(proc.name) == "julia.exe" && running(proc.handle), procs)
    printer = try
        local_printer()
    catch err
        println("Not printing the task backtraces of the Julia processes: ", sprint(showerror, err))
        return
    end
    # deepest first: a driver relays the output of its workers, a worker that of its children
    for pid in [reverse!([proc.pid for proc in julias]); root]
        what = "PID $(pid)"
        try
            println("Printing the task backtraces of $(what) to its stderr: ", print_backtraces(pid, printer), ".")
        catch err
            println("Unable to print the task backtraces of $(what): ", sprint(showerror, err))
        end
    end
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
        print_all_backtraces(root, procs)
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
