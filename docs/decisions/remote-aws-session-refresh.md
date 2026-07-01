# Remote, low-friction AWS session refresh

**Status:** Accepted. Changes only how the AWS Identity Center session is
*refreshed*; the credential-minting path stays AWS-operated, and GitHub-App
vending and downstream delivery (file shelf today,
[broker](https://github.com/twin-digital/opus/blob/main/nodejs/devcontainer/credential-shelf/docs/CREDENTIAL-BROKER.md)
later) are unchanged.

## Context

The credential-shelf sidecar vends AWS + GitHub credentials. GitHub vends
autonomously via a KMS-backed App identity (`kms:Sign`, non-extractable),
**independent of the SSO session**. **AWS** rides a human IAM Identity Center SSO
session (~8h) refreshed by `docker exec` + device-code login on the host.

Two real pains:

1. **Cumbersome** — a device-code login roughly daily.
2. **Host-only** — it can't be done remotely, so when away from the terminal you
   cannot revive AWS vending, which blocks driving agents while away.

We want refresh to be **remotely triggerable** and **modestly less frequent**,
*without* taking on a bespoke, self-operated credential-minting service.

## Decision

Two independent levers, both keeping AWS as the credential minter:

1. **Extend the Identity Center sign-in session to 24 hours.** This is the
   **access-portal / sign-in session** duration (a per-instance setting), *not*
   the ≤12h permission-set `session_duration`. 24h is a deliberately
   **conservative** value: the remote trigger (lever 2) already solves
   *remoteness*, so we only need a modest cadence bump, not the 7-day ceiling —
   keeping the dead-man window and the refresh-token lifetime short.
2. **Remote-trigger the refresh.** A small **authenticated** endpoint, reachable
   only over the existing Tailscale tailnet, causes the sidecar to run
   `refresh-credentials` and surfaces the device-code verification URL + **user
   code** to the operator, who approves in the browser (IdP + MFA). One
   *operator-initiated* tap, from anywhere on the tailnet.

The minting path is untouched: approval still happens through **AWS Identity
Center with MFA**. We change only *cadence* and *trigger ergonomics*.

### How lever 1 is applied (and a caveat that gates its value)

- **Console-only; not IaC.** The sign-in session duration must be set in the IAM
  Identity Center **console** — the AWS Terraform provider exposes only the ≤12h
  permission-set `session_duration`, so there is no resource for this knob. Even
  `twin-digital/aws` (which *does* manage this instance's permission sets in
  Terraform) can't codify it; #12 is a manual console step against instance
  `d-9067c161a5` / account `084828575849`.
- **⚠️ The extension may be a no-op — verify.** `aws sso login` has historically
  capped the SSO session at ~8h *regardless* of the configured sign-in duration,
  unless the CLI's **refresh-token** flow is active (recent AWS CLI v2). So 24h
  only takes effect if the sidecar's CLI honors it via refresh tokens; otherwise
  it silently stays ~8h. **The reliable win is lever 2** (works regardless); lever
  1 is a bonus contingent on this — confirm the sidecar's session actually reaches
  24h before relying on it.

## Consequences / accepted trades

- **Dead-man's-switch window loosens from ~8h to ~24h** (if lever 1 takes
  effect). With the human absent, vending survives up to the session length. A
  modest, deliberately-bounded trade; still **tunable** — the trigger decouples
  session length from re-login cost, so it can be shortened further at will.
- **The refresh token lives ~24h in `admin-home`.** Honest framing: the SSO OIDC
  refresh token is a **bearer** credential, **not device-bound**, so a copy
  exfiltrated from `admin-home` (a host/volume compromise) is **replayable
  off-host** — continuously minting fresh ≤1h role creds — for the session window,
  until the human notices and revokes in Identity Center. 24h (vs 7d) keeps that
  window small. MFA re-prompt cadence loosens only from ~8h to ~24h.
- **The trigger endpoint's blast radius is bounded to a login prompt — by
  construction, not by assertion.** See the isolation requirement below; the
  claim only holds if it's met.
- **No new self-operated minting TCB, no CA, no Lambda, no DynamoDB, no WebAuthn
  implementation, no cert-delivery channel.** Robustness is essentially today's
  (AWS-managed minting) plus one small endpoint whose failure degrades gracefully
  to the existing host-exec login.

## The trigger service — trust placement (REQUIRED)

The "can *initiate* but not *complete* a login, so worst case is a login-prompt
DoS, not minting" property depends entirely on **where the network-facing part
runs and what it can reach**. Required:

- The **network-facing trigger is a separate, minimal container** — **no
  `admin-home` mount, no Docker socket, no AWS credentials.** It must not be
  colocated with the SSO session / `kms:Sign`, and must not be able to `docker
  exec` (host-root-equivalent).
- It reaches the sidecar over a **narrow, single-purpose IPC**: the sidecar
  exposes exactly one primitive — "initiate a device-code refresh, return the
  verification URL + user code." The sidecar's handler **cannot** be coerced into
  minting, exfiltrating, or running arbitrary commands. This keeps the tier-3
  "sidecar is vend-only, no shells" invariant intact (one narrow inbound
  primitive, not a shell).
- Compromising the trigger therefore yields only "ask the sidecar to pop a login
  prompt" — a DoS, as claimed.

