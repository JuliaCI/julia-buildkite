# rcodesign with AWS KMS backend

This directory contains the tooling for macOS codesigning + notarization
without secrets on the build agents. We use
[apple-codesign](https://github.com/indygreg/apple-platform-rs/tree/main/apple-codesign)
(`rcodesign`) with an AWS KMS signing backend, maintained on our fork
[`KenoAIStaging/apple-platform-rs`](https://github.com/KenoAIStaging/apple-platform-rs/tree/aws-kms-backend)
(branch `aws-kms-backend`, on top of a pinned upstream commit). `build_rcodesign.sh`
clones that fork and builds it -- there is no local patch (see upstreaming note below).

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

```
./build_rcodesign.sh [output_dir]
```

builds `rcodesign` from the pinned fork commit (bump `APPLE_PLATFORM_RS_COMMIT`
in that script after pushing to the fork). CI downloads a prebuilt binary from
S3 (`tools/rcodesign-<version>-<arch>`, uploaded by `ops/30_upload_tools.sh` in
this repo) and verifies its sha256; see `utilities/macos/codesign.sh`.

## Upstreaming

The `aws-kms-backend` branch is self-contained and written to upstream standards
(feature-gated `aws-kms` Cargo feature, docs in `apple_codesign_aws_kms.rst`,
unit tests). Consider submitting it as a PR to `indygreg/apple-platform-rs`;
once merged, `build_rcodesign.sh` shrinks to a plain upstream version pin.
