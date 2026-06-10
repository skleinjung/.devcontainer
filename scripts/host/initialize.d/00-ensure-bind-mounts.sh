#!/usr/bin/env bash
set -euo pipefail

# Make sure that any bind-mount targets exist. If the target of a bind mount
# doesn't exist on the host, Docker will create a _directory_ at that path. This
# will cause runtime problems when a mount is expected to be a file.

# pre-create missing directory targets
mkdir -p "${HOME}/.claude"
mkdir -p "${HOME}/.ssh"

# pre-create missing file targets
touch "${HOME}/.bash_history"
touch "${HOME}/.claude.json"
touch "${HOME}/.ssh/id_ed25519"
touch "${HOME}/.ssh/id_ed25519.pub"

