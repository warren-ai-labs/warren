# Changelog

All notable changes to Warren are documented here.

## [Unreleased]

_No changes yet._

## [0.16.1] - 2026-09-16

> Fix release: rich mode's pane bar draws only the panes on screen, so a visit
> to a Session outside the layout no longer pins a split group to the top chrome.
> The JSON control protocol remains at 4.0.

### Fixed

- Stop the pane bar from pinning a split group on the top chrome in rich mode.
  The sidebar already lists Sessions there, so the bar now draws only the panes
  on screen: visiting a Session outside the layout no longer keeps a group for
  panes the user cannot see. Compact mode keeps the group on the strip, where it
  is the only way back into the split.

### Release notes

- The JSON control protocol remains at 4.0 and this release migrates no state.
- Local packaging uses the available Apple Development signing identity and is
  not notarized; the archive is suitable for internal or temporary testing, not
  general public distribution.

## [0.16.0] - 2026-09-16

> Fix release: restores the Desktop's pane-group writes, which 0.15.0 dropped
> because the Swift client never advertised the `pane-groups-v1` capability, and
> repairs the split-adoption path that made a scope's second split revert or land
> on the wrong pair. The JSON control protocol remains at 4.0.

### Added

- Keep the sidebar rail lit for the workspace the center is showing, so the tree
  marks the live workspace even with no pointer on it.

### Changed

- Keep the pane bar's group on the strip while another Session is visited, so the
  strip stays the way back into the split instead of hiding the group.
- Keep the sidebar's content column on the rail when the rail narrows; the
  build-provenance marker reserved a fixed slot and refused to compress, and
  centring that over-wide column pushed every row's leading text off the window.

### Fixed

- Advertise `pane-groups-v1` from the Swift transport client, so the Host's
  negotiated capability set includes it and the Desktop can create, split,
  rename, move, and remove arrangements again. Capability negotiation is an
  intersection and 0.15.0 shipped only the Host-side advertisement, so every
  pane-group write from the Desktop was gated off and silently dropped while
  CLI-driven layouts kept working.
- Keep pane groups through a projection copy: `reorderingTabs` and
  `withConnectionState` rebuilt the projection field by field and omitted
  `paneGroups`, so the Tab move that ends a split emptied them and the following
  tree commit could not find the scope's existing group. A second split in the
  same scope could therefore never land.
- Stop a stale roster from collapsing a split in flight, and split the Session
  the user aimed at instead of a stale pane: drop a scope's local tree when the
  Host owns no group for it and nothing is in flight, and match a pending split
  by the Tab rather than the pane ID the Host's echo replaces.
- Show a spinner in the iOS send button while a message is sending or
  attachments are uploading, and stop the bottom status text from flickering as
  the send state changes.

### Release notes

- The JSON control protocol remains at 4.0 and this release migrates no state, so
  a Host that already owns pane groups keeps them. If 0.15.0 is installed,
  upgrade the Desktop to 0.16.0 before relying on split panes there; the CLI was
  never affected.
- Local packaging uses the available Apple Development signing identity and is
  not notarized; the archive is suitable for internal or temporary testing, not
  general public distribution.

## [0.15.0] - 2026-09-16

> Minor release: makes a split arrangement durable Host state that any client
> can render, unifies search across Desktop, iOS, and Web, and turns selecting a
> pane into a reparent instead of a cold attach. The JSON control protocol
> remains at 4.0; Host state moves to schema 4.

### Added

- Make a split arrangement durable Host state: a Workspace or Terminal Group
  can hold several arrangements, the Host stores the pane tree, and
  `warren pane` lists, creates, splits, closes, renames, moves, and removes
  them. `warren session panes` now reports the Host's arrangement and the
  client displaying it, instead of depending on a connected Desktop.
- Inject a minimal OSC 7 working-directory hook for zsh and fish sessions, so
  the pane title, tab, and sidebar track `cd` without depending on the user's
  own shell setup.
- Share Session label rules across Desktop, iOS, and Web so every client shows
  the shell-reported directory and the running command, and add `RUN` and `CWD`
  columns to `warren session list`.
- Split high-frequency foreground metadata into its own roster delta, so a
  directory change no longer retransmits the full Session and its Agent
  projection over a Relay link.
- Share one search engine across Desktop, iOS, and Web: the same role weights,
  match tiers, phrase bonus, abbreviation rule, and
  `w:`/`p:`/`s:`/`t:`/`g:`/`@blocked` query grammar, with Tasks searchable by
  name and by the branches they span. A result is one compact line carrying its
  ancestry and the field that explains the match, led by the provider's own mark
  instead of a terminal glyph, and iOS reaches the same index behind a compact
  sheet.
- Support GFM markdown callout alerts in iOS Agent transcripts.
- Break the terminal attach's latency down by phase and trace the
  output-subscription lifecycle, so a slow attach names the phase that spent the
  time.

### Changed

- Stop a rich-mode workspace row from navigating on a single click. Hovering
  the row or one of its Sessions now lights the rail that ties the group
  together, and double-click starts a new Session in the workspace.
