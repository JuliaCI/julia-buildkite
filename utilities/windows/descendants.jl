# The selection of the processes dump_descendants.jl dumps, apart from the Win32 calls so
# that it can be tested on any platform (utilities/tests/test_descendants.jl).

# The descendants of process `root`, created at `root_created`, from a process listing
# `procs` of (pid, parent pid, image name) taken after time `cutoff`: breadth first, and
# each process' children oldest first, as named tuples (pid, name, handle).  Throws if
# `root` is gone or is another process by now; else it was running when `procs` was
# listed, so the children listed for it are its own or older (rejected below).
#
# `open(pid)` returns a handle of the process and its creation time, or `nothing` when it is
# gone; a handle keeps its process id from being reused while it is open.  Process ids are
# reused, so the process opened may not be the one listed: one created after `cutoff` was
# not listed, and one created before the process listed as its parent is not its child.
# Equal times are ambiguous and also rejected.  `close(handle)` is called on the handles of
# the processes rejected.
function descendants(root, root_created, procs, cutoff; open, close)
    opened = open(root)
    opened === nothing && error("PID $(root) is gone")
    close(opened[1])
    opened[2] == root_created || error("PID $(root) is another process by now")
    found = NamedTuple[]
    queue = [(root, root_created)]
    while !isempty(queue)
        parent, parent_created = popfirst!(queue)
        children = []
        for (pid, ppid, name) in procs
            (ppid == parent && pid != parent) || continue
            opened = open(pid)
            opened === nothing && continue
            handle, created = opened
            if parent_created < created < cutoff
                push!(children, (; created, pid, name, handle))
            else
                close(handle)
            end
        end
        for child in sort!(children; by=child -> (child.created, child.pid))
            push!(found, (; child.pid, child.name, child.handle))
            push!(queue, (child.pid, child.created))
        end
    end
    return found
end
