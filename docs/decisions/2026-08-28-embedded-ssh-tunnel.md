# Embedded SSH Tunnel for Desktop Remote Endpoints

## Status

Accepted

## Context

Desktop remote endpoints currently derive a WebSocket URL directly from the
configured endpoint URL. A public `http://` endpoint becomes `ws://`, which is
rejected by macOS App Transport Security. An SSH endpoint should therefore be
usable without requiring users to keep a separate terminal process running.

The experience must also remain predictable on a LAN: users may switch between
an SSH route and a direct HTTPS route without changing the Host daemon's data
or authentication model.

## Decision

Add an embedded SSH forwarding helper to the Desktop distribution. The helper
is a small Go process bundled and signed with the app; Swift owns its lifecycle
and consumes a line-delimited JSON control protocol.

The helper will use `golang.org/x/crypto/ssh`, `ssh/agent`, and `knownhosts`.
Charmbracelet's `wish` is intentionally not used because it is an SSH server
framework, while this feature requires an SSH client and local port forwarding.

For an endpoint containing SSH metadata, Desktop will:

1. Resolve the target through the user's SSH config and identity/agent setup.
2. Verify the host key against `known_hosts` and surface an actionable error
   for unknown or changed keys.
3. Run the existing Warren bootstrap command on the remote host and obtain the
   daemon token without persisting private key material.
4. Bind a random loopback port and forward each accepted connection to
   `127.0.0.1:8789` through the SSH connection.
5. Connect the existing remote model to `ws://127.0.0.1:<port>/v1/ws`.
6. Tear down the tunnel on endpoint switch, app termination, or failed
   authentication; reconnect with bounded exponential backoff.

Direct HTTPS endpoints remain supported for LAN or reverse-proxy deployments.
The endpoint catalog will retain the user's SSH target as the durable identity;
the allocated local port and helper PID are runtime state only.

## Helper protocol

The helper communicates over stdin/stdout using JSON lines. It starts from its
command-line target and emits `ready`, `error`, and `closed` events; the
Desktop sends a `stop` command for graceful shutdown. Secrets are never
included in diagnostic events. The protocol is intentionally line-oriented so
the helper can be replaced independently of the Swift client in a future
release.

The Desktop endpoint popover exposes an `Add SSH Host…` action. It reads
concrete aliases (including aliases from `Include` files), shows unsupported
`ProxyJump`/`ProxyCommand` entries without making them selectable, and stores
the selected alias as an SSH-backed endpoint.

## Security and usability constraints

- Bind forwarding listeners to loopback only.
- Prefer `SSH_AUTH_SOCK`; otherwise read `IdentityFile` paths from SSH config.
- Never disable host-key verification by default.
- Do not write private keys, passphrases, or raw SSH output to Warren state or
  logs.
- Use a random local port to coexist with the local daemon and other tunnels.
- Keep the existing external `warren ssh` command as a compatibility path.
- Present failures as actionable UI states (missing key, host-key mismatch,
  unreachable host, bootstrap failure, and remote daemon unavailable).

## Alternatives considered

- `wish`: rejected; it provides SSH server primitives, not a client.
- Runtime ATS changes: impossible; ATS is part of the signed app's plist.
- Global ATS exceptions: rejected for release builds because they allow
  arbitrary clear-text network traffic.
- A Swift-native SSH implementation: deferred; it duplicates mature Go SSH
  config and authentication behavior and complicates portability.

## Rollout

First extract remote bootstrap and forwarding into a reusable Go package and
add protocol-level tests. Then bundle the helper, integrate the Swift actor,
and exercise endpoint switching, reconnect, LAN direct HTTPS, and app restart
before enabling the new path by default.
