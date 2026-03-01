## Dependencies

1. [shyaml-rs](https://github.com/0k/shyaml-rs)
    - `shyaml-rs` is a drop-in replacement for the old [Python `shyaml`](https://github.com/0k/shyaml), which is now deprecated.
    - On macOS and Linux, you can install `shyaml-rs` using Dilum's Homebrew tap:
        - `brew tap dilumaluthge/tap`
        - `brew install dilumaluthge/tap/shyaml-rs`
    - Alternatively, you can install it using the instructions in the [`shyaml-rs` repo](https://github.com/0k/shyaml-rs).

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
