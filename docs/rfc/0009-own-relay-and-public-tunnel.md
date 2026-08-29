# RFC 0009: Owned Relay and Public Tunnel

- Status: Proposed
- Owner: RelayService, Headless, Desktop, Web, CLI
- Created: 2026-08-29
- Scope: self-hosted Relay, one Host connection, public HTTP/Upgrade tunnel,
  unified credentials, and a P2P follow-up
- Supersedes: `gnar` as the default public-access path

## Decision summary

This RFC defines the first owned Relay design. The decisions below are
normative for an implementation of this RFC:

1. A Host opens exactly one outbound WSS connection to Relay. Private client
   control and public HTTP/Upgrade traffic are virtual streams on that
   connection. There is no second `/v1/tunnel/connect` Host socket.
2. Headless and Relay share one logical Host identity and one canonical Host
   Secret. Relay does not mint a second long-lived Host credential. Remote
   clients receive short-lived, scoped Relay capabilities derived from that
   identity; the Host Secret is never sent to a browser.
3. Every public endpoint has an explicit Host route, a route policy, and a
   generation. A public URL is not a control-plane credential. Control APIs
   remain authenticated even when an application route is public.
4. HTTP requests, streaming responses, and WebSocket `Upgrade` are explicit
   versioned stream messages. The Relay never invents a second local listener
   or assumes that Headless is on `127.0.0.1:8789`.
5. P2P is a later optimization. It uses temporary signed session tickets and
   an authenticated ICE/DTLS or QUIC handshake, then falls back to Relay.
   Generation numbers alone are not credentials.
6. Weak-network frame dropping or downgrading is not part of this delivery.
   It is a separate P2 follow-up; terminal and Agent data retain their current
   semantics until that work is designed and measured.

## Current constraints

The current repository provides useful pieces but not the complete design:

- Relay exposes `/v1/host/connect` and `/v1/client/connect`; its registry keeps
  one live tunnel per Host and fences stale connections with a generation.
- BRLY v1 has `open`, `close`, `text`, and `binary` kinds only. WebSocket
  message boundaries provide the current payload length; there is no HTTP
  stream, flow-control, or Upgrade contract.
- Headless authenticates `/v1/ws` with the daemon token in `~/.warren/token`.
  It has no Relay connector or Relay-capability verifier yet.
- The Headless listen address and port are configurable through
  `WARREN_LISTEN`; `8789` is only the default.
- The existing `Headless/internal/tunnel` package and `gnar` lifecycle remain
  valid compatibility paths during migration.

The RFC describes the target protocol and integration. It does not claim that
the current implementation already supports these endpoints or frames.

## Goals

- Let an operator run Relay as a small, independently deployable service.
- Keep Warren resources, PTYs, transcripts, and terminal state on the Host.
- Carry private control and public application traffic over one authenticated
  Host connection.
- Route each public request to exactly one enabled Host without an arbitrary
  proxy target.
- Preserve streaming, backpressure, close, timeout, and HTTP Upgrade
  semantics.
- Make local daemon authentication and Relay enrollment one credential model,
  with scoped delegation rather than duplicated long-lived secrets.
- Support Web, Desktop, CLI, and Headless with platform-appropriate secret
  storage and a recoverable migration from `gnar`.
- Make revocation, reconnect, deployment limits, and operational recovery
  explicit before enabling the feature by default.

## Non-goals

- Replacing the local Headless API or changing the Session, Runtime, PTY, or
  transcript ownership model.
- Exposing a public route as an unauthenticated way to call `/v1/ws` or other
  control APIs.
- Arbitrary reverse proxying to a user-supplied URL, localhost port, or LAN
  address.
- Running two independent Host WSS connections for private Relay and public
  Tunnel.
- Making weak networks silently drop terminal bytes. That policy is P2.
- Making P2P a prerequisite for Relay, or treating a generation as a secret.
- Removing the `gnar`, Cloudflare, or Tailscale adapters in the first rollout.
- Horizontal Relay replicas before registry, presence, and stream routing have
  an explicit shared implementation.

## Terminology and ownership

| Term | Owner | Meaning |
| --- | --- | --- |
| Host | Headless daemon | The machine that owns Warren Projects, Workspaces, Sessions, Runtimes, PTYs, and local daemon authentication. |
| Relay | RelayService | The operator-owned edge. It stores Host identity, route metadata, token generations, presence, and bounded stream state; it does not store terminal business data. |
| Client | Web, Desktop, CLI, or another Warren UI | A remote caller with a scoped Relay capability. |
| Host Secret (`H`) | Headless, enrolled with Relay | One 256-bit random secret. It is the local daemon token and the credential used by the Host connector to authenticate to Relay. |
| Access capability (`A`) | Relay-issued, client-held | A short-lived signed delegation for a Host and scope. It is never a replacement for `H` and is never accepted as a Host connector credential. |
| Route | Relay registry | An opaque public hostname and policy bound to one Host and one generation. |
| Stream | Relay/Host transport | One private control session, HTTP request, or upgraded byte stream multiplexed over the single Host WSS. |

