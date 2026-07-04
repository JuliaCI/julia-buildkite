# rcodesign with AWS KMS backend

This directory documents the tooling for macOS codesigning + notarization
without secrets on the build agents. We use
[apple-codesign](https://github.com/indygreg/apple-platform-rs/tree/main/apple-codesign)
(`rcodesign`) with an AWS KMS signing backend, maintained on
[`JuliaCI/apple-platform-rs`](https://github.com/JuliaCI/apple-platform-rs/tree/julia-build)
(branch `julia-build`: upstream main plus the patch series listed under
Upstreaming below).

## How it works

* The **Developer ID Application certificate's private key** is an RSA-2048
  key held in AWS KMS (`SIGN_VERIFY`). `rcodesign sign --aws-kms-key <arn>
  --aws-kms-certificate-file <cert>` performs each low-level signature via
  the KMS `Sign` API. Key material never reaches the agent.
* The **App Store Connect API key** (ECDSA P-256, used to mint ES256 JWTs
  for the notary service) is also held in KMS. The unified API key JSON
  (`utilities/macos/notary_api_key.json`) references the KMS key ARN and
  contains **no secret material**, so it is committed in plaintext.
* AWS credentials come from Buildkite OIDC via
  `AWS_WEB_IDENTITY_TOKEN_FILE`/`AWS_ROLE_ARN` (see
  `utilities/aws_oidc.sh`); IAM policies restrict `kms:Sign` to the
  appropriate pipeline/step session tags.

## Building

Yggdrasil builds the binary (recipe `R/rcodesign`, `GitSource` pinned to a
`julia-build` commit, `--features aws-kms` on all platforms) and publishes it
as [`rcodesign_jll`](https://github.com/JuliaBinaryWrappers/rcodesign_jll.jl)
release assets. CI fetches and sha256-verifies the pinned tarball via
`utilities/macos/get_rcodesign.sh`.

To ship a new build: push the updated `julia-build` branch to
`JuliaCI/apple-platform-rs`, open a Yggdrasil PR bumping the `GitSource`
commit in `R/rcodesign/build_tarballs.jl`, and once the new `rcodesign_jll`
release exists, update the version / sha256 / base URL pins in
`get_rcodesign.sh`.

## Upstreaming

The patches are submitted to `indygreg/apple-platform-rs` as three series
(branches on `KenoAIStaging/apple-platform-rs`): `upstream-macho-robustness`
(zero-slice Mach-O fixes), `upstream-asc-signer` (external ES256 signers for
App Store Connect tokens), and `upstream-aws-kms` (the feature-gated
`aws-kms` backend, docs in `apple_codesign_aws_kms.rst`, unit tests). Once
they land and a release is cut, the Yggdrasil recipe returns to plain
upstream release tarballs.