- Keep that rail lit for the workspace the center is showing, so the tree marks
  the live workspace even with no pointer on it.
- List a Task-linked Workspace's Sessions under its Task row, which is the row
  that owns navigation, and leave the context-only Projects copy without leaves;
  collapsing Tasks now hides those Sessions the same way collapsing Projects
  hides the ones that copy owns.
- Read a Desktop sidebar Session leaf as its running command and directory
  instead of the generic "Shell", matching the tab label; a user-set or
  generated name still wins.
- Fall back to the directory a Session was launched in when the shell has not
  reported OSC 7, and carry the reported directory across a Ghostline rolling
  upgrade (Ghostline v1.3.2).
- Let a window render exactly one of a scope's arrangements, with Cycle Pane
  Group (⌘`) and Previous Pane Group (⇧⌘`) stepping through them. The choice is
  per viewer and never sent to the Host, and a write is gated on the negotiated
  `pane-groups-v1` capability so an older Host sees no unknown method.
- Gather a split's Sessions into one unbroken run in the pane bar, drawn as a
  labelled group at the first member's place, and stop a member from being
  dragged on its own so the rule and the chip cannot describe a layout the strip
  no longer shows.
- Promote every retained surface, local or remote, so selecting a pane that is
  already on screen is a reparent plus a control-lease swap instead of a
  snapshot re-seed; only a cold Session, or one whose transport dropped, still
  subscribes.
- Raise the warm surface budget to 32 surfaces and the warm byte limit to 3 GiB
  so the count limit is what binds, at the cost of roughly 2-3 GB of warm memory
  in the worst case.
- Pace iOS chat streaming through a dedicated pacer, cache markdown layout, and
  hand a send off without re-rendering the transcript.

### Fixed

- Keep a split group on screen while another Session is visited, hold the pane a
  split in flight was aimed at, and land a pending split as soon as its Session
  exists instead of waiting for a change notification.
- Make every close command act on the layout its chip belongs to, name every
  close by its Tab, and let a split move the Tab order.
- Stop deleting a local arrangement the Host has not seen yet, so a first split
  whose write is still in flight keeps its optimistic tree.
- Apply PTY resizes and the viewport carried by `session.focus` off the
  connection reader, with latest-wins semantics per Session, so a slow resize no
  longer delays every later command on the same connection.
- Recover a retained surface whose native renderer is gone, and report and
  recover a promotion that never draws, instead of leaving a black pane behind
  its recovery gate.
- Draw a lone pane through the split view so it survives a split, keep its title
  row in compact mode, and keep the pane view when a Session is created.
- Treat restored Agent turns as a baseline instead of completions, so a Desktop
  that connects during a transcript replay no longer rings for every restored
  terminal turn.
- Render a lone tool call as a single non-expandable row, and render dotted
  canonical control-plane events as markers in the Web client.
- Present the iOS photo picker from the composer menu, stop the composer from
  dropping IME input or lagging on each keystroke, let a compact chat bubble
  wrap past its max width, and smooth the send-time scroll and bottom tray
  transitions.

### Release notes

- The JSON control protocol remains at 4.0; the release adds the `pane-group.*`
  methods behind the `pane-groups-v1` capability, and Host state moves to schema
  4 additively. Pre-4.0 clients are still rejected at authentication. Validate
  host-owned pane groups across a rolling Host upgrade: a Host without the
  capability projects no groups, so a scope renders its Tab alone rather than
  failing.
- The warm surface budget rises to 32 surfaces and a 3 GiB byte limit, so a
  fully warm pool can retain on the order of 2-3 GB. Watch resident memory on a
  long-running Desktop with many open Sessions.
- Local packaging uses the available Apple Development signing identity and is
  not notarized; the archive is suitable for internal or temporary testing, not
  general public distribution.

## [0.14.0] - 2026-09-14

> Minor release: adds native split terminal workflows, historical Usage
> analytics, richer sidebar and workspace organization, and runtime-aware
> Session titles across Desktop, Web, and Headless. The JSON control protocol
> remains at 4.0.

### Added

- Add native AppKit split terminal panes with drag-and-drop placement, pane
  controls, independent PTY sizing, and screen reporting.
- Rebuild Usage from historical transcripts with per-day Agent, model, and
  project breakdowns, a selectable heatmap, an intraday curve, and cached
  fetches.
- Add a thread-oriented sidebar mode with Sessions as leaves, Task pinning,
  Projects and Workspaces cards, and quick setup scripts.
- Pin a Task from the Desktop sidebar context menu so important cross-repository
  Tasks sort above the rest, matching Projects, Workspaces, and Sessions.
- Add per-day Usage breakdowns by Agent, model, and project, and a Tokens/Cost
  toggle on the intraday curve.
- Show a Session's foreground command line (for example `npm run dev`) and the
  working directory the shell reports through OSC 7 in the pane title, tab, and
  sidebar, instead of falling back to the launch command.

### Changed

