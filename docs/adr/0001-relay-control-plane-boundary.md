# ADR 0001: Keep Relay administration outside Warren clients

## Status

Accepted

## Context

Warren Relay is commonly operated as shared company or community
infrastructure. Its administrator manages the Relay deployment, policy, Host
records, enrollment keys, and revocation. A Warren Desktop or iOS user
only needs to connect one local Host and, when authorized, share that Host
with another client.

Exposing Host provisioning, pairing-code exchange, route mutation, or
revocation as ordinary `warren` commands makes a client appear to administer
the shared Relay. It also encourages users to handle Relay administrator
credentials and Host Secrets directly.

## Decision

Relay administration remains in the Relay service's administrative API or a
separate service-owned administration surface. Warren clients never require a
Relay administrator credential for normal operation.

The client-facing lifecycle is deliberately small:

1. A Relay Administrator issues bounded-use enrollment keys out of band.
2. Warren Desktop prefills the Relay URL and key from a settings shortcut, or
   Headless receives them at startup; the daemon actively claims the local Host.
3. The enrolled Host Operator asks the local daemon for one opaque Pairing
   Invite, which Desktop can display or render as a QR code.
4. iOS scans the Pairing Invite and exchanges it with Relay; it never handles
   Relay administrator credentials or a Host Secret.

The pairing-code and invite-exchange endpoints remain Relay protocol
internals. They may be used by the Host daemon and native clients, but they
are not ordinary Warren CLI concepts. A managed deployment may provide a
default Relay endpoint, but each Host still requires a Relay-issued identity
or enrollment key.

## Consequences

- The Relay service can serve many organizations and Hosts without requiring
  each user to understand its control plane.
- Desktop settings shortcuts and Headless startup flags can enroll a Host; the
  connector reconnects on subsequent launches without another administrator
  action.
- `warren` user flows can focus on connect and share; diagnostic or
  administrator operations belong to service-owned tooling.
- A default Relay URL alone cannot enroll an unknown Host; an enrollment key or
  managed device-authentication mechanism is still required.
