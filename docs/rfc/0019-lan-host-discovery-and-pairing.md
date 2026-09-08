# RFC 0019: LAN Host Auto-Discovery, Zero-Trust Mutual Pairing, and Multi-Network Mobility

- Status: Draft
- Owner: Warren Desktop, Headless Server, and iOS
- Created: 2026-09-08
- Scope: local network Host discovery (mDNS/Bonjour), multi-interface candidate racing (ICE-lite), iOS "Explore in LAN" HUD button, and zero-trust mutual pairing across Desktop and Headless CLI
- Protocol baseline: Warren protocol 4.0
- Depends on: [RFC 0003](0003-terminal-groups.md), [RFC 0009](0009-own-relay-and-public-tunnel.md), [RFC 0018](0018-multi-host-sidebar-projects.md), and the [Headless and Remote Connection Architecture](../headless-architecture.md)

---

## 1. Executive Summary

Warren enables developers to run remote and local AI agent execution environments across macOS Desktop, headless Linux servers, and the iOS companion client. In real-world development workflows, laptops and mobile devices are highly nomadic: developers regularly transition between office Wi-Fi, home networks, coffee shop hotspots, mobile cellular tethering, and direct USB tethering.

Under static endpoint configurations, changing network interfaces breaks client connectivity. When a Mac moves from a home network (`192.168.1.x`) to an office intranet (`10.23.x.x`), the iOS companion client stalls in a `reconnecting` loop because the target IP address is stale. Manual reconfiguration on mobile devices is cumbersome and error-prone.

This RFC defines a complete, zero-configuration local networking architecture for Warren:
1. **Host Advertisement via mDNS / DNS-SD (Bonjour)**: Headless and Desktop daemons announce their presence, stable `host_id`, human-readable alias, Warren protocol version, and network interface candidates on the local link (`_warren._tcp`).
2. **Multi-Network Mobility & Candidate Racing (ICE-lite)**: Clients decouple Host identity from ephemeral IP:port tuples. When connecting or roaming, clients execute lightweight concurrent candidate racing across all known network paths (USB-mux / link-local, Wi-Fi LAN IP, hotspot IP, and fallback Relay tunnels), automatically latching onto the fastest, healthiest path.
3. **iOS "Explore in LAN" Floating Capsule Button**: An intuitive floating pill/capsule button rendered above the canvas, signaling nearby discovered Warren hosts with a single-tap discovery sheet.
4. **Zero-Trust Mutual Pairing & Token Exchange**: In untrusted shared environments (e.g., public Wi-Fi), hosts never expose unauthenticated tokens or accept unauthorized clients. Instead, clients initiate an out-of-band pairing request with a 6-digit Short Authentication String (SAS / PIN code). Pairing can be authorized via a **Desktop native approval dialog** or a **Headless CLI command** (`warren host pair approve <pin>`), minting a cryptographically verified, scoped client token stored in the iOS Keychain.

---

## 2. Motivation and Problem Statement

### 2.1 The Nomad Developer and Stale Endpoint Problem

Developers frequently switch physical network environments:
- **Office / Intranet**: `10.23.138.54:8789` (NAT / Enterprise subnet with client isolation)
- **Home Wi-Fi**: `192.168.1.117:8789` (Flat subnet)
- **Personal Hotspot**: `172.20.10.2:8789` (Direct peer-to-peer / cellular routing)
- **USB Cable**: `127.0.0.1` via `usbmuxd` tunnel or `169.254.x.x` Link-Local Ethernet

When the iOS client stores a static URL (e.g., `http://192.168.1.117:8789`), moving to the office immediately produces a connection failure:
```text
TCP SYN -> 192.168.1.117:8789 (Destination Unreachable / Timeout)
Client state: [reconnecting (attempt 14, backoff 30s)]
```
Even if the user injects a new IP during compilation or edits settings, the next network hop breaks it again.

### 2.2 Security Invariants in Public Subnets

