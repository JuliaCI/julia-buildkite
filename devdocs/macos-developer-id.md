## Expired Apple Developer ID

1. To replace an expired Apple certificate, you must download the julia-buildkite repo and decrypt by running `make decrypt`.
2. Get the macos_codesigning.keychain file and add it to your local keychains with the Keychain Access app.
3. From that app delete the old certificate and add the new one (it's a .cer file).
4. Test the certificate by right clicking and running both the general evaluation and the codesigning one.
5. Update the identity in `MACOS_CODESIGN_IDENTITY` (You can find the identity by doing `security find-identity -p codesigning $(PATH_TO_KEYCHAIN)/macos_codesigning.keychain` ).
6. You can also test it by running the codesign.sh script in this repo with `./utilities/macos/codesign.sh --keychain ./secrets/macos_codesigning.keychain --identity $(NEW_IDENTITY) ./test` with some executable.
7. Afterward reencrypt the keychain by running `./cryptic-buildkite-plugin/bin/encrypt_file --private-key=$(INSERT_PRIVATE_KEY) --repo-key=$(INSERT_REPO_KEY) ./secrets/macos_codesigning.keychain`
8. Finally sign the repo with `make sign_treehashes`

The `security` cli app is also useful for debugging and managing keychains. You can find more information about it by running `man security` in the terminal.