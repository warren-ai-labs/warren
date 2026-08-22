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

Do not restart Warren or delete `~/.warren` until the logs and the output spool
have been copied. A small evidence bundle is usually enough:

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
| `~/.warren/ghostline.log` | ghostline adoption/upgrade diagnostics when the ghostline runtime is used | Keep the current file and any existing archive |
| `~/.warren/output/<runtime>.out` | Raw PTY bytes for a session | May be compacted or archived by the runtime; do not remove it |

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
warren session read SESSION_ID --terminal --timeout 8s
warren session read SESSION_ID --terminal --contains 'A_KNOWN_MARKER' --timeout 8s
```

The marker should be text that the terminal definitely emitted (a prompt,
command result, or a unique line from the incident). `session read` attaches to
the session and reads the current output stream; it does not require the
desktop renderer.

Interpret the result before investigating individual rendering calls:

| Observation | Initial conclusion | Next check |
| --- | --- | --- |
| CLI reads the expected text while the desktop pane is black | Host, session, and output path are probably healthy; suspect desktop/Ghostty presentation or view lifecycle | Inspect `terminal-diagnostics.log` around the last switch/attach |
| CLI cannot read new text, but the raw spool is still growing | Bytes reach the runtime but are not reaching the client; suspect spool watcher, attach, or stream recovery | Inspect headless and ghostline logs, then compare epochs/sequences |
| CLI and spool both stop at the same point | Suspect the PTY process, runtime, or session itself rather than drawing | Check runtime/process state and the session's last command |
| Only tmux colored blocks or soft-wrapped history look wrong | Known tmux snapshot/BCE replay limitation, not proof of lost PTY bytes | See [lesson #001](lessons.md#001---tmux-snapshot-replay-misaligns-tui-color-blocks-and-why-ghostline-exists) |

For a remote endpoint, the spool and daemon logs live on that Host. Run the
filesystem checks there; the CLI result alone cannot prove that a local spool
file exists.

## 3. Check the raw spool

Find the session's `runtime` value in the JSON returned by `session list`, then
inspect the corresponding file on the Host:

```sh
runtime='RUNTIME_FROM_SESSION_JSON'
spool="$HOME/.warren/output/$runtime.out"

stat -f '%Sm %z bytes' -t '%Y-%m-%d %H:%M:%S' "$spool"
rg -a --fixed-strings 'A_KNOWN_MARKER' "$spool"
```

To tell a stalled file from a quiet one, sample its size twice:

```sh
stat -f '%z' "$spool"
sleep 2
stat -f '%z' "$spool"
```

Raw PTY output includes carriage returns, alternate-screen control sequences,
cursor movement, and erase commands. Use a byte view only when text searches
are inconclusive:

```sh
od -An -tx1 -c "$spool" | tail -80
```

Do not interpret a changed `epoch` as byte loss by itself. An epoch change
means the Host reanchored after compaction or snapshot recovery; compare the
epoch first, then compare the sequence within that epoch.

## 4. Read desktop presentation diagnostics

Each line in `terminal-diagnostics.log` is JSON. The following filter keeps the
events that describe the attach and draw path:

```sh
diagnostics=~/Library/Logs/Warren/terminal-diagnostics.log
rg '"event":"(workspace_switch|terminal_tab_switch|terminal_view_appear|select_session|attach_start|attach_size|attach_complete|feed_output|present_now|present_stall_suspected|present_complete|present_wait_extended|activation_resync|roster_apply|resize_request|viewport_sync)"' \
  "$diagnostics" | tail -150
```

Use the events as a sequence rather than treating one line as a root cause:

| Event or fields | Meaning and diagnostic use |
| --- | --- |
| `workspace_switch`, `terminal_tab_switch`, `terminal_view_appear`, `select_session` | The user/navigation transition that may have mounted or replaced a terminal view |
| `attach_start` → `attach_size` → `attach_complete` | Whether the selected session completed the client attach and which grid size was used |
| `feed_output` | Output was accepted by the selected desktop surface; correlate its `session` and `bytes` with the incident window |
| `present_now` with `surfaceReady`, `viewAttached`, `viewHidden`, `viewVisible` | Whether a draw was attempted and whether the native view was actually able to show it |
| `present_stall_suspected` with `reason` | A draw happened while the view was absent, unattached, hidden, or not visible; this strongly favors a lifecycle/presentation issue |
| `present_complete` | The delayed attach presentation reached a ready surface and presentable view |
| `present_wait_extended` | The first 2-second present window passed but the presentation task is still waiting; this is diagnostic only and no longer means the attempt was abandoned |
| `activation_resync` | A warm surface reattach detected that the viewport did not return to its pre-demotion anchor (captured at `demote`) and forced a live-bottom resync plus immediate draw; its absence means the reattach kept the user's scroll position |
| `roster_apply` | Roster processing and retained-surface count; repeated events indicate churn but do not prove that a changed projection was published |
| `resize_request`, `viewport_sync` | The grid-size negotiation around the black pane; a resize that recovers the pane is useful evidence, not a root-cause fix |

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
  rendered and target sequences are behind, continue with the Host/spool
  checks.
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
- A new `epoch` with a lower sequence is a normal reanchor boundary. Do not
  call it missing text until the raw spool and the new snapshot have been
  compared.

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
warren session read SESSION_ID --terminal --timeout 8s
```

The Web UI is normally available at `http://127.0.0.1:8789` when the local
daemon is running. A successful CLI/Web attach after a GUI restart confirms
that the session survived.

Do not delete `~/.warren/output`, `~/.warren/state.json`, or the diagnostic
logs while investigating. Restart the daemon or runtime only when the CLI and
spool evidence points to a Host-side failure; record that restart as part of
the incident because it changes the evidence.

## 7. Incident handoff checklist

Attach the following to a bug or investigation:

- local time, timezone, Warren build/commit, and endpoint;
- session ID and runtime name;
- whether the app remained interactive, and the last action (workspace switch,
  tab switch, attach, resize, or command output);
- the CLI result and the raw spool mtime/size/marker result;
- the relevant `terminal-diagnostics.log` lines, including the preceding
  switch/attach events and the following present/timeout events;
- `headless.log` and `ghostline.log` lines from the same time window;
- whether a GUI-only restart, resize, or tab switch recovered the pane.

## Related documents

- [Desktop freeze runbook](desktop-freeze-runbook.md) — app-wide hangs and
  spinner/deadlock symptoms
- [Engineering lessons](lessons.md) — known tmux/BCE and terminal lifecycle
  incidents
- [Headless architecture](headless-architecture.md) — spool, ring, epoch, and
  snapshot recovery semantics
- [Runtime comparison](runtime.md) — ghostline versus tmux behavior
- [One-way desktop rendering RFC](rfc/0002-one-way-desktop-rendering.md) —
  terminal surface lifecycle architecture
