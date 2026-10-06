# Minimal JSON reader and writer shared by the TTFX scripts, so they run under any julia
# build with no packages installed (the builds under test include release branches without
# a JSON stdlib). Objects read back as Dict{String,Any}, arrays as Vector{Any}, numbers as
# Int or Float64, null as nothing.
module TTFXJSON

export json_parse, json_write

json_parse(s::AbstractString) = json_parse(Vector{UInt8}(codeunits(s)))

function json_parse(b::Vector{UInt8})
    v, i = parse_value(b, skipws(b, 1))
    i = skipws(b, i)
    i > length(b) || error("trailing characters at byte $i")
    return v
end

function skipws(b, i)
    while i <= length(b) && (b[i] == UInt8(' ') || b[i] == UInt8('\n') || b[i] == UInt8('\r') || b[i] == UInt8('\t'))
        i += 1
    end
    return i
end

function expect(b, i, s::String)
    for c in codeunits(s)
        (i <= length(b) && b[i] == c) || error("expected $(repr(s)) at byte $i")
        i += 1
    end
    return i
end

function parse_value(b, i)
    i <= length(b) || error("unexpected end of input")
    c = b[i]
    if c == UInt8('{')
        d = Dict{String,Any}()
        i = skipws(b, i + 1)
        b[i] == UInt8('}') && return d, i + 1
        while true
            k, i = parse_string(b, skipws(b, i))
            i = expect(b, skipws(b, i), ":")
            v, i = parse_value(b, skipws(b, i))
            d[k] = v
            i = skipws(b, i)
            b[i] == UInt8(',') && (i += 1; continue)
            b[i] == UInt8('}') && return d, i + 1
            error("expected ',' or '}' at byte $i")
        end
    elseif c == UInt8('[')
        a = Any[]
        i = skipws(b, i + 1)
        b[i] == UInt8(']') && return a, i + 1
        while true
            v, i = parse_value(b, skipws(b, i))
            push!(a, v)
            i = skipws(b, i)
            b[i] == UInt8(',') && (i += 1; continue)
            b[i] == UInt8(']') && return a, i + 1
            error("expected ',' or ']' at byte $i")
        end
    elseif c == UInt8('"')
        return parse_string(b, i)
    elseif c == UInt8('t')
        return true, expect(b, i, "true")
    elseif c == UInt8('f')
        return false, expect(b, i, "false")
    elseif c == UInt8('n')
        return nothing, expect(b, i, "null")
    else
        j = i
        while j <= length(b) && (b[j] in UInt8('0'):UInt8('9') || b[j] in (UInt8('-'), UInt8('+'), UInt8('.'), UInt8('e'), UInt8('E')))
            j += 1
        end
        s = String(b[i:j-1])
        n = something(tryparse(Int, s), tryparse(Float64, s), Some(nothing))
        n === nothing && error("bad number $(repr(s)) at byte $i")
        return n, j
    end
end

function parse_string(b, i)
    b[i] == UInt8('"') || error("expected string at byte $i")
    out = UInt8[]
    i += 1
    while true
        i <= length(b) || error("unterminated string")
        c = b[i]
        if c == UInt8('"')
            return String(out), i + 1
        elseif c == UInt8('\\')
            e = b[i + 1]
            if e == UInt8('u')
                u = parse(UInt32, String(b[i+2:i+5]); base = 16)
                i += 6
                if 0xd800 <= u <= 0xdbff  # surrogate pair
                    lo = parse(UInt32, String(b[i+2:i+5]); base = 16)
                    u = 0x10000 + ((u - 0xd800) << 10) + (lo - 0xdc00)
                    i += 6
                end
                append!(out, codeunits(string(Char(u))))
                continue
            end
            push!(out, e == UInt8('n') ? UInt8('\n') : e == UInt8('t') ? UInt8('\t') :
                       e == UInt8('r') ? UInt8('\r') : e == UInt8('b') ? UInt8('\b') :
                       e == UInt8('f') ? UInt8('\f') : e)
            i += 2
        else
            push!(out, c)
            i += 1
        end
    end
end

function json_escape(s::AbstractString)
    io = IOBuffer()
    write(io, '"')
    for c in s
        if c == '"'      ; write(io, "\\\"")
        elseif c == '\\' ; write(io, "\\\\")
        elseif c == '\n' ; write(io, "\\n")
        elseif c == '\r' ; write(io, "\\r")
        elseif c == '\t' ; write(io, "\\t")
        elseif c < ' '
            write(io, "\\u", lpad(string(UInt32(c), base = 16), 4, '0'))
        else
            write(io, c)
        end
    end
    write(io, '"')
    return String(take!(io))
end

# Pretty-printed; dictionaries by sorted key, named tuples in field order.
function json_write(v, indent::Int = 0)
    pad = " "^indent
    if v === nothing
        "null"
    elseif v isa AbstractString || v isa Symbol
        json_escape(string(v))
    elseif v isa Bool
        string(v)
    elseif v isa AbstractFloat
        isfinite(v) ? string(v) : "null"
    elseif v isa Number
        string(v)
    elseif v isa NamedTuple || v isa AbstractDict
        ks = v isa NamedTuple ? collect(keys(v)) : sort!(collect(keys(v)); by = string)
        isempty(ks) && return "{}"
        items = ["$pad  $(json_escape(string(k))): $(json_write(v[k], indent + 2))" for k in ks]
        "{\n" * join(items, ",\n") * "\n$pad}"
    elseif v isa AbstractVector || v isa Tuple
        isempty(v) && return "[]"
        if all(x -> x isa Number || x === nothing, v)
            "[" * join((json_write(x) for x in v), ", ") * "]"
        else
            "[\n" * join(["$pad  " * json_write(x, indent + 2) for x in v], ",\n") * "\n$pad]"
        end
    else
        json_escape(string(v))
    end
end

end # module
