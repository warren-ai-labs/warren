# RFC 0019: LAN Host Discovery, Host-Armed Pairing, and Multi-Network Routing

- Status: Draft
- Implementation: Implemented across Headless, Transport, Desktop, and iOS
- Owner: Warren Headless, Desktop, Transport, and iOS
- Created: 2026-09-08
- Scope: mDNS/DNS-SD discovery, stable Host identity, endpoint aggregation, explicit
  iOS pairing, and opt-in Direct LAN routing
- Protocol baseline: Warren protocol 4.0
- Depends on: RFC 0003, RFC 0009, RFC 0018, and the Headless and Remote Connection Architecture

## 1. Summary

Warren treats a Host as a durable identity rather than as one ip:port tuple.
The Headless daemon advertises that identity on the local network. iOS discovers
all reachable paths, groups paths with the same host_id, and presents one Host
in the first-level Hosts list. A Host's Direct LAN addresses, Relay route, active
path, and fastest path are shown only in that Host's second-level connection menu.

Pairing is deliberately Host-controlled:

1. Pairing is off by default.
2. The owner opens a temporary 60-second window in Desktop Settings → LAN Pairing.
3. The Host displays a six-digit PIN only for that window.
4. iOS enters the PIN once and stores the returned scoped token in Keychain.
5. The window closes automatically; it is never opened by discovery.

Direct LAN auto-routing is a separate iOS preference. Discovery and path health
are always visible. Only when lanAutoRoutingEnabled is enabled may iOS
automatically promote a healthy Direct LAN path or fall back to another route.
Manual path selection remains available in either mode.

## 2. Goals and non-goals

### Goals

- Find a Warren Host without asking the user to maintain a stale LAN address.
- Preserve one logical Host while its addresses change between home, office,
  tethered, and other networks.
- Make every candidate path observable, including latency, reachability, active
  method, and the current best path.
- Require an explicit action on the Host before a new iOS device can pair.
- Keep owner credentials separate from scoped paired-client credentials.
- Keep LAN discovery unobtrusive: the iOS affordance belongs at the bottom of
  the Hosts page, not over the active dashboard.

### Non-goals

- Discovery is not trust. Seeing an mDNS record never grants access.
- Pairing is not a general device-management or Relay-revocation UI.
- This RFC does not define a CLI approval command or a Desktop alert. The
  implemented approval surface is Desktop Settings.
- The PIN is not a replacement for transport encryption. Deployments that need
  confidentiality must use an appropriate TLS or trusted local-network setup.

## 3. Host identity and endpoint model

### 3.1 Stable Host identity

Each Host has a persistent host_id. It is the key used by iOS persistence,
Keychain entries, discovery aggregation, and route selection. A Host may move
between networks without changing this identity.

An endpoint is only a path to that Host. Examples include:

    http://192.168.1.117:8789   Direct LAN
    http://10.23.138.54:8789    Direct LAN
    Relay route                  Relay

The two Direct LAN URLs above are not two Hosts. They are two paths belonging to
one Host. iOS therefore:

- merges discovery records with the same host_id;
- keeps all distinct ip:port candidates under that Host;
- stores and displays the Host name at the top level;
- shows endpoint details in the second-level connection menu;
- avoids creating duplicate Host rows when a daemon advertises multiple
  interfaces or when a saved endpoint and a newly discovered endpoint overlap.

### 3.2 Candidate state

Each candidate keeps its URL, source/method, reachability, observed latency, and
last successful time. iOS probes all discovered candidates for display and marks
the lowest-latency healthy candidate as Best. A candidate must match the
expected host_id; a responsive service with another identity is not accepted
as a path for this Host.

WarrenRemoteEndpointConfiguration.lanAutoRoutingEnabled is persisted per Host
and defaults to false for older configurations. It controls automatic route
changes only; it does not hide candidates or prevent an explicit user selection.

## 4. Host discovery