The Host remains the authority for Warren resources. Relay is a reachability
and admission boundary, not a second resource store. A route can be disabled
without deleting a Session; a Relay reconnect cannot recreate a PTY.

## Architecture

```text
Headless Host
  └─ one WSS /v1/host/connect (H, handshake, BRLY/2 streams)
          │
          ▼
Relay :443 ── WSS /v1/client/connect ── Web/Desktop/CLI
    │
    └─ HTTPS or WebSocket public Host route ── Internet caller
```

The Host connection is outbound, so a Host behind NAT does not require an
inbound firewall rule. Relay client sockets and public edge sockets are
independent from the Host socket, but all Host-bound work is scheduled onto
the same authenticated Host connection. A Host has at most one active
connection in a Relay generation; a newer authenticated connection closes the
older one.

## Unified identity and credential model

### One canonical Host Secret

Headless generates `H` with a cryptographically secure random source on first
start and persists it with restrictive permissions. Existing installations
continue to use their daemon token file as the source of truth. Enrollment
does not create a second `relay-token` file:

1. An administrator creates a Host record and receives a one-time enrollment
   ticket from Relay.
2. `warren relay enroll` reads the local `H` and sends it once over TLS with
   that ticket. Relay stores only `sha256(H)` and the Host metadata.
3. Headless stores the Relay URL, Host ID, Relay signing-key fingerprint, and
   non-secret route metadata. It keeps `H` in the platform credential store
   or the existing protected daemon-token location.
4. The connector authenticates every Host WSS upgrade with
   `Authorization: Bearer H`. Relay verifies the hash before accepting the
   socket and repeats the check while publishing the socket under its registry
   lock.

The enrollment ticket is one-time and expires after ten minutes. Relay never
returns `H` after enrollment, and Relay logs, pairing URLs, WebSocket query
strings, and browser storage must never contain it.

### Scoped delegated access

Relay issues `A` only after a pairing code or an administrator-approved client
enrollment. `A` is a compact Ed25519-signed capability with at least these
claims:

```json
{
  "iss": "relay-id",
  "aud": "warren-relay-stream",
  "host_id": "<uuid>",
  "generation": 7,
  "scope": ["control"],
  "route_id": "<optional-route-id>",
  "client_id": "<uuid>",
  "jti": "<random-id>",
  "exp": 1788000000
}
```

The Host pins Relay's public signing key during enrollment. For defense in
depth, Headless verifies `A` when Relay opens a `control` stream; Relay also
verifies the signature, audience, expiry, scope, Host ID, and current
generation before opening that stream. This is the safe meaning of “fusing”
the Headless and Relay tokens: one Host Secret and one generation lifecycle,
with scoped derivatives for remote callers. Passing `H` to a browser or using
an opaque Relay token as the local daemon token is explicitly rejected.

Supported scopes are:

- `control`: access to the Host's authenticated `/v1/ws` protocol and
  credential-free metadata allowed by that protocol;
- `tunnel`: permission to use a particular public route, subject to its route
  policy;
- `p2p-signal`: permission to exchange one temporary P2P session's signaling
  messages;
- `admin`: Relay administration only. It is never forwarded to Headless.

Every capability is checked at connection admission. A long-lived stream is
also bound to the generation and is closed when that generation is revoked.

The intended lifetimes are:

| Credential | Default lifetime | Storage and use |
| --- | --- | --- |
| Host Secret `H` | Until explicit rotation or revocation | Headless credential store; Host WSS and Host enrollment only. |
| Enrollment ticket | 10 minutes, one use | CLI memory only. |
| Pairing code | 10 minutes, one use | Operator/Host memory only. |
| Pairing ticket | 5 minutes, one use | Web URL fragment or native exchange request. |
| Access capability `A` | 15 minutes, maximum 1 hour | Memory or first WebSocket frame. |
| Refresh capability | 30 days, rotated on every use | HttpOnly cookie or native credential store; never forwarded to Headless. |

Refresh rotation is a bounded session family. Reuse of an already rotated
refresh value revokes that family; Host generation revocation revokes all
families for the Host.

### Pairing and browser exchange

Pairing remains explicit and one-time:

1. An administrator or an already enrolled Host calls
   `POST /v1/hosts/{hostID}/pairing` with Relay admin authentication or `H`.
2. Relay returns a 72-bit, ten-minute pairing code. It is consumed exactly
   once by `POST /v1/pair`.
3. Relay returns a short-lived `pairing_ticket` and an access capability. A
   Web URL contains only the one-time ticket in the fragment, never a
   long-lived access capability or `H`.