- Make pane close actions Session commands: closing a pane, other panes, or all
  panes now ends the Sessions shown there, while surviving split panes retain
  their layout and selection.
- Keep startup work, Relay device listing, state-store reads, and loopback
  handoff work off the terminal attach path to improve reconnect reliability.
- Rework Desktop Settings and Usage into categorized two-column layouts with
  grouped cards, refined typography, and a clearer sidebar tree rail.
- Read a Session's working directory from the shell's OSC 7 report and the
  foreground process name and command line from the runtime probe, and enable
  that probe by default now that the macOS path uses native sysctl calls.
- Remove the Tasks section from the Web client, so Tasks are no longer part of
  the Web surface; a Task-linked Workspace renders as an ordinary Workspace
  there, and Task management stays on Desktop and the CLI.
- Send only the selected day's five-minute Usage buckets instead of the whole
  range, cap the intraday payload at the most recent day when no day is picked,
  and skip the Usage reprice scan when neither usage nor prices changed; a
  year-long range no longer moves or reprices every bucket on each open.
- Reuse a freshly fetched Usage payload when moving between the Overview and
  Usage settings pages, and make Refresh bypass that reuse.
- Let the Usage heatmap select a day in both pages: Overview opens that day's
  detail, and Detail replaces the day menu with the same grid.

### Fixed

- Keep a Session on its retired Agent conversation until the replacement
transcript is on disk, so `/clear` and `/new` no longer regenerate the AI title
from the previous conversation; a late title response from a replaced
conversation can no longer name the current one.
- Fail loopback Host connections immediately instead of waiting for
  connectivity, and give them a short welcome deadline, so a Desktop that
  starts during a Ghostline handoff reconnects as soon as the daemon returns
  instead of showing "Migrating runtime sessions…" for the full remote
  handshake window.
- Apply a Usage range change that is made while a fetch is in flight instead of
  dropping it, so the figures always describe the selected window.
- Scope the "provider reports no token counts" caveat to the requested range, so
  a historical window is not blamed for an Agent that only exists today.

### Release notes

- The release adds no control-protocol version change or state-schema
  migration. Validate native split-pane focus and close behavior, Usage
  history reconstruction, and OSC 7 title reporting on a clean host before
  publishing.
- Local packaging uses the available Apple Development signing identity and is
  not notarized; the archive is suitable for internal or temporary testing,
  not general public distribution.

## [0.13.0] - 2026-09-11

> Minor release: makes Warren Hosts discoverable on the local network, adds
> explicit Host-armed pairing, and brings multi-Host navigation and iOS Host
> management into the client surface. This release covers macOS, iOS, Web, and
> Headless clients; the JSON control protocol remains at 4.0.

### Added

- Add mDNS/DNS-SD discovery for Warren Hosts, stable Host identity, candidate
  probing, direct-LAN routing, and endpoint aggregation across changing network
  addresses.
- Add an explicit Host-armed LAN pairing flow with a short-lived PIN and scoped
  client credentials; discovery alone never grants access.
- Add multi-Host Desktop navigation with Host-scoped Projects and Workspaces,
  endpoint display names, active-session filtering, clearer empty states, and
  Task-aware navigation.
- Add iOS Host management with local discovery, direct-LAN and Relay route
  selection, QR/PIN pairing, Agent history reload, and richer Agent cards.
- Record anonymous onboarding download starts in Workers Analytics Engine with
  release, visitor, platform, location, language, and referrer dimensions.

### Changed

- Keep Desktop, Web, CLI, and iOS Agent surfaces on the canonical projection
  while normalizing plan events, compaction summaries, provider markup, diffs,
  and legacy read responses.
- Make endpoint identity explicit in transport and sidebar state so focus,
  resize, routing, and resource selection remain scoped to the correct Host.
- Keep the terminal sidebar and embedded editor state stable while improving
  attach/reconnect behavior and preserving workspace context.

### Fixed

- Preserve terminal connections across output resets and guard focus claims and
  resizes against stale layout generations.
- Route task-linked Workspaces to their actionable Task row and distinguish
  unavailable Hosts, active-only filtering, and Hosts without Projects.
- Preserve embedded-editor workspace state across presentation and navigation
  changes.

### Release notes

- LAN discovery is a reachability mechanism, not a trust grant. Pairing must be
  explicitly armed on the Host, and existing Relay/direct endpoints remain
  available when LAN discovery is unavailable.
- The release adds no control-protocol version change or state-schema migration;
  validate direct-LAN pairing, multi-Host routing, and iOS local-network
  permissions on real devices before publishing.

## [0.12.2] - 2026-09-09

> Patch release: improves remote Host diagnostics and compatibility handling,
> strengthens Agent interaction fidelity, and stabilizes terminal attachment.
> This release covers macOS, Web, and Headless clients; iOS changes remain
> outside the release scope.

### Added

- Add advisory Host health probes for direct endpoints and show reachability,
  Headless build, protocol status, and connection errors in the Desktop
  Execution Server menu, with a manual **Check hosts** action.

