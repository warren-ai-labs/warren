# Warren Relay Service

Warren Relay is an independently deployable remote control plane. It stores Host identity, online presence, and revocation generations, and forwards WebSocket frames; Projects, Workspaces, Sessions, Runtimes, and Terminal output exist only on the Host. Relay never records or parses terminal business frames.

## One-Command Experience

From the repository root:

```bash
mise run relay:dev
```

This command automatically generates a local development secret, starts Relay,
creates a short-lived enrollment key through the admin API, builds and starts
Warren, waits for Headless to claim the Host identity, creates a seven-day
opaque `/invite/<opaque>/` pairing link, and opens the Web/PWA. The generated
Desktop `warren://settings` URL is printed for manual connection as well.
Generated development state is stored in the git-ignored
`.build/relay-dev/8080` directory, and secret files use `0600` permissions. The
local Relay listens on all LAN interfaces by default and writes the Mac's LAN
address into the pairing URL, so phones on the same network as the Mac can
reach it. Use `WARREN_RELAY_DEV_HOST=192.168.1.23` to specify an address
reachable from the phone, or `WARREN_RELAY_DEV_BIND_HOST=192.168.1.23` to
restrict listening to a single interface. This development mode is only
suitable for a trusted LAN; do not expose the port to the public internet.

Daily commands:

```bash
  mise run relay:pair    # create another seven-day shareable link
mise run relay:status  # show Relay and Host status
mise run relay:stop    # stop only the Relay; keep Warren running and terminal sessions alive
```

For a deployed public Relay, the Relay Administrator creates one or more
enrollment keys in the service-owned API and gives a key (or its settings
shortcut) to each Host operator. The operator opens the shortcut in Warren
Desktop, or uses the client shortcut directly:

```bash
curl -fsS -X POST "$WARREN_RELAY_PUBLIC_URL/v1/admin/enrollment-keys" \
  -H "Authorization: Bearer $WARREN_RELAY_ADMIN_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"count":5,"ttl":"24h","max_uses":1,"label":"team hosts"}' \
  | jq -r '.keys[] | [.key, .settings_url] | @tsv'

warren relay connect --url "$WARREN_RELAY_PUBLIC_URL" --key '<enrollment-key>'
warren relay connect '<settings-url>'
```

The settings shortcut only fills the Relay URL and enrollment key; Desktop does
not consume the key until the operator presses **Connect Relay**. Headless then
calls `POST /v1/hosts/claim`, lets Relay allocate the Host ID, and stores the
Host ID and pinned Relay key locally. A daemon can perform the same active step
at startup with `WARREN_RELAY_URL` and `WARREN_RELAY_ENROLLMENT_KEY`.

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
# Enrollment keys default to 24 hours and one Host claim. The administrator
# can override these defaults with Go durations and a bounded use count.
export WARREN_RELAY_ENROLLMENT_KEY_TTL='24h'
export WARREN_RELAY_ENROLLMENT_KEY_MAX_USES='1'
# Optional Live Activity forwarding. Use the production endpoint for App Store
# builds and the sandbox endpoint for development builds.
export WARREN_RELAY_APNS_KEY_ID='XXXXXXXXXX'
export WARREN_RELAY_APNS_TEAM_ID='YYYYYYYYYY'
export WARREN_RELAY_APNS_BUNDLE_ID='com.example.Warren'
export WARREN_RELAY_APNS_PRIVATE_KEY_FILE='/run/secrets/AuthKey_XXXXXXXXXX.p8'
export WARREN_RELAY_APNS_PRODUCTION='true'
go run ./RelayService/cmd/warren-relay
```

The APNs settings are optional. The private key may be supplied inline with
`WARREN_RELAY_APNS_PRIVATE_KEY` instead of the file variable; configure only
one of the two. `WARREN_RELAY_APNS_ENDPOINT` can override the Apple endpoint
for a controlled test service, but it must be an HTTPS origin.

Or build a container:

```bash
docker build -f RelayService/Dockerfile -t warren-relay .
docker run --read-only --tmpfs /tmp -p 127.0.0.1:8080:8080 -v warren-relay-data:/data \
  -e WARREN_RELAY_ADMIN_TOKEN \
  -e WARREN_RELAY_SIGNING_KEY \
  -e WARREN_RELAY_PUBLIC_URL=https://relay.example.com \
  -e WARREN_RELAY_ALLOWED_ORIGIN=https://relay.example.com \
  -e WARREN_RELAY_TUNNEL_BASE_DOMAIN=tunnel.example.com \
  -e WARREN_RELAY_APNS_KEY_ID \
  -e WARREN_RELAY_APNS_TEAM_ID \
  -e WARREN_RELAY_APNS_BUNDLE_ID \
  -e WARREN_RELAY_APNS_PRIVATE_KEY_FILE=/run/secrets/AuthKey_XXXXXXXXXX.p8 \
  -e WARREN_RELAY_APNS_PRODUCTION=true \
  -v /path/to/AuthKey_XXXXXXXXXX.p8:/run/secrets/AuthKey_XXXXXXXXXX.p8:ro \
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
administrator creates short-lived enrollment keys; each key is a 16-letter
`XXXX-XXXX-XXXX-XXXX` code with an expiry and a maximum use count. The Relay
stores only a hash of each key and of each Host Secret. A key is consumed when
Headless claims a Host, and the Relay allocates the Host UUID at that point.
Claim retries with the same Host Secret are idempotent, so a lost response does
not consume another use or create another Host. Re-enrollment or revocation
bumps the Host generation, disconnects the old socket, and invalidates
capabilities from the previous generation.

