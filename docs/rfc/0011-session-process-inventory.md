# RFC 0011: Per-session process inventory

- Status: Proposed
- Owner: Warren Headless, Web, Desktop, and CLI clients
- Created: 2026-09-02
- Scope: Host-side acquisition of running processes inside a single Warren
  Session; roster and roster.delta projection; resource budget under which the
  acquisition loop must stay; intentionally excludes client UI
- Depends on: ghostline session metadata primitives
  (`../ghostline/metadata_darwin.go`, `metadata_linux.go`)
- Supersedes: the single-string `Session.Process` field as the only process
  signal in roster snapshots. The field is retained as a derived view.

### Cross-repo positioning

`ghostline` is a Go standard library for terminal session lifecycle; it is
not a Warren-internal module. The contract for the new `Session.Processes`
method is therefore written without Warren concepts: it accepts no Workspace
path, no Session identifier conventions, and no Warren-specific naming. The
walker returns the OS-level processes reachable from the PTY's foreground
process group, and the caller (Warren or any other consumer) decides what
"reachable" means in product terms.

Warren-specific joins, such as the workspace-rooted set, are performed on the
Warren side after the generic set is received. This keeps the ghostline
change reusable and keeps Warren-specific concerns where they belong.

## Summary

Warren will publish, for every running Session, the bounded set of OS processes
that belong to it, plus a process state and cwd for each entry. The Host
acquires the set on a periodic background loop, caches the result, and overlays
it on the existing roster snapshot. Roster delta messages carry a per-session
PID-level diff so a stable Session does not retransmit the full list on every
tick.

The data path is split between two repos:

- `ghostline` (stdlib) provides a new `Session.Processes` RPC that returns the
  set of processes reachable from the PTY's foreground process group, with
  per-entry comm, state, cwd, and a foreground flag. It knows nothing about
  Warren Workspaces.
- `warren` consumes the ghostline result, joins the workspace-rooted set on
  the Host side, applies the per-Session cap and exited-state retention, and
  overlays the result on the roster.

The platform walk in ghostline uses `proc_listpids` + `proc_pidinfo` on macOS
and `/proc` on Linux. The per-PID `lsof` cost that made the naive walker
unsuitable is removed.

The Warren Host runs the loop on an adaptive 1.5 s–5 s ticker, pauses entirely
when zero clients are subscribed, and caps the tracked PID set at 256 entries
per Session.

Client UI rendering of the inventory is explicitly out of scope for this RFC.
The contract is "data plane only": a verified field on the roster, queryable
with `curl`, with a documented budget that future client work must respect.

## Motivation

The current process signal in Warren is the foreground comm string surfaced
via `Session.Process` and the foreground working directory surfaced via
`Session.Directory`. Both are produced by ghostline's existing metadata probe
(`ghostline/metadata_darwin.go:17`) and propagated unchanged into roster
snapshots (`Headless/internal/server/service.go:809-813`).

Three use cases are blocked by that signal:

- An operator who starts `make -j32` inside a Session and needs to know which
  workers are alive, which are stuck, and which have exited.
- A debugging flow that needs to confirm a background job such as
  `npm run watch &` is still running without scrolling the scrollback.
- Relay users on a wide-area link, who currently have no way to inspect
  Session activity without streaming PTY bytes.

A naive implementation that shells out to `ps` and `lsof` for every Session on
every tick costs roughly 20 ms of CPU and several hundred milliseconds of
wall time per Session per tick on macOS. The `lsof` per-PID call is the
dominant cost. A Warren host with 20 running Sessions under that loop spends
the majority of its CPU budget on `lsof`. This RFC exists to make the
acquisition cheap enough to run continuously, and to keep it cheap on Relay.

The data is also an honest signal. A process listing reflects what is
actually running in the Session at the moment of the probe; it is not a guess
from transcript or prompt heuristics, and it does not need provider-specific
adapters.

## Concepts

### Session process

A *Session process* is a process that belongs to a Warren Session at the
moment of the probe. Membership is the union of two sets:

| Set | Computed by | Definition |
| --- | --- | --- |
| Foreground tree | ghostline | The process whose `pgid` equals the PTY's foreground process group, plus every descendant reachable by parent PID. |
| Workspace-rooted | warren Host | Every process whose `cwd` is inside the Session's `Workspace.Path` (after symlink resolution). |

The split is deliberate. The foreground tree is a property of the PTY and
the OS process model; ghostline owns it because it already owns the PTY fd.
The workspace-rooted set is a Warren product concept; the Host owns it
because the Host owns the Workspace record. ghostline's API takes no
`WorkspaceRoot` argument and never resolves a Workspace path.

