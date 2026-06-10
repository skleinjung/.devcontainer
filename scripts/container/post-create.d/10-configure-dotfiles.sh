#!/usr/bin/env bash
set -euo pipefail

cd ~
git init
git remote add origin https://github.com/skleinjung/dotfiles.git
git fetch
git checkout -f main