4. The Web app exchanges the ticket over HTTPS, receives an in-memory `A` and
   a rotated Secure, HttpOnly, SameSite=Strict refresh cookie, and immediately
   removes the fragment with `history.replaceState`.
5. Native clients exchange the ticket directly and keep the refresh capability
   in Keychain, Secret Service, Credential Manager, or a protected file
   fallback. They keep `A` in memory and refresh it before reconnecting.

The compatibility endpoint may accept an old `#t=<token>` URL during one
deprecation window, but it must exchange and scrub it immediately. New Web
code must not persist Relay capabilities in `localStorage`.

The native endpoint is `GET /v1/client/connect`. The Web app uses the
host-scoped alias `GET /h/{hostID}/v1/client/connect` so its refresh cookie can
be scoped to `/h/{hostID}/`; both aliases enforce the same signed Host and
generation checks. `POST /v1/session/exchange` consumes a pairing ticket and
`POST /v1/session/refresh` rotates a refresh capability. Neither endpoint
returns `H`.

### Rotation and revocation

- Rotating `H` is an atomic Relay registry update acknowledged by Headless;
  the connector changes its local secret only after the new hash is durable.
- Re-enrollment, explicit Host deletion, or administrator revocation bumps
  `generation`, closes the Host WSS, closes all Client and Tunnel streams, and
  invalidates every capability from the previous generation.
- Expired pairing tickets, expired capabilities, and revoked `jti` values are
  rejected without revealing whether a Host exists.
- A Relay signing-key rotation publishes an overlapping key set and key ID;
  enrolled Hosts accept both keys only during the bounded rotation window.

### Proposed control-plane API

The names below are the stable boundary for the first implementation; response
schemas may gain additive fields:

| Endpoint | Auth | Purpose |
| --- | --- | --- |
| `POST /v1/hosts` | Relay admin | Create a Host record and one-time enrollment ticket. |
| `POST /v1/hosts/{id}/enroll` | Enrollment ticket plus `H` | Bind the existing daemon token; Relay stores only its hash. |
| `POST /v1/hosts/{id}/pairing` | Relay admin or `H` | Issue a one-time pairing code. |
| `POST /v1/pair` | Pairing code | Consume the code and issue ticket/capabilities. |
| `POST /v1/session/exchange` | Pairing ticket | Issue `A` and a refresh capability/cookie. |
| `POST /v1/session/refresh` | Refresh capability | Rotate the refresh family and issue a new `A`. |
| `GET /v1/hosts/{id}` | Admin, `H`, or `control` | Credential-free Host and route status. |
| `POST /v1/hosts/{id}/route` | Admin or `H` | Enable/disable route and set policy; never accepts an arbitrary upstream. |
| `DELETE /v1/hosts/{id}` | Relay admin | Revoke Host, route, and all generations. |
| `GET /v1/host/connect` | `H` plus Host handshake | The single outbound Host WSS. |
| `GET /v1/client/connect` | `A` or refresh cookie | Native and legacy client WSS. |

## One Host connection and handshake

The only Host endpoint is:

```text
GET /v1/host/connect?host_id=<uuid>&name=<display-name>
Authorization: Bearer H
Upgrade: websocket
```

Secrets are not accepted in query parameters. The `name` value is optional
display metadata and is length-limited. Relay rejects an invalid Host ID,
invalid credential, unsupported protocol, or a stale generation before
publishing the socket.

After the TLS/WebSocket upgrade, Relay and Host perform a capability
handshake before any business stream is accepted:

```text
Relay  -> {"t":"relay_challenge","version":"2.0","nonce":"...",
           "relay_id":"...","key_id":"...","capabilities":[...]}
Host   -> {"t":"host_hello","version":"2.0","host_id":"...",
           "capabilities":["control","http","upgrade","p2p-signal"],
           "proof":"HMAC-SHA256(H, canonical-challenge)"}
Relay  -> {"t":"host_welcome","generation":7,"limits":{...},
           "route":{...}}
```

The challenge binds the Host ID, Relay ID, protocol version, nonce, and
capability list. A Host must not send BRLY frames before `host_welcome`. Relay
must not accept a second socket for the same Host without atomically fencing
the old one. Ping/Pong heartbeats are transport liveness only and never extend
token expiry.

The connector reconnects after an unexpected close with bounded exponential
backoff (`1s`, `2s`, `4s`, …, `30s`) and jitter. It does not start a second
connector while one is in the handshake or backoff state. A clean daemon
shutdown sends a close reason and stops reconnecting until the daemon starts
again.

## BRLY/2 multiplexing protocol

BRLY/2 keeps the current WebSocket-message framing but adds explicit stream
semantics. One WebSocket binary message contains one complete Relay frame:

```text
bytes 0..3   magic "BRLY"
byte  4      protocol version (2)
byte  5      kind
bytes 6..21  stream ID (16 random bytes)
bytes 22..   payload
```

The frame has no separate length field because the enclosing WebSocket message
has a length. Implementations must still enforce the configured WebSocket and
frame limits before allocating payload memory. Stream IDs are never reused on
one Host connection.

| Kind | Payload | Direction and purpose |
| --- | --- | --- |
| `OPEN` | UTF-8 JSON metadata | Relay opens a control, HTTP, Upgrade, or signal stream. |
| `CLOSE` | status, reason, and end flags | Either side closes a stream; handling is idempotent. |
| `TEXT` | UTF-8 bytes | Existing Headless control messages or signaling messages. |
| `BINARY` | opaque bytes | Existing terminal input/output payloads. Relay does not parse them. |
| `HTTP_HEADERS` | typed request/response headers | Starts request metadata or returns an HTTP response. |
| `DATA` | body or upgraded byte data | Carries ordered chunks. |
| `END` | optional trailers and end flags | Half-closes one direction after the final `DATA`. |
| `WINDOW_UPDATE` | unsigned credit | Grants bytes that may be sent on a stream. |
| `ERROR` | typed protocol error | Reports a stream-local or connection-fatal error. |

`OPEN` metadata contains a stream class, protocol version, request ID, and
deadline. A `control` stream carries the existing Headless authentication and
request/response protocol unchanged; Relay is only a frame router. The Host
must treat an `OPEN` supplied by Relay as untrusted input until its delegated
capability and route context have been verified.

Each direction has an initial credit window. The sender stops at zero credit;
the receiver sends `WINDOW_UPDATE` only after it has capacity. A full bounded
queue closes the slow stream with a retryable backpressure error instead of
unbounded memory growth. `CLOSE` and `END` propagate independently so an HTTP
response can finish while the opposite direction is being torn down.

The existing BRLY v1 private-control path may remain for a compatibility
window, but a Host must advertise BRLY/2 before Relay enables public HTTP or
Upgrade. New clients must not infer HTTP semantics from v1 `TEXT` or `BINARY`.

## Private Relay control

The client endpoint remains a client-side WebSocket, not a second Host socket:

```text
GET /v1/client/connect
Origin: <exact configured browser origin, when present>
Upgrade: websocket
```

The first client message is a text envelope within ten seconds:

```json
{
  "t": "auth",
  "version": "2.0",
  "access_token": "A",
  "client_id": "<uuid>",
  "capabilities": ["control", "recovery"]
}
```

Relay derives the Host ID from the signed capability; an optional legacy
`host_id` query value must match and must not be trusted for routing. Relay
checks origin, token signature, expiry, scope, generation, and Host presence,
then opens one `control` stream on the Host WSS. The capability envelope is
forwarded to Headless for the second signature check; `H` is never forwarded.

The Headless side receives the same control messages as a local `/v1/ws`
client, including protocol-version and terminal-state-format negotiation. The
Relay does not parse roster, Agent, or terminal business payloads. A client
disconnect sends `CLOSE` to the Host; a Host close sends a WebSocket close to
the client. All queues and write deadlines are bounded per client.

Relay control and administration have separate authorization surfaces:

| Surface | Required credential | Notes |
| --- | --- | --- |
| Host provisioning, route policy, revocation | Relay admin token | Bootstrap only; never sent to Headless. |
| Host enrollment and pairing start | `H` for that Host or Relay admin token | Origin-independent HTTPS request; rate-limited. |
| Client control WebSocket | `A` with `control` | Token only in the first frame or an HttpOnly cookie. |
| Public route | Route policy, and `A` with `tunnel` in owner mode | Never grants `control` by implication. |

`WARREN_RELAY_ALLOWED_ORIGIN` is mandatory for browser control connections in
production. It is an exact origin or an explicitly configured list; an empty
value is a startup/configuration error, not “allow all.” Native Host
connections use the credentialed handshake and do not need a browser Origin.

## Public Host routing and policy

### Route identity

Enabling public access creates or reuses a route record:

```text
route_id          128-bit random opaque identifier
public_hostname   exact hostname, normally <route_id>.<tunnel-domain>
host_id           owning Host UUID
generation        Host generation at enable time
path_prefix       "/" in the first version
auth_mode         "public" or "owner"
enabled           boolean
```

The canonical URL is `https://<public_hostname>/`. Relay normalizes the
incoming SNI and Host header and performs an exact route lookup. Unknown,
disabled, mismatched-generation, or ambiguous hosts return `404` or `410`
without probing any Host. An operator may bind a custom hostname only after a
DNS ownership check and certificate provisioning. A path-based fallback such
as `/t/<route_id>/` is allowed for deployments without wildcard DNS, but it
uses the same exact route table and policy.