### Changed

- Extend Relay and remote WebSocket handshake windows for slower DNS, TLS,
  proxy, and mobile-network negotiation.
- Preserve Codex question schemas while exposing optional notes and completed
  answer labels through the provider-neutral interaction response.
- Keep terminal attach and focus reconciliation generation-safe, coalesce
  duplicate attaches, and avoid redundant layout work during presentation.
- Keep external IDE discovery cached across repeated Desktop menu opens.

### Fixed

- Stop reconnect loops when the Host reports an incompatible protocol or
  terminal-state format, while retaining retry behavior for transient failures.
- Match resolved Agent interactions by request or interaction identity so
  replayed responses retain their original questions and options.

## [0.12.1] - 2026-09-08

> Patch release: improves Agent interaction reliability, cross-client control
> flow, task and workspace navigation, external IDE discovery, and the
> embedded editor surface. This release covers macOS, Web, and Headless
> clients; iOS changes remain outside the release scope.

### Changed

- Keep canonical Agent View operations independent from the single-tenant
  terminal PTY control lease so Web and Headless Agent actions do not contend
  with terminal focus.
- Simplify the Web Agent surface by keeping model and reasoning choices in
  launch-time/provider configuration instead of issuing in-session switch
  commands.
- Cache external IDE options for repeated workspace menu opens and align the
  embedded editor typography with the native Warren editor.
- Keep task-linked workspaces anchored to their Task navigation, avoid
  unnecessary sidebar recentering, and make workspace selection state clearer
  across Desktop and Web; keep disabled workspace rows visually quiet.

### Fixed

- Resolve structured question responses by option index, including multi-choice
  keyboard navigation, custom answers, and multi-step interactions.
- Prevent Agent interaction submissions from getting stuck behind terminal
  control ownership or a stale loading state.

## [0.12.0] - 2026-09-08

> Minor release: introduces Warren protocol 4.0, canonical Agent execution, an independently deployed Relay control plane, and a coordinated terminal/runtime boundary. Pre-4.0 clients are rejected. Host state schemas 1 and 2 migrate in place to schema 3; compatible Ghostline v1 sessions use rolling handoff, while v0 sockets and legacy Agent projections require recreation. Targets arm64 Apple Silicon on macOS 13+; Public Access uses Relay routes.

### Added

- Add the canonical Agent event protocol with a durable Host journal, idempotent command admission, history pagination, gap recovery, reconnect-safe client replicas, and structured status, tool, diff, diagnostics, queue, goal, attachment, approval, and question events.
- Add normalized Agent providers for Codex, Claude, OpenCode, Pi, Qoder, and Antigravity, with model and reasoning controls, queued turns, explicit interruption and cancellation, provider binding hooks, and Agent-first CLI commands. Trae remains an interactive shell preset rather than an Agent provider.
- Add the independently deployed Relay control plane with expiring enrollment keys, server-owned Host identities, opaque share links, signed scoped capabilities, refresh tokens, device association and revocation, IP/path routes, and LAN-to-Relay endpoint fallback.
- Add embedded SSH endpoints and a bundled forwarding helper, plus terminal-link opening in the workspace-scoped embedded editor.
- Add safer Task, Workspace, and Session workflows: Task rename and ordering, active-only workspace filtering, setup scripts, worktree import controls, MRU navigation, compare-and-swap session moves, preflight checks, and guarded undo operations.

### Changed

- Move terminal recovery to atomic DENB state snapshots while retaining wire version 1, durable Ghostline cursors, bounded output rings, and rolling handoff across compatible Ghostline v1 runtimes.
- Bound CLI list and transcript output by default. Use `--all`, `--ended`, `--full`, `--tool-output`, filtering, quiet mode, or explicit truncation controls when automation needs more data.
- Keep Web, Desktop, and CLI Agent surfaces on the canonical event projection; unknown Agent event types are retained for forward-compatible replicas.

### Breaking

- Advance the JSON control protocol to 4.0. Legacy Agent aliases, JSON terminal-input fallback, the old session lifecycle, compatibility attach/roster paths, the Ghostline v0 bridge, and the legacy PTY alias are removed.
- Require the coordinated 0.12.0 Host and client surface. A pre-4.0 client is rejected during authentication, and old Ghostline v0 sockets cannot be recovered by this release.

### RFCs

- [RFC 0012: Antigravity CLI Agent support](docs/rfc/0012-antigravity-cli-agent-support.md) — proposed, with provider implementation included.
- [RFC 0013: Agent interaction architecture and PTY guarding](docs/rfc/0013-agent-interaction-architecture-and-pty-guarding.md) — proposed.
- [RFC 0014: Autonomous engineering pipeline](docs/rfc/0014-autonomous-engineering-pipeline.md) — proposed.
- [RFC 0015: Cloud Agent daemon and scheduled bots](docs/rfc/0015-cloud-agent-daemon-and-scheduled-bots.md) — baseline draft.
- [RFC 0016: Canonical Agent execution protocol](docs/rfc/0016-canonical-agent-execution-protocol.md) — accepted and implemented.
- [RFC 0017: Agent task handoff](docs/rfc/0017-agent-task-handoff.md) — accepted and implemented.
- [RFC 0018: Multi-Host sidebar and projects](docs/rfc/0018-multi-host-sidebar-projects.md) — draft.
- [RFC 0019: LAN Host discovery and pairing](docs/rfc/0019-lan-host-discovery-and-pairing.md) — draft.

