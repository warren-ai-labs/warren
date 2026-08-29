# Codex TUI Black Foreground: A Reproducible Terminal Rendering Investigation

- Recorded: 2026-08-29 (Asia/Shanghai)
- Status: Fix applied and verified on a real macOS Warren Desktop build
- Scope: Warren Desktop, the local Ghostline runtime, the native Ghostty
  snapshot protocol, and the `codex-luna-max` TUI
- Endpoint: `local` only
- User-visible symptom: Codex's `Working` label or shimmer could become black
  and disappear on Warren's dark terminal background after a cold attach,
  workspace switch, or snapshot recovery
- Fix: preserve the native snapshot protocol and reapply Warren's already-built
  Ghostty runtime configuration immediately after a successful native restore

This is an evidence record, not a claim that an earlier commit, test, or
explanation was correct. The investigation started from the user's instruction
to distrust the existing implementation and prove the first divergent boundary
with a real shell and a real Codex TUI.

## Executive result

The terminal path is:

```text
Codex TUI bytes
  -> Ghostline PTY
  -> Ghostline VT state
  -> native snapshot encode/decode
  -> client Ghostty state
  -> refresh/display-link
  -> draw/framebuffer
```

The first observed semantic mismatch was not in Codex's PTY output, Ghostline,
the snapshot cursor, `refresh`, the display link, `draw`, or the framebuffer. It
was at the client call to `ghostty_surface_restore_snapshot`:

1. Before restore, a query of the live client terminal returned Warren's
   configured defaults:

   ```text
   OSC 10: rgb:eaea/e8e8/e6e6   (foreground #eae8e6)
   OSC 11: rgb:1515/1111/1010   (background #151110)
   ```

2. The native snapshot restored the visible grid and cursor correctly, but it
   also replaced the per-surface default-color state. The same OSC queries then
   returned black defaults in the old implementation.

3. Codex uses OSC 10/11 to choose the base and highlight colors for its
   `Working` shimmer. Once it cached the restored black foreground, it emitted
   a black foreground SGR and the label disappeared against `#151110`.

4. Reapplying the current Ghostty configuration after the successful restore
   made the client answer the same OSC queries as the live path. The next
   Codex frame therefore used the same terminal semantics before and after
   recovery.

The minimal fix is in commit `3522a545` (`fix: preserve terminal defaults after
native snapshot restore`). It keeps the desktop's `ghostty-vt-snapshot-v1`
fast path, does not switch to ANSI replay, and does not add an unconditional
high-frequency draw loop.

The goal that constrained the work is recorded in [GOAL.md](../../GOAL.md).

## The investigation in chronological order

The order matters because several changes made the symptom look better without
explaining it. Each row was a hypothesis to falsify, not an accepted cause:

| Phase | Hypothesis or experiment | Result |
| --- | --- | --- |
| 1 | Treat the black `Working` label as a contrast problem; try Ghostty `minimum-contrast` values `4.5`, `2.5`, and `1.8` | Values above the black-background ratio promoted text to white and flattened the shimmer; the shader behavior was misunderstood |
| 2 | Use `minimum-contrast=1.2` after measuring the darkest shimmer sample | Pure black became visible while `#2a2625` remained grey; this is a narrow visual guard, not the restore root cause |
| 3 | Rewrite black SGR bytes in Warren's output writer | The label became visible, but Composer backgrounds and unrelated color blocks changed; the rewrite was discarded |
| 4 | Compare the working embedded-SSH workspace and vary `TERM`, `COLORTERM`, `TERM_PROGRAM`, `PROGRAM`, `NO_COLOR`, and `CI` | `COLORTERM` and `NO_COLOR` changed capability detection; `TERM_PROGRAM`/`PROGRAM` did not explain the Warren-only transition |
| 5 | Add or force refresh/draw/timer work | Draws completed, but terminal semantic defaults remained wrong; presentation was downstream |
| 6 | Trace bytes, Ghostline anchors, native restore, OSC replies, and present events in one real TUI window | The first mismatch appeared immediately after native snapshot restore |
| 7 | Reapply the existing Ghostty config under the writer feed lock | OSC 10/11, live cursor continuation, and the real Codex animation stayed consistent across recovery |

This sequence is useful when repeating the incident: a visual improvement is not
evidence of a causal fix unless the experiment also removes the first observed
state mismatch.

## Codex's color dependency

Codex performs a terminal palette probe during startup. In the source inspected
for this incident, the shimmer uses the terminal's default foreground as its
base (`#eae8e6` in Warren) and the default background as its highlight
(`#151110`). Its blend is approximately:

```text
shimmer(t) = blend(default_bg, default_fg, t * 0.9)
```

With the correct defaults, the darkest sample is approximately
`0.9 * 21 + 0.1 * 234 = 42` (`#2a2625`), while the bright frame approaches
`#eae8e6`. This is why a terminal that answers OSC 10/11 differently can
produce a visibly different spinner even when the PTY bytes and layout are
otherwise identical.

The distinction is important:

- an environment capability change controls whether Codex emits RGB SGR at
  all;
