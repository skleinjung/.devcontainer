#!/usr/bin/env bash
set -euo pipefail

# Wire the opus checkout to authenticate GitHub over HTTPS using the KMS-minted App token: the gh
# wrapper mints on demand (gated by the ambient AWS session) and `gh auth git-credential` hands the
# token to git. Works for everyone using this checkout — you at the terminal and any agent.
#
# Clone opus over HTTPS so git authenticates with the App token. An SSH clone would use your own
# keys/agent instead.
#
# Repo-local (not --global): the App installation token is scoped to twin-digital/opus. Idempotent.

REPO=/workspace/opus
[ -d "$REPO/.git" ] || exit 0

# Hand credentials to git via gh's own helper, routed through our minting wrapper (/usr/local/bin/gh).
# The leading empty value resets inherited helpers (e.g. the VS Code credential proxy) so the App
# token is authoritative for this repo rather than whatever the host happens to offer.
git -C "$REPO" config --local --unset-all credential.helper 2>/dev/null || true
git -C "$REPO" config --local --add credential.helper ""
git -C "$REPO" config --local --add credential.helper "!/usr/local/bin/gh auth git-credential"