## [0.11.3] - 2026-08-30

> Patch release: makes Codex Working state visibly blink in the agent view and preserves configured terminal colors after snapshot restore. Targets arm64 Apple Silicon on macOS 13+; Public Access uses Relay routes. A local Apple Development build may fail Gatekeeper until replaced by a notarized Developer ID build.

### Changed

- Show a visible blinking Working indicator while Codex is actively producing output.
- Reapply Warren's terminal color configuration after native snapshot restoration so Working output remains visible.

### Fixed

- Mark interrupted agent messages consistently in the Web view.

## [0.11.2] - 2026-08-29

> Patch release: adds Host-owned Tasks that aggregate Workspaces across Projects and migrates Host state to schema 2 so Task data is durable. Targets arm64 Apple Silicon on macOS 13+; Public Access uses Relay routes. A local Apple Development build may fail Gatekeeper until replaced by a notarized Developer ID build.

### Added

- Add Host-owned Tasks that aggregate Workspaces across Projects, with provider-neutral external work-item metadata, Web and CLI lifecycle controls, and Web/Desktop Workspace attach and detach actions.

### Changed

- Migrate Host state from schema 1 to schema 2 so Task data is durable and unknown future schemas fail closed.

## [0.11.1] - 2026-08-29

> Patch release: hardens endpoint switching, preserves Public Access state, fixes web-link auth and mobile scrolling, and improves Linux terminfo handling. Targets arm64 Apple Silicon on macOS 13+; Public Access uses Relay routes. A local Apple Development build may fail Gatekeeper until replaced by a notarized Developer ID build.

### Added

- Add endpoint hang diagnostics with a main-thread watchdog, detailed endpoint and surface lifecycle logging, and a freeze-capture helper for weblink and host switching stalls.

### Changed

- Preserve Codex shimmer while lifting black text for clearer Working visibility.
- Build and verify Linux headless artifacts in CI.

### Fixed

- Persist Public Access route state across daemon restarts by checking persisted Relay route metadata so a configured route keeps Start instead of Configure.
- Preserve the auth fragment when copying web links so pasted links can authenticate the protected WebSocket.
- Keep warm promotion for remote endpoints and rebuild the connection when endpoint locality changes so local and remote terminal presentation remain correct.
- Allow initial input for dedicated codex, claude, and opencode sessions before the agent transcript is bound so the first prompt is delivered without requiring a Terminal setup retry.
- Install `xterm-ghostty` terminfo on Linux by supporting both `x` and `78` tic output directories.
- Restore vertical swipe scrolling for the agent view on mobile by fixing flex sizing and touch-action hints.

## [0.11.0] - 2026-08-28

> Minor release: refreshes terminal rendering and session handoff, hardens workspace creation, and bundles truecolor terminfo for Ghostline. Targets arm64 Apple Silicon on macOS 13+; Public Access uses Relay routes. A local Apple Development build may fail Gatekeeper until replaced by a notarized Developer ID build.

### Added

- Add Refresh Runtime to the daemon menubar for manual runtime refresh with failure feedback and automatic version polling.
- Bundle `xterm-ghostty` terminfo with Tc (truecolor) so Ghostline sessions inherit correct truecolor without requiring Ghostty to be installed; the bundled entry is auto-installed to `~/.terminfo` when missing and falls back to `tic` generation when no checked-in entry is available.

### Changed

- Make warm promotion jump to the latest frame in one tick without visible replay or Zeno target chase; background subscriptions keep the grid current while hidden and scrollback remains intact.
- Debounce resize handling (50 ms coalesce plus 250 ms hidden defer) so actively outputting shells settle at the new width before reveal and avoid 1-2 s of missing color blocks.
- Tune terminal palette for codex Working visibility: restore bold-bright palette to match xterm, set Ghostty minimum-contrast to 1.8, and ensure foreground draws happen at synchronized-output boundaries rather than queue-empty heuristics.

### Fixed

- Make workspace creation visible and reliable: auto-expand the owning project when a workspace is added while collapsed or unselected, keep the creation dialog open on failure with inline error and Creating state, and surface Not connected and daemon errors both inline and in the notice center.
- Harden Ghostline handoff: restrict version handoff to canonical semver tags, expose WarrenVersion in headless State for upgrade gating, make forced ghostline handoff reliable even without a cached revision, and guard synchronized-output tracking across Data boundaries with spillover buffering and a 50 ms stall force to avoid permanently black warm promotions.
- Isolate OpenCode SQLite tailer memory failures: avoid GROUP BY on large message payloads by using an indexed correlated aggregate for part timestamps, retain only title and body from message summaries, and contain SQLITE_NOMEM panics at the tailer boundary so one oversized conversation cannot crash headless during restore.
- Unify shell and direct codex Working blink color: keep Ghostty ticking while hidden without Metal draws for the blink clock and ensure direct codex sessions inherit truecolor via sanitized environment so shell and direct share the same amber Working color.