- a snapshot restore state change controls the palette values Codex learns;
- a Ghostty contrast setting controls how the renderer displays a received
  foreground;
- a framebuffer lifecycle issue controls whether a valid rendered pixel is
  visible.

They are four different boundaries and require four different probes.

## Investigation contract

The following rules kept the investigation falsifiable.

- Treat history, current code, existing tests, and previous diagnoses as
  hypotheses. A passing unit test is not proof that a real TUI is correct.
- Use a real Warren shell session and the real `codex-luna-max` executable.
  Do not substitute a fake terminal, a scripted frame generator, or a standard
  library terminal mock for acceptance.
- Keep Desktop on its existing native snapshot protocol. Web/CLI replay is a
  different client contract and cannot explain a Desktop-only mismatch.
- Compare one time window at every boundary. Do not change color rules,
  snapshot format, timers, and drawing in the same experiment.
- Identify the first state mismatch before changing that layer. A later
  successful draw cannot repair a state that was already wrong upstream.
- Use `warren --endpoint local` for every Warren command in this document.
  An endpoint name is part of a resource identity; a session with the same
  display name on another endpoint is not the same experiment.
- After each implementation change, run the real TUI reproduction and the
  relevant automated checks. Keep the visual result and the diagnostic event
  order together.
- Install only with `mise run install`. Normal iteration uses the current
  checkout's build and does not require reinstalling the app.

## Rendering chain and invariants

The complete chain is easier to debug when every layer has one explicit owner:

| Layer | Owner and state | Invariant used in the investigation |
| --- | --- | --- |
| Codex process | `codex-luna-max` decides when to query OSC 10/11 and which SGR sequences to emit | The application byte stream is observed before assigning blame to a renderer |
| PTY transport | Ghostline owns one persistent PTY per Warren Session | A CLI read of the same session must see the acceptance marker |
| Ghostline VT | The server-side VT emulator tracks cursor, screen, SGR, and native checkpoint state | The checkpoint and its `(epoch, sequence)` boundary are paired |
| Wire protocol | The Host sends `attached`, one `ghostty-vt-snapshot-v1` atomic frame, matching `synced`, then live output | The snapshot is opaque on the wire; Desktop does not replay it through ANSI |
| Client Ghostty | `InMemoryTerminalSession` restores the native surface and receives later PTY bytes | Restoring a grid must not leave Warren's configured default palette changed |
| Presentation | `refresh`/tick, display-link, `ghostty_surface_draw`, AppKit view visibility, framebuffer | A successful draw is checked only after semantic state is known to match |

The Host cursor and the visual framebuffer are intentionally independent. A
matching cursor proves ordering, not color. A visible pixel proves presentation,
not that Codex received the expected OSC answer. The investigation therefore
records both byte/state evidence and presentation timing.

## 1. Reproduction prerequisites

### Host and software

The original reproduction was run on an Apple Silicon macOS host with:

- the Warren checkout and its Swift/Go dependencies;
- `mise` (the repository task runner);
- a locally available `codex-luna-max` command;
- an initialized Warren `local` endpoint at `http://127.0.0.1:8789`;
- a running detached Ghostline serve process owning the PTYs.

On a newly installed machine, initialize the application and the local CLI
endpoint only through the repository task:

```sh
mise run install
```

Do not use an ad-hoc copy of `Warren.app`, manually edit Warren state, or point
the experiment at an SSH/remote endpoint. The rest of this document assumes
that `local` already exists:

```sh
warren endpoint list | rg '\blocal\b'
```

`endpoint list` reads the CLI's local endpoint configuration and does not dial a
Host. Every project/workspace/session/agent resource command below explicitly
spells out `--endpoint local`.

### Build the current checkout

The web bundle is not relevant to this native rendering diagnosis. Reuse the
current build path:

```sh
WARREN_SKIP_WEB_BUILD=1 mise run build
```

This produces `Warren.app` in the checkout and rebuilds the headless/CLI
artifacts used by the local endpoint. If the build fails, record the failure
and do not call a stale installed binary a validation of the change.

### Launch the Desktop diagnostics stream

The GUI uses a single-instance lock. Quit only the existing GUI before starting
the checkout build; leave `warren-headless`, Ghostline serve, and the test
sessions alive.

```sh
diagnostic_dir="/tmp/warren-terminal-codex-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$diagnostic_dir"

osascript -e 'tell application id "com.abcdlsj.warren" to quit' \
  >/dev/null 2>&1 || true

WARREN_TERMINAL_DIAGNOSTICS=1 \
WARREN_TERMINAL_DIAGNOSTICS_DIR="$diagnostic_dir" \
  ./Warren.app/Contents/MacOS/Warren --terminal-diagnostics
```

If another Warren process still owns the single-instance lock, wait for it to
exit instead of launching a second copy. The diagnostics file is written as
JSON milestone lines at:

```text
$diagnostic_dir/terminal-diagnostics.log
```

With `WARREN_TERMINAL_DIAGNOSTICS=1`, the vendored `GhosttyTerminal` stream is
also appended to the same file. A normal run records milestones; verbose mode
records per-draw and native output details and should be enabled only for one
short reproduction.

