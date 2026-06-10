#!/usr/bin/env bash
set -euo pipefail

# TODO: why is this here instead of in the Dockerfile? we should standardize...

# install ansible
pipx install ansible-core

# install dependencies needed by Ansible plugins
pipx inject ansible-core requests
