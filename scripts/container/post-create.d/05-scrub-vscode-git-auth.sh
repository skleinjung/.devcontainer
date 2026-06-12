#!/usr/bin/env bash
set -euo pipefail

# Neutralize VS Code's host-reaching env channels in INTERACTIVE TERMINALS. devcontainer.json
# `remoteEnv` already blanks these for the processes VS Code spawns (the agent's non-interactive
# shells included) — but VS Code RE-INJECTS VSCODE_GIT_IPC_HANDLE / VSCODE_IPC_HOOK_CLI / BROWSER
# into integrated terminals via its terminal EnvironmentVariableCollection, overriding remoteEnv
# there (empirically confirmed). This shell scrub is what cleans interactive terminals, and so
# also anything launched from them (e.g. an agent started by typing `claude`). git/gh are
# unaffected — they authenticate via git-credential-shelf, independent of askpass. See SECURITY.md
# "two-layer env neutralization".
#
# TODO(#4): installs via sudo, which #4 removes (no-new-privileges disables setuid sudo). Move
# this to a build-time Dockerfile step before #4 lands.
#
# Residual: a process launched directly by the VS Code server (not via a terminal shell that
# sources these files) could still inherit VSCODE_GIT_IPC_HANDLE and would have to speak the git
# IPC protocol to the socket directly — a much higher bar, and the easy askpass path is gone.

scrub='# Drop VS Code host-reaching channels so they are not inherited by agents (see .devcontainer
# README). Secondary to devcontainer.json remoteEnv (which covers VS Code-spawned processes); this
# covers shells started OUTSIDE VS Code, e.g. `docker exec`. SSH_AUTH_SOCK is intentionally kept.
unset GIT_ASKPASS VSCODE_GIT_ASKPASS_NODE VSCODE_GIT_ASKPASS_MAIN VSCODE_GIT_ASKPASS_EXTRA_ARGS \
      VSCODE_GIT_IPC_HANDLE VSCODE_IPC_HOOK_CLI BROWSER GPG_AGENT_INFO 2>/dev/null || true'

f=/etc/profile.d/50-scrub-vscode-git-auth.sh
printf '%s\n' "$scrub" | sudo tee "$f" >/dev/null
sudo chmod 0644 "$f"

# Login shells source /etc/profile -> profile.d; interactive non-login shells source
# /etc/bash.bashrc, which may not. Wire bash.bashrc to the same file so both are covered.
if ! sudo grep -qF '50-scrub-vscode-git-auth.sh' /etc/bash.bashrc 2>/dev/null; then
  printf '\n. %s\n' "$f" | sudo tee -a /etc/bash.bashrc >/dev/null
fi
