# Warren Relay Service

Warren Relay is an independently deployable remote control plane. It stores Host identity, online presence, and revocation generations, and forwards WebSocket frames; Projects, Workspaces, Sessions, Runtimes, and Terminal output exist only on the Host. Relay never records or parses terminal business frames.

## One-Command Experience

From the repository root:

```bash
mise run relay:dev
```

This command automatically generates a local development secret, starts Relay, registers the current Mac, builds and starts Warren, waits for the Host to come online, creates a seven-day opaque `/invite/<opaque>/` pairing link, and opens the Web/PWA. Generated development state is stored in the git-ignored `.build/relay-dev/8080` directory, and secret files use `0600` permissions. The local Relay listens on all LAN interfaces by default and writes the Mac's LAN address into the pairing URL, so phones on the same network as the Mac can reach it. Use `WARREN_RELAY_DEV_HOST=192.168.1.23` to specify an address reachable from the phone, or `WARREN_RELAY_DEV_BIND_HOST=192.168.1.23` to restrict listening to a single interface. This development mode is only suitable for a trusted LAN; do not expose the port to the public internet.

Daily commands:

```bash
  mise run relay:pair    # create another seven-day shareable link
mise run relay:status  # show Relay and Host status
mise run relay:stop    # stop only the Relay; keep Warren running and terminal sessions alive
```

Connecting to a deployed public Relay is also one command; the admin token is only needed for the first registration of this Mac:

```bash
WARREN_RELAY_URL=https://relay.example.com \
WARREN_RELAY_ADMIN_TOKEN='<admin-token>' \
mise run relay:connect
```

Afterwards, the same address keeps the Host ID and pinned Relay key in `~/Library/Application Support/Warren/relay-cli/<relay-id>` with `0600` permissions. The daemon token remains the canonical Host Secret; later runs can omit the admin token. If the Host is already online, re-running does not rebuild or restart the app; it only generates a new pairing URL. Add `WARREN_RELAY_NO_OPEN=1` to skip opening the browser automatically.

The installed CLI also provides the short path for a new Host and for sharing
one link with several devices:

```bash
# Create a Relay Host record and enroll the local daemon in one step.
warren relay register --url https://relay.example.com \
  --admin-token "$WARREN_RELAY_ADMIN_TOKEN"

# Create a reusable seven-day link, optionally writing a protected QR PNG.
warren relay share --url https://relay.example.com --host HOST_ID \
  --host-secret "$(cat ~/.warren/token)" --qr "$HOME/Desktop/warren-relay-pairing.png"
```

Add `--share` (and optionally `--qr`/`--open`) to `relay register` when the
local Warren daemon is already running; the command waits briefly for the Host
to come online before creating the link.

The link is a bearer credential: share it only with intended clients. A new
`relay share` invocation rotates the pairing code and invalidates the previous
link; Host re-enrollment and revocation invalidate all existing client access.
Relay persists only a hash of the opaque invite, so a Relay restart does not
invalidate it once the Host reconnects.

## Start

First generate an admin token and an Ed25519 signing seed of at least 32 bytes. Production must terminate TLS behind an HTTPS/WSS reverse proxy (or provide the TLS certificate and key directly).

```bash
export WARREN_RELAY_ADMIN_TOKEN='replace-admin-token'
export WARREN_RELAY_SIGNING_KEY='replace-with-at-least-32-random-bytes'
export WARREN_RELAY_PUBLIC_URL='https://relay.example.com'
export WARREN_RELAY_ALLOWED_ORIGIN='https://relay.example.com'
export WARREN_RELAY_TUNNEL_BASE_DOMAIN='tunnel.example.com'
# Pairing links are reusable for seven days by default. Override with a Go
# duration such as 72h when a shorter sharing window is appropriate.
export WARREN_RELAY_PAIRING_TTL='168h'
export WARREN_RELAY_PAIRING_TICKET_TTL='168h'
go run ./RelayService/cmd/warren-relay
```

Or build a container:

```bash
docker build -f RelayService/Dockerfile -t warren-relay .
docker run --read-only --tmpfs /tmp -p 127.0.0.1:8080:8080 -v warren-relay-data:/data \
  -e WARREN_RELAY_ADMIN_TOKEN \
  -e WARREN_RELAY_SIGNING_KEY \
  -e WARREN_RELAY_PUBLIC_URL=https://relay.example.com \
  -e WARREN_RELAY_ALLOWED_ORIGIN=https://relay.example.com \
  -e WARREN_RELAY_TUNNEL_BASE_DOMAIN=tunnel.example.com \
  warren-relay
```

If using `--read-only`, the runtime also needs a writable temporary directory (for example `--tmpfs /tmp`); persistent data is only written to `/data`.

### IP and port deployments

`WARREN_RELAY_PUBLIC_URL` may be an ordinary `http://` or `https://` URL with
an IPv4/IPv6 literal and port, for example `http://192.0.2.10:8080` or
`https://[2001:db8::10]:8443`. A DNS name and wildcard certificate are not
required for the Relay control plane. When a route is created without an
explicit `public_hostname`, an IP-based Relay keeps the listener authority and
assigns an opaque path, such as:

```text
http://192.0.2.10:8080/t/<route-id>/
```

