import { createContext, useContext, useEffect, useMemo, useState } from "react";

const messages = {
  en: {
    "nav.overview": "Overview",
    "nav.terminal": "Terminal",
    "nav.why": "Why",
    "nav.changelog": "Changelog",
    "nav.source": "Source",
    "hero.kicker": "A workbench that stays running on your machine",
    "hero.titleA": "Your work",
    "hero.titleB": "keeps running.",
    "hero.lede":
      "Warren is a workbench for terminals, agents, and code, running on your own Mac or VPS instead of someone else's cloud. Quit the app, lose Wi-Fi, or move to a browser; the Host keeps the work running and you walk straight back into it.",
    "hero.ctaTerminal": "Try the terminal",
    "hero.ctaDocs": "Read the source",
    "hero.ctaDownload": "Download",
    "hero.downloading": "Getting latest…",
    "hero.downloadReady": "Downloading…",
    "hero.downloadFallback": "Open releases",
    "hero.status": "Open source · phase one",
    "hero.platform": "macOS · Web · CLI",
    "ticker.items": ["Terminals", "Agents", "Editor", "Detach", "Reconnect", "Resume"],
    "product.kicker": "Across every screen",
    "product.title": "One workspace: terminal, agent, editor.",
    "product.lede":
      "Start on the desktop, pick up in a browser, drop to the CLI. The same Host keeps every workspace running, whichever screen you open it on.",
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
        badge: "Coming soon",
        alt: "Warren mobile client showing an agent conversation",
        caption: "Check progress and respond from your phone.",
      },
      {
        label: "Mobile · terminal",
        badge: "Coming soon",
        alt: "Warren mobile client showing a terminal session",
        caption: "Reconnect to the Host wherever you are.",
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
    "features.title": "The work belongs to the Host.",
    "features.lede": "Not to the window you happened to close.",
    "features.items": [
      {
        title: "Durable sessions",
        body: "Quit the app, switch networks, close the laptop. Your session stays on the Host and is still there when you come back.",
      },
      {
        title: "Terminal, agent, editor",
        body: "One workspace carries a real terminal, a structured agent view, and an embedded VS Code-compatible editor beside it — not three disconnected tools.",
      },
      {
        title: "One resource model",
        body: "Projects, workspaces, sessions and runtimes are the same objects on desktop, web and CLI. No parallel universes.",
      },
      {
        title: "Local and remote",
        body: "SSH just gets you to the Host. After that, all clients speak the same WebSocket protocol to the same daemon.",
      },
      {
        title: "Real terminal fidelity",
        body: "The desktop uses Ghostty, the web uses xterm.js. ANSI, OSC, Unicode and TUI colors keep working.",
      },
      {
        title: "Workspaces and cross-repo tasks",
        body: "Main checkouts and Git worktrees are first-class, and a Task can group workspaces from several repositories into one piece of work.",
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
    "architecture.note": "SSH and Relay only provide reachability. They are not the product model.",
    "principle.quote":
      "Closing a tab is the only way to end a session. Quitting, switching workspaces, losing Wi-Fi — that's just walking away.",
    "principle.cite": "Warren product design, §5",
    "footer.line": "The work belongs to the Host.",
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
        version: "0.19.0",
        dateISO: "2026-09-18",
        date: "September 18, 2026",
        title: "Warren puts the embedded editor beside the Terminal.",
        summary:
          "A minor release that mounts the embedded editor as a region beside the Terminal instead of a page that replaces it, and gives iOS taps a visible acknowledgement with bubbles sized to the screen; the JSON control protocol remains at 4.0.",
        sections: [
          {
            title: "Added",
            items: [
              "Mount the embedded editor as a region beside the Terminal (RFC 0021): one code-server surface split from the Terminal by a single divider, with the Terminal left mounted and subscribed instead of parked by a whole-page content mode.",
              "Open the editor per Workspace and durably on this Mac: a marker keyed by Endpoint and Workspace records that it is open and which document was left, so an editor-only Workspace survives `Active only`; the retired content mode's set migrates into markers.",
              "Acknowledge taps on iOS: `IOSPressableStyle` dims rows and transcript blocks under the finger, and additionally settles floating chrome toward it; the scale is dropped under reduce motion.",
            ],
          },
          {
            title: "Changed",
            items: [
              "Size iOS transcript bubbles as a fraction of the column (0.89) instead of a fixed 345pt, measured once at the transcript and handed down, so bubbles no longer re-measure every scroll frame.",
              "Open the Terminal and the editor on even halves, reserving 180pt for the Explorer beside code-server's 220pt editor floor.",
              "Give the 22 RFCs an index, archive the three that describe no current behaviour, and correct the README (duplicate entry, abandoned RFC, stale 0.12.0 migration section).",
            ],
          },
          {
            title: "Fixed",
            items: [
              "Register a semantic node's action as a stable trampoline, so a state-dependent control stops performing the direction it was born with.",
            ],
          },
          {
            title: "Release notes",
            items: [
              "The protocol remains at 4.0 and the state schema stays at 4 with no migration; an editor opened in the retired content mode is migrated into a marker and opens as a region.",
              "The editor region is not a Host pane leaf — it has no PTY, lifecycle, input lease, or Host ownership — so it follows the Desktop's layout rather than a Host-owned arrangement.",
              "Local packaging uses the available Apple Development signing identity and is not notarized; the archive is for internal or temporary testing.",
            ],
          },
        ],
      },
      {
        version: "0.18.0",
        dateISO: "2026-09-18",
        date: "September 18, 2026",
        title: "Warren counts Usage once and pairs with opaque invites.",
        summary:
          "A minor release that makes Usage count each billable model call once and derive cost on read, replaces host-scoped pairing links with opaque invites, prunes the Host's canonical journal, and removes the stalls, mislabelled waits, and guessed states between a client, a Host, and a Relay; the JSON control protocol remains at 4.0.",
        sections: [
          {
            title: "Added",
            items: [
              "Prune retired Agent streams from the Host's canonical journal with a bounded background sweep, so `agent-journal.db` stops growing without limit.",
              "Bind live Codex Sessions from every profile home, so a Session running under a profile-specific `CODEX_HOME` gets a live transcript.",
            ],
          },
          {
            title: "Changed",
            items: [
              "Pairing links are opaque invites only: the host-scoped `/h/<host>/#t=<code>` form is gone, along with the Relay's exchange route, the body ticket fields, and the Host-side acceptance.",
              "A Relay route and a Host identity are two different ids on iOS, so LAN pairing and discovery no longer overwrite the Relay record id, and a Relay-only Host adopts the identity a verified LAN probe reports.",
              "Usage counts Codex history from every profile home, shows where the money went beside where the tokens went, filters the intraday curve by Agent or model, and says how long ago its figures were rebuilt.",
              "The Host rotates `headless.log` while it runs, and install detects a running app from any bundle path.",
              "An authenticated client waiting for its Host says \"Waiting for Mac…\" and waits up to 15 seconds instead of being told the Host is offline.",
              "Relay compresses by frame size, forwards each client stream in both directions independently, and queues up to 1024 control frames bounded by 8 MiB.",
            ],
          },
          {
            title: "Fixed",
            items: [
              "Usage counts each billable model call once, derives cost from tokens on every read, and no longer clears providers it cannot re-read.",
              "Resume the websocket ping continuation only once, which crashed `WarrenIOSApp` with SIGTRAP during Relay reconnects.",
              "Claim Agent control without waiting for capability negotiation, so a new Agent Session no longer reports the Host as offline.",
              "The rich sidebar's session rail lights only for a pointer that moved onto the group, or for the workspace the center is showing.",
            ],
          },
          {
            title: "Release notes",
            items: [
              "The protocol remains at 4.0 and the state schema stays at 4 with no migration; a host-scoped pairing link is no longer accepted, so reissue an opaque invite for a client that still holds one.",
              "The Host prunes retired Agent streams, but a deleted Session's conversation is not reconstructible; back up `~/.warren` before upgrading a Host you rely on.",
              "Local packaging uses the available Apple Development signing identity and is not notarized; the archive is for internal or temporary testing.",
            ],
          },
        ],
      },
      {
        version: "0.17.0",
        dateISO: "2026-09-16",
        date: "September 16, 2026",
        title: "Warren drops the guessed Agent stall states.",
        summary:
          "A minor release that removes the Agent `stalled` activity and the `warning` attention kind, so Agent state means only what a provider explicitly reports; the JSON control protocol remains at 4.0.",
        sections: [
          {
            title: "Removed",
            items: [
              "Remove the Agent `stalled` activity: the 30-second grace-period warning fired on ordinary long-running work and withheld client input, so activity is now `ready | working | blocked | failed | exited` and attention comes only from an explicit provider input or approval observation.",
              "Remove the Agent `warning` attention kind, which only ever carried the stalled warning; `attention.kind` is now `input | approval`, and a client receiving an unknown kind renders no banner.",
            ],
          },
          {
            title: "Release notes",
            items: [
              "The protocol remains at 4.0 with no state migration, and a rolling upgrade stays compatible: a Host that still sends `stalled` or an unknown attention kind renders no indicator on an upgraded client instead of an error.",
              "Local packaging uses the available Apple Development signing identity and is not notarized; the archive is for internal or temporary testing.",
            ],
          },
        ],
      },
      {
        version: "0.16.1",
        dateISO: "2026-09-16",
        date: "September 16, 2026",
        title: "Warren keeps rich mode's pane bar to the panes on screen.",
        summary:
          "A patch release that stops rich mode's pane bar from pinning a split group to the top chrome when the user visits a Session outside the layout; the JSON control protocol remains at 4.0.",
        sections: [
          {
            title: "Fixed",
            items: [
              "Stop the pane bar from pinning a split group on the top chrome in rich mode: the sidebar already lists Sessions there, so the bar draws only the panes on screen, and compact mode keeps the group on the strip as the way back into the split.",
            ],
          },
          {
            title: "Release notes",
            items: [
              "No control-protocol or state-schema change. Local packaging uses the available Apple Development signing identity and is not notarized; the archive is for internal or temporary testing.",
            ],
          },
        ],
      },
      {
        version: "0.16.0",
        dateISO: "2026-09-16",
        date: "September 16, 2026",
        title: "Warren restores the Desktop's host-owned split panes.",
        summary:
          "A fix release that restores the Desktop's pane-group writes, which 0.15.0 dropped because the Swift client never advertised the `pane-groups-v1` capability, and repairs the split-adoption path that made a scope's second split revert or land on the wrong pair; the JSON control protocol remains at 4.0.",
        sections: [
          {
            title: "Added",
            items: [
              "Keep the sidebar rail lit for the workspace the center is showing, so the tree marks the live workspace with no pointer on it.",
            ],
          },
          {
            title: "Changed",
            items: [
              "Keep the pane bar's group on the strip while another Session is visited, so the strip stays the way back into the split.",
              "Keep the sidebar's content column on the rail when the rail narrows, instead of pushing every row's leading text off the window.",
            ],
          },
          {
            title: "Fixed",
            items: [
              "Advertise `pane-groups-v1` from the Swift transport client so the Host's negotiated set includes it and the Desktop can create, split, rename, move, and remove arrangements again; 0.15.0 shipped only the Host-side advertisement, so those writes were silently dropped while CLI layouts kept working.",
              "Keep pane groups through a projection copy, so the Tab move that ends a split no longer empties them and a second split in the same scope can land.",
              "Stop a stale roster from collapsing a split in flight, split the Session the user aimed at instead of a stale pane, and drop a scope's local tree once the Host owns no group for it.",
              "Show a spinner in the iOS send button while sending or uploading, and stop the bottom status text from flickering.",
            ],
          },
          {
            title: "Release notes",
            items: [
              "The protocol remains at 4.0 and this release migrates no state; a Host that already owns pane groups keeps them. If 0.15.0 is installed, upgrade the Desktop to 0.16.0 before relying on split panes there.",
              "Local packaging uses the available Apple Development signing identity and is not notarized; the archive is for internal or temporary testing.",
            ],
          },
        ],
      },
      {
        version: "0.15.0",
        dateISO: "2026-09-16",
        date: "September 16, 2026",
        title: "Warren makes split layouts durable and search consistent.",
        summary:
          "A minor release that makes a split terminal arrangement durable Host state any client can render, shares one search engine across Desktop, iOS, and Web, and turns selecting a pane into a reparent instead of a cold attach; the JSON control protocol remains at 4.0.",
        sections: [
          {
            title: "Added",
            items: [
              "Make a split arrangement durable Host state: a Workspace or Terminal Group holds several arrangements, and `warren pane` lists, creates, splits, closes, renames, moves, and removes them.",
              "Share one search engine across Desktop, iOS, and Web with the same ranking and `w:`/`p:`/`s:`/`t:`/`g:`/`@blocked` grammar, with results led by the provider's own mark.",
              "Inject an OSC 7 working-directory hook for zsh and fish sessions so the pane title, tab, and sidebar track `cd`.",
              "Share Session label rules across clients, add `RUN` and `CWD` columns to `warren session list`, and stream foreground metadata in its own roster delta.",
              "Support GFM markdown callout alerts in iOS Agent transcripts.",
            ],
          },
          {
            title: "Changed",
            items: [
              "Render exactly one of a scope's arrangements per window, with Cycle Pane Group (⌘`) and Previous Pane Group (⇧⌘`) to step through them.",
              "Gather a split's Sessions into one labelled, unbroken run in the pane bar so no Tab can fall inside the group.",
              "Stop a rich-mode workspace row from navigating on a single click; hovering now lights the group's rail, and double-click starts a new Session.",
              "Read a sidebar Session leaf as its running command and directory, with a fallback to the launch directory until the shell reports OSC 7.",
              "Promote every retained surface so selecting a visible pane is a reparent instead of a snapshot re-seed.",
              "Raise the warm surface budget to 32 surfaces and a 3 GiB byte limit.",
              "Pace iOS chat streaming, cache markdown layout, and hand a send off without re-rendering the transcript.",
            ],
          },
          {
            title: "Fixed",
            items: [
              "Keep a split group on screen while another Session is visited and land a pending split as soon as its Session exists.",
              "Make every close command act on the layout its chip belongs to, and stop deleting a local arrangement the Host has not seen yet.",
              "Apply PTY resizes and focus viewports off the connection reader so a slow resize no longer delays later commands.",
              "Recover a retained surface whose renderer is gone, and treat restored Agent turns as a baseline instead of new completions.",
              "Present the iOS photo picker from the composer menu, stop the composer from dropping IME input or lagging on each keystroke, and smooth compact chat bubbles and send-time transitions.",
            ],
          },
          {
            title: "Release notes",
            items: [
              "The protocol remains at 4.0 with the `pane-group.*` methods behind the `pane-groups-v1` capability, and Host state moves to schema 4 additively. Validate host-owned pane groups across a rolling Host upgrade.",
              "The warm surface budget raises the worst-case retained pool to roughly 2-3 GB; watch resident memory on a long-running Desktop.",
              "Local packaging uses the available Apple Development signing identity and is not notarized; the archive is for internal or temporary testing.",
            ],
          },
        ],
      },
      {
        version: "0.14.0",
        dateISO: "2026-09-14",
        date: "September 14, 2026",
        title: "Warren brings native split terminals and richer Usage insights.",
        summary:
          "A minor release that adds native split terminal workflows, historical Usage analytics, thread-oriented sidebar organization, and runtime-aware Session titles across Desktop, Web, and Headless clients; the JSON control protocol remains at 4.0.",
        sections: [
          {
            title: "Added",
            items: [
              "Add native AppKit split terminal panes with drag-and-drop placement, independent PTY sizing, and screen reporting.",
              "Rebuild Usage from historical transcripts with per-day Agent, model, and project breakdowns, a selectable heatmap, an intraday curve, and cached fetches.",
              "Add a thread-oriented sidebar mode with Sessions as leaves, Task pinning, Projects and Workspaces cards, and quick setup scripts.",
              "Show a Session's foreground command line and OSC 7 working directory in its pane title, tab, and sidebar.",
            ],
          },
          {
            title: "Changed",
            items: [
              "Make pane close actions Session commands: closing a pane, other panes, or all panes now ends the Sessions shown there.",
              "Rework Desktop Settings and Usage into categorized two-column layouts with grouped cards, refined typography, and a clearer sidebar tree rail.",
              "Keep startup work, Relay device listing, state-store reads, and loopback handoff work off the terminal attach path to improve reconnect reliability.",
              "Remove the Tasks section from the Web client; Task management remains on Desktop and the CLI.",
            ],
          },
          {
            title: "Fixed",
            items: [
              "Keep a Session on its retired Agent conversation until the replacement transcript is on disk, preventing stale title updates.",
              "Apply Usage range changes made during an in-flight fetch and scope missing-token caveats to the requested range.",
              "Improve terminal search highlight contrast and use Menlo in the find field.",
            ],
          },
          {
            title: "Release notes",
            items: [
              "The release adds no control-protocol version change or state-schema migration; validate split-pane focus and close behavior, Usage history reconstruction, and OSC 7 title reporting on a clean host.",
              "Local packaging uses the available Apple Development signing identity and is not notarized; the archive is suitable for internal or temporary testing, not general public distribution.",
            ],
          },
        ],
      },
      {
        version: "0.13.0",
        dateISO: "2026-09-11",
        date: "September 11, 2026",
        title: "Warren makes Hosts discoverable and workflows multi-Host.",
        summary:
          "A minor release that adds local-network Host discovery, explicit Host-armed pairing, multi-Host navigation, and iOS Host management. It also strengthens canonical Agent projections and terminal recovery across macOS, iOS, Web, and Headless clients; the JSON control protocol remains at 4.0.",
        sections: [
          {
            title: "Added",
            items: [
              "Add mDNS/DNS-SD Host discovery, stable Host identity, candidate probing, direct-LAN routing, and endpoint aggregation across changing network addresses.",
              "Add an explicit Host-armed LAN pairing flow with a short-lived PIN and scoped client credentials; discovery alone never grants access.",
              "Add multi-Host Desktop navigation with Host-scoped Projects and Workspaces, endpoint display names, active-session filtering, clearer empty states, and Task-aware navigation.",
              "Add iOS Host management with local discovery, direct-LAN and Relay route selection, QR/PIN pairing, Agent history reload, and richer Agent cards.",
              "Record anonymous onboarding download starts in Workers Analytics Engine with release, visitor, platform, location, language, and referrer dimensions.",
            ],
          },
          {
            title: "Changed",
            items: [
              "Keep Desktop, Web, CLI, and iOS Agent surfaces on the canonical projection while normalizing plan events, compaction summaries, provider markup, diffs, and legacy read responses.",
              "Make endpoint identity explicit in transport and sidebar state so focus, resize, routing, and resource selection remain scoped to the correct Host.",
              "Keep the terminal sidebar and embedded editor state stable while improving attach/reconnect behavior and preserving workspace context.",
            ],
          },
          {
            title: "Fixed",
            items: [
              "Preserve terminal connections across output resets and guard focus claims and resizes against stale layout generations.",
              "Route task-linked Workspaces to their actionable Task row and distinguish unavailable Hosts, active-only filtering, and Hosts without Projects.",
              "Preserve embedded-editor workspace state across presentation and navigation changes.",
            ],
          },
          {
            title: "Release notes",
            items: [
              "LAN discovery is a reachability mechanism, not a trust grant. Pairing must be explicitly armed on the Host, and existing Relay/direct endpoints remain available when LAN discovery is unavailable.",
              "The release adds no control-protocol version change or state-schema migration; validate direct-LAN pairing, multi-Host routing, and iOS local-network permissions on real devices before publishing.",
            ],
          },
        ],
      },
      {
        version: "0.12.2",
        dateISO: "2026-09-09",
        date: "September 9, 2026",
        title: "Warren makes remote Hosts easier to understand and recover.",
        summary:
          "A patch release that improves Host diagnostics and compatibility handling, strengthens Agent interaction fidelity, and stabilizes terminal attachment. Covers macOS, Web, and Headless clients; iOS changes remain outside this release.",
        sections: [
          {
            title: "Added",
            items: [
              "Add advisory Host health probes for direct endpoints and show reachability, Headless build, protocol status, and connection errors in the Desktop Execution Server menu, with a manual Check hosts action.",
            ],
          },
          {
            title: "Changed",
            items: [
              "Extend Relay and remote WebSocket handshake windows for slower DNS, TLS, proxy, and mobile-network negotiation.",
              "Preserve Codex question schemas while exposing optional notes and completed answer labels through the provider-neutral interaction response.",
              "Keep terminal attach and focus reconciliation generation-safe, coalesce duplicate attaches, and avoid redundant layout work during presentation.",
              "Keep external IDE discovery cached across repeated Desktop menu opens.",
            ],
          },
          {
            title: "Fixed",
            items: [
              "Stop reconnect loops when the Host reports an incompatible protocol or terminal-state format, while retaining retry behavior for transient failures.",
              "Match resolved Agent interactions by request or interaction identity so replayed responses retain their original questions and options.",
            ],
          },
        ],
      },
      {
        version: "0.12.1",
        dateISO: "2026-09-08",
        date: "September 8, 2026",
        title: "Warren makes Agent workflows calmer and more predictable.",
        summary:
          "A patch release that improves Agent interaction reliability, cross-client control flow, task and workspace navigation, external IDE discovery, and embedded editor typography. Covers macOS, Web, and Headless clients; iOS changes remain outside this release.",
        sections: [
          {
            title: "Changed",
            items: [
              "Keep canonical Agent View operations independent from the terminal PTY control lease so Web and Headless Agent actions do not contend with terminal focus.",
              "Keep model and reasoning choices in launch-time/provider configuration instead of issuing in-session switch commands in the Web Agent surface.",
              "Cache external IDE options, align embedded editor typography with the native editor, and keep task-linked workspaces anchored to Task navigation.",
              "Avoid unnecessary sidebar recentering, make workspace selection state clearer across Desktop and Web, and keep disabled workspace rows visually quiet.",
            ],
          },
          {
            title: "Fixed",
            items: [
              "Resolve structured question responses by option index, including multi-choice keyboard navigation, custom answers, and multi-step interactions.",
              "Prevent Agent interaction submissions from getting stuck behind terminal control ownership or a stale loading state.",
            ],
          },
        ],
      },
      {
        version: "0.12.0",
        dateISO: "2026-09-08",
        date: "September 8, 2026",
        title: "Warren adopts canonical Agent execution and Relay control.",
        summary:
          "A minor release that advances the JSON control protocol to 4.0, adds durable canonical Agent execution across Codex, Claude, OpenCode, Pi, Qoder, and Antigravity, and makes Relay an independently deployed control plane. Host state schemas 1 and 2 migrate to schema 3; pre-4.0 clients and Ghostline v0 sockets are not compatible. Targets arm64 Apple Silicon on macOS 13+; Public Access uses Relay routes.",
        sections: [
          {
            title: "Added",
            items: [
              "Add canonical Agent events, durable command admission, history recovery, structured interactions, queues, attachments, goals, and model/reasoning controls.",
              "Add normalized Agent providers for Codex, Claude, OpenCode, Pi, Qoder, and Antigravity; Trae remains an interactive shell preset.",
              "Add Relay enrollment keys, opaque share links, signed capabilities, refresh tokens, device revocation, and IP/path routes.",
              "Add embedded SSH endpoints, a bundled forwarding helper, and terminal-link opening in the embedded editor.",
              "Add safer Task, Workspace, and Session workflows with ordering, worktree import, MRU navigation, preflight checks, and guarded undo.",
            ],
          },
          {
            title: "Changed",
            items: [
              "Move terminal recovery to atomic DENB state snapshots with durable Ghostline cursors and rolling handoff across compatible v1 runtimes.",
              "Bound CLI list and transcript output by default; use --all, --full, --tool-output, filtering, quiet mode, or explicit truncation for automation.",
            ],
          },
          {
            title: "Breaking",
            items: [
              "Advance the JSON control protocol to 4.0 and remove legacy Agent aliases, JSON input fallback, old session lifecycle paths, the Ghostline v0 bridge, and the legacy PTY alias.",
              "Ship the 0.12.0 Host and client surface together; pre-4.0 clients are rejected during authentication and Ghostline v0 sockets require recreation.",
            ],
          },
          {
            title: "RFCs",
            items: [
              "Include RFC 0012, 0013, 0014, 0015, 0016, 0017, 0018, and 0019 with their current proposed, draft, or implemented status.",
            ],
          },
        ],
      },
      {
        version: "0.11.3",
        dateISO: "2026-08-30",
        date: "August 30, 2026",
        title: "Warren makes Codex Working visibly blink.",
        summary:
          "A patch release that adds a visible blinking Working indicator, preserves configured terminal colors after snapshot restore, and marks interrupted agent messages consistently. Targets arm64 Apple Silicon on macOS 13+; Public Access uses Relay routes.",
        sections: [
          {
            title: "Changed",
            items: [
              "Show a visible blinking Working indicator while Codex is actively producing output.",
              "Reapply Warren's terminal color configuration after native snapshot restoration so Working output remains visible.",
            ],
          },
          {
            title: "Fixed",
            items: ["Mark interrupted agent messages consistently in the Web view."],
          },
        ],
      },
      {
        version: "0.11.2",
        dateISO: "2026-08-29",
        date: "August 29, 2026",
        title: "Warren adds Host-owned Tasks and a durable Host schema.",
        summary:
          "A patch release that adds Host-owned Tasks aggregating Workspaces across Projects and migrates Host state to schema 2 so Task data is durable. Targets arm64 Apple Silicon on macOS 13+; Public Access uses Relay routes.",
        sections: [
          {
            title: "Added",
            items: [
              "Add Host-owned Tasks that aggregate Workspaces across Projects, with provider-neutral external work-item metadata, Web and CLI lifecycle controls, and Web/Desktop Workspace attach and detach actions.",
            ],
          },
          {
            title: "Changed",
            items: [
              "Migrate Host state from schema 1 to schema 2 so Task data is durable and unknown future schemas fail closed.",
            ],
          },
        ],
      },
      {
        version: "0.11.1",
        dateISO: "2026-08-29",
        date: "August 29, 2026",
        title: "Warren hardens endpoint switching and Public Access state.",
        summary:
          "A patch release that hardens endpoint switching, preserves Public Access state across restarts, fixes web-link auth and mobile scrolling, and improves Linux terminfo handling. Targets arm64 Apple Silicon on macOS 13+; Public Access uses Relay routes.",
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
              "Persist Public Access route state across daemon restarts by checking the Relay route metadata.",
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
          "A minor release that bundles xterm-ghostty truecolor terminfo, tightens terminal rendering around warm promotion and resize, and hardens Ghostline handoff and workspace creation. Targets arm64 Apple Silicon on macOS 13+; Public Access uses Relay routes.",
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
          "A super-major release that upgrades to incompatible Ghostline runtime semantics with automatic session handoff. Downgrading without recreating sessions is not supported. Targets arm64 Apple Silicon on macOS 13+; Public Access uses Relay routes.",
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
        title: "Warren ships Relay route support.",
        summary:
          "A maintenance release that aligns Public Access with Relay routes and keeps the onboarding page at the top until the terminal demo is explicitly requested.",
        sections: [
          {
            title: "Changed",
            items: [
              "Align Public Access route lifecycle with the Relay protocol.",
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
              "Add Public Access through a self-hosted Relay with Save & Test, pairing, lifecycle controls, restart recovery, and credential-free endpoint reporting.",
              "Add agent-first CLI commands for Codex and Claude Agents, normalized transcript reads, bounded turn waits, and explicit targeting.",
              "Add provider-neutral Agent activity and human-attention status across Host, Web, Desktop, and CLI with Workspace and Terminal Group aggregation.",
              "Add scoped warren://terminal and Web links for Project, Workspace, and Session targets, plus warren://settings links for Public Access setup.",
              "Add a bounded desktop notice center with unread and mute controls, a compact Workspace More menu, and shared Unix editing shortcuts for non-terminal inputs.",
            ],
          },
          {
            title: "Changed",
            items: [
              "Use Relay route metadata and scoped capabilities without packaging a local reachability worker.",
              "Keep Agent, roster, terminal, and transcript projections explicit and bounded while preserving terminal dimensions through responsive chrome and notices.",
              "Roll Ghostline upgrades by release tag and require stable code signing for distributable macOS builds.",
            ],
          },
          {
            title: "Fixed",
            items: [
              "Harden Public Access Relay enrollment, route lifecycle recovery, secret handling, setup defaults, and explicit browser authentication links.",
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
    "hero.kicker": "常驻在你机器上的开发工作台",
    "hero.titleA": "你的活儿，",
    "hero.titleB": "一直在跑。",
    "hero.lede":
      "Warren 把终端、Agent 和代码放进同一个工作台，跑在你自己的 Mac 或 VPS 上，而不是别人的云里。退出应用、网络断开、换成浏览器打开——活儿在 Host 上继续跑，你随时走回去接手。",
    "hero.ctaTerminal": "试试终端",
    "hero.ctaDocs": "查看源码",
    "hero.ctaDownload": "下载",
    "hero.downloading": "获取最新版…",
    "hero.downloadReady": "开始下载…",
    "hero.downloadFallback": "打开 Releases",
    "hero.status": "Phase one · 开源",
    "hero.platform": "macOS · Web · CLI",
    "ticker.items": ["终端", "Agent", "编辑器", "断开", "重连", "接着做"],
    "product.kicker": "每一块屏幕",
    "product.title": "一个 Workspace，装下终端、Agent 和编辑器。",
    "product.lede":
      "从桌面端开始，在浏览器里接着做，也可以退回 CLI。同一个 Host 让每个 Workspace 一直跑着，你从哪块屏幕打开都一样。",
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
        badge: "即将推出",
        alt: "Warren 移动端中的 Agent 对话",
        caption: "用手机查看进度、继续回复。",
      },
      {
        label: "移动端 · 终端",
        badge: "即将推出",
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
    "features.title": "活儿属于 Host。",
    "features.lede": "不属于你刚关掉的那扇窗口。",
    "features.items": [
      {
        title: "持久会话",
        body: "退出应用、切换网络、合上电脑。会话留在 Host 上，你回来时它还在。",
      },
      {
        title: "终端、Agent、编辑器",
        body: "同一个 Workspace 里有真实终端、结构化的 Agent 视图，和一个并排的 VS Code 兼容编辑器——不是三个各自为政的工具。",
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
        title: "Workspace 与跨仓库 Task",
        body: "主检出和 Git worktree 都是一等资源；一个 Task 可以把多个仓库的 Workspace 聚成同一件活。",
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
    "architecture.note": "SSH 和 Relay 只负责提供访问路径，不属于产品模型。",
    "principle.quote":
      "关闭 Tab 是结束会话的唯一方式。退出、切换工作区、Wi-Fi 断了——那只是离开而已。",
    "principle.cite": "Warren 产品设计，§5",
    "footer.line": "活儿属于 Host。",
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
        version: "0.19.0",
        dateISO: "2026-09-18",
        date: "2026 年 9 月 18 日",
        title: "Warren 把内嵌编辑器放到 Terminal 旁边。",
        summary:
          "次版本：内嵌编辑器不再替换 Terminal，而是作为 Terminal 旁的独立区域；iOS 点击有了可见反馈，气泡宽度改为随屏幕。JSON 控制协议仍为 4.0。",
        sections: [
          {
            title: "新增",
            items: [
              "内嵌编辑器改为 Terminal 旁的独立区域（RFC 0021）：一个 code-server surface 与 Terminal 由一个分隔条分开，Terminal 保持挂载与订阅，不再被整页 content mode 停放。",
              "编辑器按 Workspace 打开并在本机持久：以 (Endpoint, Workspace) 为键的记录保存打开状态与最后文档，仅剩编辑器的 Workspace 也能在 `Active only` 下保留；旧 content mode 的集合会迁移为标记。",
              "iOS 点击有了可见反馈：`IOSPressableStyle` 让行与 transcript 块在手指下变暗，浮动控件另向手指收缩；reduce motion 下取消缩放。",
            ],
          },
          {
            title: "调整",
            items: [
              "iOS transcript 气泡宽度改为列宽的 0.89 倍，不再固定 345pt，且在 transcript 处只量一次并向下传递，不再每帧重测。",
              "Terminal 与编辑器各占一半，在 code-server 220pt 编辑器下限旁为 Explorer 保留 180pt。",
              "为 22 个 RFC 建立索引，归档不再描述现行行为的三个，并修正 README（重复条目、推荐已废弃 RFC、过期的 0.12.0 迁移说明）。",
            ],
          },
          {
            title: "修复",
            items: [
              "语义节点的 action 改为稳定的 trampoline，使依赖状态的控件不再重复执行它诞生时的方向。",
            ],
          },
          {
            title: "发布说明",
            items: [
              "协议仍为 4.0，state schema 仍为 4，无 migration；旧 content mode 中打开的编辑器会迁移为标记并以区域形式打开。",
              "编辑器区域不是 Host pane leaf（无 PTY、lifecycle、input lease 与 Host 所有权），因此它跟随 Desktop 布局，而非 Host 托管的布局。",
              "本地打包使用现有 Apple Development 签名且未 notarize；归档仅适合内部或临时测试。",
            ],
          },
        ],
      },
      {
        version: "0.18.0",
        dateISO: "2026-09-18",
        date: "2026 年 9 月 18 日",
        title: "Warren 让 Usage 只计一次，并改用不透明邀请配对。",
        summary:
          "次版本：Usage 将每次可计费模型调用只计一次并在读取时现算成本，host-scoped 配对链接改为不透明邀请，Host 会清理 journal，并移除 client、Host 与 Relay 之间的停顿、误标等待与猜测状态；JSON 控制协议仍为 4.0。",
        sections: [
          {
            title: "新增",
            items: [
              "以有界后台扫描清理 Host canonical journal 中已退役的 Agent stream，使 `agent-journal.db` 不再无限增长。",
              "从每个 profile home 绑定在跑的 Codex Session，使使用 profile 专属 `CODEX_HOME` 的 Session 也能获得实时 transcript。",
            ],
          },
          {
            title: "调整",
            items: [
              "配对链接只保留不透明邀请：host-scoped 的 `/h/<host>/#t=<code>` 形式及其 Relay exchange 路由、body ticket 字段和 Host 侧接受逻辑全部移除。",
              "iOS 上 Relay 路由与 Host 身份是两个不同的 id，LAN 配对与发现不再覆盖 Relay record id；仅经 Relay 配对的 Host 会采纳经校验的 LAN 探测所报的身份。",
              "Usage 从每个 profile home 统计 Codex 历史，在 token 之外同时显示花费去向，可按 Agent 或模型过滤日内曲线，并显示上次重建距今多久。",
              "Host 在运行中轮转 `headless.log`，安装流程可从任意 bundle 路径识别正在运行的 app。",
              "等待 Host 的已认证客户端会显示「Waiting for Mac…」并最多等待 15 秒，而不是立刻被告知 Host 离线。",
              "Relay 按帧大小决定压缩，双向独立转发每条 client stream，控制帧队列提升至 1024 帧 / 8 MiB。",
            ],
          },
          {
            title: "修复",
            items: [
              "Usage 将每次可计费模型调用只计一次，成本在读取时由 token 现算，且重建不再清空无法重读的 provider。",
              "websocket ping 的 continuation 只 resume 一次，修复 Relay 重连时以 SIGTRAP 崩溃 `WarrenIOSApp` 的问题。",
              "不再等待能力协商即可 claim Agent control，新建 Agent Session 不再误报 Host 离线。",
              "富模式侧栏竖线只在指针真实移动到该 group，或该 workspace 是当前 scope 时才亮。",
            ],
          },
          {
            title: "发布说明",
            items: [
              "协议仍为 4.0，state schema 仍为 4，无 migration；host-scoped 配对链接不再被接受，持有此类链接的客户端需重新签发不透明邀请。",
              "Host 会清理已退役的 Agent stream，但被删除的 Session conversation 无法重建；升级依赖的 Host 前请备份 `~/.warren`。",
              "本地打包使用现有 Apple Development 签名且未 notarize；归档仅适合内部或临时测试。",
            ],
          },
        ],
      },
      {
        version: "0.17.0",
        dateISO: "2026-09-16",
        date: "2026 年 9 月 16 日",
        title: "Warren 移除凭猜测得出的 Agent 停滞状态。",
        summary:
          "次版本：移除 Agent 的 `stalled` activity 与 `warning` attention kind，使 Agent 状态只表达 provider 明确报告的事实；JSON 控制协议仍为 4.0。",
        sections: [
          {
            title: "移除",
            items: [
              "移除 Agent 的 `stalled` activity：30 秒宽限警告在普通长任务上误报并扣住客户端输入，现在 activity 为 `ready | working | blocked | failed | exited`，attention 只来自 provider 明确的 input 或 approval 观测。",
              "移除 Agent 的 `warning` attention kind（它只承载 stalled 警告）：`attention.kind` 现为 `input | approval`，客户端收到未知 kind 不再显示横幅。",
            ],
          },
          {
            title: "发布说明",
            items: [
              "协议仍为 4.0，无 state migration，滚动升级兼容：仍发送 `stalled` 或未知 attention kind 的 Host 在升级后的客户端上不显示指示，而不会报错。",
              "本地打包使用现有 Apple Development 签名且未 notarize；归档仅适合内部或临时测试。",
            ],
          },
        ],
      },
      {
        version: "0.16.1",
        dateISO: "2026-09-16",
        date: "2026 年 9 月 16 日",
        title: "Warren 让富模式的 pane bar 只显示在屏的 pane。",
        summary:
          "修补版本：富模式下当用户浏览布局之外的 Session 时，pane bar 不再把分屏组钉在顶部 chrome；JSON 控制协议仍为 4.0。",
        sections: [
          {
            title: "修复",
            items: [
              "富模式下 pane bar 不再把分屏组钉在顶部 chrome：该模式的侧边栏已列出全部 Session，因此条带只绘制在屏的 pane；紧凑模式仍在条带保留分组，作为回到分屏的入口。",
            ],
          },
          {
            title: "发布说明",
            items: [
              "无控制协议或 state schema 变化。本地打包使用现有 Apple Development 签名且未 notarize；归档仅适合内部或临时测试。",
            ],
          },
        ],
      },
      {
        version: "0.16.0",
        dateISO: "2026-09-16",
        date: "2026 年 9 月 16 日",
        title: "Warren 恢复 Desktop 的 Host 托管分屏。",
        summary:
          "修复版本：恢复 Desktop 的 pane group 写操作（0.15.0 因 Swift 客户端未 advertise `pane-groups-v1` 而被静默丢弃），并修复让同一作用域第二次分屏回退或落在错误组合上的采纳路径；JSON 控制协议仍为 4.0。",
        sections: [
          {
            title: "新增",
            items: [
              "当前显示的 workspace 会让侧边栏导轨常亮，无需指针悬停即可标出活动 workspace。",
            ],
          },
          {
            title: "调整",
            items: [
              "浏览其他 Session 时，pane bar 仍保留分屏组，使条带继续作为回到分屏的入口。",
              "侧边栏收窄时内容列保持在导轨上，不再把每行前导文字挤出窗口。",
            ],
          },
          {
            title: "修复",
            items: [
              "让 Swift 客户端 advertise `pane-groups-v1`，使 Host 协商结果包含它，Desktop 重新可以创建、分屏、重命名、移动和删除布局；0.15.0 只做了 Host 侧 advertise，导致这些写操作被静默丢弃，而 CLI 布局一直可用。",
              "投影副本不再丢失 pane groups，使结束分屏的 Tab 移动不再清空它们，同一作用域的第二次分屏可以落地。",
              "过期 roster 不再折叠在途分屏，分屏对准用户点击的 Session，并在 Host 不再拥有该组时清理本地树。",
              "iOS 发送按钮在发送或上传时显示 spinner，并停止底部状态文字闪烁。",
            ],
          },
          {
            title: "发布说明",
            items: [
              "协议仍为 4.0，本版本无 state migration；已拥有 pane groups 的 Host 会保留它们。若已安装 0.15.0，请在 Desktop 上先升级到 0.16.0 再使用分屏。",
              "本地打包使用现有 Apple Development 签名且未 notarize；归档仅适合内部或临时测试。",
            ],
          },
        ],
      },
      {
        version: "0.15.0",
        dateISO: "2026-09-16",
        date: "2026 年 9 月 16 日",
        title: "Warren 让分屏布局持久化，也让搜索在各端一致。",
        summary:
          "次版本：将分屏终端布局变为可由任意客户端渲染的 Host 持久状态，在 Desktop、iOS 与 Web 之间共享同一套搜索引擎，并把切换可见 pane 从冷附加变为 reparent；JSON 控制协议仍为 4.0。",
        sections: [
          {
            title: "新增",
            items: [
              "将分屏布局变为 Host 持久状态：一个 Workspace 或 Terminal Group 可容纳多套布局，`warren pane` 可列出、创建、分屏、关闭、重命名、移动和删除。",
              "在 Desktop、iOS 与 Web 之间共享同一套搜索引擎，排序规则与 `w:`/`p:`/`s:`/`t:`/`g:`/`@blocked` 语法一致，结果行以 provider 自身标识开头。",
              "为 zsh 和 fish 注入 OSC 7 工作目录钩子，让 pane 标题、Tab 与侧边栏跟随 `cd`。",
              "跨端共享 Session 标签规则，为 `warren session list` 增加 `RUN` 与 `CWD` 列，并用独立的 roster delta 推送前台元数据。",
              "在 iOS Agent transcript 中支持 GFM markdown callout。",
            ],
          },
          {
            title: "调整",
            items: [
              "每个窗口只渲染当前作用域的一套布局，可用 Cycle Pane Group（⌘`）与 Previous Pane Group（⇧⌘`）切换。",
              "在 pane bar 中把同一分屏组的 Session 聚为一段连续且带标签的区段，避免有 Tab 落在组内。",
              "富模式 workspace 行不再单击导航；悬停点亮所属组的导轨，双击在该 workspace 新建 Session。",
              "侧边栏 Session 叶子显示运行命令与目录，shell 尚未上报 OSC 7 时回退到启动目录。",
              "所有 retained surface 统一走 promotion，选中可见 pane 变为 reparent，而非重新装载快照。",
              "预热 surface 上限提升到 32 个、字节上限提升到 3 GiB。",
              "为 iOS 聊天加入流式节流、markdown 布局缓存，并让发送不再重渲染整段 transcript。",
            ],
          },
          {
            title: "修复",
            items: [
              "在浏览其他 Session 时保持分屏组显示，并在其 Session 出现后立即落地待完成的分屏。",
              "让每个关闭命令作用于其 chip 所属的布局，并停止删除 Host 尚未见过的本地布局。",
              "将 PTY resize 与 focus 视口移出连接 reader，慢 resize 不再阻塞同一连接上的后续命令。",
              "恢复原生渲染器已消失的 retained surface，并把恢复出来的 Agent turn 视为基线而非新完成。",
              "修复 iOS 相册选择器弹出、输入法丢字与逐键延迟，以及紧凑聊天气泡换行和发送时的滚动/底部栏过渡。",
            ],
          },
          {
            title: "发布说明",
            items: [
              "协议仍为 4.0，`pane-group.*` 方法由 `pane-groups-v1` capability 保护，Host state 以追加方式升至 schema 4。请在 Host 滚动升级场景下验证 Host 托管的分屏组。",
              "预热 surface 预算使最坏情况的 retained pool 约为 2-3 GB；请关注长时间运行且打开大量 Session 的 Desktop 内存占用。",
              "本地打包使用现有 Apple Development 签名且未 notarize；归档仅适合内部或临时测试。",
            ],
          },
        ],
      },
      {
        version: "0.14.0",
        dateISO: "2026-09-14",
        date: "2026 年 9 月 14 日",
        title: "Warren 带来原生分屏终端与更完整的 Usage 分析。",
        summary:
          "次版本：为 Desktop、Web 与 Headless 新增原生分屏终端、历史 Usage 分析、面向 thread 的侧边栏组织方式，以及带运行时信息的 Session 标题；JSON 控制协议仍为 4.0。",
        sections: [
          {
            title: "新增",
            items: [
              "新增原生 AppKit 分屏终端，支持拖拽放置、每个 pane 独立 PTY 尺寸与 screen report。",
              "从历史 transcript 重建 Usage，提供按天、Agent、模型和项目的明细、可选热力图、日内曲线与缓存获取。",
              "新增面向 thread 的侧边栏模式，让 Sessions 成为叶子，并支持 Task 置顶、Projects/Workspaces 卡片和快速 setup script。",
              "在 pane 标题、Tab 和侧边栏显示 Session 的 foreground command line 与 OSC 7 工作目录。",
            ],
          },
          {
            title: "调整",
            items: [
              "将 pane 关闭操作视为 Session 命令：关闭单个、其他或全部 pane 会结束其中显示的 Session。",
              "将 Desktop Settings 与 Usage 重构为分类侧栏、双栏布局和 grouped cards，并改进排版与侧边栏树形导轨。",
              "把启动工作、Relay device 列表、state store 读取和 loopback handoff 移出 terminal attach 路径，提升重连可靠性。",
              "移除 Web 客户端的 Tasks 区域；Task 管理仍保留在 Desktop 和 CLI。",
            ],
          },
          {
            title: "修复",
            items: [
              "让 Session 在替换 transcript 写入磁盘前继续绑定旧 Agent conversation，避免过期标题覆盖当前会话。",
              "修复 fetch 进行期间的 Usage 范围变更丢失问题，并将 token 缺失提示限定在请求范围内。",
              "提高 terminal search 高亮对比度，并在查找输入框使用 Menlo。",
            ],
          },
          {
            title: "发布说明",
            items: [
              "本版本没有控制协议版本变化或 state schema migration；请在干净 Host 上验证分屏焦点与关闭行为、Usage 历史重建和 OSC 7 标题。",
              "本地打包使用现有 Apple Development 签名且未 notarize；归档仅适合内部或临时测试，不适合面向公众分发。",
            ],
          },
        ],
      },
      {
        version: "0.13.0",
        dateISO: "2026-09-11",
        date: "2026 年 9 月 11 日",
        title: "Warren 让 Host 可被发现，也让工作流支持多 Host。",
        summary:
          "次版本：新增局域网 Host 发现、Host 主动配对、多 Host 导航和 iOS Host 管理，同时增强 macOS、iOS、Web 与 Headless 的统一 Agent 投影和终端恢复；JSON 控制协议仍为 4.0。",
        sections: [
          {
            title: "新增",
            items: [
              "新增 mDNS/DNS-SD Host 发现、稳定 Host 身份、候选地址探测、直连 LAN 路由，以及对变化中的网络地址做 endpoint 聚合。",
              "新增 Host 主动开启的 LAN 配对流程，使用短时 PIN 和受限客户端凭据；发现 Host 本身不会授予访问权限。",
              "新增支持多 Host 的 Desktop 导航，按 Host 作用域展示 Project 与 Workspace，支持 endpoint 显示名、活动会话过滤、更清晰的空状态和 Task 导航。",
              "新增 iOS Host 管理，支持局域网发现、直连 LAN 与 Relay 路由选择、二维码/PIN 配对、Agent 历史刷新和更完整的 Agent 卡片。",
              "在 Workers Analytics Engine 记录匿名 onboarding 下载开始事件，包含 release、visitor、platform、location、language 和 referrer 维度。",
            ],
          },
          {
            title: "调整",
            items: [
              "让 Desktop、Web、CLI 与 iOS Agent 界面统一使用 canonical projection，并规范 plan event、compaction summary、provider markup、diff 和旧 read response。",
              "让 transport 与 sidebar 状态显式携带 endpoint 身份，确保 focus、resize、路由和资源选择始终作用于正确的 Host。",
              "稳定 terminal sidebar 与 embedded editor 状态，改进 attach/reconnect 行为并保留 Workspace 上下文。",
            ],
          },
          {
            title: "修复",
            items: [
              "修复 output reset 导致终端连接丢失的问题，并防止过期 layout generation 误认 focus claim 或 resize。",
              "将关联 Task 的 Workspace 导航到可操作的 Task 行，并区分不可用 Host、仅活动过滤和没有 Project 的 Host。",
              "修复 embedded editor 在呈现和导航变化中丢失 Workspace 状态的问题。",
            ],
          },
          {
            title: "发布说明",
            items: [
              "LAN 发现只提供可达性，不代表信任。必须在 Host 上显式开启配对；LAN 不可用时仍可使用已有 Relay/直连 endpoint。",
              "本版本没有控制协议版本变化或 state schema migration；发布前必须在真实设备上验证直连 LAN 配对、多 Host 路由和 iOS 局域网权限。",
            ],
          },
        ],
      },
      {
        version: "0.12.2",
        dateISO: "2026-09-09",
        date: "2026 年 9 月 9 日",
        title: "Warren 让远程 Host 更容易理解，也更容易恢复。",
        summary:
          "修复版本：改进远程 Host 诊断与兼容性处理，增强 Agent 交互上下文保留，并稳定终端 attach。覆盖 macOS、Web 与 Headless，iOS 变化不在本次发布范围内。",
        sections: [
          {
            title: "新增",
            items: [
              "为直连 endpoint 增加提示性的 Host health probe，并在 Desktop Execution Server 菜单显示可达性、Headless build、协议状态和连接错误，同时提供手动“检查 Host”。",
            ],
          },
          {
            title: "调整",
            items: [
              "延长 Relay 与远程 WebSocket handshake 等待时间，适应较慢的 DNS、TLS、代理和移动网络协商。",
              "保留 Codex question schema，并通过 provider-neutral interaction response 暴露可选备注和已完成答案标签。",
              "让 terminal attach 与 focus reconciliation 按 generation 安全处理，合并重复 attach，并减少呈现过程中的重复 layout。",
              "缓存 Desktop 菜单重复打开时的外部 IDE 发现结果。",
            ],
          },
          {
            title: "修复",
            items: [
              "Host 报告协议或 terminal-state format 不兼容时停止无效重连，同时保留瞬时故障的重试行为。",
              "按 request 或 interaction identity 匹配已完成 Agent interaction，让 replay response 保留原始问题和选项。",
            ],
          },
        ],
      },
      {
        version: "0.12.1",
        dateISO: "2026-09-08",
        date: "2026 年 9 月 8 日",
        title: "Warren 让 Agent 工作流更稳定、更可预测。",
        summary:
          "修复版本：提升 Agent 交互可靠性、跨客户端控制流、Task 与 Workspace 导航、外部 IDE 发现和 embedded editor 排版。本版本覆盖 macOS、Web 与 Headless，iOS 变化不在发布范围内。",
        sections: [
          {
            title: "调整",
            items: [
              "统一 Agent View 操作不再争抢终端 PTY control lease，Web 与 Headless Agent 操作不会再和终端焦点互相阻塞。",
              "Web Agent 将模型与推理选项保持在启动时或 provider 配置中，不再发送 session 内切换命令。",
              "缓存外部 IDE 选项，统一 embedded editor 与原生编辑器的排版，并让关联 Task 的 Workspace 保持在 Task 导航下。",
              "避免侧边栏无必要的居中滚动，在 Desktop 与 Web 中明确 Workspace 的选择状态，并让禁用的 Workspace 行保持安静的视觉状态。",
            ],
          },
          {
            title: "修复",
            items: [
              "按 option index 解析结构化 question 响应，覆盖多选键盘导航、自定义答案与多步骤交互。",
              "避免 Agent 交互提交被终端控制权或过期 loading 状态卡住。",
            ],
          },
        ],
      },
      {
        version: "0.12.0",
        dateISO: "2026-09-08",
        date: "2026 年 9 月 8 日",
        title: "Warren 引入统一 Agent 执行协议与 Relay 控制面。",
        summary:
          "次版本：JSON 控制协议升级到 4.0，为 Codex、Claude、OpenCode、Pi、Qoder 与 Antigravity 提供持久化的统一 Agent 执行模型，并将 Relay 独立为控制面。Host state schema 1/2 原地升级到 schema 3；4.0 之前的客户端与 Ghostline v0 socket 不兼容。面向 arm64 macOS 13+，Public Access 使用 Relay 路由。",
        sections: [
          {
            title: "新增",
            items: [
              "新增统一 Agent 事件、幂等 command journal、历史恢复、结构化交互、队列、附件、目标与模型/推理控制。",
              "新增 Codex、Claude、OpenCode、Pi、Qoder、Antigravity 的统一 Agent provider；Trae 仍是交互式 shell preset。",
              "新增 Relay enrollment key、opaque 分享链接、签名 capability、refresh token、设备撤销与 IP/path 路由。",
              "新增 embedded SSH endpoint、内置转发 helper，以及默认在 embedded editor 中打开终端链接。",
              "新增更安全的 Task、Workspace、Session 操作，包括排序、worktree 导入、MRU 导航、preflight 与受保护 undo。",
            ],
          },
          {
            title: "调整",
            items: [
              "终端恢复改用原子 DENB 状态快照、持久化 Ghostline cursor，并支持兼容 Ghostline v1 runtime 的 rolling handoff。",
              "CLI list 与 transcript 默认限制输出；自动化场景请显式使用 --all、--full、--tool-output、过滤、quiet 或截断参数。",
            ],
          },
          {
            title: "不兼容变更",
            items: [
              "JSON 控制协议升级到 4.0，移除旧 Agent alias、JSON input fallback、旧 session lifecycle、Ghostline v0 bridge 与 legacy PTY alias。",
              "Host 与客户端必须一起升级到 0.12.0；4.0 之前的客户端会在认证阶段被拒绝，Ghostline v0 socket 需要重建。",
            ],
          },
          {
            title: "RFC",
            items: [
              "随版本收录 RFC 0012、0013、0014、0015、0016、0017、0018、0019，并保留各自 proposed、draft 或 implemented 状态。",
            ],
          },
        ],
      },
      {
        version: "0.11.3",
        dateISO: "2026-08-30",
        date: "2026 年 8 月 30 日",
        title: "Warren 让 Codex Working 明显闪烁。",
        summary:
          "修复版本：新增可见的 Working 闪烁指示器，在快照恢复后保持终端颜色配置，并在 Web 界面统一标记被中断的 agent 消息。面向 arm64 macOS 13+，Public Access 使用 Relay 路由。",
        sections: [
          {
            title: "调整",
            items: [
              "Codex 正在生成输出时显示可见的 Working 闪烁指示器。",
              "原生快照恢复后重新应用 Warren 的终端颜色配置，确保 Working 输出保持可见。",
            ],
          },
          {
            title: "修复",
            items: ["在 Web 界面统一标记被中断的 agent 消息。"],
          },
        ],
      },
      {
        version: "0.11.1",
        dateISO: "2026-08-29",
        date: "2026 年 8 月 29 日",
        title: "Warren 加固端点切换与 Public Access 状态。",
        summary:
          "修复版本：加固端点切换、重启后保持 Public Access 状态、修复网页链接鉴权与移动端滚动，并在 Linux 上改进 terminfo 安装。面向 arm64 macOS 13+，Public Access 使用 Relay 路由。",
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
              "重启后通过已持久化的 Relay 路由元数据保持 Public Access 状态。",
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
          "次版本：内置 xterm-ghostty truecolor，收紧 warm promotion 与 resize 渲染，并加固 Ghostline handoff 与工作区创建。面向 arm64 macOS 13+，Public Access 使用 Relay 路由。",
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
          "超级重大版本：升级到不兼容的 Ghostline 运行时语义，自动迁移已有会话；不支持不重建会话的回退。面向 arm64 macOS 13+，Public Access 使用 Relay 路由。",
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
        title: "Warren 完成 Relay 路由支持。",
        summary:
          "维护版本：Public Access 对齐 Relay 路由，并保持 onboarding 首屏停留在顶部，只有明确请求时才进入终端演示。",
        sections: [
          {
            title: "调整",
            items: [
              "让 Public Access 路由生命周期与 Relay 协议保持一致。",
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
              "通过自托管 Relay 新增 Public Access，支持在设置中 Save & Test、使用 pairing 完成注册、控制生命周期、重启恢复，并报告不含凭据的公共 Endpoint。",
              "新增面向 Agent 的 CLI 命令，支持 Codex 和 Claude Agent 的创建、列表、读取、发送、等待、附加和明确定位；支持规范化 Transcript 读取与有界 turn 等待。",
              "新增跨 Host、Web、Desktop 和 CLI 的统一 Agent 活动与人工关注状态，并汇总到 Workspace 和 Terminal Group。",
              "新增范围明确的 warren://terminal 与 Web 链接，可定位 Project、Workspace 和 Session；新增可预填 Public Access 的 warren://settings 链接。",
              "新增有界桌面通知中心、未读与静音控制、紧凑 Workspace More 菜单，以及适用于非终端输入框的 Unix 编辑快捷键。",
            ],
          },
          {
            title: "调整",
            items: [
              "使用 Relay 路由元数据和范围明确的 capability，不再打包本地访问 worker。",
              "让 Agent、roster、Terminal 和 Transcript 投影保持明确且有界，并在响应式 Chrome 与通知出现时保持终端尺寸稳定。",
              "按发布 tag 滚动升级 Ghostline，并要求可分发的 macOS 构建使用稳定代码签名。",
            ],
          },
          {
            title: "修复",
            items: [
              "强化 Public Access Relay 注册、路由生命周期恢复、密钥处理、设置默认值和显式浏览器认证链接。",
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
