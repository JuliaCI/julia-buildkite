# Concise release checklist

1. Create tag
    - [ ] `git tag v1.X.Y <sha> && git push origin v1.X.Y`
    - [ ] Wait until `julia-ci` is green on `v1.X.Y`
    - [ ] Wait until `julia-publish` is green on `v1.X.Y`
2. `julia-promote`
    - [ ] `bk build create -p julialang/julia-promote --branch v1.X.Y --commit v1.X.Y -m 'Promote v1.X.Y' -i`
    - [ ] Wait until `julia-promote` is green on `v1.X.Y`
3. GitHub release
    - [ ] If latest Julia release:           `gh release create v1.X.Y --repo JuliaLang/julia --verify-tag --latest=true  --title v1.X.Y`
    - [ ] If older Julia release (e.g. LTS): `gh release create v1.X.Y --repo JuliaLang/julia --verify-tag --latest=false --title v1.X.Y`
    - [ ] `contrib/github_source_release.sh v1.X.Y --execute`
4. `versions.json`
    - [ ] Trigger: https://github.com/JuliaLang/VersionsJSONUtil.jl/actions/workflows/CI.yml
    - [ ] Wait until it's done.
5. Juliaup version DB
    - [ ] Trigger: https://github.com/JuliaLang/juliaup/actions/workflows/updateversiondb.yml
    - [ ] Wait until it's done.
6. PDF docs
    - [ ] https://github.com/JuliaLang/docs.julialang.org/actions/workflows/PDFs.yml
    - [ ] Wait until it's done.
7. Website PR
    - [ ] Update `version` and `date` in `config.md`
    - [ ] Regenerate oldreleases
8. Discourse announcement
    - [ ] Post Discourse announcement