### Generate enrollment keys

The administrator can create one key or a batch. Defaults are 24 hours and one
use; `ttl` accepts a Go duration and `max_uses` is bounded by the service:

```bash
curl -fsS -X POST "$WARREN_RELAY_PUBLIC_URL/v1/admin/enrollment-keys" \
  -H "Authorization: Bearer $WARREN_RELAY_ADMIN_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"count":5,"ttl":"24h","max_uses":1,"label":"team hosts"}' \
  | jq -r '.keys[] | [.key, .expires_at, .settings_url] | @tsv'
```

The response contains the clear-text key exactly once and a matching
`warren://settings` URL. Treat both as bearer credentials. The settings URL
only fills Desktop's Relay URL and key fields; it does not consume the key
until the operator presses **Connect Relay**.

The production image is distroless and intentionally has no shell, `curl`, or
admin subcommand, so `docker exec warren-relay ...` is not available. Publish
the Relay port and run the request from the Docker host (or a one-shot helper
on the Relay network):

```bash
docker run --rm --network container:warren-relay curlimages/curl:8.12.1 \
  -fsS -X POST http://127.0.0.1:8080/v1/admin/enrollment-keys \
  -H "Authorization: Bearer $WARREN_RELAY_ADMIN_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"count":1}' \
  | jq -r '.keys[0] | [.key, .settings_url] | @tsv'
```

Give the key or settings URL to the Host operator. Headless actively claims the
Host and pins the Relay signing key:

```bash
WARREN_RELAY_URL="$WARREN_RELAY_PUBLIC_URL" \
WARREN_RELAY_ENROLLMENT_KEY='<enrollment-key>' \
warren-headless
```

The client-side equivalent is:

```bash
warren relay connect --url "$WARREN_RELAY_PUBLIC_URL" --key '<enrollment-key>'
warren relay connect '<settings-url>'
```

Headless supplies the daemon token itself; the Relay administrator token never
enters Desktop, CLI, or a `warren://settings` URL.

The daemon stores the Relay URL, Host ID, and signing key in its settings and
opens exactly one outbound `wss://.../v1/host/connect` socket. Control-plane
secrets are stripped from every shell/runtime child process.

Warren only makes outbound WSS connections; with no control plane configured, it still listens on `127.0.0.1` only.

### Live Activity push forwarding

The iOS Dynamic Island Live Activity is a separate delivery path from Relay
WebSocket keep-alive. iOS registers its ActivityKit push token at
`POST /h/<host-id>/v1/live-activities`; the Host publishes bounded Session
snapshots at `POST /v1/hosts/<host-id>/live-activities` with the Host Secret;
Relay then forwards those snapshots to APNs. Relay does not parse BRLY/2
terminal frames, and an Activity never grants an indefinite background
WebSocket.

Desktop and other local clients use the token-protected Headless endpoint
`POST /v1/relay/join` with `relayUrl` and `enrollmentKey`. Headless calls the
Relay claim endpoint, validates the returned signing key, persists the Relay
metadata, and starts the outbound connector. This endpoint is intentionally
unrelated to Public Access route settings.

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
- Enrollment keys are short-lived and bounded by their configured use count.
  Pairing codes and client pairing links are reusable for their configured
  seven-day sharing window.
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
