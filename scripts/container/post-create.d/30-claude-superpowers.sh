#!/usr/bin/env bash
set -euo pipefail

# Superpowers plugin for Claude Code, user scope (~/.claude is a persistent bind mount).
# Re-runnable: an existing install prints "already installed" and exits 0. The marketplace
# is public; CLAUDE_CODE_PLUGIN_PREFER_HTTPS=1 (devcontainer.json) keeps the fetch off SSH.
claude plugin install superpowers@claude-plugins-official --scope user