The installed default locations, useful when the GUI was launched normally,
are:

```text
$HOME/Library/Logs/Warren/terminal-diagnostics.log
$HOME/.warren/headless.log
$HOME/.warren/ghostline.log
```

Do not delete or rotate these files while collecting evidence. The desktop log
rotates at 2 MiB; the headless log rotates at 5 MiB.

## 2. Create a real shell and a real Codex TUI

### Resolve IDs, never infer them from names

A Warren project, workspace, session, agent session, and transcript have
different identities. Resolve the exact workspace ID from a fresh local roster:

```sh
warren --endpoint local --json workspace list --all
warren --endpoint local --json session list --all
```

Use the `id` of the workspace that owns the experiment. Do not copy an ID from
an old log or assume that the current working directory identifies a session.
For a scripted retry, `jq` can select a workspace by a known path or branch;
inspect the JSON first and adjust the predicate to the current roster:

```sh
workspace_id="$({
  warren --endpoint local --json workspace list --all
} | jq -r '.[0].id')"
test -n "$workspace_id" && test "$workspace_id" != null
```

The `.[0]` selection above is only a shell placeholder. For a real incident,
replace it with a predicate that uniquely matches the intended workspace and
verify the result before creating anything.

### Create an isolated generic PTY session

`session` is deliberately used here instead of `agent`: the goal is to see the
raw PTY bytes and the TUI, not the normalized Agent transcript.

```sh
session_json="$(warren --endpoint local --json session create "$workspace_id" \
  --kind shell --command bash --title codex-black-repro)"
session_id="$(printf '%s\n' "$session_json" | jq -r '.id // .warrenSessionId')"
test -n "$session_id" && test "$session_id" != null
printf 'session_id=%s\n' "$session_id"
```

Ghostline starts an interactive shell and Warren types the requested command
into it. If the local `codex-luna-max` command is only an interactive-shell
alias, create the session with the user's interactive shell instead (for
example `--command zsh`) or invoke the absolute executable after checking it:

```sh
warren --endpoint local session send "$session_id" 'command -v codex-luna-max'
warren --endpoint local session read "$session_id" --timeout 3s
warren --endpoint local session send "$session_id" \
  'printf "TERM=%s\\nCOLORTERM=%s\\nTERM_PROGRAM=%s\\nPROGRAM=%s\\nNO_COLOR=%s\\n" "$TERM" "$COLORTERM" "$TERM_PROGRAM" "$PROGRAM" "${NO_COLOR-<unset>}"'
warren --endpoint local session read "$session_id" --timeout 3s
```

Start the real TUI:

```sh
warren --endpoint local session send "$session_id" 'codex-luna-max'
warren --endpoint local session read "$session_id" --timeout 8s
```

Open the corresponding workspace/session in the diagnostic Warren GUI. The
CLI read is an independent observer of the same Host output; it does not use
the desktop renderer and therefore helps separate missing bytes from a bad
framebuffer.

### Trigger a visible Working interval

While the Codex TUI is active, submit a command that takes long enough for the
Working animation to cross an attach or switch boundary. The same command was
used for the final acceptance:

```text
sleep 20; printf CODEX_BLACK_ACCEPTANCE_OK
```

It can be entered in the TUI itself, or sent to the PTY when the TUI is the
foreground program:

```sh
warren --endpoint local session send "$session_id" \
  'sleep 20; printf CODEX_BLACK_ACCEPTANCE_OK'
warren --endpoint local session read "$session_id" \
  --contains CODEX_BLACK_ACCEPTANCE_OK --timeout 30s
```

Observe the GUI while the command runs. To exercise the cold native recovery
path, switch to another Warren workspace/tab and back, or quit and relaunch the
GUI while the PTY remains alive. The exact action is less important than
recording it beside the diagnostics timestamp. A normal warm promotion and a
cold recovery are different paths; do not label every tab switch a snapshot
restore without checking the event log.

## 3. Capture bytes before interpreting pixels

Capture raw output to a binary file. Do not pipe a TUI through a text filter
before preserving the original bytes:

```sh
evidence_dir="/tmp/codex-terminal-evidence-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$evidence_dir"

warren --endpoint local session read "$session_id" --timeout 8s \
  >"$evidence_dir/session.raw"
```

`session read` returns PTY data, including control sequences. The command may
include a small amount of prior output because the Host keeps a bounded ring;
record the start time and the marker used to delimit the interval.

Inspect bytes without allowing a terminal emulator to reinterpret them:

```sh
od -An -tx1 -c "$evidence_dir/session.raw" | less
```

Extract SGR sequences in a binary-safe way (the exact colors matter; a visual
copy/paste does not):

```sh
perl -0ne '
  while (/\e\[([0-9;?]*)m/g) {
    print "ESC[${1}m\n"
  }
' "$evidence_dir/session.raw" | sort -u
```

The relevant forms seen during the experiments were:

```text
ESC[38;2;0;0;0m       pure-black truecolor foreground
ESC[38;2;215;213;211m
ESC[38;2;167;165;163m
ESC[38;2;108;105;103m
ESC[38;2;60;56;55m
ESC[38;2;42;38;37m
ESC[38;2;234;232;230m
```

The grey values are Codex's shimmer samples. Whether the pure-black sequence
appears depends on the terminal defaults Codex observed; seeing a black SGR in
the PTY is evidence that the application emitted it, not evidence that the
renderer is at fault.

## 4. Probe OSC 10/11 at the same boundary

Codex's shimmer depends on the terminal's default foreground and background.
Probe those defaults from the actual PTY before and after a Desktop recovery.
The probe must be sent through the shell/TUI session, not a fake in-process
terminal:

```sh
warren --endpoint local session send "$session_id" \
  'printf "\033]10;?\033\\\033]11;?\033\\"'
warren --endpoint local session read "$session_id" --timeout 3s \
  >"$evidence_dir/osc-query.raw"
```

There are two byte directions, and confusing them invalidates the experiment:

- The query (`ESC ] 10 ; ? ...` / `ESC ] 11 ; ? ...`) is PTY output and can be
  captured by `session read`.
- The terminal's reply is a `terminal -> host` callback. It is input to the
  process, not necessarily another PTY-output chunk, so `session read` alone
  is not proof of the *client* Ghostty state.

With verbose Desktop diagnostics enabled, `TerminalDebugLog` records that
callback as a line beginning with `[GhosttyTerminal][...][input] host <- terminal`.
Search the same log immediately after the probe:

```sh
rg 'host <- terminal.*(eaea|1515|0000|rgb:)' \
  "$diagnostic_dir/terminal-diagnostics.log" | tail -40
```

If Codex currently owns the foreground input, wait for its shell prompt or
use a fresh isolated session for the probe. The parser below is useful only if
the shell was explicitly made to read and print the terminal response; it is
not a substitute for the verbose Desktop callback log:

```sh
perl -0ne '
  while (/\e\]10;.*?(?:\a|\e\\)/g) { print "$&\n" }
  while (/\e\]11;.*?(?:\a|\e\\)/g) { print "${&}\n" }
' "$evidence_dir/osc-query.raw"
```

When a shell round-trip is used, the corrected live/native response is:

```text
ESC]10;rgb:eaea/e8e8/e6e6 ESC + backslash
ESC]11;rgb:1515/1111/1010 ESC + backslash
```

Repeat the exact probe after the GUI has installed a native snapshot. In the
old implementation, the restore changed these semantic defaults to black even
though the restored text and cursor looked structurally valid. That comparison
is the decisive experiment. The verbose client callback remains authoritative
when the shell does not echo the response.

## 5. Reproduce the environment-variable matrix

The embedded SSH workspace observation was useful: its Codex spinner worked,
which suggested an environment difference. The matrix proved that environment
variables do affect Codex's color capability, but also that they do not explain
the post-snapshot divergence by themselves.

### What Warren supplies

The local Ghostline path sanitizes launcher noise before starting an interactive
session:

- an empty or `dumb` `TERM` becomes `xterm-ghostty`;
- a missing/empty `COLORTERM` becomes `truecolor`;
- ambient `NO_COLOR` is removed because the *presence* of `NO_COLOR`, even with
  an empty value, disables color in common TUI libraries;
- Ghostline also receives bundled `xterm-ghostty` terminfo when needed.

These rules are implemented in `Headless/internal/runtime/env.go` and
`Headless/internal/server/ghostline.go`. A user-provided session environment
can still intentionally opt out, so inspect the real child environment rather
than guessing from the outer launcher.

### Baseline observed in Warren Desktop

```text
TERM=xterm-ghostty
COLORTERM=truecolor
TERM_PROGRAM=
PROGRAM=
```

### Matrix results

| Variant | Observed Codex output | Interpretation |
| --- | --- | --- |
| `TERM=xterm-ghostty`, `COLORTERM=truecolor` | truecolor shimmer | Warren baseline |
| `COLORTERM` missing or empty | no truecolor shimmer | capability detection changed |
| `TERM=xterm-256color`, `COLORTERM=truecolor` | still truecolor | `TERM` name is not the deciding variable when truecolor is advertised |
| `TERM_PROGRAM=ghostty` | same as baseline | not causal |
| `TERM_PROGRAM=vscode` | same as baseline | not causal; the outer harness value was a red herring |
| `NO_COLOR=1` | color disabled | expected opt-out |
| `NO_COLOR=` | also color disabled in the tested libraries | presence-sensitive trap |
| `CI=1` | color remained in this experiment | not a reliable explanation for this issue |

### Repeat one matrix row with a fresh real TUI

Do not mutate one live TUI through all rows: its cached terminal palette would
make the rows incomparable. Create a fresh shell session for each row and
replace `env_assignments` with exactly one row:

```sh
matrix_session_json="$(warren --endpoint local --json session create "$workspace_id" \
  --kind shell --command bash --title codex-env-row)"
matrix_session_id="$(printf '%s\n' "$matrix_session_json" | jq -r '.id // .warrenSessionId')"

env_assignments='TERM=xterm-ghostty COLORTERM=truecolor TERM_PROGRAM=ghostty'
warren --endpoint local session send "$matrix_session_id" \
  "$env_assignments codex-luna-max"

warren --endpoint local session send "$matrix_session_id" \
  'sleep 20; printf CODEX_ENV_ROW_OK'
warren --endpoint local session read "$matrix_session_id" \
  --contains CODEX_ENV_ROW_OK --timeout 30s \
  >"$evidence_dir/env-row.raw"
```

For a missing variable, use the shell's `env -u` form rather than an empty
assignment:

```sh
env -u COLORTERM TERM=xterm-ghostty TERM_PROGRAM=ghostty codex-luna-max
```

For the explicit opt-out row:

```sh
NO_COLOR=1 TERM=xterm-ghostty COLORTERM=truecolor codex-luna-max
```

### Compare the embedded-SSH workspace without confusing identities

The “working spinner” observation came from another Warren workspace. Compare
it through the same local Host, not through the outer SSH/Agent process:

```sh
warren --endpoint local --json workspace list --all
warren --endpoint local --json agent list --all
warren --endpoint local --json session list --all
```

An Agent ID is a Warren Session ID, while `agentThreadId` is the provider's
conversation identity. After resolving the exact row, use the Session reader
for raw TUI bytes:

```sh
warren --endpoint local session read "$agent_id" --timeout 8s \
  >"$evidence_dir/embedded-ssh.raw"
```

Use `agent read` only for normalized transcript activity; it intentionally
does not contain terminal control bytes. If you need a live raw view, use
`warren --endpoint local agent attach "$agent_id"` interactively and record
the workspace/session ID alongside it. Never infer the inner PTY's
`TERM_PROGRAM` from the outer SSH client's environment.

Stop and remove each temporary session only after its raw capture is complete.
Use the exact ID returned by the fresh roster; never remove by display title.

The environment matrix is a capability experiment. It must not be used as a
substitute for the snapshot probe: `COLORTERM=truecolor` can explain why the
shimmer uses RGB SGR, while only the OSC 10/11 comparison can prove whether a
restore changed the defaults that Codex cached.

## 6. Read the diagnostic timeline as a causal trace

The desktop diagnostics are JSON lines. Keep only one reproduction window and
correlate the session ID with the raw capture:

```sh
diagnostics="$diagnostic_dir/terminal-diagnostics.log"

rg '"event":"(workspace_switch|terminal_tab_switch|terminal_view_appear|select_session|attach_start|attach_size|attach_complete|recovery_anchor|atomic_recovery_deferred|atomic_recovery_installed|atomic_recovery_failed|feed_output|present_now|present_stall_suspected|present_complete|resize_request|viewport_sync)"' \
  "$diagnostics" | tail -200

rg 'native state restore|runtime config reapplied|\[GhosttyTerminal\]' \
  "$diagnostics" | tail -200
```

The relevant meanings are:

| Event or observation | What it proves (and what it does not prove) |
| --- | --- |
| `session read` contains the marker | The PTY and Host output path produced bytes; it says nothing about pixels |
| `feed_output` | The selected desktop surface accepted a payload; it does not prove the payload was visible |
| `recovery_anchor` with matching epoch/sequence | The client and Host agree on the cursor boundary; it does not prove color state |
| `atomic_recovery_installed` | The native payload was accepted by Ghostty; it does not prove runtime config survived |
| `present_now` with `surfaceReady=true`, `viewVisible=true`, `result=true` | A draw was issued to a presentable view |
| `present_stall_suspected` | A lifecycle/presentation issue exists at that instant; investigate it only if it precedes the semantic mismatch |
| `present_complete` | The recovery gate reached a visible frame; it is a presentation milestone, not a color-state proof |

The corrected run showed this order (timestamps and IDs are deliberately
omitted here because they are run-specific):

```text
terminal native state restore result=true
in-memory session runtime config reapplied
atomic_recovery_installed
present_now result=true
present_complete
```

The old run had the restore and presentation milestones but no configuration
reapply between them. Since the OSC probe already differed immediately after
restore, adding more refreshes could not have repaired the cause.

## 7. Boundary-by-boundary evidence

| Boundary | Evidence from the real run | Conclusion |
| --- | --- | --- |
| Codex process -> PTY bytes | Raw capture contained Codex's OSC queries and RGB SGR; the 20-second command eventually emitted `CODEX_BLACK_ACCEPTANCE_OK` | Codex and the PTY were alive; do not rewrite bytes before proving a renderer mismatch |
| PTY -> Ghostline VT | Ghostline cursor/anchor advanced and the CLI read the same marker independently | No lost-output explanation for the black foreground |
| Ghostline VT -> native snapshot | Epoch/sequence and snapshot payload were accepted; restored text/cursor were present | Snapshot transport and visible grid were structurally valid |
| Snapshot -> client Ghostty semantic state | OSC 10/11 changed from `#eae8e6/#151110` to black after old restore | **First divergence**; native restore replaced configured defaults |
| Client state -> refresh/display link | `present_now` and `present_complete` followed in the expected order | Refresh timing was downstream of the already-wrong state |
| Draw -> framebuffer | The view was presentable and a native draw completed; repeated forced draws did not restore the OSC defaults | No evidence that the framebuffer was the root cause |

