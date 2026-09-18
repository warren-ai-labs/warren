# Warren deferred work

One place for work we consciously did **not** do: low-priority cleanups, changes
waiting on a policy decision, and items whose trigger has not fired yet. This is
not a wishlist or a roadmap — every entry says why it can wait and what would
force it, so nobody has to re-derive that reasoning later.

## How to use this file

- One entry per item, in no particular order. Keep an open entry as it is;
  delete it once the work lands (git history keeps the reasoning) and mention
  the entry in the commit message.
- Every entry answers: **what**, **why it can wait**, **the trigger** that makes
  it urgent, **cost**, and where the code lives.
- Link RFCs, decision records, or runbooks instead of restating them.
- When the code is non-obvious, cross-reference this file from the code point.
  Do not leave bare `TODO` comments.

## 1. Relay session bookkeeping has no expiry sweep

**What.** `refreshTokens`, `usedRefresh`, and `revokedFamilies` in
`RelayService/internal/controlplane` are deleted only when a capability is used
or a device/Host is revoked. Nothing is deleted on expiry, and
`persistSessions` rewrites the whole `<WARREN_RELAY_DATA>.sessions` file on every
refresh (`server.go:1045`).

**Why it can wait.** Growth is bounded by `AccessTTL` (15m by default): a client
refreshes at most once per access-token lifetime, so ≤96 `usedRefresh` entries
per device per day, about 72 bytes each. Modeled, not measured:

| Scale | `usedRefresh` entries/year | `.sessions` growth/year |
| --- | --- | --- |
| One busy phone (~40 refreshes/day) | ~15k | ~1.1 MB |
| Three devices (~60/day) | ~22k | ~1.6 MB |
| Ten-person team (~300/day) | ~110k | ~8 MB |

Nothing here is a bottleneck at self-hosted scale.

**Why a sweep is not a standalone fix.** `RefreshTTL` defaults to 0 — refresh
capabilities never expire — and `loadSessions` explicitly clears `Expires` in
that case (`server.go:1030`). So there is nothing to prune: a consumed
capability must be remembered for as long as it could still be presented, or
replay detection and device revocation can be bypassed. Bounding these maps
requires bounding the credential lifetime first, which is a policy decision.

**Trigger.** Either we decide refresh capabilities should expire (which is also
the answer to "a leaked refresh token is a permanent credential"), or a
deployment's `.sessions` file reaches a size where the full-file rewrite starts
to matter.

**Cost.** ~1.5 h including tests. The three parts must land together: a
`WARREN_RELAY_REFRESH_TTL` setting (default 0 keeps today's behaviour),
timestamps on the used/revoked entries, and sweeps at load plus opportunistically
on refresh (prune beyond `TTL + grace`). Tests must pin that a replayed
capability is still rejected after a sweep, and that `TTL = 0` behaves exactly as
today. Client-visible consequence: a device idle past the window has to pair
again.

## 2. One Relay path grammar, three implementations

**What.** The host-scoped route shape `/h/{hostID}/v1/...` and the optional
`/invite/{invite}` scope are built independently in the Relay server routing
(`RelayService/internal/controlplane`), the native client
(`WarrenRemoteModels.swift`, `relayPath`), and the web runtime
(`Web/src/runtime.js`, `relayPath`/`relayScopePath`).

**Why it can wait.** The three agree today and each one has tests.

**Trigger.** The next time a route shape changes, or a client needs a scope the
other two do not know about.

**Cost.** Needs an RFC before code: three runtimes cannot share an
implementation, so the deliverable is one written grammar plus a conformance
test in each language.
