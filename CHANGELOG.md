# Changelog

All notable changes to Warren are documented here.

## [Unreleased]

- Add release notes here before the next version is published.

## [0.11.1] - 2026-08-29

> Patch release: hardens endpoint switching, preserves Public Access state, fixes web-link auth and mobile scrolling, and improves Linux terminfo handling. Targets arm64 Apple Silicon on macOS 13+; bundled gnar remains v1.7.2. A local Apple Development build may fail Gatekeeper until replaced by a notarized Developer ID build.

### Added

- Add endpoint hang diagnostics with a main-thread watchdog, detailed endpoint and surface lifecycle logging, and a freeze-capture helper for weblink and host switching stalls.

### Changed

- Preserve Codex shimmer while lifting black text for clearer Working visibility.
- Build and verify Linux headless artifacts in CI.

### Fixed

- Persist Public Access authenticated state across daemon restarts by checking the persisted gnar credential store so a valid `~/.warren/gnar/credentials.json` keeps Start instead of Configure.
- Preserve the auth fragment when copying web links so pasted links can authenticate the protected WebSocket.
- Keep warm promotion for remote endpoints and rebuild the connection when endpoint locality changes so local and remote terminal presentation remain correct.
- Allow initial input for dedicated codex, claude, and opencode sessions before the agent transcript is bound so the first prompt is delivered without requiring a Terminal setup retry.
- Install `xterm-ghostty` terminfo on Linux by supporting both `x` and `78` tic output directories.
- Restore vertical swipe scrolling for the agent view on mobile by fixing flex sizing and touch-action hints.

## [0.11.0] - 2026-08-28

> Minor release: refreshes terminal rendering and session handoff, hardens workspace creation, and bundles truecolor terminfo for Ghostline. Targets arm64 Apple Silicon on macOS 13+; bundled gnar remains v1.7.2. A local Apple Development build may fail Gatekeeper until replaced by a notarized Developer ID build.

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

> Major release: Warren upgrades to a new incompatible Ghostline runtime semantics. Existing sessions are migrated automatically via the verified handoff path. This is a super-major compatibility break from 0.9.x; downgrading without recreating sessions is not supported. This release targets arm64 Apple Silicon Macs running macOS 13 or later; a local Apple Development build may fail Gatekeeper until it is replaced by a notarized Developer ID build. Bundled gnar remains v1.7.2.

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

> Patch release: Warren now embeds gnar v1.7.2 and keeps the onboarding
> experience at the top of the page until the terminal demo is explicitly
> requested.

### Changed

- Update the bundled gnar worker to v1.7.2 so Public Access ships the matching worker release.

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

> Major release: Warren can share a Host through a self-hosted gnar Edge,
> while agent workflows, resource links, and clearer desktop notices make
> macOS, Web, and CLI easier to control. Public Access enrollment keys stay in
> memory and go directly to gnar; review the setup-link and key flow before
> sharing one.

### Added

- Add Public Access through a self-hosted gnar Edge, with Settings-based Save & Test, Invite Key and Approval Key enrollment, start/stop/restart lifecycle controls, restart recovery, and credential-free endpoint reporting.
- Add agent-first CLI commands for creating, listing, reading, sending, waiting for, attaching to, and targeting Codex and Claude Agents; keep normalized transcripts separate from raw PTY sessions and support bounded turn waits.
- Add provider-neutral Agent activity and human-attention status across the Host, Web, Desktop, and CLI, including explicit input, approval, warning, stalled, failed, ready, and exited states with Workspace and Terminal Group aggregation.
- Add scoped resource links for Project, Workspace, and Session targets through `warren://terminal` and Web hash state, plus `warren://settings` links that can prefill Public Access setup.
- Add a bounded desktop notice center for system messages, diagnostics, and update failures, with unread and mute controls, and add a compact Workspace More menu for secondary actions.
- Add shared Unix text-editing shortcuts to Web and native AppKit text fields without intercepting terminal input.

### Changed

- Bundle a release-selected gnar worker with an isolated `~/.warren/gnar` credential store, inject a public release default Edge at build time, and keep explicit or system gnar paths available.
- Make Agent and roster projections explicit and bounded, promote Agent commands to the primary CLI interface, and keep terminal, Agent, and transcript operations semantically separate.
- Replace the diagnostic sidebar with stable top-chrome notices and responsive overflow actions while preserving terminal dimensions; clarify pane directory and terminal-tab labels across Desktop and Web.
- Roll Ghostline runtime upgrades by release tag and require a stable code-signing identity for distributable macOS builds.

### Fixed

- Harden Public Access enrollment and lifecycle compatibility, route gnar v1.7 Invite and Approval Keys correctly, avoid persisting bootstrap secrets, and append the Web authentication fragment only for an explicit browser open.
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
