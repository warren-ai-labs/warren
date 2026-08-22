# Terminal runtimes: ghostline and tmux

Warren's headless daemon can own terminal sessions with either of two
engines:

- **ghostline** — the default and recommended engine. A Go library plus a
  detached server process (`ghostline serve`) that owns PTY children and a
  libghostty-vt emulator, rendering screen snapshots with the same terminal
  core as the Ghostty client.
- **tmux** — the classic, battle-tested terminal multiplexer, kept as a fully
  supported alternative.

Both engines are always registered when the daemon runs, so a session created
with one engine keeps using that engine for its whole lifetime. Sessions
record their engine in `runtimeKind`; the default only decides what new
sessions use.

## Where the choice lives

Runtime selection is a **headless-daemon concern**, not a client one:

- The Desktop and Web are clients. They never pick an engine; they render
  whatever the daemon streams.
- The daemon decides the engine for every `session.create` request:
  an explicit `runtimeKind` parameter wins, otherwise the daemon's default.
- Existing sessions are never migrated: a session created with tmux stays on
  tmux even if the default later changes to ghostline (or vice versa).

The default can be changed three ways:

1. `~/.warren/settings.json`:

   ```json
   {
     "defaultRuntime": "ghostline",
     "runtimeEnv": {
       "GIT_PAGER": "less",
       "PAGER": "less",
       "GH_PAGER": "less",
       "TERM": "xterm-256color"
     },
     "autoOpenShell": false,
     "autoStartAI": false
   }
   ```

   `runtimeEnv` overrides environment variables inherited by terminal runtime
   children (ghostline PTYs and tmux sessions). Warren first strips
   launcher-only semantics such as `GIT_PAGER=cat` or `TERM=dumb`, then these
   explicit values win. An empty value unsets the variable (for example
   `"CI": ""`), which is different from passing an empty string.

2. The `--runtime ghostline|tmux` flag (or `WARREN_RUNTIME`), which overrides
   the settings file for this daemon invocation.
3. `PUT /v1/settings` (or the Desktop **Settings → Terminal runtime** panel),
   which persists to `settings.json` for future daemon starts.

Git worktree import is not a host-wide setting. Each Project stores its own
`autoImportGitWorktrees` flag. Enable it from that project's context menu to
import all currently existing external worktrees without confirmation, or use
the project's **Import Existing Worktrees…** action to select a one-time batch;
already imported candidates remain visible but disabled.

## ghostline

Good:

- **Same terminal core as the client.** Snapshots are rendered by
  libghostty-vt, the exact emulator Ghostty uses, so colors, alt-screen,
  DEC 2026, and BCE behavior match what the client would render.
- **Independent session server.** Sessions are owned by a detached
  `ghostline serve` process; daemon upgrades and restarts never end them.
- **Verbatim input.** Bytes reach the PTY unchanged, so kitty-protocol keys
  (Shift+Enter, modified arrows) work without a key-mapping middleman.
- **No tmux dependency.** No separate multiplexer process, no tmux config or
  key bindings to leak into the user experience.

Not so good:

- Newer and less battle-tested than tmux; the API is still evolving.
- Requires libghostty-vt, which must be built with Zig and is currently
  bundled as a prebuilt dylib for macOS arm64.
- A forced restart of the ghostline server process ends its sessions. Normal
  protocol upgrades are rolled in place: a fresh server adopts every session
  from the old one before the old process exits, so children keep running.
  If adoption is impossible, the daemon keeps the old server rather than
  ending sessions.
- On startup, Warren forces a rolling upgrade when the RPC protocol is
  incompatible, and also rolls a protocol-compatible server when its
  Ghostline release tag differs from the embedded tag. Development builds
  without a tag do not trigger the tag check.

## tmux

Good:

- Extremely mature and stable; a decade of real-world validation.
- Sessions survive anything short of a tmux server crash, including daemon
  restarts, SSH drops, and terminal closes.
- No extra build-time dependency for the daemon beyond the `tmux` binary.

Not so good (why ghostline is the default):

- **A middle layer re-parses and re-renders.** tmux interprets program output
  and emits its own rendering sequence, which the client parses again. This
  can degrade colors, images, and exact terminal behavior.
- **Input goes through paste/key translation.** Raw escape sequences are not
  a real key press in tmux, so Warren maps keys (for example Shift+Enter via
  kitty protocol) and pastes the rest; every mapping is another place where
  behavior can drift.
- **Snapshot replay can misalign colored history.** Replaying a full tmux
  capture through Ghostty can break background-color blocks on soft-wrapped
  colored history (Ghostty BCE behavior, upstream issues #12497 / #12505).
- **Another process and config surface.** tmux needs to be installed and
  managed, and its own key bindings/options can interfere when users interact
  with it directly.

## Recommendation

Use ghostline for new deployments. Keep tmux for environments where the
ghostline build requirements are not acceptable, or while migrating existing
tmux sessions. Both are supported; neither is deprecated.