The route ID and Host UUID are identifiers, not secrets. Unguessability is not
used as authentication. The route record is persisted with the Host registry
and is not regenerated on an ordinary daemon or Relay restart.

### Public authentication boundary

`auth_mode=public` permits application requests without a Warren token, but
it is deliberately narrow:

- `/v1/ws`, `/v1/state`, mutation APIs, and all other control-plane paths are
  denied or require a `control` capability regardless of route mode;
- the route may allowlist application paths and methods;
- browser `Origin` and WebSocket subprotocols are checked against route policy;
- the Host receives a signed route context over the authenticated Host stream,
  not a client-controlled `Host` or `X-Warren-*` header.

`auth_mode=owner` requires a `tunnel` capability in an HttpOnly cookie or an
`Authorization: Bearer A` header. Tokens in query strings are rejected. This
mode is the default for a newly enabled route; an administrator must opt into
public application access and acknowledge its exposure.

The public edge never treats a route URL as permission to operate on a
different Host. A request is bound to the route's Host ID and generation
before an `OPEN` frame is emitted.

## HTTP and WebSocket Upgrade forwarding

Relay terminates public TLS and acts as a bounded stream endpoint. It does not
open an arbitrary reverse-proxy URL. The Host connector dispatches the stream
to the in-process Headless HTTP service; if an implementation uses a loopback
adapter, it obtains the actual listener address from the configured listener
(`WARREN_LISTEN`) rather than hard-coding port `8789`.

### Ordinary HTTP

For a request, Relay sends an `OPEN` stream descriptor followed by an
`HTTP_HEADERS` frame:

```json
{
  "class": "http",
  "route_id": "...",
  "request_id": "...",
  "deadline_ms": 30000
}
```

The corresponding `HTTP_HEADERS` payload is:

```json
{
  "method": "POST",
  "scheme": "https",
  "authority": "public.example",
  "path": "/api/job",
  "headers": [["content-type", "application/json"]],
  "body_limit": 67108864
}
```

The request body is zero or more ordered `DATA` frames followed by `END`. The
Host returns one `HTTP_HEADERS` frame with status, filtered response headers,
and an optional content-length, then response `DATA`, optional trailer
metadata, and `END`. A response may stream before the request has ended only
for an explicitly supported full-duplex endpoint.

The first implementation uses these limits, all configurable downward by an
operator:

| Limit | Default |
| --- | ---: |
| One Relay frame | 8 MiB |
| Request/response header block | 64 KiB |
| One header name or value | 8 KiB |
| In-flight bytes per stream | 16 MiB |
| Concurrent Host streams | 128 |
| Public concurrent streams per Host | 64 |
| Header wait / idle stream timeout | 10 s / 60 s |
| Maximum ordinary request body | 64 MiB |

Streaming endpoints may opt into a byte-rate and duration quota instead of an
aggregate body limit. A slow or over-limit caller receives a typed `408`,
`413`, or `429` response and a stream `CLOSE`; it cannot consume an unbounded
Host queue.

### Header and authority filtering

Relay removes hop-by-hop headers (`Connection`, `Keep-Alive`, `Proxy-Auth*`,
`TE`, `Trailer`, `Transfer-Encoding`, and `Upgrade` outside the Upgrade
handshake), rejects duplicate framing headers, and overwrites trusted
forwarding metadata. Incoming `X-Forwarded-*`, `X-Warren-*`, route, and Host
identity headers are never authoritative. `Cookie` and end-to-end
`Authorization` are preserved only when the route policy allows them. Relay
adds a signed internal route context in stream metadata instead of relying on
headers. Response hop-by-hop headers are filtered symmetrically.

### HTTP/1.1 Upgrade

For a public WebSocket Upgrade, Relay validates `GET`, `Connection: Upgrade`,
`Upgrade: websocket`, `Sec-WebSocket-Version`, and the configured
`Sec-WebSocket-Protocol` values before opening an `upgrade` stream. The Host
receives the request headers and returns an `HTTP_HEADERS` response with
status `101` and the negotiated protocol. Only after `101` is committed do
both sides send opaque ordered `DATA` frames in upgraded mode. Relay does not
parse application WebSocket messages or manufacture a second handshake.

The selected subprotocol is forwarded exactly once; per-message compression is
disabled at the public edge in the first implementation. After both public and
Host-side handshakes return `101`, `DATA` carries raw post-handshake bytes in
order. A Host-side adapter may use an equivalent message-preserving transport
only if it documents the framing; Relay itself does not parse application
WebSocket messages. A failed Upgrade returns the Host's status and closes the
stream. Closing either WebSocket propagates a close/half-close to the other
side, with a 60-second idle timeout and an operator-configurable absolute
lifetime.

HTTP/2 extended CONNECT and arbitrary TCP forwarding are not part of this
version. They require separate framing and abuse controls.

## Public-tunnel lifecycle

