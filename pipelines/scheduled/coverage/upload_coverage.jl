Base.DEPOT_PATH[1] = mktempdir(; cleanup = true)

import Pkg
import Logging
import TOML

Pkg.add(; name = "Coverage", uuid = "a2441757-f6aa-5fb2-8edb-039e3f45d037", branch = "ib/modernize")

import Coverage

function get_external_stdlib_names(stdlib_dir::AbstractString)
    filename_list = filter(x -> isfile(joinpath(stdlib_dir, x)), readdir(stdlib_dir))
    # find all of the files like `Pkg.version`, `Statistics.version`, etc.
    regex_matches_or_nothing = match.(Ref(r"^([\w].*?)\.version$"), filename_list)
    regex_matches = filter(x -> x !== nothing, regex_matches_or_nothing)
    # get the names of the external stdlibs, like `Pkg`, `Statistics`, etc.
    external_stdlib_names = only.(regex_matches)
    unique!(external_stdlib_names)
    sort!(external_stdlib_names)
    @info "# Begin list of external stdlibs"
    for (i, x) in enumerate(external_stdlib_names)
        @info "$(i). $(x)"
    end
    @info "# End list of external stdlibs"
    return external_stdlib_names
end

function get_external_stdlib_prefixes(stdlib_dir::AbstractString)
    external_stdlib_names = get_external_stdlib_names(stdlib_dir)
    prefixes_1 = joinpath.(Ref(stdlib_dir), external_stdlib_names, Ref(""))
    prefixes_2 = joinpath.(Ref(stdlib_dir), string.(external_stdlib_names, Ref("-")))
    prefixes = vcat(prefixes_1, prefixes_2)
    unique!(prefixes)
    sort!(prefixes)
    # example of what `prefixes` might look like:
    # 4-element Vector{String}:
    # "stdlib/Pkg-"
    # "stdlib/Pkg/"
    # "stdlib/Statistics-"
    # "stdlib/Statistics/"
    return prefixes
end

function print_coverage_summary(fc::Coverage.FileCoverage)
    cov_lines, tot_lines = Coverage.get_summary(fc)
    if cov_lines == tot_lines == 0
        cov_pct = 0
    else
        cov_pct = floor(Int, cov_lines/tot_lines * 100)
    end
    pad_1 = 71
    pad_2 = 15
    pad_3 = 15
    col_1 = rpad(fc.filename, pad_1)
    col_2 = rpad(string(cov_pct, " %"), pad_2)
    col_3 = string(
        rpad(string(cov_lines), pad_3),
        string(tot_lines),
    )
    @info "$(col_1) $(col_2) $(col_3)"
    return nothing
end

function print_coverage_summary(
        fcs::Vector{Coverage.FileCoverage}, description::AbstractString,
    )
    cov_lines, tot_lines = Coverage.get_summary(fcs)
    if cov_lines == tot_lines == 0
        cov_pct = 0
    else
        cov_pct = floor(Int, cov_lines/tot_lines * 100)
    end
    @info "$(description): $(cov_pct)% ($(cov_lines)/$(tot_lines))"
    return (; cov_pct)
end

function buildkite_env(name::String)
    value = String(strip(ENV[name]))
    if isempty(value)
        throw(ErrorException("environment variable $(name) is empty"))
    end
    return value
end

function buildkite_env(name_1::String, name_2::String, default::String)
    value_1 = String(strip(ENV[name_1]))
    value_2 = String(strip(ENV[name_2]))
    !isempty(value_1) && return value_1
    !isempty(value_2) && return value_2
    return default
end

function buildkite_branch_and_commit()
    branch = buildkite_env("BUILDKITE_BRANCH")
    commit = String(strip(read(`git rev-parse HEAD`, String)))
    if !occursin(r"^[a-f0-9]{40}$", commit)
        msg = "'$(commit)' does not look like a long commit SHA"
        @error msg commit
        throw(ErrorException(msg))
    end
    return (; branch, commit)
end

# Load coverage data
fcs = Coverage.LCOV.readfolder("./lcov_files")

# Debug: Log what we're starting with
@info "Initial file count: $(length(fcs))"

# This assumes we're run with a current working directory of a julia checkout
base_jl_files = Set{String}()
cd("base") do
    for (root, dirs, files) in walkdir(".")
        # Strip off the leading `./`
        if startswith(root, ".")
            root = root[2:end]
        end
        if startswith(root, "/")
            root = root[2:end]
        end
        for f in files
            if !endswith(f, ".jl")
                continue
            end
            push!(base_jl_files, joinpath(root, f))
        end
    end
end

# Only include source code files. Exclude test files, benchmarking files, etc.
filter!(fcs) do fc
    # Base files do not have a directory name, they are all implicitly paths
    # relative to the `base/` folder, so the only way to detect them is to
    # compare them against a list of files that exist within `base`:
    fc.filename ∈ base_jl_files ||
        occursin("/src/", fc.filename) ||
        occursin("Compiler/", fc.filename)  # Include Compiler module files
end;

@info "After filtering for source files: $(length(fcs))"

# Exclude all stdlib JLLs (stdlibs of the form `stdlib/*_jll/`).
filter!(fcs) do fc
    !occursin(r"^stdlib\/[A-Za-z0-9]*?_jll\/", fc.filename)
end;

@info "After excluding JLLs: $(length(fcs))"

