# Terminal runtime

Warren uses Ghostline as its sole terminal runtime. Each session owns one
persistent PTY managed by the detached Ghostline server. Live output follows
Ghostline's opaque cursor stream.

The daemon synchronizes a focused desktop client's measured viewport before
requesting a native atomic state. The desktop installs that opaque state into
Ghostty and presents once at the matching `synced` marker; it does not replay
history through the VT parser. Passive subscribers never resize a shared
runtime. Desktop negotiates `ghostty-vt-snapshot-v1`; Web, mobile, and CLI
peers negotiate `ghostline-vt-replay-v1` and apply the checkpoint behind a
presentation gate.

The historical `tmux` runtime is removed. Configurations that select it fail at
startup and must be migrated to `ghostline`; existing sessions are not silently
reassigned to another runtime.

## Environment boundaries

Warren has three separate environment boundaries:

1. The desktop and headless daemon start from a clean, host-level baseline.
   The baseline keeps identity, locale, a stable system `PATH`, the selected
   login shell, a valid `SSH_AUTH_SOCK`, and host display/XDG settings. It
   drops terminal integration, task-runner state (`mise`/`direnv`), inherited
   agent IDs, pager/color overrides, proxies, and credentials. The daemon may
   additionally retain Warren/provider configuration for its control-plane
   work; those values are not part of the terminal baseline.
2. The detached Ghostline server is started with the terminal baseline only.
   Warren/provider configuration, relay/control variables, and launch-path
   overrides never become inherited shell variables. Ghostline is not rebuilt
   from a launching terminal on every request.
3. Session creation adds Warren's binding variables and the persisted
   `RuntimeEnv` overrides to the new PTY only. Runtime environment keys cannot
   replace Warren-owned session or agent identity variables; an empty value is
   an explicit request to unset a key in that session (the mandatory `TERM`
   terminal value remains Warren's default).
4. The PTY starts the validated login shell (`$SHELL -il`). Its startup files
   and the project directory are responsible for rebuilding user state such as
   `mise`, `direnv`, virtual environments, and project `.envrc` values. Warren
   does not continuously observe or synchronize changes made inside that shell.

`RuntimeEnv` therefore affects new sessions only. Existing PTYs keep the
environment with which they were created, and changing a shell's environment
after startup is ordinary shell behavior rather than a Warren settings update.
