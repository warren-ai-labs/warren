# RFC 0009: Own Relay and Public Tunnel

- Status: Draft
- Owner: RelayService, Headless, Desktop, Web
- Created: 2026-08-29
- Scope: relay (private) and tunnel (public) split, weak-net downgrade, P2P
- Supersedes: gnar as default public-access path

## Summary

Warren Relay and public tunnel are two capabilities that share one long-lived host connection but remain independently switchable.

```text
Host (warren-headless) ──WSS /v1/host/connect + /v1/tunnel/connect──► Relay Edge
                                ▲ multiplex BRLY frames
                                │
Client (Web/Desktop) ──WSS /v1/client/connect─────────────────────────┘
Public Internet ──HTTPS :443──► Edge HTTP proxy ──┘ (tunnel Kind)
```

* Relay = private direct reachability for the owner's devices behind NAT. Host makes one outbound WSS, clients pair via one-time code to obtain `HMAC(generation)` token. No public URL is published.
* Tunnel = optional public exposure. Same host connection forwards public `HTTP/Upgrade` to `127.0.0.1:8789` when `tunnelEnabled=1`. No `gnar` binary required.
* Both kinds multiplex on one `hostTunnel` (`BRLY` `headerSize=22`). Weak network degrades `terminal` frames first, keeps `agent` events.

## Motivation

`gnar` for public-access imposes `edge URL + account + enrollment/invite key + bundled binary + ~/.warren/gnar` credential store (`Headless/cmd/warren-headless/main.go:88`). Self-hosting the private relay should be `ADMIN_TOKEN + SIGNING_KEY + PUBLIC_URL`. Coupling them forces every relay user to understand the public tunnel. Cloudflare non-443 forwarding adds >1s latency that makes interactive terminal unusable. Weak networks need graceful downgrade.

## Design

### 1. Transport

One `hostTunnel` per Host (`RelayService/internal/controlplane/tunnel.go:13`). `connection *websocket.Conn`, `writes sync.Mutex`, `clients map[connectionID]*clientRoute (128 buffered)`, `heartbeat 30s +/- jitter`, `ReadDeadline 120s`, `WriteDeadline 15s`. `RelayService/internal/controlplane/protocol.go:8` `BRLY|ver1|kind|connectionID[16]|payload` with `kind: 0x01 open, 0x02 close, 0x03 text, 0x04 binary, 0x05 http`. Control and tunnel virtual connections share the map, distinguished by `Kind`. Server `connectHost: server.go:122` and `connectTunnel` reuse `registry.connectHost` generation check under lock to prevent stale credential publish (`registry.go:156`).

### 2. Relay (private)

* Provision: `POST /v1/hosts` admin only → `randomToken(32)` → `sha256` stored, `Generation++`.
* Pair: `POST /v1/hosts/{id}/pairing` (admin or host credential, host must be `online`) → `randomToken(9)` 10m one-time. `POST /v1/pair` → `auth.go:41 signer.issue(hostID, "control", generation, 30d)` → `web_url /h/{id}/#t=`. Revoke `DELETE /v1/hosts/{id}` bumps generation, closes tunnel, invalidates tokens.
* Client connect: `GET /v1/client/connect?host_id=` checks `AllowedOrigin`, first frame must be `{t:"auth",token}` within 10s, `authorizedTunnel(generation)` lookup, `openClient` sends `frameOpen`, then bidirectional relay. `maxRelayMessageBytes 8MiB`. `registry.json` atomic `0600` persists only `CredentialHash/Generation`.

Host connector (`Headless/internal/relay`) dials `wss://relay.example.com/v1/host/connect?host_id=&name=` with `Authorization: Bearer host_credential`, exponential backoff `1s..30s + jitter`, `Pong` → `touchHost`.

### 3. Tunnel (public)

* Edge `GET /v1/tunnel/connect` reuses host credential + generation, no pairing.
* Edge `:443` terminates TLS, proxies `Host: <public>` to `127.0.0.1:8789` via `frameHttp` on same `hostTunnel`. Lifecycle bound to `settings.json tunnelEnabled`, restored on daemon restart, stopped on `POST /v1/public-access/disable`. No `gnar` process.
* Backward compat: existing `gnar` adapter remains under `Headless/internal/tunnel` gated by `WARREN_GNAR_PATH`, but relay tests never require it.

### 4. Weak-net downgrade

* Signals: `RTT>800ms` or `route.frames` full or `loss>2%`.
* Policy: pause `frameBinary` (terminal `DENB`) forwarding, keep `frameText` `agent` events (`agent.status` 256KiB batches). Client shows `Weak network — agents only`. `Resize/input` still allowed. Recovery is automatic when RTT recovers.

### 5. P2P (follow-up)

Relay stays as signaling + `STUN`. Host and client attempt `QUIC/WebRTC` hole punch using the paired `generation` as auth. Success → direct; fail within 10s → fallback to `hostTunnel`. No protocol change, only new `Kind=p2p-offer`.

### 6. User interaction

* Self-host: `docker run --read-only -v warren-relay-data:/data -e WARREN_RELAY_ADMIN_TOKEN -e WARREN_RELAY_SIGNING_KEY -e WARREN_RELAY_PUBLIC_URL=https://relay.example.com warren-relay` (preserved `RelayService/Dockerfile:12`). Or `mise relay:dev` auto-generates secrets in `.build/relay-dev/8080` `0600`.
* Connect: `warren relay connect --url https://relay.example.com` (stores `host_id` in Keychain), `warren relay pair` prints `https://relay.example.com/h/<uuid>/#t=` + QR. `WARREN_RELAY_NO_OPEN=1` suppresses `open`.
* Public: `warren relay up --public` starts both; `warren public enable/disable` toggles only tunnel. Daily `warren relay status`.
* Latency: relay must be `443` `WSS`; non-443 Cloudflare forwarding is not supported for interactive use.

## Security

* Admin token never leaves server/host setup; host credential shown once, stored as hash.
* Pairing codes one-time, 72-bit, 10m TTL (`registry.go:201`).
* Access tokens `HMAC-SHA256` bound to `hostID+scope+generation`, verified on every `connectClient: server.go:273` and `connectTunnel`.
* Origin strictly checked for browsers, host connector bypasses (`server_test.go:292`).
* No credential in query string; fragment + first `auth` frame only.
* `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`, `0600` persistence.

## Alternatives

* Keep `gnar` only: retains external binary and edge/account UX.
* Dual host connections (one for relay, one for tunnel): doubles TLS/handshakes; rejected in favor of single multiplex.

## Migration

* Existing `warren-headless` without relay connector continues via `Warren.app` forwarding (no break).
* New `Headless` with connector auto-migrates on `warren relay connect`.
* `gnar` public-access remains functional; no data migration.
