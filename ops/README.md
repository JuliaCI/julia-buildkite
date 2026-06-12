# Julia CI trust infrastructure (post-cryptic)

This directory configures the AWS (and Azure) resources that replace the
`cryptic` Buildkite plugin:

- **`terraform/`** — the declarative infrastructure: Buildkite OIDC
  provider, the four KMS keys, the IAM roles and their policies.
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
| S3 uploads               | static `AWS_ACCESS_KEY_ID/SECRET` in yml   | OIDC → `julia-oidc-stage-{pr,ci}` (untrusted, per pipeline) + `julia-oidc-publish` (trusted) roles |
| macOS codesigning        | keychain file w/ Developer ID key          | KMS RSA key + patched `rcodesign` (`utilities/macos/rcodesign`) |
| macOS notarization       | Apple ID + app-specific password           | App Store Connect API key in KMS (ES256 JWTs via `kms:Sign`)  |
| Linux/source GPG signing | raw GPG private key file                   | fresh key generated in KMS, `utilities/kms_gpg_sign.py` (new public key published) |
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
 julia-pr  (pull requests)            julia-ci  (master / release-* / tags / scheduled)
   build ──► s3://julialang-ephemeral-pr/      build ──► s3://julialang-ephemeral-ci/
               <prefix>/<commit>/julia-*                   <prefix>/<commit>/julia-*
   (UNTRUSTED: the build step stages directly -- write-once, own pipeline's
    ephemeral bucket, own commit's path; per-pipeline roles
    julia-oidc-stage-pr / julia-oidc-stage-ci, no KMS)
   PRs stop here (juliaup reads               │  tests pass, julia-ci only:
   the -pr bucket).                           ▼  trigger
                              julia-publish  ──►  publish_all (single step)
   (TRUSTED: role julia-oidc-publish, kms:Sign + read julia-ci staging bucket
    ONLY + write final)
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

The publish step runs on a single linux `queue: publish` agent: every
signature is remote-key (KMS / Trusted Signing) and all packaging tooling
is ported to linux (see "Publish image prerequisites" below). The only
artifact that still requires a Mac is the one-time .app launcher skeleton
(AppleScript can only be compiled by `osacompile`), which is committed to
this repository.

## Trust model

Buildkite agents mint OIDC tokens (`buildkite-agent oidc request-token`)
whose `sub` claim is `organization:<org>:pipeline:<pipeline>:ref:<ref>:commit:<sha>:step:<step>`
and which carry AWS session tags (`step_key`, `build_commit`, `pipeline_slug`, ...).

* **Trusted roles** (`julia-oidc-publish`, `julia-oidc-docs-deploy`) are
  assumable only from the `julia-publish` pipeline slug, and only from the
  expected step (`aws:RequestTag/step_key` in the trust policy).
* Every trust policy additionally pins the Buildkite **organization,
  pipeline, and cluster UUIDs** (`aws:RequestTag/organization_id` /
  `pipeline_id` / `cluster_id`, values in
  `ops/terraform/buildkite_ids.auto.tfvars`). Slugs are renameable and can
  be re-minted by deleting + recreating a pipeline; the UUIDs cannot, so a
  recreated pipeline with a matching slug does not regain role access.
  IAM can only condition on `aud`/`sub` from the raw OIDC token, which is
  why these (like `step_key`) travel as AWS session tags requested in
  `utilities/aws_oidc.sh`; the claims are attested by Buildkite, and a
  token requested without the tags fails the trust conditions outright.
* **Staging**: each build pipeline has its own role
  (`julia-oidc-stage-pr` / `julia-oidc-stage-ci`), assumable from any job
  of that one pipeline (the build step assumes it directly; there is no
  step restriction on the untrusted roles). Each role can *only* write to
  its own pipeline's staging bucket, and only below
  `<prefix>/${aws:PrincipalTag/build_commit}/*` — the source git sha,
  an attested session tag the job cannot influence. The buckets
  (`julialang-ephemeral-pr` / `julialang-ephemeral-ci`) are ephemeral and
  lifecycle-expired, and publish reads **only** the `julia-ci` one — so a
  PR build can never place, or pre-claim (paths are write-once), anything
  that publish would consume. Build / PR jobs cannot touch release paths
  or sign anything. (Consumers, e.g. juliaup, map PR number → head sha
  via the GitHub API and fetch from the sha path in the `-pr` bucket.)