## [0.10.1] - 2026-08-28

> Patch release: fixes codex Working blink color/visibility and the OpenCode bind plugin payload format.

### Fixed

- Prevent the codex Working blink from appearing black in shell overlays by skipping Ghostty draws when the terminal view is not presentable.
- Align direct codex Working color with shell sessions by defaulting COLORTERM to truecolor for ghostline children.
- Correct the OpenCode bind plugin to use PluginModule and real newlines for bind/state payloads.

## [0.10.0] - 2026-08-28

> Major release: Warren upgrades to a new incompatible Ghostline runtime semantics. Existing sessions are migrated automatically via the verified handoff path. This is a super-major compatibility break from 0.9.x; downgrading without recreating sessions is not supported. This release targets arm64 Apple Silicon Macs running macOS 13 or later; a local Apple Development build may fail Gatekeeper until replaced by a notarized Developer ID build. Public Access uses Relay routes.

### Added

- Add upgraded Ghostline semantic handling for the new runtime contract.

### Changed

- Upgrade Ghostline to the new incompatible semantics with automatic session handoff; legacy v1 sessions are transferred without loss when the handoff is verified.
- Refresh terminal and session coordination to align with the new Ghostline contract.

### Fixed

- Harden Ghostline rolling upgrades and recovery around the new semantic boundary.

## [0.9.1] - 2026-08-25

> Patch release: Warren refreshes the Ghostline v1.0.0 dependency to commit
> `773f4fffbc9879a8b724b1873e230dcaa39dd58e` (`Exercise binary migration
> crash windows`) so the bundled runtime includes the corrected migration
> handoff behavior. This release targets arm64 Apple Silicon Macs running
> macOS 13 or later; a local Apple Development build may fail Gatekeeper until
> it is replaced by a notarized Developer ID build.

### Changed

- Refresh the Ghostline v1.0.0 module content and checksum to the current
  release commit.

### Fixed

- Ship Ghostline's updated binary migration and crash-window handling for
  rolling upgrades from the v0 compatibility bridge.

## [0.9.0] - 2026-08-25

> Major release: Warren moves to Ghostline v1, adds an embedded workspace
> editor, and makes terminal and session workflows faster and easier to
> diagnose. Existing Ghostline v0 sessions are migrated through the bundled
> v0.8 compatibility bridge. This release targets arm64 Apple Silicon Macs
> running macOS 13 or later; a local Apple Development build may fail
> Gatekeeper until it is replaced by a notarized Developer ID build.

### Added

- Add a workspace-scoped embedded editor for local workspaces, with an
  isolated code-server profile, managed layout, and background language
  extension setup.
- Add build identity diagnostics covering the release version, source revision,
  and dirty working-tree state.

### Changed

- Migrate the default Ghostline runtime to v1 and bundle a v0.8 compatibility
  bridge and arm64 library for one-time migration of retained sessions.
- Replace command-palette graph scans with a normalized, ranked resource index,
  native keyboard navigation, IME-safe input handling, contextual match status,
  and a bounded visible result set.
- Improve terminal and session responsiveness by reusing output and roster
  state, bounding transcript assembly, and making output replay more efficient.
- Defer native terminal split panes while the embedded editor and existing
  terminal surfaces remain the supported workflow.

## [0.8.2] - 2026-08-23

> Patch release: Warren aligns Public Access with Relay routes and keeps the onboarding
> experience at the top of the page until the terminal demo is explicitly
> requested.

### Changed

- Align the Public Access route lifecycle with the Relay protocol.

### Fixed

- Prevent ghostty-web's initial focus from scrolling onboarding to the WASM terminal; the `#demo` link remains an explicit opt-in.

## [0.8.1] - 2026-08-22

> Patch release: Warren now runs on macOS 13 and later on arm64 Apple Silicon,
> with a refreshed Ghostline runtime and a bundled Raycast terminal launcher.
> Intel macOS support is intentionally out of scope for this release.

### Added

- Add macOS 13 deployment support across the desktop app and Swift packages, including compatibility fallbacks for APIs introduced in macOS 14.
- Add a bundled Raycast terminal command and Warren icon for launching terminal groups from Raycast.

### Changed

- Update the Ghostline runtime dependency to v0.6.4 and keep rolling upgrades keyed to the expected release tag.
- Build and package the release app for arm64 macOS 13+ with the Ghostline-provided `libghostty-vt.dylib`, stable release markers, and explicit signing checks.
- Refresh terminal environment defaults before starting Ghostline or tmux child processes.

### Fixed

