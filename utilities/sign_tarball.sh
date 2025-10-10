#!/usr/bin/env bash

TARGET="${2}"

# Create temporary gpg home so that we have an isolated keyring
GNUPGHOME="$(mktemp -d)"
export GNUPGHOME
trap 'rm -rf "$GNUPGHOME"' EXIT INT TERM HUP

# Import key as first argument.  The `touch` is a workaround for a `gpg-agent` bug.
touch /dev/random /dev/urandom
gpg --import <"${1}"

# Sign the second argument as a file, creating a `.asc` file.
gpg --armor --detach-sig --batch --yes "${TARGET}"

# Kill gpg-agent when we're done
gpgconf --kill gpg-agent
