# Terminal runtime

Warren uses Ghostline as its sole terminal runtime. Each session owns one
persistent PTY managed by the detached Ghostline server. Clients receive raw
PTY output and recover through an atomic checkpoint containing the rendered
screen and an opaque output cursor.

The daemon synchronizes a focused client's measured viewport before taking a
checkpoint. Passive subscribers never resize a shared runtime. During cold
recovery, clients keep a neutral placeholder until the `synced` marker arrives;
staged output is then applied and rendered once.

The historical `tmux` runtime is removed. Configurations that select it fail at
startup and must be migrated to `ghostline`; existing sessions are not silently
reassigned to another runtime.
