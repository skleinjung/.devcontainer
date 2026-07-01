# Remote, low-friction AWS session refresh

**Status:** Accepted. Adds a way to refresh the AWS Identity Center session
*remotely*; the credential-minting path stays AWS-operated, the **session length
is unchanged**, and GitHub-App vending + downstream delivery (file shelf today,
[broker](https://github.com/twin-digital/opus/blob/main/nodejs/devcontainer/credential-shelf/docs/CREDENTIAL-BROKER.md)
later) are unchanged.

## Context

The credential-shelf sidecar vends AWS + GitHub credentials. GitHub vends
autonomously via a KMS-backed App identity (`kms:Sign`, non-extractable),
**independent of the SSO session**. **AWS** rides a human IAM Identity Center SSO
session (~8h) refreshed by `docker exec` + device-code login on the host.

Two real pains:

1. **Cumbersome** — a device-code login roughly daily, done by `docker exec` on
   the host.
2. **Host-only** — it can't be done remotely, so when away from the terminal you
   cannot revive AWS vending, which blocks driving agents while away.

## Decision

Add a small **remote-trigger** for the existing device-code refresh, and **leave
the session length unchanged (~8h)**. The trigger removes the friction, so there
is no need to lengthen the session — we keep the tighter dead-man window and the
shorter refresh-token lifetime. AWS Identity Center + MFA stays the minter; only
*trigger ergonomics* change.

- **Reachability: local network only.** The trigger binds to the home LAN — **not
  public, not joined to any tailnet.** The operator's devices reach it directly on
  the home network, or routed in via the home router (which is on the operator's
  tailnet). No Tailscale in the compose project.
- **A separate, minimal container** — **no `admin-home` mount, no Docker socket,
  no AWS credentials**, not colocated with the SSO session / `kms:Sign`, and no
  ability to `docker exec`.
- **A new, narrow single-purpose primitive — *not* the existing
  `refresh-credentials`** (which logs in *every* configured session and vends
  immediately). The sidecar exposes exactly one handler: *start a device
  authorization, return the `user_code` + `verification_uri`, then background-poll
  and vend only on operator approval.* It takes **no caller-supplied arguments**
  (no `start_url` / session selection that could redirect the flow) and cannot be
  coerced into minting, exfiltrating, or running commands — preserving the tier-3
  "sidecar is vend-only, no shells" invariant (one inbound primitive, not a shell).
- Auth token (v1; passkey later) + **rate-limiting** (repeated triggers can hit
  AWS device-authorization limits and *block* the legitimate refresh) +
  **audit-log** every trigger; the `user_code` goes only to the authenticated
  operator.

Because compromising the trigger yields only "ask the sidecar to start a login
prompt," its worst case is a **login-prompt DoS, not minting** — *by
construction*, given the isolation above.

### Device-code approval stays operator-initiated

The device authorization grant doesn't bind *who approves* to *who initiated*.
What helps: approval is **not pushed to the operator's browser** — they only ever
enter a `user_code` they were handed. What remains an **accepted residual**: an
attacker can independently start a device-code flow and *phish* a `user_code` to
the operator, so "**only approve a code you just initiated**" is genuinely
load-bearing operator discipline. The trigger surfaces the `user_code` so the
operator matches it against the AWS approval screen; unsolicited prompts are
refused.

## Consequences

- **No session-length change** → the dead-man window and the (bearer,
  off-host-replayable) refresh-token lifetime **stay at the status-quo ~8h**. This
  decision loosens nothing; an earlier idea of extending the session to 24h was
  dropped — with frictionless remote refresh, the tighter window is free.
- **A new network-facing container** in the compose project. SECURITY.md today
  records the shape as "two containers, not three"; this adds a third, always-
  reachable (on the LAN) service, isolated as above and added + reviewed under the
  same rebuild discipline. That topology note updates at implementation.
- **Trigger blast radius = DoS**, per the trust placement.
- **No new minting TCB, no Tailscale / control-plane dependency, no CA / Lambda /
  DynamoDB / WebAuthn / cert-delivery.** Robustness is essentially today's
  (AWS-managed minting) plus one small, LAN-local, isolated endpoint whose failure
  degrades gracefully to the existing host-exec login.

## What this protects — and does not

The trigger gates the **sidecar** refresh (the already-trusted tier). It does
**not** gate the consumer: untrusted code in the workspace reads fresh ≤1h creds
off the `:ro` shelf every hour whether or not a human is present. Reducing that
consumer-side exposure is the separate, deferred soft-lease enhancement
(Alternative A).

## Alternatives considered

### A. Soft in-sidecar lease — *deferred (future enhancement), not rejected*
A timestamp the operator/workspace refreshes; the vend loop refuses to mint when
stale. As a *capability* gate it's weak — the SSO session still sits on the
sidecar, so a sidecar/host exfil bypasses it (defends liveness, not
exfiltration). **But** it gates the **consumer** side — mint to `/creds` **only
during active work** (purge when idle), shrinking the low-trust workspace's
standing-credential exposure without touching the capability. Worth keeping;
deferred as a future enhancement. Tracked: skleinjung/.devcontainer#14.

### B. Presence-gated two-Lambda lease + tailnet binding
Lambda A (passkey-gated) writes a lease to DynamoDB; Lambda B mints
`developer-ai-agent` STS creds hourly while the lease is fresh; the issuer reached
only over the tailnet, sidecar authenticated by tailnet identity. **Discarded**
after review: Tailscale ACLs filter L3/L4 and can't path-segment one API Gateway;
"tailnet membership = authorization" makes a single fail-open ACL document the
entire boundary; the **Tailscale control plane enters the TCB** as a root ~equal
to AWS; an **always-on relay** (~$7–10/mo) becomes a new hot-path SPOF; the
residual node key is portable and reactivates on every tap.

*Contrast with the chosen design:* B pulls the Tailscale **control plane into the
TCB** and makes tailnet-ACL correctness the **mint** authorization; the chosen
trigger uses **no tailnet at all** (local-network-only), and a reachability slip
there is a **DoS, not a mint**.

### C. IAM Roles Anywhere (KMS-CA issuer + passkey + fixed leaf cert)
Explored across four review passes. A non-extractable KMS key signs short-lived
leaf certs on a passkey tap; the sidecar self-services ≤1h STS hourly from the
public RA endpoint — no relay, no tailnet, reusing the GitHub-App KMS-signer. Its
headline **self-expiring bearer** dissolved under review: the dead-man bound is
**issuer-CODE-enforced** (nothing in RA caps leaf validity); "self-expiring" holds
only under enforced cert non-publication **and** a delivery channel a departed
thief can't pull from (needing a memory-only key + a passkey tap on *every*
restart); a pre-auth WebAuthn bypass is a full dead-man bypass. Net: self-expiry
**≈ equal to SSO**, while RA moves the whole minting path into self-operated,
security-critical code with multiple new SPOFs. **Discarded on that far larger
security surface and its SPOFs**, not on build cost (the trigger *does* land in
the opus toolkit, so amortization doesn't distinguish them). Defensible only under
a hard **no-IdP / no-device-code** requirement, which does not apply. Full RA
exploration is preserved in git history.

## Implementation tracking

- twin-digital/opus#196 — the remote-trigger service (opus `credential-shelf`):
  the new narrow purpose-built handler + trust placement + operator-initiated
  device-code + audit/rate-limit; **local-network** reachability.
- skleinjung/.devcontainer#13 — wire the trigger into this devcontainer (LAN-local
  bind, auth, isolation) + docs.
- skleinjung/.devcontainer#14 — *deferred* soft consumer-side minting gate
  (Alternative A).
- skleinjung/.devcontainer#12 — **closed**: no session-duration change (the
  session stays ~8h; the trigger removes the friction that would have motivated
  lengthening it).

## Open follow-ups

- Trigger-service auth: shared token (v1) vs passkey — settled in the opus PR
  (#196), an implementation detail, not a design fork.
