## Dependencies

1. [shyaml](https://github.com/0k/shyaml)

## Instructions

If you are a maintainer, and you want to re-sign all of the signatures, here are the steps:

### If you only have access to the _repository_ private key

```shell
git clone git@github.com:JuliaCI/julia-buildkite.git
cd julia-buildkite
git checkout YOURINITIALS/YOUR-BRANCH-NAME
git clone https://github.com/JuliaCI/cryptic-buildkite-plugin.git
mv /path/to/my/repository/private/key ./cryptic_repo_keys/repo_key
make sign_treehashes
git push origin YOURINITIALS/YOUR-BRANCH-NAME
```

### If you have access to the _agent_ private key

```
git clone git@github.com:JuliaCI/julia-buildkite.git
cd julia-buildkite
git checkout YOURINITIALS/YOUR-BRANCH-NAME
git clone https://github.com/JuliaCI/cryptic-buildkite-plugin.git
cd cryptic-buildkite-plugin
git checkout main
cd ..
export AGENT_PRIVATE_KEY_PATH=/path/to/my/agent.key
make sign_treehashes
unset AGENT_PRIVATE_KEY_PATH
rm -f /path/to/my/agent.key
git push origin YOURINITIALS/YOUR-BRANCH-NAME
```