The `/t/<route-id>` prefix is removed before the request reaches Headless, so
`/t/<route-id>/api/status` is delivered to the Host as `/api/status`. Multiple
Hosts can share one IP and port because their route paths are independent. A
DNS deployment continues to use the per-route hostname form; an explicit
`path_prefix` can be used in either deployment.

For an intentional trusted-network HTTP deployment, including the iOS App
Transport Security exception required by a private development build, see
[Using an HTTP Relay](../docs/relay-http.md). Public or untrusted deployments
must terminate TLS instead.

## Host Registration and Connection

The daemon token in `~/.warren/token` is the canonical Host Secret. Create a Host record to obtain a one-time enrollment ticket, then enroll that existing token; Relay stores only `sha256(Host Secret)`. Re-enrollment or revocation bumps the Host generation, disconnects the old socket, and invalidates capabilities from the previous generation.

```bash
export WARREN_HOST_ID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
curl -sS -X POST https://relay.example.com/v1/hosts \
  -H "Authorization: Bearer $WARREN_RELAY_ADMIN_TOKEN" \
  -H 'Content-Type: application/json' \
  -d "{\"id\":\"$WARREN_HOST_ID\",\"name\":\"My Mac\"}"
```

The response contains `enrollment_ticket`, the Relay signing public key, and a
canonical `settings_url`. Open that
`warren://settings` link in the Warren desktop app to prefill the Relay URL,
Host ID, pinned key, and one-time ticket, or enroll from the CLI. The link
contains no daemon token and should be discarded after enrollment; the ticket
is valid for ten minutes and cannot be reused.

Enroll the existing daemon token once:

```bash
warren relay enroll --url https://relay.example.com --host "$WARREN_HOST_ID" \
  --ticket '<enrollment-ticket>' --secret "$(cat ~/.warren/token)"
```

The command stores the Relay URL, Host ID, and signing key in the daemon
settings and enables the supervised connector. It then opens exactly one
outbound `wss://.../v1/host/connect` socket and reuses the local daemon token as
its Host Secret; control-plane secrets are stripped from every shell/runtime
child process.

Warren only makes outbound WSS connections; with no control plane configured, it still listens on `127.0.0.1` only.

Desktop and other local clients can use the equivalent Headless endpoint
`POST /v1/relay/enroll` with `relayUrl`, `hostId`, and `enrollmentTicket`.
Headless supplies the daemon token itself, validates the returned signing key,
and persists the Relay metadata. This endpoint is intentionally unrelated to
Public Access route settings.

## Pairing, Discovery, and Revocation

An admin or the Host's own credential can generate a seven-day pairing code:

```bash
curl -sS -X POST https://relay.example.com/v1/hosts/<host-uuid>/pairing \
  -H "Authorization: Bearer $WARREN_RELAY_ADMIN_TOKEN"
```

A client exchanges the code for a seven-day, reusable Web/iOS pairing link and
a short-lived Ed25519 access capability bound to the Host, scope, route, and
generation:

```bash
curl -sS -X POST https://relay.example.com/v1/pair \
  -H 'Content-Type: application/json' \
  -d '{"host_id":"<host-uuid>","pairing_code":"<pairing-code>"}' \
  | jq '{pairing_url, pairing_expires_in, pairing_expires_at}'
```

`pairing_url` (also returned as the compatibility field `web_url`) is the
responsive Web/PWA entry point. It has the form `/invite/<opaque>/` and does
not disclose the Host ID. The pairing link can be exchanged by multiple devices
until it expires; each exchange returns a short-lived capability and the Host ID
is used only in memory to open the Host-scoped WebSocket. Generating a new
pairing code replaces the previous code; re-enrolling or revoking the Host
invalidates existing links and access capabilities.

```bash
curl -sS -X DELETE https://relay.example.com/v1/hosts/<host-uuid> \
  -H "Authorization: Bearer $WARREN_RELAY_ADMIN_TOKEN"
```

## Security Boundaries

- The admin API uses a separate bootstrap token; the Host Secret remains the daemon token and is never sent to a browser.
- Enrollment tickets remain one-time and short-lived. Pairing codes and client
  pairing links are reusable for their configured seven-day sharing window.
  Access capabilities are Ed25519-signed and include scope, route, client, JTI,
  expiry, and generation claims.
- Client capabilities appear only in the first WebSocket auth frame (or an `Authorization` header for an owner route), never in query strings or normal access logs.
- Relay registry writes are atomic with `0600` permissions and only store Host credential hashes and control-plane metadata.
- Each BRLY/2 frame is capped at 8 MiB, each stream has a 16 MiB credit window, and each Host has 128 streams (64 public streams); slow queues are closed.
- Relay never sends the Host Secret to browsers. The Web app exchanges the
  shareable pairing ticket for an in-memory access capability and an HttpOnly
  refresh cookie, then scrubs the fragment. The ticket remains valid for the
  configured sharing window so another device can use the same link.
- Production deployments must use TLS, strong random secrets, a persistent volume, and a strict `WARREN_RELAY_ALLOWED_ORIGIN`.

The registry and Host tunnels currently live in a single Relay instance; deployments should stay single-replica with a persistent volume. Horizontal scaling requires moving registry, presence, and connection routing to a shared storage/messaging layer first.