- Clean up stale Ghostline sockets, pid files, and logs before reconnecting or adopting a runtime so old artifacts cannot block session startup.
- Preserve desktop state observation and file-dialog behavior on macOS 13 while keeping newer macOS affordances available when supported.

## [0.8.0] - 2026-08-22

> Major release: Warren can share a Host through a self-hosted Relay,
> while agent workflows, resource links, and clearer desktop notices make
> macOS, Web, and CLI easier to control. Public Access enrollment keys stay in
> memory and go directly to Relay; review the setup-link and capability flow before
> sharing one.

### Added

- Add Public Access through a self-hosted Relay, with Settings-based Save & Test, pairing, route lifecycle controls, restart recovery, and credential-free endpoint reporting.
- Add agent-first CLI commands for creating, listing, reading, sending, waiting for, attaching to, and targeting Codex and Claude Agents; keep normalized transcripts separate from raw PTY sessions and support bounded turn waits.
- Add provider-neutral Agent activity and human-attention status across the Host, Web, Desktop, and CLI, including explicit input, approval, warning, stalled, failed, ready, and exited states with Workspace and Terminal Group aggregation.
- Add scoped resource links for Project, Workspace, and Session targets through `warren://terminal` and Web hash state, plus `warren://settings` links that can prefill Public Access setup.
- Add a bounded desktop notice center for system messages, diagnostics, and update failures, with unread and mute controls, and add a compact Workspace More menu for secondary actions.
- Add shared Unix text-editing shortcuts to Web and native AppKit text fields without intercepting terminal input.

### Changed

- Use Relay route metadata and scoped capabilities without packaging a local reachability worker.
- Make Agent and roster projections explicit and bounded, promote Agent commands to the primary CLI interface, and keep terminal, Agent, and transcript operations semantically separate.
- Replace the diagnostic sidebar with stable top-chrome notices and responsive overflow actions while preserving terminal dimensions; clarify pane directory and terminal-tab labels across Desktop and Web.
- Roll Ghostline runtime upgrades by release tag and require a stable code-signing identity for distributable macOS builds.

### Fixed

- Harden Public Access Relay enrollment and route lifecycle compatibility, avoid persisting bootstrap secrets, and append the Web authentication fragment only for an explicit browser open.
- Recover Public Access setup defaults, Web-panel navigation, and endpoint links without blank clients or stale setup state.
- Preserve Warren terminal colors across appearance changes and restore the Codex composer background.
- Harden compact chrome spacing, Web input fallback, session labels, and notice controls across reconnect, mobile, and narrow desktop states.

## [0.7.0] - 2026-08-20

> Important release: the Web workspace now includes a complete Git panel,
> while deterministic agent turn waits and configurable multi-agent presets
> make automation and launch workflows easier to control. The Push flow stages
> and commits every workspace change before pushing; review the change list and
> commit message before confirming it.

### Added

- Add a Git panel with status, line counts, branch checkout, upstream sync, branch history, pull request details, and pull request creation.
- Add virtualized, syntax-highlighted Diff and File views with unified and split layouts, per-workspace UI restoration, and shareable URL state.
- Add blocking agent turn waits with `agent wait` and `session send --wait`, bounded timeouts, and structured turn results.
- Add configurable multi-agent presets with Trae Agent support, visibility controls, ordering, and per-agent launch commands across macOS and Web.

### Changed

- Cache and revalidate Git panel projections in the background while keeping manual refresh available.
- Bound Git command output, file content, diffs, and unique-branch history; oversized file views return a visible 16 MiB prefix with an explicit truncation notice.

### Fixed

- Reject flag-like commit references, keep symlink reads inside the workspace boundary, serialize Git mutations per workspace, and restore the index when a commit hook fails.
- Recover Git loading and action states after connection loss, restore the first saved Git view, and keep the panel usable at compact desktop widths.
- Keep pull request actions from wrapping and reduce desktop external-IDE icon and label sizing.

## [0.6.3] - 2026-08-20

> Patch release: make manual update checks bypass stale local release responses.

### Fixed

- Force manual update checks to bypass the local URLSession cache so newly published releases appear immediately.

## [0.6.2] - 2026-08-20

> Maintenance release: make search and workspace activity clearer while
> keeping terminal resizing and reconnects smooth.

### Added

- Search projects, workspaces, terminal groups, sessions, and tabs from the command palette.
- Show concurrent workspace activity in the desktop sidebar.

### Changed

- Coalesce terminal resize requests and defer AppKit/Ghostty metric synchronization so window and pane resizing settles cleanly.
- Keep transient daemon restart gaps out of the Inspector while reconnecting, and cancel stale remote requests safely.

### Fixed

- Keep healthy WebSocket clients connected during brief resize contention, reanchoring only after the bounded wait expires.
- Focus terminal search and command palette fields reliably after presentation so the terminal does not steal input.

## [0.6.1] - 2026-08-20

> Maintenance release: make terminal launchers easier to use and keep
> workspace deletion isolated from active session operations.

### Added

- Add the `warren://terminal` deep link for opening a terminal group from
  external launchers.
