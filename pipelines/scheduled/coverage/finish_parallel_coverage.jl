# Script to signal completion of parallel Coveralls uploads
# This should be run after all parallel coverage upload jobs have completed

Base.DEPOT_PATH[1] = mktempdir(; cleanup = true)

import Pkg
import Logging

Pkg.add(; name = "Coverage", uuid = "a2441757-f6aa-5fb2-8edb-039e3f45d037", rev = "ib/modernize")

import Coverage

@info "Signaling completion of parallel Coveralls uploads..."

# Check if we have a Coveralls token
coveralls_token = get(ENV, "COVERALLS_TOKEN", nothing)
if coveralls_token === nothing
    @warn "COVERALLS_TOKEN not found - parallel completion not needed"
    exit(0)
end

# Signal that all parallel jobs are complete
try
    success = Coverage.finish_coveralls_parallel(token=coveralls_token)
    if success
        @info "✅ Successfully signaled parallel job completion to Coveralls"
        exit(0)
    else
        @error "❌ Failed to signal parallel completion"
        exit(1)
    end
catch e
    @error "❌ Error during parallel completion" exception=e
    exit(1)
end