This table is the reason the final change is deliberately small. It repairs the
first mismatching state and leaves later layers alone.

## 8. Why the environment clue was real but incomplete

`COLORTERM=truecolor` matters. Codex's TUI uses terminal capability detection
to decide whether to emit truecolor. Removing it makes the spinner look
different, so a separate embedded-SSH workspace can appear to have a healthier
spinner when it is simply using a different color path.

`TERM_PROGRAM` and `PROGRAM` did not matter in the controlled matrix. Setting
them to `ghostty` or `vscode` produced the same result as leaving them empty.
The value observed in the outer Agent/SSH harness therefore could not explain a
state change that happened only after Warren restored a snapshot.

`NO_COLOR` is particularly dangerous during diagnosis: an automation launcher
may inject `NO_COLOR=1` or even `NO_COLOR=` and make a correct TUI look
monochrome. Warren removes only the ambient launcher value; an explicit session
override remains an explicit user choice. Always log the child environment for
the row being compared.

## 9. False leads and what each experiment taught us

### Refresh, timer, display-link, and draw frequency

The black frame initially looked like a refresh lifecycle problem. Experiments
added immediate ticks/draws and compared `present_now`/`present_complete` timing.
They established that a draw could reach a presentable view while the terminal
still answered the wrong OSC defaults. Repeated drawing changes when pixels are
submitted; it does not change the restored terminal state.

The investigation therefore rejects an unconditional high-frequency draw loop.
It would spend CPU/GPU time on the hot path and hide, rather than fix, a state
replacement bug.

### `TERM_PROGRAM` and the embedded SSH workspace

The working spinner in the other workspace suggested that `TERM_PROGRAM` might
select a special renderer. The matrix contradicted that hypothesis. The
relevant capability variable was `COLORTERM`, and the restore-specific state
loss still reproduced when the capability variables matched.

### Global SGR rewriting

A tempting workaround was to replace every exact
`ESC[38;2;0;0;0m` with a visible grey. A broader variant also rewrote indexed
black foreground/background SGRs. It made the Working label visible, but it
changed unrelated UI: the Composer's grey background and other color blocks
were distorted. Streaming rewrites also need to handle an SGR split across two
PTY chunks.

That experiment proved only that a different byte stream can make the symptom
less visible. It did not explain why the live and restored terminals disagreed,
so it was reverted rather than expanded into a global color rule.

### `minimum-contrast` values

Warren's dark theme is:

```text
background #151110
foreground #eae8e6
```

Pure black on that background has a measured contrast of about `1.12`, so it is
visually easy to lose. Several values were tried:

| Value | Observed behavior | Why it was not the complete fix |
| --- | --- | --- |
| `1` (Ghostty default/disabled) | Pure black stayed black; the shimmer gradient was preserved | The static black label could disappear |
| `4.5` | Black became white | Too harsh and flattened the intended visual transition |
| `2.5` | Also became white locally | The shader is binary, not a grey-target calculator |
| `1.8` | Also became white for the darkest shimmer sample | The shimmer gradient was flattened |
| `1.2` | Pure black was promoted, while the darkest measured shimmer `#2a2625` (contrast about `1.27`) remained grey | Useful narrow renderer tuning, but it cannot restore defaults lost by a snapshot |

The upstream shader's `contrasted_color` chooses either black or white when the
ratio is below the threshold. It does not interpolate to the expected
`#5c5856`. For the Warren background, white has a much larger contrast ratio
than black, so thresholds above `1.12` select white. The current `1.2` setting
is intentionally narrow: it separates Codex's pure-black label from the
shimmer's darkest emitted grey without applying a global SGR rewrite.

The relevant implementation references are the vendored Ghostty shader
(`common.glsl`/`shaders.metal`) and
`Packages/GhosttyAdapter/Sources/GhosttyAdapter/GhosttySurface.swift`.

### ANSI replay and protocol replacement

Desktop already negotiates `ghostty-vt-snapshot-v1`. Switching it to
`ghostline-vt-replay-v1` would alter the performance path and introduce a new
ordering problem for an order-dependent TUI. It would also bypass the very
boundary that needed to be observed. Native snapshot restore remained the
baseline throughout the investigation.

### Fake terminals and scripted frame checks

Synthetic terminal state and scripted framebuffer assertions can prove that a
test fixture is internally consistent, but they cannot prove what a real
Codex binary emits through a real Ghostline PTY or what the Desktop client
restores. They were not used for acceptance. The unit test added later covers
the specific OSC boundary already confirmed by the real run.

## 10. Snapshot semantics and the minimum repair

