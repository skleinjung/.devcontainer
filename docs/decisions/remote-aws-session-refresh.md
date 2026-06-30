# Remote, low-friction AWS session refresh

**Status:** Accepted. Changes only how the AWS Identity Center session is
*refreshed*; the credential-MINTING path stays AWS-operated, and GitHub-App
vending and downstream delivery (file shelf today,
[broker](../../../opus/nodejs/devcontainer/credential-shelf/docs/CREDENTIAL-BROKER.md)
later) are unchanged.

## Context

The credential-shelf sidecar vends AWS + GitHub credentials. GitHub vends
autonomously via a KMS-backed App identity (`kms:Sign`, non-extractable). **AWS**
rides a human IAM Identity Center SSO session (~8h) refreshed by `docker exec` +
device-code login on the host.

Two real pains:

1. **Cumbersome** — a device-code login roughly daily.
2. **Host-only** — it can't be done remotely, so when away from the terminal you
   cannot revive vending, which blocks driving agents while away.

We want refresh to be **less frequent** and **remotely triggerable**, *without*
taking on a bespoke, self-operated credential-minting service.

## Decision

Two independent levers, both keeping AWS as the credential minter:

1. **Extend the Identity Center session to 7 days** (org setting). The SSO OIDC
   refresh token keeps the access token alive within the window, so the sidecar
   auto-refreshes role creds (and GitHub) unattended between logins. Daily
   device-code → roughly weekly.
2. **Remote-trigger the refresh.** A small **authenticated** endpoint, reachable
   only over the existing Tailscale tailnet, runs `refresh-credentials` in the
   sidecar and surfaces the device-code verification URL + code to the operator's
   phone (push/link). One tap to start, approve in the browser (IdP + MFA), done
   — from anywhere on the tailnet.

The minting path is untouched: approval still happens through **AWS Identity
Center with MFA**. We change only *cadence* and *trigger ergonomics*.

## Why this, and not a presence-gated minting service

The motivating goals were **usability** (less-frequent, one-tap refresh) and
**remote control of agents when away from the terminal**. Both are satisfied by
cadence + trigger changes alone. Two more ambitious designs were explored in
depth and discarded — see Alternatives. The short version: they replace
AWS-operated minting with a **self-operated, security-critical minting service**,
and the security property that would justify that cost ("a stolen sidecar bearer
self-expires") turned out to be **roughly equal to plain SSO** under scrutiny.
So they buy the same usability win this decision buys, at far higher operational
cost and lower robustness.

## Consequences / accepted trades

- **Dead-man's-switch window loosens from ~8h to 7 days.** With the human absent,
  vending now survives up to the session length. This is an accepted trade for
  usability — and it's **tunable**: because the remote trigger makes re-login
  cheap and remote, the session can be dialed *shorter* later for a tighter
  dead-man's switch without reintroducing the original friction. (Session length
  is the knob; the trigger decouples it from re-login cost.)
