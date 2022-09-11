const root_pipelines_main_misc_pdfdocs = @__DIR__
const root_pipelines_main_misc = dirname(root_pipelines_main_misc_pdfdocs)
const root_pipelines_main = dirname(root_pipelines_main_misc)
const root_pipelines = dirname(root_pipelines_main)
const root = dirname(root_pipelines)
const root_utilities = joinpath(root, "utilities")
include(joinpath(root_utilities, "proc_utils.jl"))

documenter_latex_debug = ENV["DOCUMENTER_LATEX_DEBUG"]
@info "" documenter_latex_debug

julia_executable = Base.julia_cmd().exec[1]
cmd = `make -C doc pdf JULIA_EXECUTABLE=$(julia_executable)`
proc = run(ignorestatus(cmd))

rm("latex-debug-logs.tar.gz"; force = true)
run(`tar czvf latex-debug-logs.tar.gz $(documenter_latex_debug)`)
run(`buildkite-agent artifact upload latex-debug-logs.tar.gz`)

mirror_exit_code(proc)