Local network broadcast must not degrade Warren's zero-trust security model:
- The Host daemon must never broadcast its root secret or master bearer token over mDNS.
- A rogue machine on public Wi-Fi must not be able to connect to a Warren Host or execute terminal commands without explicit user authorization on the Host machine.
- Token exchange must require human-in-the-loop mutual consent (out-of-band verification).

### 2.3 Headless vs Desktop Disparity

A developer may run Warren Desktop on macOS (where UI prompts and system notifications are natural) or run `warren-headless` on a headless Linux box / Mac mini via SSH or systemd (where no GUI exists). The pairing approval protocol must seamlessly support both GUI popups and CLI commands without architectural divergence.

---

## 3. Architecture & Core Concepts

```text
┌─────────────────────────────────────────────────────────────┐
│                       Warren Host                           │
│  (Desktop or Headless CLI: macOS / Linux)                    │
│                                                             │
│  ┌──────────────────────────────┐                           │
│  │   Bonjour / mDNS Announcer   │                           │
│  │   _warren._tcp. local.       │                           │
│  │   TXT: host_id, name, cand   │                           │
│  └──────────────┬───────────────┘                           │
│                 │                                           │
│  ┌──────────────┴───────────────┐  Pairing Approval         │
│  │   Pairing & Auth Service     │◄───────────────────────── │
│  │   - Desktop: NSAlert dialog  │   [Desktop Dialog]        │
│  │   - Headless: CLI command    │   or [warren host pair]   │
│  └──────────────┬───────────────┘                           │
└─────────────────┼───────────────────────────────────────────┘
                  │ mDNS Multicast / Candidate Probes
                  ▼
┌─────────────────────────────────────────────────────────────┐
│                    iOS Companion Client                     │
│                                                             │
│  ┌──────────────────────────────┐                           │
│  │  NWBrowser / Discovery Engine│                           │
│  │  Listens for _warren._tcp    │                           │
│  └──────────────┬───────────────┘                           │
│                 ▼                                           │
│  ┌──────────────────────────────┐                           │
│  │ Candidate Address Racer      │                           │
│  │ (USB Link -> LAN -> Relay)   │                           │
│  └──────────────┬───────────────┘                           │
│                 ▼                                           │
│  ┌──────────────────────────────┐                           │
│  │ "Explore in LAN" Capsule HUD │                           │
│  │ One-Tap Pair & Connect Sheet │                           │
│  └──────────────────────────────┘                           │
└─────────────────────────────────────────────────────────────┘
```

### 3.1 Host Identity vs Network Route

A Warren Host is uniquely identified by an immutable UUID `host_id`, generated on first startup and persisted in `~/.warren/host.json`:

```json
{
  "host_id": "b79b2d8c-e8fd-438b-9e52-60e881c3cffb",
  "name": "Songjian's MacBook Pro",
  "created_at": "2026-03-01T08:00:00Z"
}
```

A network route (such as `10.23.138.54:8789` or `192.168.1.117:8789`) is merely a transient path to that Host. Clients maintain configurations indexed by `host_id`, binding multiple candidate paths to a single logical Host.

---

## 4. Host Discovery Service (mDNS / Bonjour)

### 4.1 Service Registration

The Warren Host registers a DNS-SD service over mDNS:
- **Service Type**: `_warren._tcp`
- **Domain**: `local.`
- **Port**: Host HTTP/WebSocket port (default `8789`)
- **Instance Name**: `${host_name} (${host_id_prefix})` (e.g., `Songjian's MacBook Pro (b79b2d)`)

### 4.2 TXT Record Attributes

The TXT record publishes operational metadata required for zero-touch discovery without exposing private tokens:

| Key | Example | Description |
| --- | --- | --- |
| `txtvers` | `1` | Schema version of TXT record |
| `id` | `b79b2d8c-e8fd-438b-9e52-60e881c3cffb` | Canonical Host UUID |
| `name` | `Songjian's MacBook Pro` | Display name configured on Host |
| `ver` | `4.0` | Supported Warren protocol version |
| `tls` | `0` (or `1`) | Whether TLS is enabled on this port |
| `pair` | `1` | `1` if open to pairing requests; `0` if locked |
| `cand` | `10.23.138.54:8789,172.20.10.1:8789` | Comma-separated list of active IP:port candidates |