Additional trigger requirements: tailnet-only reachability + auth token (or
passkey) + **rate-limiting** (repeated triggers can hit AWS device-authorization
rate limits and *block the legitimate refresh* — an availability harm, not just
prompt spam); **audit-log** every trigger (who/when — it pops MFA prompts and
conditions human approvals); deliver the verification URL **only to the
authenticated operator**.

### Device-code approval must stay operator-initiated

The device authorization grant does **not** cryptographically bind *who approves*
to *who initiated*. So the flow must not train the operator to reflexively approve
pushed prompts (that would violate the shelf's "never approve a touch/prompt you
didn't initiate" discipline). Requirements: the trigger **surfaces the `user
code`** so the operator **matches it** against the AWS approval screen; the
operator approves **only a refresh they just initiated**; an unsolicited prompt
(one they didn't trigger) is **refused**, not approved.

## What this protects — and does not

Presence/refresh gates the **sidecar** (the already-trusted tier). It does **not**
gate the consumer: untrusted code in the workspace reads fresh ≤1h creds off the
`:ro` shelf every hour whether or not a human is present. Reducing that
consumer-side exposure is the separate, deferred soft-lease enhancement
(Alternative A).

## Alternatives considered

### A. Soft in-sidecar lease — *deferred (future enhancement), not rejected*
A timestamp the operator/workspace refreshes; the vend loop refuses to mint when
stale. As a *capability* gate it's weak — the SSO session still sits on the
sidecar, so a sidecar/host exfil bypasses it (defends liveness, not
exfiltration). **But** it has a distinct benefit the presence-gated designs
lacked: it gates the **consumer** side — mint to `/creds` **only during active
work** (purge when idle), shrinking the low-trust workspace's standing-credential
exposure without touching the capability. Worth keeping; deferred as a future
enhancement layered on this decision. Tracked: skleinjung/.devcontainer#14.

### B. Presence-gated two-Lambda lease + tailnet binding
Lambda A (passkey/WebAuthn-gated) writes a lease to DynamoDB; Lambda B, called
hourly by the sidecar, mints `developer-ai-agent` STS creds while the lease is
fresh; the issuer was reached only over the tailnet with the sidecar
authenticated by tailnet identity. **Discarded** after review: Tailscale ACLs
filter L3/L4 and can't path-segment one API Gateway; "tailnet membership =
authorization" makes a single fail-open ACL document the entire boundary; the
**Tailscale control plane enters the TCB** as a root ~equal to AWS; an **always-on
relay** (~$7–10/mo) becomes a new hot-path SPOF; the residual node key is portable
and reactivates on every tap. Large self-operated TCB + cost, no security gain
over SSO.

### C. IAM Roles Anywhere (KMS-CA issuer + passkey + fixed leaf cert)
The most promising alternative; explored across four review passes. A
non-extractable KMS key signs short-lived (8h) leaf certs on a passkey tap; the
sidecar uses `aws_signing_helper` to self-service ≤1h STS hourly from the public
RA endpoint — no relay, no tailnet, reusing the GitHub-App KMS-signer pattern. Its
headline appeal was a **self-expiring bearer**, which review dissolved:

- The dead-man bound is **issuer-CODE-enforced**, not AWS-enforced — the issuer
  chooses `NotAfter`; nothing in RA caps leaf validity.
- "Self-expiring" holds only under **enforced cert non-publication** (deny the
  vended role `rolesanywhere:GetSubject` etc.) **and** a cert-delivery channel a
  departed thief can't pull from — which, to be airtight against a full-state
  thief, needs a memory-only key + a passkey tap on **every sidecar restart**.
- A pre-auth WebAuthn bypass is a **full dead-man bypass** for a key-thief, making
  the WebAuthn impl confidentiality-critical.

Net: the self-expiry property is **≈ equal to SSO** (both ultimately bounded by
`max_age` + detect-and-revoke), while RA moves the *entire* minting path into
self-operated, security-critical code (CA, issuer, RA config, WebAuthn,
non-publication IAM denies, cert delivery, an auto-revoke pipeline as a *gating*
dependency) with multiple new SPOFs. **Discarded primarily on that far larger
security-critical surface and its new SPOFs**, and on the ≈-SSO self-expiry
finding — *not* on build cost alone (the trigger service does land in the opus
toolkit, so the amortization argument doesn't distinguish them). RA stays
defensible only under a hard **no-IdP / no-device-code** requirement, which does
not apply here. Full RA exploration, including the hardened invariant set, is
preserved in git history.

## Implementation tracking

- twin-digital/opus#196 — the remote-trigger service (opus `credential-shelf`),
  built to the trust-placement + device-code requirements above.
- skleinjung/.devcontainer#12 — set the Identity Center **sign-in session to
  24h** (console step against `d-9067c161a5` / `084828575849`; verify it takes
  effect vs. the CLI ~8h cap).
- skleinjung/.devcontainer#13 — wire the trigger into this devcontainer + docs.
- skleinjung/.devcontainer#14 — *deferred* soft consumer-side minting gate
  (Alternative A).

## Open follow-ups

- Trigger-service auth: shared token (v1) vs passkey — settled in the opus PR
  (#196), an implementation detail, not a design fork.
- Confirm lever 1 actually extends the sidecar's session to 24h (CLI refresh-token
  behavior); if it doesn't, drop lever 1 and rely on lever 2 alone.
- Session length stays tunable — shorten further if a tighter dead-man's switch is
  wanted; the remote trigger keeps that low-friction.
