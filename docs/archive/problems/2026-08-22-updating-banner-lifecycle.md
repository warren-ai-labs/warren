# Updating Banner Lifecycle Across Warren Restarts

- Recorded: 2026-08-22 (Asia/Shanghai)
- Status: Observed; no code change in this note
- Scope: Native desktop terminal maintenance banner

## Symptom

The native terminal surface can show an `Updating Warren…` capsule while the
daemon is about to restart. The application usually exits before ten seconds,
then the installer spends a few seconds stopping and replacing the daemon and
application before launching Warren again. The banner therefore disappears
with the old process instead of remaining visible until the replacement is
fully ready.

## Current lifecycle

The banner is rendered whenever `WarrenTerminalSurfaceView` receives a non-nil
`maintenanceMessage` from `WarrenRemoteApplicationModel`.

1. The daemon broadcasts a maintenance announcement with the `starting` state.
2. The native client stores the message and starts a ten-second safety task.
3. A subsequent authenticated `roster` clears the message as soon as the
   daemon is available again.
4. If no roster arrives first, the safety task clears the message after ten
   seconds.
5. If the Warren application exits first, the model and its task are destroyed;
   no ten-second callback or completion state survives the restart.

The release install script announces maintenance before asking the GUI to quit.
The in-app detached installer waits for the GUI to quit and replaces the bundle,
but it does not currently emit the daemon maintenance announcement itself.

## Root cause

The maintenance protocol currently communicates only `starting`. It has no
cross-process completion or failure state. The ten-second task is therefore a
watchdog, not an update-progress mechanism. The first post-restart `roster` is
the strongest existing completion signal because it proves that the new daemon
accepted the client connection and returned an authoritative snapshot.

The process boundary is the important detail: a SwiftUI state value or a
`Task.sleep` callback cannot represent the installer phase after the GUI exits.
The newly launched process starts with a fresh model and a nil
`maintenanceMessage`.

## Recommended direction

Treat the capsule as a **daemon restart notice**, not as a progress bar:

- Clear it normally only after the first authenticated `roster`.
- Remove the ten-second timer as a normal clearing path.
- Keep a longer watchdog only for the abnormal case where the daemon never
  returns. The watchdog should mark the state as stalled or add a recoverable
  notice; it must not claim that the update completed by silently hiding the
  banner.
- Keep the existing roster-based completion signal instead of adding a
  `finished` event. The old daemon cannot reliably deliver a completion event
  after it has exited.

If the product requires an update indicator to survive the GUI restart, add a
small persisted pending-update record containing the target version and start
time. The new process can show a finishing state, verify the installed bundle
version, and clear the record after the daemon's first successful roster. A
timeout should report a failed or stalled update rather than silently clearing
the record.

## Verification cases

- Maintenance announcement followed by a roster before the watchdog: the
  capsule disappears immediately after the roster.
- Maintenance announcement followed by a restart longer than ten seconds: the
  capsule does not falsely disappear merely because a fixed duration elapsed.
- GUI exit before daemon recovery: the old capsule is expected to disappear;
  any post-restart indication requires the persisted pending-update record.
- Aborted or failed restart: the watchdog exposes a stalled/recoverable state
  instead of reporting success.