### 4.3 Multi-Platform Implementation
- **macOS / iOS (Desktop & Client)**: Implemented using Apple's `Network.framework` (`NWListener` and `NWBrowser`) for native low-power background discovery.
- **Linux (Headless daemon)**: Implemented using `avahi-client` / D-Bus or embedded zero-dependency pure-Go multicast DNS (`github.com/grandcat/zeroconf` or `hashicorp/mdns`).

---

## 5. Candidate Address Racing (ICE-lite)

When roaming across networks, a Host may have multiple IP addresses (e.g., Wi-Fi, Ethernet, VPN, USB CDC/NCM). A client must not block for 30 seconds on a dead IP before trying the next.

### 5.1 Address Candidate Hierarchy

Candidates are ordered by expected latency and throughput:
1. **USB Direct Route (Priority 100)**:
   - macOS-to-iOS via usbmuxd tunnel (`127.0.0.1:<port>`) or USB NCM link-local (`169.254.x.x`). Latency < 1ms, zero packet loss, immune to Wi-Fi drops.
2. **Local Subnet Candidate (Priority 80)**:
   - Discovered Wi-Fi / Ethernet LAN IP from mDNS or local interface scan (e.g., `10.23.138.54:8789`). Latency 2-10ms.
3. **Persisted Last-Known Candidate (Priority 60)**:
   - The previously successful IP:port stored in client local persistence.
4. **Relay Tunnel Candidate (Priority 40)**:
   - Fallback via self-hosted or public Relay tunnel ([RFC 0009](0009-own-relay-and-public-tunnel.md)). Available even under strict enterprise symmetric NATs.

### 5.2 Racing Algorithm (Happy Eyeballs for Warren)

When a connection is requested or reconnection begins:
```text
Client                          Candidate 1 (USB)      Candidate 2 (LAN)     Candidate 3 (Last Known)
  │                                     │                      │                        │
  ├────── Probe (GET /healthz) ────────►│                      │                        │
  │   (Wait 50ms stagger)               │                      │                        │
  ├────── Probe (GET /healthz) ───────────────────────────────►│                        │
  │   (Wait 50ms stagger)               │                      │                        │
  ├────── Probe (GET /healthz) ────────────────────────────────────────────────────────►│ (Timeout)
  │                                     │                      │                        │
  │◄───── 200 OK (Host ID Match) ──────────────────────────────┘                        │
  │                                     │ (Winner: Candidate 2)                         │
  │                                     │                                               │
  ├────── Establish WS Session ───────────────────────────────►│                        │
```

1. The client constructs a candidate list for the target `host_id`.
2. It launches lightweight HTTP probes (`GET /healthz` with header `X-Warren-Client-ID: <uuid>`) spaced with a 50ms staggered interval.
3. Each probe expects an immediate response containing `{"status":"ok","host_id":"..."}`.
4. The first candidate that returns a `200 OK` with a matching `host_id`:
   - Wins the race.
   - All other pending probes are cancelled.
   - The winning URL is updated in the client's local endpoint store (`active-endpoint`).
   - The client initiates the primary Warren protocol 4.0 WebSocket connection.

---

## 6. iOS User Experience: "Explore in LAN"

### 6.1 Visual Appearance & Placement

On the iOS client, discovery must be easily discoverable when needed, but unobtrusive during active editing.

```text
┌──────────────────────────────────────────────────────────┐
│  Warren                     [ 🟢 Connected: Warren LAN ]  │
│                                                          │
│  [ Projects ]                                            │
│  ├── warren                                              │
│  └── ghostline                                           │
│                                                          │
│  ... (workspace canvas) ...                              │
│                                                          │
│                                  ┌────────────────────┐  │
│                                  │ 📡 2 Hosts Nearby  │  │
│                                  └────────────────────┘  │
│                                    (Floating Capsule)    │
└──────────────────────────────────────────────────────────┘
```

