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