* **Tokens**: only `julia-ci` has a tokens role (`julia-oidc-tokens-ci`,
  SSM `ssm:GetParameter` on the telemetry tokens). There is deliberately
  no `-pr` counterpart: a pull request executes attacker-controlled code
  inside the job, which could exfiltrate any bearer token the job can
  read — so PR builds hold **no tokens at all** (and consequently no
  coverage/analytics uploads happen on PRs).
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

1. Create the three Buildkite pipelines and set their WebUI steps:
   - `julia-pr` — builds pull requests; WebUI = `pipelines/main/0_webui.yml`.
   - `julia-ci` — builds master / release-* / tags / schedule (no PRs);
     WebUI = `pipelines/main/0_webui.yml` (same launch flow; only `julia-ci`
     reaches the publish trigger via the `if:` in `trigger_publish.yml`).
   - `julia-publish` — PRs OFF, branch-limited, triggered by `julia-ci`;
     WebUI = `pipelines/publish/0_webui.yml`.
   All are plain `buildkite-agent pipeline upload` (no cryptic plugin, no
   `cryptic_capable` agent targeting).
2. Record the organization / pipeline / cluster UUIDs that the IAM trust
   policies pin (in addition to the slug-based `sub` patterns; slugs can
   be renamed or re-minted, UUIDs cannot) in
   `ops/terraform/buildkite_ids.auto.tfvars` and commit it (the UUIDs are
   not secrets). They come from the Buildkite REST API (token scope
   `read_pipelines`): `GET /v2/organizations/julialang` (`.id`) and
   `GET /v2/organizations/julialang/pipelines/<slug>` (`.id`,
   `.cluster_id`). The UUIDs are static; this needs redoing only if a
   pipeline is ever recreated or moved to another cluster. Terraform
   refuses to apply without real values here.
3. `terraform -chdir=ops/terraform init && terraform -chdir=ops/terraform apply`
   — creates the OIDC provider for `agent.buildkite.com`, the four KMS
   keys (the notary key as `EXTERNAL`-origin, pending import), and the
   IAM roles + policies (one stage role per build pipeline, tokens for
   julia-ci only, publish + docs-deploy). Re-apply any time trust
   patterns or policies change. Local state is fine while testing (it
   contains no secrets); once things settle, move it to S3 by adding a
   `backend "s3"` block (bucket `julia-ci-tfstate`, `use_lockfile =
   true`) and running `terraform init -migrate-state` — the resources
   are untouched by the migration.
4. Key material:
   * `./20_export_gpg_pubkey.py --created <today>` — exports the OpenPGP
     public half of the KMS-generated tarball signing key to
     `secrets/tarball_signing.pub.asc`. Commit it, and publish it as the
     new Julia releases signing key (it **replaces** the pre-migration
     `juliareleases.asc`; old signatures keep verifying against the old
     key, new signatures only against this one). `--created` is part of
     the key fingerprint: pin it and never change it.
   * `./21_import_notary_key.sh AuthKey_X.p8 <issuer-id> <key-id>` — the
     App Store Connect API key is Apple-generated and must be imported
     (from a trusted workstation; obtain the .p8 once via the legacy
     cryptic agent key, securely delete it afterwards). Writes
     `utilities/macos/notary_api_key.json` — commit it; it contains no
     secret material.
5. Telemetry tokens into SSM:
   * `./23_put_tokens.sh codecov_token`
   * `./23_put_tokens.sh coveralls_token`
   * `./23_put_tokens.sh buildkite_analytics_token`
6. macOS certificate for the new KMS key:
   * `./22_generate_macos_csr.sh`
   * Submit CSR at developer.apple.com → Developer ID Application cert
   * `openssl x509 -inform DER -in developerID_application.cer -out utilities/macos/developer_id.pem`
     and commit (certificates are public).