`ghostty_surface_restore_snapshot` is an atomic replacement of native terminal
state. In the version embedded by Warren, it is not a merge operation with an
option to preserve the embedder's configured defaults. The snapshot contains
the terminal state Ghostty needs to resume the grid; restoring it can therefore
replace per-surface defaults such as OSC 10/11.

The repair follows the existing native path:

```text
GhosttySurface.restoreSnapshot
  -> WarrenGhosttyOutputWriter.restoreSnapshotAndReapplyRuntimeConfig
     -> terminalFeedLock
        -> InMemoryTerminalSession.restoreSnapshot
        -> TerminalController.reapplyRuntimeConfig
           -> InMemoryTerminalSession.reapplyRuntimeConfig
              -> ghostty_surface_update_config
        -> markSnapshotRestored(epoch, sequence)
```

Important ordering details:

- The reapply callback runs only after `restoreSnapshot` reports success.
- The native restore, configuration update, and writer recovery-boundary mark
  share `terminalFeedLock`, so a live output slice cannot land between the
  state replacement and color restoration.
- `InMemoryTerminalSession` protects its native calls with its existing
  `terminalCallLock` and checks that the surface is ready.
- The writer resets the pending buffer only after Ghostty accepts the snapshot;
  stale in-flight slices cannot be appended after the new epoch/sequence.
- The controller reuses its already-built `ghostty_config_t`; it does not parse
  a config file or rebuild a theme for each output chunk.

The regression test restores a native fixture, sends OSC 10/11 queries, and
asserts the exact Warren replies (`rgb:eaea/e8e8/e6e6` and
`rgb:1515/1111/1010`). It also checks that the restored viewport and live cursor
continue to work. This test is intentionally narrow because the real TUI run
identified this exact boundary.

### Can native snapshot restore avoid overwriting?

Not with the current public Ghostty embedding API. The restore call is a
wholesale native-state replacement; there is no state-only/merge flag that
preserves Warren's runtime defaults. A future upstream API could expose a
state-only restore or explicitly separate grid state from embedder config. Until
then, restoring and immediately reapplying the existing configuration is the
smallest observable equivalent.

## 11. Performance and locking answer

The extra operation is intentionally on the cold recovery path only:

- It runs once per successful native snapshot restore, not for each PTY chunk.
- It is not attached to the display-link callback, refresh timer, or normal
  live output drain.
- It uses the existing in-memory `ghostty_config_t`; there is no file I/O,
  ANSI replay, or configuration parsing in the hot path.
- The critical section covers a native state swap, one config update, and the
  writer's anchor bookkeeping. It does not wait for the network or a full
  scrollback replay.
- `ghostty_surface_update_config` may request one config-change redraw. That is
  the expected bounded cost of making the restored state semantically match the
  live state.

The measured diagnostic order placed `runtime config reapplied` immediately
after the successful native restore and before `atomic_recovery_installed` and
`present_complete`. This is a short, deterministic cold-path cost rather than
an unconditional high-frequency draw policy.

The desktop still receives and installs one opaque native snapshot. Web/mobile/
CLI replay behavior is unchanged. A genuinely lower-cost solution would require
an upstream Ghostty state-only restore API; inventing a second protocol locally
would be a larger risk than this bounded reapply.

## 12. Verification protocol

### Automated checks

Run the checks that cover the changed Swift package, the Ghostline environment,
and the real app artifact:

```sh
swift test --package-path Packages/GhosttyAdapter
mise exec -- go test ./Headless/internal/server ./Headless/internal/runtime
WARREN_SKIP_WEB_BUILD=1 mise run build
git diff --check
```

The completed verification for this fix was:

- 37 `GhosttyAdapter` tests passed;
- the selected Headless server/runtime Go tests passed;
- `Warren.app` built successfully from the current checkout;
- `git diff --check` passed.

These checks are necessary but are not the final acceptance because none of
them, by itself, demonstrates that Codex's animation remains visible.

### Real-TUI acceptance

Repeat the following after every renderer or snapshot change:

1. Build the current checkout with `WARREN_SKIP_WEB_BUILD=1 mise run build`.
2. Start the GUI with a fresh diagnostics directory.
3. Resolve a fresh local workspace ID and create a fresh generic shell
   session.
4. Start `codex-luna-max` in that PTY and submit
   `sleep 20; printf CODEX_BLACK_ACCEPTANCE_OK`.
5. While `Working` is animating, switch away and back (or relaunch only the
   GUI) to exercise the native cold recovery path.
6. Read the same session through the CLI until the marker appears. Preserve
   the raw capture and inspect its SGR/OSC bytes.
7. Probe OSC 10/11 before and after restore. Both sides must report Warren's
   configured defaults.
8. Check that the diagnostic order contains restore success, runtime-config
   reapply, matching atomic recovery, a successful present, and completion.
9. Visually confirm that the Working animation continues to update and that no
   black foreground replaces it after recovery.

The final real run observed the Codex shimmer grey samples (`128`, `138`,
`167`, `202`, `231`, and `242` channels in the captured gradient), emitted the
acceptance marker, and did not produce the former pure-black foreground during
the acceptance interval. The diagnostic order matched the sequence above.