- **Floating HUD Capsule (`WarrenExploreCapsule`)**:
  - Rendered as a floating pill button in the bottom-trailing safe area (or integrated into the top navigation bar when disconnected).
  - Uses native glassmorphic background (`.ultraThinMaterial`) with an animated radio wave icon (`wave.3.forward.circle.fill`).
  - Label states:
    - `Disconnected`: "📡 Explore in LAN" (pulsing accent badge)
    - `Discovered`: "📡 1 Host Nearby" (vibrant green indicator)
    - `Connected`: Collapses into a discreet status dot, expanding on swipe or tap.

### 6.2 The Exploration Sheet (`WarrenHostDiscoverySheet`)

Tapping the capsule presents a sheet detailing local discovery:

```text
┌──────────────────────────────────────────────────────────┐
│                    Nearby Warren Hosts                   │
│                                                          │
│  DISCOVERED ON LOCAL NETWORK                             │
│  ┌────────────────────────────────────────────────────┐  │
│  │ 💻 Songjian's MacBook Pro                          │  │
│  │    10.23.138.54:8789 • Direct Wi-Fi                │  │
│  │    Status: Paired (Current Host)      [ Connected ]│  │
│  └────────────────────────────────────────────────────┘  │
│  ┌────────────────────────────────────────────────────┐  │
│  │ 🖥️ Linux Dev Server (b79b2d)                       │  │
│  │    10.23.140.12:8789 • Subnet                      │  │
│  │    Status: Not Paired                     [ Pair ] │  │
│  └────────────────────────────────────────────────────┘  │
│                                                          │
│  [ Manual IP Configuration ]             [ Refresh (3s) ]│
└──────────────────────────────────────────────────────────┘
```

- Each host entry shows:
  - Host icon, human-readable name, and short UUID prefix.
  - Active reachability badge: `Direct Wi-Fi`, `USB Connected`, `Tailscale / WireGuard`, `Relay`.
  - Relationship status:
    - **Paired & Active**: Currently streaming live session.
    - **Paired (Known)**: Token exists in Keychain; single-tap switches endpoint.
    - **New Host**: Requires mutual pairing; tapping displays the pairing workflow.

---

## 7. Zero-Trust Mutual Pairing & Token Exchange

Connecting to a Host must not require insecure token pasting or unauthenticated endpoints.

### 7.1 Protocol Flow

```text
  iOS Client                                          Warren Host
      │                                                    │
      │ 1. POST /api/v1/pairing/request                    │
      │    { client_id, name: "iPhone Air", pubkey }       │
      ├───────────────────────────────────────────────────►│
      │                                                    │ 2. Generate 6-digit PIN
      │                                                    │    (e.g., 492 810)
      │ 3. 202 Accepted                                    │    Hold pending state
      │    { request_id: "pr_9f2", pin: "492810" }         │    (60s TTL)
      │◄───────────────────────────────────────────────────┤
      │                                                    │
      │ [UI: "Confirm PIN on Host: 492 810"]               │ 4. Notify User
      │                                                    │    (Desktop alert OR
      │                                                    │     CLI command)
      │                                                    │
      │                                                    │ 5. User Approves PIN
      │                                                    │
      │ 6. GET /api/v1/pairing/status?request_id=pr_9f2    │
      │    (Long-polling or SSE stream)                    │
      ├───────────────────────────────────────────────────►│
      │ 7. 200 OK                                          │
      │    { status: "approved", token: "warren_tok_..." } │
      │◄───────────────────────────────────────────────────┤
      │                                                    │
      │ 8. Store token in iOS Keychain                     │
      │ 9. Connect WS /ws (Auth: Bearer warren_tok_...)    │
      ├───────────────────────────────────────────────────►│
```

### 7.2 Step-by-Step Sequence

1. **Client Initiation**:
   The iOS client generates a device-unique `client_id` (UUID) and an ephemeral curve25519 keypair. It sends:
   ```http
   POST /api/v1/pairing/request HTTP/1.1
   Host: 10.23.138.54:8789
   Content-Type: application/json

   {
     "client_id": "9A7F11C2-814E-43B0-8C71-987B2E3F10A2",
     "client_name": "Songjian's iPhone Air",
     "platform": "ios",
     "ephemeral_pubkey": "base64_encoded_key...",
     "requested_scope": "client:interactive"
   }
   ```

