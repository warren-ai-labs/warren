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

For a deployed public Relay, the service startup log gives the first operator
the setup link. For every later Host, the Relay Administrator creates a Host
record in the service-owned API and gives the operator the returned setup
link. The operator opens that link in Warren Desktop (or uses the client
shortcut):

```bash
warren relay connect '<settings-url>'
```

Afterwards, the daemon keeps the Host ID and pinned Relay key in its protected
settings, reconnects automatically, and never exposes the Host Secret. A
managed Warren build may provide the Relay URL by default; enrollment still
comes from the service-owned setup invitation.

The installed CLI also provides the short path for sharing one link with
several devices from an already enrolled Host:

```bash
# Create a reusable seven-day link and a protected QR PNG.
warren relay share --qr "$HOME/Desktop/warren-relay-pairing.png"
```

Add `--share` (and optionally `--qr`/`--open`) to `relay connect` when the
operator wants the first setup to end with a shareable iPhone QR.

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
  --name warren-relay \
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

The daemon token in `~/.warren/token` is the canonical Host Secret. The Relay
creates a Host record and one-time enrollment ticket, then enrolls that
existing token; Relay stores only `sha256(Host Secret)`. Re-enrollment or
revocation bumps the Host generation, disconnects the old socket, and
invalidates capabilities from the previous generation.

### Generate a Warren setup URL

On a fresh Relay (or while its first Host is still pending), the Relay prints
an initial setup link at startup. Copy the value after `setup_link=` from
`docker logs` (or the service log) and open it in Warren Desktop on the Host
that should connect. The link provisions the first Host; the Relay generates
its UUID automatically. Once a Host has enrolled, restarts do not create a new
implicit Host; use the service-owned API below for additional Hosts.

The setup link is a bearer credential. Restrict access to the container/service
logs and remove the link from copied logs or chat after enrollment.

```bash
docker logs warren-relay 2>&1 | sed -n 's/.*setup_link=\([^ ]*\).*/\1/p' | tail -n 1
```

Send the printed `warren://settings?...` value to the Host operator. It is a
one-time credential, expires after ten minutes, and should be removed from
shell history or chat after the Host connects. The generated URL always uses
`WARREN_RELAY_PUBLIC_URL`, which must be reachable by the Host.

For additional Hosts, the Relay administrator can call the service-owned API.
The request contains only an optional display name; the Relay still generates
the Host UUID and returns it in `host_id` and `settings_url`:

```bash
curl -fsS -X POST "$WARREN_RELAY_PUBLIC_URL/v1/hosts" \
  -H "Authorization: Bearer $WARREN_RELAY_ADMIN_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"name":"My Mac"}' | jq -er '.settings_url'
```

The production image is distroless and intentionally has no shell, `curl`, or
admin subcommand, so `docker exec warren-relay ...` is not available. The
container command above publishes the Relay port; run the request from the
Docker host with `WARREN_RELAY_PUBLIC_URL=http://127.0.0.1:8080` when that is
the address reachable from the admin shell. The setup link itself continues to
use the public URL configured in the Relay container.

If the admin machine cannot reach a published port, run a one-shot `curl`
helper on the Relay container's network instead of using `docker exec`:

```bash
docker run --rm --network container:warren-relay curlimages/curl:8.12.1 \
  -fsS -X POST http://127.0.0.1:8080/v1/hosts \
  -H "Authorization: Bearer $WARREN_RELAY_ADMIN_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"name":"My Mac"}' \
  | jq -er '.settings_url'
```

The response contains the generated `host_id`, `enrollment_ticket`, the Relay
signing public key, and a canonical `settings_url`. Give that
`warren://settings` link to the Warren Host operator. Opening it in Warren
Desktop consumes the one-time ticket through the local daemon, pins the Relay
key, and starts the connector. The link contains no daemon token and should be
discarded after enrollment; the ticket is valid for ten minutes and cannot be
reused. A managed deployment may use `warren relay connect` with the same link,
but the Host Secret remains inside the daemon.

The daemon stores the Relay URL, Host ID, and signing key in its settings and
opens exactly one outbound `wss://.../v1/host/connect` socket. Control-plane
secrets are stripped from every shell/runtime child process.

Warren only makes outbound WSS connections; with no control plane configured, it still listens on `127.0.0.1` only.

Desktop and other local clients can use the equivalent Headless endpoint
`POST /v1/relay/enroll` with `relayUrl`, `hostId`, and `enrollmentTicket`.
Headless supplies the daemon token itself, validates the returned signing key,
and persists the Relay metadata. This endpoint is intentionally unrelated to
Public Access route settings.

## Pairing, Discovery, and Revocation

The enrolled Host operator normally presses **Share with iPhone** in Warren
Desktop or runs `warren relay share --qr`. The local daemon authenticates to
Relay and returns only an opaque, reusable Web/iOS pairing link. A Relay
administrator can perform the service-owned operation for a Host through the
admin API:

```bash
curl -sS -X POST https://relay.example.com/v1/hosts/<host-uuid>/pairing \
  -H "Authorization: Bearer $WARREN_RELAY_ADMIN_TOKEN"
```

A Host daemon or native client exchanges the code for a seven-day, reusable
Web/iOS pairing link and a short-lived Ed25519 access capability bound to the
Host, scope, route, and generation:

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