- **The trigger endpoint is new, small attack surface.** It can *initiate* a
  device-code login and surface the URL — it **cannot complete** one (that needs
  the human's IdP auth + MFA in the browser). So a compromised/abused endpoint is
  at most a login-prompt DoS, **not** a path to mint credentials. Mitigations:
  tailnet-only reachability, an auth token (or passkey), rate-limiting, and the
  verification URL delivered only to the authenticated operator (don't broadcast
  it).
- **The refresh token lives longer in `admin-home`** (host-compromise reuse
  window ~8h → ~7 days). Same location and class of secret as today, just
  longer-lived; bounded by the (tunable) session length and revocable in Identity
  Center.
- **No new self-operated minting TCB, no CA, no Lambda, no DynamoDB, no WebAuthn
  implementation, no cert-delivery channel.** Robustness is essentially today's
  (AWS-managed minting) plus one small endpoint whose failure degrades gracefully
  to the existing host-exec login.

## Alternatives considered

### A. Soft in-sidecar lease
A timestamp the operator refreshes; the vend loop refuses to mint when stale.
**Rejected:** the capability secret sits on the sidecar, so exfiltrating it
bypasses the check. Defends liveness, not exfiltration.

### B. Presence-gated two-Lambda lease + tailnet binding
Lambda A (passkey/WebAuthn-gated) writes a lease to DynamoDB; Lambda B, called
hourly by the sidecar, mints `developer-ai-agent` STS creds while the lease is
fresh. To avoid a standing AWS secret on the sidecar, the issuer was reached only
over the tailnet with the sidecar authenticated by tailnet identity.
**Discarded** after review surfaced: Tailscale ACLs filter L3/L4 and can't
path-segment one API Gateway (so "only the sidecar reaches `issue`" wasn't
enforceable as drawn); "tailnet membership = authorization" makes a single
fail-open ACL document the entire boundary; the **Tailscale control plane enters
the TCB as a root ~equal to AWS** (anyone who can add+tag a node gets the role);
an **always-on relay** (~$7–10/mo) becomes a new hot-path SPOF; and the residual
node key is portable to a volume-thief and reactivates on every tap. Large
self-operated TCB + cost for no security gain over SSO.

### C. IAM Roles Anywhere (KMS-CA issuer + passkey + fixed leaf cert)
The most promising alternative; explored across four review passes. A
non-extractable KMS key signs short-lived (8h) leaf certs on a passkey tap; the
sidecar uses `aws_signing_helper` with the leaf cert to self-service ≤1h STS
hourly from the public RA endpoint. No relay, no tailnet, reuses the GitHub-App
KMS-signer pattern. Its headline appeal was a **self-expiring bearer**. Review
dissolved that edge:

- **The dead-man bound is issuer-CODE-enforced, not AWS-enforced.** AWS enforces
  the `NotAfter` of an *honest* cert, but the issuer Lambda *chooses* it; nothing
  in RA caps leaf validity, so a compromised issuer mints a 10-year cert — the
  same honest-code dependency as B's lease check.
- **"Self-expiring" holds only under conditions that are expensive to guarantee.**
  It requires *enforced cert non-publication* (hard-deny the vended role
  `rolesanywhere:GetSubject`/`ListSubjects`, CloudTrail cert data, and the issuer
  log group — else a departed key-thief pivots `stolen key → CreateSession →
  developer-ai-agent → read the next fresh cert → repeat forever`) **and** a
  cert-delivery channel a departed thief can't pull from — which, to be airtight
  against a thief who copied the sidecar's full state, needs a **memory-only key +
  a passkey tap on every sidecar restart**.
- **The WebAuthn implementation is confidentiality-critical**, not just an
  availability gate: a pre-auth bypass lets a key-thief mint fresh certs for the
  stolen key — a full dead-man's-switch bypass.

Net: the self-expiry property is **≈ equal to SSO** (both ultimately bounded by
`max_age` + detect-and-revoke), while RA moves the *entire* credential-minting
path into self-operated, security-critical code (CA, issuer, RA trust config,
WebAuthn, non-publication IAM denies, cert delivery, an auto-revoke pipeline as a
*gating* dependency) with multiple new SPOFs. A large bespoke build and ongoing
operational burden whose only real benefit over this decision — remote one-tap —
is captured here far more cheaply.

**RA remains defensible** if the credential-shelf is built as a **reusable
product** (the opus toolkit, where the complexity amortizes across many
consumers) or if a hard **no-IdP / no-device-code** requirement emerges. Neither
applies to the current single-sidecar homelab need. The full RA exploration,
including the hardened invariant set, is preserved in this repo's git history.

## Implementation shape

- **Identity Center:** set the session duration to 7 days (console / IaC).
- **Remote-trigger service:** a small Node.js service (per the repo's Node-first
  preference), tailnet-fronted (`tailscale serve`), authenticated (token or
  passkey) + rate-limited. On request it runs the sidecar's existing
  `refresh-credentials` and returns/pushes the device-code verification URL + code
  to the operator only. Lives alongside the sidecar (compose service or the opus
  toolkit); it holds **no** AWS minting capability — it only kicks off the
  human-completed device-code flow.
- **Docs:** update `README`/`SECURITY` (the daily-use refresh step and the
  trigger's trust boundary).

## Open follow-ups

- Decide where the trigger service lives (a `.devcontainer` compose service vs.
  the opus `credential-shelf` toolkit) and its exact auth (shared token vs.
  passkey) — an implementation detail, not a design fork.
- If a tighter dead-man's switch is wanted later, shorten the session duration;
  the remote trigger keeps that low-friction.
