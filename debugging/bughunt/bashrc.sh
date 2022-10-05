#!/bin/bash

# Add our `bughunt_commands` folder onto the end of PATH
# We do this here so that we can inherit the default `PATH` of the container
export PATH="$PATH:/usr/local/libexec/bughunt_commands"

# I use this too much.
alias ll="ls -la"