7. Docs deploy key:
   * `./24_docs_deploy_pubkey.sh` and register the printed key as a
     deploy key with write access on JuliaLang/docs.julialang.org.
   * Ensure the `aws_uploader` rootfs image (JuliaCI/rootfs-images)
     ships `aws_kms_pkcs11.so` (https://github.com/JackOfMostTrades/aws-kms-pkcs11).
8. Build + publish the patched rcodesign binary (on any x86_64 linux
   machine -- the publish job runs on linux):
   * `utilities/macos/rcodesign/build_rcodesign.sh`
   * `./30_upload_tools.sh <binary>`; update the pinned sha256 in
     `utilities/macos/get_rcodesign.sh`.
   And the one Mac-only artifact, the .app launcher skeleton (only needs
   redoing if `contrib/mac/app/startup.applescript` ever changes):
   * `./31_build_app_skeleton.sh /path/to/julia-checkout` (on a Mac) and
     commit `utilities/macos/julia-app-skeleton.tar.gz`.
9. `terraform -chdir=ops/terraform/azure apply -var azure_app_id=<client-id>`
   (with Azure credentials that may manage the Trusted Signing app
   registration) — federated credentials for Windows Trusted Signing
   (matched to the `julia-publish` pipeline, where Windows signing now
   runs); fill the (non-secret) `AZURE_TENANT_ID` / `AZURE_CLIENT_ID`
   placeholders on the `publish_all` step in `pipelines/publish/launch.yml`.
   If flexible federated credentials are unavailable on the tenant, fall
   back to `--subject-claim organization_id` tokens (exact-match credential
   on the Buildkite organization UUID) at the cost of org-level granularity.
10. Fill `JULIA_CI_AWS_ACCOUNT_ID` in `utilities/aws_oidc.sh` (from the
    `julia_ci_aws_account_id` Terraform output).
11. Once green: revoke the legacy static AWS IAM user, delete the cryptic
    agent keys from the agents, decommission `cryptic_capable` queues,
    revoke the old Apple Developer ID certificate, the Apple ID
    app-specific password, the old SSH deploy key, and the
    `AZURE_CLIENT_SECRET`. Revoke the old GPG release signing key (its
    private half lived on agents) and securely delete all copies; keep
    its revoked public key published so old releases remain verifiable.

## Agent/rootfs prerequisites

* AWS CLI on **all build agents/rootfs images** (the build step itself
  stages to S3 now), recent enough for
  `aws s3api put-object --if-none-match` (conditional writes). For linux
  builds that means inside the build rootfs images (`package_*`); also the
  macOS / Windows / FreeBSD build agents.
* AWS CLI on test agents/rootfs images too (the test step fetches the
  Test Analytics token from SSM itself). This one is soft: test_julia.sh
  skips the analytics upload with a warning when `aws` is missing.
* `aws_kms_pkcs11.so` in the `aws_uploader` rootfs (docs deploy).

### Publish image prerequisites (linux, `queue: publish`)

The single publish step signs and packages for every OS on linux:

* AWS CLI; python3 (stdlib only; `kms_gpg_sign.py`, plist editing, PE
  signature checks); a host julia (provided by the JuliaCI/julia plugin;
  patches pkgimage checksums in the foreign install trees).
* macOS: `rcodesign` is fetched at runtime (pinned sha256, see
  `utilities/macos/get_rcodesign.sh`); for the `.dmg`: `mkfs.hfsplus`
  (hfsprogs) and the `hfsplus` + `dmg` tools from
  [mozilla/libdmg-hfsplus](https://github.com/mozilla/libdmg-hfsplus)
  (the same tools Mozilla uses to package Firefox DMGs on linux; the
  mozilla fork carries the `symlink` and `attr` subcommands we use).
* Windows: Wine (64-bit) with Inno Setup 6 installed in the prefix at
  `C:\Program Files (x86)\Inno Setup 6` (or set `ISCC_EXE`); `jsign`
  >= 6.0 on PATH (Azure Trusted Signing storetype) + a JRE; `7z` (p7zip)
  for the .zip.

## Notes

* The GPG tarball signing key is **generated inside KMS** and never
  exists anywhere else; a new public key must therefore be published
  (`ops/20_export_gpg_pubkey.py`), and signatures made after the
  migration do not verify against the pre-migration `juliareleases.asc`.
  Only the notary key uses KMS `EXTERNAL` (BYOK) import, because Apple
  generates App Store Connect API keys and we cannot register our own
  public key with Apple.
* Retried upload jobs hitting an existing identical object are handled in
  `utilities/upload_julia.sh` (412 + ETag comparison), not by allowing
  overwrites.
* juliaup needs a change to consume PR binaries: resolve PR number → head
  sha via the GitHub API, then fetch
  `s3://julialang-ephemeral-pr/bin/<sha>/julia-*` (this replaces the old
  `julia-prNNNN-` upload filenames).
