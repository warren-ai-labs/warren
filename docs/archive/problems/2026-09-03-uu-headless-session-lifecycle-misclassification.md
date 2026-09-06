# Problem Record: UU Display Reconfiguration Misclassified Headless Sessions

- Recorded: 2026-09-04 (Asia/Shanghai)
- Incident window: 2026-09-03 23:19:13–23:19:20 (Asia/Shanghai)
- Status: Warren-side failure mode confirmed; UU-to-Ghostline RPC mechanism not fully proven
- Scope: read-only investigation; no Warren resource or session state was changed
- Affected components: UU remote access, macOS WindowServer, Warren Desktop, `warren-headless`, Ghostline v1

## Summary

After UU remote access was established, all visible headless Ghostline tabs
disappeared from Warren within roughly two seconds. The durable Warren state
shows that 29 running Ghostline sessions were written as `ended` in one batch.

The immediate cause is a Headless lifecycle misclassification, not a confirmed
client-side delete: a transient failure of the Ghostline `List`, `Get`, or
`Status` RPC probes was treated as proof that the runtime no longer existed.
The reconciler then called `markEnded()` for every affected session. Warren's
roster projection intentionally excludes ended sessions, so the Desktop then
showed an empty session list.

UU is the most likely trigger. It established a peer connection at the start
of the incident, while WindowServer performed display wake/remove/rebuild and
multiple display reconfigurations. The exact UU-to-Ghostline RPC failure path
was not captured, so this document does not claim that UU directly killed
Ghostline or directly called a Warren deletion API.

## User-visible symptom

- Warren was left running at the office and accessed remotely later in the
  evening.
- Shortly after UU connected, the previously retained headless Ghostline
  sessions disappeared from the Warren UI.
- The failure affected the whole batch rather than one terminal.

## Evidence and timeline

### UU

- `23:19:13.529`: UU established a peer connection.
- `23:19:18.707`: UU entered a sequence of connection states `2`, `3`, `4`,
  and `5`.
- Heartbeats continued afterward; UU did not show a self-initiated exit.
- No UU log entry showed a Warren `session.delete` (or equivalent lifecycle
  mutation).

### macOS and Warren Desktop

During the same interval, WindowServer logged display wake, removal, rebuild,
and repeated display reconfiguration. Warren Desktop logged errors including:

```text
invalid display identifier
Invalid display 0x00000001
```

The Desktop roster shrank in one burst:

```text
29 → 24 → 16 → 12 → 9 → 7 → 0
```

The burst completed in about 1.5 seconds, followed by an approximately
2,102 ms main-thread stall. This is consistent with the Desktop receiving
successive rosters after the server-side lifecycle writes; it is not evidence
that the Desktop initiated those writes.

### Durable Warren state

All 29 affected Ghostline sessions were written with `lifecycle=ended` in the
following UTC interval:

```text
2026-09-03T15:19:18.326Z–2026-09-03T15:19:19.868Z
```

That is the same as 23:19:18.326–23:19:19.868 local time, immediately after
the UU and display events.

### Headless and Ghostline

- A Headless roster snapshot in the incident window still reported
  `sessions=307`.
- Headless later created new Ghostline sessions successfully.
- These observations show that Headless and Ghostline did not both simply
  crash at the same instant.
- The evidence confirms the Warren state transition. It does not by itself
  prove whether every underlying PTY was still alive after the transition.
  The five-minute orphan reaper could subsequently kill a runtime that had
  been incorrectly marked ended.

## Code path that explains the batch failure

The relevant implementation is in `Headless/internal/server`:

1. `Service.reconcile` calls `runningSessions` and then evaluates every
   durable session whose lifecycle is `running`.
2. `runningSessions` calls the runtime `List` RPC. A `List` error is swallowed;
   no distinction is retained between “the list is empty” and “the runtime
   could not be probed”.
3. When no successful list is available, the fallback calls
   `GhostlineRuntime.Exists` for each session.
4. `GhostlineRuntime.Exists` calls `Get` and `Status`, but converts any error
   to `false`. A timeout, stuck RPC, or temporarily unavailable Unix socket is
   therefore indistinguishable from a missing or dead session.
