# Headless Output Watchers Saturate Session Creation

- Recorded: 2026-08-24 (Asia/Shanghai)
- Status: Warren fix retained; Ghostline watcher change isolated for review
- Affected build: Warren `0.8.2`, Ghostline `0.6.4`

## Symptom

Creating a terminal becomes progressively slower on a Host with many retained
running Sessions. The delay spans `session.create`, the post-create roster
refresh, and attach even though the attach handler itself usually completes in
50–270 ms.

## Evidence

- The affected Host had about 124 Sessions, including 69 running Sessions and
  107 Ghostline Sessions.
- Each running Session owned a Ghostline `SpoolWatcher` with a fixed 10 ms
  ticker. An idle watcher still called `file.Stat()` on every tick, producing
  about 6,900 metadata syscalls per second for 69 running Sessions.
- `warren-headless` consumed about 93–127% CPU. Process samples concentrated in
  `SpoolWatcher.drain`, `Fstat`, output ring append, encoding, and broadcast.
- The Desktop requested an authoritative roster after create. The old roster
  projection also performed runtime liveness probes per Session, multiplying
  work that already belonged to the single lifecycle loop.

## Root cause

Two observer paths scaled with the number of Sessions instead of with actual
changes:

1. Ghostline polled every spool file at interactive cadence even when no output
   was being written.
2. Warren roster snapshots repeated runtime probes for every observer request.

The fixed 400 ms command launch grace and the Desktop's bounded surface-size
wait can add latency to specific flows, but neither explains the sustained
Headless CPU when Sessions are idle.

## Resolution boundary

- Warren roster projection now reads cached state only. Runtime adoption and
  exit detection stay in the existing single lifecycle loop.
- Successful Session creation records runtime creation, Store persistence,
  output adoption, agent discovery, and total durations. Roster snapshots log
  only when they exceed 50 ms.
- The event-driven Ghostline watcher is kept off Warren `main` while its
  callback cadence and burst-coalescing semantics are reviewed in isolation.

## Risks and mitigations

- **Business intrusiveness:** Session lifecycle, spool ownership, recovery
  anchors, and output framing are unchanged.
- **Interaction:** Warren `main` keeps Ghostline `v0.6.4` polling semantics as
  the stable comparison while the event-driven implementation is reviewed.
- **Performance:** roster runtime probes no longer multiply per connected
  observer; spool polling CPU remains a known cost on the stable comparison.
- **Out-of-the-box usability:** no setting or migration is required; the
  fallback preserves operation on unsupported filesystems and platforms.
- **Functional coupling:** file notification belongs to Ghostline's generic
  spool API. Warren retains only lifecycle policy, roster projection, and
  phase diagnostics.
