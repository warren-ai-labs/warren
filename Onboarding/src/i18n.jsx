import { createContext, useContext, useEffect, useMemo, useState } from "react";

const messages = {
  en: {
    "nav.overview": "Overview",
    "nav.terminal": "Terminal",
    "nav.why": "Why",
    "nav.changelog": "Changelog",
    "nav.source": "Source",
    "hero.kicker": "Local-first AI workflow workspace",
    "hero.titleA": "Your AI workflow,",
    "hero.titleB": "kept alive.",
    "hero.lede":
      "Run an agent-driven workflow on your Mac or VPS. Close Warren, lose Wi-Fi, or switch clients; the host keeps the workflow ready to resume from the desktop, web, or CLI.",
    "hero.ctaTerminal": "Try the terminal",
    "hero.ctaDocs": "Read the source",
    "hero.ctaDownload": "Download",
    "hero.downloading": "Getting latest…",
    "hero.downloadReady": "Downloading…",
    "hero.downloadFallback": "Open releases",
    "hero.status": "Open source · phase one",
    "hero.platform": "macOS · Web · CLI",
    "ticker.items": ["Run", "Detach", "Reconnect", "Resume", "Workspaces", "Agent views"],
    "product.kicker": "Across every screen",
    "product.title": "One workspace, every screen.",
    "product.lede":
      "Start on the desktop, pick up in a browser, or check in from your phone. The same host keeps every workflow ready.",
    "product.devices": [
      {
        label: "macOS desktop",
        alt: "Warren macOS desktop with projects, terminal tabs, and an agent view",
        caption: "The complete workspace for focused work.",
      },
      {
        label: "Web · agent view",
        alt: "Warren web client showing an agent conversation",
        caption: "Pick up the same workflow from a browser.",
      },
      {
        label: "Web · terminal",
        alt: "Warren web client showing a terminal session",
        caption: "Keep terminal access when you leave the desktop.",
      },
      {
        label: "Mobile · agent view",
        alt: "Warren mobile client showing an agent conversation",
        caption: "Check progress and respond from your phone.",
      },
      {
        label: "Mobile · terminal",
        alt: "Warren mobile client showing a terminal session",
        caption: "Reconnect to the host wherever you are.",
      },
    ],
    "terminal.kicker": "Interactive demo",
    "terminal.title": "The desktop's terminal engine, try it here",
    "terminal.lede":
      "This demo runs Ghostty's VT parser, compiled to WASM — the same engine that powers the desktop app. It talks to a fake host, but the terminal behavior is real. Type help, then try sessions or detach.",
    "terminal.badge": "ghostty-wasm",
    "terminal.hint": "Click inside and type help",
    "terminal.engineNote": "Demo engine: Ghostty WASM · Warren Web client: xterm.js",
    "features.kicker": "Why Warren",
    "features.title": "Sessions belong to the host.",
    "features.lede": "That is how a workflow survives the client.",
    "features.items": [
      {
        title: "Durable sessions",
        body: "Quit the app, switch networks, close the laptop. Your session stays on the host and is still there when you come back.",
      },
      {
        title: "One resource model",
        body: "Projects, workspaces, sessions and runtimes are the same objects on desktop, web and CLI. No parallel universes.",
      },
      {
        title: "Local and remote",
        body: "SSH just gets you to the host. After that, all clients speak the same WebSocket protocol to the same daemon.",
      },
      {
        title: "Real terminal fidelity",
        body: "The desktop uses Ghostty, the web uses xterm.js. ANSI, OSC, Unicode and TUI colors keep working.",
      },
      {
        title: "Agent views",
        body: "Codex and Claude transcripts become readable conversations, while the raw terminal remains one tab away for full control.",
      },
      {
        title: "Workspace-first Git",
        body: "Projects, main checkouts, and worktrees stay attached to the same context as your sessions and agents.",
      },
    ],
    "architecture.kicker": "How it fits together",
    "architecture.title": "One host, every surface",
    "architecture.lede":
      "Desktop, web and CLI all talk to the same warren-headless daemon over one WebSocket protocol. The host owns sessions and runtimes.",
    "architecture.clients": "Clients",
    "architecture.host": "Host",
    "architecture.runtime": "Runtime",
    "architecture.clientLine": "macOS app · Web/PWA · CLI",
    "architecture.hostLine": "warren-headless",
    "architecture.runtimeLine": "Ghostline",
    "architecture.note": "SSH, Tailscale and Cloudflare Tunnel only get you there. They are not the product model.",
    "principle.quote":
      "Closing a tab is the only way to end a session. Quitting, switching workspaces, losing Wi-Fi — that's just walking away.",
    "principle.cite": "Warren product design, §5",
    "footer.line": "Sessions belong to the host.",
    "footer.servedBy": "Served by a Cloudflare Worker",
    "footer.source": "Source",
    "footer.license": "Apache-2.0",
    "footer.domain": "warrenai.xyz",
    "changelog.kicker": "Release notes",
    "changelog.title": "A living record.",
    "changelog.lede":
      "Warren is built in public. Here is what changed, what shipped, and where the work is heading.",
    "changelog.viewRelease": "View release",
    "changelog.releaseTitle": "Warren release",
    "changelog.stale": "Showing the last cached changelog; the repository could not be reached.",
    "changelog.error": "The changelog is temporarily unavailable. View the repository instead.",
    // Offline fallback; live entries come from the repository changelog API.
    "changelog.entries": [
      {
        version: "0.11.1",
        dateISO: "2026-08-29",
        date: "August 29, 2026",
        title: "Warren hardens endpoint switching and Public Access state.",
        summary:
          "A patch release that hardens endpoint switching, preserves Public Access state across restarts, fixes web-link auth and mobile scrolling, and improves Linux terminfo handling. Targets arm64 Apple Silicon on macOS 13+; bundled gnar remains v1.7.2.",
        sections: [
          {
            title: "Added",
            items: [
              "Add endpoint hang diagnostics with a main-thread watchdog, detailed switching logs, and a freeze-capture helper for weblink and host switching stalls.",
            ],
          },
          {
            title: "Changed",
            items: [
              "Preserve Codex shimmer while lifting black text for clearer Working visibility.",
              "Build and verify Linux headless artifacts in CI.",
            ],
          },
          {
            title: "Fixed",
            items: [
              "Persist Public Access authenticated state across daemon restarts by checking the persisted gnar credential store.",
              "Preserve the auth fragment when copying web links so pasted links can authenticate the protected WebSocket.",
              "Keep warm promotion for remote endpoints and rebuild the connection when endpoint locality changes.",
              "Allow initial input for dedicated codex, claude, and opencode sessions before the agent transcript is bound.",
              "Install xterm-ghostty terminfo on Linux by supporting both x and 78 tic output directories.",
              "Restore vertical swipe scrolling for the agent view on mobile by fixing flex sizing and touch-action hints.",
            ],
          },
        ],
      },
      {
        version: "0.11.0",
        dateISO: "2026-08-28",
        date: "August 28, 2026",
        title: "Warren refreshes terminal rendering and workspace creation.",
        summary:
          "A minor release that bundles xterm-ghostty truecolor terminfo, tightens terminal rendering around warm promotion and resize, and hardens Ghostline handoff and workspace creation. Targets arm64 Apple Silicon on macOS 13+; bundled gnar remains v1.7.2.",
        sections: [
          {
            title: "Added",
            items: [
              "Add Refresh Runtime to the daemon menubar for manual runtime refresh with failure feedback and automatic version polling.",
              "Bundle xterm-ghostty terminfo with Tc (truecolor) so Ghostline sessions inherit correct truecolor without requiring Ghostty; auto-installs to ~/.terminfo when missing.",
            ],
          },
          {
            title: "Changed",
            items: [
              "Make warm promotion jump to the latest frame without visible replay; background subscriptions keep the grid current while hidden and scrollback remains intact.",
              "Debounce resize handling so actively outputting shells settle at the new width before reveal and avoid missing color blocks.",
              "Tune terminal palette for codex Working visibility: restore bold-bright palette, set minimum-contrast to 1.8, and draw at synchronized-output boundaries.",
            ],
          },
          {
            title: "Fixed",
            items: [
              "Make workspace creation visible and reliable: auto-expand the owning project while collapsed, keep the dialog open on failure with inline error, and surface Not connected and daemon errors.",
              "Harden Ghostline handoff by restricting version checks to canonical semver tags, exposing WarrenVersion in State, and guarding synchronized-output tracking across Data boundaries with stall recovery.",
              "Isolate OpenCode SQLite tailer memory failures by avoiding GROUP BY on large payloads and containing SQLITE_NOMEM panics at the tailer boundary.",
              "Unify shell and direct codex Working blink color so both share the same amber truecolor.",
            ],
          },
        ],
      },
      {
        version: "0.10.1",
        dateISO: "2026-08-28",
        date: "August 28, 2026",
        title: "Warren fixes codex Working blink and OpenCode bind.",
        summary: "A patch release that fixes codex Working blink color/visibility and the OpenCode bind plugin payload format.",
        sections: [
          {
            title: "Fixed",
            items: [
              "Prevent the codex Working blink from appearing black in shell overlays by skipping Ghostty draws when the terminal view is not presentable.",
              "Align direct codex Working color with shell sessions by defaulting COLORTERM to truecolor for ghostline children.",
              "Correct the OpenCode bind plugin to use PluginModule and real newlines for bind/state payloads.",
            ],
          },
        ],
      },
      {
        version: "0.10.0",
        dateISO: "2026-08-28",
        date: "August 28, 2026",
        title: "Warren upgrades Ghostline semantics.",
        summary:
          "A super-major release that upgrades to incompatible Ghostline runtime semantics with automatic session handoff. Downgrading without recreating sessions is not supported. Targets arm64 Apple Silicon on macOS 13+; bundled gnar remains v1.7.2.",
        sections: [
          {
            title: "Added",
            items: ["Add upgraded Ghostline semantic handling for the new runtime contract."],
          },
          {
            title: "Changed",
            items: [
              "Upgrade Ghostline to the new incompatible semantics with automatic session handoff; legacy v1 sessions are transferred without loss when the handoff is verified.",
              "Refresh terminal and session coordination to align with the new Ghostline contract.",
            ],
          },
          {
            title: "Fixed",
            items: ["Harden Ghostline rolling upgrades and recovery around the new semantic boundary."],
          },
        ],
      },
      {
        version: "0.9.1",
        dateISO: "2026-08-25",
        date: "August 25, 2026",
        title: "Warren refreshes Ghostline v1 migration.",
        summary:
          "A patch release that updates Ghostline v1.0.0 to commit 773f4fff and ships corrected binary migration and crash-window handling.",
        sections: [
          {
            title: "Changed",
            items: [
              "Refresh the Ghostline v1.0.0 module content and checksum to commit 773f4fffbc9879a8b724b1873e230dcaa39dd58e.",
            ],
          },
          {
            title: "Fixed",
            items: [
              "Ship Ghostline's updated binary migration and crash-window handling for rolling upgrades from the v0 compatibility bridge.",
            ],
          },
        ],
      },
      {
        version: "0.9.0",
        dateISO: "2026-08-25",
        date: "August 25, 2026",
        title: "Warren moves to Ghostline v1.",
        summary:
          "A major release that adds an embedded workspace editor, improves command palette and terminal responsiveness, and migrates existing sessions through a bundled Ghostline v0 compatibility bridge.",
        sections: [
          {
            title: "Added",
            items: [
              "Add a workspace-scoped embedded editor for local workspaces, with an isolated code-server profile, managed layout, and background language extension setup.",
              "Add build identity diagnostics covering the release version, source revision, and dirty working-tree state.",
            ],
          },
          {
            title: "Changed",
            items: [
              "Migrate the default Ghostline runtime to v1 and bundle a v0.8 compatibility bridge and arm64 library for one-time migration of retained sessions.",
              "Replace command-palette graph scans with a normalized, ranked resource index, native keyboard navigation, IME-safe input handling, contextual match status, and a bounded visible result set.",
              "Improve terminal and session responsiveness by reusing output and roster state, bounding transcript assembly, and making output replay more efficient.",
              "Defer native terminal split panes while the embedded editor and existing terminal surfaces remain the supported workflow.",
            ],
          },
        ],
      },
      {
        version: "0.8.2",
        dateISO: "2026-08-23",
        date: "August 23, 2026",
        title: "Warren ships the latest gnar worker.",
        summary:
          "A maintenance release that embeds gnar v1.7.2 and keeps the onboarding page at the top until the terminal demo is explicitly requested.",
        sections: [
          {
            title: "Changed",
            items: [
              "Update the bundled gnar worker to v1.7.2 so Public Access ships the matching worker release.",
            ],
          },
          {
            title: "Fixed",
            items: [
              "Prevent ghostty-web's initial focus from scrolling onboarding to the WASM terminal; the #demo link remains an explicit opt-in.",
            ],
          },
        ],
      },
      {
        version: "0.8.1",
        dateISO: "2026-08-22",
        date: "August 22, 2026",
        title: "Warren reaches macOS 13+.",
        summary:
          "A compatibility release for arm64 Apple Silicon Macs with Ghostline v0.6.4, safer runtime cleanup, and a bundled Raycast terminal launcher.",
        sections: [
          {
            title: "Added",
            items: [
              "Add macOS 13 deployment support across the desktop app and Swift packages, with compatibility fallbacks for APIs introduced in macOS 14.",
              "Add a bundled Raycast terminal command and Warren icon for launching terminal groups from Raycast.",
            ],
          },
          {
            title: "Changed",
            items: [
              "Update the Ghostline runtime dependency to v0.6.4 and keep rolling upgrades keyed to the expected release tag.",
              "Build and package the release app for arm64 macOS 13+ with the Ghostline-provided libghostty-vt.dylib and stable release signing checks.",
              "Refresh terminal environment defaults before starting Ghostline or tmux child processes.",
            ],
          },
          {
            title: "Fixed",
            items: [
              "Clean up stale Ghostline sockets, pid files, and logs before reconnecting or adopting a runtime.",
              "Preserve desktop state observation and file-dialog behavior on macOS 13 while keeping newer macOS affordances available when supported.",
            ],
          },
        ],
      },
      {
        version: "0.8.0",
        dateISO: "2026-08-22",
        date: "August 22, 2026",
        title: "Warren opens a secure path to every Host.",
        summary:
          "A major release with self-hosted Public Access, agent-first workflows, scoped resource links, and clearer desktop notifications with cross-client navigation.",
        sections: [
          {
            title: "Added",
            items: [
              "Add Public Access through a self-hosted gnar Edge with Save & Test, Invite Key and Approval Key enrollment, lifecycle controls, restart recovery, and credential-free endpoint reporting.",
              "Add agent-first CLI commands for Codex and Claude Agents, normalized transcript reads, bounded turn waits, and explicit targeting.",
              "Add provider-neutral Agent activity and human-attention status across Host, Web, Desktop, and CLI with Workspace and Terminal Group aggregation.",
              "Add scoped warren://terminal and Web links for Project, Workspace, and Session targets, plus warren://settings links for Public Access setup.",
              "Add a bounded desktop notice center with unread and mute controls, a compact Workspace More menu, and shared Unix editing shortcuts for non-terminal inputs.",
            ],
          },
          {
            title: "Changed",
            items: [
              "Bundle release-selected gnar with an isolated credential store, inject a public default Edge at build time, and keep explicit or system gnar paths available.",
              "Keep Agent, roster, terminal, and transcript projections explicit and bounded while preserving terminal dimensions through responsive chrome and notices.",
              "Roll Ghostline upgrades by release tag and require stable code signing for distributable macOS builds.",
            ],
          },
          {
            title: "Fixed",
            items: [
              "Harden Public Access enrollment, gnar v1.7 key routing, lifecycle recovery, secret handling, setup defaults, and explicit browser authentication links.",
              "Preserve Warren terminal colors across appearance changes and restore the Codex composer background.",
              "Harden compact chrome, Web input fallback, session labels, and notice controls across reconnect, mobile, and narrow desktop states.",
            ],
          },
        ],
      },
      {
        version: "0.7.0",
        dateISO: "2026-08-20",
        date: "August 20, 2026",
        title: "Warren brings Git into the workspace.",
        summary:
          "A major workflow release with Git operations, deterministic agent waits, configurable multi-agent presets, and hardened recovery and safety boundaries.",
        sections: [
          {
            title: "Added",
            items: [
              "Add a complete Git panel with status, line counts, branch checkout, upstream sync, history, and pull request workflows.",
              "Add virtualized Diff and File views with syntax highlighting, unified and split layouts, saved UI state, and shareable URLs.",
              "Add blocking agent turn waits with agent wait and session send --wait, bounded timeouts, and structured turn results.",
              "Add configurable multi-agent presets with Trae Agent support, visibility controls, ordering, and per-agent launch commands across macOS and Web.",
            ],
          },
          {
            title: "Changed",
            items: [
              "Cache and revalidate Git data in the background, and show an explicit notice when an exceptional file view reaches the 16 MiB system limit.",
            ],
          },
          {
            title: "Fixed",
            items: [
              "Harden Git references, workspace paths, commit rollback, mutation ordering, reconnect recovery, saved views, and compact desktop layouts.",
            ],
          },
        ],
      },
      {
        version: "0.6.3",
        dateISO: "2026-08-20",
        date: "August 20, 2026",
        title: "Warren finds new releases immediately.",
        summary:
          "A patch release that prevents stale local release responses from hiding newly published updates.",
        sections: [
          {
            title: "Fixed",
            items: [
              "Force manual update checks to bypass the local URLSession cache so newly published releases appear immediately.",
            ],
          },
        ],
      },
      {
        version: "0.6.2",
        dateISO: "2026-08-20",
        date: "August 20, 2026",
        title: "Warren stays smooth while you search and resize.",
        summary:
          "A maintenance release that broadens command-palette search, makes workspace activity clearer, and stabilizes terminal resizing and reconnection.",
        sections: [
          {
            title: "Added",
            items: [
              "Search projects, workspaces, terminal groups, sessions, and tabs from the command palette.",
              "Show concurrent workspace activity in the desktop sidebar.",
            ],
          },
          {
            title: "Changed",
            items: [
              "Coalesce terminal resize requests and defer AppKit/Ghostty metric synchronization so window and pane resizing settles cleanly.",
              "Keep transient daemon restart gaps out of the Inspector while reconnecting, and cancel stale remote requests safely.",
            ],
          },
          {
            title: "Fixed",
            items: [
              "Keep healthy WebSocket clients connected during brief resize contention, reanchoring only after the bounded wait expires.",
              "Focus terminal search and command palette fields reliably after presentation so the terminal does not steal input.",
            ],
          },
        ],
      },
      {
        version: "0.6.1",
        dateISO: "2026-08-20",
        date: "August 20, 2026",
        title: "Warren makes terminal launching easier.",
        summary:
          "A maintenance release with a stable terminal deep link, a bundled Raycast launcher, and safer workspace deletion cleanup.",
        sections: [
          {
            title: "Added",
            items: [
              "Add the warren://terminal deep link for opening a terminal group from external launchers.",
              "Bundle a Raycast Script Command and Warren icon with the release app.",
            ],
          },
          {
            title: "Fixed",
            items: [
              "Keep workspace deletion cleanup isolated from roster publication and active session lifecycle so deletion cannot block unrelated session operations.",
              "Focus the command palette input when it opens so keyboard-first use remains reliable.",
            ],
          },
        ],
      },
      {
        version: "0.6.0",
        dateISO: "2026-08-20",
        date: "August 20, 2026",
        title: "Warren makes session operations safe.",
        summary:
          "Important release: session targeting now fails closed, explains its target, and supports safe recovery when context changes.",
        sections: [
          {
            title: "Added",
            items: [
              "Add session current, safe current-session moves, explicit confirmation, dry-run preflight output, and compare-and-swap context guards.",
              "Mark the current Warren Session separately from agent, thread, and transcript IDs, and record reversible move operation IDs with session undo.",
            ],
          },
          {
            title: "Changed",
            items: [
              "Publish project and workspace removals before slow runtime and filesystem cleanup so active session operations remain responsive.",
              "Bound destructive mutations independently from the initiating WebSocket, allowing cleanup to finish safely after a client disconnects.",
            ],
          },
          {
            title: "Fixed",
            items: [
              "Prevent workspace deletion from blocking session creation, closing, or other session operations.",
              "Suppress stale terminal focus reports during tab transitions.",
            ],
          },
        ],
      },
      {
        version: "0.5.2",
        dateISO: "2026-08-20",
        date: "August 20, 2026",
        title: "Warren keeps release notes in sync.",
        summary:
          "The onboarding changelog now follows the repository while remaining useful when the network is unavailable.",
        sections: [
          {
            title: "Added",
            items: [
              "Load the onboarding changelog from the repository at runtime and keep the last successful response available for offline use.",
              "Add parser coverage for wrapped Markdown release notes and links.",
              "Proxy release metadata through a Cloudflare Worker with cached GitHub API/page fallbacks and a documented updater endpoint.",
            ],
          },
          {
            title: "Changed",
            items: [
              "Serve cached changelog entries while refreshing stale data so the public release history remains available during transient repository failures.",
              "Route the desktop updater through the release service and show update status in optimized builds without the development BUILD marker.",
            ],
          },
        ],
      },
      {
        version: "0.5.1",
        dateISO: "2026-08-20",
        date: "August 20, 2026",
        title: "Warren starts lighter.",
        summary:
          "The first workspace becomes available sooner while optional startup work continues safely in the background.",
        sections: [
          {
            title: "Added",
            items: [
              "Document cold-start milestones, ownership boundaries, deferral rules, and the measurement checklist for future startup changes.",
            ],
          },
          {
            title: "Changed",
            items: [
              "Defer optional CLI installation, tunnel status refresh, and agent hook installation so the first usable workspace is not blocked by setup work.",
              "Let the authenticated WebSocket own local daemon readiness instead of issuing a duplicate state probe during launch.",
            ],
          },
        ],
      },
      {
        version: "0.5.0",
        dateISO: "2026-08-20",
        date: "August 20, 2026",
        title: "Warren can update itself.",
        summary:
          "Warren makes new releases easier to adopt while keeping deletion flows and terminal layout predictable.",
        sections: [
          {
            title: "Added",
            items: [
              "Check GitHub Releases every three hours and offer one-click download and installation from the in-app update banner or Warren menu.",
              "Show project and workspace deletion progress directly in the desktop sidebar.",
            ],
          },
          {
            title: "Changed",
            items: [
              "Preserve legacy Warren-managed worktree ownership during startup migration while leaving external checkouts user-owned.",
              "Keep desktop workspace actions in an explicit, stable order.",
            ],
          },
          {
            title: "Fixed",
            items: [
              "Reconcile pending project and workspace deletions across roster refreshes and reconnects without leaving stale loading indicators.",
              "Flush the AppKit layout before creating a terminal surface so the initial shell cursor and viewport use the final pane geometry.",
            ],
          },
        ],
      },
      {
        version: "0.4.0",
        dateISO: "2026-08-19",
        date: "August 19, 2026",
        title: "Worktrees fit the workflow.",
        summary:
          "Projects, worktrees, and empty workspaces become easier to configure across Warren's clients.",
        sections: [
          {
            title: "Added",
            items: [
              "Add project-scoped controls for importing existing Git worktrees, including one-time selection and automatic import from Desktop, Web, and CLI.",
              "Show merged worktrees in the macOS sidebar and keep their terminal groups accessible.",
              "Configure empty-workspace defaults for opening a shell and starting an AI session.",
            ],
          },
          {
            title: "Changed",
            items: [
              "Keep imported worktrees protected from destructive workspace operations.",
              "Present the terminal-group editor from the desktop window for predictable modal behavior.",
            ],
          },
          {
            title: "Fixed",
            items: [
              "Make workspace removal resilient when Git worktree cleanup fails.",
              "Correct tmux session listing when separators appear in session names.",
              "Preserve workspace initializer argument order during worktree-backed workspace creation.",
            ],
          },
        ],
      },
      {
        version: "0.3.1",
        dateISO: "2026-08-19",
        date: "August 19, 2026",
        title: "First launch connects cleanly.",
        summary: "The local daemon now becomes available reliably on a clean first launch.",
        sections: [
          {
            title: "Fixed",
            items: [
              "Re-read the local daemon token on every connection attempt so first-run startup can connect after the daemon writes it.",
            ],
          },
        ],
      },
      {
        version: "0.3.0",
        dateISO: "2026-08-19",
        date: "August 19, 2026",
        title: "Worktrees become first-class.",
        summary:
          "Warren adds worktree-aware projects, smarter session defaults, and a more capable workspace sidebar.",
        sections: [
          {
            title: "Added",
            items: [
              "Import project Git worktrees behind a configurable project setting.",
              "Start a default AI session for new workspaces on macOS and the web.",
              "Configure the order of session presets.",
              "Open worktrees in external IDEs with installed IDE detection and custom IDE entries.",
              "Drag projects to reorder the sidebar directly on the web.",
              "Add an onboarding changelog page.",
            ],
          },
          {
            title: "Fixed",
            items: [
              "Make the worktree import setting toggleable in settings.",
              "Avoid restoring sessions during web restoration.",
              "Reject invalid Git worktree records.",
            ],
          },
        ],
      },
      {
        version: "0.2.0",
        dateISO: "2026-08-19",
        date: "August 19, 2026",
        title: "Sessions move with you.",
        summary:
          "A release focused on session control, agent context, and a calmer way to move through workspaces.",
        sections: [
          {
            title: "Added",
            items: [
              "Move sessions between terminal groups and workspaces with tab-scoped targets.",
              "Read agent transcripts in the headless service and surface agent chat updates on the web.",
              "Remember scoped navigation positions and merge them into workspace state.",
              "Track worktree branches merged into the default branch.",
              "Add merge projection state and session locking in the headless service.",
            ],
          },
          {
            title: "Changed",
            items: [
              "Improve session title precedence and merged-workspace reconciliation.",
              "Remove activity drag-to-dismiss in favor of the context-menu flow.",
              "Bound session attach preparation and harden terminal surface/output lifecycle handling.",
            ],
          },
          {
            title: "Fixed",
            items: [
              "Prevent fullscreen teardown deadlocks and merge projection refresh saturation.",
              "Preserve terminal search keyboard handling.",
              "Harden agent transcript parsing and stream handling.",
              "Scope relay web assets under the host route when Vite emits relative URLs.",
            ],
          },
        ],
      },
      {
        version: "0.1.1",
        dateISO: "2026-08-18",
        date: "August 18, 2026",
        title: "A smoother first launch.",
        summary:
          "Warren became easier to install and easier to discover, with a bundled CLI and a public onboarding site.",
        sections: [
          {
            title: "Added",
            items: [
              "Install the bundled Warren CLI on first launch and expose it in the shell path.",
              "Publish the Warren onboarding site with an interactive terminal demo and direct downloads.",
            ],
          },
          {
            title: "Changed",
            items: ["Keep the Chinese locale hidden until its typeface rendering is ready."],
          },
        ],
      },
      {
        version: "0.1.0",
        dateISO: "2026-08-18",
        date: "August 18, 2026",
        title: "The first public release.",
        summary:
          "Warren launched as a local-first development workbench for durable terminal sessions.",
        sections: [
          {
            title: "Included",
            items: [
              "A native macOS desktop app with a menu bar daemon.",
              "A bundled warren-headless daemon and Warren CLI.",
              "A responsive Web/PWA client served by the daemon.",
              "Durable terminal sessions that survive disconnects, app quits, and network changes.",
            ],
          },
        ],
      },
    ],
  },
  zh: {
    "nav.overview": "概览",
    "nav.terminal": "终端",
    "nav.why": "为什么",
    "nav.changelog": "更新日志",
    "nav.source": "源码",
    "hero.kicker": "本地优先的开发工作台",
    "hero.titleA": "你的终端，",
    "hero.titleB": "一直在。",
    "hero.lede":
      "Warren 是一个本地优先的开发工作台，给那些住在终端里的人。会话跑在 Host 上——你的 Mac 或一台 VPS——退出应用、网络断开、合上电脑，它都还在。",
    "hero.ctaTerminal": "试试终端",
    "hero.ctaDocs": "查看源码",
    "hero.ctaDownload": "下载",
    "hero.downloading": "获取最新版…",
    "hero.downloadReady": "开始下载…",
    "hero.downloadFallback": "打开 Releases",
    "hero.status": "Phase one · 开源",
    "hero.platform": "macOS · Web · CLI",
    "ticker.items": ["断开", "重连", "恢复", "工作区", "会话", "Agent 视图"],
    "product.kicker": "每一块屏幕",
    "product.title": "一个 Workspace，随时随地接着做。",
    "product.lede":
      "从桌面端开始，在浏览器里接着做，也能用手机查看进度。所有客户端共享同一个 Host。",
    "product.devices": [
      {
        label: "macOS 桌面端",
        alt: "Warren macOS 桌面端：项目、终端 Tab 和 Agent 视图",
        caption: "完整的工作区，适合专注工作。",
      },
      {
        label: "Web · Agent 视图",
        alt: "Warren Web 客户端中的 Agent 对话",
        caption: "打开浏览器，接着同一个工作流。",
      },
      {
        label: "Web · 终端",
        alt: "Warren Web 客户端中的终端会话",
        caption: "离开桌面端，也能继续使用终端。",
      },
      {
        label: "移动端 · Agent 视图",
        alt: "Warren 移动端中的 Agent 对话",
        caption: "用手机查看进度、继续回复。",
      },
      {
        label: "移动端 · 终端",
        alt: "Warren 移动端中的终端会话",
        caption: "无论在哪里，都能重新连回 Host。",
      },
    ],
    "terminal.kicker": "可交互演示",
    "terminal.title": "桌面端同一个终端引擎，这里就能试",
    "terminal.lede":
      "这个演示用的就是 Ghostty 的 VT 解析器，编译成 WASM——和桌面端同一个引擎。它连的是一个假 Host，但终端行为是真的。输入 help，然后试试 sessions 或 detach。",
    "terminal.badge": "ghostty-wasm",
    "terminal.hint": "点击终端，输入 help",
    "terminal.engineNote": "演示引擎：Ghostty WASM · Warren Web 客户端：xterm.js",
    "features.kicker": "为什么是 Warren",
    "features.title": "会话属于 Host。",
    "features.lede": "Warren 里的一切都围绕这句话展开。",
    "features.items": [
      {
        title: "持久会话",
        body: "退出应用、切换网络、合上电脑。会话留在 Host 上，你回来时它还在。",
      },
      {
        title: "统一的资源模型",
        body: "Project、Workspace、Session、Runtime 在桌面端、Web 和 CLI 上是同一套对象，没有平行宇宙。",
      },
      {
        title: "本地与远程",
        body: "SSH 只负责把你带到 Host。之后所有客户端都通过同一条 WebSocket 协议连同一个 daemon。",
      },
      {
        title: "真正的终端保真",
        body: "桌面端用 Ghostty，Web 用 xterm.js。ANSI、OSC、Unicode、TUI 颜色都照常工作。",
      },
      {
        title: "Agent 会话视图",
        body: "Codex 和 Claude 的转写会变成可读的对话，原始终端也还在旁边。",
      },
      {
        title: "以 Workspace 为先的 Git",
        body: "Project、主检出、worktree 都是真实资源。已有的 Superset 项目导一次就行。",
      },
    ],
    "architecture.kicker": "它如何拼起来",
    "architecture.title": "一个 Host，所有入口",
    "architecture.lede":
      "桌面端、Web 和 CLI 都通过同一条 WebSocket 协议连接同一个 warren-headless daemon。会话和运行时归 Host 所有。",
    "architecture.clients": "客户端",
    "architecture.host": "Host",
    "architecture.runtime": "运行时",
    "architecture.clientLine": "macOS 应用 · Web/PWA · CLI",
    "architecture.hostLine": "warren-headless",
    "architecture.runtimeLine": "Ghostline",
    "architecture.note": "SSH、Tailscale 和 Cloudflare Tunnel 只负责把你带到那里，不属于产品模型。",
    "principle.quote":
      "关闭 Tab 是结束会话的唯一方式。退出、切换工作区、Wi-Fi 断了——那只是离开而已。",
    "principle.cite": "Warren 产品设计，§5",
    "footer.line": "会话属于 Host。",
    "footer.servedBy": "由 Cloudflare Worker 托管",
    "footer.source": "源码",
    "footer.domain": "warrenai.xyz",
    "changelog.kicker": "更新日志",
    "changelog.title": "每一次变化，都有记录。",
    "changelog.lede":
      "Warren 在公开构建。这里记录每次改变、每个版本，以及接下来要去的地方。",
    "changelog.viewRelease": "查看 Release",
    "changelog.releaseTitle": "Warren 版本",
    "changelog.stale": "仓库暂时无法访问，当前显示的是上次缓存的更新日志。",
    "changelog.error": "更新日志暂时不可用，可以先查看仓库。",
    // Offline fallback; live entries come from the repository changelog API.
    "changelog.entries": [
      {
        version: "0.11.1",
        dateISO: "2026-08-29",
        date: "2026 年 8 月 29 日",
        title: "Warren 加固端点切换与 Public Access 状态。",
        summary:
          "修复版本：加固端点切换、重启后保持 Public Access 已认证状态、修复网页链接鉴权与移动端滚动，并在 Linux 上改进 terminfo 安装。面向 arm64 macOS 13+，内置 gnar 仍为 v1.7.2。",
        sections: [
          {
            title: "新增",
            items: [
              "为端点与 weblink 切换新增挂起诊断：主线程 watchdog、详细切换日志与 freeze 捕获脚本。",
            ],
          },
          {
            title: "调整",
            items: [
              "在提升黑字可见性的同时保留 Codex shimmer 效果。",
              "在 CI 中构建并校验 Linux headless 产物。",
            ],
          },
          {
            title: "修复",
            items: [
              "重启后通过已持久化的 gnar 凭据保持 Public Access 已认证状态。",
              "复制网页链接时保留鉴权 fragment，使粘贴链接可认证受保护的 WebSocket。",
              "为远端端点保留 warm promotion，并在端点本地/远端变化时重建连接。",
              "在 agent transcript 绑定前允许 codex/claude/opencode 专属会话的初始输入。",
              "在 Linux 上同时支持 x 与 78 目录以正确安装 xterm-ghostty terminfo。",
              "修复移动端 agent 视图的纵向滑动，修正 flex 与 touch-action。",
            ],
          },
        ],
      },
      {
        version: "0.11.0",
        dateISO: "2026-08-28",
        date: "2026 年 8 月 28 日",
        title: "Warren 刷新终端渲染与工作区创建。",
        summary:
          "次版本：内置 xterm-ghostty truecolor，收紧 warm promotion 与 resize 渲染，并加固 Ghostline handoff 与工作区创建。面向 arm64 macOS 13+，内置 gnar 仍为 v1.7.2。",
        sections: [
          {
            title: "新增",
            items: [
              "在 daemon 菜单栏新增 Refresh Runtime，支持手动刷新并在失败时显示原因。",
              "内置带 Tc 的 xterm-ghostty terminfo，使 Ghostline 会话无需安装 Ghostty 即可获得正确 truecolor；缺失时自动安装到 ~/.terminfo。",
            ],
          },
          {
            title: "调整",
            items: [
              "warm promotion 改为一帧跳到最新，无可见回放；后台保持订阅使网格常新，scrollback 保持可回滚。",
              "对 resize 做防抖处理，避免高频输出 shell 在新宽度下出现色块缺失。",
              "校正终端调色：恢复粗体亮色、将最小对比度调至 1.8，并在同步输出边界绘制前景。",
            ],
          },
          {
            title: "修复",
            items: [
              "让工作区创建更可靠：折叠时自动展开所属项目，失败时保持对话框并内联展示错误。",
              "加固 Ghostline 迁移：仅对规范 tag 触发版本 handoff，并在 Data 切片间跟踪同步深度。",
              "隔离 OpenCode 大会话的内存风险，避免在超大 payload 上 GROUP BY 并兜住 SQLITE_NOMEM panic。",
              "统一 shell 与直连 codex Working 闪烁颜色，共享同一 amber truecolor。",
            ],
          },
        ],
      },
      {
        version: "0.10.1",
        dateISO: "2026-08-28",
        date: "2026 年 8 月 28 日",
        title: "Warren 修复 codex 闪烁与 OpenCode 绑定。",
        summary: "修复版本：修复 codex Working 闪烁颜色/可见性与 OpenCode 绑定插件负载格式。",
        sections: [
          {
            title: "修复",
            items: [
              "避免在终端视图不可呈现时绘制 Ghostty 帧，防止 shell overlay 中 codex Working 闪烁变黑。",
              "为 ghostline 子进程默认设置 COLORTERM=truecolor，使直连 codex Working 颜色与 shell 会话一致。",
              "修正 OpenCode 绑定插件使用 PluginModule 并写入真实换行符。",
            ],
          },
        ],
      },
      {
        version: "0.10.0",
        dateISO: "2026-08-28",
        date: "2026 年 8 月 28 日",
        title: "Warren 升级 Ghostline 语义。",
        summary:
          "超级重大版本：升级到不兼容的 Ghostline 运行时语义，自动迁移已有会话；不支持不重建会话的回退。面向 arm64 macOS 13+，内置 gnar 仍为 v1.7.2。",
        sections: [
          {
            title: "新增",
            items: ["新增对新运行时契约的 Ghostline 语义支持。"],
          },
          {
            title: "调整",
            items: [
              "升级到不兼容的新 Ghostline 语义，已验证 handoff 会自动迁移旧会话。",
              "刷新终端与会话协同以对齐新的 Ghostline 契约。",
            ],
          },
          {
            title: "修复",
            items: ["加固新语义边界附近的 Ghostline 滚动升级与恢复。"],
          },
        ],
      },
      {
        version: "0.9.1",
        dateISO: "2026-08-25",
        date: "2026 年 8 月 25 日",
        title: "Warren 刷新 Ghostline v1 迁移实现。",
        summary:
          "修复版本：将 Ghostline v1.0.0 更新到 commit 773f4fff，内置修正后的二进制迁移与崩溃窗口处理。",
        sections: [
          {
            title: "调整",
            items: [
              "将 Ghostline v1.0.0 模块内容和校验值刷新到 commit 773f4fffbc9879a8b724b1873e230dcaa39dd58e。",
            ],
          },
          {
            title: "修复",
            items: [
              "内置 Ghostline 更新后的二进制迁移和崩溃窗口处理，支持从 v0 兼容桥滚动升级。",
            ],
          },
        ],
      },
      {
        version: "0.9.0",
        dateISO: "2026-08-25",
        date: "2026 年 8 月 25 日",
        title: "Warren 迁移到 Ghostline v1。",
        summary:
          "重大版本：新增嵌入式 Workspace 编辑器，提升命令面板与终端响应速度，并通过内置的 Ghostline v0 兼容桥迁移已有会话。",
        sections: [
          {
            title: "新增",
            items: [
              "为本地 Workspace 新增范围明确的嵌入式编辑器，使用隔离的 code-server 配置、托管布局，并在后台安装语言扩展。",
              "新增构建身份诊断，记录发布版本、源码修订和工作树是否有未提交修改。",
            ],
          },
          {
            title: "调整",
            items: [
              "默认 Ghostline 运行时迁移到 v1，并内置 v0.8 兼容桥及 arm64 库，用于保留会话的一次性迁移。",
              "命令面板改用规范化的资源排序索引，支持原生键盘导航、IME 安全输入、上下文匹配状态和有界可见结果。",
              "通过复用输出与 roster 状态、限制 Transcript 组装范围并优化输出回放，提升终端和会话响应速度。",
              "暂缓原生终端分栏；嵌入式编辑器和现有终端界面仍是当前支持的工作流。",
            ],
          },
        ],
      },
      {
        version: "0.8.2",
        dateISO: "2026-08-23",
        date: "2026 年 8 月 23 日",
        title: "Warren 内置最新 gnar Worker。",
        summary:
          "维护版本：内置 gnar v1.7.2，并保持 onboarding 首屏停留在顶部，只有明确请求时才进入终端演示。",
        sections: [
          {
            title: "调整",
            items: [
              "内置 gnar Worker 升级到 v1.7.2，让 Public Access 使用匹配的 Worker 版本。",
            ],
          },
          {
            title: "修复",
            items: [
              "避免 ghostty-web 初始化时的 focus 将 onboarding 自动滚动到 WASM Terminal；只有明确点击 #demo 才会进入演示。",
            ],
          },
        ],
      },
      {
        version: "0.8.1",
        dateISO: "2026-08-22",
        date: "2026 年 8 月 22 日",
        title: "Warren 支持 macOS 13+。",
        summary:
          "兼容性版本：面向 arm64 Apple Silicon Mac，升级 Ghostline v0.6.4，清理运行时残留，并内置 Raycast 终端启动命令。",
        sections: [
          {
            title: "新增",
            items: [
              "桌面端和 Swift 包全面支持 macOS 13，并为 macOS 14 才提供的 API 增加兼容回退。",
              "内置 Raycast 终端命令和 Warren 图标，可从 Raycast 启动 Terminal Group。",
            ],
          },
          {
            title: "调整",
            items: [
              "Ghostline 运行时依赖升级到 v0.6.4，并继续按预期发布 tag 执行滚动升级。",
              "发布版改为使用 Ghostline 提供的 libghostty-vt.dylib 构建 arm64 macOS 13+ 应用，并执行稳定签名校验。",
              "启动 Ghostline 或 tmux 子进程前刷新终端环境默认值。",
            ],
          },
          {
            title: "修复",
            items: [
              "在重新连接或接管运行时前清理残留的 Ghostline socket、pid 文件和日志，避免旧残留阻塞会话启动。",
              "在 macOS 13 上保持桌面状态观察和文件选择器行为，同时在支持时保留更新系统的能力。",
            ],
          },
        ],
      },
      {
        version: "0.8.0",
        dateISO: "2026-08-22",
        date: "2026 年 8 月 22 日",
        title: "Warren 为每个 Host 打开安全的访问路径。",
        summary:
          "重大版本：新增自托管 Public Access、Agent 优先工作流、范围明确的资源链接，以及覆盖 macOS、Web 和 CLI 的通知与导航体验。",
        sections: [
          {
            title: "新增",
            items: [
              "通过自托管 gnar Edge 新增 Public Access，支持在设置中 Save & Test、使用 Invite Key 或 Approval Key 完成注册、控制生命周期、重启恢复，并报告不含凭据的公共 Endpoint。",
              "新增面向 Agent 的 CLI 命令，支持 Codex 和 Claude Agent 的创建、列表、读取、发送、等待、附加和明确定位；支持规范化 Transcript 读取与有界 turn 等待。",
              "新增跨 Host、Web、Desktop 和 CLI 的统一 Agent 活动与人工关注状态，并汇总到 Workspace 和 Terminal Group。",
              "新增范围明确的 warren://terminal 与 Web 链接，可定位 Project、Workspace 和 Session；新增可预填 Public Access 的 warren://settings 链接。",
              "新增有界桌面通知中心、未读与静音控制、紧凑 Workspace More 菜单，以及适用于非终端输入框的 Unix 编辑快捷键。",
            ],
          },
          {
            title: "调整",
            items: [
              "发布版可内置 gnar，并使用隔离的凭据目录；构建时注入公开的默认 Edge，同时保留显式或系统 gnar 路径。",
              "让 Agent、roster、Terminal 和 Transcript 投影保持明确且有界，并在响应式 Chrome 与通知出现时保持终端尺寸稳定。",
              "按发布 tag 滚动升级 Ghostline，并要求可分发的 macOS 构建使用稳定代码签名。",
            ],
          },
          {
            title: "修复",
            items: [
              "强化 Public Access 注册、gnar v1.7 密钥路由、生命周期恢复、密钥处理、设置默认值和显式浏览器认证链接。",
              "修复 Warren 终端在外观变化时的颜色保持问题，并恢复 Codex composer 背景。",
              "强化紧凑 Chrome、Web 输入回退、Session 标签和通知控制在重连、移动端与窄桌面状态下的表现。",
            ],
          },
        ],
      },
      {
        version: "0.7.0",
        dateISO: "2026-08-20",
        date: "2026 年 8 月 20 日",
        title: "Warren 把 Git 带进了 Workspace。",
        summary:
          "工作流重大更新：新增 Git 操作、确定性的 Agent 等待、可配置的多 Agent 预设，并强化恢复能力与安全边界。",
        sections: [
          {
            title: "新增",
            items: [
              "新增完整 Git 面板，支持状态、行数统计、分支切换、上游同步、历史和 Pull Request 工作流。",
              "新增虚拟化 Diff 与文件视图，支持语法高亮、统一与分栏布局、状态保存和 URL 分享。",
              "新增阻塞式 Agent turn 等待，支持 agent wait、session send --wait、有界超时和结构化 turn 结果。",
              "新增可配置的多 Agent 预设，支持 Trae Agent、显示隐藏、排序和逐个 Agent 的启动命令，并同步覆盖 macOS 与 Web。",
            ],
          },
          {
            title: "调整",
            items: [
              "在后台缓存并刷新 Git 数据；极端文件视图达到 16 MiB 系统上限时显示明确提示。",
            ],
          },
          {
            title: "修复",
            items: [
              "强化 Git 引用、Workspace 路径、提交回滚、变更串行、断线恢复、视图恢复和紧凑桌面布局。",
            ],
          },
        ],
      },
      {
        version: "0.6.3",
        dateISO: "2026-08-20",
        date: "2026 年 8 月 20 日",
        title: "Warren 会立即发现新版本了。",
        summary: "修复本地版本缓存导致新发布版本不显示的问题。",
        sections: [
          {
            title: "修复",
            items: [
              "手动检查更新时绕过本地 URLSession 缓存，让刚发布的版本立即显示。",
            ],
          },
        ],
      },
      {
        version: "0.6.2",
        dateISO: "2026-08-20",
        date: "2026 年 8 月 20 日",
        title: "Warren 的搜索和调整大小都更顺畅了。",
        summary:
          "维护版本：扩展 Command Palette 搜索范围，让 Workspace 活动更清晰，并稳定终端调整大小与重连。",
        sections: [
          {
            title: "新增",
            items: [
              "支持从 Command Palette 搜索 Project、Workspace、Terminal Group、Session 和 Tab。",
              "在桌面侧栏显示并发 Workspace 活动。",
            ],
          },
          {
            title: "调整",
            items: [
              "合并终端 resize 请求，并延后 AppKit/Ghostty 指标同步，让窗口和面板调整大小更稳定。",
              "重连期间将守护进程短暂重启间隔从 Inspector 中隐藏，并安全取消过期远程请求。",
            ],
          },
          {
            title: "修复",
            items: [
              "resize 短暂竞争时保持健康 WebSocket 连接，只有等待超时才重新锚定。",
              "Terminal Search 和 Command Palette 弹出后可靠聚焦，避免终端抢走输入。",
            ],
          },
        ],
      },
      {
        version: "0.6.1",
        dateISO: "2026-08-20",
        date: "2026 年 8 月 20 日",
        title: "Warren 更容易启动终端了。",
        summary:
          "维护版本：增加稳定的终端 deep link、内置 Raycast 启动器，并让 Workspace 删除清理更安全。",
        sections: [
          {
            title: "新增",
            items: [
              "增加 warren://terminal deep link，支持从外部启动器打开指定 Terminal Group。",
              "在发布版应用中内置 Raycast Script Command 和 Warren 图标。",
            ],
          },
          {
            title: "修复",
            items: [
              "隔离 Workspace 删除清理与 roster 发布及活跃 Session 生命周期，避免删除操作阻塞无关的 Session 操作。",
              "打开 Command Palette 时自动聚焦输入框，保证键盘操作可靠。",
            ],
          },
        ],
      },
      {
        version: "0.6.0",
        dateISO: "2026-08-20",
        date: "2026 年 8 月 20 日",
        title: "Warren 让 Session 操作更安全。",
        summary:
          "重要版本：Session 定位现在会失败即关闭、明确展示目标，并在上下文变化时支持安全恢复。",
        sections: [
          {
            title: "新增",
            items: [
              "增加 session current、安全的当前 Session 移动、显式确认、dry-run 预检输出和 compare-and-swap 上下文保护。",
              "在 CLI 输出中明确区分 Warren Session、Agent、Thread 和 Transcript ID，并为移动操作记录可撤销的 operation ID，支持 session undo。",
            ],
          },
          {
            title: "调整",
            items: [
              "先发布 Project 和 Workspace 的移除状态，再执行耗时的运行时和文件系统清理，保持活跃 Session 操作响应。",
              "让破坏性变更脱离发起请求的 WebSocket 独立执行，即使客户端断开，清理也能安全完成。",
            ],
          },
          {
            title: "修复",
            items: [
              "修复 Workspace 删除阻塞 Session 创建、关闭和其他操作的问题。",
              "抑制终端 Tab 切换期间的过期 focus 上报。",
            ],
          },
        ],
      },
      {
        version: "0.5.2",
        dateISO: "2026-08-20",
        date: "2026 年 8 月 20 日",
        title: "Warren 的更新日志现在会保持同步。",
        summary: "Onboarding 更新日志现在跟随仓库，同时在网络不可用时仍可使用。",
        sections: [
          {
            title: "新增",
            items: [
              "运行时从仓库加载 Onboarding 更新日志，并保留最近一次成功响应供离线使用。",
              "增加对折行 Markdown 发布说明和链接的解析测试。",
              "通过 Cloudflare Worker 代理版本信息，使用带缓存的 GitHub API/页面降级，并补充更新服务接口文档。",
            ],
          },
          {
            title: "调整",
            items: [
              "刷新过期数据时继续提供缓存的更新日志，让公共版本记录在仓库短暂不可用时仍可访问。",
              "让桌面端更新器通过更新服务获取版本信息，并在优化构建中显示更新状态而不显示开发版 BUILD 标记。",
            ],
          },
        ],
      },
      {
        version: "0.5.1",
        dateISO: "2026-08-20",
        date: "2026 年 8 月 20 日",
        title: "Warren 启动更轻了。",
        summary: "首个 Workspace 更快可用，非关键启动工作会在后台安全完成。",
        sections: [
          {
            title: "新增",
            items: [
              "记录冷启动里程碑、职责边界、延后规则，以及后续启动改动的测量清单。",
            ],
          },
          {
            title: "调整",
            items: [
              "延后可选的 CLI 安装、Tunnel 状态刷新和 Agent Hook 安装，首个可用 Workspace 不再被设置工作阻塞。",
              "让已认证的 WebSocket 自己负责本地 daemon 就绪判断，启动时不再重复发起 state 探测。",
            ],
          },
        ],
      },
      {
        version: "0.5.0",
        dateISO: "2026-08-20",
        date: "2026 年 8 月 20 日",
        title: "Warren 现在会自己更新了。",
        summary: "这一版让新版本更容易获取，也让删除流程和终端布局更稳定。",
        sections: [
          {
            title: "新增",
            items: [
              "每三小时后台检查 GitHub Releases，并可从应用内更新提示或 Warren 菜单一键下载、安装。",
              "在桌面端侧栏直接显示 Project 和 Workspace 的删除进度。",
            ],
          },
          {
            title: "调整",
            items: [
              "启动迁移时保留旧版本 Warren 管理的 worktree 归属，同时把外部 checkout 留给用户管理。",
              "让桌面端 Workspace 操作保持明确、稳定的顺序。",
            ],
          },
          {
            title: "修复",
            items: [
              "在 roster 刷新和重连后协调等待中的 Project、Workspace 删除，避免加载状态残留。",
              "创建终端 surface 前先刷新 AppKit 布局，让首次 shell 光标和 viewport 使用最终 pane 尺寸。",
            ],
          },
        ],
      },
      {
        version: "0.4.0",
        dateISO: "2026-08-19",
        date: "2026 年 8 月 19 日",
        title: "Worktree 真正融入工作流。",
        summary: "Project、worktree 和空 Workspace 在各端都更容易配置。",
        sections: [
          {
            title: "新增",
            items: [
              "增加 Project 级别的已有 Git worktree 导入控制，支持一次性选择，也支持从 Desktop、Web、CLI 自动导入。",
              "在 macOS 侧栏显示已经合并的 worktree，并保留它们的 Terminal Group。",
              "配置空 Workspace 是否自动打开 Shell 和启动 AI Session。",
            ],
          },
          {
            title: "调整",
            items: [
              "保护导入的 worktree，避免 Workspace 操作误删它们。",
              "让 Terminal Group 编辑器从桌面窗口呈现，交互更可预期。",
            ],
          },
          {
            title: "修复",
            items: [
              "Git worktree 清理失败时，Workspace 删除仍能继续。",
              "修复 tmux 在 session 名称包含分隔符时的列表解析。",
              "保留基于 worktree 创建 Workspace 时的 initializer 参数顺序。",
            ],
          },
        ],
      },
      {
        version: "0.3.1",
        dateISO: "2026-08-19",
        date: "2026 年 8 月 19 日",
        title: "第一次启动也能顺利连接。",
        summary: "全新机器第一次启动时，本地 daemon 现在可以可靠连接。",
        sections: [
          {
            title: "修复",
            items: [
              "每次连接都重新读取本地 daemon token，确保 daemon 首次启动写入 token 后可以正常连接。",
            ],
          },
        ],
      },
      {
        version: "0.3.0",
        dateISO: "2026-08-19",
        date: "2026 年 8 月 19 日",
        title: "Worktree 成为一等公民。",
        summary: "Warren 增加 worktree 感知的 Project、更聪明的 Session 默认值和更完整的 Workspace 侧栏。",
        sections: [
          {
            title: "新增",
            items: [
              "支持通过 Project 设置导入 Git worktree。",
              "macOS 和 Web 新建 Workspace 时支持启动默认 AI Session。",
              "支持配置 Session preset 顺序。",
              "支持在外部 IDE 中打开 worktree，并检测已安装 IDE、配置自定义 IDE。",
              "支持在 Web 端直接拖拽调整 Project 侧栏顺序。",
              "增加 Onboarding changelog 页面。",
            ],
          },
          {
            title: "修复",
            items: [
              "让 worktree 导入设置可以在设置页切换。",
              "避免 Web 恢复时恢复 Session。",
              "拒绝无效的 Git worktree 记录。",
            ],
          },
        ],
      },
      {
        version: "0.2.0",
        dateISO: "2026-08-19",
        date: "2026 年 8 月 19 日",
        title: "会话跟着你走。",
        summary: "这一版聚焦会话控制、Agent 上下文，以及更从容的 Workspace 导航。",
        sections: [
          {
            title: "新增",
            items: [
              "支持在 Terminal Group 和 Workspace 之间移动会话，并严格限定 Tab 的目标范围。",
              "Headless 服务支持读取 Agent transcript，Web 端展示 Agent 对话更新。",
              "记住每个作用域的导航位置，并合并进 Workspace 状态。",
              "标记已经合并到默认分支的 worktree 分支。",
              "Headless 服务增加 merge projection 状态和会话锁。",
            ],
          },
          {
            title: "调整",
            items: [
              "优化会话标题优先级和合并 Workspace 的状态协调。",
              "移除拖拽关闭 Activity，改用上下文菜单流程。",
              "限制会话 attach 准备时间，并加固终端 surface/output 生命周期。",
            ],
          },
          {
            title: "修复",
            items: [
              "避免全屏 teardown 死锁和 merge projection 刷新过载。",
              "保留终端搜索快捷键行为。",
              "加固 Agent transcript 解析和流处理。",
              "Vite 使用相对资源路径时，Relay Web 资源仍正确挂在 Host 路由下。",
            ],
          },
        ],
      },
      {
        version: "0.1.1",
        dateISO: "2026-08-18",
        date: "2026 年 8 月 18 日",
        title: "更顺滑的第一次启动。",
        summary: "Warren 变得更容易安装和发现，首启 CLI 和公开 onboarding 站点都已就位。",
        sections: [
          {
            title: "新增",
            items: [
              "首次启动时安装内置 Warren CLI，并将它加入 shell PATH。",
              "发布带交互式终端演示和直接下载入口的 Warren onboarding 站点。",
            ],
          },
          {
            title: "调整",
            items: ["中文 locale 的字体渲染准备好之前，暂时隐藏中文切换。"],
          },
        ],
      },
      {
        version: "0.1.0",
        dateISO: "2026-08-18",
        date: "2026 年 8 月 18 日",
        title: "第一个公开版本。",
        summary: "Warren 作为一个本地优先、提供持久终端会话的开发工作台正式发布。",
        sections: [
          {
            title: "包含",
            items: [
              "原生 macOS 桌面端和菜单栏 daemon。",
              "内置 warren-headless daemon 和 Warren CLI。",
              "由 daemon 提供服务的响应式 Web/PWA 客户端。",
              "断开连接、退出应用和切换网络后仍然存在的持久终端会话。",
            ],
          },
        ],
      },
    ],
  },
};

const I18nContext = createContext(null);

function detectLocale() {
  // Chinese is temporarily hidden until the typeface rendering is improved.
  return "en";
}

export function I18nProvider({ children }) {
  const [locale, setLocaleState] = useState(detectLocale);

  const value = useMemo(() => {
    const setLocale = (next) => {
      setLocaleState(next);
      try {
        localStorage.setItem("warren.locale", next);
      } catch {
        // Private mode; the toggle still works for this session.
      }
      document.documentElement.lang = next === "zh" ? "zh-CN" : "en";
    };
    return {
      locale,
      t: (key) => messages[locale][key] ?? messages.en[key] ?? key,
      setLocale,
    };
  }, [locale]);

  useEffect(() => {
    document.documentElement.lang = locale === "zh" ? "zh-CN" : "en";
  }, [locale]);

  return <I18nContext.Provider value={value}>{children}</I18nContext.Provider>;
}

export function useI18n() {
  return useContext(I18nContext);
}
