# Julia CI trust infrastructure (post-cryptic)

These scripts configure the AWS (and Azure) resources that replace the
`cryptic` Buildkite plugin. After this migration, **no private key ever
exists on a build agent or in this repository** — every signature is a
remote KMS operation, authorized by the job's OIDC identity:

| Concern                  | Before (cryptic)                          | After                                                        |
|--------------------------|-------------------------------------------|--------------------------------------------------------------|
| S3 uploads               | static `AWS_ACCESS_KEY_ID/SECRET` in yml   | OIDC → `julia-ci-upload[-pr]` role                            |
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

## Trust model

Buildkite agents mint OIDC tokens (`buildkite-agent oidc request-token`)
whose `sub` claim is `organization:<org>:pipeline:<pipeline>:ref:<ref>:commit:<sha>:step:<step>`
and which carry AWS session tags (`step_key`, `build_commit`, `pipeline_slug`, ...).

* **Release roles** (`julia-ci-upload`, `julia-ci-docs-deploy`) only trust
  `master` / `release-*` / `v*` tag refs of the release pipelines, and only
  from the expected step (`aws:RequestTag/step_key` in the trust policy).
* **PR uploads** (`julia-ci-upload-pr`) may be assumed from any ref, but can
  *only* write to `bin/pr/${aws:PrincipalTag/build_commit}/*` — a path
  containing the source git sha, tagged by the (trusted) agent itself. PR
  builds cannot touch release paths, sign anything, or read tokens.
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

One-time setup, in order (admin AWS credentials; region via `AWS_REGION`,
defaults in `common.sh`):

1. `./10_oidc_provider.sh` — IAM OIDC provider for `agent.buildkite.com`.
2. `./11_kms_keys.sh` — create the five KMS keys.
3. `./12_iam_roles.sh` — create/update the four roles + policies.
   Re-run any time patterns/policies change.
4. Import existing key material (from a trusted workstation; obtain the
   plaintexts once via the legacy cryptic agent key):
   * `./20_import_gpg_key.sh /path/to/tarball_signing.gpg`
   * `./21_import_notary_key.sh AuthKey_X.p8 <issuer-id> <key-id>`
     (writes `utilities/macos/notary_api_key.json` — commit it; it
     contains no secret material)
   * securely delete the plaintexts afterwards.
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
8. Build + publish rcodesign binaries (on a macOS machine):
   * `utilities/macos/rcodesign/build_rcodesign.sh` (per arch)
   * `./30_upload_tools.sh <binary> <arch>`; update the pinned sha256s in
     `utilities/macos/get_rcodesign.sh`.
9. `AZURE_APP_ID=... ./50_azure_trusted_signing_oidc.sh` — federated
   credentials for Windows Trusted Signing; fill the (non-secret)
   `AZURE_TENANT_ID` / `AZURE_CLIENT_ID` placeholders in
   `pipelines/*/platforms/upload_windows*.yml`. If flexible federated
   credentials are unavailable on the tenant, fall back to
   `--subject-claim organization_id` tokens (exact-match credential on the
   Buildkite organization UUID) at the cost of org-level granularity.
10. Fill `JULIA_CI_AWS_ACCOUNT_ID` in `utilities/aws_oidc.sh`.
11. Update the Buildkite WebUI steps to match `pipelines/*/0_webui.yml`
    (plain `buildkite-agent pipeline upload`, no cryptic plugin, no
    `cryptic_capable` agent targeting).
12. Once green: revoke the legacy static AWS IAM user, delete the cryptic
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
  sha via the GitHub API, then fetch `bin/pr/<sha>/julia-*` (this replaces
  the old `julia-pr<NUM>-` upload names).