2. **Host PIN Generation**:
   The Host validates request rate limits (max 3 concurrent pending requests per IP). It generates:
   - A random 6-digit Short Authentication String (SAS / PIN): e.g., `492 810`.
   - A unique `request_id`: `pr_<random_hex>`.
   - A state record with a 60-second time-to-live (TTL).
   The Host responds with `202 Accepted` including the `request_id` and PIN.

3. **Client Confirmation Display**:
   The iOS client displays a pairing modal:
   > **Confirm Pairing on Host**  
   > Verification Code: **492 810**  
   > Confirm this code on your computer to complete pairing.

4. **Host Approval Modalities**:

   #### Modality A: Desktop Mode (macOS)
   When `warren-desktop` is running, it listens to internal host pairing events. A native macOS confirmation sheet appears:
   ```text
   ┌──────────────────────────────────────────────────────────┐
   │ 📡 Warren Pairing Request                                │
   │                                                          │
   │ "Songjian's iPhone Air" (10.23.138.99) is requesting      │
   │ access to this Host.                                     │
   │                                                          │
   │ Verification Code:                                       │
   │                   [ 4 9 2   8 1 0 ]                      │
   │                                                          │
   │             [ Decline ]          [ Approve ]             │
   └──────────────────────────────────────────────────────────┘
   ```
   Tapping **Approve** approves the pairing session.

   #### Modality B: Headless CLI Mode (Linux / macOS Headless)
   In headless server mode, the daemon logs the pairing alert to stderr/syslog and opens a local CLI pairing socket.
   The user approves from any authorized shell on the Host machine:
   ```bash
   # View pending pairing requests
   $ warren host pair list
   REQUEST ID   CLIENT NAME           IP            CODE     EXPIRES
   pr_9f2       Songjian's iPhone Air 10.23.138.99  492810   48s

   # Approve the request by PIN or Request ID
   $ warren host pair approve 492810
   ✔ Approved client 'Songjian's iPhone Air' (9A7F11C2-...). Scoped token minted.
   ```

5. **Token Minting & Storage**:
   - Once approved, the Host generates a scoped token with metadata:
     ```json
     {
       "client_id": "9A7F11C2-814E-43B0-8C71-987B2E3F10A2",
       "client_name": "Songjian's iPhone Air",
       "scope": "client:interactive",
       "created_at": "2026-09-08T11:30:00Z",
       "token": "warren_tok_c8129a00f2e8b..."
     }
     ```
   - The token is signed/hashed and saved to `~/.warren/paired_clients.json`.
   - The client polls or streams `/api/v1/pairing/status` and receives the approved token.
   - The client stores `warren_tok_...` securely in the **iOS Keychain** under the service `com.warren.client.tokens` keyed by `host_id`.
   - Future connections to this `host_id` skip pairing entirely and authenticate directly.

### 7.3 Revocation and Lifecycle

A paired client can be audited or revoked at any time from Desktop Settings or CLI:
```bash
$ warren host pair list --all
CLIENT ID     NAME                  LAST SEEN       STATUS
9A7F11C2...   Songjian's iPhone Air 2 minutes ago   Active
5B1290EE...   iPad Pro (Desk)       3 days ago      Active

$ warren host pair revoke 9A7F11C2...
✔ Revoked client 'Songjian's iPhone Air'. Active WebSocket sessions closed immediately.
```
Upon revocation, the Host immediately terminates all active WebSocket connections belonging to that token and invalidates all session leases.

---

## 8. Data Structures and CLI Commands

### 8.1 Paired Clients Schema (`~/.warren/paired_clients.json`)

