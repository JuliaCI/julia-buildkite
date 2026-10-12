# Included by an instrumented task script (`task_ttfx.jl`, see instrument_task in
# ttfx_bench.jl) before its first marker, in the untimed invalidations run only. The
# script logs invalidations from its first marker to its third, in the two logs
# SnoopCompile reads:
#
#   `jl_debug_method_invalidation`: code already in the session that a method definition
#   invalidated. Per tree, the invalidated callers with their depth, then the root
#   followed by the tag; per method, the method followed by the tag.
#   `debug_method_invalidation` (Base.StaticData, Compiler.ReinferUtils on 1.14): code in
#   a package image that is not reinstated on load because an edge no longer holds:
#   (sig, "insert_backedges_callee", ci, matches) at the root, (ci, "verify_methods",
#   cause) for every caller of invalidated code.
#
# It prints one line, `__TTFX_INV__:{"load": ..., "run": ...}`, for the load and run
# phases: the MethodInstances whose code was dropped (unique per phase), split by how,
# the method definitions that invalidated anything, and the causes with the most.

module TTFXInvalidations

include(joinpath(@__DIR__, "ttfx_json.jl"))
using .TTFXJSON

const MI = Core.MethodInstance
const TOP = 5

mi(x) = x isa Core.CodeInstance ? (isdefined(Base, :get_ci_mi) ? Base.get_ci_mi(x) : x.def) :
        x isa MI ? x : nothing
cause(m::Method) = first(string(parentmodule(m), ": ", m.sig), 150)
cause(x) = first(string(x), 150)
top(d) = [[k, n] for (k, n) in first(sort!(collect(d); by = last, rev = true), TOP)]

# The edges log moved from Base.StaticData (1.12, 1.13) to Compiler.ReinferUtils (1.14);
# before 1.12 there is none and only the definitions are counted.
edges_logger() = isdefined(Base, :ReinferUtils) ? Base.ReinferUtils :
                 isdefined(Base, :StaticData) ? Base.StaticData : nothing

function start()
    m = edges_logger()
    edges = m === nothing ? Any[] : m.debug_method_invalidation(true)
    return (ccall(:jl_debug_method_invalidation, Any, (Cint,), 1), edges)
end

function stop()
    ccall(:jl_debug_method_invalidation, Any, (Cint,), 0)
    m = edges_logger()
    m === nothing || m.debug_method_invalidation(false)
    return nothing
end

# Over meths[rm] and edges[re]
function summarize(meths, rm, edges, re)
    inserted = Set{MI}(); tree = Set{MI}(); insertions = 0
    by_method = Dict{String,Int}()
    for i in rm
        x = meths[i]
        if (x isa MI || x isa Core.CodeInstance) && i < last(rm) && meths[i+1] isa Int32
            m = mi(x); m === nothing || (push!(inserted, m); push!(tree, m))
        elseif x == "jl_method_table_insert" || x == "jl_method_table_disable"
            prev = meths[i-1]
            if !(prev isa Method)
                m = mi(prev); m === nothing || (push!(inserted, m); push!(tree, m))
            elseif !isempty(tree)
                insertions += 1
                k = cause(prev)
                by_method[k] = get(by_method, k, 0) + length(tree)
                empty!(tree)
            end
        end
    end
    # Every dropped package-image instance is attributed to the root it follows from
    rejected = Set{MI}(); root = IdDict{Any,String}()
    for i in re
        x = edges[i]
        if x == "insert_backedges_callee"
            ci, matches = edges[i+1], edges[i+2]
            ms = matches isa Vector ? [m for m in matches if m isa Method] : Method[]
            root[ci] = isempty(ms) ? "(no method) " * cause(edges[i-1]) : join(unique(cause.(ms)), " | ")
            m = mi(ci); m === nothing || push!(rejected, m)
        elseif x == "verify_methods"
            ci = edges[i-1]
            root[ci] = get(root, edges[i+1], "(unattributed)")
            m = mi(ci); m === nothing || push!(rejected, m)
        end
    end
    by_root = Dict{String,Int}(); seen = Set{MI}()
    for (ci, k) in root
        m = mi(ci)
        (m === nothing || m in seen) && continue
        push!(seen, m)
        by_root[k] = get(by_root, k, 0) + 1
    end
    return Dict("invalidated" => length(union(inserted, rejected)),
                "by_definition" => length(inserted), "rejected_at_load" => length(rejected),
                "definitions" => insertions,
                "top_definitions" => top(by_method), "top_rejected" => top(by_root))
end

function report((meths, edges), n2)
    load = summarize(meths, 1:n2[1], edges, 1:n2[2])
    run = summarize(meths, n2[1]+1:length(meths), edges, n2[2]+1:length(edges))
    println(stdout, "__TTFX_INV__:", replace(json_write(Dict("load" => load, "run" => run)), '\n' => ""))
end

end