The two sets are merged and de-duplicated by PID in the Warren Host before
the per-Session cap is applied. The `IsForeground` field is true exactly
for the members of the foreground tree. The truncation preference, when the
cap is hit, is foreground tree first, then workspace-rooted, then arbitrary
within each group; clients must not assume ordering.

A process that leaves both sets between two probes is marked `exited` and
retained in the cache for `processExitedTTL` (5 s) so the UI can show the
"just exited" state before the entry disappears. After the TTL the entry is
dropped. The exited retention lives in the Warren cache layer, not in
ghostline; ghostline returns only the current observed set.

### Acquisition cadence

The Host probes every running Session on a single goroutine, the
`processLoop`, with a ticker that defaults to 1.5 s. The loop measures the
wall time of each probe and adapts:

- Probe under 100 ms: keep 1.5 s.
- Probe 100–300 ms: stretch to 3 s.
- Probe over 300 ms: stretch to 5 s.

The interval is not changed on a single outlier. A 3-tick hysteresis counter
requires three consecutive ticks in the same bucket before the ticker is
reset. This prevents flapping between 1.5 s and 5 s under bursty load, for
example during a `make -j32` that briefly inflates the proc table.

The ticker is also paused entirely when the roster has zero subscribers. The
cache is preserved; the next subscriber triggers a single immediate probe
followed by the resumed cadence. This keeps the host idle when no client is
attached, with no cold-start delay for the first reconnecting client.

The cap on a single probe is 3 s wall time. A probe that exceeds the cap is
cancelled and the Session's cache is left at the previous value. The cap is
per-probe, not per-tick: a single Session that times out does not delay the
remaining Sessions in the same tick.

The cadence constants and their roles are:

| Constant | Value | Role |
| --- | --- | --- |
| `processRefreshInterval` | 1.5 s | Default ticker interval (fast tier) |
| `processRefreshSlow` | 3 s | Mid tier, hysteresis-gated |
| `processRefreshVerySlow` | 5 s | Slow tier, hysteresis-gated |
| `processProbeTimeout` | 3 s | Per-Session probe wall-time cap |
| `processPIDCap` | 256 | Per-Session tracked PID cap |
| `processExitedTTL` | 5 s | Exited retention window |

### Session identity

The Session identity used by the inventory is the same `Session.ID` that
already drives roster, agent status, and broadcast locks. No new identifier
is introduced.

## Data model

### `api.ProcessInfo`

```go
type ProcessState string

const (
    ProcessStateRunning  ProcessState = "running"
    ProcessStateSleeping ProcessState = "sleeping"
    ProcessStateStopped  ProcessState = "stopped"
    ProcessStateZombie   ProcessState = "zombie"
    ProcessStateExited   ProcessState = "exited"
)

type ProcessInfo struct {
    PID          int          `json:"pid"`
    PPID         int          `json:"ppid"`
    PGID         int          `json:"pgid"`
    Comm         string       `json:"comm"`
    State        ProcessState `json:"state"`
    CWD          string       `json:"cwd,omitempty"`
    IsForeground bool         `json:"isForeground"`
    FirstSeen    time.Time    `json:"firstSeen"`
    LastSeen     time.Time    `json:"lastSeen"`
}
```

`State` is a finite vocabulary. New states are not added by clients; they
require an RFC update. The mapping from OS state codes is:

| OS state code | `ProcessState` |
| --- | --- |
| `R` | `running` |
| `S`, `D`, `I` | `sleeping` |
| `T` | `stopped` |
| `Z` | `zombie` |
| PID absent on `kill(pid, 0)` | `exited` (cache only) |

`CWD` is omitted when the platform walker could not resolve it. The Warren
client must render the absence as "unknown" rather than assume a value.

### `api.Session` extension

```go
type Session struct {
    // ... existing fields unchanged ...
    Process   string        `json:"process,omitempty"`   // retained, derived
    Directory string        `json:"directory,omitempty"` // retained, derived
    Processes []ProcessInfo `json:"processes,omitempty"` // new; overlay only
}
```

`Processes` is **overlay-only** and is never persisted in the durable Session
record. The Host clears it on session end, like `Process` and `Directory`.

The retained `Process` string is the comm of the foreground PID, derived from
the cache; clients that only consume the field keep working unchanged.

### `rosterDeltaMessage` extension

```go
type rosterDeltaMessage struct {
    // ... existing fields unchanged ...
    SessionProcesses *rosterProcessesBySessionDelta `json:"sessionProcesses,omitempty"`
}

type rosterProcessesBySessionDelta struct {
    Sessions map[string]rosterEntityDelta[api.ProcessInfo] `json:"sessions"`
}
```

