# RFC 0009: Relay-owned access and public routes

- Status: implemented
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

An administrator creates a Host record and receives a one-time enrollment
ticket. `warren relay enroll` sends the existing daemon token once over HTTPS:

```text
POST /v1/hosts/{hostID}/enroll
{"enrollment_ticket":"...","host_secret":"..."}
```

Relay stores only a credential hash. Headless persists the Relay URL, Host ID,
signing-key pin, and non-secret route metadata; the daemon token remains in its
protected token file. The Host opens one outbound WSS connection at
`/v1/host/connect` and authenticates with BRLY/2.

## Pairing and native clients

An administrator or the enrolled Host starts pairing with
`POST /v1/hosts/{hostID}/pairing`. The pairing code remains valid for the
configured sharing window (seven days by default) and can be exchanged more
than once by `POST /v1/pair`. Each exchange returns a short-lived
`access_token` and a reusable browser `pairing_ticket`. Native CLI clients use the capability at
`/h/{hostID}/v1/client/connect` (or the unscoped equivalent) and send:

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

## CLI contract

The CLI keeps enrollment, pairing, route lifecycle, and revocation separate:

```text
warren relay enroll --url RELAY_URL --host HOST_ID --ticket TICKET --secret HOST_SECRET
warren relay pairing --url RELAY_URL --host HOST_ID --host-secret HOST_SECRET
warren relay pair --url RELAY_URL --host HOST_ID --code PAIRING_CODE
warren relay register --url RELAY_URL --admin-token ADMIN_TOKEN [--share] [--qr [PATH]]
warren relay share --url RELAY_URL --host HOST_ID --host-secret HOST_SECRET [--qr [PATH]]
warren relay status --url RELAY_URL --host HOST_ID --token ACCESS_TOKEN
warren relay tunnel enable --url RELAY_URL --host HOST_ID --host-secret HOST_SECRET \
  [--auth-mode owner|public] [--public-hostname HOSTNAME] [--path-prefix PREFIX]
warren relay tunnel disable --url RELAY_URL --host HOST_ID --host-secret HOST_SECRET
warren relay revoke --url RELAY_URL --host HOST_ID --admin-token ADMIN_TOKEN
```

`--token` remains a compatibility alias when supplied explicitly on a
management command. A configured Relay endpoint stores only its short-lived
`ACCESS_TOKEN`; that value is never inferred as a Host Secret or admin token.

`relay register` creates and enrolls a Host in one step. `relay share` creates
the client-facing link and can write a QR image. The link is reusable by
multiple devices until the sharing window expires; generating a new pairing
code rotates the old link. Host re-enrollment and revocation invalidate all
existing pairing tickets.

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
