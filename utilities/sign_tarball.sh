#!/bin/bash

TARGET="${2}"

# Create temporary gpg home so that we have an isolated keyring
export GNUPGHOME="$(mktemp -d)"
trap 'rm -rf "$GNUPGHOME"' EXIT INT TERM HUP

# Import key as first argument
gpg --import <"${1}"

# Sign the second argument as a file, creating a `.asc` file.
gpg --armor --detach-sig --batch --yes "${2}"

# Kill gpg-agent when we're done
gpgconf --kill gpg-agent