`Session.Processes` is removed from the JSON path of the Session entity by
adding `json:"-"` to the field. Clients merge the per-session PID delta into
the local process map by upsert/remove, exactly the same way the existing
`rosterEntityDelta` is applied to other entity types.

The `Session` entity still carries every other field, so a field-only change
on the Session (a title edit, a pin toggle) still goes through the existing
upsert path without touching the per-process delta.

## Acquisition

The acquisition is split between two repos. This section documents each side
in order: the ghostline stdlib API first, then the Warren Host consumption.

### ghostline: new `Session.Processes` RPC

The platform walk is a ghostline capability. Warren already consumes
`Session.Metadata` from the detached `ghostline-serve` process
(`Headless/internal/server/ghostline.go:226`), so the same boundary carries
the new method.

The new method takes generic options only. It does not accept a Workspace
path, a Session name convention, or any Warren-specific value.

#### New ghostline types

```go
// In ghostline/session.go
type SessionProcess struct {
    PID          int    `json:"pid"`
    PPID         int    `json:"ppid"`
    PGID         int    `json:"pgid"`
    Comm         string `json:"comm"`
    State        string `json:"state"`
    CWD          string `json:"cwd,omitempty"`
    IsForeground bool   `json:"isForeground"`
}

type ProcessesOptions struct {
    // Cap is the maximum number of processes to return. Zero selects the
    // ghostline default (256). The caller is responsible for any further
    // truncation that product policy requires.
    Cap int
    // MaxDepth bounds the BFS walk over the process tree. Zero selects the
    // ghostline default (8). The cap protects against pathological trees
    // such as a deeply nested recursive shell.
    MaxDepth int
}

func (s *Session) Processes(ctx context.Context, opts ProcessesOptions) ([]SessionProcess, error)
```

`SessionProcess.State` is one of `"running"`, `"sleeping"`, `"stopped"`,
`"zombie"`. The exact same vocabulary is used by the Warren `ProcessState`
enum; ghostline stays stringly-typed to keep the contract minimal, and the
Warren adapter validates the value at the boundary.

#### New ghostline RPC method

```go
// In ghostline/rpc.go
const rpcMethodProcesses = "processes"

type processesParams struct {
    Name     string `json:"name"`
    Cap      int    `json:"cap,omitempty"`
    MaxDepth int    `json:"maxDepth,omitempty"`
}

type processesResult struct {
    Processes []SessionProcess `json:"processes"`
}
```

The server-side handler in `ghostline/server.go` follows the `metadata`
case at line 799. The client wrapper in `ghostline/client.go` follows the
existing `metadata` wrapper at line 596. Both routes gate on the new
`CapabilityProcesses` capability advertised in the `Version` RPC.

#### macOS walker (`ghostline/processes_darwin.go`, new)

Replaces the per-PID `lsof` cost with a single `proc_listpids` plus per-PID
`proc_pidinfo` calls. The walker only computes the foreground tree; the
workspace-rooted set is the Warren Host's responsibility.

```go
//go:build darwin
func probeSessionProcesses(ctx context.Context, fd int, opts ProcessesOptions) ([]SessionProcess, error)
```

Steps:

1. `unix.IoctlGetInt(fd, unix.TIOCGPGRP)` to get the foreground PGID. If
   that fails, return `(nil, nil)` and no error; the caller decides whether
   "no foreground" means "no processes" or "skip this tick".
2. `proc_listpids(PROC_ALL_PIDS, 0, nil, 0)` once to size the buffer; a
   second call to fill it. The expected cardinality is the system PID count
   (typically a few hundred to a few thousand).
3. For each PID, `proc_pidinfo(PROC_PIDTASKINFO)` to get `pid`, `ppid`,
   `pgid`, `stat` (state), and the truncated `comm` (`p_comm`, 16 bytes).
   This is one syscall per PID; the cost is dominated by the loop, not the
   syscall.
4. Build two indices in one pass: a parent-to-children map and a
   pid-to-(comm, ppid, pgid, state) map.
5. BFS from each leader PID (every PID with `pgid == foregroundPGID`) over
   the parent map to collect the foreground tree. Cap the walk depth at
   `opts.MaxDepth` generations (default 8) to bound pathological cases
   like nested shells invoking recursive scripts.
6. For each PID in the tree, resolve its cwd with
   `proc_pidinfo(PROC_PIDVNODEPATHINFO)`. Cwd is best-effort; a failure on
   a single PID does not abort the walk and the field is left empty for
   that entry.
