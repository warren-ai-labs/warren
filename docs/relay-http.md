# Using an HTTP Relay

Warren supports an HTTP Relay for trusted-network development and private
self-hosting. This mode is deliberately opt-in. Use HTTPS/WSS for any Relay
that is reachable from an untrusted network or the public Internet.

## Security boundary

With an HTTP Relay, the client-to-Relay control requests and WebSocket frames
are plaintext. The enrolled Host also connects to the Relay with `ws://`
instead of `wss://`. A network observer can read pairing exchanges, access
capabilities, terminal input, and terminal output. HTTP does not become safe
because a pairing link expires; the default link is a seven-day bearer
credential and can be reused by multiple devices.

Use HTTP only when all of the following are true:

- the Relay is bound to a trusted LAN or private network;
- the Relay port is not forwarded from the public Internet;
- administrator tokens, Host Secrets, signing keys, and pairing links stay
  private; and
- the deployment owner accepts that the network path is not encrypted.

Do not use `NSAllowsArbitraryLoads` to make every iOS request insecure. For an
iOS development build, allow only the exact Relay hostname in the app's
`Info.plist` (see [iOS](#ios)).

## Start the Relay

Keep the Relay listener private when a reverse proxy or private network
boundary is available:

```bash
export WARREN_RELAY_LISTEN='127.0.0.1:8787'
export WARREN_RELAY_PUBLIC_URL='http://relay.example.test'
export WARREN_RELAY_ALLOWED_ORIGIN='http://relay.example.test'
export WARREN_RELAY_ADMIN_TOKEN='replace-with-a-random-admin-token'
export WARREN_RELAY_SIGNING_KEY='replace-with-at-least-32-random-bytes'
export WARREN_RELAY_DATA='./data/registry.json'

go run ./RelayService/cmd/warren-relay
```

For a trusted LAN without a reverse proxy, bind the listener to the LAN
interface and include the port in both URLs. Prefer a private DNS name over a
numeric address so the endpoint can be changed without replacing every
client configuration:

```bash
export WARREN_RELAY_LISTEN='192.0.2.10:8787'
export WARREN_RELAY_PUBLIC_URL='http://relay.lan.example:8787'
export WARREN_RELAY_ALLOWED_ORIGIN='http://relay.lan.example:8787'
```

The hostname in `WARREN_RELAY_ALLOWED_ORIGIN` must match the browser origin,
including the scheme and port. Do not put credentials in these URLs.

If the Relay runs behind a reverse proxy, keep the upstream HTTP and expose
only the proxy's private or HTTPS endpoint. The proxy must forward HTTP and
WebSocket upgrades without rewriting the host-scoped paths.

## Enroll a Host

The daemon token in `~/.warren/token` is the Host Secret. A Relay administrator
creates short-lived enrollment keys; each is a 16-letter
`XXXX-XXXX-XXXX-XXXX` bearer code with an expiry and maximum use count. The
Relay allocates the Host UUID when Headless claims a key and stores only hashes.

```bash
curl -sS -X POST "$WARREN_RELAY_PUBLIC_URL/v1/admin/enrollment-keys" \
  -H "Authorization: Bearer $WARREN_RELAY_ADMIN_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"count":5,"ttl":"24h","max_uses":1,"label":"LAN hosts"}' \
  | jq -r '.keys[] | [.key, .settings_url] | @tsv'
```

Give a key or its `warren://settings` shortcut to the Host operator. The
shortcut only prefills Desktop's Relay URL and key fields; the key is consumed
when **Connect Relay** is pressed. Headless then calls the Relay claim endpoint
and pins the signing key. The CLI has the same client-side shortcut:

```bash
warren relay connect --url "$WARREN_RELAY_PUBLIC_URL" --key '<enrollment-key>'
warren relay connect '<settings-url>'
```

For a headless-only install, set the two startup values:

```bash
WARREN_RELAY_URL="$WARREN_RELAY_PUBLIC_URL" \
WARREN_RELAY_ENROLLMENT_KEY='<enrollment-key>' \
warren-headless
```

Enrollment keys expire and are limited by their configured use count. Remove
keys and settings shortcuts from shell history, chat, and copied logs after
use.

## Pair a client

On an enrolled Host, press **Share with iPhone** in Warren Desktop or run the
client-side shortcut:

```bash
warren relay share --qr --open
```

The daemon keeps the Host Secret and pairing code internal. The resulting
`pairing_url` is the value to open in a browser or encode in a QR code. It has
the form `/invite/<opaque>/` and does not disclose the Host ID. A QR code must
contain this Web pairing URL, not a `warren://settings` enrollment link:

```bash
printf '%s' "$pairing_url" \
  | qrencode -o warren-relay-pairing.png -
```

Pairing codes and Web tickets are reusable for the configured sharing window
(seven days by default), so the same link or QR image can provision multiple
devices. Generating a new pairing code replaces the old one. Re-enrolling or
revoking the Host invalidates existing links. Treat the link as a bearer
credential and protect it accordingly.

## iOS

The released iOS app follows App Transport Security and therefore rejects an
arbitrary public `http://` Relay. An app built from source for a trusted HTTP
Relay needs a hostname-specific exception in its own `Info.plist`:

```xml
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsLocalNetworking</key>
    <true/>
    <key>NSExceptionDomains</key>
    <dict>
        <key>relay.example.test</key>
        <dict>
            <key>NSExceptionAllowsInsecureHTTPLoads</key>
            <true/>
            <key>NSIncludesSubdomains</key>
            <false/>
        </dict>
    </dict>
</dict>
```

Use the exact hostname used in the Relay URL. A stable private DNS name is
preferable to an IP literal because the exception and client configuration do
not have to change when the address changes. Keep this exception in a private
development build; do not add a real deployment hostname, ticket, or Host
Secret to a public source tree.

The Warren iOS pairing screen accepts the `web_url` by QR scan or paste. The
same shareable link can be exchanged by multiple devices until it expires. Each
exchange stores only a scoped capability and Relay metadata; the app does not
need the Host Secret. Access capabilities remain short-lived and refresh
through an HttpOnly cookie.

## Troubleshooting

- **“The app must use secure connections.”** The URL is HTTP and the iOS build
  has no matching `NSExceptionDomains` entry. Use an HTTPS Relay, or rebuild a
  private development app with the exact hostname exception above.
- **Pairing succeeds but the client cannot connect.** Confirm that the Relay
  URL and `WARREN_RELAY_ALLOWED_ORIGIN` use the same scheme, hostname, and
  port, and that the proxy forwards WebSocket upgrades.
- **A ticket is rejected as expired.** Pairing codes and Web tickets are
  reusable only within their configured sharing window. Generate a fresh
  pairing code and QR image after that window, or when you intentionally want
  to rotate the old link.
- **A direct HTTP deployment leaks its address.** Move the Relay behind a
  private DNS name and an HTTPS reverse proxy, or keep it reachable only on a
  trusted network. Do not publish the numeric address in documentation,
  screenshots, issue reports, or setup links.
