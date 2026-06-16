# Workspace devcontainer

A hardened dev container built on the **[`devcontainers` toolkit](../devcontainers)**: the
`workspace` runs on the toolkit's `default` image plus a thin specialized layer
([Dockerfile](./Dockerfile) — pandoc, Claude Code, `tf`/`aws-get-account-id`, dotfiles),
and a **credential sidecar** vends short-lived, scoped AWS + GitHub credentials onto a
read-only `/creds` shelf the workspace consumes.

- **Patterns** (trust model, VS Code channel hardening, container isolation, the credential
  contract) live in the toolkit: [devcontainers/docs/SECURITY.md](../devcontainers/docs/SECURITY.md)
  and [SECRETS.md](../devcontainers/docs/SECRETS.md).
- **What's specific to this devcontainer** (trust tiers, what it vends, mounts, invariants)
  is in [SECURITY.md](./SECURITY.md).
- This file is the **operational guide** — first run, daily use, troubleshooting.

## Components

| | Image | Role |
|---|---|---|
| `workspace` | `default` + [Dockerfile](./Dockerfile) | the dev container; reads `/creds` via base's `devcred`/git/gh/aws shims |
| `credentials` | `credential-shelf` + [creds/](./creds) | one image, N loops — vends the AWS agent role → `/creds/aws/credentials` and per-org GitHub App tokens → `/creds/github/<org>` |

The sidecar holds the SSO session + `kms:Sign` in an `admin-home` volume mounted into **no**
consumer. The workspace has neither — it can only read what's vended.

## First run (one-time)

1. **Publish/pull the images** (`workspace`, `credential-shelf`) — built + pushed to
   `ghcr.io/twin-digital/*` by the opus monorepo publish workflow.
2. **GitHub App key → KMS** (once, if not already done): in the sidecar,
   `import-app-private-key <app-key.pem>` imports it as a non-extractable KMS key; set the
   alias as `kms_key_id` in `creds/vend.yaml`, grant `kms:Sign` to the signer role, shred the `.pem`.
3. **Configure what's vended** — [creds/vend.yaml](./creds/vend.yaml): the `aws-sso`
   provider's start URL + grant(s), and a `github-app` provider per installation. The sidecar
   renders the shared `~/.aws/config` from it on start (no hand-authoring).
4. **SSO login** — log in once (device-code flow; `AWS_SSO_USE_DEVICE_CODE=1` is set):
   ```sh
   docker exec -it <project>-credentials-1 refresh-credentials
   ```
   `refresh-credentials` does the device-code login for every configured session (no profile
   name needed) and vends immediately; within ~60s all loops are serving creds.

## Daily use

- **Re-login** when the Identity Center session lapses (~8h): re-run `refresh-credentials`
  above. One login revives every vend loop (they share the one session).
- **Health**: `cat /creds/status/*` (`ok expires=…` / `stalled …`; mtime is a heartbeat) or
  `docker logs -f <project>-credentials-1`.
- `git push/pull` over HTTPS and `aws`/`gh` "just work" via base's shims; nothing in the
  workspace can mint or widen a credential.

| Credential | Lifetime | Renewal |
|---|---|---|
| GitHub token (`/creds/github/<org>`) | 1h (GitHub-fixed) | auto, <10 min left |
| AWS role creds (`/creds/aws/credentials`) | 1h (permission-set) | auto, <15 min left |
| **Identity Center session** | ~8h (org setting) | **device-code login (the one recurring step)** |
| KMS App key | permanent, non-extractable | — |

## Troubleshooting

| Symptom | Meaning | Fix |
|---|---|---|
| `aws`/`gh`/`git` unauthenticated, `devcred` breadcrumb | shelf creds aged out (vend stalled) | `refresh-credentials` in `credentials` |
| `/creds/status/*` says `stalled since=…` | a vend loop can't reach SSO/KMS | `docker logs <…-credentials-1>`; usually re-login |
| `gh`/`git` wrong-org / "no valid token" | no repo context + `GH_DEFAULT_ORG` unset/not-vended | pass `-R <org>/<repo>` or set `GH_DEFAULT_ORG` to a vended org |
| status mtime >5 min old | the sidecar isn't running | `docker compose up -d` (host, from the workspace project) |
| `/creds` missing | container built without the shelf mount | rebuild the workspace |

## Changing what's vended

Edit [creds/vend.yaml](./creds/vend.yaml) and **rebuild** the `credentials` sidecar — it's
baked into the image (a reviewed rebuild, not a `/workspace` mount).

- **AWS scope**: add/remove grants under the `aws-sso` provider (one per account+role).
- **GitHub orgs/repos**: add a `github-app` provider per installation, with one grant per org
  (`name`, optional `repos`/`perms`). For a new org, install the App on it first and note its
  installation id. Consumers route per-org automatically (`git` by request path, `gh` by
  `-R`/cwd), so it's a config change, not code.

## Rebuilding (keep all services in one compose project)

The `creds-shelf` volume is shared **only within one compose project** (Docker names it
`<project>_creds-shelf`). **Rebuild from VS Code** ("Dev Containers: Rebuild Container"), which
recreates the workspace + sidecar in one project. A bare `docker compose up -d` from the host
outside that project would create an orphaned sidecar on a different volume the workspace can't
read. After a rebuild the `admin-home` volume may be fresh, so re-run `refresh-credentials` once.

## Change discipline

These `.devcontainer` files are on the agent-writable `/workspace` mount; changes take effect
only when a **human rebuilds/recreates** the containers — so review the diff of this directory
before any rebuild. Note `.vscode/settings.json` and `devcontainer.json` can apply on a window
**reload** (a lower bar than rebuild) — review them before *reloading*, not only rebuilding.