### 4.1 DNS-SD service

The Headless daemon publishes:

- Service type: _warren._tcp
- Domain: local.
- Port: the Warren HTTP/WebSocket listener (normally 8789)
- Instance: <host name> (<host id prefix>)

The mDNS record contains routing metadata only. It never contains a Host token,
a paired-client token, a workspace path, or any other secret.

### 4.2 TXT schema

| Key | Example | Meaning |
| --- | --- | --- |
| txtvers | 1 | TXT schema version |
| id | b79b2d8c-e8fd-438b-9e52-60e881c3cffb | Stable host_id |
| name | Songjian's MacBook Pro | Host display name |
| ver | 4.0 | Warren protocol version |
| build | development | Host build label |
| tls | 0 | Whether the advertised listener uses TLS |
| pair | 0 or 1 | Whether the explicit pairing window is currently open |
| cand, cand.1, cand.2, … | 10.23.138.54:8789,192.168.1.117:8789 | Normalized candidates, split across numbered TXT keys when needed |

Each candidate TXT item, including its key and `=`, is at most 255 bytes as
required by DNS-SD. The receiver concatenates `cand`, `cand.1`, `cand.2`, and
later numbered keys in numeric order before parsing the comma-separated
endpoints. Older clients that only understand `cand` still receive the first
chunk and remain backward compatible.

Headless omits loopback, point-to-point, link-local, unspecified, and multicast
addresses from the candidate set. This keeps VPN tunnel and non-routable
interface addresses out of the LAN advertisement while retaining routable
addresses from active interfaces.

The pair value is dynamic. It is 0 after daemon startup and after the 60-second
window expires. Changing the value does not require restarting the mDNS
responder.

### 4.3 Candidate probing

Discovery supplies candidate URLs; it does not authenticate the client. iOS
probes candidates concurrently, records latency and status, and verifies the
returned Host identity before accepting a candidate. The probe result is used
for display and, when the per-Host auto-routing preference is enabled, route
promotion.

## 5. iOS product surface

### 5.1 Hosts page affordance

The Explore in LAN control is a small floating capsule at the bottom of the
Hosts page. It is not placed at the top of the dashboard and does not cover
session or Host information. While discovery is running the capsule has a
subtle pulse; it reports the number of nearby Hosts when results are available.

The empty/help state tells the user exactly where pairing is enabled:

    Desktop Settings → LAN Pairing

It also explains that discovery is informational until the Host owner opens the
temporary window.

### 5.2 Host hierarchy and route menu

The first-level list contains one row per logical Host. Selecting a row opens a
second-level menu for that Host. The menu shows:

- every Direct LAN ip:port candidate;
- Relay, when configured;
- the currently active method and endpoint;
- the measured Best candidate;
- manual actions to use a candidate;
- the independent Automatically switch to Direct LAN toggle.

The current method is visible in both the Host detail view and the route menu.
The Host detail view keeps the first endpoint as its compact summary; opening
the route menu is the place to inspect all paths.

### 5.3 Pairing sheet

An unknown discovered Host has a Pair this Host action in its second-level
menu. The sheet accepts exactly six digits, explains the Desktop Settings flow,
and reports an error without exposing or asking for the Host token. On success
the iOS client stores the scoped token in Keychain and adds the discovered
endpoint under the existing host_id.

## 6. Pairing protocol

### 6.1 Host-side state

The pairing window is held in daemon memory and is not restored after restart.
Opening it generates a fresh six-digit PIN and an expiry 60 seconds in the
future. The PIN is not persisted. Paired-client records persist only:

- client_id;
- optional client name;
- creation time;
- SHA-256 hash of the issued token.

The plaintext token is returned exactly once to iOS and is stored in iOS
Keychain. Pairing the same client_id again replaces its previous token hash.

### 6.2 Owner control

An owner-authenticated Desktop connection uses these WebSocket RPC methods:

| Method | Result |
| --- | --- |
| pairing.enable | Opens a fresh window and returns enabled, pin, expiresAt, and expiresIn |
| pairing.status | Returns the current window projection |
| pairing.disable | Closes the window and returns a disabled projection |

The same operations are available to an owner with the authenticated HTTP
endpoints POST /v1/pairing/enable, GET /v1/pairing/status, and
POST /v1/pairing/disable. Desktop uses the WebSocket RPC surface. No
discovery event, iOS button, or unauthenticated request can open the window.

### 6.3 iOS exchange

While the window is open, iOS sends an unauthenticated request to the candidate
endpoint:

    POST /v1/pairing/request
    Content-Type: application/json

    {
      "host_id": "b79b2d8c-e8fd-438b-9e52-60e881c3cffb",
      "client_id": "9A7F11C2-814E-43B0-8C71-987B2E3F10A2",
      "client_name": "Songjian's iPhone",
      "pin": "492810"
    }

The Host accepts the request only when:

- the request has the required fields and a six-digit numeric PIN;
- host_id matches the local Host identity;
- the temporary window is still open;
- the PIN matches the in-memory PIN.

On success it returns a one-time response:

    {
      "paired": true,
      "host_id": "b79b2d8c-e8fd-438b-9e52-60e881c3cffb",
      "client_id": "9A7F11C2-814E-43B0-8C71-987B2E3F10A2",
      "token": "<scoped bearer token>"
    }

The response is never advertised over mDNS. The iOS client writes token to
Keychain and authenticates later WebSocket sessions with that scoped bearer.

### 6.4 Access boundaries

The static Host token remains the owner credential. A paired token can use the
interactive Host surface, but cannot mutate owner settings, public-access
configuration, or Relay management. This separation prevents a pairing from
silently becoming an owner login.

## 7. Routing behavior

Discovery and health observation are independent from automatic route changes:

| lanAutoRoutingEnabled | Probe/display candidates | Automatically promote Direct LAN | Automatically fall back |
| --- | --- | --- | --- |
| false | Yes | No | No |
| true | Yes | Yes | Yes |

When the toggle is off, iOS keeps the user's current route even if a faster LAN
candidate appears, while still showing the candidate and its health. Selecting
a route manually is always allowed. Relay remains a normal explicit route and
may be used when no Direct LAN candidate is healthy.

## 8. Security and lifecycle invariants

1. **No secret in multicast.** mDNS contains identity and routing metadata only.
2. **Pairing defaults closed.** Daemon startup and expiry leave pair=0.
3. **Host authority.** Only an owner-authenticated Desktop/HTTP/WebSocket call
   can open or close the pairing window.
4. **Bounded exposure.** The PIN window lasts 60 seconds and a fresh PIN is
   generated each time it is opened.
5. **Scoped credentials.** iOS receives a client token, never the static Host
   token; only its hash is persisted on the Host.
6. **Identity check.** A candidate must report the expected host_id; a
   reachable but different daemon is rejected.
7. **No implicit routing changes.** The LAN auto-routing preference is explicit,
   per Host, and independent of route preference or pairing.
8. **Keychain storage.** iOS does not persist the paired token in endpoint JSON
   or UserDefaults.

## 9. Verification

The implementation is verified by:

- Go tests for discovery, pairing HTTP/RPC behavior, and the Headless command;
- Transport tests for endpoint identity, path aggregation, and pairing exchange;
- WarrenIOS tests for persistence, pairing UI flow, discovery, and route policy;
- WarrenDesktop tests for settings/deep-link compatibility;
- a macOS build of the application target to verify the Desktop settings wiring.

## 10. Follow-up work

- Add a dedicated paired-client management view when Host-side revocation and
  audit requirements are defined.
- Add a transport-level TLS setup flow for deployments where the local network
  cannot be trusted.
- Continue measuring candidate quality across VPN, USB, and tethered interfaces.