7. Truncate to `opts.Cap` (default 256) preserving the BFS order so the
   foreground leaders and their immediate descendants are kept before
   deep-tree leaves. Clients must not assume the result is exhaustive when
   the cap is hit; truncation is signalled only by the cap itself, not by
   an explicit `truncated` flag.
8. Mark `IsForeground=true` for every member of the tree (the BFS already
   started from the foreground set, so all members qualify).

The walker does not own the cache. It returns the raw snapshot for the
caller to merge with the previous tick. The merge is the caller's concern.

#### Linux walker (`ghostline/processes_linux.go`, new)

```go
//go:build linux
func probeSessionProcesses(ctx context.Context, fd int, opts ProcessesOptions) ([]SessionProcess, error)
```

Steps mirror the macOS walker with these substitutions:

- Foreground PGID via the same `TIOCGPGRP` ioctl.
- Process table via `os.ReadDir("/proc")` plus per-PID
  `os.ReadFile("/proc/<pid>/stat")` (parses the `(`…`)` comm field) and
  `os.Readlink("/proc/<pid>/cwd")`.
- Parent map from `stat` field 4 (ppid).
- BFS, depth cap, and truncation as in the macOS walker.
- Cwd is best-effort; a `Readlink` error on a transient race is logged at
  the ghostline debug level and the field is left empty.

The Linux path is dominated by `Readlink` and `ReadFile`; expected cost is
under 10 ms for 200 PIDs.

#### Fallback (`ghostline/processes_other.go`, new)

Returns `(nil, nil)` on platforms where neither path is supported. The
caller treats a nil result as "no data" and does not surface an error to
clients.

### Warren Headless: new runtime adapter

The Warren Host owns the join between the ghostline foreground tree and the
workspace-rooted set. This is the only place in the data path where Warren
product concepts are applied.

#### Interface (`Headless/internal/runtime/metadata.go`)

```go
type ProcessInfo struct {
    PID, PPID, PGID int
    Comm, CWD       string
    State           string
    IsForeground    bool
    FirstSeen, LastSeen time.Time
}

type RuntimeProcessProvider interface {
    Processes(ctx context.Context, name string) ([]ProcessInfo, error)
}
```

#### Ghostline adapter (`Headless/internal/server/ghostline.go`)

`GhostlineRuntime` gains:

```go
func (r *GhostlineRuntime) Processes(ctx context.Context, name string) ([]ProcessInfo, error)
```

The implementation:

1. Looks up the Session in the `Store` snapshot and resolves its Workspace
   path. If the Session has no Workspace, the workspace-rooted join is
   skipped; the foreground tree alone is returned.
2. Resolves the Workspace path through `filepath.EvalSymlinks` so the
   comparison in step 5 uses the canonical form.
3. Calls the new ghostline RPC with `Cap=processPIDCap` (256) and
   `MaxDepth=8`. The call is gated on the
   `CapabilityProcesses` advertisement from the `Version` handshake; if the
   capability is missing, the function returns `(nil, nil)` and the cache
   is left unchanged for the tick.
4. Translates the result into `runtime.ProcessInfo` with empty
   `FirstSeen`/`LastSeen`; the cache layer fills those in.
5. Computes the workspace-rooted set. The walker is `lsof -t +D <root>` on
   macOS and `os.ReadDir("/proc")` + `Readlink("/proc/<pid>/cwd")` on
   Linux. The cwd of each PID in the foreground tree is reused from the
   ghostline result to avoid an extra syscall; only PIDs not in the tree
   are probed for cwd. A PID whose resolved cwd is a strict prefix of the
   canonicalized Workspace path is added to the set.
6. Merges the two sets by PID, de-duplicates, and applies the per-Session
   256 cap with foreground-tree-first preference. The 64-entry UI cap is
   a separate downstream trim applied by the Web and Desktop renderers; the
   Host does not enforce it.
7. Returns the merged slice. The Host does not log individual PIDs.

