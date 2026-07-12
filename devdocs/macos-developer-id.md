# macOS Developer ID certificate

The Developer ID Application private key lives in AWS KMS
(`alias/julia-macos-codesigning`); macOS codesigning happens via
`rcodesign` with the AWS KMS backend (see `utilities/macos/rcodesign/`).
The certificate itself is public and committed at
`utilities/macos/developer_id.pem`.

## Expired certificate

The main symptom will be failing upload jobs (signature validation errors
or Apple rejecting the notarization). To renew:

1. Generate a fresh CSR from the KMS key (no new key needed):
   `ops/22_generate_macos_csr.sh`
2. Submit it at https://developer.apple.com/account/resources/certificates
   (type: "Developer ID Application"), download the `.cer`.
3. Convert and commit:
   `openssl x509 -inform DER -in developerID_application.cer -out utilities/macos/developer_id.pem`
4. Test locally (requires kms:Sign on the key):
   `rcodesign sign --aws-kms-key alias/julia-macos-codesigning --aws-kms-certificate-file utilities/macos/developer_id.pem <some-binary>`

## New agreements

It is also possible that just a new agreement is needed. In that case, you
will see the following error message during notarization:

> HTTP status code: 403. A required agreement is missing or has expired.
> This request requires an in-effect agreement that has not been signed or
> has expired. Ensure your team has signed the necessary legal agreements
> and that they are not expired.

In this case, it is sufficient to visit `developer.apple.com` and log in
using the Apple ID that is associated with the Apple Developer account. You
will be prompted to accept the new agreement. After that, the build should
succeed.

Note that currently, the Apple ID that's used to sign Julia binaries is
owned by JuliaHub, so you will need to get in touch with somebody from the
organization to accept the agreement.
