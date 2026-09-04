# RFC 0009: Relay-owned access and public routes

- Status: Implemented
- Protocol: BRLY/2 and Warren API 2.0

## Decision

Warren has one remote access transport: the independently deployable Relay.
The Host daemon owns Projects, Workspaces, Sessions, PTYs, and terminal
output. Relay owns Host registration, pairing, capability issuance, public
route metadata, and WebSocket/frame forwarding. SSH remains a client-side
bootstrap path that forwards a loopback daemon port; it is not a business
protocol.

Public Access and owner access use the same enrolled Host and the same Relay
route service. No second tunnel provider or fallback transport is part of the
product model.

## Host enrollment

The Relay administrator creates one or more short-lived enrollment keys with
the admin API. A key is a bounded-use `XXXX-XXXX-XXXX-XXXX` code. Warren
Desktop can receive a `warren://settings` shortcut containing the Relay URL
and key, or the operator can provide both values to Headless/CLI. The shortcut
only prefills the form; it is consumed when the operator explicitly connects.

Headless then actively claims the Host over HTTPS:

```text
POST /v1/hosts/claim
{"enrollment_key":"XXXX-XXXX-XXXX-XXXX","host_secret":"...","name":"..."}
```

Relay allocates the Host UUID and stores only credential hashes. Claim retries
with the same Host Secret are idempotent. Headless persists the Relay URL,
Host ID, signing-key pin, and non-secret route metadata; the daemon token
remains in its protected token file. The Host opens one outbound WSS
connection at `/v1/host/connect` and authenticates with BRLY/2.

## Pairing and native clients

An administrator or the enrolled Host starts pairing with
`POST /v1/hosts/{hostID}/pairing`. The pairing code remains valid for the
configured sharing window (seven days by default) and can be exchanged more
than once by `POST /v1/pair`. Each exchange returns a short-lived
`access_token` and an opaque reusable invite URL at `/invite/<opaque>/`. The
invite hash is persisted, so a Relay restart does not invalidate the link after
the Host reconnects. Browser and iOS clients exchange the invite and receive
the Host ID in the response; they keep that identity in memory and then use the
Host-scoped WebSocket path `/h/{hostID}/v1/client/connect`:

```json
{
  "t": "auth",
  "version": "2.0",
  "access_token": "...",
  "client_id": "...",
  "capabilities": ["roster-delta"],
  "terminalStateFormats": ["ghostline-vt-replay-v1"]
}
```

Capabilities are scoped to a Host and generation. They are kept in memory by
the CLI and are never copied into the Host Secret or a URL query string.

## Public routes

The route lifecycle is explicit:

```text
POST   /v1/hosts/{hostID}/route   configure or enable
GET    /v1/hosts/{hostID}/route   read route state
DELETE /v1/hosts/{hostID}/route   disable route
```

Route configuration accepts `auth_mode` (`owner` or `public`), an optional
public hostname, and a path prefix. Relay issues a short-lived tunnel
capability for each public stream and forwards only filtered headers and body
frames to Headless. The Host verifies the capability before dispatching the
stream. Public endpoint reporting contains no access token or Host Secret.

Headless persists enabled intent and route metadata in `settings.json`. A
restart reconnects the single Relay connector and retries the route. Reset
disables the route and clears local route metadata without deleting Host
enrollment.

## Client-facing commands

Warren exposes only the operations a Host operator needs:

```text
warren relay connect [SETTINGS_URL] [--url RELAY_URL --key ENROLLMENT_KEY]
warren relay join [SETTINGS_URL] [--url RELAY_URL --key ENROLLMENT_KEY]
warren relay share [--qr [PATH]] [--open]
```

The settings URL or URL/key pair is passed to the selected local Headless
daemon. The daemon supplies the Host Secret, calls `/v1/hosts/claim`, and
starts the outbound connector. These commands never create a Host directly or
accept a Relay administrator token.

`relay share` asks the local daemon for an opaque client-facing link and can
write a QR image. The daemon performs the pairing-code exchange internally and
returns no access capability or Host Secret. Pairing-code exchange, Host
provisioning, route mutation, and revocation remain Relay service operations,
not Warren client commands. The link is reusable by multiple devices until
the sharing window expires; generating a new pairing window rotates old links.

`warren endpoint add NAME --type relay --url RELAY_URL --token ACCESS_TOKEN
--host-id HOST_ID` stores a Relay endpoint. Resource commands detect that type
and use the scoped Relay WebSocket path instead of appending `/v1/ws` to the
Relay origin. SSH endpoints remain durable aliases; their loopback listener
and token are created and cleaned up per process.

## Security and compatibility

- Protocol versions and stream classes are validated at both Relay and Host.
- Host generations fence revoked capabilities and close active streams.
- Redirects are disabled for enrollment and route requests.
- Query strings, fragments, and userinfo are rejected from Relay origins.
- Relay never stores terminal output, user input, or a Host Secret.
- Legacy reachability adapters and their configuration are not accepted.
