#!/usr/bin/env bash
set -euo pipefail

# Repo dependencies for the opus checkout, including the openspec CLI
# (@fission-ai/openspec is a root devDependency; run it with `pnpm exec openspec`).
cd /workspace/opus
pnpm install
