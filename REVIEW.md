# Review Requirements

This document is only required when reviewing a change. It does not replace the general contribution guidance in [`CONTRIBUTING.md`](CONTRIBUTING.md).

## Review Standard

Before submitting or merging a change, review the implementation from all of the following angles:

- **Business intrusiveness**: confirm that the change does not alter existing business behavior, data ownership, or user expectations beyond the stated scope. Call out migrations, compatibility risks, and irreversible effects.
- **Interaction impact**: verify loading, error, empty, retry, keyboard, accessibility, and responsive states. Check that existing flows remain predictable and that new prompts or defaults do not interrupt normal work.
- **Performance impact**: consider startup time, steady-state latency, throughput, memory, CPU, I/O, network traffic, and battery usage. Measure or document the reason when a change adds work to a hot path.
- **Out-of-the-box usability**: ensure a fresh checkout can build, run, and recover with the documented prerequisites and defaults. Avoid hidden credentials, machine-specific paths, manual cleanup, or undocumented setup steps.
- **Functional coupling**: keep boundaries explicit and dependencies minimal. Check whether the change creates unnecessary coupling between domain logic, UI, storage, transport, or platform code, and preserve a straightforward path for future replacement.

Record any material risk and its mitigation in the change description before requesting review. Do not mark a change ready while any of these dimensions remains unexamined.

## Contribution Identity

Only identifiable individual developers may submit contributions. Do not accept commits or pull requests authored by organizations, bots, shared accounts, or other non-personal identities. Company-domain email addresses are not accepted as contributor identities; ask the contributor to re-submit with a personal, verifiable identity before merging.
