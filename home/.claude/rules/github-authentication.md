# GitHub Credentials

## Vended GitHub credentials (devcontainer)

GitHub access is via **per-org GitHub App tokens** vended to the shelf at
`/creds/github/<org>`. There is no single "my token" — select the correct
org's token for the repo you're touching.

- **Pin the org explicitly.** The `gh` wrapper sets `GH_TOKEN` from
  `devcred get github/<org>`, choosing `<org>` by: `GH_ORG` → `-R/--repo` →
  `GH_REPO` → the cwd's `origin` remote → `GH_DEFAULT_ORG`. The harness resets
  cwd between commands, so cwd-origin detection silently selects the wrong
  org. Always pin it: `GH_ORG=<org> gh …` or `gh -R <org>/<repo> …`.
- **Raw git over HTTPS:** `TOKEN=$(devcred get github/<org>); git push
  "https://x-access-token:$TOKEN@github.com/<org>/<repo>.git" <branch>`.
  Prefer HTTPS — SSH uses the forwarded hardware-key agent (touch-gated) and
  hangs in a headless session.
- **Don't conclude "no access" prematurely.** The `permissions` object from
  `GET /repos` is unreliable for App-installation tokens (it can read
  `push:false` on repos you can actually push to, especially public ones).
  Verify by *attempting the operation*. And `--paginate` any
  `installation/repositories` listing (default page = 30) before deciding a
  repo is out of scope.
- **Scope changes are human-only** (sidecar `vend.yaml` / App installation).
  If a token genuinely lacks a repo after the checks above, surface it and
  wait — don't work around it.
