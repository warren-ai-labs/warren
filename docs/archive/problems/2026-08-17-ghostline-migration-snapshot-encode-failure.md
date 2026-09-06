# Problem Record: Ghostline Migration Fails to Encode a Live Session Snapshot

- Recorded: 2026-08-17 (Asia/Shanghai)
- Repository: `abcdlsj/warren`
- Branch: `main`
- Related repository: `../ghostline` (event dependency `v0.5.0`; compatibility fix on local `main`)
- Status: Root cause confirmed; compatibility workaround implemented in Ghostline; upstream fix pending
- First observed: 2026-08-17 11:30:04 (Asia/Shanghai)
- Affected runtime: `warren_150c5318c4bf404e9b9c6a2cb31bd6c1`
- Affected session ID: `150c5318-c4bf-404e-9b9c-6a2cb31bd6c1`
- Affected workspace: repository `abcdlsj/warren`, branch `main`

## Summary

Warren's new headless daemon embeds ghostline `v0.5.0`, while the detached
ghostline server that owns existing PTY sessions is still running the `v0.4.0`
protocol. Warren correctly detects the protocol mismatch and attempts a rolling
upgrade. The upgrade pauses the old server, prepares each session, and asks the
old server to encode a libghostty-vt migration snapshot. Encoding fails for one
live session with `ghostty snapshot encode failed: -2`.

The new server exits and Warren keeps the old server alive. This preserves the
session and is the correct failure behavior for a migration that cannot prove
that all sessions were transferred.

## Symptom

The affected session is visibly healthy and remains interactive. It is a
long-lived Codex shell with `lifecycle=running` and `alive=true`. However, the
rolling upgrade fails during the migration snapshot step:

```text
ghostline serve: adopt from /Users/lisongjian/.warren/ghostline.sock.admin: encode snapshot for warren_150c5318c4bf404e9b9c6a2cb31bd6c1: ghostty snapshot encode failed: -2
ghostline upgrade phase=failed from_version="0.4.0" to_version="0.5.0" trigger="protocol_mismatch" error="start upgraded server: spawned ghostline server exited: exit status 1: ghostline serve: adopt from /Users/lisongjian/.warren/ghostline.sock.admin: encode snapshot for warren_150c5318c4bf404e9b9c6a2cb31bd6c1: ghostty snapshot encode failed: -2"
```

The same failure was retried at 11:49 and failed on the same session. The
old server continued to answer RPC requests with protocol version `0.4.0`.

## Expected Behavior

When Warren starts with ghostline `v0.5.0` and finds an older detached server,
the server should migrate every live session, including the emulator state,
without interrupting child PTYs. After all sessions are committed, the stable
socket should point to the new server and the old server should retire.

If any session cannot be transferred safely, the old server must remain the
owner of every session and the new server must exit. No session or PTY data
should be lost.

## Version Evidence

- `warren/go.mod` declares `github.com/abcdlsj/ghostline v0.5.0`.
- The installed `/Applications/Warren.app/Contents/MacOS/warren-headless`
  binary embeds ghostline `v0.5.0` and Warren build `40d7977`.
- The long-lived ghostline server process (PID `92390`) loads
  `~/go/pkg/mod/github.com/abcdlsj/ghostline@v0.4.0/third_party/lib/libghostty-vt.dylib`
  and reports RPC protocol version `0.4.0`.
- The local `../ghostline` checkout is now at `v0.6.0` (`01bdbfd`); Warren's
  event binary and the detached server still use the older `v0.5.0`/`v0.4.0`
  generations described above.

## Upgrade Path

The relevant path is `ensureGhostlineClient` in
`Headless/cmd/warren-headless/main.go`:

1. Connect to the stable ghostline socket.
2. Query the detached server's protocol version.
3. On a mismatch, spawn a fresh server on a temporary socket.
4. Ask the fresh server to adopt every session through the old admin socket.
5. The old server encodes one migration snapshot per session.
6. Only after all sessions are prepared and committed does Warren replace the
   stable socket symlink.
7. On any error, the fresh server exits and Warren keeps using the old client.