```json
{
  "version": 1,
  "clients": {
    "9A7F11C2-814E-43B0-8C71-987B2E3F10A2": {
      "client_id": "9A7F11C2-814E-43B0-8C71-987B2E3F10A2",
      "client_name": "Songjian's iPhone Air",
      "token_hash": "sha256_hash_of_token...",
      "scope": "client:interactive",
      "paired_at": "2026-09-08T11:30:00Z",
      "last_seen_at": "2026-09-08T11:35:12Z",
      "last_ip": "10.23.138.99"
    }
  }
}
```

### 8.2 CLI Command Specifications

| Command | Arguments | Description |
| --- | --- | --- |
| `warren host discover` | `[--timeout <sec>]` | Actively browses for other Warren hosts on local LAN |
| `warren host pair list` | `[--all]` | Lists pending (or all) client pairing requests |
| `warren host pair approve` | `<pin \| request_id>` | Approves a pending pairing request |
| `warren host pair reject` | `<pin \| request_id>` | Rejects and terminates a pairing request |
| `warren host pair revoke` | `<client_id>` | Permanently revokes a paired client token |

---

## 9. Security and Invariants

1. **No Token in Multicast**:
   The mDNS broadcast never contains authentication credentials, session tokens, or private workspace paths.
2. **Short Authentication String (SAS) Verification**:
   The 6-digit numeric PIN guarantees protection against Man-in-the-Middle (MITM) and rogue network scanning on public Wi-Fi.
3. **Strict Rate Limiting & Backoff**:
   Host limits pending pairing attempts to 3 concurrent slots. Repeated rejected attempts from an IP enforce exponential backoff to prevent brute-force PIN guessing ($10^6$ combinations with 60s window).
4. **Local Authority Invariant**:
   Approval authority remains strictly on the Host machine. No third-party cloud server or relay has authority to grant pairing tokens.
5. **Secure Storage Invariant**:
   Client-side tokens MUST be saved to iOS Keychain (protected with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`) rather than plain `UserDefaults` or unencrypted plists.

---

## 10. Implementation Plan & Milestones

### Milestone 1: Core Host Discovery & Bonjour Announcer
- Implement mDNS advertiser in `warren-headless` / `warren` Go daemon.
- Implement `NWBrowser` discovery wrapper in `Packages/WarrenIOS/Sources/WarrenIOS/Discovery/`.
- Verify detection of Host on physical iPhone via USB and Wi-Fi.

### Milestone 2: Candidate Address Racing (ICE-lite)
- Implement `WarrenCandidateRacer` in `WarrenIOS`.
- Add concurrent probe logic with 50ms stagger.
- Latch successful winner to `activeEndpoint` configuration dynamically.

### Milestone 3: iOS "Explore in LAN" Floating Capsule UI
- Build `WarrenExploreCapsule` SwiftUI view with glassmorphism and pulsing animation.
- Build `WarrenHostDiscoverySheet` listing detected hosts and reachability statuses.

### Milestone 4: Mutual Pairing Protocol & Token Exchange
- Implement `/api/v1/pairing/*` HTTP handlers on Warren Host.
- Add macOS native Desktop approval dialog in Desktop app.
- Add `warren host pair approve/reject/revoke` CLI commands.
- Integrate Keychain storage on iOS client.

---

## 11. Alternatives Considered

1. **QR Code Scanning Only**:
   - *Consideration*: Requiring the iOS client to scan a QR code displayed in the Host terminal or Desktop app.
   - *Trade-off*: Excellent security, but fails completely for remote headless setups accessed without a screen, or when the phone is docked / mounted. The proposed PIN protocol allows both screen (Desktop dialog) and headless CLI, while QR codes can optionally be layered on top as an encoding of the pairing PIN.
2. **Zero-Confirmation Trust on First Use (TOFU)**:
   - *Consideration*: Automatically accepting the first client that discovers the Host on LAN.
   - *Trade-off*: Unacceptable security risk in corporate offices, co-working spaces, and coffee shops where untrusted devices share the local subnet.
3. **Hardcoded IP Fallback Lists**:
   - *Consideration*: Simply letting the user enter multiple fallback IPs in a settings screen.
   - *Trade-off*: High friction, brittle, and does not solve dynamic DHCP reassignments when roaming. Candidate racing with mDNS solves this autonomously.