5. `reconcile` performs a second `Exists` check through `anyRuntimeOwns`. If
   the transient failure persists for both calls, it calls `markEnded`.
6. `markEnded` persists `lifecycle=ended` and stops Warren's output tracking.
7. `RosterVersion` filters ended sessions from the observer-facing roster, so
   the Desktop tabs disappear.
8. On a later orphan-reap pass, a runtime whose name is recorded as ended may
   be killed after `orphanReapGrace` (currently five minutes).

The current code already contains a comment stating that a transient probe
failure must not end a live session. The boolean runtime interface prevents
that intention from being enforced.

## Why `headless` did not protect this incident

`ProbeForeground=false` disables the optional OS-level foreground process
metadata probe. It does not make the Headless daemon independent of the
Ghostline Unix socket or its RPC control plane. A display hotplug can therefore
coincide with a control-plane probe failure even when no terminal surface is
being drawn.

Headless is expected to retain the Ghostline runtime when a client disconnects;
that architectural contract is documented in `docs/headless-architecture.md`.
The failure here is that a control-plane availability error was interpreted as
a runtime exit, which violates that contract.

## Confirmed and unconfirmed conclusions

### Confirmed

- 29 Warren Ghostline session records were changed from `running` to `ended`
  in one short batch.
- The change occurred immediately after the UU/display event window.
- The Headless reconciler contains the exact error path that can convert a
  Ghostline probe failure into those state writes.
- Warren Desktop filters ended sessions and therefore explains the visible
  disappearance without requiring a client-side delete.
- No evidence shows UU or Warren Desktop explicitly invoking a session-delete
  operation.

### Strongly indicated

- UU's remote-display setup triggered macOS display hotplug/reconfiguration.
- The display event and a transient Ghostline RPC probe failure overlapped.
- The Warren-side false lifecycle decision, rather than a normal headless
  shutdown, caused the mass disappearance.

### Not established

- The precise UU action that made Ghostline `List/Get/Status` fail.
- Whether UU sent a signal to the Ghostline process.
- Whether the underlying PTYs were alive after the `ended` writes or were later
  removed by the orphan reaper.

DiagnosticReports also contain several later startup failures from an old
standalone `ghostline@v0.6.1` binary that could not load
`libghostty-vt.dylib`. Those occurred at approximately 23:55, 00:14, 00:23,
and the following day at 12:42. Warren was using Ghostline v1.1.3, so these
reports are treated as unrelated legacy/residual process noise, not as the
23:19 root cause.

## Proposed remediation (not implemented)

The smallest causal fix is to preserve the distinction between runtime death
and probe uncertainty:

- Replace the boolean lifecycle probe with `alive`, `dead`, and `unknown`
  outcomes (or an equivalent typed error contract).
- Treat `List/Get/Status` transport, timeout, and server-availability errors as
  `unknown`; log them and leave the durable lifecycle unchanged.
- Mark a session ended only after explicit death evidence, preferably confirmed
  across multiple healthy probes.
- Prevent the orphan reaper from acting on sessions whose state is based only
  on an unavailable probe.
- Add structured probe-error logs and regression tests for a runtime-wide RPC
  outage, a single missing session, and recovery after the outage.
- Keep foreground metadata probing optional and isolated from lifecycle
  decisions. Separately, configure UU to avoid unnecessary virtual-display
  teardown/reconfiguration where operationally possible.

This deliberately trades a short-lived stale tab or delayed cleanup during a
real Ghostline outage for protection against a destructive, host-wide false
positive. Existing records already written as `ended` should not be
automatically resurrected without independently proving that their underlying
runtime still exists.

## Investigation boundary

The investigation used only read-only source inspection and existing logs/state
artifacts: UU logs, WindowServer/Warren Desktop logs, Headless roster output,
durable Warren state timestamps, and DiagnosticReports. No session was
removed, moved, renamed, pinned, sent input, attached, restarted, or otherwise
mutated during the investigation.