- Bundle a Raycast Script Command and Warren icon with the release app.

### Fixed

- Keep workspace deletion cleanup isolated from roster publication and active
  session lifecycle so deletion cannot block unrelated session operations.
- Focus the command palette input when it opens so keyboard-first use remains
  reliable.

## [0.6.0] - 2026-08-20

> Important release: this version hardens session operations and prevents stale
> or ambiguous context from changing the wrong terminal. Review the new
> confirmation, dry-run, and undo behavior before using session moves in
> automation.

### Added

- Add `session current`, safe `session move --current`, explicit move confirmation, dry-run preflight output, and compare-and-swap context guards.
- Mark the current Warren Session and distinguish its ID from agent/thread and transcript IDs in CLI output; record reversible move operation IDs with a fail-closed `session undo` path.

### Changed

- Publish project and workspace removals before slow runtime and filesystem cleanup so active session operations remain responsive.
- Bound destructive mutations independently from the initiating WebSocket, allowing cleanup to finish safely after a client disconnects.

### Fixed

- Prevent workspace deletion from blocking session creation, closing, or other session operations.
- Suppress stale terminal focus reports during tab transitions.

## [0.5.2] - 2026-08-20

### Added

- Load the onboarding changelog from the repository at runtime and keep the last successful response available for offline use.
- Add parser coverage for wrapped Markdown release notes and links.
- Proxy release metadata through a Cloudflare Worker with cached GitHub API/page fallbacks and a documented updater endpoint.

### Changed

- Serve cached changelog entries while refreshing stale data so the public release history remains available during transient repository failures.
- Route the desktop updater through the release service and show update status in optimized builds without the development BUILD marker.

## [0.5.1] - 2026-08-20

### Added

- Document the cold-start milestones, ownership boundaries, deferral rules, and measurement checklist for future startup changes.

### Changed

- Defer optional CLI installation, tunnel status refresh, and agent hook installation so the first usable workspace is not blocked by setup work.
- Let the authenticated WebSocket own local daemon readiness instead of issuing a duplicate state probe during launch.

## [0.5.0] - 2026-08-20

### Added

- Check GitHub Releases for updates every three hours in the background and offer one-click download and installation from the in-app update banner or Warren menu.
- Show project and workspace deletion progress directly in the desktop sidebar, disabling affected controls until the daemon confirms removal.

### Changed

- Preserve legacy Warren-managed worktree ownership during startup migration while leaving external checkouts user-owned.
- Keep desktop workspace actions in an explicit, stable order.

### Fixed

- Reconcile pending project and workspace deletions across roster refreshes and reconnects without leaving stale loading indicators.
- Flush the AppKit layout before creating a terminal surface so the initial shell cursor and viewport use the final pane geometry.

## [0.4.0] - 2026-08-19

### Added

- Add project-scoped controls for importing existing Git worktrees, including one-time selection and automatic import from Desktop, Web, and CLI.
- Show merged worktrees in the macOS sidebar and keep their terminal groups accessible.
- Configure empty-workspace defaults for opening a shell and starting an AI session.

### Changed

- Keep imported worktrees protected from destructive workspace operations.
- Present the terminal-group editor from the desktop window for predictable modal behavior.

### Fixed

- Make workspace removal resilient when Git worktree cleanup fails.
- Correct tmux session listing when separators appear in session names.
- Preserve workspace initializer argument order during worktree-backed workspace creation.

## [0.3.1] - 2026-08-19

### Fixed

- Fix first launch reporting "The local daemon is not running" (code 7) on a clean
  machine: the client now re-reads `~/.warren/token` on every connect attempt, so it
  picks up the token the daemon writes during first-run startup.

## [0.3.0] - 2026-08-19

### Added

- Import project git worktrees into workspaces, gated behind a new worktree setting.
- Start a default AI session for new workspaces on macOS and the web.
- Configure the order of session presets.
- Open worktrees in external IDEs from the workspace menu, with installed IDE detection and custom IDE entries.
- Drag projects to reorder the sidebar directly on the web.
- Add an onboarding changelog page.

### Fixed

- Make the worktree import setting toggleable in settings.
- Avoid restoring sessions during web restoration.
- Reject invalid git worktree records.

## [0.2.0] - 2026-08-19

### Added

- Move sessions between terminal groups and workspaces with tab-scoped targets.
- Read agent transcripts in the headless service and surface agent chat updates on the web.
- Remember scoped navigation positions and merge them into workspace state.
- Track worktree branches merged into the default branch.
- Add merge projection state and session locking in the headless service.

### Changed

- Improve session title precedence and merged-workspace reconciliation.
- Remove activity drag-to-dismiss in favor of the context-menu flow.
- Bound session attach preparation and harden terminal surface/output lifecycle handling.

### Fixed

- Prevent fullscreen teardown deadlocks and merge projection refresh saturation.
- Preserve terminal search keyboard handling.
- Harden agent transcript parsing and stream handling.
- Scope relay web assets under the host route when Vite emits relative URLs.