The failure occurs at step 5, before the new server can commit this session.

## What `-2` Means

`-2` is `GHOSTTY_INVALID_VALUE`. In this incident it is raised by the snapshot
grid encoder after a resize leaves an invalid wide-cell pair. A wide head must
be followed by a spacer tail; the encoder rejects a wide head at the right edge
or any other unpaired wide state.

This is a serialization precondition failure. It does not mean that the PTY
child exited, that the session is not interactive, or that the visible screen
cannot be formatted for display. Warren's normal display snapshot uses the
formatter path; migration uses the stricter persistent-state encoder.

## Confirmed Root Cause

The failing replay is deterministic with the old libghostty-vt library:

1. A 138-column session has a valid wide character whose head is at column
   `122` and whose spacer tail is at column `123`.
2. The session is resized to 123 columns while the alternate screen is
   present. Alternate screens use `reflow = false`.
3. Ghostty's no-reflow shrink path calls `page.clearCells(row, cols, old_cols)`.
   That clears the spacer tail at the new boundary but leaves the wide head at
   `cols - 1`.
4. Snapshot encoding visits both primary and alternate screens and returns
   `GHOSTTY_INVALID_VALUE` for the orphan head.

The retained spool replay reaches the same invalid grid after the resize and
returns `-2`. The historical live parser state is therefore not needed to
explain this failure.

## Ghostty Upstream Context

