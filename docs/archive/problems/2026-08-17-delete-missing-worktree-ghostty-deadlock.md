# Warren Desktop Freeze: Delete of a Missing Worktree

- Recorded: 2026-08-17 (Asia/Shanghai)
- Status: Diagnosed; no code change made in this incident
- Workspace: `0789db90-b766-42de-b0b8-33fb01bb2644` (`terminal-groups`)

## Trigger and filesystem state

The diagnostics log records:

```text
deleteWorkspace(0789db90-b766-42de-b0b8-33fb01bb2644, removeLocalWorktree: true)
```

The recorded path is:

```text
/Users/lisongjian/.warren/worktrees/1d4aff87/0789db90-feat-terminal-groups
```

That directory does not exist, and `git worktree list --porcelain` does not
contain it. The workspace is still returned by `warren workspace list`, so the
delete request did not remove the state record.

The headless delete implementation currently calls
`terminateProcessesUnder(workspace.Path)` and then runs
`git worktree remove --force workspace.Path`. A missing path is not treated as
an idempotent success; the Git command returns an error and the state update is
never reached. This is a separate delete-path bug, not the GUI deadlock itself.

## Deadlock evidence

`sample 94078 5` (`/tmp/warren-delete-worktree-missing-20260817.sample.txt`)
shows the Warren main thread blocked for the full sample in:

```text
TerminalSurfaceManager.scheduleReconciliation
  -> reconcile -> attach
  -> AppTerminalView.resignFirstResponder
  -> TerminalSurfaceCoordinator.setFocus
  -> ghostty_surface_set_focus
  -> __ulock_wait2
```

The same sample shows the lock cycle's other participants:

- Ghostty's `io` thread is in `receiveResizeCallback` ->
  `InMemoryTerminalSession.dispatchResize`, waiting for the session `NSLock`.
- The utility output task is in `WarrenGhosttyOutputWriter.drain` ->
  `InMemoryTerminalSession.receive`, then waiting inside
  `ghostty_surface_write_buffer` while the session path is active.

The cycle is therefore:

```text
main:   Ghostty surface lock (setFocus)
io:     Ghostty surface lock -> InMemoryTerminalSession.lock
feed:   InMemoryTerminalSession.lock -> Ghostty surface lock (writeBuffer)
```

Deleting the workspace is the proximate trigger because it changes the roster
and causes surface/focus reconciliation. It does not itself hold the lock that
deadlocks the GUI. The root cause is the existing lock-order inversion in the
in-memory session bridge.

## Safety and follow-up

The headless service remains alive and `warren workspace list` still responds.
Restarting only the Warren GUI preserves the headless sessions. After recovery,
the stale workspace record can be removed separately with an idempotent
missing-worktree path (for example, a keep-worktree removal); that cleanup was
not run during this investigation.

The code fix should first move all `ghostty_surface_*` calls out of the
`InMemoryTerminalSession` lock, then make missing worktree removal converge to a
successful state cleanup instead of returning a Git error.

