import { createContext, useContext, useEffect, useMemo, useState } from "react";

const messages = {
  en: {
    "nav.label": "Sections",
    "nav.howItWorks": "How it works",
    "nav.demo": "Demo",
    "nav.changelog": "Changelog",
    "nav.download": "Download",
    "download.loading": "Getting latest…",
    "download.ready": "Downloading…",
    "download.fallback": "Opening releases…",
    "hero.titleA": "Quit the app.",
    "hero.titleB": "Your agents keep working.",
    "hero.lede":
      "Warren runs your terminals and coding agents on your own Mac or server. The desktop app, a browser and your phone are all windows onto the same running sessions, so closing one never stops the work.",
    "hero.download": "Download for Mac",
    "hero.source": "View source",
    "hero.requirements": "macOS 13+ · Apple silicon · Host also runs on Linux",
    "hero.shotAlt":
      "Warren on macOS: a Claude conversation in a workspace, with the project sidebar on the left and the Inspector showing uncommitted changes on the right",
    "anywhere.title": "Same session on every screen.",
    "anywhere.lede":
      "The Host owns the session. Open it from the desktop, a browser or your phone and you land on the same conversation, scrolled to the same answer.",
    "anywhere.browser": "Browser",
    "anywhere.soon": "Coming soon",
    "anywhere.browserAlt":
      "Warren in a web browser showing a Claude conversation about resuming ACP agents after a Host restart",
    "anywhere.phoneAlt": "The same Claude conversation in the Warren iPhone app",
    "anywhere.note":
      "Both screenshots show one Claude session on one Mac. The code block and the 13:39 timestamp are the same message.",
    "lifecycle.title": "Only closing the tab ends a session.",
    "lifecycle.lede": "Everything else is just walking away. The whole product is built on this rule.",
    "lifecycle.label": "What happens to a running session",
    "lifecycle.running": "keeps running",
    "lifecycle.ends": "ends",
    "lifecycle.rows": [
      {
        action: "Quit Warren",
        why: "Open the app again and the terminal is where you left it, scrollback included.",
      },
      {
        action: "Lose Wi-Fi or close the lid",
        why: "The client reconnects when the network returns, and output produced meanwhile is replayed.",
      },
      {
        action: "Switch workspace",
        why: "Each workspace keeps its own tabs. Switching back shows them as they are now.",
      },
      {
        action: "Restart the Host",
        why: "Agents run in a detached holder. The next Host reattaches and picks up a prompt still in progress.",
      },
      {
        action: "Close the tab",
        why: "The one deliberate way to stop a session and its process.",
        ends: true,
      },
    ],
    "demo.title": "See it, then try it.",
    "demo.lede":
      "A film recorded in the real apps, and the desktop's terminal engine running here in your browser.",
    "film.play": "Play film",
    "film.caption":
      "Four agents messaging each other, a quit and a return, a reply from the phone, two Hosts in one sidebar.",
    "terminal.title": "Terminal",
    "terminal.loading": "Loading Ghostty…",
    "terminal.error": "The terminal engine could not load in this browser.",
    "terminal.captionA": "Click in and type ",
    "terminal.captionB": ". It talks to a fake Host, but the terminal is the real one.",
    "details.title": "What's in it.",
    "details.items": [
      {
        title: "Terminal, agent and editor in one workspace",
        body: "A real terminal, a structured view for Claude, Codex and OpenCode, and a VS Code compatible editor beside them.",
      },
      {
        title: "Worktrees and cross-repo tasks",
        body: "Main checkouts and Git worktrees are first class. A task can group workspaces from several repositories.",
      },
      {
        title: "Your Mac or your server",
        body: "Run the Host locally or on a VPS, and switch between Hosts from one sidebar.",
      },
      {
        title: "Faithful terminal output",
        body: "Ghostty on the desktop, xterm.js on the web. Colors, Unicode and full-screen TUIs render as they should.",
      },
      {
        title: "One model on every client",
        body: "Projects, workspaces and sessions are the same objects on desktop, web and CLI.",
      },
      {
        title: "Reachable when you choose",
        body: "Nothing is exposed by default. Turn on Public Access through your own Relay when you want the web client from outside.",
      },
    ],
    "how.title": "How it connects.",
    "how.lede": "Every client speaks the same WebSocket protocol to one daemon, and the daemon owns the sessions.",
    "how.clients": ["macOS app", "Browser", "CLI"],
    "how.host": "your Mac or server",
    "how.session": "session",
    "how.store": "durable store",
    "how.note": "SSH and the Relay only make the Host reachable. They never store terminal output or input.",
    "close.title": "Start something long. Then close the laptop.",
    "close.changelog": "Read the changelog",
    "close.license": "Source available under FSL-1.1-ALv2",
    "footer.label": "Footer",
    "footer.license": "License",
    "changelog.title": "Changelog",
    "changelog.lede": "What changed in each release of Warren.",
    "changelog.viewRelease": "View release",
    "changelog.releaseTitle": "Warren release",
    "changelog.stale": "Showing the last cached changelog; the repository could not be reached.",
    "changelog.error": "The changelog is temporarily unavailable. View the repository instead.",
    // Offline fallback; live entries come from the repository changelog API.
    "changelog.entries": [
      {
        version: "0.34.1",
        dateISO: "2026-10-27",
        date: "October 27, 2026",
        title: "Warren gives a shell row its command and the sidebar one right edge.",
        summary:
          "A patch release that finishes the new Desktop sidebar: a plain shell row leads with the command it runs, its second line says where and how it went, every row ends at one right edge, worktrees with Sessions come first, and branch names keep a readable ink on the dark Ember sidebar. The JSON control protocol remains at 4.0 and this release migrates no state.",
        sections: [
          {
            title: "Changed",
            items: [
              "Lead a plain shell's sidebar row with the command it runs or last ran, and its directory before anything runs. The second line says where it runs relative to the worktree and whether it is running, done, stopped, or failed with an exit code; the Tab and pane header keep naming where the shell is, and a name the user gave still wins.",
              "End every Session's second line at the age column so rows share one right edge, draw project names a half step larger, and keep the bright title ink for Sessions that are working, waiting, or failed.",
              "Space the tree in four steps - 0 inside a block, 2 between one-line summaries, 10 between blocks, and 20 between projects and Tasks - and order worktrees with Sessions first.",
              "Seat branch rows closer to their Sessions in a quieter 11pt face, fade a long branch instead of cutting its prefix, give every chevron one column, and drop a lone default branch from its project row.",
              "Show the pin and Task link on hover only, keep an inactive row's avatars as plain swatches, and let a Task lead with a drawn flag. A project whose worktrees all belong to Tasks now says so and leads to the Tasks tab.",
            ],
          },
          {
            title: "Fixed",
            items: [
              "Give the dark sidebar's branch names their own ink, so a branch and its prefix stay legible on Ember instead of sitting below 3:1 contrast.",
              "Lift the pi tile off its card.",
            ],
          },
          {
            title: "Release notes",
            items: [
              "The JSON control protocol remains at 4.0 and this release migrates no state.",
              "Local packaging uses the available Apple Development signing identity and is not notarized; the archive is suitable for internal or temporary testing, not general public distribution.",
            ],
          },
        ],
      },
      {
        version: "0.34.0",
        dateISO: "2026-10-26",
        date: "October 26, 2026",
        title: "Warren runs work on a schedule and shows a Lead's Crew.",
        summary:
          "A minor release that lets a Host run Agent prompts and commands on a cron or one-off schedule, keeps a stopped Session's last output and resumes it from its Tab or all at once, presents a Lead Agent's references, decisions, checks and Crew on the Conversation, splits the Desktop sidebar into Projects and Tasks tabs with a new rhythm and ink ladder, and asks before installing a mounted disk image. The JSON control protocol remains at 4.0 with additive `session.history`, `session.resume`, and `schedule.*` methods, and this release migrates no state.",
        sections: [
          {
            title: "Added",
            items: [
              "Run Agent prompts and commands on a Host schedule with `warren schedule create|list|view|remove|pause|resume|run|runs`: a cron expression or one instant in the Host's local time zone, kept in `schedules.json` across daemon restarts. An agent action starts one turn and holds the prompt while the Agent is mid-turn; a command action runs a new shell Session in a Workspace. `--provider` creates a fresh Agent per run, with `--when-busy` and `--keep N` to bound the runs.",
              "Keep a stopped Session: the Host records why it ended, retains its last output through `session.history`, and shows it as a quiet Tab with Resume for an Agent or Restart in the same directory for a shell. A stopped banner's Resume All resumes the Session on screen first, then the others in place.",
              "Present a Lead Agent's markers as structure: `#agent` references become inline Session capsules, `#ask` a decision panel, `#accept` a checklist, and its Crew a strip on the Conversation. A LEAD word marks the Session and only an unanswered request raises the attention dot.",
              "Split the sidebar into Projects and Tasks tabs with their counts, a waiting dot for the hidden list, the add action and the fold-all action.",
              "Ask before installing a mounted disk image: the window names the image's version beside the installed one, says whether it is newer, the same or older, and spells out a downgrade.",
            ],
          },
          {
            title: "Changed",
            items: [
              "Give the sidebar four steps of rhythm and a five-step ink ladder: Agent rows at 44pt, a plain shell on one 28pt line, branch labels at 11.5pt, Task and project tiles, and sentence-case section headings with a quiet count.",
              "Draw group names at one optical size per script, with wide scripts half a step down, and read a tooltip's anchor when it opens instead of on every scroll frame.",
              "Shape the provider permission dock like the Lead's panels: the attention hue is only the eyebrow's dot, choices are rows, and one filled default action.",
              "Drop the sample-session chip from the web hero.",
            ],
          },
          {
            title: "Fixed",
            items: [
              "Resolve `warren project add PATH` at the client, so `.`, `..`, and `~/repo` name the repository the user meant.",
              "Open a stopped Session from its sidebar row, draw its title in the quiet ink, and put a resumed Session in the stopped Tab's place.",
              "Keep Task links and worktrees marked by a quiet badge, keep a Task's long external ID in its tooltip, and overlay Agent message actions without shifting the layout.",
              "Show provider diagnostics as quiet warnings, align the composer caret with its placeholder, and keep Lead replies and Tab titles distinct.",
              "Refuse a second resume writer inside the state transaction, so two clients cannot resume one conversation into two running Sessions.",
              "Stop re-measuring the window and rebuilding sidebar rows on every scroll frame, and pause sidebar hover while it scrolls.",
            ],
          },
          {
            title: "Release notes",
            items: [
              "The JSON control protocol remains at 4.0; the Host adds `session.history`, `session.resume`, and `schedule.*` methods, and the Host state schema is unchanged. This release migrates no state.",
              "Local packaging uses the available Apple Development signing identity and is not notarized; the archive is suitable for internal or temporary testing, not general public distribution.",
            ],
          },
        ],
      },
      {
        version: "0.33.0",
        dateISO: "2026-10-21",
        date: "October 21, 2026",
        title: "Warren stops a turn the way the provider expects.",
        summary:
          "A minor release that stops an Agent's running turn from the CLI and from the Desktop with the key its provider reads as \"stop\"; a restarted Host serves its roster at once instead of after the Agent journal opens; a workspace branch counts as merged only when it has commits of its own and the default branch contains them; and the product film, screenshots and onboarding page show the current Desktop. The JSON control protocol remains at 4.0 and this release migrates no state.",
        sections: [
          {
            title: "Added",
            items: [
              "Stop an Agent's running turn from the CLI with `warren agent cancel AGENT_ID [--current] [--wait]`. The Host drives the provider's own interrupt, so a terminal Agent and a protocol-driven Agent are both stopped the way they expect, and `--wait` reports the turn once it actually ends.",
            ],
          },
          {
            title: "Fixed",
            items: [
              "Serve the first roster right after a Host restart instead of waiting for the Agent journal, which used to block every client for about five seconds on a cold start.",
              "Report a workspace branch as merged only when it has commits of its own and the default branch contains them.",
              "Stop a pi or Codex Agent with the key it reads as \"stop the turn\", and end a turn pi reports as stopped instead of leaving the Agent working.",
              "Keep `warren agent wait` on the turn that is running.",
            ],
          },
          {
            title: "Changed",
            items: [
              "The onboarding film is re-cut from the current Desktop, with camera moves over real pointer work: hovering the tree, switching Tabs, splitting the stage from the top bar, folding the sidebar away, switching Host, the Inspector's changes, a browser an Agent drives, and the same Session in the browser and on the phone.",
              "The README and the onboarding page show screenshots from the same build.",
            ],
          },
          {
            title: "Release notes",
            items: [
              "The JSON control protocol remains at 4.0 and this release migrates no state.",
              "Local packaging uses the available Apple Development signing identity and is not notarized; the archive is suitable for internal or temporary testing, not general public distribution.",
            ],
          },
        ],
      },
      {
        version: "0.32.0",
        dateISO: "2026-10-20",
        date: "October 20, 2026",
        title: "Warren installs from a disk image.",
        summary:
          "A minor release that ships a drag-to-install disk image, and opening a newer one installs it and restarts the app; the Command+K search panel is redrawn to the Workbench spec; iPhone Host reachability, pairing, and Relay fallback are fixed, and the Desktop recovers SSH and Relay connections after sleep, a network change, or a token refresh. The JSON control protocol remains at 4.0 and this release migrates no state.",
        sections: [
          {
            title: "Added",
            items: [
              "Download Warren as a disk image. Its window shows where to drag the app and how to approve the first launch in Privacy & Security. The zip stays in each release for the in-app updater.",
              "Install a downloaded disk image without dragging or a second approval. When Warren is running, opening a newer Warren disk image brings Warren forward, checks that the app is signed by the same developer, installs it, ejects the disk image, and restarts Warren.",
            ],
          },
          {
            title: "Changed",
            items: [
              "Draw the Command+K search panel like the rest of the Workbench: the dialog surface at 600 points, a larger search field, menu-style rows with the app icon each Session wears on its Tab, and a key-hint bar that also lists the scope filters.",
            ],
          },
          {
            title: "Fixed",
            items: [
              "Show each Launch Commands preset in Settings with the app icon the + menu, Tabs and sidebar use, instead of the older bare logo.",
              "Say why a Host cannot be reached on iPhone. Once a loss outlasts the grace period, the Inbox and the Session title show the reason, such as \"Mac is offline · last seen 3 minutes ago\", and a first load that cannot connect says so instead of showing placeholder rows.",
              "Ask for a new pairing code when a Host no longer accepts a device. A removed device or a reset pairing used to retry forever while the app said it was waiting for the Mac; the iPhone and the Desktop now stop and say to pair again.",
              "Keep a device paired when a Relay token refresh loses its reply on a weak network. Relay accepts the same refresh again for 60 seconds instead of revoking the device.",
              "Fall back to Relay on iPhone when the phone leaves the Host's network, even with automatic LAN switching off, and return to the same LAN address when it answers again. Editing a Host no longer switches it to its LAN address.",
              "Name Hosts paired over Relay after the Host instead of \"Warren Host\", keep a second Host's pairing code from joining the first Host, and keep every saved credential when a Host is renamed.",
              "Show pairing progress and failures in the iPhone Hosts list, and whether each saved Host answers on this network or when it last connected. Switching Hosts shows the new Host at once.",
              "Recover SSH Hosts on the Desktop after sleep or a network change. The SSH connection sends keepalives, a dead tunnel is rebuilt, and sidebar Hosts that could not connect retry on their own.",
              "Keep a Desktop Relay connection when its token refreshes instead of reconnecting it.",
              "Reconnect a Host to Relay as soon as its Mac wakes instead of waiting out the rest of its backoff.",
              "Keep terminal output aligned while a split pane resizes. The Desktop changes a terminal's grid only at the output position where the Host reports the PTY actually resized, so text written for the old width is never drawn on the new grid and the pane no longer shows garbled rows.",
            ],
          },
          {
            title: "Release notes",
            items: [
              "The JSON control protocol remains at 4.0 and this release migrates no state.",
              "Local packaging uses the available Apple Development signing identity and is not notarized; the archive is suitable for internal or temporary testing, not general public distribution.",
            ],
          },
        ],
      },
      {
        version: "0.31.0",
        dateISO: "2026-10-19",
        date: "October 19, 2026",
        title: "Warren answers Agents sooner over a slow link.",
        summary:
          "A minor release that removes fixed waits from the Agent path: the transcript watcher reads at 50ms after input and while a turn works, PTY submission continues as soon as the TUI echoes and goes quiet, and the new opt-in `output-ack-v1` capability bounds terminal output in flight to about one round trip. It also counts waiting Agents on the Dock icon and posts a macOS notification while Warren is in the background. The JSON control protocol remains at 4.0 and this release migrates no state.",
        sections: [
          {
            title: "Added",
            items: [
              "Bound terminal output in flight with `output-ack-v1`. A client that negotiates the capability acknowledges received output with `session.ack`; the Host keeps about one round trip plus 200ms in flight and pauses the reader beyond that, so a keystroke echo or Agent event is no longer stuck behind seconds of queued PTY output on a slow link. A reader held back for over a second skips its backlog and receives a fresh terminal state in place, instead of the connection closing for a re-anchor.",
              "Tell a person away from the window that an Agent is waiting. The Desktop counts the current Host's waiting Sessions on the Dock icon, posts one macOS notification per new request while Warren is in the background, lets an approval be allowed or rejected from the notification, and withdraws the notification once nobody is asking. Settings > Notifications has a switch for each.",
            ],
          },
          {
            title: "Changed",
            items: [
              "Answer Agent messages without fixed waits. The transcript watcher reads at 50ms right after input and while a turn is working, then back at 500ms when idle, and PTY submission continues once the TUI has echoed the input and gone quiet, still capped at 300ms. Codex's queue poll stays on the idle cadence.",
              "Open an iOS Agent Session without terminal output. The Agent view subscribes to the Agent stream directly and no longer carries TUI redraws it never shows; the terminal stream attaches when the user switches to the terminal.",
              "Name a Session the same way on every client. The kind promotion moves into `SessionTitle`, iOS resolves with the owning Workspace's path, and the roster carries `resultSentence` so the iOS Inbox row says what a finished Agent did. A new iOS Agent Session is named New Session.",
              "Cut Relay round trips on resume, reconnect, and session switch: an expiring access capability is refreshed before dialing, the Session holding the control lease is restored first, the resume probe ceiling grows with measured round trips, and iOS sends the old unsubscribe alongside the new subscribe.",
              "Say Host instead of server or endpoint in Desktop copy.",
            ],
          },
          {
            title: "Fixed",
            items: [
              "Keep a slow Relay stream from stalling the Host socket. Each stream drains its own bounded inbound queue, and a delivery failure closes only that stream instead of reconnecting every client; the connector also probes the Relay right after the machine wakes from sleep.",
              "Close races in output flow control and Relay streams: record output as sent before enqueueing it, allow a held-back reader 1s plus two round trips before skipping its backlog, let a backlog skip yield to a subscribe already in flight, check and clear the terminal attachment atomically, and queue a Relay CLOSE behind undelivered body frames.",
              "Keep the iOS terminal reachable after opening a Session in the Agent view.",
              "Keep a panel that rises above its anchor inside the window.",
            ],
          },
          {
            title: "Release notes",
            items: [
              "The JSON control protocol remains at 4.0 and this release migrates no state. It adds the opt-in `output-ack-v1` capability; a client that does not negotiate it behaves as before.",
              "Local packaging uses the available Apple Development signing identity and is not notarized; the archive is suitable for internal or temporary testing, not general public distribution.",
            ],
          },
        ],
      },
      {
        version: "0.30.0",
        dateISO: "2026-10-19",
        date: "October 19, 2026",
        title: "Warren rebuilds the Desktop workbench.",
        summary:
          "A major release that rebuilds the Desktop workbench — sidebar, top bar, menus, the conversation pane, and a separate Settings window — around what a Session is really doing: a shell's own prompt state, an agent's own conversation name, and one row per running subagent. Terminal Groups are removed, so every Session now belongs to a Workspace. The JSON control protocol remains at 4.0 and this release migrates no state.",
        sections: [
          {
            title: "Added",
            items: [
              "Let a Host record per-provider ACP server commands in `~/.warren/settings.json` (`acpCommands`). A Chat Session created without an explicit command now uses that entry, so Desktop, Web, iOS, and `warren agent create --agent-handler acp` can route chat through an ACP server that carries the provider's credentials instead of the built-in adapter resolved from `PATH`. An explicit request `command` still wins, and an empty entry keeps the built-in.",
              "Give every Session row the same two lines. A row no longer changes height as turns start and end: every row draws what the Session is doing and what it last did and how long ago, with the resting line one colour tier below a working one, a slow highlight on a working Agent's line that Reduce Motion removes, a fade at the tail instead of a truncation glyph, and a chip that counts the subagents a Session is running and opens their rows in place.",
              "Read a shell's prompt state from the shell itself. With OSC 133 marks in the shell integration (zsh and fish), a shell row's title says where it is instead of repeating its command, and its second line says what it is running, what it last ran, and, when that command exited non-zero without being interrupted, its exit code. The state comes from ghostline v1.5.0's `SessionMetadata.Shell`; a shell that reports no marks keeps the foreground-process line it had. A command that starts an agent CLI turns the Session back into an Agent.",
              "Rebuild the conversation pane. Answers occupy the reading column with no bubble; user messages sit in a right-aligned bubble that folds past eight lines; one line carries the turn's work and expands into its steps; thinking collapses to its own line; changed files open in the inspector's Changes tab; and the composer holds attachments, the permission mode, the context figure, and the model beside a send key that becomes a stop key while the agent works. Decisions, plans, and queued prompts stack on the composer, and a decision is the only thing in the pane drawn with the accent colour.",
              "Show what a subagent is doing. Warren tails the child transcripts Claude and Codex write and attaches every event to the child's stable identity (`subagentId`), with `parentCallId` linking the spawn call. A Session shows one row per subagent and the commands it is running, and a subagent's activity never changes the parent Session's status, attention, or turn.",
              "Use the name an agent CLI generates for its own conversation as the Session title. Codex, Claude Code, OpenCode, and Qoder all name the conversation they are running, so Warren reads those names instead of spending a second model call on the same exchange. A name the user set still wins, and a Host-generated name is replaced by the agent's own. Subagent conversations are never used.",
            ],
          },
          {
            title: "Changed",
            items: [
              "Polish the Web client's chrome. The sidebar and tab strips fade their scroll edges with a seven-stop non-linear alpha ramp, structural separators are true hairlines on Retina, compact controls press with a sampled spring, and keyboard focus draws the ring plus a soft accent halo. The sidebar list and both tab strips are single Tab stops now, with the arrows, Home/End, and PageUp/PageDown to walk them.",
              "Shorten what a row reports to the width it has: a path keeps its last segment, a `--flag value` pair either becomes the object it names or goes away, a compound command keeps its first command, and a generated title is bounded by display width with the verb first. A title the user set, and a name an agent generated for its own conversation, are never rewritten.",
              "Unify the sidebar's time format and count vocabulary. Ages read `now / 5m / 2h / 3d / 2w` and then a date; durations read `18s / 3m / 1h`; a turn's counts rank edits, Git writes, commands, fetches, searches, and reads, with unknown tools folded into one `Used n tools`.",
              "Keep the Host's own title request as a fallback for every agent. An agent that names its own conversation gets a 30-second grace period first, a name that arrives later still replaces the Host's title for another minute, and an agent that never names the conversation falls back to the configured LLM request as before. The Settings switch now reads as the fallback it is.",
              "Give every Session one name. The top bar, the sidebar row, a split pane's header, a tab, and the window title now resolve the same `SessionTitle`: the user's name wins, then an Agent's own or generated name, then a kind name, then a custom command's summary, then a shell's location. A shell's running command travels beside the title rather than inside it.",
              "Drop the verb from a shell row's second line. It says only the command now, in the monospaced face, shortened by the same `CommandSummary` the top bar uses.",
              "Let a resting shell's row collapse to one line. Ten minutes after its last command ends — or right away if it never ran — a shell row drops to a 30pt line, and running a command brings the second line back. A failed command stays two lines until the Session has been looked at once.",
              "Make a section's add control a permanent part of its heading. Projects and Tasks always show the small grey `+` left of the fold arrow instead of revealing it on hover.",
              "Slide the selected plate between top-bar tabs. A Tab's selection is the sidebar's fill with a hairline border, and the plate travels on the shared `WarrenMotion.selection` spring instead of fading in place. The tab track no longer sits in an outer capsule.",
              "Put the blocking dialogs on one container. `WarrenDialog` owns the ground, the padding, the title block and the S/M/L widths (400 / 480 / 720), so the rename prompt, the message dialog, and the task, workspace and project delete confirmations draw inside it.",
              "Draw settings in its own window. ⌘, opens one 860×620 window that can sit beside the terminal it changes while the main window stays live. The navigation is 220pt wide with monochrome SF Symbols, settings rows are 44pt tall, and Settings' palette derives every value from the shared tokens.",
              "Give a resting Agent row the Host's result sentence. At the end of a turn the Host asks its title endpoint for one past-tense line describing what the turn did, so a resting row says what happened instead of `Edited 2 files`; when the endpoint is not configured or fails, the row keeps its counts.",
              "Give Settings the shared code chip and a real setup-script editor. `$1`, `$2`, and `WARREN_*` draw as one monospaced code chip, and a project's setup script shows its first line with a `+N lines` marker and an Edit… button that opens the whole script.",
              "Merge the Launch Commands list. One row per preset carries its order, its visibility, and its command on a second monospaced line; clicking the row opens the command editor under it.",
              "Put the editor choice in the Settings editor list. Each row carries the same white checkmark column a single-choice menu uses, and a chosen colour card draws the same white ring a focused field uses.",
              "Let a Launch Commands row be dragged onto another to reorder it; a row that holds the keyboard also answers ⌥↑ / ⌥↓.",
              "Give the Relay connection row its on/off switch. Enrolling a Host keeps it enrolled; the switch only starts or stops the tunnel, so pausing a Relay no longer means resetting the enrollment.",
              "Draw New workspace, New Task, the worktree importer, the Superset importer, and the setup-script editor in the shared `WarrenDialog`, so every blocking flow shares one ground, one padding scale, and keycap buttons.",
              "Give the AI Titles page the shared validated form. Its fields stay a page-local draft, a primary Save & Test saves and checks the endpoint with a spinner, and a Test button (disabled until there is a draft) checks without saving.",
              "Keep the Relay invite and the LAN pairing PIN inline with a countdown bar. The invite's QR no longer opens a popover, and both rows show how much of their window is left as a thin bar under the text.",
              "Rework the Terminal page's previews. The font preview keeps a fixed 132pt height, the pane-title template renders its result right under it behind a ↳, and the placeholder chips show only the placeholder so all nine fit in two rows.",
              "Use the app's own segmented control for the Usage range instead of the system one, so the chart does not borrow the platform accent.",
              "Size Tabs by the room the track has. A Tab is 200pt wide when there are few and narrows evenly down to a 96pt floor; past the floor the track scrolls under its two edge fades and a `⌄ N` control lists every Tab.",
              "Put Public Access's state in a header row: a dot, the address it serves (or not published), and a switch at the tail.",
            ],
          },
          {
            title: "Fixed",
            items: [
              "Stop the sidebar jumping under a shell row's hover card. Hover cards now draw without the menu layer's click-catching scrim and never take the pointer, and a shell row's collapse and expansion animate the rows below it instead of only itself.",
              "Give the chrome's state changes their motion. Menus and hover cards fade in and out, the sidebar's rows move when a Session opens or closes or a Workspace folds, the controls that hovering reveals fade in, the solo pill grows into a shell's running command, and the Hosts heading cross-fades to its count.",
              "Keep a Session's pane arrangement when its activity line changes. The projection copy that updates that line rebuilt every relationship by hand and left the pane groups behind, so an Agent step could erase the Host's split arrangements until the next roster snapshot.",
              "Stop truncating a public response when a route's delivery queue fills. A route's buffer is now bounded in bytes by the sender's whole window, and a per-route delivery goroutine hands frames to the consumer in order, so a full handoff buffer never stalls the tunnel or loses a frame.",
              "Install the managed agent hooks even when the agent CLI has never run, so its configuration directory does not exist yet. Codex, Claude Code, and Qoder were all affected, and the failure was invisible because every developer machine already had those directories.",
              "Stop binding an OpenCode Session to a session OpenCode created to delegate work. Every subagent task runs in its own child session, and Warren treated the newest `session.created` as the conversation the terminal was in. The bind plugin now ignores a child session (`parentID`), discovery only offers root conversations, and a binding that already names a child is repaired to the conversation that owns it.",
            ],
          },
          {
            title: "Removed",
            items: [
              "Remove Terminal Groups, the Host-owned containers (default `Inbox`) for standalone shell Sessions. Every Session now belongs to a Workspace. The `terminal-group.*` methods are gone, the roster no longer carries `terminalGroups`, `session.create` requires a `workspace`, and the CLI drops the `warren terminal-group` resource and every `--group` flag. The Web client, search, and docs drop the group surface, and the Raycast extension is removed.",
            ],
          },
          {
            title: "Release notes",
            items: [
              "The JSON control protocol remains at 4.0 and this release migrates no state.",
              "Terminal Groups are removed, a breaking change for clients and scripts: `session.create` requires a `workspace`, the `terminal-group.*` methods and every `--group` flag are gone, and the roster no longer carries `terminalGroups`. Update clients and scripts to this release.",
              "Local packaging uses the available Apple Development signing identity and is not notarized; the archive is suitable for internal or temporary testing, not general public distribution.",
            ],
          },
        ],
      },
      {
        version: "0.25.0",
        dateISO: "2026-10-12",
        date: "October 12, 2026",
        title: "Warren adds an opt-in translucent window.",
        summary:
          "A minor release that adds an opt-in Translucent Window material to the Desktop, so the window itself can carry one Ember coat over the desktop, and stacks a Conversation's pending work on the composer while it is on. The JSON control protocol remains at 4.0 and this release migrates no state.",
        sections: [
          {
            title: "Added",
            items: [
              "Add an opt-in Translucent Window switch under Settings > Appearance, off by default. With it on the main window is the material: a behind-window blur with one translucent coat of the Ember background drawn at the root. Regions (sidebar, top bar, tabs, preset bar, panes, inspector, conversation timeline, settings) stop painting their own ground, raised surfaces (composer, cards, inputs) take the same Ember tone made denser, and floating surfaces add an in-window blur. Terminals paint no default background, so the coat shows through and OSC 11 still reports what is on screen.",
              "Stack a Conversation's pending work on the composer while the preference is on: a dismissible problem banner, the decision dock, and one raised panel carrying the plan and the queued follow-ups, which can be edited back into the composer or dropped. The transcript scrolls beneath the stack, a sent message can be brought back into the composer to edit and resend, a long message folds after eight lines, and an empty Conversation names the workspace it will work in.",
            ],
          },
          {
            title: "Changed",
            items: [
              "Name the setting Translucent Window, and let the arrangement it turns on follow the preference rather than the window material, so Reduce Transparency keeps the layout while forcing the window back to opaque. With it off nothing changes.",
            ],
          },
          {
            title: "Fixed",
            items: [
              "Bind a fresh Agent to its hook-reported transcript before the file exists. Claude creates its JSONL only with the first prompt, so a new Session had no timeline and clients kept showing it as starting while the TUI was already usable; the Host now trusts the path a SessionStart binding reports for the conversation the Session was started with, and the watcher retries the missing file. A switch to another conversation still waits for its file.",
              "Pair Claude queue rows instead of reopening delivered prompts. Claude writes a `queued_command` attachment when a queued prompt is delivered, after its dequeue/remove row; it was projected as an enqueue nothing cleared, so idle conversations showed queued messages. The parser now numbers each enqueue and resolves dequeue and remove to that queueId.",
              "Lift a worktree row's title to the project foreground only while the row is active.",
            ],
          },
          {
            title: "Release notes",
            items: [
              "The JSON control protocol remains at 4.0 and this release migrates no state.",
              "Local packaging uses the available Apple Development signing identity and is not notarized; the archive is suitable for internal or temporary testing, not general public distribution.",
            ],
          },
        ],
      },
      {
        version: "0.24.0",
        dateISO: "2026-10-08",
        date: "October 8, 2026",
        title: "Warren redraws the Inspector's diffs.",
        summary:
          "A minor release that redraws the Desktop Inspector's diffs in one text view, so a large diff lays out in one pass instead of drawing every row at once, and tightens the branch card. The JSON control protocol remains at 4.0 and this release migrates no state.",
        sections: [
          {
            title: "Changed",
            items: [
              "Tighten the Inspector's branch card: upstream and the branch's standing on the main line fold into one quiet line under the branch name, the pull-request row shrinks to a single line, and a drawn branch mark replaces the SF fork arrow in the card and the header.",
            ],
          },
          {
            title: "Fixed",
            items: [
              "Draw the Inspector's diffs with one text view at fixed row heights. Rows inside the horizontal scroller could not be lazy, so opening a large diff laid out every row at once (about 820ms for 1,500 lines) and left blank gaps where estimated row heights met real ones. A vertical swipe now goes to the Inspector's list, and Copy takes only the code.",
              "Keep code from showing through the line-number gutter, index line starts once per edit instead of recounting the file on every scroll frame, and build the Files tree's change map once per render rather than once per row.",
            ],
          },
          {
            title: "Release notes",
            items: [
              "The JSON control protocol remains at 4.0 and this release migrates no state.",
              "Local packaging uses the available Apple Development signing identity and is not notarized; the archive is suitable for internal or temporary testing, not general public distribution.",
            ],
          },
        ],
      },
      {
        version: "0.23.0",
        dateISO: "2026-09-29",
        date: "September 29, 2026",
        title: "Warren runs Agents over ACP and opens an Inspector.",
        summary:
          "A minor release that adds ACP (Agent Client Protocol) Sessions and one Conversation surface for every Agent across Desktop, Web, and iOS, an Inspector beside the Desktop terminal for changes, history, and files, and a rebuilt iOS navigation. The JSON control protocol remains at 4.0; the Host advertises two additive capabilities, `agent-config-v1` and `agent-streams-v1`, and the Host state schema is unchanged.",
        sections: [
          {
            title: "Added",
            items: [
              "Drive Agents over the Agent Client Protocol (RFC 0023). An ACP Session has no PTY: the Host launches the provider's ACP server through the login shell, translates `session/update`, permissions, and prompt results into canonical Agent events, and survives an agent crash or Host restart through `session/resume` or `session/load`. A detached holder keeps the agent alive across a Host restart, and the CLI creates one with `--agent-handler acp`.",
              "Open an ACP Session in one Conversation surface on all three clients — a trailing prompt bubble, one collapsed work trail, reasoning on demand, an edited-files card, and a decision dock above the composer — shared with terminal Agents. The new-session sheet offers Chat or Terminal for Claude, Codex, and OpenCode.",
              "Publish the agent's model, mode, and effort selectors under `agent-config-v1` and accept `agent.config.set`; back ACP `terminal/create` with a visible terminal Session; and hand a conversation off to a resuming terminal Session with `session.handoff`.",
              "Keep every running Agent Session current in the background: iOS and Desktop negotiate `agent-streams-v1` for one stream per subscribed Session, with `agent.events.unsubscribe`.",
              "Draw plan proposals as their own card (Codex `<proposed_plan>` and Claude `ExitPlanMode`), answer Claude's `AskUserQuestion` from the Agent view, and answer Codex's “Implement this plan?” picker.",
              "Add an Inspector beside the Desktop terminal (⌥⌘B) for changes, history, and files, with inline diffs and a pull-request flow; Swift clients get `git.panel`, `git.diff`, `git.commit`, `git.push`, `git.pull`, and `git.pr.create`.",
              "Notify on iOS when a running Agent Session needs approval or input, fails, or finishes a turn, and carry the latest config, plan, and context events with every history page.",
            ],
          },
          {
            title: "Changed",
            items: [
              "Encode Agent activity as one dot all three clients share: motion means work is progressing, color says what a state asks of a person, and an attention payload outranks the lifecycle it arrives with. Four priority ladders collapse into one table.",
              "Treat a finished turn as a completion notice: `ready` stops being drawn once seen, device-locally and persistently; `exited` is no longer drawn; the word is “Done”, and the working pulse is quieter.",
              "Rebuild iOS navigation on native chrome and grouped lists, quiet the Conversation type, move its controls into the composer, and queue a message written while the Agent works.",
              "Set each Desktop Host on a tinted plate, and, when collapsed, report its project count and most actionable Agent mark.",
            ],
          },
          {
            title: "Fixed",
            items: [
              "Re-read the Git panel's local status, log, and branches after two seconds so files an Agent changes appear, and report a fresh branch as having no commits beyond main rather than as merged.",
              "Keep the Desktop terminal mounted when the Inspector or editor opens, reach the local daemon at its launched address, and fail half-open sockets on a probe deadline that a probe can also cut short.",
              "Fall back from a dead direct route to Relay, keep a turn working when a tool fails, and project Claude and Codex task and plan tools to Todo/Plan.",
              "Fix the iOS notice tap that aborted the app, the Relay invite rejection, and the Web blank page on first render.",
            ],
          },
          {
            title: "Release notes",
            items: [
              "The JSON control protocol remains at 4.0 and the Host state schema stays at 4; this release migrates no state. The Host adds the `agent-config-v1` and `agent-streams-v1` capabilities, and a client that does not negotiate them behaves as before.",
              "ACP requires the provider's ACP server reachable through the login shell, and an ACP Session has no PTY, so terminal attach and read are refused on it.",
              "Local packaging uses the available Apple Development signing identity and is not notarized; the archive is suitable for internal or temporary testing, not general public distribution.",
            ],
          },
        ],
      },
      {
        version: "0.22.0",
        dateISO: "2026-09-23",
        date: "September 23, 2026",
        title: "Warren adds a browser an Agent can drive.",
        summary:
          "A minor release that adds Warren Browser, a Host-owned Chromium Session an Agent drives, makes the browser an ordinary Desktop pane, and gives both clients one shared connection presentation; the JSON control protocol remains at 4.0.",
        sections: [
          {
            title: "Added",
            items: [
              "Add Warren Browser (RFC 0022): a browser Session owns a Chromium process instead of a PTY, and an Agent drives it through 21 actions over the new `browser-v1` capability, a `browser.*` RPC surface, an HTTP viewer page and frame stream, and a `warren browser` CLI. Frames carry their own `browserFrame` binary kind, and each Session keeps its own profile directory.",
              "Make the browser an ordinary Desktop pane with a Browser preset in the command bar and a WKWebView viewer that reports its own viewport, and let a Session row be dragged out of the sidebar tree into a pane.",
              "Keep a sent message on screen until the timeline owns it: both clients hold an `accepted` state between the Host's receipt and the provider's echo, matched through the new `agent-causation-v1` capability.",
              "Persist the unsent message queue per endpoint and session on both clients, so a tab close or an app relaunch no longer discards messages, and grow the iOS composer for multi-line drafts.",
              "Tell an established client why its Host went away, with the Host's name and last-seen time, and keep the LAN advertisement aligned with the Host's current addresses.",
            ],
          },
          {
            title: "Changed",
            items: [
              "Report connection state through one presentation layer both clients share — live, settling, and interrupted with a 1.2s grace — so sub-second flaps no longer paint a red banner while an absent Host is still reported at once.",
              "Prove liveness to the Host: iOS advertises and sends `app-heartbeat-v1` pings, and all three Relay hops count any inbound frame as liveness, not only pongs.",
              "Run Agent turns through a per-session ordered dispatcher on the Headless reader, so a slow turn no longer delays the heartbeat while two turns for one session keep the CLI's arrival order.",
            ],
          },
          {
            title: "Fixed",
            items: [
              "Acknowledge every screencast frame, recover a page target that dies under a running Chromium, render the live view at the density the viewer reports, and follow CDP's scroll convention; the viewer also reconnects with a keepalive ping instead of stalling.",
              "Resolve `CausedBy` as a late-bound annotation rather than part of event identity, and tighten the echo matcher so a longer message cannot claim a shorter pending one.",
              "Decode a denied `AskUserQuestion` whose `toolUseResult` is a plain string, and derive sided modifier flags for remapped keyboards so AppKit control keys are encoded from hardware input.",
              "Stop the iOS Agent view from rescanning the transcript for every row, let a long pane title truncate instead of pushing the sidebar off screen, and stop reserving the editor's width while the editor is closed.",
            ],
          },
          {
            title: "Release notes",
            items: [
              "The JSON control protocol remains at 4.0 and the Host state schema is unchanged; this release migrates no state.",
              "Warren Browser requires a Chromium the Host can launch, and only a local endpoint can render the viewer, so a remote Host drops the Desktop preset.",
              "Local packaging uses the available Apple Development signing identity and is not notarized; the archive is suitable for internal or temporary testing, not general public distribution.",
            ],
          },
        ],
      },
      {
        version: "0.21.0",
        dateISO: "2026-09-20",
        date: "September 20, 2026",
        title: "Warren keeps Agent hooks and the embedded editor in sync.",
        summary:
          "A maintenance release that repairs stale Warren-owned Agent hooks so provider arguments survive, and reloads live embedded editor web views when appearance changes; the JSON control protocol remains at 4.0.",
        sections: [
          {
            title: "Fixed",
            items: [
              "Normalize every Warren-owned Agent hook entry for an event and keep exactly one, removing stale comment-form duplicates while preserving user entries and the first owned entry's matcher. Manual Claude overlays no longer lose their provider argument or get mislabeled as Codex after a restart.",
              "Reload live embedded editor web views after an appearance change so code-server picks up the selected theme without losing open tabs or edits; settings, injected scripts, and page chrome now move together.",
            ],
          },
          {
            title: "Release notes",
            items: [
              "The JSON control protocol remains at 4.0 and the Host state schema stays at 4; this release migrates no state.",
              "Local packaging uses the available Apple Development signing identity and is not notarized; the archive is suitable for internal or temporary testing, not general public distribution.",
            ],
          },
        ],
      },
      {
        version: "0.20.0",
        dateISO: "2026-09-20",
        date: "September 20, 2026",
        title: "Warren brings a complete light appearance to Desktop and Terminal.",
        summary:
          "A minor release that adds a client-local System, Light, and Dark appearance across Desktop, Terminal, TUIs, and the embedded editor, and tightens terminal focus and pointer delivery; the JSON control protocol remains at 4.0.",
        sections: [
          {
            title: "Added",
            items: [
              "Add a client-local appearance setting with System, Light, and Dark choices. The new Ember Paper palette covers Desktop chrome, terminal ANSI colors, TUIs, and the embedded editor, and switches live with the selected appearance.",
            ],
          },
          {
            title: "Changed",
            items: [
              "Make the terminal and its TUIs follow Warren's selected appearance, including Ghostty's bold and contrast behavior, OSC color answers, and the editor's embedded workbench theme.",
              "Refresh the CLI help and glossary to match the shipped surface: document `session panes`, the accepted Agent providers and options, both removal spellings, and the Host-owned Pane model.",
            ],
          },
          {
            title: "Fixed",
            items: [
              "Deliver terminal pointer, resize, and text callbacks through the live surface path, so focus answers where the keyboard actually is and returns to a Terminal that kept its pane.",
              "Recover an embedded editor region after its model stops, keep its workspace and cursor registrations current, and prevent its row badges from overlapping.",
            ],
          },
          {
            title: "Release notes",
            items: [
              "The JSON control protocol remains at 4.0 and the Host state schema stays at 4; this release migrates no state.",
              "Appearance is client-local and existing installations remain Dark by default; System and Light are opt-in from Desktop settings.",
              "Local packaging uses the available Apple Development signing identity and is not notarized; the archive is suitable for internal or temporary testing, not general public distribution.",
            ],
          },
        ],
      },
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
    "nav.label": "页面导航",
    "nav.howItWorks": "工作方式",
    "nav.demo": "演示",
    "nav.changelog": "更新日志",
    "nav.download": "下载",
    "download.loading": "获取最新版…",
    "download.ready": "开始下载…",
    "download.fallback": "正在打开 Releases…",
    "hero.titleA": "退出应用，",
    "hero.titleB": "Agent 还在干活。",
    "hero.lede":
      "Warren 把你的终端和编程 Agent 跑在你自己的 Mac 或服务器上。桌面端、浏览器和手机都只是同一批运行中会话的窗口，关掉哪一个，活儿都不会停。",
    "hero.download": "下载 Mac 版",
    "hero.source": "查看源码",
    "hero.requirements": "macOS 13+ · Apple 芯片 · Host 也能跑在 Linux 上",
    "hero.shotAlt": "macOS 上的 Warren：Workspace 里的一段 Claude 对话，左侧是项目侧栏，右侧 Inspector 显示未提交的改动",
    "anywhere.title": "每块屏幕，同一个会话。",
    "anywhere.lede":
      "会话属于 Host。从桌面端、浏览器或手机打开，看到的都是同一段对话，停在同一条回答上。",
    "anywhere.browser": "浏览器",
    "anywhere.soon": "即将推出",
    "anywhere.browserAlt": "浏览器里的 Warren，显示一段关于 Host 重启后恢复 ACP Agent 的 Claude 对话",
    "anywhere.phoneAlt": "Warren iPhone 应用里的同一段 Claude 对话",
    "anywhere.note": "两张截图是同一台 Mac 上的同一个 Claude 会话。那段代码和 13:39 的时间戳是同一条消息。",
    "lifecycle.title": "只有关掉 Tab 才会结束会话。",
    "lifecycle.lede": "其他操作都只是暂时离开。整个产品都建立在这条规则上。",
    "lifecycle.label": "运行中的会话会怎样",
    "lifecycle.running": "继续运行",
    "lifecycle.ends": "结束",
    "lifecycle.rows": [
      {
        action: "退出 Warren",
        why: "重新打开应用，终端还在原处，回滚记录也在。",
      },
      {
        action: "断网或合上电脑",
        why: "网络恢复后客户端自动重连，期间的输出会补回来。",
      },
      {
        action: "切换 Workspace",
        why: "每个 Workspace 保留自己的 Tab，切回来看到的是它们现在的样子。",
      },
      {
        action: "重启 Host",
        why: "Agent 跑在独立的托管进程里，新的 Host 会重新接上，进行中的回答也能接着收。",
      },
      {
        action: "关掉 Tab",
        why: "主动停止会话和进程的唯一方式。",
        ends: true,
      },
    ],
    "demo.title": "先看，再试。",
    "demo.lede": "一段在真实 App 里录制的影片，还有桌面端的终端引擎，直接在浏览器里跑。",
    "film.play": "播放影片",
    "film.caption": "四个 Agent 互相发消息，退出再回来，从手机上回复，两台 Host 在同一个侧栏里。",
    "terminal.title": "终端",
    "terminal.loading": "正在加载 Ghostty…",
    "terminal.error": "终端引擎无法在这个浏览器里加载。",
    "terminal.captionA": "点进去输入 ",
    "terminal.captionB": "。它连的是假的 Host，但终端是真的。",
    "details.title": "里面有什么。",
    "details.items": [
      {
        title: "终端、Agent 和编辑器在同一个 Workspace",
        body: "真正的终端，Claude、Codex 和 OpenCode 的结构化视图，旁边还有兼容 VS Code 的编辑器。",
      },
      {
        title: "Worktree 和跨仓库任务",
        body: "主检出和 Git worktree 都是一等公民。一个任务可以把多个仓库的 Workspace 组在一起。",
      },
      {
        title: "你的 Mac，或你的服务器",
        body: "Host 可以跑在本机，也可以跑在 VPS 上，在同一个侧栏里切换。",
      },
      {
        title: "终端输出原样呈现",
        body: "桌面端用 Ghostty，Web 用 xterm.js。颜色、Unicode 和全屏 TUI 都正常显示。",
      },
      {
        title: "每个客户端同一套模型",
        body: "项目、Workspace 和会话在桌面端、Web 和 CLI 上是同一批对象。",
      },
      {
        title: "由你决定何时可访问",
        body: "默认不对外开放任何入口。需要从外面用 Web 客户端时，再通过你自己的 Relay 打开 Public Access。",
      },
    ],
    "how.title": "怎么连起来。",
    "how.lede": "每个客户端都用同一条 WebSocket 协议连同一个 daemon，会话归 daemon 所有。",
    "how.clients": ["macOS 应用", "浏览器", "CLI"],
    "how.host": "你的 Mac 或服务器",
    "how.session": "会话",
    "how.store": "持久存储",
    "how.note": "SSH 和 Relay 只负责让 Host 能被访问到，从不保存终端输出或输入。",
    "close.title": "跑个长任务，然后合上电脑。",
    "close.changelog": "看更新日志",
    "close.license": "源码以 FSL-1.1-ALv2 许可公开",
    "footer.label": "页脚",
    "footer.license": "许可",
    "changelog.title": "更新日志",
    "changelog.lede": "Warren 每个版本改了什么。",
    "changelog.viewRelease": "查看 Release",
    "changelog.releaseTitle": "Warren 版本",
    "changelog.stale": "仓库暂时无法访问，当前显示的是上次缓存的更新日志。",
    "changelog.error": "更新日志暂时不可用，可以先查看仓库。",
    // Offline fallback; live entries come from the repository changelog API.
    "changelog.entries": [
      {
        version: "0.34.1",
        dateISO: "2026-10-27",
        date: "2026 年 10 月 27 日",
        title: "Warren 让 shell 行以命令为主，并给侧栏一条右缘。",
        summary:
          "补丁版本：完善新版 Desktop 侧栏——普通 shell 行以正在或最后运行的命令为主，第二行说明运行位置与结果，所有行共用一条右缘，含 Session 的工作树排在前面，深色 Ember 侧栏中的分支名也有可读的墨色。JSON 控制协议仍为 4.0，本版本不迁移任何状态。",
        sections: [
          {
            title: "调整",
            items: [
              "普通 shell 的侧栏行以正在或最后运行的命令为主，未运行任何命令前显示所在目录。第二行说明相对工作树的运行位置，以及正在运行、完成、停止或因失败退出码；Tab 与窗格标题仍标明 shell 所在位置，用户自定义名称仍然优先。",
              "所有 Session 第二行在年龄列收束，使各行共用一条右缘；项目名放大半级；只有工作中、等待中或失败的 Session 使用明亮标题墨色。",
              "树采用四级间距：块内 0、单行摘要之间 2、块之间 10、项目与 Task 之间 20；含 Session 的工作树排在前面。",
              "分支行更靠近其 Session，使用更安静的 11pt 字面；长分支名淡出而不是截断前缀；每个折叠箭头占一列；项目行不再显示唯一的默认分支。",
              "仅在悬停时显示固定与 Task 链接；非活动行的头像改为纯色块；Task 以绘制的小旗开头。工作树全部属于 Task 的项目会说明并跳到 Tasks Tab。",
            ],
          },
          {
            title: "修复",
            items: [
              "深色侧栏的分支名使用专属墨色，使分支及其前缀在 Ember 上保持可读，而不是低于 3:1 对比度。",
              "把 pi 图标移出卡片。",
            ],
          },
          {
            title: "版本说明",
            items: [
              "JSON 控制协议仍为 4.0，本版本不迁移任何状态。",
              "本地打包使用可用的 Apple Development 签名身份，未做公证；该归档适合内部或临时测试，不适合面向公众分发。",
            ],
          },
        ],
      },
      {
        version: "0.34.0",
        dateISO: "2026-10-26",
        date: "2026 年 10 月 26 日",
        title: "Warren 按计划执行工作，并呈现 Lead 的 Crew。",
        summary:
          "次版本：Host 可按 cron 或一次性时间运行 Agent 提示与命令；停下的 Session 保留最后输出，可从 Tab 或一次性全部恢复；Lead Agent 的引用、决定、检查与 Crew 呈现在会话里；Desktop 侧栏分为 Projects 与 Tasks 两个 Tab，并采用新的间距与墨色层级；挂载的磁盘映像安装前会先询问。JSON 控制协议仍为 4.0，新增 `session.history`、`session.resume` 与 `schedule.*` 方法，本版本不迁移任何状态。",
        sections: [
          {
            title: "新增",
            items: [
              "用 `warren schedule create|list|view|remove|pause|resume|run|runs` 按 Host 本地时区的 cron 表达式或一次性时间运行 Agent 提示与命令；计划保存在 state 文件旁的 `schedules.json`，daemon 重启后继续触发。agent 动作启动一轮，并在 Agent 忙碌时挂起提示；command 动作在工作区里新建 shell Session。`--provider` 每次运行新建 Agent，`--when-busy` 与 `--keep N` 用来约束运行。",
              "保留停下的 Session：Host 记录结束原因，通过 `session.history` 保留最后输出，并以安静的 Tab 展示；Agent 提供 Resume，shell 在同一目录提供 Restart。停下横幅的 Resume All 先恢复当前 Session，再原地恢复其余。",
              "把 Lead Agent 的标记呈现为结构：`#agent` 引用变成内联 Session 胶囊，`#ask` 成为决定面板，`#accept` 成为检查清单，Crew 成为会话上的条带。LEAD 字样标记该 Session，只有未回答的请求点亮注意力圆点。",
              "侧栏分为 Projects 与 Tasks 两个 Tab，带各自计数、隐藏列表的等待圆点、添加动作与全部折叠动作。",
              "安装挂载的磁盘映像前先询问：窗口并列显示映像版本与已安装版本，说明更新、相同或更旧，并明确写出降级。",
            ],
          },
          {
            title: "调整",
            items: [
              "侧栏采用四级间距与五级墨色：Agent 行 44pt，普通 shell 占一行 28pt，分支标签 11.5pt，Task 与项目使用方块图标，分区标题为句首大写并带安静计数。",
              "组名按文字脚本各自取同一视觉字号，宽字符脚本低半级；tooltip 在打开时读取锚点，而不是每个滚动帧都跟踪。",
              "provider 权限停靠栏采用 Lead 面板的形状：注意力色只用于眉标的圆点，选项为行，只有一个填充的默认动作。",
              "网站首屏移除示例 Session 芯片。",
            ],
          },
          {
            title: "修复",
            items: [
              "在客户端解析 `warren project add PATH`，让 `.`、`..` 与 `~/repo` 指向用户所指的仓库。",
              "可从侧栏行打开停下的 Session，其标题使用安静墨色，恢复后的 Session 放回停下 Tab 的位置。",
              "Task 链接与工作树用安静徽标标记，Task 的长外部 ID 放进 tooltip，Agent 消息动作浮层不再挤动布局。",
              "provider 诊断显示为安静警告，composer 光标与占位符对齐，Lead 回复与 Tab 标题保持区分。",
              "在追加新 Session 的状态事务内拒绝第二个 resume 写入者，两个客户端无法把同一段对话恢复成两个运行中的 Session。",
              "不再在每个滚动帧重新测量窗口或重建侧栏行，侧栏滚动时暂停悬停处理。",
            ],
          },
          {
            title: "版本说明",
            items: [
              "JSON 控制协议仍为 4.0；Host 新增 `session.history`、`session.resume` 与 `schedule.*` 方法，Host 状态 schema 不变。本版本不迁移任何状态。",
              "本地打包使用可用的 Apple Development 签名身份，未做公证；该归档适合内部或临时测试，不适合面向公众分发。",
            ],
          },
        ],
      },
      {
        version: "0.33.0",
        dateISO: "2026-10-21",
        date: "2026 年 10 月 21 日",
        title: "Warren 按各家自己的方式停住一轮对话。",
        summary:
          "次版本：CLI 与 Desktop 都能用该 provider 认作「停止」的按键停住 Agent 正在跑的一轮；Host 重启后立即给出 roster，不再等待 Agent journal 打开；工作区分支只有自带提交且默认分支已包含时才计为已合并；产品影片、截图与官网展示当前 Desktop。JSON 控制协议仍为 4.0，本版本不迁移任何状态。",
        sections: [
          {
            title: "新增",
            items: [
              "用 `warren agent cancel AGENT_ID [--current] [--wait]` 从 CLI 停住 Agent 正在跑的一轮。Host 走 provider 自己的中断路径，终端 Agent 与协议驱动的 Agent 都以各自期待的方式停下，`--wait` 在该轮真正结束时才返回。",
            ],
          },
          {
            title: "修复",
            items: [
              "Host 重启后立即给出第一份 roster，不再因 Agent journal 打开而让所有客户端在冷启动时卡住约五秒。",
              "工作区分支只有自带提交、且默认分支确实包含它们时才显示为已合并。",
              "用 pi 与 Codex 各自认作的「停止」按键停住一轮，并让被 pi 标记为已停下的轮次真正结束，不再停留在工作中。",
              "`warren agent wait` 只盯正在跑的那一轮。",
            ],
          },
          {
            title: "变更",
            items: [
              "按当前 Desktop 重剪产品影片，运镜落在真实指针操作上：悬停树、切 Tab、从顶栏分屏、收起侧栏、切换 Host、Inspector 的改动、Agent 驱动的浏览器，以及同一个 Session 在浏览器与手机上。",
              "README 与官网改用同一 build 的截图。",
            ],
          },
          {
            title: "版本说明",
            items: [
              "JSON 控制协议仍为 4.0，本版本不迁移任何状态。",
              "本地打包使用可用的 Apple Development 签名身份，未做公证；该归档适合内部或临时测试，不适合面向公众分发。",
            ],
          },
        ],
      },
      {
        version: "0.32.0",
        dateISO: "2026-10-20",
        date: "2026 年 10 月 20 日",
        title: "Warren 用磁盘映像安装。",
        summary:
          "次版本：Warren 提供拖入安装的磁盘映像，打开更新版本的映像即可完成安装并重启；Command+K 搜索面板按 Workbench 规范重绘；修复 iPhone 上 Host 可达性、配对与 Relay 回退，Desktop 在睡眠、网络切换或令牌刷新后恢复 SSH 与 Relay 连接。JSON 控制协议仍为 4.0，本版本不迁移任何状态。",
        sections: [
          {
            title: "新增",
            items: [
              "以磁盘映像下载 Warren。映像窗口显示把应用拖到哪里，以及如何在“隐私与安全性”中批准首次启动。每个版本仍保留 zip，供应用内更新使用。",
              "无需拖动或二次批准即可安装下载的磁盘映像。Warren 正在运行时，打开更新版本的 Warren 磁盘映像会前置 Warren，确认该应用由同一开发者签名，完成安装，推出磁盘映像并重启 Warren。",
            ],
          },
          {
            title: "调整",
            items: [
              "让 Command+K 搜索面板与 Workbench 其余部分一致：600 点的对话框表面、更大的搜索框、带每个 Session 在其 Tab 上所戴应用图标的菜单式行，以及同时列出范围过滤键的按键提示栏。",
            ],
          },
          {
            title: "修复",
            items: [
              "Settings 中的每个 Launch Commands 预设现在显示 + 菜单、Tab 和侧边栏所用的应用图标，而不是旧版裸标志。",
              "在 iPhone 上说明 Host 为何无法连接。断连超过宽限期后，Inbox 与 Session 标题会给出原因，例如“Mac is offline · last seen 3 minutes ago”；首次加载连不上时也直接说明，而不是显示占位行。",
              "当 Host 不再接受某设备时要求新的配对码。此前被移除的设备或重置的配对会一直重试，而应用只显示正在等待 Mac；现在 iPhone 与 Desktop 会停下并提示重新配对。",
              "弱网下 Relay 令牌刷新丢失回复时仍保持设备已配对。Relay 在 60 秒内接受同一刷新，而不是吊销设备。",
              "iPhone 离开 Host 所在网络时回退到 Relay，即使关闭了自动 LAN 切换也一样；当 LAN 地址重新可用时回到同一地址。编辑 Host 不再把它切换到 LAN 地址。",
              "通过 Relay 配对的 Host 以 Host 命名，不再叫“Warren Host”；第二个 Host 的配对码不会并入第一个 Host；重命名 Host 会保留所有已保存的凭据。",
              "在 iPhone 的 Hosts 列表中显示配对进度与失败，以及每个已保存的 Host 在当前网络上是否有响应或上次连接的时间。切换 Host 会立即显示新 Host。",
              "Desktop 在睡眠或网络切换后恢复 SSH Host。SSH 连接发送 keepalive，失效的隧道会被重建，侧边栏中连接失败的 Host 会自行重试。",
              "Desktop 的 Relay 连接在令牌刷新时保持，而不是重新连接。",
              "Mac 唤醒后立即把 Host 重连到 Relay，而不是等完剩余的退避时间。",
              "分屏面板调整大小时保持终端输出对齐。Desktop 只在 Host 报告 PTY 实际调整尺寸的那个输出位置改变终端网格，因此按旧宽度写入的文字不会画到新网格上，面板不再出现乱码行。",
            ],
          },
          {
            title: "发行说明",
            items: [
              "JSON 控制协议仍为 4.0，本版本不迁移任何状态。",
              "本地打包使用可用的 Apple Development 签名身份，未做公证；该压缩包适合内部或临时测试，不适合公开发布。",
            ],
          },
        ],
      },
      {
        version: "0.31.0",
        dateISO: "2026-10-19",
        date: "2026 年 10 月 19 日",
        title: "Warren 在慢链路上更快回应 Agent。",
        summary:
          "次版本：去掉 Agent 路径上的固定等待——收到输入后以及回合进行中，transcript watcher 以 50ms 读取，PTY 提交在 TUI 回显且输出安静后立即继续，新增可选的 `output-ack-v1` 能力把在途终端输出限制在约一个往返。同时把等待中的 Agent 计数到 Dock 图标，并在 Warren 处于后台时发一条 macOS 通知。JSON 控制协议仍为 4.0，本版本不迁移任何状态。",
        sections: [
          {
            title: "新增",
            items: [
              "新增 `output-ack-v1`，限制在途终端输出。协商该能力的客户端用 `session.ack` 确认已收到的输出；Host 保持在途约一个往返加 200ms，超过就暂停读取，因此慢链路上按键回显或 Agent 事件不再堵在数秒排队输出之后。被压后超过一秒的读取方会跳过积压，就地收到一份新的终端状态，而不是断开连接重新锚定。",
              "在窗口外提醒有人 agent 在等待。Desktop 把当前 Host 等待中的 Session 计数到 Dock 图标；Warren 处于后台时，每个新请求发一条 macOS 通知；可以直接在通知里通过审批托盘放行或拒绝；无人等待时撤回通知。Settings > Notifications 为各项提供开关。",
            ],
          },
          {
            title: "调整",
            items: [
              "去掉 Agent 消息的固定等待。收到输入后以及回合进行中，transcript watcher 以 50ms 读取，空闲时回到 500ms；PTY 提交在 TUI 回显输入并安静后立即继续，仍以 300ms 为上限。Codex 的队列轮询保持空闲节奏。",
              "打开 iOS Agent Session 时不再订阅终端输出。Agent 视图直接订阅 Agent 流，不再背负它从不显示的 TUI 重绘；切换到终端时再附加终端流。未协商 `agent-streams-v1` 的 Host 保持原路径。",
              "让 Session 在所有客户端上同名。kind 提升逻辑移入 `SessionTitle`，iOS 用所属 Workspace 的路径解析，roster 携带 `resultSentence`，iOS Inbox 行因此像 Desktop 侧边栏一样说明已完成的 Agent 做了什么。iOS 上新建的 Agent Session 命名为 New Session。",
              "减少 resume、重连和切换 Session 时的 Relay 往返：即将过期的 access capability 在拨号前刷新，持有控制租约的 Session 先恢复，resume 探测上限随实测往返增长，iOS 把旧的 unsubscribe 与新的 subscribe 一起发送。",
              "Desktop 文案把 server 或 endpoint 统一称为 Host。",
            ],
          },
          {
            title: "修复",
            items: [
              "阻止慢 Relay 流卡住 Host socket。每条流各自排空有界入站队列；投递失败只关闭该流，不再让所有客户端重连；连接器在机器从睡眠唤醒后立即探测 Relay。",
              "关闭输出流控与 Relay 流中的竞态：入队前先记录输出已发送；被压后的读取方在跳过积压前允许 1 秒加两个往返；积压跳过让位于已在途的 subscribe；原子地检查并清除终端附加；把 Relay 的 CLOSE 排到未投递的 body 帧之后。",
              "在 Agent 视图中打开 Session 后，iOS 终端仍然可达。",
              "向上超出锚点的面板保持在窗口内。",
            ],
          },
          {
            title: "发行说明",
            items: [
              "JSON 控制协议仍为 4.0，本版本不迁移任何状态。新增可选的 `output-ack-v1` 能力；未协商的客户端行为不变。",
              "本地打包使用可用的 Apple Development 签名身份，未做公证；该压缩包适合内部或临时测试，不适合公开发布。",
            ],
          },
        ],
      },
      {
        version: "0.30.0",
        dateISO: "2026-10-19",
        date: "2026 年 10 月 19 日",
        title: "Warren 重建 Desktop 工作台。",
        summary:
          "大版本：围绕 Session 的真实状态重建 Desktop 工作台——侧边栏、顶栏、菜单、对话面板，以及独立的 Settings 窗口——并展示 shell 自身的提示符状态、agent 自己生成的对话名，以及每个运行中子 agent 的独立行。Terminal Group 被移除，每个 Session 都归属一个 Workspace。JSON 控制协议仍为 4.0，本版本不迁移任何状态。",
        sections: [
          {
            title: "新增",
            items: [
              "让 Host 在 `~/.warren/settings.json` 中按 provider 记录 ACP server 命令（`acpCommands`）。未显式指定命令创建的 Chat Session 现在会使用该配置，因此 Desktop、Web、iOS 和 `warren agent create --agent-handler acp` 都可以把聊天交给携带该 provider 凭据的 ACP server，而不是 `PATH` 上解析到的内置适配器。请求中显式的 `command` 仍然优先，条目为空则保留内置适配器。",
              "让每个 Session 行都保持两行。行高不再随回合开始和结束而变化：每一行都显示 Session 正在做什么、上一次做了什么以及多久以前。休息态那一行比工作态低一档颜色，工作中的 Agent 那一行有缓慢高亮（“减弱动态效果”会去掉），末尾用渐隐代替截断省略号，标题行还有一个芯片统计 Session 正在运行的子 agent 数量并就地展开它们的行。",
              "从 shell 自身读取提示符状态。shell 集成（zsh 与 fish）中带有 OSC 133 标记时，shell 行的标题显示它所在的位置，而不是重复它的命令；第二行显示正在运行什么、上一次运行了什么，以及该命令未被中断且以非零退出时的退出码。状态来自 ghostline v1.5.0 的 `SessionMetadata.Shell`；没有标记的 shell 保持原有的前台进程行。启动 agent CLI 的命令会让 Session 重新变成 Agent。",
              "重建对话面板。回答占据阅读栏，不带气泡；用户消息是右对齐气泡，超过八行折叠；一行承载本回合的工作并可展开为具体步骤；thinking 折叠成自己的一行；变更文件在 inspector 的 Changes 标签页中打开；composer 上放附件、权限模式、上下文数值和模型，旁边的发送键在 agent 工作时变成停止键。决策、计划和排队 prompt 叠放在 composer 上，决策是面板中唯一使用强调色的元素。",
              "展示子 agent 正在做什么。Warren 现在跟踪 Claude 和 Codex 写入的子会话 transcript，把每个事件挂到子 agent 的稳定标识（`subagentId`）上，并用 `parentCallId` 关联发起调用的位置。Session 为每个子 agent 显示一行及其正在运行的命令，子 agent 的活动不会改变父 Session 的状态、attention 或回合。",
              "用 agent CLI 为自己对话生成的名字作为 Session 标题。Codex、Claude Code、OpenCode 和 Qoder 都会给正在运行的对话命名，Warren 现在直接读取这些名字，不必为同一次交互再花一次模型调用。用户设置的名字仍然优先，Host 生成的名字会被 agent 自己的名字替换。子 agent 的对话永不使用。",
            ],
          },
          {
            title: "调整",
            items: [
              "打磨 Web 客户端的界面。侧边栏和标签条用七段非线性 alpha 渐变软化滚动边缘；结构性分隔在 Retina 上是真正的一像素细线；紧凑控件用采样过的弹簧按压；键盘焦点同时画焦点环和柔和的强调色光晕。侧边栏列表和两条标签条各是一个 Tab 停靠点，用方向键、Home/End 和 PageUp/PageDown 在其中移动。",
              "按可用宽度缩短每一行报告的内容：路径只保留最后一段，`--flag value` 要么变成它命名的对象要么直接去掉，复合命令只保留第一条命令，生成的标题按显示宽度截断（约 30 个拉丁字符或 16 个中日韩字符）并以动词开头。用户设置的标题和 agent 为自己对话生成的名字永不改写。",
              "统一侧边栏的时间格式与计数用语。时间显示为 `now / 5m / 2h / 3d / 2w` 之后是日期；时长显示为 `18s / 3m / 1h`；一回合的计数按编辑、Git 写入、命令、拉取、搜索、读取排序，未知工具合并为一条 `Used n tools`。",
              "把 Host 自己的标题请求保留为所有 agent 的后备。会为自己对话命名的 agent 先获得 30 秒宽限期，之后到达的名字在接下来一分钟内仍会替换 Host 的标题；从不为自己对话命名的 agent 则照常走配置的 LLM 请求。Settings 中的开关现在如其名，是一个后备开关。",
              "让每个 Session 只有一个名字。顶栏、侧边栏行、分屏面板标题栏、标签和窗口标题现在都解析同一个 `SessionTitle`：用户的名字优先，其次是 Agent 自己或生成的名字，再次是 kind 名字，再次是自定义命令的摘要，最后是 shell 的位置。shell 正在运行的命令与标题并排显示，而不是嵌在标题里。",
              "去掉 shell 行第二行的动词。现在只显示命令，使用等宽字体，并由顶栏使用的同一个 `CommandSummary` 缩短。",
              "让休息中的 shell 行折叠为一行。最后一条命令结束十分钟后——或从未运行则立即——shell 行降为 30pt 高的一行，运行命令会让第二行立即恢复。失败的命令保持两行，直到该 Session 被查看过一次。",
              "让分组的添加控件常驻在它的标题中。Projects 和 Tasks 始终在折叠箭头左侧显示小的灰色 `+`，不再悬停才显示。",
              "让选中底板在顶栏标签之间滑动。标签的选中态是侧边栏的填充色加一像素描边，底板在共享的 `WarrenMotion.selection` 弹簧上滑动到新选中的标签，而不是原地淡入。标签轨道不再包在外层胶囊里。",
              "把阻塞式对话框统一到同一个容器。`WarrenDialog` 现在负责底色、内边距、标题区和 S/M/L 宽度（400 / 480 / 720），重命名提示、消息对话框，以及 Task、Workspace、Project 的删除确认都画在它内部。",
              "让设置在独立窗口中显示。⌘, 打开一个 860×620 的窗口（最小 720×480，记忆位置），可以与被修改的终端并排，主窗口保持可用。导航宽 220pt，使用单色 SF Symbols；设置行高 44pt；Settings 的调色板全部取自共享 token，不再与 App 其余部分脱节。",
              "让休息中的 Agent 行显示 Host 的结果句。回合结束时 Host 向标题接口请求一句描述本回合做了什么的过去式句子（`Fixed the resize race, added 3 tests`），休息行因此显示发生了什么，而不是 `Edited 2 files`；未配置接口或请求失败时，行仍显示计数。",
              "让 Settings 使用共享代码芯片和真正的启动脚本编辑器。`$1`、`$2` 和 `WARREN_*` 画成一个等宽代码芯片并在旁标注，项目的启动脚本显示第一行（附 `+N lines`）和一个 Edit… 按钮，打开承载完整脚本的 L 对话框。",
              "合并 Launch Commands 列表。每个预设一行，携带顺序、可见性和第二行等宽命令；点击该行在其下方打开命令编辑器。",
              "把编辑器选择放进 Settings 的编辑器列表。每行带与单项选择菜单相同的白色对勾列，点击行即为设为 Open in Editor；选中的颜色卡片画与聚焦输入框相同的白色圆环。",
              "允许把一行 Launch Command 拖到另一行上重新排序，拖动时抬起该行；持有键盘焦点的行也响应 ⌥↑ / ⌥↓。",
              "给 Relay 连接行加上开关。注册 Host 后保持注册状态，开关只启停隧道，暂停 Relay 不再需要重置注册。",
              "把 New workspace、New Task、worktree 导入器、Superset 导入器和启动脚本编辑器都画在共享的 `WarrenDialog` 中，让每个阻塞流程共用同一底色、同一内边距尺度和键帽按钮。",
              "让 AI Titles 页使用共享的校验表单。字段保持为页面本地草稿，主按钮 Save & Test 保存并带 spinner 检查接口，Test 按钮（无草稿时禁用）只检查不保存，结果显示在按钮旁。",
              "把 Relay 邀请和局域网配对 PIN 与倒计时条并排显示。邀请的二维码不再打开弹层，两行都在文字下方用细条显示剩余窗口时间。",
              "重做 Terminal 页的预览。字体预览保持固定 132pt 高度，面板标题模板在自身下方以 ↳ 开头渲染结果，占位符芯片只显示占位符（说明作为 tooltip），九个全部能放进两行。",
              "Usage 范围改用 App 自己的分段控件，不再借用系统控件和平台强调色。",
              "按轨道可用空间决定 Tab 宽度。标签少时宽 200pt，随数量增加均匀收窄至 96pt 下限；超过下限后轨道在两侧边缘渐隐下滚动，并用 `⌄ N` 控件列出所有标签。",
              "把 Public Access 的状态放进标题行：一个圆点、它提供的地址（或未发布），以及尾部的开关。",
            ],
          },
          {
            title: "修复",
            items: [
              "阻止侧边栏在 shell 行悬停卡片下跳动。悬停卡片（shell 行的和顶栏标题的）现在不再画在菜单层捕获点击的遮罩上，也永不接收指针；shell 行的折叠与展开会带动下方各行动画，而不是只动自己。",
              "给界面的状态变化补上动效。菜单和悬停卡片淡入淡出；Session 打开或关闭、Workspace 折叠进空闲行时侧边栏各行移动；悬停才出现的控件淡入；solo 胶囊长成 shell 的运行命令；Hosts 标题交叉淡变为计数。",
              "在 Session 的活动行变化时保留它的 pane 排布。更新该行的投影副本此前手工重建了每个关系，丢下了 pane 分组，因此一个 Agent 步骤可能抹掉 Host 的分屏排布，直到下一次 roster 快照。",
              "路由投递队列填满时不再截断公共响应。路由缓冲现按字节、以发送方的整个窗口为上限；每条路由的投递 goroutine 按序把帧交给消费者，因此交接缓冲写满也不会阻塞隧道或丢帧。",
              "即使 agent CLI 从未运行、配置目录还不存在，也安装托管的 agent hooks。此前安装器只创建 Warren 自己的 hook 脚本目录，然后把 `hooks.json` 写进 agent 的配置目录，因而报 `no such file or directory`；daemon 记录警告并在没有 hook 的情况下继续运行。Codex、Claude Code 和 Qoder 都受影响，而因为每台开发机都已有这些目录，故障一直不可见。",
              "不再把 OpenCode Session 绑定到 OpenCode 为委派工作而创建的会话上。每个子 agent 任务都在自己的子会话中运行，而 Warren 把最新的 `session.created` 当作终端所在的对话，于是子 agent 把绑定指向了 agent 的内部工作，投影对话、活动覆盖层和 Session 标题都跟着子会话走。bind 插件现在忽略子会话（`parentID`），发现只提供根对话，已经指向子会话的绑定会被修复到拥有它的对话，而不是丢弃。",
            ],
          },
          {
            title: "移除",
            items: [
              "移除 Terminal Groups，即 Host 为独立 shell Session 持有的容器（默认 `Inbox`）。现在每个 Session 都归属一个 Workspace。`terminal-group.*` 方法被移除，roster 和 `roster.delta` 不再携带 `terminalGroups`，Session 与 Pane Group 记录去掉 `terminalGroup` 和 `scope`。`session.create` 要求 `workspace` 且没有默认分组回退；`session.move`、`pane-group.create` 和 `browser.session.create`/`list` 只接受 `workspace`。CLI 移除 `warren terminal-group` 资源及所有 `--group` 标志，`warren session create` 要求 Workspace。Web 客户端、搜索（`g:` 与 `group:` 前缀）和文档移除分组表面，唯一命令是打开 Terminal Group 中 shell 的 Raycast 扩展也被移除。[RFC 0003](docs/rfc/0003-terminal-groups.md) 标记为已撤回。",
            ],
          },
          {
            title: "发行说明",
            items: [
              "JSON 控制协议仍为 4.0，本版本不迁移任何状态。",
              "Terminal Group 被移除，对客户端和脚本是破坏性变更：`session.create` 要求 `workspace`，`terminal-group.*` 方法和所有 `--group` 标志被移除，roster 不再携带 `terminalGroups`。客户端和脚本需升级到本版本。",
              "本地打包使用可用的 Apple Development 签名身份，未做公证；该压缩包适合内部或临时测试，不适合公开发布。",
            ],
          },
        ],
      },
      {
        version: "0.25.0",
        dateISO: "2026-10-12",
        date: "2026 年 10 月 12 日",
        title: "Warren 加入可选的半透明窗口。",
        summary:
          "次版本：Desktop 新增可选的半透明窗口材质，窗口本身在桌面上覆一层 Ember 底色；开启时 Conversation 的待办事项叠放在 composer 上。JSON 控制协议仍为 4.0，本版本不迁移任何状态。",
        sections: [
          {
            title: "新增",
            items: [
              "在 Settings > Appearance 下新增可选的“半透明窗口”开关，默认关闭。开启后主窗口本身成为材质：窗口背后模糊，根部只覆一层半透明 Ember 背景。各区域（侧边栏、顶栏、标签、预设栏、面板、inspector、对话时间线、设置）不再自绘底色，浮起表面（composer、卡片、输入框）用同一 Ember 色调加重，浮动表面再加一层窗口内模糊。终端不绘制默认背景，因此底色透出，OSC 11 仍如实报告屏幕内容。",
              "开启该偏好时，Conversation 的待办事项叠放在 composer 上：可关闭的问题横幅、决策区，以及一块承载计划与排队消息的浮起面板，排队消息可以取回 composer 编辑或丢弃。记录在该叠层下方滚动，已发送的消息可以取回 composer 编辑重发，长消息超过八行折叠，空 Conversation 会标出将要在哪个 workspace 工作。",
            ],
          },
          {
            title: "调整",
            items: [
              "把该设置命名为“半透明窗口”，并让它带出的排布跟随偏好而非窗口材质，因此“降低透明度”只把窗口恢复为不透明，不会撤销布局。关闭时行为不变。",
            ],
          },
          {
            title: "修复",
            items: [
              "在新 Agent 的 hook 上报的 transcript 文件还不存在时就绑定它。Claude 只在收到第一条 prompt 时才创建 JSONL，因此新 Session 此前没有时间线，TUI 已经可用，客户端却一直显示为启动中；现在只要 SessionStart 绑定所指的对话正是该 Session 启动时所用的对话且尚无其他绑定，Host 就信任该路径，watcher 会重试缺失的文件。切换到另一个对话仍会等待其文件出现。",
              "配对 Claude 的队列行，不再把已投递的 prompt 重新显示为排队。Claude 在投递排队 prompt 时写入 `queued_command` 附件，位置在其 dequeue/remove 行之后；此前它被投影成一条永不清除的入队，空闲对话因此显示排队消息。队列行不带条目 ID，解析器现为每条入队编号，并把 dequeue 与 remove 解析到该 queueId。",
              "worktree 行的标题只在行处于活动状态时提升为项目前景色。",
            ],
          },
          {
            title: "发行说明",
            items: [
              "JSON 控制协议仍为 4.0，本版本不迁移任何状态。",
              "本地打包使用可用的 Apple Development 签名身份，未做公证；该压缩包适合内部或临时测试，不适合公开发布。",
            ],
          },
        ],
      },
      {
        version: "0.24.0",
        dateISO: "2026-10-08",
        date: "2026 年 10 月 8 日",
        title: "Warren 重绘 Inspector 的 diff。",
        summary:
          "次版本：Desktop Inspector 的 diff 改用单个文本视图重绘，大 diff 一次完成布局，不再逐行绘制；分支卡片也更紧凑。JSON 控制协议仍为 4.0，本版本不迁移任何状态。",
        sections: [
          {
            title: "调整",
            items: [
              "收紧 Inspector 的分支卡片：upstream 与相对主线的位置并为分支名下一行安静的元信息，pull request 行缩为单行，卡片与标题栏中的 SF 分叉箭头换成手绘分支图标。",
            ],
          },
          {
            title: "修复",
            items: [
              "Inspector 的 diff 改用单个文本视图、固定行高绘制。水平滚动区内的 SwiftUI 行无法懒加载，打开大 diff 会一次性布局所有行（1,500 行约 820ms），并在估算行高与真实行高相接处留下空白。垂直滑动现在交给 Inspector 列表，复制只取代码。",
              "代码不再从行号栏下透出；行首索引每次编辑只建一次，不再每帧滚动都重新数文件；Files 树的变更映射每次渲染只建一次，而非每行一次。",
            ],
          },
          {
            title: "发行说明",
            items: [
              "JSON 控制协议仍为 4.0，本版本不迁移任何状态。",
              "本地打包使用可用的 Apple Development 签名身份，未做公证；该压缩包适合内部或临时测试，不适合公开发布。",
            ],
          },
        ],
      },
      {
        version: "0.23.0",
        dateISO: "2026-09-29",
        date: "2026 年 9 月 29 日",
        title: "Warren 用 ACP 驱动 Agent，并加入 Inspector。",
        summary:
          "次版本：新增 ACP（Agent Client Protocol）Session，以及三个客户端共用的一套 Conversation 界面；Desktop 终端旁新增 Inspector，可看变更、历史与文件；iOS 导航按系统样式重建。JSON 控制协议仍为 4.0；Host 新增 `agent-config-v1` 与 `agent-streams-v1` 两个能力，Host 状态 schema 不变。",
        sections: [
          {
            title: "新增",
            items: [
              "用 Agent Client Protocol（RFC 0023）驱动 Agent。ACP Session 没有 PTY：Host 通过登录 shell 启动 provider 的 ACP server，把 `session/update`、权限请求与 prompt 结果翻译成标准 Agent 事件，并通过 `session/resume` 或 `session/load` 在 agent 崩溃或 Host 重启后继续。独立 holder 让 agent 跨 Host 重启存活，CLI 用 `--agent-handler acp` 创建。",
              "三个客户端共用一套 Conversation：prompt 为尾部气泡、每轮一条折叠的工作轨迹、按需的 reasoning、变更文件卡片，以及 composer 上方的决策区；终端 Agent 也用同一界面。新建面板为 Claude、Codex、OpenCode 提供 Chat 或 Terminal。",
              "在 `agent-config-v1` 下发布模型、模式、effort 选择器并接受 `agent.config.set`；用可见的终端 Session 承载 ACP `terminal/create`；用 `session.handoff` 把会话交给可续接的终端 Session。",
              "让每个运行中的 Agent Session 在后台保持最新：iOS 与 Desktop 协商 `agent-streams-v1`，每个订阅的 Session 各持一条流，并可用 `agent.events.unsubscribe` 释放。",
              "把计划提议画成独立卡片（Codex `<proposed_plan>`、Claude `ExitPlanMode`），在 Agent 界面回答 Claude 的 `AskUserQuestion`，并回答 Codex 的 “Implement this plan?” 选择框。",
              "Desktop 终端旁新增 Inspector（⌥⌘B），查看变更、历史与文件，含行内 diff 与创建 pull request；Swift 客户端获得 `git.panel`、`git.diff`、`git.commit`、`git.push`、`git.pull`、`git.pr.create`。",
              "iOS 在 Agent 需要审批或输入、失败或完成一轮时发通知；每个历史分页都带上最新的 config、plan 与 context 事件。",
            ],
          },
          {
            title: "变更",
            items: [
              "三个客户端共用一种 Agent 活动圆点：动表示正在工作，颜色表示状态对人的要求，attention 载荷优先于随行的 lifecycle。四份优先级表合并为一份。",
              "把完成的回合当作一次通知：`ready` 看过后不再显示（本地持久化）；`exited` 不再显示；措辞改为 “Done”，工作脉冲更安静。",
              "iOS 导航按系统样式与分组列表重建，Conversation 排版更安静，控制项移入 composer，Agent 工作时输入的消息进入队列。",
              "Desktop 每个 Host 放在带底色的托盘上，折叠时显示项目数与最需要处理的 Agent 标记。",
            ],
          },
          {
            title: "修复",
            items: [
              "Git 面板的本机状态、日志与分支改为两秒后重读，Agent 改动的文件即时可见；新分支不再被说成已合并，而是“相对 main 没有新提交”。",
              "打开 Inspector 或编辑器时保持终端挂载；本地 daemon 用启动时的地址连接；半开 socket 按探测超时失败，探测也能中断退避。",
              "直连路由失效后回退到 Relay；工具失败不再让整轮失败；把 Claude 与 Codex 的任务、计划工具投影为 Todo/Plan。",
              "修复 iOS 点击通知导致 App 中止、Relay 拒绝邀请交换，以及 Web 首次渲染白屏。",
            ],
          },
          {
            title: "发行说明",
            items: [
              "JSON 控制协议仍为 4.0，Host 状态 schema 仍为 4，本版本不迁移任何状态。Host 新增 `agent-config-v1` 与 `agent-streams-v1` 能力，未协商的客户端行为不变。",
              "ACP 需要 provider 的 ACP server 能通过登录 shell 启动；ACP Session 没有 PTY，因此拒绝终端 attach 与 read。",
              "本地打包使用可用的 Apple Development 签名身份，未做公证；该压缩包适合内部或临时测试，不适合公开发布。",
            ],
          },
        ],
      },
      {
        version: "0.22.0",
        dateISO: "2026-09-23",
        date: "2026 年 9 月 23 日",
        title: "Warren 新增可由 Agent 驱动的浏览器。",
        summary:
          "次版本：新增 Warren Browser——由 Host 持有、可被 Agent 驱动的 Chromium Session；浏览器成为普通的 Desktop pane；两个客户端共用一套连接展示状态。JSON 控制协议仍为 4.0。",
        sections: [
          {
            title: "新增",
            items: [
              "新增 Warren Browser（RFC 0022）：浏览器 Session 持有 Chromium 进程而非 PTY，Agent 通过 21 个 action 驱动它，对应新的 `browser-v1` capability、`browser.*` RPC、HTTP viewer 页面与帧流，以及 `warren browser` CLI。帧使用独立的 `browserFrame` 二进制类型，每个 Session 拥有自己的 profile 目录。",
              "浏览器成为普通的 Desktop pane：命令栏新增 Browser preset，WKWebView viewer 自行上报 viewport；侧边栏树中的 Session 行也可拖入 pane。",
              "已发送的消息在看到它出现在时间线之前不会消失：两个客户端在 Host 回执与 provider echo 之间维持 `accepted` 状态，通过新的 `agent-causation-v1` capability 匹配。",
              "两个客户端按 endpoint 与 session 持久化未发送队列，关闭 tab 或重启 App 不再丢失消息；iOS 输入框可随多行草稿长高。",
              "Host 离开时告知已连接的客户端，并带上 Host 名称与最后在线时间；LAN 广播随 Host 当前地址更新。",
            ],
          },
          {
            title: "调整",
            items: [
              "两个客户端共用一套连接展示：live、settling、interrupted，宽限期 1.2 秒；亚秒级抖动不再立刻变红，Host 确实不在了仍会立即上报。",
              "向 Host 证明活性：iOS 声明并发送 `app-heartbeat-v1` ping，Relay 三段链路都把所有入站帧计为活性，而不只看 pong。",
              "Headless 读取端用按 session 排序的 dispatcher 执行 Agent 轮次：慢轮次不再阻塞心跳，而同一 session 的两轮仍保持 CLI 的到达顺序。",
            ],
          },
          {
            title: "修复",
            items: [
              "确认每一个 screencast 帧以免流中断，在 Chromium 仍运行时恢复已死的 page target，按 viewer 上报的密度渲染实时画面，并使用 CDP 的滚动方向约定；viewer 也会用 keepalive ping 重连而不是停在启动提示上。",
              "将 `CausedBy` 视为后绑定批注而非事件身份的一部分；echo 匹配也收紧，更长的消息不会认领更短的待发消息。",
              "修复被拒绝的 `AskUserQuestion`（其 `toolUseResult` 为字符串）无法解码；为改键键盘推导左右修饰键，使 AppKit 控制键从硬件输入编码。",
              "iOS Agent 视图不再为每一行重新扫描 transcript；过长的 pane 标题改为截断而不再把侧边栏挤出屏幕；编辑器关闭时不再预留其宽度。",
            ],
          },
          {
            title: "发布说明",
            items: [
              "JSON 控制协议仍为 4.0，Host state schema 未变；本版本不迁移状态。",
              "Warren Browser 需要 Host 可启动的 Chromium，且只有本机 endpoint 能渲染 viewer，因此远端 Host 不会提供 Desktop preset。",
              "本地打包使用现有 Apple Development 签名且未 notarize；归档仅适合内部或临时测试，不适合一般公开分发。",
            ],
          },
        ],
      },
      {
        version: "0.21.0",
        dateISO: "2026-09-20",
        date: "2026 年 9 月 20 日",
        title: "Warren 修复 Agent hook，并让内嵌编辑器保持同步。",
        summary:
          "维护版本：修复过时的 Warren Agent hook，确保 provider 参数不丢失；外观变化时刷新活动中的内嵌编辑器 WebView。JSON 控制协议仍为 4.0。",
        sections: [
          {
            title: "修复",
            items: [
              "按事件规范化所有 Warren 自有的 Agent hook，并只保留一个；清理旧的注释形式重复项，同时保留用户项顺序和第一个自有项的 matcher。手动 Claude overlay 不再丢失 provider 参数，也不会在重启后被误标为 Codex。",
              "外观变化后重新加载活动中的内嵌编辑器 WebView，使 code-server 采用所选主题，同时保留打开的 tab 与编辑内容；settings、注入脚本和页面 chrome 一起更新。",
            ],
          },
          {
            title: "发布说明",
            items: [
              "JSON 控制协议仍为 4.0，Host state schema 仍为 4；本版本不迁移状态。",
              "本地打包使用现有 Apple Development 签名且未 notarize；归档仅适合内部或临时测试，不适合一般公开分发。",
            ],
          },
        ],
      },
      {
        version: "0.20.0",
        dateISO: "2026-09-20",
        date: "2026 年 9 月 20 日",
        title: "Warren 为 Desktop 与 Terminal 带来完整的浅色外观。",
        summary:
          "次版本：新增本机可选的 System、Light 与 Dark 外观，让 Desktop、Terminal、TUI 和内嵌编辑器同步，并收紧终端焦点与指针投递；JSON 控制协议仍为 4.0。",
        sections: [
          {
            title: "新增",
            items: [
              "新增本机外观设置，可选择 System、Light 或 Dark。新的 Ember Paper 调色板覆盖 Desktop chrome、终端 ANSI 颜色、TUI 与内嵌编辑器，并会随所选外观即时切换。",
            ],
          },
          {
            title: "调整",
            items: [
              "终端及其 TUI 跟随 Warren 所选外观，包括 Ghostty 的粗体与对比度行为、OSC 颜色响应，以及编辑器内嵌工作台主题。",
              "让 CLI 帮助与术语表和实际界面一致：补充 `session panes`、可用 Agent provider 与选项、两种移除写法，以及由 Host 所有的 Pane 模型。",
            ],
          },
          {
            title: "修复",
            items: [
              "通过实际运行的 surface 路径投递终端指针、resize 与文本回调，使焦点回答当前键盘所在位置，并能回到仍保留 pane 的 Terminal。",
              "编辑器模型停止后可恢复其区域，保持 Workspace 与 cursor 注册最新，并防止行徽章互相遮挡。",
            ],
          },
          {
            title: "发布说明",
            items: [
              "JSON 控制协议仍为 4.0，Host state schema 仍为 4；本版本不迁移状态。",
              "外观设置仅属于客户端，已有安装仍默认 Dark；System 与 Light 需在 Desktop 设置中主动选择。",
              "本地打包使用现有 Apple Development 签名且未 notarize；归档仅适合内部或临时测试，不适合一般公开分发。",
            ],
          },
        ],
      },
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
  try {
    const stored = localStorage.getItem("warren.locale");
    if (stored === "en" || stored === "zh") return stored;
  } catch {
    // Storage is unavailable in some private modes; fall back to the browser.
  }
  return navigator.language?.toLowerCase().startsWith("zh") ? "zh" : "en";
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
