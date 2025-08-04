if Base.VERSION < v"1.6"
    throw(ErrorException("The `$(basename(@__FILE__))` script requires Julia 1.6 or greater"))
end

function mirror_exit_code(process::Base.Process)
    # If the process signalled, let's try to mirror the signal
    if process.termsignal != 0
        # Blindly call `raise()` as some signals are fatal by default
        ccall(:raise, Cvoid, (Cint,), process.termsignal)

        # If that signal doesn't kill us, and we got a nonzero exit
        # code from the process, go ahead and just mirror that
        if process.exitcode != 0
            exit(process.exitcode)
        else
            # Otherwise, the process died from a signal that we don't
            # die from.  Let's just exit with 1 in that case.
            exit(1)
        end
    end

    # If the process didn't signal, just mirror its exit code.
    exit(process.exitcode)
end

function get_bool_from_env(name::AbstractString, default_value::Bool)
    value = get(ENV, name, "$(default_value)") |> strip |> lowercase
    result = parse(Bool, value)::Bool
    return result
end

const is_buildkite = get_bool_from_env("BUILDKITE", false)
const Cpid_t = Int32
