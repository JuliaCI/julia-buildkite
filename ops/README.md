# Julia CI trust infrastructure (post-cryptic)

This directory configures the AWS (and Azure) resources that replace the
`cryptic` Buildkite plugin:

- **`terraform/`** — the declarative infrastructure: Buildkite OIDC
  provider, the four KMS keys, the four IAM roles and their policies.
- **`terraform/azure/`** — a separate root module (different control
  plane / credentials) for the Azure Trusted Signing federated identity
  credentials.
- **numbered scripts** — the imperative one-time operations: importing
  existing key material into KMS, entering bearer tokens, generating the
  macOS CSR, printing the docs deploy public key, uploading tool binaries.
  These stay out of Terraform on purpose: their inputs are secrets, and
  anything Terraform touches ends up in its state file. The Terraform
  state for this module therefore contains **no secret material** and can
  be stored in any ordinary backend. After this migration, **no private key ever
exists on a build agent or in this repository** — every signature is a
remote KMS operation, authorized by the job's OIDC identity:

| Concern                  | Before (cryptic)                          | After                                                        |
|--------------------------|-------------------------------------------|--------------------------------------------------------------|
| S3 uploads               | static `AWS_ACCESS_KEY_ID/SECRET` in yml   | OIDC → `julia-oidc-stage` (untrusted) + `julia-oidc-publish` (trusted) roles |
| macOS codesigning        | keychain file w/ Developer ID key          | KMS RSA key + patched `rcodesign` (`utilities/macos/rcodesign`) |
| macOS notarization       | Apple ID + app-specific password           | App Store Connect API key in KMS (ES256 JWTs via `kms:Sign`)  |
| Linux/source GPG signing | raw GPG private key file                   | GPG key material imported into KMS, `utilities/kms_gpg_sign.py` |
| Windows codesigning      | `AZURE_CLIENT_SECRET`                      | Azure workload identity federation (Buildkite OIDC)           |
| Docs deploy SSH key      | cryptic-encrypted key file                 | SSH key in KMS, ssh signs via [aws-kms-pkcs11](https://github.com/JackOfMostTrades/aws-kms-pkcs11) |
| Telemetry bearer tokens  | cryptic-encrypted variables                | SSM Parameter Store (SecureString), OIDC-gated `ssm:GetParameter` |

(The codecov / coveralls / buildkite-analytics tokens are bearer tokens —
there is no public-key operation to delegate — so they live in the AWS
secrets store and are fetched at runtime; they are never stored in the
repository in any form.)

## Trusted / untrusted pipeline split

The single most important control is that **pull requests and release
publishing run in different Buildkite pipelines**, and the trusted IAM roles
only trust the publish pipeline's slug. There are three pipelines:

- **`julia-pr`** — builds pull requests (untrusted).
- **`julia-ci`** — builds trusted refs only: master, release-*, tags, and the
  scheduled nightlies (untrusted to sign, but it is what triggers publish).
- **`julia-publish`** — the trusted pipeline that signs + promotes.

```
 julia-pr  (pull requests)          julia-ci  (master / release-* / tags / scheduled)
   build + test                        build + test
        │                                   │
        ▼                                   ▼
   stage_<triplet>  ──►  s3://<bucket>/<prefix>/staging/<commit>/julia-*.tar.gz
   (UNTRUSTED: role julia-oidc-stage, write-once to its own commit's staging path; no KMS)
   PRs stop here.                          │  julia-ci only: trigger
                                           ▼
                              julia-publish  ──►  publish_all (single step)
   (TRUSTED: role julia-oidc-publish, kms:Sign + read staging + write final)
   verify_trusted_commit.sh → sign (rcodesign / Trusted Signing / KMS-GPG) → promote → deploy docs
```

Why this is safe where branch-pinning was not: Buildkite reports a pull
request build's `sub` ref as the PR head branch, with no PR-vs-push
discriminator, so a fork PR whose branch is named `master` would match a
`ref:refs/heads/master` trust pattern. We therefore do **not** trust any
build-pipeline slug for signing. The trusted roles trust only the
`julia-publish` slug, and a PR (which only ever runs in `julia-pr`) cannot
produce a build under that slug.

**Required Buildkite configuration** (this is load-bearing — the IAM trust
depends on it):
- `julia-pr`: builds pull requests (this is the only pipeline that should).
- `julia-ci`: builds master / release-* / tags / schedule; **does not build
  pull requests**.
- `julia-publish`: "Build pull requests" OFF (incl. third-party forks);
  branch-limited to `master release-*` (plus build tags `v*`); triggered only
  by `julia-ci`. Its webUI step loads launch steps from a pinned
  julia-buildkite (the external-buildkite plugin), never from the triggered
  build's tree.
- Backstop: every publish job runs `utilities/verify_trusted_commit.sh`,
  which aborts unless `BUILDKITE_COMMIT` is reachable from a protected ref
  of the canonical upstream — so even a mis-triggered build cannot publish.

The publish step runs on a `queue: publish` agent whose image must carry the
full signing toolchain: `rcodesign` (cross-platform Apple signing + dmg +
notarize), InnoSetup + a cross-platform Authenticode signer (e.g. jsign /
azuresigntool) for Windows, the KMS-GPG python signer, and the AWS CLI.

## Trust model

Buildkite agents mint OIDC tokens (`buildkite-agent oidc request-token`)
whose `sub` claim is `organization:<org>:pipeline:<pipeline>:ref:<ref>:commit:<sha>:step:<step>`
and which carry AWS session tags (`step_key`, `build_commit`, `pipeline_slug`, ...).

* **Trusted roles** (`julia-oidc-publish`, `julia-oidc-docs-deploy`) are
  assumable only from the `julia-publish` pipeline slug, and only from the
  expected step (`aws:RequestTag/step_key` in the trust policy).
* **Staging** (`julia-oidc-stage`) may be assumed from any ref of `julia-ci`
  or `julia-pr`, but can *only* write to
  `<prefix>/staging/${aws:PrincipalTag/build_commit}/*` — a path containing
  the source git sha, tagged by the (trusted) agent itself. Build / PR jobs
  cannot touch release paths, sign anything, or read tokens.
  (Consumers, e.g. juliaup, map PR number → head sha via the GitHub API and
  fetch from the sha path.)
* **No overwrites**: all roles must use S3 conditional writes
  (`If-None-Match: *`, enforced via the `s3:if-none-match` policy condition);
  uploads of already-existing objects fail. The only exception is the
  `julia-latest-*` pointer objects, which release builds intentionally
  repoint. Object versioning on the bucket is recommended belt-and-braces.
* Signing never exposes key material: every signature (macOS code signature,
  notarization JWT, GPG tarball signature, docs-deploy SSH authentication)
  is a `kms:Sign` call, conditioned on the calling job's step
  (`aws:PrincipalTag/step_key`).

## Runbook

One-time setup, in order (admin AWS credentials; region and bucket names
are Terraform variables with the production defaults):

1. `terraform -chdir=ops/terraform init && terraform -chdir=ops/terraform apply`
   — creates the OIDC provider for `agent.buildkite.com`, the four KMS
   keys (the notary + tarball keys as `EXTERNAL`-origin, pending import),
   and the four IAM roles + policies. Re-apply any time trust patterns or
   policies change. Configure a state backend of your choice first (the
   state contains no secrets).
2. Import existing key material (from a trusted workstation; obtain the
   plaintexts once via the legacy cryptic agent key):
   * `./20_import_gpg_key.sh /path/to/tarball_signing.gpg`
   * `./21_import_notary_key.sh AuthKey_X.p8 <issuer-id> <key-id>`
     (writes `utilities/macos/notary_api_key.json` — commit it; it
     contains no secret material)
   * securely delete the plaintexts afterwards.
3. Telemetry tokens into SSM:
   * `./23_put_tokens.sh codecov_token`
   * `./23_put_tokens.sh coveralls_token`
   * `./23_put_tokens.sh buildkite_analytics_token`
4. macOS certificate for the new KMS key:
   * `./22_generate_macos_csr.sh`
   * Submit CSR at developer.apple.com → Developer ID Application cert
   * `openssl x509 -inform DER -in developerID_application.cer -out utilities/macos/developer_id.pem`
     and commit (certificates are public).
5. Docs deploy key:
   * `./24_docs_deploy_pubkey.sh` and register the printed key as a
     deploy key with write access on JuliaLang/docs.julialang.org.
   * Ensure the `aws_uploader` rootfs image (JuliaCI/rootfs-images)
     ships `aws_kms_pkcs11.so` (https://github.com/JackOfMostTrades/aws-kms-pkcs11).
6. Build + publish rcodesign binaries (on a macOS machine):
   * `utilities/macos/rcodesign/build_rcodesign.sh` (per arch)
   * `./30_upload_tools.sh <binary> <arch>`; update the pinned sha256s in
     `utilities/macos/get_rcodesign.sh`.
7. `terraform -chdir=ops/terraform/azure apply -var azure_app_id=<client-id>`
   (with Azure credentials that may manage the Trusted Signing app
   registration) — federated credentials for Windows Trusted Signing
   (matched to the `julia-publish` pipeline, where Windows signing now
   runs); fill the (non-secret) `AZURE_TENANT_ID` / `AZURE_CLIENT_ID`
   placeholders on the `publish_all` step in `pipelines/publish/launch.yml`.
   If flexible federated credentials are unavailable on the tenant, fall
   back to `--subject-claim organization_id` tokens (exact-match credential
   on the Buildkite organization UUID) at the cost of org-level granularity.
8. Fill `JULIA_CI_AWS_ACCOUNT_ID` in `utilities/aws_oidc.sh` (from the
   `julia_ci_aws_account_id` Terraform output).
9. Create/rename the three Buildkite pipelines and set their WebUI steps:
    - `julia-pr` — builds pull requests; WebUI = `pipelines/main/0_webui.yml`.
    - `julia-ci` — builds master / release-* / tags / schedule (no PRs);
      WebUI = `pipelines/main/0_webui.yml` (same launch flow; only `julia-ci`
      reaches the publish trigger via the `if:` in `trigger_publish.yml`).
    - `julia-publish` — PRs OFF, branch-limited, triggered by `julia-ci`;
      WebUI = `pipelines/publish/0_webui.yml`.
    All are plain `buildkite-agent pipeline upload` (no cryptic plugin, no
    `cryptic_capable` agent targeting).
10. Once green: revoke the legacy static AWS IAM user, delete the cryptic
    agent keys from the agents, decommission `cryptic_capable` queues,
    revoke the old Apple Developer ID certificate, the Apple ID
    app-specific password, the old SSH deploy key, and the
    `AZURE_CLIENT_SECRET`.

## Agent/rootfs prerequisites

* AWS CLI recent enough for `aws s3api put-object --if-none-match`
  (conditional writes) on all upload agents, and available in the
  `package_linux` rootfs (coverage jobs) + windows package docker image.
* `aws_kms_pkcs11.so` in the `aws_uploader` rootfs (docs deploy).
* python3 (stdlib only) on upload agents for `kms_gpg_sign.py`.

## Notes

* KMS `EXTERNAL` (BYOK) keys mean published GPG signatures keep verifying
  against the existing `juliareleases.asc` public key, and notarization
  keeps using the existing App Store Connect API key.
* Retried upload jobs hitting an existing identical object are handled in
  `utilities/upload_julia.sh` (412 + ETag comparison), not by allowing
  overwrites.
* juliaup needs a change to consume PR binaries: resolve PR number → head
  sha via the GitHub API, then fetch `bin/staging/<sha>/julia-*` (this
  replaces the old `julia-prNNNN-` upload filenames).