Headless persists user intent in `settings.json` (for example,
`relay.enabled`, `publicTunnel.enabled`, route policy, and a non-secret route
ID). Starting or restoring a public route is asynchronous and must not delay
the local daemon's listener or first roster. The route is announced as
`pending` until the Host WSS handshake and Relay route registration both
succeed.

The lifecycle is:

1. `publicTunnel.enabled=true` is saved atomically.
2. Headless ensures the Relay connector is running and advertises the
   `http`/`upgrade` capabilities during its one Host handshake.
3. Relay creates or restores the route for the current generation and reports
   its canonical URL through a credential-free status projection.
4. `disable` marks the route unavailable first, closes public streams, then
   stops sending new route `OPEN` frames. It does not stop Sessions or PTYs.
5. A daemon shutdown closes the Host socket and route presence. Relay returns
   `503 Service Unavailable` with `Retry-After` while the route is enabled but
   offline; it never queues public requests across a restart.

The existing `gnar` adapter remains selectable during migration. A Host must
not publish the same public route through both adapters at once; the owner of
the route is recorded so rollback cannot leave two processes competing for one
endpoint.

## P2P follow-up

P2P is an optimization after the one-connection Relay path is stable. Relay
continues to provide signaling and optional STUN/TURN reachability; it does
not hand out a Host Secret.

For each attempt, the Client and Host generate fresh ephemeral signing keys
and a random `p2p_session_id`. Relay issues a ticket signed with its pinned
key:

```json
{
  "iss": "relay-id",
  "host_id": "...",
  "generation": 7,
  "session_id": "...",
  "role": "host|client",
  "client_id": "...",
  "ephemeral_key": "...",
  "exp": 1788000000
}
```

The signaling sequence is explicit:

1. Client sends a signed ICE offer and candidates with the ticket.
2. Relay validates scope, generation, expiry, and session ID, then forwards
   the offer to the Host over the existing Host stream.
3. Host returns a signed ICE answer and candidates; Relay forwards them.
4. Both peers verify the Relay ticket, each other's ephemeral signature over
   the complete transcript, and the negotiated peer key before opening a
   WebRTC data channel or QUIC connection.
5. A DTLS/QUIC exporter binds the application stream to the transcript. Warren
   control messages are enabled only after that binding succeeds.

Candidates are not credentials. A ticket expires within one minute, is
single-use, and is invalidated by generation revocation. If ICE, the peer
signature, or the data channel does not complete within ten seconds, both
peers close the attempt and continue over the authenticated Host WSS without
changing control semantics. No P2P code is required for the initial release.

## Client and credential integration

### Headless

Headless adds a supervised Relay connector alongside its existing HTTP server.
The connector owns the one WSS, handshake, reconnection, stream scheduler, and
Relay capability verifier. It dispatches control streams to the same service
used by `/v1/ws` and dispatches HTTP/Upgrade streams to that service's actual
listener or in-process handler. Control-plane secrets are stripped from every
Shell, Runtime, and Agent child environment.

The connector reads the Relay URL and Host ID from settings or an explicit
first-run enrollment command. Long-lived secrets are not required in process
arguments or ordinary environment variables after enrollment. A changed local
`H` triggers re-enrollment rather than silently opening a new Host identity.

### Desktop

Desktop extends its endpoint model with a Relay endpoint type containing the
Relay URL, Host ID, route metadata, and a secret reference. A Relay endpoint
uses `/v1/client/connect` and the access-capability handshake; it must not
append a Relay URL to the local `/v1/ws` path or assume that a Relay is a
Headless HTTP server. Local, SSH, and Relay endpoints remain selectable and
retain their existing reconnect and recovery behavior.

The macOS implementation stores Host Secrets and native access capabilities in
Keychain. It displays expiry, scope, online state, route state, and the last
connection error, but never displays a secret after enrollment.

### Web

Relay serves a Host-scoped Web shell under a route such as `/h/<hostID>/`.
Pairing fragments are consumed once, exchanged for an in-memory access
capability plus a rotated HttpOnly refresh cookie, and removed from the address
bar and history. The Web app uses the host-scoped WebSocket alias
`/h/<hostID>/v1/client/connect`, so the refresh cookie can be scoped to the
same `/h/<hostID>/` path. It keeps only the minimum in-memory access state
needed to reconnect. It must not put a Host Secret or a long-lived capability
in `localStorage`, analytics, referrer headers, or clipboard text by default.

### CLI and non-macOS storage

The CLI provides explicit operations equivalent to:

```text
warren relay enroll --url https://relay.example.com
warren relay pair --host <uuid>
warren relay status
warren relay tunnel enable|disable
warren relay revoke --host <uuid>
```

