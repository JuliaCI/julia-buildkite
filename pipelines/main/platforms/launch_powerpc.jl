function parse_version_file()
    # This is the `/VERSION` file at the top-level of the `JuliaLang/julia` repo.
    filename = "VERSION"

    contents = read(filename, String)
    ver = VersionNumber(strip(contents))
    return ver
end

# arches_file is eg:
# .buildkite/pipelines/main/platforms/build_linux.powerpc.arches
const arches_file = ARGS[1]

# yaml_pipeline_file is eg:
# .buildkite/pipelines/main/platforms/build_linux.yml
const yaml_pipeline_file = ARGS[2]

const cmd = `bash ".buildkite/utilities/arches_pipeline_upload.sh" "$(arches_file)" "$(yaml_pipeline_file)"`

const parsed_julia_version = parse_version_file()
# const should_include_powerpc_builds = parsed_julia_version < v"1.12-" # TODO: Uncomment when finished debugging
const should_include_powerpc_builds = true # TODO: Delete this line when finished debugging

if should_include_powerpc_builds
    @info "Including PowerPC builds, because Julia is < 1.12" should_include_powerpc_builds parsed_julia_version
    run(cmd)
else
    @info "Skipping PowerPC builds, because Julia is >= 1.12" should_include_powerpc_builds parsed_julia_version
end
