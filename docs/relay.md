# Remote access with Warren Relay

Warren Relay is how a phone or browser reaches a Warren Host that is not on the
same network. The Host keeps every Project, Workspace, Session, and Agent;
Relay only stores Host identity, presence, and revocation state, and forwards
WebSocket frames. This guide covers the day-to-day flow. For the control-plane
HTTP API see [relay-http.md](relay-http.md); for deploying a Relay see
[../RelayService/README.md](../RelayService/README.md).

## Two routes, one Host

A paired client can reach a Host two ways. Both are configured on the same
endpoint, and **Connection methods** in the app shows which one is active.

| Route | When it works | Notes |
| --- | --- | --- |
| Direct LAN | Phone and Mac on the same network | Fastest. Its identity is the Host's own `host_id` from `/healthz`. |
| Relay | Anywhere | Depends on the Relay being reachable. Its identity is the Relay's host record id, which the Relay assigns at enrollment. |

Turn on **Automatically switch to Direct LAN** if you want a client to promote
the LAN route whenever a verified local address answers; otherwise pick a route
by hand in **Connection methods**.

## Enroll a Host

### Issue keys (Relay administrator)

The administrator mints enrollment keys in batches. Each key is a 16-letter
`XXXX-XXXX-XXXX-XXXX` code with a bounded lifetime and use count. The response
carries a `warren://settings` shortcut holding only the Relay URL and the key:

```bash
curl -fsS -X POST "$WARREN_RELAY_PUBLIC_URL/v1/admin/enrollment-keys" \
  -H "Authorization: Bearer $WARREN_RELAY_ADMIN_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"count":5,"ttl":"24h","max_uses":1,"label":"developer laptops"}' \
  | jq -r '.keys[] | [.key, .settings_url] | @tsv'
```

Enrollment keys are bearer credentials. Share one only with the intended Host
operator, and clear it from shell history, chat, and copied logs after use.

### Consume a key (Host operator)

An enrollment key is short-lived and bounded-use. The Host operator consumes it
once:

```bash
warren relay connect --url "$WARREN_RELAY_PUBLIC_URL" --key '<enrollment-key>'
warren relay connect '<warren://settings?...>'   # same thing from a settings link
```

In Warren Desktop the same step is **Settings → Relay → Connect Relay**.
Headless can do it unattended at startup with `WARREN_RELAY_URL` and
`WARREN_RELAY_ENROLLMENT_KEY`. The daemon calls `POST /v1/hosts/claim`; the
Relay allocates the Host id and the daemon stores that id plus the Host
credential locally. Nothing about the Relay is ever written into a client's
endpoint catalog by enrollment.

Check that the Host came online:

```bash
curl -fsS "$WARREN_HOST_URL/healthz" | jq '.status.relay'
# {"configured":true,"connected":true,"state":"connected","lastError":""}
```

`state` is `connected` while the Host's WebSocket to the Relay is open and
`disconnected` while the connector retries; a non-empty `lastError` names the
last transport failure (for example a broken pipe after an idle drop) without
meaning the Host gave up.

## Pair a device

Pairing hands the client an **opaque, reusable invite link**. It never contains
the Host id, so a shared QR code does not disclose which Host record it belongs
to.

```bash
warren relay share --qr --open                    # 7-day link + QR PNG + browser
warren relay share --qr "$HOME/Desktop/warren.png"
```

On the phone: **Add Host → Scan QR code**, or copy the link and use the paste
action in the same sheet. In a browser the invite page exchanges the invite on
load and scrubs it from the URL.

Each invite can be exchanged by more than one device until it expires.
Generating a new one rotates the pairing code, so the previous link stops
working; re-enrolling or revoking the Host invalidates every link and access
capability at once. Treat a link or QR image as a bearer credential.

## Self-host a Relay

Relay is a separate Go service and can run next to the Host or on a small
server behind TLS:

```bash
# Local development: starts Relay, enrolls this Mac, and prints a pairing link.
mise run relay:dev

# A deployed Relay (see RelayService/README.md for TLS, signing key, and proxy).
go run ./RelayService/cmd/warren-relay
```

Point a Host or the development helper at a deployed Relay with
`WARREN_RELAY_URL=https://relay.example.com`. Clients only need the Relay URL
the Host enrolled with; enrollment keys never reach them.

## Troubleshooting

Ordered by what actually fails, most common first:

1. **Relay unreachable from the phone.** Open `https://<relay>/healthz` on the
   phone. On iOS an `http://` Relay is rejected by App Transport Security
   unless the build carries a hostname exception — use HTTPS.
2. **Host not connected.** `GET /healthz` on the Host and read
   `status.relay`. `configured: false` means no enrollment; `connected: false`
   with a `lastError` means the Host cannot reach the Relay (DNS, TLS, firewall,
   or a proxy that drops WebSocket upgrades).
3. **A device cannot connect although the Host is online.** Re-pair it. A
   rotated invite, a revoked device family, or an expired capability all
   surface as an authentication failure; a fresh invite from
   `warren relay share` is the fix. Nothing needs to be restarted.
4. **A pairing link is rejected as expired.** Links live for the configured
   sharing window (seven days by default). Generate a new one.
5. **Wrong route is in use.** In the app open **Connection methods** and check
   which path is active, then switch or enable automatic LAN routing. A client
   pinned to `Relay only` will not fall back to LAN on its own.

## Review and revoke access

```bash
# Devices the Relay currently knows for a Host.
curl -fsS "$RELAY/v1/hosts/$HOST_ID/devices" -H "Authorization: Bearer $HOST_TOKEN" | jq

# Revoke one device family.
curl -fsS -X DELETE "$RELAY/v1/hosts/$HOST_ID/devices/$DEVICE_ID" \
  -H "Authorization: Bearer $HOST_TOKEN"

# Revoke the Host itself (Relay admin credential).
curl -fsS -X DELETE "$RELAY/v1/hosts/$HOST_ID" \
  -H "Authorization: Bearer $WARREN_RELAY_ADMIN_TOKEN"
```

Revoking a device invalidates that family's refresh capability; revoking the
Host invalidates every device and every outstanding invite. The Host Secret
never leaves the daemon, and access capabilities stay short-lived and rotate
through a refresh capability.
