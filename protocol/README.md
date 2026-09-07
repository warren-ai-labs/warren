# Warren Protocol

This directory is the single source of truth for the Warren wire protocol. It
exists because the same constants — DENB magic bytes, direction/kind codes,
capability strings, method names, event discriminators — are implemented
identically in three languages. A drift here used to mean a silent client
that just doesn't connect. Now there's a JSON Schema and a bindings map, so a
tooling pass can catch divergence before it ships.

## Canonical documents

- [`warren.schema.json`](./warren.schema.json) — machine-readable spec. Every
  constant that moves on the wire has a `const` so JSON-Schema validators can
  pin it.
- `README.md` (this file) — human-readable index, bindings map, and rules
  for changing the spec.

When a section of code disagrees with this spec, fix the spec first if the
code is wrong, or update the spec and every binding in the same commit. Do
not change one binding in isolation.

## How the protocol is layered

There are three independent wire surfaces:

1. **Binary DENB frames** between a client and the Host, for terminal I/O
   (PTY output, client input, atomic state snapshots). Wire version 1; this
   is the part that has to keep matching across Go, Swift, and TypeScript.
2. **JSON control envelopes** over the same WebSocket, for the full RPC
   surface and server-pushed events. Logical version 4.0. This is a clean
   break: pre-4.0 clients and protocol state are rejected or reset.
3. **BRLY/2 frames** between the Host connector and the Relay control
   plane. Independent wire version 2; clients do not decode these.

The Relay serves a relayed WebSocket that tunnels the first surface plus
the second, so the public client surface is still "DENB over WS, JSON for
control, BRLY/2 underneath". The /v1/relay/* HTTP endpoints provision
the Relay side; the client only ever talks to the inner WS.

## Bindings map

Every section of the schema points to a concrete file in every binding. If
you change a constant here, all four rows must move together.

| Spec section | Go | Swift | TypeScript |
| --- | --- | --- | --- |
| `logicalVersion` | `Headless/internal/api/types.go` (`Version`) | `Packages/Protocol/Sources/WarrenProtocol/ProtocolVersion.swift` | `Web/src/connection.js` |
| `binaryEnvelope.magic/wireVersion` | `Headless/internal/output/wire.go` (`BinaryMagic`, `Version`) | `Packages/Transport/Sources/WarrenTransport/WarrenWireCodec.swift` (`binaryMagic`, `binaryVersion`) | `Web/src/wire.js` (`MAGIC`, `VERSION`) |
| `binaryEnvelope.directions/kinds/limits` | `Headless/internal/output/wire.go` (`Direction*`, `Kind*`, `Max*`) | `Packages/Protocol/Sources/WarrenProtocol/BinaryFrameKind.swift` (kinds) and `Packages/Transport/Sources/WarrenTransport/WarrenWireCodec.swift` (`defaultMax*`) | `Web/src/wire.js` (`DIRECTION_*`, `KIND_*`, `MAX_*`) |
| `binaryEnvelope.layout` | `Headless/internal/output/wire.go` (`binaryPrefixLength`) | `Packages/Transport/Sources/WarrenTransport/WarrenBinaryEnvelopeParser.swift` (`Self.binaryPrefixLength`) | `Web/src/wire.js` (`PREFIX_LENGTH`) |
| `binaryEnvelope.headers` | `Headless/internal/output/wire.go` (`outputHeader`, `inputHeader`, `atomicStateHeader`) | `Packages/Protocol/Sources/WarrenProtocol/BinaryFrameHeader.swift`, `InputMetadata.swift` | `Web/src/wire.js` (header struct literals at encode time) |
| `jsonControl.envelope/response` | `Headless/internal/api/types.go` (`Envelope`, `Response`) | `Packages/Protocol/Sources/WarrenProtocol/ClientMessages.swift`, `ServerMessages.swift` | `Web/src/connection.js` |
| `capabilities` | `Headless/internal/api/agent_view.go` (`Capability*`) | `Packages/Protocol/Sources/WarrenProtocol/ServerMessages.swift` (capability list) | (negotiated in `Web/src/connection.js`) |
| `terminalStateFormats` | `Headless/internal/server/http.go` (`selectTerminalStateFormat`) | `Packages/Protocol/Sources/WarrenProtocol/ServerMessages.swift` | (sent from `Web/src/connection.js`) |
| `rpcMethods` | `Headless/internal/server/http.go` (handler switch) | `Packages/Protocol/Sources/WarrenProtocol/ClientMessages.swift` | `Web/src/connection.js` (call sites) |
| `serverEvents` | `Headless/internal/server/http.go` (writeJSON call sites) | `Packages/Protocol/Sources/WarrenProtocol/ServerMessages.swift` | `Web/src/connection.js` (message dispatch) |
| `relayStream` | `RelayService/internal/controlplane/protocol.go` | n/a (relay is server-side) | n/a |
| `httpRoutes` | `Headless/internal/server/http.go` (`mux.HandleFunc`) | n/a (server-side) | (consumed in `Web/src/connection.js`, `runtime.js`) |

## Rules for changes

- **Bumping `wireVersion` is a hard break.** No fallback — old clients must
  reject new frames and vice versa. The DENB wire version stays at 1 by
  design; the control protocol's logical version is independent.
- **New `capabilities` go through the negotiation round-trip.** A client
  that wants a new capability must include it in the welcome envelope; the
  Host responds with the intersection in client order. Adding a capability
  without negotiating it is a silent failure on the client.
- **The logical control version is a hard break.** Protocol 4.0 has one
  canonical Agent command surface, one `agent.events` event envelope, one
  session subscription lifecycle, and DENB-only input. A pre-4.0 client is
  rejected during authentication; no Agent aliases, dual event broadcasts,
  raw input fallback, or a JSON input path are permitted.
- **Unknown `agent.events` types are data, not transport errors.** Clients
  persist the event and advance their stream cursor even when their renderer
  does not know the type.
- **New `serverEvents` outside Agent are non-breaking within 4.x.** Do not
  change the `t` value or shape of an existing event.
- **New `rpcMethods` are additive within 4.x.** Removing or renaming a method
  requires a new logical major version.
- **Atomic-state format identifiers are forward-compatible.** A client may
  advertise multiple formats; the Host picks one. To roll a new format,
  add a new entry to `terminalStateFormats` and update the client bindings
  in lock-step. Do not change an existing identifier.
- **HTTP routes may move or be added.** Removing a route is a hard break;
  adding a route is non-breaking. The Host's route table is the
  authoritative list — `Headless/internal/server/http.go` is what every
  client links against.

## Drift checks

There is no formal codegen yet (that is B2). For now, the bindings map in
this README is what reviewers use. When the schema changes, the diff must
list the file in each binding that moved, even if the change is "no
op". This is what the next PR will tighten up with an actual
`go test ./protocol/...` that re-parses this file and compares to
generated constants.
