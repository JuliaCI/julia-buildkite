# Concise release checklist

1. Create tag
    - [ ] `git tag vX.Y.Z <sha> && git push origin vX.Y.Z`
    - [ ] Wait until `julia-ci` is green on `vX.Y.Z`
    - [ ] Wait until `julia-publish` is green on `vX.Y.Z`
2. `julia-promote`
    - [ ] `bk build create -p julialang/julia-promote --branch vX.Y.Z --commit -m "Promote vX.Y.Z" -i`
    - [ ] Wait until `julia-promote` is green on `vX.Y.Z`
3. GitHub release
    - [ ] If latest Julia release:           `gh release create vX.Y.Z --repo JuliaLang/julia --verify-tag --latest=true  --title vX.Y.Z`
    - [ ] If older Julia release (e.g. LTS): `gh release create vX.Y.Z --repo JuliaLang/julia --verify-tag --latest=false --title vX.Y.Z`
    - [ ] `contrib/github_source_release.sh vX.Y.Z --execute`
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