The exact command names may follow the existing CLI conventions, but the
workflow must remain explicit: enrollment, pairing, route enablement, and
revocation are separate operations. macOS uses Keychain, Windows uses
Credential Manager, and Linux uses Secret Service when available. A fallback
file under the Warren configuration directory is `0600`, contains only the
minimum required secret, is excluded from logs and diagnostics, and produces a
visible warning when no OS credential store is available.

## Deployment and operations

### Relay deployment

Production Relay requires:

- a strong admin bootstrap token;
- an Ed25519 signing key (a 32-byte private seed) with a documented rotation
  procedure;
- a persistent protected registry volume;
- an HTTPS/WSS reverse proxy or a directly configured TLS listener;
- a canonical `WARREN_RELAY_PUBLIC_URL` and a wildcard/custom certificate
  policy for public Host routes; and
- a non-empty, exact `WARREN_RELAY_ALLOWED_ORIGIN` configuration.

The Docker example must include the origin and route-domain settings rather
than relying on an empty-origin default:

```sh
docker run --read-only --tmpfs /tmp \
  -p 127.0.0.1:8080:8080 -v warren-relay-data:/data \
  -e WARREN_RELAY_ADMIN_TOKEN \
  -e WARREN_RELAY_SIGNING_KEY \
  -e WARREN_RELAY_PUBLIC_URL=https://relay.example.com \
  -e WARREN_RELAY_ALLOWED_ORIGIN=https://relay.example.com \
  -e WARREN_RELAY_TUNNEL_BASE_DOMAIN=tunnel.example.com \
  warren-relay
```

The reverse proxy must preserve WebSocket Upgrade, set a trusted
`X-Forwarded-Proto`, enforce request-header/body limits, and never log
Authorization headers, pairing fragments, or access-token payloads. TLS 1.2+
is required; TLS termination and Relay must agree on the public origin.

The initial deployment is single-replica with a persistent volume. Relay must
refuse or clearly warn about a second replica because an in-memory Host socket
cannot be routed by a different instance. A future multi-replica design needs
shared registry/presence, stream ownership, and a durable or reliable message
bus before changing this rule.

### Limits, abuse controls, and observability

Relay applies per-IP and per-Host rate limits to pairing, client handshakes,
public requests, and Upgrade attempts. It enforces maximum Hosts, concurrent
Host streams, public streams, header bytes, body bytes, idle time, and total
connection lifetime from configuration. Route policy may impose a lower limit.

Structured logs and metrics include Relay instance, Host ID, route ID, stream
ID, scope, status code, bytes, latency, and close reason. They never include
`H`, `A`, pairing codes, cookies, Authorization headers, or URL fragments.
Audit events cover enrollment, credential rotation, pairing, route enable/
disable, P2P attempts, and revocation. Status responses are credential-free
and may report `online`, `last_seen`, `generation`, route URL, and expiry
timestamps only.

## Security requirements

- All external traffic uses TLS. Host-to-Relay authentication uses `H` plus
  the challenge handshake; browser control uses a scoped capability or
  HttpOnly cookie with strict Origin and CSRF checks.
- The Relay registry stores hashes and public metadata, not `H`, pairing codes,
  access capabilities, terminal output, or transcripts. Registry writes are
  atomic and files are `0600`.
- A public route is not a control authorization. `/v1/*` control paths are
  denied or require `control`, and mutation methods require the Headless
  protocol's normal authorization and control lease rules.
- Route selection is exact and Host-bound. User input cannot choose an
  upstream URL, file path, socket, or other Host. This prevents SSRF and
  cross-Host routing.
- Hop-by-hop, forwarding, route, and internal-auth headers are filtered as
  described above. Cookies and application Authorization are handled only by
  route policy.
- Access and pairing values are absent from query strings and logs. New Web
  links contain only one-time tickets and scrub them immediately.
- Slow clients are isolated by bounded queues and flow control. A full queue
  closes that stream; it must not block unrelated Hosts or clients.
- Credential rotation and generation revocation close existing streams and
  prevent stale sockets from publishing themselves after a newer connection.
- Relay signing-key fingerprints are pinned at enrollment and rotated through
  an overlapping, auditable key set. P2P uses ephemeral keys and transcript
  signatures; a generation is only a revocation/version value.

## Migration and rollback

Migration is additive and reversible:

1. Existing Headless, local Desktop, SSH endpoints, and `gnar` public access
   continue to work unchanged when Relay is not enabled.
2. `warren relay enroll` binds the existing daemon token as `H`; it does not
   replace the local token or create a second long-lived Host credential.
3. Relay control is enabled first. The operator pairs a client and verifies a
   control roster, terminal input/output, reconnect, and revocation before
   enabling a public route.
4. The operator enables the Relay route and verifies HTTP and WebSocket
   Upgrade health. Only then may the `gnar` route be disabled. The selected
   route owner is persisted so a restart cannot start both adapters.