fcs = Coverage.merge_coverage_counts(fcs)
sort!(fcs; by = fc -> fc.filename);
fcs = map(fcs) do fc
    fc.filename ∈ base_jl_files && return Coverage.FileCoverage(joinpath("base", fc.filename), fc.source, fc.coverage)
    if occursin("stdlib", fc.filename)
        new_name = "stdlib" * String(split(fc.filename, joinpath("stdlib", "v" * string(VERSION.major) * "." * string(VERSION.minor)))[end])
        return Coverage.FileCoverage(new_name, fc.source, fc.coverage)
    else
        return fc
    end
end

# Must occur after truncation performed above
# Exclude all external stdlibs (stdlibs that live in external repos).
const external_stdlib_prefixes = get_external_stdlib_prefixes("stdlib")
filter!(fcs) do fc
    all(x -> !startswith(fc.filename, x), external_stdlib_prefixes)
end;

@info "After excluding external stdlibs: $(length(fcs))"

# Include base, stdlib, and Compiler files
filter!(fc -> (startswith(fc.filename, "base") ||
               startswith(fc.filename, "stdlib") ||
               startswith(fc.filename, "Compiler")), fcs)

@info "After final filtering: $(length(fcs))"

# This must be run to make sure all lines of code are hit.
# See docstring for `Coverage.amend_coverage_from_src!``
for fc in fcs
    Coverage.amend_coverage_from_src!(fc.coverage, fc.filename)
end

# Log detailed statistics about what we're uploading
@info "Coverage file statistics:"
base_files = filter(fc -> startswith(fc.filename, "base"), fcs)
stdlib_files = filter(fc -> startswith(fc.filename, "stdlib"), fcs)
compiler_files = filter(fc -> startswith(fc.filename, "Compiler"), fcs)

@info "  Base files: $(length(base_files))"
@info "  Stdlib files: $(length(stdlib_files))"
@info "  Compiler files: $(length(compiler_files))"

# Show sample files from each category for verification
if !isempty(base_files)
    @info "  Sample base files: $(first(base_files, min(3, length(base_files))) .|> (fc -> fc.filename))"
end
if !isempty(compiler_files)
    @info "  Sample Compiler files: $(first(compiler_files, min(3, length(compiler_files))) .|> (fc -> fc.filename))"
end

print_coverage_summary.(fcs);
const total_cov_pct = print_coverage_summary(fcs, "Total").cov_pct

# Set up Buildkite-specific environment variables for coverage services
function setup_buildkite_env()
    branch, commit = buildkite_branch_and_commit()

    # Set environment variables that the coverage uploaders expect
    ENV["CI"] = "true"
    ENV["BUILDKITE"] = "true"
    ENV["BUILDKITE_COMMIT"] = commit
    ENV["BUILDKITE_BRANCH"] = branch

    # For git info
    ENV["BUILDKITE_BUILD_AUTHOR"] = buildkite_env(
        "BUILDKITE_BUILD_AUTHOR",
        "BUILDKITE_BUILD_CREATOR",
        ""
    )
    ENV["BUILDKITE_BUILD_AUTHOR_EMAIL"] = buildkite_env(
        "BUILDKITE_BUILD_AUTHOR_EMAIL",
        "BUILDKITE_BUILD_CREATOR_EMAIL",
        ""
    )

    @info "Set up Buildkite environment for coverage upload" branch commit
end

# Upload coverage using the modern API
function upload_coverage(fcs)
    setup_buildkite_env()

    # Get tokens from environment
    codecov_token = get(ENV, "CODECOV_TOKEN", nothing)
    coveralls_token = get(ENV, "COVERALLS_TOKEN", nothing)

    success_results = []

    # Upload to Codecov if token is available
    if codecov_token !== nothing
        @info "Uploading to Codecov..."
        codecov_success = Coverage.upload_to_codecov(fcs; token=codecov_token)
        push!(success_results, codecov_success)
        if codecov_success
            @info "✅ Successfully uploaded to Codecov"
        else
            @error "❌ Failed to upload to Codecov"
        end
    else
        @warn "CODECOV_TOKEN not found, skipping Codecov upload"
    end

    # Upload to Coveralls if token is available
    if coveralls_token !== nothing
        @info "Uploading to Coveralls..."
        coveralls_success = Coverage.upload_to_coveralls(fcs; token=coveralls_token)
        push!(success_results, coveralls_success)
        if coveralls_success
            @info "✅ Successfully uploaded to Coveralls"
        else
            @error "❌ Failed to upload to Coveralls"
        end
    else
        @warn "COVERALLS_TOKEN not found, skipping Coveralls upload"
    end

    # Return overall success (at least one service succeeded)
    return !isempty(success_results) && any(success_results)
end

# Upload coverage
upload_success = upload_coverage(fcs)

if !upload_success
    @warn "Coverage upload failed for all services"
end

# Smoke test for coverage percentage
const smoke_test_pct = 60

if total_cov_pct < smoke_test_pct
    msg = string(
        "The total coverage is less than $(smoke_test_pct)%. This should never happen, ",
        "so it means that something has probably gone wrong with the code coverage job.",
    )
    @error msg total_cov_pct
    throw(ErrorException(msg))
end

@info "Coverage upload completed" total_coverage_pct=total_cov_pct upload_success=upload_success
