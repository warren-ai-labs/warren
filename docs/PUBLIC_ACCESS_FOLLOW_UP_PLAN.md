# Public Access Follow-up Plan

## Scope

Public Access is a Relay-owned route. The Headless daemon keeps only the Relay
origin, Host identity, route metadata, and enabled intent; the Host Secret stays
in the daemon credential store.

## Workflow

1. Enroll the Host with a one-time Relay ticket.
2. Validate or configure the route with Save & Test.
3. Enable or disable the route explicitly.
4. Report only the canonical public endpoint and credential-free status.

Owner access and Public Access use the same Relay Host connection and route
service. Pairing issues a short-lived scoped capability, while route changes
remain authenticated with the Host Secret and never expose it to the browser.

## Verification

- Relay route configuration accepts hostname, path prefix, and auth mode.
- Restart recovery reconnects the Host and restores enabled route intent.
- Reset disables the route and clears local route metadata without deleting Host
  enrollment.
- CLI and Desktop expose the same Relay status and endpoint fields.