The ghostline result is the source of truth for `comm`, `state`,
`isForeground`, `pid`, `ppid`, `pgid`, and `cwd` for the PIDs in the
foreground tree. The workspace-rooted PIDs use the same `comm` and `state`
from the same per-PID probe if they appear in the proc table; if a PID is
visible only to `lsof +D` (e.g. on macOS where `lsof` is more permissive
than the foreground tree's view), the Host falls back to a one-shot `ps -o
comm=,stat=` lookup. This fallback is bounded to 64 PIDs per tick to keep
its cost predictable.

### Warren Headless: process cache

#### `Headless/internal/server/process_cache.go` (new)

Mirrors `Headless/internal/server/metadata_cache.go`:

```go
type processCache struct {
    mu          sync.RWMutex
    values      map[string][]api.ProcessInfo
    previousIDs map[string]map[int]struct{} // sessionID → PID set, last tick
}

func (c *processCache) get(sessionID string) ([]api.ProcessInfo, bool)
func (c *processCache) update(sessionID string, observed []ProcessInfo, ttl time.Duration) []api.ProcessInfo
func (c *processCache) remove(sessionID string)
func (c *processCache) prune(running map[string]bool)
```

`update` reconciles the new observed snapshot with the previous tick:

- A PID in both ticks: `LastSeen = now`, `State` from the new observation.
- A PID in the previous tick but not the new one: copy the entry, set
  `State = ProcessStateExited`, set `LastSeen = now`. Retain for `ttl`,
  then drop on the next call.
- A PID in the new tick but not the previous: stamp `FirstSeen = now`,
  `LastSeen = now`.

#### `processLoop` in `Headless/internal/server/service.go`

```go
const (
    processRefreshInterval = 1500 * time.Millisecond
    processRefreshSlow     = 3 * time.Second
    processRefreshVerySlow = 5 * time.Second
    processProbeTimeout    = 3 * time.Second
    processPIDCap          = 256
    processExitedTTL       = 5 * time.Second
)

func (s *Service) processLoop(ctx context.Context) {
    s.refreshProcesses(ctx) // immediate first probe
    current := processRefreshInterval
    ticker := time.NewTicker(current)
    defer ticker.Stop()
    for {
        select {
        case <-ctx.Done():
            return
        case <-ticker.C:
            if s.subscriberCount() == 0 {
                continue
            }
            start := time.Now()
            s.refreshProcesses(ctx)
            elapsed := time.Since(start)
            next := pickProcessInterval(elapsed)
            if next != current {
                current = next
                ticker.Reset(current)
            }
        }
    }
}
```

`pickProcessInterval` is the hysteresis map listed in the cadence section.
The hysteresis uses a 3-tick counter to avoid flapping under bursty load.

`subscriberCount` is a new method on `Service` that returns the count of
active roster WebSocket peers, computed by walking the peer set in
`Headless/internal/server/http.go` (the `wsPeer` registration path).

### Warren Headless: roster overlay

In `RosterVersion` (`service.go:800-823`), alongside the existing
metadata overlay at line 809:

```go
if s.processCache != nil {
    if procs, ok := s.processCache.get(session.ID); ok {
        // Deep-copy so per-subscriber mutations cannot leak.
        copied := append([]api.ProcessInfo(nil), procs...)
        session.Processes = copied
    }
}
```

The cache is read-only on the roster path. The `processLoop` is the only
writer.

### Roster delta: per-session PID diff

`makeRosterDelta` (`Headless/internal/server/roster_delta.go:32`) gains a
new step that compares the previous and current `Session.Processes` for
each Session and emits a per-PID diff:

```go
if delta := sessionProcessesByPID(before, after); delta.hasChanges() {
    result.SessionProcesses = &delta
}
```

`sessionProcessesByPID` walks the previous and current process slices,
indexes both by PID, and produces one `rosterEntityDelta[api.ProcessInfo]`
per Session ID. The output of `rosterEntityDelta` is reused unchanged.

The `Session` entity itself drops the `Processes` field from its JSON
output. The field becomes `json:"-"` and is omitted from `rosterEntityDelta`
serialization, but it is still populated in the `api.State` used by
`makeRosterDelta` so the diff can be computed.

The other fields of `Session` continue to flow through the existing
`rosterEntityDelta[api.Session]` upsert path. A title change no longer
re-pays the cost of the process list.

## Resource budget

The following budgets are normative. Each is a precondition for the
implementation being accepted, not an aspiration.

| Metric | Budget | Measurement |
| --- | --- | --- |
| Single probe wall time, macOS, 20 Sessions × 50 PIDs | ≤ 300 ms total per tick | `go test -bench` over the platform walker |
| Single probe wall time, Linux, 20 Sessions × 50 PIDs | ≤ 200 ms total per tick | same |
| Per-PID walker cost, macOS | ≤ 0.5 ms (PID 1 ms; cwd 0.3 ms) | benchmark |
| Per-PID walker cost, Linux | ≤ 0.1 ms | benchmark |
| Roster snapshot full-dump cost, 50 Sessions, 64 PIDs each | ≤ 1 ms | benchmark |
| Roster delta cost, 50 Sessions, steady state (no PID changes) | ≤ 5 KB total per tick | tcpdump on the WebSocket |
| Per-Session PID cap | 256 (configurable constant) | unit test |
| Per-Session UID-displayed PID cap | 64 (UI consumption cap) | documented in API |
| Exited retention | 5 s | unit test |
| `processLoop` idle CPU when zero subscribers | 0 % | daemon log shows ticker skip events |
| Daemon RSS growth vs. RFC 0010 baseline | ≤ 2 MB | `ps -o rss` diff |
| Adaptive interval floor | 1.5 s | constant |
| Adaptive interval ceiling | 5 s | constant |
| Probe timeout | 3 s | constant |

A probe that exceeds the budget is recorded in a rolling daemon metric
(`headless.log`) once per 100 ticks, not per tick, to keep log volume
bounded under sustained pressure.

## Privacy and security

The walker runs inside `ghostline-serve`, the same detached process that
owns the PTYs, and inherits its uid. It only sees processes visible to that
uid; other users' processes are filtered by the kernel regardless of any
arguments Warren passes. No process outside the uid is enumerated or named
in the result.

The Warren Host does not log the process list. The list is overlay-only and
is never written to `state.json`, the daemon log, or the Relay outbound
stream beyond the bounded roster delta.

Future signal operations (TERM, STOP, KILL) are not part of this RFC. If
added, they must validate ownership against the Session's uid before sending
any signal, and must require a client-side confirmation gate.

## Capability protocol

ghostline uses a normalized capability protocol to advertise which optional
RPCs a server supports. This RFC introduces a new capability and, in doing
so, fixes the pattern so future additions follow the same shape.

### Pattern

1. The capability name uses the form `<feature>-v<n>`. The version suffix
   increments on any breaking change to the RPC's params or result schema.
   Non-breaking additions (a new optional field) do not bump the suffix.
2. The capability constant is declared in `ghostline/rpc.go` next to the
   existing `CapabilityRawPayload`, `CapabilityStreams`, and
   `CapabilityAtomicState`. The constant is the single source of truth; the
   string value is what the wire carries.
3. The capability is added to the `protocolCapabilities` slice so it is
   advertised by every `Version` RPC response, in the `Capabilities` field
   of `versionResult`. Old clients that do not know the capability ignore
   it; old servers that do not advertise it cause the client to fall back
   to a no-op.
4. The RPC method itself is added to the `rpcMethod*` block in
   `ghostline/rpc.go`. The handler in `server.go` and the wrapper in
   `client.go` both gate on the capability before performing any work.
5. Documented alongside the capability is the fallback contract: what the
   client must do when the capability is absent. For `processes-v1`, the
   fallback is "return `(nil, nil)`; the caller treats it as no data".

### New capability

```go
// In ghostline/rpc.go
const CapabilityProcesses = "processes-v1"
```

`processes-v1` advertises the `processes` RPC. The RPC returns
`[]SessionProcess` with the schema documented in the "New ghostline types"
section above.

### Fallback contract

When a Warren Host connects to a `ghostline-serve` whose `Version` does
not include `processes-v1`, the Host:

- never calls the `processes` RPC;
- treats the `Processes` field of every `Session` as empty;
- does not retry the version handshake on every tick; the result is cached
  at handshake time and re-checked only on reconnect;
- does not raise an error to the operator; the absence is silent because
  the existing `Session.Process` and `Session.Directory` fields are still
  populated by the original `metadata` RPC, which is its own capability
  and is unaffected by this RFC.

### Cross-version behavior matrix

| Host | ghostline-serve | Behavior |
| --- | --- | --- |
| old (no processes) | old (no capability) | unchanged, `Session.Processes` is absent |
| old (no processes) | new (advertises capability) | old host ignores the capability, unchanged |
| new (uses processes) | old (no capability) | new host silently omits `Session.Processes` |
| new (uses processes) | new (advertises capability) | new host populates `Session.Processes` |

The matrix is exhaustive. The protocol does not need a compatibility
shim for the new field.

## Testing and acceptance

The implementation is complete only when all of the following hold. The
tests are split between ghostline (stdlib) and Warren (product) because the
responsibilities are split.

### ghostline (stdlib)

G1. `go test ./...` in `../ghostline` passes locally and on the release
    build host.
G2. A unit test for the macOS walker over a synthetic proc table asserts:
    - the foreground tree is BFS-correct from the leader PID;
    - `IsForeground` is true for every member of the tree;
    - the cap truncates deterministically (BFS order, leaders first);
    - depth > `MaxDepth` is cut.
G3. A unit test for the Linux walker asserts the same invariants.
G4. A unit test for the `Version` RPC asserts the `Capabilities` field
    includes `processes-v1` on a build that ships the walker, and omits it
    on a build without the walker (e.g. a non-macOS, non-Linux platform
    stub).
G5. A unit test asserts the `processes` RPC handler returns
    `unavailable` (or the documented fallback error) when the
    `processes-v1` capability is not advertised on the connection.
G6. A conformance test against a real `ghostline-serve` binary asserts the
    capability advertisement and a full RPC round-trip.

### Warren Headless (product)

W1. `go test ./...` in `Headless/` passes.
W2. A unit test for the `RuntimeProcessProvider` adapter asserts:
    - when the ghostline `Version` lacks `processes-v1`, the function
      returns `(nil, nil)` and no error;
    - when the capability is present, the function calls the RPC exactly
      once per tick and caches the result;
    - the workspace-rooted join extends the ghostline result with PIDs
      whose cwd is inside the canonicalized Workspace path;
    - the merge is de-duplicated by PID and the 256 cap truncates with
      foreground-tree-first preference.
W3. A unit test for `processCache` asserts:
    - new PIDs are stamped with `FirstSeen = now`;
    - PIDs that disappear are kept for `processExitedTTL` and then dropped;
    - `prune(running)` drops Sessions that are no longer running.
W4. A unit test for `pickProcessInterval` asserts the 3-tick hysteresis
    does not flap on a single outlier tick and does settle after three
    consecutive ticks in the same bucket.
W5. A unit test for `subscriberCount` asserts it returns zero when the
    `wsPeer` set is empty and increments on each new peer registration.
W6. A unit test for `sessionProcessesByPID` asserts:
    - steady state produces no delta;
    - a single PID change produces a one-entry upsert;
    - a disappearing PID produces a `remove`, not an upsert.
W7. A unit test asserts the `processLoop` is a no-op when
    `subscriberCount() == 0` and resumes within one tick of the first
    subscriber reconnecting.
W8. A unit test asserts that the Roster delta over 50 stable Sessions
    produces less than 5 KB of payload, measured with
    `json.Marshal` on a synthetic snapshot.

### Integration (Warren, real bash)

I1. An integration test starts a `bash -i` Session, runs
    `sleep 30 &` and `python3 -c 'import time; time.sleep(30)'` inside
    it, waits one tick, and asserts:
    - `bash` is in `processes` with `isForeground=true`;
    - `sleep` and `python3` are present with `isForeground=false`;
    - `sleep`'s `ppid` points to `bash`.
I2. The same test then `kill -9`s `sleep` and asserts that within one tick
    the entry is `state=exited` and within `processExitedTTL` it is
    removed.
I3. A test asserts the per-Session PID cap is enforced (a process spawned
    in a tight loop that exceeds the cap does not grow the cache beyond
    `processPIDCap`).
I4. A test asserts the cross-version behavior matrix: starting a Session
    against a `ghostline-serve` binary that does not advertise
    `processes-v1` results in `Session.Processes` being empty without
    any error in the daemon log.

A pull request that touches this area without a passing run of every
numbered item above is incomplete. The `G` items gate the ghostline tag
release; the `W` and `I` items gate the Warren Headless release.

## Implementation guide

The order below is the dependency order. Each step is independently
mergeable. Steps G1–G3 land in ghostline first; steps W1–W5 land in warren
after a ghostline tag is available.

### ghostline (stdlib) — prerequisite

G1. **Add `Session.Processes` and the `processes` RPC.** Extend
    `sessionBackend`, `localSession`, `remoteSession`, `Session`,
    `rpc.go`, `server.go`, and `client.go`. Add `processes_darwin.go`,
    `processes_linux.go`, `processes_other.go`.
G2. **Add the `CapabilityProcesses` constant** in `rpc.go` and add it to
    the `protocolCapabilities` slice. The constant is the wire value
    `"processes-v1"`.
G3. **Ship a ghostline tag.** The tag is the only contract surface the
    Warren Host pins against. The `go.mod` bump on the warren side happens
    after the tag exists.

### warren Headless (product)

W1. **Wire the runtime adapter.** Extend `runtime/metadata.go` with
    `ProcessInfo` and `RuntimeProcessProvider`. Implement `Processes` on
    `GhostlineRuntime` in `Headless/internal/server/ghostline.go`. Gate
    the call on `CapabilityProcesses` from the cached `Version` result.
    Implement the workspace-rooted join on the Host side as documented
    in the "Warren Headless: new runtime adapter" section.
W2. **Add the cache and the loop.** Add `process_cache.go`. Add the
    constants, `processLoop`, `pickProcessInterval`, `subscriberCount`,
    and the overlay in `RosterVersion` in `service.go`. Start the loop
    from `lazyInit` next to `metadataLoop` (line 562). Hysteresis uses a
    3-tick counter; subscriber-gated zero work preserves the cache.
W3. **Extend the API surface.** Add `ProcessInfo` and `ProcessState` to
    `api/types.go`. Add `Processes []ProcessInfo` to `Session` with
    `json:"processes,omitempty"`. Verify that `store/store.go` does not
    persist the field; the store round-trip is for the durable record
    only.
W4. **Update the roster delta.** Update `roster_delta.go` to compute the
    per-session PID diff. Mark `Session.Processes` `json:"-"` for the
    entity-delta serialization only; the field remains live in
    `api.State` for diff computation.
W5. **Tests.** Add the W1–W8 and I1–I4 tests from "Testing and
    acceptance".

### Design decisions honored by every step

- **ghostline stays a stdlib.** The walker exposes only the foreground
  tree and cwd. It takes no Workspace path, no Session identifier, no
  Warren-specific constant. The Warren Host owns the workspace join.
- **Capabilities are versioned.** New RPCs follow the
  `<feature>-v<n>` naming and are added to the `protocolCapabilities`
  slice. The capability gate is checked at the client wrapper, not at
  the server handler.
- **Cross-version compatibility is silent.** A missing capability means
  empty data, not an error. The original `metadata` RPC remains the
  fallback for `Session.Process` and `Session.Directory`.
- **Resource budgets are normative.** Every step lands behind a
  benchmark that records the per-tick cost and the per-PID walker cost.
  The benchmark is in the CI pipeline, not a one-off measurement.
- **The cache is overlay-only.** `Session.Processes` is never persisted
  in `state.json`. A daemon restart begins a fresh cache; the next
  subscriber triggers an immediate probe.
- **The exited retention is a Warren concept.** ghostline returns only
  the current observed set. The Warren `processCache` is the only place
  that stamps `FirstSeen` and infers `exited`.

UI consumption is a separate RFC, scoped after this contract has shipped
and been measured in production for at least one release.

## Open questions deferred to a follow-up RFC

The following are deliberately out of scope and are listed so a future RFC
can pick them up without re-deriving the boundary.

- A ghostline RFC that documents the capability protocol pattern in full
  (`<feature>-v<n>` naming, the `protocolCapabilities` slice, the
  client-side gate, the documented fallback contract). This RFC uses the
  pattern but does not author the canonical spec; that belongs in the
  ghostline repo so the stdlib owns its own wire contract.
- Client UI rendering, including the choice between a collapsed panel and
  a dedicated inspector drawer.
- Process signal operations (TERM, STOP, KILL, CONT) with client-side
  confirmation and uid ownership checks.
- Per-PID CPU and memory accounting. The macOS walker would need a
  `proc_pidinfo(PROC_PIDTASKINFO)` deltas read; the Linux walker would
  read `/proc/<pid>/stat` field 13/14. The cost of either is significant
  and would invalidate the resource budget above; that work must come with
  its own budget revision.
- Client-driven probe pacing (e.g. lowering the cadence when the
  desktop window is unfocused). This depends on the visibility plumbing
  that is itself out of scope here.

## References

- Warren RFC 0006 — Agent activity and human attention. The pattern of an
  overlay-only Host-owned projection is reused here.
- Warren RFC 0010 — iOS agent view presentation parity. The current
  end of the Warren RFC sequence.
- `Headless/internal/server/worktree_processes.go` — the existing pattern
  for lsof + /proc + cwd resolution. The Warren-side workspace join reuses
  its macOS `lsof -t +D` and Linux `/proc` walkers; the new code adds
  per-PID cwd lookup, but the underlying primitives are the same.
- `Headless/internal/server/metadata_cache.go` — the cache pattern
  mirrored by `process_cache.go`.
- `Headless/internal/server/service.go:562-597` — the existing
  `metadataLoop` that `processLoop` is shaped after.
- `ghostline/metadata_darwin.go` — the existing single-process probe the
  new walker is a generalization of.
- `ghostline/session.go:273-295` — the existing `localSession.metadata`
  pattern the new `Processes` method follows for fd access.
- `ghostline/rpc.go:48-72` — the RPC method list the new `processes`
  method slots into.
- `ghostline/rpc.go:34-45` — the existing `Capability*` constants and the
  `protocolCapabilities` slice the new `CapabilityProcesses` constant
  joins.
- The ghostline stdlib positioning (no Warren concepts in the wire
  contract) follows the precedent set by the existing
  `Session.Metadata` RPC, which similarly returns only generic session
  attributes and leaves product-specific decisions to the caller.
