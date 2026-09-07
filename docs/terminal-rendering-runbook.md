# Terminal Black Screen and Missing Text Troubleshooting Runbook

Use this runbook when the Warren app is still interactive but a terminal pane
is black, blank, partially rendered, or appears to lose text after a workspace,
tab, attach, or resize operation. The goal is to separate a desktop
presentation failure from a missing PTY byte or runtime failure before the
short-lived logs are overwritten.

If the whole app is unresponsive, shows a spinner, or has a sustained CPU or
deadlock symptom, use [the desktop freeze runbook](desktop-freeze-runbook.md)
instead.

## 1. Preserve the evidence first

Do not restart Warren or delete `~/.warren` until the logs and an independent
CLI read have been captured. A small evidence bundle is usually enough:

```sh
stamp=$(date +%Y%m%d-%H%M%S)
bundle="/tmp/warren-terminal-$stamp"
mkdir -p "$bundle"

for path in \
  ~/Library/Logs/Warren/terminal-diagnostics.log \
  ~/Library/Logs/Warren/terminal-diagnostics.log.1 \
  ~/.warren/headless.log \
  ~/.warren/headless.log.1 \
  ~/.warren/ghostline.log \
  ~/.warren/ghostline.log.1
do
  if [ -f "$path" ]; then
    cp -p "$path" "$bundle/"
  fi
done

ls -lh "$bundle"
```

The important locations are:

| Path | What it contains | Retention |
| --- | --- | --- |
| `~/Library/Logs/Warren/terminal-diagnostics.log` | Desktop terminal lifecycle and presentation milestones | Direct file writes, not `os_log`; rotates to `.log.1` at 2 MiB |
| `~/.warren/headless.log` | Headless daemon start/stop, restore, tunnel, and error events | Rotates to `.log.1` at 5 MiB |
| `~/.warren/ghostline.log` | Ghostline adoption, cursor, and upgrade diagnostics | Keep the current file and any existing archive |

The diagnostics file is intentionally independent of the unified log. A busy
`logd` or a throttled `os_log` stream must not be mistaken for an empty
terminal. Capture the file mtime as well as its contents:

```sh
stat -f '%Sm %z bytes' -t '%Y-%m-%d %H:%M:%S' \
  ~/Library/Logs/Warren/terminal-diagnostics.log
tail -100 ~/Library/Logs/Warren/terminal-diagnostics.log
```

## 2. Establish whether bytes still exist

Use the Warren CLI as an independent client of the same Host. Replace
`SESSION_ID` with the affected session; add `--endpoint NAME` when the session
is on a configured remote endpoint.

```sh
warren session list --all --json
warren session read SESSION_ID --timeout 8s
warren session read SESSION_ID --contains 'A_KNOWN_MARKER' --timeout 8s
```

The marker should be text that the terminal definitely emitted (a prompt,
command result, or a unique line from the incident). `session read` attaches to
the session and reads the current output stream; it does not require the
desktop renderer.

Interpret the result before investigating individual rendering calls:

| Observation | Initial conclusion | Next check |
| --- | --- | --- |
| CLI reads the expected text while the desktop pane is black | Host, session, and output path are probably healthy; suspect desktop/Ghostty presentation or view lifecycle | Inspect `terminal-diagnostics.log` around the last switch/attach |
| CLI cannot read new text and Ghostline reports no cursor progress | Suspect the PTY process or Runtime rather than drawing | Inspect headless and Ghostline logs and the session's foreground process |
| CLI reads live text but cold desktop recovery fails | The cursor stream is healthy; suspect atomic-state negotiation, install, or presentation | Correlate `atomic_recovery_*`, `recovery_anchor`, and `present_*` events |

For a remote endpoint, daemon and Ghostline logs live on that Host. Run log
checks there; a local file does not describe the remote Runtime.

## 3. Check the recovery boundary

Headless logs the selected branch and anchor for every attach. Keep these
events together with the Ghostline cursor diagnostics:

```sh
rg 'recovery|cursor|atomic.state|checkpoint' \
  ~/.warren/headless.log ~/.warren/ghostline.log | tail -150
```

For a cold desktop attach, the expected order is measured focused resize,
`attached`, one atomic-state binary frame (`ghostty-vt-snapshot-v1` for
Desktop or `ghostline-vt-replay-v1` for Web/mobile/CLI), matching `synced`,
then live cursor output. A passive subscriber must not resize the Runtime.
Protocol 4 clients negotiate the format during authentication; there is no
implicit replay or snapshot fallback path.

Do not interpret a changed `epoch` as byte loss by itself. Compare the full
`epoch + sequence` anchor and confirm that the atomic-state frame and `synced`
marker carry the same boundary.

## 4. Read desktop presentation diagnostics

Each line in `terminal-diagnostics.log` is JSON. The following filter keeps the
events that describe the attach and draw path:

```sh
diagnostics=~/Library/Logs/Warren/terminal-diagnostics.log
rg '"event":"(workspace_switch|terminal_tab_switch|terminal_view_appear|select_session|attach_start|attach_size|attach_complete|atomic_recovery_installed|atomic_recovery_failed|recovery_anchor|feed_output|present_now|present_stall_suspected|present_complete|present_wait_timeout|present_wait_extended|activation_resync|roster_apply|resize_request|viewport_sync)"' \
  "$diagnostics" | tail -150
```

Use the events as a sequence rather than treating one line as a root cause:

| Event or fields | Meaning and diagnostic use |
| --- | --- |
| `workspace_switch`, `terminal_tab_switch`, `terminal_view_appear`, `select_session` | The user/navigation transition that may have mounted or replaced a terminal view |
| `attach_start` → `attach_size` → `attach_complete` | Whether the selected session completed the client attach and which grid size was used |
| `recovery_anchor` → `atomic_recovery_installed` → matching `recovery_anchor` with `synced=true` | The native state was installed behind the recovery gate and reached its atomic presentation boundary |
| `feed_output` | Output was accepted by the selected desktop surface; correlate its `session` and `bytes` with the incident window |
| `present_now` with `surfaceReady`, `viewAttached`, `viewHidden`, `viewVisible` | Whether a draw was attempted and whether the native view was actually able to show it |
| `present_stall_suspected` with `reason` | A draw happened while the view was absent, unattached, hidden, or not visible; this strongly favors a lifecycle/presentation issue |
| `present_complete` | Recovery reached a ready surface and presentable view. Warm promotions log the fixed `targetEpoch/targetSequence` boundary they waited for; cold attaches log the atomic anchor. |
| `present_wait_timeout` | A promotion did not consume its fixed output boundary within two seconds. The pane is revealed as a bounded fallback; correlate the rendered and enqueued sequences with writer/reset events. |
| `present_wait_extended` | Legacy diagnostic from the previous Zeno wait; current promotions use a fixed boundary and `present_wait_timeout` fallback. |
| `activation_resync` | A warm surface reattach detected that the viewport did not return to its pre-demotion anchor (captured at `demote`) and forced a live-bottom jump (no animation) plus immediate draw; scrollback remains intact so upward scroll after the jump still works. Its absence means the reattach kept the user's scroll position |
| `roster_apply` | Roster processing and retained-surface count; repeated events indicate churn but do not prove that a changed projection was published |
| `resize_request`, `viewport_sync` | Grid-size negotiation. Rapid resizes are debounced (50ms) and promotion defers 250ms after resize to let actively outputting shells settle at the new width; a brief buffered delay replaces 1-2s of missing color blocks. |

The default file records milestone events. Successful visible draws and normal
`feed_output` events are verbose-only after the initial attach nudge, so their
absence in a non-verbose file is not evidence that no bytes were rendered.

The most useful patterns are:

- `attach_complete` and `feed_output` are present, the CLI sees the text, but
  there is no successful `present_complete`, or `present_now` reports
  `surfaceReady=false`: investigate surface ownership and teardown first.
- `present_stall_suspected` reports `view-not-attached`, `view-hidden`, or
  `view-not-visible`: the draw path ran before the AppKit view was presentable.
