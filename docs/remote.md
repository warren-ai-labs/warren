# Remote access with Bolthole

Warren reaches a Host from anywhere through a [Bolthole](https://github.com/abcdlsj/bolthole)
relay. The relay is a stateless forwarder: the client and the Host run a
Noise handshake keyed by a connect code only they hold, so the relay sees
ciphertext and stores nothing. It can run on Cloudflare Workers (free plan),
as a single binary, or not at all when the client is on the Host's network.

This replaces the enrollment-based [Warren Relay](relay.md), which is kept
only until every client has moved to remote access.

## How it fits together

```
phone ──WSS /c/<token>/.bolthole/e2e──▶ relay ◀──WSS /v1/agent── Host (warren-headless)
phone ──WS  ws://<lan-ip>:8789/.bolthole/e2e ─────────────────▶ Host   (direct, same handshake)
        └──── Noise_NNpsk0 end-to-end session ────┘
              └── `ws` stream /v1/ws  → the normal Warren protocol
              └── `http` streams      → the Host's HTTP API (pairing)
```

- **Connect code**: 32 random bytes in `~/.warren/remote.code` (0600). The
  connection string is the relay URL with the code in its `#fragment`, which
  never reaches a server.
- **Device authorization stays on the Host.** Holding the code only opens an
  encrypted session; `/v1/ws` still requires a paired-client token, exactly as
  on the LAN. Each device is its own entry in `pairedClients` and can be
  revoked alone.
- **LAN and relay are interchangeable.** The Host serves the same E2E entry
  point on its own listener and advertises those addresses inside the
  encrypted hello. Clients race them against the relay, move to a direct path
  when one answers, and fall back to the relay when it stops.

## Using it

```bash
warren remote enable                 # connect to the official relay
warren remote enable --relay https://relay.example.com   # or your own
warren remote enable --relay default # drop a self-hosted relay, back to the official one
warren remote share                  # link + terminal QR, pairs devices for 10 minutes
warren remote status                 # relay, its source, and remote device count
warren remote rotate                 # new code; forgets remotely paired devices
warren remote disable                # stop the relay connection (LAN keeps working)
```

`remote status` reports `RELAY SOURCE` as `default` (the build's relay) or
`self-hosted` (a URL this Host carries), so nobody has to remember which one
it is on. The relay a Host carries is remembered across restarts; `--relay
default` is the way back, and `remote enable` with no `--relay` keeps using
the remembered one.

`remote share` requires remote access to be on and refuses with a pointer to
`remote enable` otherwise: the link it prints reaches the Host through the
relay it names, so handing one out while the relay connection is down would
look like a broken Host. Each share lasts 10 minutes.

`remote share` opens a 10-minute pairing window. Every device that scans the
link in that window exchanges its invite for its own token at
`POST /v1/pairing/request` (`{"host_id","client_id","client_name","invite"}`),
over the encrypted session. A remotely paired device has owner authority,
like a Relay invite had; LAN PIN pairings stay non-owner.

The link's fragment carries `k` (connect code), `host` (Host ID), `invite`
and `name`. Treat it like a password until it expires.

## Host API

All endpoints require the Host owner token. Desktop uses the WebSocket
methods of the same names.

| HTTP | WebSocket | Purpose |
| --- | --- | --- |
| `GET /v1/remote` | `remote.status` | State, relay, number of remote devices |
| `POST /v1/remote/enable` `{"relayUrl"?}` | `remote.enable` | Connect to a relay (default: the build's) |
| `POST /v1/remote/disable` | `remote.disable` | Disconnect from the relay |
| `POST /v1/remote/share` `{"relayUrl"?}` | `remote.share` | Open a pairing window and return the link |
| `POST /v1/remote/rotate` | `remote.rotate` | Replace the code, revoke remote devices, cut live sessions |

`/healthz` reports the relay connection under `status.remote`. `GET /v1/remote`
and `remote.status` also carry `relaySource` (`default` or `self-hosted`) next
to `relayURL`, `configuredRelayURL` and `defaultRelayURL`.

The default relay is `https://bolthole.warrenai.xyz`. A release build can
change it with `-ldflags "-X main.defaultRemoteRelayURL=https://…"`, and a
single Host can override it with `--remote-relay-url` /
`WARREN_REMOTE_RELAY_URL` or with `warren remote enable --relay URL`.

## Running your own relay

The official relay is the default because it needs no operator: enable remote
access and share a Host. Run your own when that is worth the extra step —
keeping transcripts off someone else's relay, pinning the Durable Object
region near the Host, or putting the relay on your own domain.

```bash
# Cloudflare Workers, free plan
npx wrangler deploy            # from the bolthole repository or fork
npx wrangler secret put BOLTHOLE_KEYS        # optional: gate who may register

# On the Host that will use it
warren remote enable --relay https://relay.example.com
```

Set `LOCATION_HINT` (`apac`, `enam`, `weur`, …) in the Worker's
`wrangler.jsonc` to keep the agent's Durable Object in one region instead of
near whoever connects first. A single Go binary (`bolthole serve --addr`) or
the Docker compose file in bolthole's `deploy/` works the same way behind any
TLS proxy.

A relay that gates enrollment (Cloudflare `BOLTHOLE_KEYS`, or
`BOLTHOLE_JWT_SECRET` plus a token from `bolthole token`) needs the matching
credential on the Host: `--remote-relay-key` or `WARREN_REMOTE_RELAY_KEY`.
It is a bearer credential, so keep it in the environment rather than in
`settings.json`, and never paste it into a share link, a log, or a ticket.
