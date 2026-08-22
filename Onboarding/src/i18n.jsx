import { createContext, useContext, useEffect, useMemo, useState } from "react";

const messages = {
  en: {
    "nav.overview": "Overview",
    "nav.terminal": "Terminal",
    "nav.why": "Why",
    "nav.changelog": "Changelog",
    "nav.source": "Source",
    "hero.kicker": "Local-first development workbench",
    "hero.titleA": "Your terminal,",
    "hero.titleB": "kept alive.",
    "hero.lede":
      "Warren is a local-first workbench for people who live in the terminal. Sessions run on a host — your Mac or a VPS — and survive app quits, network drops, and closing the laptop.",
    "hero.ctaTerminal": "Try the terminal",
    "hero.ctaDocs": "Read the source",
    "hero.ctaDownload": "Download",
    "hero.downloading": "Getting latest…",
    "hero.downloadReady": "Downloading…",
    "hero.downloadFallback": "Open releases",
    "hero.status": "Phase one · open source",
    "hero.platform": "macOS · Web · CLI",
    "ticker.items": ["Detach", "Reconnect", "Resume", "Workspaces", "Sessions", "Agent views"],
    "product.kicker": "Today",
    "product.title": "This is the desktop app.",
    "product.caption": "Projects and workspaces on the left; terminal tabs, sessions and agent views in the middle.",
    "product.alt": "Warren desktop with project sidebar, terminal tabs and an agent view",
    "terminal.kicker": "Interactive demo",
    "terminal.title": "The desktop's terminal engine, try it here",
    "terminal.lede":
      "This demo runs Ghostty's VT parser, compiled to WASM — the same engine that powers the desktop app. It talks to a fake host, but the terminal behavior is real. Type help, then try sessions or detach.",
    "terminal.badge": "ghostty-wasm",
    "terminal.hint": "Click inside and type help",
    "terminal.engineNote": "Demo engine: Ghostty WASM · Warren Web client: xterm.js",
    "features.kicker": "Why Warren",
    "features.title": "Sessions belong to the host.",
    "features.lede": "Everything else in Warren is built around that.",
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
        body: "Codex and Claude transcripts show up as readable conversations, and the raw terminal is still one tab away.",
      },
      {
        title: "Workspace-first Git",
        body: "Projects, main checkouts and worktrees are real resources. Import your existing Superset projects once and move on.",
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
    "architecture.runtimeLine": "ghostline / tmux",
    "architecture.note": "SSH, Tailscale and Cloudflare Tunnel only get you there. They are not the product model.",
    "principle.quote":
      "Closing a tab is the only way to end a session. Quitting, switching workspaces, losing Wi-Fi — that's just walking away.",
    "principle.cite": "Warren product design, §5",
    "footer.line": "Sessions belong to the host.",
    "footer.servedBy": "Served by a Cloudflare Worker",
    "footer.source": "Source",
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
    "product.kicker": "现在",
    "product.title": "这是现在的桌面端。",
    "product.caption": "左边是 Project 和 Workspace，中间是终端 Tab、会话和 Agent 视图。",
    "product.alt": "Warren 桌面端截图：项目侧栏、终端 Tab 和 Agent 视图",
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
    "architecture.runtimeLine": "ghostline / tmux",
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
