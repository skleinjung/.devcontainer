#!/usr/bin/env bash
set -euo pipefail

cd ~
# --autostash so local edits to tracked dotfiles don't block the rebase; they're
# stashed, the pull rebases, then they're reapplied on top.
git checkout main
git pull --rebase --autostash
