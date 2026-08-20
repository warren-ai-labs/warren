# Changelog

All notable changes to Warren are documented here.

## [Unreleased]

- Add release notes here before the next version is published.

## [0.7.0] - 2026-08-20

> Important release: the Web workspace now includes a complete Git panel.
> The Push flow stages and commits every workspace change before pushing;
> review the change list and commit message before confirming it.

### Added

- Add a Git panel with status, line counts, branch checkout, upstream sync, branch history, pull request details, and pull request creation.
- Add virtualized, syntax-highlighted Diff and File views with unified and split layouts, per-workspace UI restoration, and shareable URL state.

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