If the marker is present but the pane is black, stop at the first mismatch:

- missing marker: investigate Codex/PTY/Ghostline;
- marker present, OSC changes after restore: investigate snapshot/config state;
- OSC stable, `present_now` not visible: investigate AppKit surface lifecycle;
- OSC stable and present succeeds, but pixels stale: only then investigate
  display-link/framebuffer behavior.

## 13. Safe cleanup and retry discipline

Keep a list of every session ID created by the experiment. Before deleting
anything, obtain a fresh local roster and verify the exact IDs:

```sh
warren --endpoint local --json session list --all
warren --endpoint local session read "$session_id" --timeout 1s
```

For a temporary session that is no longer needed:

```sh
warren --endpoint local session remove "$session_id" --force
```

If the TUI is still running, interrupt it through the PTY first and then
remove the exact session. Do not use broad `pkill` patterns. In particular:

- never stop the detached Ghostline serve process during diagnosis; it owns all
  PTYs and stopping it destroys the evidence;
- do not delete `~/.warren/output`, `~/.warren/state.json`, or diagnostic logs;
- quit/relaunch the GUI when testing a desktop-only problem, but leave the
  headless daemon and local sessions alive;
- restore the normal local workspace/tab selection after the experiment so the
  next run starts from a known presentation state.

Run the matrix with fresh sessions when possible. Reusing a session can retain
Codex's cached OSC defaults, shell modes, or alternate-screen state and make a
successful retry look like a protocol fix when it is only a fresh process.

## 14. Final implementation boundary

The fix deliberately does not:

- change the desktop protocol from native snapshots to ANSI replay;
- rewrite all black SGRs or all dim/contrast rules;
- add an unconditional timer or high-frequency draw;
- make passive subscribers resize the shared PTY;
- change Ghostline's cursor/ring ordering;
- install any dependency outside `mise run install`.

It does one thing at the proven boundary: after a successful native snapshot
restore, reapply the current Warren Ghostty configuration before exposing the
matching live stream. This preserves the snapshot's performance and the
terminal's order-dependent semantics while preventing Codex from learning a
different default palette after recovery.

## 15. Lessons for a future technical blog

### A visual symptom is not a rendering-layer diagnosis

“The text is black” can mean at least four different things: the application
emitted black, the terminal state changed black, a shader promoted/demoted the
color, or a valid pixel never reached a visible view. Only a byte/state/timing
trace distinguishes them.

### Capability variables and terminal state are different classes of evidence

`COLORTERM` changed the kind of color Codex emitted. The native snapshot changed
what Codex believed the default colors were. Both affected the picture, but at
different boundaries. A successful environment experiment cannot replace a
state comparison around restore.

### Opaque snapshots can still overwrite semantic defaults

“Opaque” is a wire-format property, not a promise that an embedder's runtime
configuration is preserved. A native restore can be structurally correct and
semantically incomplete for the embedding application. Probe OSC state around
the restore instead of assuming the snapshot is configuration-neutral.

### The first divergence gives the smallest safe fix

Once the OSC mismatch was observed immediately after native restore, changing
the timer, draw frequency, protocol, or global color policy would only increase
scope. Reapplying one already-built config under the existing feed lock fixed
the cause with a bounded cold-path cost.

### Real TUI evidence remains the acceptance authority

The unit test protects the confirmed OSC boundary. The real
`codex-luna-max` run proves the complete chain: PTY bytes, Ghostline recovery,
Codex's Working animation, and visible presentation. Both are useful, but they
answer different questions.

## Remaining limitations

- The current Ghostty API still offers no state-only native restore. The
  reapply step remains necessary until an upstream API separates terminal grid
  state from embedder configuration.
- Ghostty's minimum-contrast shader is binary black/white for text. The `1.2`
  value is tuned to the measured Codex colors and should not be raised without
  rechecking the shimmer gradient.
- Explicit user/session `NO_COLOR` remains an opt-out by design. A monochrome
  TUI under that setting is not evidence of a Warren renderer regression.
- The real-TUI procedure is macOS/Desktop-specific. Web and CLI negotiate the
  ANSI replay format and need separate acceptance evidence.

## Related references

- [Terminal rendering runbook](../terminal-rendering-runbook.md)
- [Minimum-contrast experiments](../decisions/2026-08-28-minimum-contrast-experiments.md)
- [Terminal runtime](../runtime.md)
- [Headless and remote connection architecture](../headless-architecture.md)
- [Terminal experience progress](../terminal-experience-progress.md)
- `Packages/GhosttyAdapter/Sources/GhosttyAdapter/GhosttySurface.swift`
- `Packages/GhosttyAdapter/Sources/GhosttyAdapter/WarrenGhosttyOutputWriter.swift`
- `Packages/Vendor/GhosttyEmbedding/Sources/GhosttyTerminal/InMemory/InMemoryTerminalSession.swift`
- `Packages/Vendor/GhosttyEmbedding/Sources/GhosttyTerminal/Controller/TerminalController.swift`
- `Headless/internal/runtime/env.go`
- `Headless/internal/server/ghostline.go`