No upstream issue or pull request with this exact shrink-path failure was found.
The closest related change is [Ghostty PR #11135](https://github.com/ghostty-org/ghostty/pull/11135)
([commit `678601d94`](https://github.com/ghostty-org/ghostty/commit/678601d94)),
which fixes stale spacer heads when a no-reflow resize grows a screen. It does
not cover the orphan wide head left by a no-reflow shrink. Recent strict
snapshot validation makes the latent grid defect observable as `-2`; relaxing
that validation would hide corrupted state rather than fix it.

## Compatibility Fix

The workaround is deliberately confined to Ghostline's `VTTerminal` wrapper;
it does not fork or patch Ghostty:

- Before a no-reflow shrink, the wrapper reads the target boundary cell through
  Ghostty's public grid-reference API. If it is a wide head, the wrapper emits
  a local VT erase for that pair before calling `ghostty_terminal_resize`.
- `EncodeState` repairs an already-resized active screen as a fallback. If the
  first encode still returns `GHOSTTY_INVALID_VALUE`, it briefly visits the
  inactive alternate screen through mode 47, repairs the same boundary, restores
  the original active screen and cursor position, then retries the encode.
- The repair is skipped while the parser is off ground or origin mode is active,
  because the public API does not expose enough state to address those cases
  without changing terminal semantics.

The compatibility release also bumps the Ghostline protocol to `0.6.0`. During
rolling migration, the new server recognizes source protocols `0.4.0` and
`0.5.0`, keeps the old session paused, skips the old native snapshot request,
and rebuilds the destination emulator from the retained gzip archives and live
spool. Sources advertising newer protocols continue to use authoritative native
snapshot transfer, so the bridge is not part of the steady-state path.

This keeps Ghostline compatible with older libghostty-vt behavior while the
upstream fix is investigated. The VT repair is only present in newly started
Ghostline processes; the migration bridge is what lets a new process adopt an
already-running v0.4.0/v0.5.0 server without asking that old process to encode
the invalid state.

## Investigation Evidence

### Continuation tracking is a separate failure class

The same library can independently produce `-2` for an unterminated OSC
sequence larger than the configured continuation budget. We also reproduced
the restored-continuation case where tracking is unavailable after restore.
Those experiments explain why continuation tracking remains enabled in
Ghostline, but they do not match this incident:

- The retained spool replay encodes successfully before the resize.
- The same replay returns `-2` only after the 138-to-123 resize.
- Scans for large OSC input, partial UTF-8 input, and synchronized-update
  boundaries did not reproduce the archived session's failure.

### The retained spool reproduces the grid failure

The affected session's retained output consists of three gzip archives followed
by the current live spool. Replaying them in chronological order produced about
31 MB of PTY bytes.

- Full replay before resize: `EncodeState` succeeded.
- Replaying at 138x42, resizing to 123x40, and encoding: `-2` with the old
  wrapper/library combination; success with the Ghostline compatibility layer.
- 4 KiB incremental scan across the complete replay: zero failures.
- Byte-by-byte scan over the final 200 KiB, covering the upgrade failure period
  and subsequent output: zero failures.
- The live session still returns a normal display checkpoint and remains alive.

This reproduces the failure class from retained bytes, but it does not prove
that the historical live session used the same output sequence or resize
dimensions. The live emulator state and exact bytes around the original event
were not captured.

### Spool compaction is a separate evidence gap

Warren currently handles output compaction in two separate calls in
`Headless/internal/server/service.go`:

```go
_ = adapter.ArchiveSpool(ctx, session.Runtime)
_ = adapter.TruncateSpool(ctx, session.Runtime)
```

Ghostline feeds PTY bytes into the emulator and spool under `outputMu`, while
the host's archive and truncate operations are separate runtime calls. Archive
errors are ignored, and there is no single transaction covering archive,
truncation, and the persisted watcher offset. This can create a gap between
what the emulator has consumed and what remains available for later replay.

This remains a separate reliability issue because it can make live emulator
state unavailable for later replay. It is not required to explain the
reproducible `-2` after the no-reflow resize.

## Confirmed vs. Unconfirmed

### Confirmed

- The running detached server is ghostline protocol `0.4.0`.
- The new Warren daemon expects ghostline protocol `0.5.0`.
- Rolling upgrade is attempted automatically on protocol mismatch.
- The upgrade fails while encoding the migration snapshot for the session
  listed above.
- The error is `GHOSTTY_INVALID_VALUE` from `ghostty_snapshot_encode_alloc`.
- The old library's no-reflow shrink leaves orphan wide heads at the right
  edge; snapshot encoding rejects those cells on either screen.
- The old server is intentionally retained after the failed migration.
- The session is healthy from the user's point of view and can still produce a
  normal display snapshot.
- The Ghostline wrapper workaround makes the retained replay encodable after
  the same resize.
- A real old `v0.4.0` server with the minimized malformed state was adopted by
  the compatibility build through spool replay; its old socket retired and
  the transferred session remained usable.

### Unconfirmed

- Whether the historical live session used exactly the same byte sequence and
  dimensions as the retained replay.
- Whether spool compaction caused the emulator/spool evidence gap.
- Whether Ghostty will accept an upstream fix for both no-reflow shrink and
  grow paths.

## Impact

- Existing sessions remain on ghostline `v0.4.0` after every failed upgrade
  attempt.
- New sessions created after the daemon starts may still be served through the
  existing old server, so the process can remain on the older protocol longer
  than expected.
- No evidence of PTY termination or user-visible session data loss was found.
- Repeated daemon starts retry the upgrade and emit the same failure until the
  offending session ends or the migration path is fixed.

## Follow-up Work

1. Publish the Ghostline compatibility release with protocol `0.6.0`, update
   Warren's `go.mod`, and restart the detached server; an already-running
   v0.4.0 process cannot load code from a new binary in place.
2. File an upstream Ghostty issue with the minimized no-reflow shrink reproducer
   and the invalid-grid snapshot result.
3. Make spool archive/truncate and watcher re-anchoring atomic from the host's
   point of view, or refuse to truncate when archiving fails.
4. Preserve the current migration failure contract: do not retire the old
   server unless every session has been prepared and committed.
5. Retry the upgrade with the affected session still alive and verify that the
   stable socket reports `0.6.0` without ending the PTY child.

## Acceptance Criteria

- The affected session can be migrated while remaining interactive.
- The stable ghostline socket reports `0.6.0` after a successful daemon restart.
- No PTY output is lost across archive, migration, or re-anchoring boundaries.
- A deliberately unencodable session causes a clear, structured diagnostic and
  leaves the old server serving all sessions.
- The wide-boundary failure and compatibility fallback are covered by automated
  Ghostline tests.
