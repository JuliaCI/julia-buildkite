## Expired certificates

The main symptom will be that the upload job will be failing. The unlock
keychain step prints the status of the certificate and it will print something
like (`CSSMERR_TP_CERT_EXPIRED`) if the certificate is expired.

### Update expired Apple Developer ID

To replace the certificate you will need first a MacOS machine and to emit a new
certificate.

1. To replace an expired Apple certificate, clone `julia-buildkite` repo and
   clone https://github.com/JuliaCI/cryptic-buildkite-plugin in its root.
   You will also need to have the private `agent.key`, and point towards it
   by defining the `AGENT_PRIVATE_KEY_PATH` environment variable.
2. You can decrypt by running `make decrypt`.
3. Get the `macos_codesigning.keychain` file in the `secrets` directory and add
   it to your local keychains with the Keychain Access app (File > Import
   Items).
4. From that app delete the old certificate and add the new one (it's a `.cer`
   file).
5. Test the certificate by right clicking and running both the general
   evaluation and the codesigning one.
6. Update the identity in `MACOS_CODESIGN_IDENTITY` (You can find the identity
   by doing `security find-identity -p codesigning $(PATH_TO_KEYCHAIN)/macos_codesigning.keychain` ).
7. You can also test it by running the codesign.sh script in this repo with
   `./utilities/macos/codesign.sh --keychain ./secrets/macos_codesigning.keychain --identity $(NEW_IDENTITY) ./test`
   with some executable.
8. Afterward reencrypt the keychain by running
   `./cryptic-buildkite-plugin/bin/encrypt_file --private-key=$(INSERT_PRIVATE_KEY) --repo-key=$(INSERT_REPO_KEY) ./secrets/macos_codesigning.keychain`
9. Finally sign the repo with `make sign_treehashes`

The `security` cli app is also useful for debugging and managing keychains. You
can find more information about it by running `man security` in the terminal.


## New agreements

It is also possible that just a new agreement is needed. In that case, you will
see the following error message returned by the `codesign` command:

> HTTP status code: 403. A required agreement is missing or has expired. This
> request requires an in-effect agreement that has not been signed or has
> expired. Ensure your team has signed the necessary legal agreements and that
> they are not expired.

In this case, it is sufficient to visit `developer.apple.com` and logging in
using the Apple ID that is associated with the Apple Developer account. You
will be prompted to accept the new agreement. After that, the build should
succeed.

Note that currently, the Apple ID that's used to sign Julia binaries is owned
by JuliaHub, so you will need to get in touch with somebody from the
organization to accept the agreement.