- `present_wait_extended` shows a ready output sequence but an unready view:
  this is a desktop lifecycle/presentation stall. The presentation task keeps
  waiting past the diagnostic marker, so compare the event with later
  `present_complete` events before concluding the pane is lost. If both the
  rendered and target sequences are behind, continue with the Host/Ghostline
  recovery-boundary checks.
- A warm tab shows only recent history until the window is resized: this is
  the scrollback-compression lazy-restore path. Warren disables idle
  compression and resyncs a reattached viewport only when its pre-demotion
  anchor no longer matches
  (see `problems/2026-08-17-warm-reattach-truncated-scrollback.md`); a
  missing `activation_resync` after an abnormal warm attach is evidence the
  fix is not in the running build.
- After switching from an empty workspace to one with tabs, repeated
  `terminal_view_appear` events followed by `surfaceReady` changing from true
  to false indicate a surface lifecycle/ownership race. This is the failure
  documented in [lesson #003](lessons.md#003---black-terminal-pane-after-empty-workspace---populated-workspace),
  not evidence that the PTY stopped producing bytes.
- A new `epoch` with a lower sequence is a normal reanchor boundary. Verify the
  snapshot and `synced` anchors before calling it missing text.

## 5. Reproduce with verbose diagnostics

The default file contains milestone events. Enable the verbose Ghostty stream
only for a short, controlled reproduction:

```sh
diagnostic_dir="/tmp/warren-terminal-verbose-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$diagnostic_dir"

WARREN_TERMINAL_DIAGNOSTICS=1 \
WARREN_TERMINAL_DIAGNOSTICS_DIR="$diagnostic_dir" \
/Applications/Warren.app/Contents/MacOS/Warren --terminal-diagnostics
```

Quit the existing Warren GUI first. Warren uses a single-instance lock, so
starting a second GUI may only forward the launch request to the already
running process. The headless daemon, ghostline server, and terminal sessions
can remain running while the GUI is relaunched.

Reproduce one workspace or tab switch, then stop the GUI and copy the verbose
directory into the evidence bundle. Verbose logging is intentionally noisy and
should not be left enabled during a long session.

## 6. Safe recovery

When the evidence shows a desktop-only failure, quit and relaunch the Warren
GUI, not the headless service. Sessions are owned by the Host and should remain
available through either the CLI or the local Web UI:

```sh
warren session read SESSION_ID --timeout 8s
```

The Web UI is normally available at `http://127.0.0.1:8789` when the local
daemon is running. A successful CLI/Web attach after a GUI restart confirms
that the session survived.

Do not delete `~/.warren/output`, `~/.warren/state.json`, or the diagnostic
logs while investigating. Restart only the control-plane daemon when the CLI
and logs point to a Host-side failure. Never stop the separate Ghostline serve
process during diagnosis; doing so ends the PTYs and destroys the evidence.

## 7. Incident handoff checklist

Attach the following to a bug or investigation:

- local time, timezone, Warren build/commit, and endpoint;
- session ID and runtime name;
- whether the app remained interactive, and the last action (workspace switch,
  tab switch, attach, resize, or command output);
- the CLI read result and the recovery/cursor log boundary;
- the relevant `terminal-diagnostics.log` lines, including the preceding
  switch/attach events and the following present/timeout events;
- `headless.log` and `ghostline.log` lines from the same time window;
- whether a GUI-only restart, resize, or tab switch recovered the pane.

## Related documents

- [Desktop freeze runbook](desktop-freeze-runbook.md) — app-wide hangs and
  spinner/deadlock symptoms
- [Engineering lessons](lessons.md) — historical terminal and lifecycle incidents
- [Headless architecture](headless-architecture.md) — cursor, ring, epoch, and
  atomic-state recovery semantics
- [Terminal runtime](runtime.md) — current Ghostline-only behavior
- [One-way desktop rendering RFC](rfc/0002-one-way-desktop-rendering.md) —
  terminal surface lifecycle architecture