5. Existing old `#t=` links are accepted only during the compatibility window
   and are exchanged/scrubbed. New pairings use one-time tickets and scoped
   capabilities. No terminal or Session data migration is needed.

If the Relay connector or public route fails, rollback disables only
`relay.enabled`/`publicTunnel.enabled`, restores the previous `gnar` setting,
and leaves the daemon token, Sessions, PTYs, and local endpoint untouched. A
failed credential rotation restores the old hash and secret atomically; a
failed route migration never deletes the old route until the new route has
passed its health checks.

## Implementation phases

### P0: authenticated Relay and single connection

- Define BRLY/2, capability claims, enrollment, generation fencing, and the
  Headless connector.
- Add Relay origin enforcement, route registry, rate limits, and bounded
  stream queues.
- Keep private control working before enabling any public route.

### P1: public HTTP/Upgrade and client integration

- Implement HTTP headers/data/end flow control and Upgrade switching.
- Add Headless settings and lifecycle, Desktop Relay endpoints, Web ticket
  exchange, CLI enrollment/pairing, and platform credential stores.
- Run the real reverse-proxy and public-route acceptance matrix before making
  the route visible by default.

### P2 follow-ups (not this delivery)

- Weak-network measurement and policy. Any downgrade must preserve terminal
  correctness, distinguish frame classes at the protocol level, and be backed
  by user-visible state; this RFC intentionally does not pause or drop
  `BINARY` frames.
- P2P signaling, ephemeral peer authentication, ICE/STUN/TURN, and fallback
  metrics described in this RFC.
- HTTP/2 extended CONNECT, arbitrary TCP forwarding, and multi-replica Relay.

## Testing and acceptance

The implementation is not ready for rollout until all of the following are
covered:

| Area | Required checks |
| --- | --- |
| Credentials | Enrollment binds the existing daemon token; Relay stores only its hash; capability scope, expiry, audience, key rotation, and generation revocation are tested. |
| Handshake | Wrong Host ID, stale socket, replayed challenge, unsupported version, missing capability, and concurrent replacement are rejected. |
| Private control | One Host WSS serves multiple clients; control messages, terminal binary frames, recovery anchors, close propagation, backpressure, and reconnect remain correct. |
| Routing | Exact Host/SNI lookup, disabled route, custom hostname, path fallback, wrong generation, unknown route, and cross-Host attempts return the documented status. |
| HTTP | Header filtering, request streaming, response streaming, trailers, body/header limits, timeout, rate limit, half-close, and slow-reader isolation are tested. |
| Upgrade | Valid and invalid WebSocket Upgrade, subprotocol negotiation, close propagation, idle timeout, and no-compression behavior are tested through the real reverse proxy. |
| Authentication boundary | Public application requests cannot call `/v1/ws` or mutations; owner routes require `tunnel`; control routes require `control`; Origin and CSRF checks reject wrong sites. |
| Clients | Desktop, Web, CLI, macOS Keychain, Linux/Windows stores, fragment scrubbing, token expiry, endpoint switching, and daemon restart are tested. |
| Migration | Existing `gnar`, local, and old-link compatibility; relay-to-gnar rollback; credential rotation; and no duplicate tunnel owner are tested. |
| Operations | Docker read-only deployment, persistent registry restart, required AllowedOrigin, TLS/WSS, rate limits, metrics, redacted logs, and single-replica behavior are verified. |
| Real behavior | Start the built Relay and a real Headless with a non-default listen address, pair a real Web/Desktop client, execute control operations, `curl` an HTTP route, perform a WebSocket Upgrade, revoke access, and confirm existing Sessions survive. |

Unit tests and protocol fixtures are necessary but insufficient. The final
gate is a real Relay reverse proxy and a real Headless process; fixture data
must not substitute for observing the public request, Upgrade, reconnect, and
revocation behavior.

## Alternatives considered

- **Two Host WSS connections, one for control and one for Tunnel:** rejected.
  It doubles TLS state, heartbeats, reconnect races, and credential rotation
  without adding an ownership boundary. Stream classes already provide the
  required isolation on one connection.
- **Forward the local daemon token to the browser:** rejected. It turns a
  public pairing link into full Host credential disclosure and makes browser
  history a daemon compromise. Scoped signed capabilities and a ticket exchange
  preserve the unified identity without exposing `H`.
- **Relay rewrites every client token into an opaque local token:** rejected.
  Headless cannot independently verify the delegation and Relay becomes a
  hidden authentication oracle. A pinned public signing key gives the Host a
  second, offline-verifiable check.
- **Keep `gnar` as the only public path:** rejected as the default because it
  requires an external binary, account/enrollment state, and a separate
  credential lifecycle. It remains a compatibility adapter during rollout.
- **Drop terminal frames on a weak network now:** rejected and deferred to P2;
  silent byte loss is not a valid terminal recovery strategy.
