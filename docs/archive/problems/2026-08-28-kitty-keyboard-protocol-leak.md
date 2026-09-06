# Kitty Keyboard Protocol Leak After Abnormal TUI Exit

- Recorded: 2026-08-28 (Asia/Shanghai)
- Status: Observed; deferred — no code change in this note
- Scope: Terminal input — `ghostty` / `ghostline` kitty keyboard protocol in Warren Desktop and Web
- Reproduction: Warren Desktop tab running `codex-luna-max` (or any TUI that enables kitty keyboard), killed with `Ctrl+C`

## Symptom

After interrupting the TUI, the shell prompt shows literal escape fragments on subsequent input, e.g.:

```
follow git:(release/app-home/follow) ✗ codex-luna-max
follow git:(release/app-home/follow) ✗ [99;5:3u[99;5:3u[99;5u co^C
```

`[99;5:3u` is the visible tail of `ESC[99;5:3u` (`CSI 99;5:3 u`): `99='c'`, `5=ctrl`, `:3=release`. Similar fragments appear for other keys, bracketed paste (`[200~`), etc. The shell does not interpret them and echoes them literally. The issue reproduces on both Warren Desktop (`GhosttyEmbedding`) and Web (`xterm.js`), confirmed on Desktop.

## Investigation

- Warren sessions are persistent PTYs owned by the detached `ghostline` server (`Headless/internal/server/ghostline.go:43`, `docs/runtime.md`). The PTY survives TUI exit and returns to the shell; the terminal emulator state does not reset with the child process.
- Kitty keyboard protocol is negotiated by the application: `CSI > flags u` pushes flags, `CSI < n u` pops, `CSI = flags : action u` sets modes (`src/terminal/stream.zig:2450` in upstream `ghostty`, mirrored in Warren's vendored libghostty). The per-screen stack lives in `src/terminal/kitty/key.zig:8` `FlagStack` / `src/terminal/Screen.zig:75` `kitty_keyboard`, and is only cleared on hard reset (`Screen.zig:443` `self.kitty_keyboard = .{}` for RIS/DECSTR). Returning to the shell does not clear it.
- Upstream `ghostty` source was copied to `../../gh/ghostty` for inspection:
  - `src/input/kitty.zig:35` defines the keymap,
  - `src/input/key_encode.zig:99` encodes keys as `CSI u` when `kitty_keyboard.current() != .disabled`,
  - `src/termio/stream_handler.zig:312` pushes/pops/sets the stack.
- Warren Desktop wraps the same engine via `Packages/Vendor/GhosttyEmbedding/Sources/GhosttyTerminal/Surface/TerminalSurface.swift:35` `ghostty_surface_key` / `:55` `submitReturn` (comment `kitty-protocol CSI 118;5u` at `:71`), Web uses `Web/src/App.jsx:1678` `allowProposedApi:true` + `onData` at `:1847`. Both correctly enable kitty when the child requests it, as intended for `Shift+Enter` etc. (`Headless/README.md:242`, `Web/src/App.jsx:822`).
- When the child is killed with `Ctrl+C` before it can send `CSI < u`, the stack remains enabled. Subsequent shell input is then encoded as `CSI u` and misinterpreted by `zsh`.
- `TERM_PROGRAM=vscode` observed in the outer `opencode` harness is unrelated. The inner Warren PTY reports `TERM=xterm-256color` (`Headless/internal/runtime/env.go:30` `DefaultTerm`) on Web and `xterm-ghostty` on Desktop, with `COLORTERM=truecolor` (`ghostline.go:41`). The leak occurs entirely inside Warren's PTY + emulator boundary.

## Why this is not a ghostty bug

`ghostty` follows the kitty spec strictly: the application owns the push/pop lifecycle. The behavior is identical in standalone `ghostty` (`printf '\e[>1u'` then kill, same leak, recovers with `printf '\e[<u'`). Warren inherits the same property via embedding.

## Decision

Deferred. Severity is low — visual noise only, no data loss, recoverable with `reset` or `printf '\e[<u\e[?2004l'`. No code change in this cycle. Keep the persistent PTY model unchanged.

## Future direction when prioritized

- Add an explicit terminal-mode reset on shell return: inject `CSI < u` / `CSI ?2004l` or call `terminal.reset()` / `ghostty_surface` reset when the foreground process exits abnormally, or when Warren detects `kitty_keyboard != disabled` while the shell is at prompt. Scope to Desktop `TerminalSurfaceManager` and Web `Web/src/App.jsx` / `Web/src/terminal.js`.
- Optionally expose a `Terminal` context-menu action `Reset Terminal` for manual recovery.
- Keep `kitty` enabled for TUIs (`Shift+Enter`, `Ctrl+V` etc.) — do not disable globally. The fix should be lifecycle-bound, not a feature removal.

## Verification when fixed

- `codex`/`claude` TUI killed with `Ctrl+C` twice in a row, then plain shell typing shows no `[99;5` fragments.
- `Shift+Enter` still delivers `CSI 13;2u` inside a fresh TUI.
- No regression to `PAGER`/`COLORTERM` sanitization (`Headless/internal/runtime/env_test.go:22`).
