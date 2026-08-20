import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { webAssetURL } from "./runtime.js";
import { terminalSearchSummary } from "./terminal.js";
import { terminalTabTitle } from "./title.js";
import { shouldDismissOnBackdrop } from "./presentation.js";

const activityLabels = {
  working: "Working",
  waitingForInput: "Needs input",
  failed: "Failed",
  ready: "Ready",
  exited: "Exited",
  connecting: "Connecting",
};

const activityPriority = {
  failed: 5,
  waitingForInput: 4,
  connecting: 3,
  working: 2,
  ready: 1,
  exited: 0,
};

const terminalIcon = (
  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" aria-hidden="true">
    <rect x="3" y="4" width="18" height="16" rx="2" />
    <path d="m7 9 3 3-3 3m5 0h5" />
  </svg>
);

const folderIcon = (
  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" aria-hidden="true">
    <path d="M3 7h7l2 2h9v10H3z" />
    <path d="M3 7V5h7l2 2" />
  </svg>
);

const pinIcon = (
  <svg viewBox="0 0 24 24" fill="currentColor" stroke="none" aria-hidden="true">
    <path d="M15 3v6l2 2v2h-4v7l-1 1-1-1v-7H7v-2l2-2V3h6z" />
  </svg>
);

const mergeIcon = (
  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
    <circle cx="6" cy="6" r="2.4" />
    <circle cx="18" cy="18" r="2.4" />
    <path d="M8.4 6H12a4 4 0 0 1 4 4v5.6" />
  </svg>
);

const moreIcon = (
  <svg viewBox="0 0 24 24" fill="currentColor" stroke="none" aria-hidden="true">
    <circle cx="5" cy="12" r="1.7" />
    <circle cx="12" cy="12" r="1.7" />
    <circle cx="19" cy="12" r="1.7" />
  </svg>
);

const MenuIcon = (
  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" aria-hidden="true">
    <path d="M4 7h16M4 12h16M4 17h16" />
  </svg>
);

const ChevronLeftIcon = (
  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" aria-hidden="true">
    <path d="m15 6-6 6 6 6" />
  </svg>
);

const ChevronRightIcon = (
  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" aria-hidden="true">
    <path d="m9 6 6 6-6 6" />
  </svg>
);

const GitIcon = (
  <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
    <circle cx="4" cy="4" r="1.6" />
    <circle cx="4" cy="12" r="1.6" />
    <circle cx="12" cy="6" r="1.6" />
    <path d="M4 5.6v4.8M4 5.6c2.5.4 4.5 1.8 5.2 4.1" />
    <path d="M12 7.6v.2a2.2 2.2 0 0 1-2.2 2.2" />
  </svg>
);

function useBuildVariant() {
  // The Vite dev server is always a preview build. In production the daemon
  // serves a build-variant.txt stamped by scripts/build-app.sh, so a Web UI
  // shipped by a release install stays unmarked.
  const [isBuild, setIsBuild] = useState(() => import.meta.env.DEV);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const response = await fetch(webAssetURL("build-variant.txt"), { cache: "no-store" });
        if (!response.ok) return;
        const value = (await response.text()).trim();
        if (!cancelled) setIsBuild(value === "build");
      } catch {
        // Keep the dev-server default; a release install without a marker
        // stays unmarked.
      }
    })();
    return () => {
      cancelled = true;
    };
  }, []);

  return isBuild;
}

export function ActivityDot({ activity }) {
  const label = activityLabels[activity];
  if (!label) return null;
  const pulse = activity === "ready" || activity === "exited" ? "" : " pulse";
  return <span className={`activity ${activity}${pulse}`} title={label} aria-label={label} />;
}

function mergedBadgeTitle(tabs) {
  const count = tabs.length;
  const parts = ["Merged to default branch"];
  if (count) parts.push(`${count} active`);
  const activity = activityLabels[highestActivity(tabs)];
  if (activity) parts.push(activity);
  return parts.join(" · ");
}

export function MergedBadge({ tabs = [] }) {
  const label = mergedBadgeTitle(tabs);
  return (
    <span className="merge-badge" title={label} aria-label={label} role="img">
      {mergeIcon}
    </span>
  );
}

function SessionPresetIcon({ kind }) {
  const asset = kind === "codex" ? "preset-codex-white.svg" : `preset-${kind}.svg`;
  return (
    <span className={`preset-brand-icon preset-brand-icon-${kind}`} aria-hidden="true">
      <img src={webAssetURL(asset)} alt="" />
    </span>
  );
}

export function Sidebar({
  catalog,
  activeWorkspace,
  expandedProjects,
  tabsForWorkspace,
  connection,
  onToggleProject,
  onChooseWorkspace,
  onOpenWorkspace,
  onNewSessionInWorkspace,
  onNewSession,
  onOpenSettings,
  onProjectContextMenu,
  onWorkspaceContextMenu,
  onMoveProject,
  onMoveWorkspace,
  onBeginProjectDrag,
  onEndProjectDrag,
}) {
  const isBuild = useBuildVariant();
  const [dragState, setDragState] = useState(null);
  const [dragOverID, setDragOverID] = useState(null);
  const [dragOverPosition, setDragOverPosition] = useState(null);

  const beginDrag = (kind, id, projectID, event) => {
    event.dataTransfer.effectAllowed = "move";
    event.dataTransfer.setData("text/plain", id);
    setDragOverID(null);
    setDragOverPosition(null);
    setDragState({ kind, id, projectID });
    if (kind === "project") onBeginProjectDrag(expandedProjects);
  };

  const endDrag = () => {
    if (dragState?.kind === "project") onEndProjectDrag();
    setDragState(null);
    setDragOverID(null);
    setDragOverPosition(null);
  };

  const projectDragOver = (projectID, event) => {
    if (dragState?.kind !== "project") return;
    event.preventDefault();
    event.dataTransfer.dropEffect = "move";
    const rect = event.currentTarget.getBoundingClientRect();
    const position = event.clientY < rect.top + rect.height / 2 ? "before" : "after";
    if (dragOverID !== projectID || dragOverPosition !== position) {
      setDragOverID(projectID);
      setDragOverPosition(position);
    }
  };

  const workspaceDragOver = (workspace, event) => {
    if (dragState?.kind !== "workspace" || dragState.projectID !== workspace.project) return;
    event.preventDefault();
    event.dataTransfer.dropEffect = "move";
    if (dragOverID !== workspace.id) setDragOverID(workspace.id);
  };

  const dropProject = (projectID, event) => {
    if (dragState?.kind !== "project") return;
    event.preventDefault();
    const rect = event.currentTarget.getBoundingClientRect();
    const beforeProjectID = event.clientY < rect.top + rect.height / 2
      ? projectID
      : projectAfter(projectID);
    onMoveProject(dragState.id, beforeProjectID);
    endDrag();
  };

  const projectIDs = catalog.projects.map(project => project.id);

  const projectAfter = projectID => {
    const index = projectIDs.indexOf(projectID);
    if (index < 0 || index + 1 >= projectIDs.length) return null;
    return projectIDs[index + 1];
  };

  const dropWorkspace = (workspace, event) => {
    if (dragState?.kind !== "workspace" || dragState.projectID !== workspace.project) return;
    event.preventDefault();
    onMoveWorkspace(dragState.id, workspace.id);
    endDrag();
  };

  return (
    <aside className="sidebar" aria-label="Projects and workspaces">
      <div className="brand">
        <img className="brand-mark" src={webAssetURL("icon.svg")} alt="Warren" />
        {isBuild && <span className="build-badge">Build</span>}
        <span className={`connection${connection.online ? " online" : ""}`}>
          <span className="connection-dot" />
          <span>{connection.message}</span>
        </span>
      </div>
      <div className="sidebar-scroll">
        <div className="section-label">Projects</div>
        {catalog.projects.length ? catalog.projects.map(project => {
          const workspaces = catalog.workspacesByProject.get(project.id) || [];
          const open = expandedProjects.has(project.id);
          return (
            <section className={`project${open ? " open" : ""}`} key={project.id}>
              <div
                className={`project-toggle${dragOverID === project.id ? " drag-over" : ""}${dragOverID === project.id && dragOverPosition === "before" ? " drag-before" : ""}${dragOverID === project.id && dragOverPosition === "after" ? " drag-after" : ""}`}
                onContextMenu={event => onProjectContextMenu(event, project)}
                draggable
                onDragStart={event => beginDrag("project", project.id, null, event)}
                onDragEnd={endDrag}
                onDragOver={event => projectDragOver(project.id, event)}
                onDrop={event => dropProject(project.id, event)}
              >
                <button
                  type="button"
                  className="project-toggle-main"
                  aria-expanded={open}
                  onClick={() => onToggleProject(project.id)}
                >
                  <span className="branch">{project.name}</span>
                  {project.pinned && <span className="pin-icon" title="Pinned">{pinIcon}</span>}
                  <span className="project-count">({workspaces.length})</span>
                </button>
                {workspaces[0] && (
                  <button
                    type="button"
                    className="project-add"
                    aria-label={`New session in ${project.name}`}
                    title="New session"
                    onClick={event => {
                      event.stopPropagation();
                      (onNewSessionInWorkspace || onOpenWorkspace)(workspaces[0].id);
                    }}
                  >
                    <PlusIcon />
                  </button>
                )}
                <button
                  type="button"
                  className="project-chevron"
                  aria-label={open ? `Collapse ${project.name}` : `Expand ${project.name}`}
                  onClick={() => onToggleProject(project.id)}
                >
                  <span className="chevron">{ChevronRightIcon}</span>
                </button>
              </div>
              <div className="workspace-list">
                {workspaces.map(workspace => (
                  <button
                    type="button"
                    className={`workspace-row${workspace.id === activeWorkspace ? " active" : ""}${dragOverID === workspace.id ? " drag-over" : ""}`}
                    key={workspace.id}
                    onClick={() => onChooseWorkspace(workspace.id)}
                    onDoubleClick={() => onOpenWorkspace(workspace.id)}
                    onContextMenu={event => onWorkspaceContextMenu(event, workspace)}
                    draggable
                    onDragStart={event => beginDrag("workspace", workspace.id, workspace.project, event)}
                    onDragEnd={endDrag}
                    onDragOver={event => workspaceDragOver(workspace, event)}
                    onDrop={event => dropWorkspace(workspace, event)}
                  >
                    {workspace.mergeState === "merged"
                      ? <MergedBadge tabs={tabsForWorkspace(workspace.id)} />
                      : <ActivityDot activity={highestActivity(tabsForWorkspace(workspace.id))} />}
                    {workspace.pinned && <span className="pin-icon" title="Pinned">{pinIcon}</span>}
                    <span className="branch">{workspace.branch || workspace.name || "Workspace"}</span>
                  </button>
                ))}
                {dragState?.kind === "workspace" && dragState.projectID === project.id && (
                  <div
                    className={`sidebar-drop-end${dragOverID === "__workspace_end" ? " drag-over" : ""}`}
                    onDragOver={event => {
                      event.preventDefault();
                      event.dataTransfer.dropEffect = "move";
                      if (dragOverID !== "__workspace_end") setDragOverID("__workspace_end");
                    }}
                    onDrop={event => {
                      if (dragState?.kind !== "workspace") return;
                      event.preventDefault();
                      onMoveWorkspace(dragState.id, null);
                      endDrag();
                    }}
                  />
                )}
              </div>
            </section>
          );
        }) : <div className="workspace-row">No projects</div>}
        {dragState?.kind === "project" && (
          <div
            className={`sidebar-drop-end${dragOverID === "__project_end" ? " drag-over" : ""}`}
            onDragOver={event => {
              event.preventDefault();
              event.dataTransfer.dropEffect = "move";
              if (dragOverID !== "__project_end") setDragOverID("__project_end");
            }}
            onDrop={event => {
              if (dragState?.kind !== "project") return;
              event.preventDefault();
              onMoveProject(dragState.id, null);
              endDrag();
            }}
          />
        )}
      </div>
      <footer className="sidebar-footer">
        <button
          type="button"
          className="footer-new-session"
          disabled={!activeWorkspace}
          onClick={onNewSession}
        >
          <PlusIcon />
          <span>New session</span>
        </button>
        <button type="button" className="chrome-button" aria-label="Settings" onClick={onOpenSettings}>
          <SettingsIcon />
        </button>
      </footer>
    </aside>
  );
}

export function TopBar({
  tabs,
  activeSession,
  workspace,
  onAttachSession,
  onNewSession,
  onOpenMenu,
  onOpenSearch,
  onToggleGit,
  gitActive,
  onTabContextMenu,
}) {
  const tabRefs = useRef(new Map());
  const tabsRef = useRef(null);
  const [hasOverflow, setHasOverflow] = useState(false);
  const [canScrollLeft, setCanScrollLeft] = useState(false);
  const [canScrollRight, setCanScrollRight] = useState(false);

  const updateOverflow = useCallback(() => {
    const el = tabsRef.current;
    if (!el) return;
    const maxScrollLeft = el.scrollWidth - el.clientWidth;
    setHasOverflow(maxScrollLeft > 1);
    setCanScrollLeft(el.scrollLeft > 1);
    setCanScrollRight(el.scrollLeft < maxScrollLeft - 1);
  }, []);

  useEffect(() => {
    const el = tabsRef.current;
    if (!el) return;
    const observer = new ResizeObserver(updateOverflow);
    observer.observe(el);
    el.addEventListener("scroll", updateOverflow, { passive: true });
    window.addEventListener("resize", updateOverflow);
    updateOverflow();
    return () => {
      observer.disconnect();
      el.removeEventListener("scroll", updateOverflow);
      window.removeEventListener("resize", updateOverflow);
    };
  }, [updateOverflow, tabs]);

  useEffect(() => {
    if (!activeSession) return;
    const node = tabRefs.current.get(activeSession);
    node?.scrollIntoView({ inline: "nearest", block: "nearest", behavior: "smooth" });
  }, [activeSession, tabs]);

  const scrollTabs = useCallback(direction => {
    const el = tabsRef.current;
    if (!el) return;
    const distance = Math.max(160, el.clientWidth * 0.8);
    el.scrollBy({ left: direction === "left" ? -distance : distance, behavior: "smooth" });
  }, []);

  const handleTabListKeyDown = event => {
    const keys = ["ArrowRight", "ArrowLeft", "Home", "End"];
    if (!keys.includes(event.key)) return;
    if (!tabs.length) return;
    const current = Math.max(0, tabs.findIndex(session => session.id === activeSession));
    let next = current;
    if (event.key === "ArrowRight") next = (current + 1) % tabs.length;
    else if (event.key === "ArrowLeft") next = (current - 1 + tabs.length) % tabs.length;
    else if (event.key === "Home") next = 0;
    else if (event.key === "End") next = tabs.length - 1;
    event.preventDefault();
    const session = tabs[next];
    if (!session) return;
    onAttachSession(session.id);
    tabRefs.current.get(session.id)?.focus();
  };

  return (
    <header className="topbar">
      <button type="button" className="menu-button" aria-label="Open navigation" onClick={onOpenMenu}>{MenuIcon}</button>
      <div className="tabs-wrap">
        {hasOverflow && canScrollLeft && (
          <button
            type="button"
            className="tabs-chevron tabs-chevron-left"
            aria-label="Earlier tabs"
            onClick={() => scrollTabs("left")}
          >
            {ChevronLeftIcon}
          </button>
        )}
        <div
          ref={tabsRef}
          className={`tabs${canScrollLeft ? " fade-left" : ""}${canScrollRight ? " fade-right" : ""}`}
          role="tablist"
          aria-label="Sessions"
          onKeyDown={handleTabListKeyDown}
        >
          {tabs.map(session => {
            const active = session.id === activeSession;
            return (
              <button
                type="button"
                role="tab"
                aria-selected={active}
                className={`tab${active ? " active" : ""}`}
                key={session.id}
                onClick={() => onAttachSession(session.id)}
                onContextMenu={event => onTabContextMenu(event, session)}
                ref={node => {
                  if (node) tabRefs.current.set(session.id, node);
                  else tabRefs.current.delete(session.id);
                }}
              >
                <ActivityDot activity={session.activity} />
                {session.pinned && <span className="pin-icon" title="Pinned">{pinIcon}</span>}
                <span className="tab-title">{terminalTabTitle(session, workspace)}</span>
              </button>
            );
          })}
        </div>
        {hasOverflow && canScrollRight && (
          <button
            type="button"
            className="tabs-chevron tabs-chevron-right"
            aria-label="More tabs"
            onClick={() => scrollTabs("right")}
          >
            {ChevronRightIcon}
          </button>
        )}
      </div>
      <button type="button" className="new-session" aria-label="New shell" onClick={onNewSession}>
        <PlusIcon />
      </button>
      <div className="chrome-spacer" />
      <button
        type="button"
        className={`chrome-button${gitActive ? " active" : ""}`}
        aria-label="Toggle Git panel"
        aria-pressed={gitActive}
        onClick={onToggleGit}
      >
        {GitIcon}
      </button>
      <button type="button" className="chrome-button" aria-label="Search projects" onClick={onOpenSearch}>
        <SearchIcon />
      </button>
    </header>
  );
}

export function MobileShell({
  workspace,
  tabs,
  activeSession,
  connection,
  agentSession,
  agentViewActive,
  agentModel,
  onAttachSession,
  onToggleAgentView,
  onOpenMenu,
  onOpenSearch,
  onNewSession,
  onOpenSessionMenu,
  onSessionContextMenu,
}) {
  const handleTabListKeyDown = event => {
    const keys = ["ArrowRight", "ArrowLeft", "Home", "End"];
    if (!keys.includes(event.key) || !tabs.length) return;
    const current = Math.max(0, tabs.findIndex(session => session.id === activeSession));
    let next = current;
    if (event.key === "ArrowRight") next = (current + 1) % tabs.length;
    else if (event.key === "ArrowLeft") next = (current - 1 + tabs.length) % tabs.length;
    else if (event.key === "Home") next = 0;
    else if (event.key === "End") next = tabs.length - 1;
    event.preventDefault();
    const session = tabs[next];
    if (!session) return;
    onAttachSession(session.id);
    document.querySelector(`.mobile-tab[data-session="${session.id}"]`)?.focus();
  };

  return (
    <header className="mobile-shell">
      <div className="mobile-command">
        <button type="button" className="menu-button" aria-label="Open navigation" onClick={onOpenMenu}>{MenuIcon}</button>
        <div className="mobile-workspace" title={connection.message}>
          <span className="mobile-workspace-name">{workspace?.branch || workspace?.name || "Warren"}</span>
          <span className={`mobile-connection${connection.online ? " online" : ""}`} aria-label={connection.message}>
            <span className="connection-dot" />
          </span>
        </div>
        {agentSession && (
          <div className="agent-view-toggle" role="group" aria-label="View" title={agentModel ? `Model: ${agentModel}` : undefined}>
            <button
              type="button"
              className={agentViewActive ? undefined : "active"}
              aria-pressed={!agentViewActive}
              onClick={() => onToggleAgentView("terminal")}
            >
              Term
            </button>
            <button
              type="button"
              className={agentViewActive ? "active" : undefined}
              aria-pressed={agentViewActive}
              onClick={() => onToggleAgentView("agent")}
            >
              Chat
            </button>
          </div>
        )}
        <div className="chrome-spacer" />
        {activeSession && (
          <button type="button" className="chrome-button" aria-label="Session actions" onClick={onOpenSessionMenu}>
            {moreIcon}
          </button>
        )}
        <button type="button" className="chrome-button" aria-label="Search projects" onClick={onOpenSearch}>
          <SearchIcon />
        </button>
        <button type="button" className="new-session" aria-label="New session" onClick={onNewSession}>
          <PlusIcon />
        </button>
      </div>
      <nav className="mobile-tabs" role="tablist" aria-label="Sessions" onKeyDown={handleTabListKeyDown}>
        {tabs.map(session => {
          const active = session.id === activeSession;
          return (
            <button
              type="button"
              role="tab"
              data-session={session.id}
              aria-selected={active}
              className={`mobile-tab${active ? " active" : ""}`}
              key={session.id}
              onClick={() => onAttachSession(session.id)}
              onContextMenu={event => onSessionContextMenu?.(event, session)}
            >
              <ActivityDot activity={session.activity} />
              <span className="mobile-tab-title">{terminalTabTitle(session, workspace)}</span>
            </button>
          );
        })}
      </nav>
    </header>
  );
}

export function ContextMenu({ menu, onClose }) {
  const menuRef = useRef(null);
  const [mobile, setMobile] = useState(() => window.matchMedia("(max-width: 767px)").matches);

  useEffect(() => {
    const media = window.matchMedia("(max-width: 767px)");
    const onChange = event => setMobile(event.matches);
    media.addEventListener("change", onChange);
    return () => media.removeEventListener("change", onChange);
  }, []);

  useEffect(() => {
    if (!menu) return undefined;
    const items = () => Array.from(menuRef.current?.querySelectorAll('[role="menuitem"]') || []);
    const first = items()[0] || menuRef.current?.querySelector("button");
    first?.focus();
    const handlePointerDown = event => {
      if (!menuRef.current?.contains(event.target)) onClose();
    };
    const handleKeyDown = event => {
      if (event.key === "Escape") onClose();
      else if (["ArrowDown", "ArrowUp", "Home", "End"].includes(event.key)) {
        event.preventDefault();
        const list = items();
        if (!list.length) return;
        const current = Math.max(0, list.indexOf(document.activeElement));
        let next = current;
        if (event.key === "ArrowDown") next = (current + 1) % list.length;
        else if (event.key === "ArrowUp") next = (current - 1 + list.length) % list.length;
        else if (event.key === "Home") next = 0;
        else if (event.key === "End") next = list.length - 1;
        list[next]?.focus();
      }
    };
    window.addEventListener("pointerdown", handlePointerDown);
    window.addEventListener("keydown", handleKeyDown);
    window.addEventListener("blur", onClose);
    return () => {
      window.removeEventListener("pointerdown", handlePointerDown);
      window.removeEventListener("keydown", handleKeyDown);
      window.removeEventListener("blur", onClose);
    };
  }, [menu, onClose]);

  if (!menu) return null;
  return (
    <div
      ref={menuRef}
      className="context-menu"
      role={mobile ? "dialog" : "menu"}
      aria-modal={mobile ? "true" : undefined}
      aria-label={mobile ? "Actions" : undefined}
      style={{ left: menu.x, top: menu.y }}
    >
      {menu.items.map((item, index) => (
        <button
          type="button"
          role={mobile ? undefined : "menuitem"}
          className={item.danger ? "danger" : undefined}
          key={index}
          onClick={() => {
            onClose();
            item.action();
          }}
        >
          {item.label}
        </button>
      ))}
    </div>
  );
}

export function PresetBar({ presets, onCreateSession }) {
  return (
    <nav className="presetbar" aria-label="Session presets">
      {presets.map(preset => (
        <button type="button" className="preset" key={preset.kind} onClick={() => onCreateSession(preset.kind)}>
          <SessionPresetIcon kind={preset.kind} />
          {preset.label}
        </button>
      ))}
    </nav>
  );
}

export function EmptyTerminal({
  activeWorkspace,
  activeSession,
  attachedSession,
  tabCount,
  projectCount,
  override,
  onNewSession,
}) {
  let content;
  let hidden = false;

  if (override) {
    content = override.loading ? <Loading message={override.message} /> : <span>{override.message}</span>;
  } else if (activeSession && attachedSession === activeSession) {
    hidden = true;
    content = null;
  } else if (activeSession) {
    content = <Loading message="Connecting…" />;
  } else if (activeWorkspace && tabCount) {
    content = (
      <div className="empty-state">
        <div className="empty-title">Select a session</div>
        <p className="empty-hint">Choose a tab above to open its terminal.</p>
      </div>
    );
  } else if (activeWorkspace) {
    content = (
      <div className="empty-state">
        {terminalIcon}
        <div className="empty-title">Start a session</div>
        <p className="empty-hint">Create a shell in this workspace to get started.</p>
        <button type="button" className="empty-action" onClick={onNewSession}>New session</button>
      </div>
    );
  } else {
    content = (
      <div className="empty-state">
        {folderIcon}
        <div className="empty-title">{projectCount ? "Select a workspace" : "No projects on this host"}</div>
        <p className="empty-hint">
          {projectCount
            ? "Choose a workspace from the sidebar to open its sessions."
            : "Projects appear here after you connect to a host."}
        </p>
      </div>
    );
  }

  return <div className="terminal-empty" hidden={hidden}>{content}</div>;
}

export function TerminalSearch({
  open,
  query,
  resultIndex,
  resultCount,
  focusNonce,
  onQueryChange,
  onNext,
  onPrevious,
  onClose,
}) {
  const inputRef = useRef(null);

  useEffect(() => {
    if (open) inputRef.current?.focus();
  }, [open, focusNonce]);

  const handleKeyDown = event => {
    if (event.key === "Enter") {
      event.preventDefault();
      if (event.shiftKey) onPrevious();
      else onNext();
    } else if (event.key === "Escape") {
      event.preventDefault();
      onClose();
    }
  };

  if (!open) return null;

  const summary = terminalSearchSummary(resultIndex, resultCount, Boolean(query));
  const hasMatches = Boolean(query) && resultCount > 0;
  return (
    <div className="terminal-search" role="search" aria-label="Search terminal">
      <SearchIcon />
      <input
        ref={inputRef}
        value={query}
        onChange={event => onQueryChange(event.target.value)}
        onKeyDown={handleKeyDown}
        placeholder="Find…"
        aria-label="Find in terminal"
        autoComplete="off"
        spellCheck="false"
      />
      <span className="terminal-search-count">{summary}</span>
      <button type="button" aria-label="Previous match" title="Previous match (⇧↵)" disabled={!hasMatches} onClick={onPrevious}>
        <ChevronUpIcon />
      </button>
      <button type="button" aria-label="Next match" title="Next match (↵)" disabled={!hasMatches} onClick={onNext}>
        <ChevronDownIcon />
      </button>
      <button type="button" aria-label="Close search" title="Close search (esc)" onClick={onClose}>
        <CloseIcon />
      </button>
    </div>
  );
}

export function MobileKeys({ onInput }) {
  const [extended, setExtended] = useState(false);
  // The primary row is always visible; Ctrl chords expand on demand so the
  // keyboard never eats the terminal by default.
  const keyRows = [
    [
      ["escape", "Esc", "\u001b"],
      ["tab", "Tab", "\t"],
      ["home", "Home", "\u001b[H"],
      ["end", "End", "\u001b[F"],
      ["up", "↑", "\u001b[A"],
      ["down", "↓", "\u001b[B"],
      ["left", "←", "\u001b[D"],
      ["right", "→", "\u001b[C"],
    ],
    [
      ["ctrlC", "Ctrl-C", "\u0003"],
      ["ctrlD", "Ctrl-D", "\u0004"],
      ["ctrlA", "Ctrl-A", "\u0001"],
      ["ctrlE", "Ctrl-E", "\u0005"],
      ["ctrlU", "Ctrl-U", "\u0015"],
      ["ctrlK", "Ctrl-K", "\u000b"],
      ["ctrlL", "Ctrl-L", "\u000c"],
    ],
  ];

  return (
    <nav className="mobile-keys" aria-label="Terminal keys">
      <div className="mobile-key-row">
        {keyRows[0].map(([key, label, sequence]) => (
          <button type="button" className="mobile-key" key={key} onClick={() => onInput(sequence)}>{label}</button>
        ))}
        <button
          type="button"
          className={`mobile-key mobile-key-toggle${extended ? " active" : ""}`}
          aria-pressed={extended}
          aria-label={extended ? "Hide Ctrl keys" : "Show Ctrl keys"}
          onClick={() => setExtended(previous => !previous)}
        >
          Ctrl
        </button>
      </div>
      {extended && (
        <div className="mobile-key-row">
          {keyRows[1].map(([key, label, sequence]) => (
            <button type="button" className="mobile-key" key={key} onClick={() => onInput(sequence)}>{label}</button>
          ))}
        </div>
      )}
    </nav>
  );
}

export function SessionSheet({ open, presets, onChoose, onClose }) {
  const firstItemRef = useRef(null);

  useEffect(() => {
    if (!open) return undefined;
    firstItemRef.current?.focus();
    const handleKeyDown = event => {
      if (event.key === "Escape") onClose();
    };
    document.addEventListener("keydown", handleKeyDown);
    return () => document.removeEventListener("keydown", handleKeyDown);
  }, [open, onClose]);

  if (!open) return null;
  return (
    <div className="session-sheet-overlay" onClick={onClose}>
      <div
        className="session-sheet"
        role="dialog"
        aria-modal="true"
        aria-label="New session"
        onClick={event => event.stopPropagation()}
      >
        <div className="session-sheet-handle" aria-hidden="true" />
        <div className="session-sheet-title">New session</div>
        {presets.map((preset, index) => (
          <button
            type="button"
            className="session-sheet-item"
            key={preset.kind}
            ref={index === 0 ? firstItemRef : undefined}
            onClick={() => onChoose(preset.kind)}
          >
            <SessionPresetIcon kind={preset.kind} />
            <span>{preset.label}</span>
          </button>
        ))}
        <button type="button" className="session-sheet-cancel" onClick={onClose}>Cancel</button>
      </div>
    </div>
  );
}

export function WorktreeImportDialog({ dialog, onClose, onToggle, onImport }) {
  const firstItemRef = useRef(null);

  useEffect(() => {
    if (!dialog) return undefined;
    firstItemRef.current?.focus();
    const handleKeyDown = event => {
      if (event.key === "Escape") onClose();
    };
    document.addEventListener("keydown", handleKeyDown);
    return () => document.removeEventListener("keydown", handleKeyDown);
  }, [dialog, onClose]);

  if (!dialog) return null;
  const candidates = Array.isArray(dialog.candidates) ? dialog.candidates : [];
  const selected = new Set(dialog.selectedPaths || []);
  const availableCount = candidates.filter(candidate => !candidate.imported).length;

  return (
    <div
      className="worktree-dialog-overlay"
      onClick={() => {
        if (shouldDismissOnBackdrop("sheet", dialog.loading || selected.size > 0)) onClose();
      }}
    >
      <div
        className="worktree-dialog"
        role="dialog"
        aria-modal="true"
        aria-labelledby="worktree-dialog-title"
        onClick={event => event.stopPropagation()}
      >
        <div className="worktree-dialog-header">
          <div>
            <h2 id="worktree-dialog-title">Import existing worktrees</h2>
            <p>Choose Git worktrees to register under <strong>{dialog.project.name}</strong>. This is a one-time import: Warren does not create, move, or delete files.</p>
          </div>
          <button type="button" className="worktree-dialog-close" aria-label="Close" onClick={onClose}>×</button>
        </div>
        <div className="worktree-dialog-body">
          {dialog.loading ? (
            <Loading message="Reading Git worktrees…" />
          ) : dialog.error ? (
            <div className="worktree-dialog-error" role="alert">{dialog.error}</div>
          ) : !candidates.length ? (
            <div className="worktree-dialog-empty">No external Git worktrees are available to import.</div>
          ) : (
            <div className="worktree-candidate-list" role="listbox" aria-label="Existing Git worktrees" aria-multiselectable="true">
              {candidates.map((candidate, index) => {
                const imported = Boolean(candidate.imported);
                const checked = selected.has(candidate.path);
                return (
                  <button
                    type="button"
                    role="option"
                    aria-selected={checked}
                    aria-disabled={imported}
                    className={`worktree-candidate${checked ? " selected" : ""}${imported ? " imported" : ""}`}
                    key={candidate.path}
                    ref={index === 0 ? firstItemRef : undefined}
                    disabled={imported}
                    onClick={() => onToggle(candidate.path)}
                  >
                    <span className="worktree-candidate-check" aria-hidden="true">{checked ? "☑" : "☐"}</span>
                    <span className="worktree-candidate-copy">
                      <span className="worktree-candidate-title">
                        <span>{candidate.name || candidate.branch || "Worktree"}</span>
                        {candidate.branch && candidate.branch !== candidate.name && <code>{candidate.branch}</code>}
                        {candidate.locked && <span className="worktree-candidate-badge">Locked</span>}
                        {imported && <span className="worktree-candidate-badge">Imported</span>}
                      </span>
                      <span className="worktree-candidate-path">{candidate.path}</span>
                    </span>
                  </button>
                );
              })}
            </div>
          )}
        </div>
        <div className="worktree-dialog-footer">
          <span className="worktree-dialog-summary">
            {dialog.loading ? "" : `${selected.size} selected · ${availableCount} available`}
          </span>
          <div className="worktree-dialog-actions">
            <button type="button" className="worktree-dialog-secondary" onClick={onClose}>Cancel</button>
            <button
              type="button"
              className="worktree-dialog-primary"
              disabled={dialog.loading || Boolean(dialog.error) || selected.size === 0}
              onClick={onImport}
            >
              Import selected
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}

export function TextInputDialog({
  title,
  message,
  fieldLabel,
  initialValue,
  confirmLabel = "Rename",
  destructive = false,
  onCancel,
  onConfirm,
}) {
  const inputRef = useRef(null);
  const [text, setText] = useState(initialValue || "");

  useEffect(() => {
    inputRef.current?.focus();
    const handleKeyDown = event => {
      if (event.key === "Escape") {
        event.stopPropagation();
        onCancel();
      }
    };
    document.addEventListener("keydown", handleKeyDown);
    return () => document.removeEventListener("keydown", handleKeyDown);
  }, [onCancel]);

  const submit = () => {
    const trimmed = text.trim();
    if (trimmed) onConfirm(trimmed);
  };

  return (
    <div className="warren-dialog-overlay">
      <div
        className="warren-dialog"
        role="dialog"
        aria-modal="true"
        aria-labelledby="warren-dialog-title"
      >
        <h2 id="warren-dialog-title" className="warren-dialog-title">{title}</h2>
        {message && <p className="warren-dialog-message">{message}</p>}
        <label className="warren-dialog-field">
          <span>{fieldLabel}</span>
          <input
            ref={inputRef}
            value={text}
            onChange={event => setText(event.target.value)}
            onKeyDown={event => {
              if (event.key === "Enter") {
                event.preventDefault();
                submit();
              }
            }}
            autoComplete="off"
            spellCheck="false"
          />
        </label>
        <div className="warren-dialog-actions">
          <button type="button" className="warren-dialog-button secondary" onClick={onCancel}>
            Cancel
          </button>
          <button
            type="button"
            className={`warren-dialog-button ${destructive ? "danger" : "primary"}`}
            disabled={!text.trim()}
            onClick={submit}
          >
            {confirmLabel}
          </button>
        </div>
      </div>
    </div>
  );
}

export function ConfirmationDialog({
  title,
  message,
  confirmLabel = "Delete",
  onCancel,
  onConfirm,
}) {
  const cancelRef = useRef(null);

  useEffect(() => {
    cancelRef.current?.focus();
    const handleKeyDown = event => {
      if (event.key === "Escape") {
        event.stopPropagation();
        onCancel();
      }
    };
    document.addEventListener("keydown", handleKeyDown);
    return () => document.removeEventListener("keydown", handleKeyDown);
  }, [onCancel]);

  return (
    <div className="warren-dialog-overlay">
      <div
        className="warren-dialog"
        role="dialog"
        aria-modal="true"
        aria-labelledby="warren-dialog-title"
      >
        <h2 id="warren-dialog-title" className="warren-dialog-title">{title}</h2>
        {message && <p className="warren-dialog-message">{message}</p>}
        <div className="warren-dialog-actions">
          <button
            ref={cancelRef}
            type="button"
            className="warren-dialog-button secondary"
            onClick={onCancel}
          >
            Cancel
          </button>
          <button type="button" className="warren-dialog-button danger" onClick={onConfirm}>
            {confirmLabel}
          </button>
        </div>
      </div>
    </div>
  );
}

export function SettingsPage({
  open,
  fontFamily,
  fontSize,
  titleTemplate,
  presetCommands,
  presets,
  hiddenPresets = [],
  autoOpenShell,
  autoStartAI,
  titlePreview,
  placeholders,
  onClose,
  onFontFamilyChange,
  onFontSizeChange,
  onTitleTemplateChange,
  onPresetCommandChange,
  onPresetVisibilityChange,
  onAutoOpenShellChange,
  onAutoStartAIChange,
  onMovePreset,
  onAppendPlaceholder,
  onRestore,
}) {
  const [activeSection, setActiveSection] = useState("font");
  const [searchQuery, setSearchQuery] = useState("");

  const sections = useMemo(() => [
    {
      id: "font",
      label: "Font",
      description: "Applied to every web terminal.",
      keywords: ["font", "family", "size", "typography"],
    },
    {
      id: "title",
      label: "Title",
      description: "Build a title from live Session metadata.",
      keywords: ["title", "template", "placeholder", "preview"],
    },
    {
      id: "presets",
      label: "Presets",
      description: "Choose visible presets and customize every launch command.",
      keywords: ["preset", "command", "launch", "shell", "claude", "codex", "trae", "agent", "visible", "hidden"],
    },
    {
      id: "workspaces",
      label: "Workspaces",
      description: "Control project import and workspace entry defaults.",
      keywords: ["workspace", "project", "git", "worktree", "import", "shell", "open"],
    },
  ], []);

  const needle = searchQuery.trim().toLowerCase();
  const visibleSections = useMemo(() => {
    if (!needle) return sections;
    return sections.filter(section =>
      [section.label, section.description, ...section.keywords]
        .some(value => String(value).toLowerCase().includes(needle)),
    );
  }, [needle, sections]);

  useEffect(() => {
    if (!open) setSearchQuery("");
  }, [open]);

  useEffect(() => {
    if (needle && visibleSections.length && !visibleSections.some(section => section.id === activeSection)) {
      setActiveSection(visibleSections[0].id);
    }
  }, [needle, activeSection, visibleSections]);

  return (
    <section className={`settings-page settings${open ? " open" : ""}`} aria-label="Settings">
      <nav className="settings-nav" aria-label="Settings sections">
        <div className="settings-nav-top">
          <button type="button" className="settings-back" aria-label="Back to Warren" onClick={onClose}>
            <BackIcon />
            <span>Back</span>
          </button>
          <h1 className="settings-title">Settings</h1>
        </div>
        <div className="settings-search">
          <SearchIcon />
          <label className="visually-hidden" htmlFor="settings-search">Search settings</label>
          <input
            id="settings-search"
            value={searchQuery}
            onChange={event => setSearchQuery(event.target.value)}
            placeholder="Search settings…"
            autoComplete="off"
            spellCheck="false"
          />
          {searchQuery && (
            <button
              type="button"
              className="settings-search-clear"
              aria-label="Clear settings search"
              onClick={() => setSearchQuery("")}
            >
              <CloseIcon />
            </button>
          )}
        </div>
        <div className="settings-nav-scroll">
          <div className="settings-nav-label">Terminal</div>
          {visibleSections.map(section => (
            <button
              type="button"
              className={`settings-nav-item${activeSection === section.id ? " active" : ""}`}
              aria-current={activeSection === section.id ? "true" : undefined}
              key={section.id}
              onClick={() => setActiveSection(section.id)}
            >
              {section.id === "font"
                ? terminalIcon
                : section.id === "title"
                  ? <TitleIcon />
                  : section.id === "workspaces"
                    ? <BranchIcon />
                    : <PresetIcon />}
              <span>{section.label}</span>
            </button>
          ))}
          {!visibleSections.length && <div className="settings-nav-empty">No settings match your search</div>}
        </div>
      </nav>
      <div className="settings-detail">
        <div className="settings-content">
          {visibleSections.length ? (
            activeSection === "font" ? (
              <section className="settings-section">
                <header className="settings-page-heading">
                  <h2>Terminal font</h2>
                  <p>Applied to every web terminal.</p>
                </header>
                <div className="settings-fields">
                  <label>
                    Font family
                    <input value={fontFamily} onChange={event => onFontFamilyChange(event.target.value)} autoComplete="off" spellCheck="false" />
                  </label>
                  <label>
                    Size
                    <input type="number" min="8" max="32" step="1" value={fontSize} onChange={event => onFontSizeChange(event.target.value)} />
                  </label>
                </div>
                <div className="font-preview" style={{ fontFamily, fontSize: `${fontSize}px` }}>Aa&nbsp;&nbsp;The quick brown fox&nbsp;&nbsp;0123456789</div>
              </section>
            ) : activeSection === "presets" ? (
              <section className="settings-section">
                <header className="settings-page-heading">
                  <h2>Launch commands</h2>
                  <p>Edited in a terminal session after the shell starts, so quitting an agent keeps the tab alive.</p>
                </header>
                <div className="preset-order-section">
                  <div className="settings-subheading">
                    <h3>Session order</h3>
                    <p>This order controls the preset buttons; opening a workspace never changes it.</p>
                  </div>
                  <div className="preset-order-list">
                    {presets.map((preset, index) => (
                      <div className="preset-order-row" key={preset.kind}>
                        <SessionPresetIcon kind={preset.kind} />
                        <span>{preset.label}</span>
                        <label className="preset-visibility-toggle">
                          <input
                            type="checkbox"
                            checked={!hiddenPresets.includes(preset.kind)}
                            onChange={event => onPresetVisibilityChange(preset.kind, event.target.checked)}
                          />
                          <span>Show</span>
                        </label>
                        <div className="preset-order-actions">
                          <button
                            type="button"
                            disabled={index === 0}
                            aria-label={`Move ${preset.label} up`}
                            onClick={() => onMovePreset(preset.kind, -1)}
                          >
                            ↑
                          </button>
                          <button
                            type="button"
                            disabled={index === presets.length - 1}
                            aria-label={`Move ${preset.label} down`}
                            onClick={() => onMovePreset(preset.kind, 1)}
                          >
                            ↓
                          </button>
                        </div>
                      </div>
                    ))}
                  </div>
                </div>
                <div className="preset-fields">
                  {presets.map(preset => (
                    <label key={preset.kind}>
                      {preset.label}
                      <input
                        value={presetCommands[preset.kind] || ""}
                        onChange={event => onPresetCommandChange(preset.kind, event.target.value)}
                        placeholder={preset.kind === "shell" ? "default shell (empty)" : `command for ${preset.kind}`}
                        autoComplete="off"
                        spellCheck="false"
                      />
                    </label>
                  ))}
                </div>
                <p className="settings-note">
                  Hidden presets stay configurable here but do not appear in the preset bar. Leave Shell empty to
                  open a plain terminal. Agents run inside the shell, so you can exit them with Ctrl+C / Ctrl+D and
                  keep the session.
                </p>
              </section>
            ) : activeSection === "workspaces" ? (
              <section className="settings-section">
                <header className="settings-page-heading">
                  <h2>Workspaces</h2>
                  <p>Configure project worktree import and empty-workspace entry behavior.</p>
                </header>
                <div className="settings-options">
                  <div className="settings-info-card">
                    <span>
                      <strong>Git worktree import is configured per project</strong>
                      <small>Open a project’s context menu to enable automatic import (it imports existing worktrees immediately, without a confirmation step), or choose Import existing worktrees… for a one-time selection. Imported workspaces are never removed when the automatic setting is disabled.</small>
                    </span>
                  </div>
                  <label className="settings-toggle">
                    <input
                      type="checkbox"
                      checked={autoOpenShell}
                      onChange={event => onAutoOpenShellChange(event.target.checked)}
                    />
                    <span>
                      <strong>Open a Shell when opening an empty workspace</strong>
                      <small>When enabled, double-clicking an empty workspace creates one Shell. A single click only selects it. Existing sessions are reused, and explicit New Session or preset actions are unchanged.</small>
                    </span>
                  </label>
                  <label className="settings-toggle">
                    <input
                      type="checkbox"
                      checked={autoStartAI}
                      onChange={event => onAutoStartAIChange(event.target.checked)}
                    />
                    <span>
                      <strong>Start the first AI when entering an empty workspace</strong>
                      <small>When enabled, selecting a project or workspace (including Search and Command Palette navigation) starts the first AI in Launch commands order. Navigation restore does not start a process. On double-click, this AI action takes precedence over the Shell option so only one session is created.</small>
                    </span>
                  </label>
                </div>
              </section>
            ) : (
              <section className="settings-section">
                <header className="settings-page-heading">
                  <h2>Terminal title</h2>
                  <p>Build a title from live Session metadata.</p>
                </header>
                <label>
                  Title template
                  <input value={titleTemplate} onChange={event => onTitleTemplateChange(event.target.value)} autoComplete="off" spellCheck="false" />
                </label>
                <div className="settings-preview">Preview: {titlePreview}</div>
                <div className="placeholder-list">
                  {placeholders.map(([key, description]) => (
                    <button type="button" className="placeholder" key={key} title={description} onClick={() => onAppendPlaceholder(`{${key}}`)}>{`{${key}}`}</button>
                  ))}
                </div>
              </section>
            )
          ) : (
            <div className="settings-empty">No settings match “{searchQuery}”.</div>
          )}
          <div className="settings-footer">
            <button type="button" className="settings-reset" onClick={onRestore}>Restore terminal defaults</button>
          </div>
        </div>
      </div>
    </section>
  );
}

function PresetIcon() {
  return (
    <svg viewBox="0 0 16 16" width="15" height="15" aria-hidden="true">
      <path d="M2 4.5h8v1H2v-1zm0 3h8v1H2v-1zm0 3h5v1H2v-1zm10.2-4.2l1.8 1.7-1.8 1.7-.7-.7 1.1-1-1.1-1 .7-.7z" fill="currentColor"/>
    </svg>
  );
}

export function SearchPanel({
  open,
  query,
  catalog,
  onQueryChange,
  onClose,
  onChooseWorkspace,
  onChooseProject,
}) {
  const inputRef = useRef(null);
  const itemRefs = useRef(new Map());
  const [activeIndex, setActiveIndex] = useState(0);

  useEffect(() => {
    if (open) {
      inputRef.current?.focus();
      setActiveIndex(0);
    }
  }, [open]);

  useEffect(() => {
    setActiveIndex(0);
  }, [query]);

  const needle = query.trim().toLowerCase();
  const matches = value => !needle || String(value || "").toLowerCase().includes(needle);

  const groups = [];
  let nextIndex = 0;
  for (const project of catalog.projects) {
    const workspaces = catalog.workspacesByProject.get(project.id) || [];
    const projectMatches = matches(project.name) || matches(project.path);
    const visibleWorkspaces = workspaces.filter(workspace =>
      projectMatches || matches(workspace.name) || matches(workspace.branch),
    );
    if (!projectMatches && !visibleWorkspaces.length) continue;
    const rows = [{ kind: "project", project, workspace: null, index: nextIndex++ }];
    for (const workspace of visibleWorkspaces) {
      rows.push({ kind: "workspace", project, workspace, index: nextIndex++ });
    }
    groups.push({ project, rows });
  }
  const flatRows = groups.flatMap(group => group.rows);
  const rowCount = flatRows.length;
  const activeRow = flatRows[activeIndex] || null;

  useEffect(() => {
    const node = itemRefs.current.get(activeIndex);
    node?.scrollIntoView({ block: "nearest" });
  }, [activeIndex, query]);

  const chooseRow = row => {
    if (!row) return;
    if (row.kind === "project") onChooseProject(row.project.id);
    else onChooseWorkspace(row.workspace.id);
  };

  const handleKeyDown = event => {
    if (event.key === "ArrowDown") {
      event.preventDefault();
      if (rowCount) setActiveIndex(index => Math.min(index + 1, rowCount - 1));
    } else if (event.key === "ArrowUp") {
      event.preventDefault();
      setActiveIndex(index => Math.max(index - 1, 0));
    } else if (event.key === "Home") {
      event.preventDefault();
      setActiveIndex(0);
    } else if (event.key === "End") {
      event.preventDefault();
      setActiveIndex(rowCount - 1);
    } else if (event.key === "Enter") {
      event.preventDefault();
      chooseRow(activeRow);
    } else if (event.key === "Escape") {
      event.preventDefault();
      onClose();
    }
  };

  return (
    <div
      className={`search-overlay${open ? " open" : ""}`}
      onMouseDown={event => {
        if (event.target === event.currentTarget) onClose();
      }}
    >
      <section className="search-panel" role="dialog" aria-modal="true" aria-label="Project search">
        <div className="search-input-wrap">
          <SearchIcon />
          <label className="visually-hidden" htmlFor="warren-search">Search projects and workspaces</label>
          <input
            ref={inputRef}
            id="warren-search"
            className="search-input"
            value={query}
            onChange={event => onQueryChange(event.target.value)}
            onKeyDown={handleKeyDown}
            placeholder="Type a command or search…"
            autoComplete="off"
            spellCheck="false"
          />
          <kbd className="search-kbd">esc</kbd>
        </div>
        <div className="search-results">
          {groups.map(group => (
            <div className="search-group" key={group.project.id}>
              <div className="search-group-heading">{group.project.name}</div>
              {group.rows.map(row => {
                const active = row.index === activeIndex;
                const shared = {
                  ref: node => {
                    if (node) itemRefs.current.set(row.index, node);
                    else itemRefs.current.delete(row.index);
                  },
                  onMouseEnter: () => setActiveIndex(row.index),
                };
                return row.kind === "project" ? (
                  <button
                    type="button"
                    key={row.project.id}
                    className={`search-item search-project-item${active ? " active" : ""}`}
                    {...shared}
                    onClick={() => onChooseProject(row.project.id)}
                  >
                    {folderIcon}
                    <span className="search-copy">
                      <span className="search-name">{row.project.name}</span>
                      <span className="search-path">{row.project.path || ""}</span>
                    </span>
                  </button>
                ) : (
                  <button
                    type="button"
                    key={row.workspace.id}
                    className={`search-item search-workspace-item${active ? " active" : ""}`}
                    {...shared}
                    onClick={() => onChooseWorkspace(row.workspace.id)}
                  >
                    {row.workspace.mergeState === "merged"
                      ? <MergedBadge tabs={catalog.tabsByWorkspace.get(row.workspace.id) || []} />
                      : <BranchIcon />}
                    <span className="search-name">{row.workspace.branch || row.workspace.name || "Workspace"}</span>
                    <span className="search-kind">Workspace</span>
                  </button>
                );
              })}
            </div>
          ))}
          {!rowCount && (
            <div className="search-empty">
              {needle
                ? <>No results for “{query.trim()}”. Try a different name or path.</>
                : "Search projects and workspaces by name or path."}
            </div>
          )}
        </div>
      </section>
    </div>
  );
}

export function Loading({ message }) {
  return (
    <span className="terminal-loading">
      <span className="braille-spinner" aria-hidden="true">
        <i /><i /><i /><i /><i /><i /><i /><i />
      </span>
      {message}
    </span>
  );
}

function highestActivity(sessions) {
  return sessions.reduce((highest, session) => {
    const activity = session.activity;
    return (activityPriority[activity] || 0) > (activityPriority[highest] || 0) ? activity : highest;
  }, null);
}

function PlusIcon() {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" aria-hidden="true">
      <path d="M12 5v14M5 12h14" />
    </svg>
  );
}

function BackIcon() {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" aria-hidden="true">
      <path d="M19 12H5m6-7-7 7 7 7" />
    </svg>
  );
}

function BranchIcon() {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" aria-hidden="true">
      <circle cx="6" cy="6" r="2.5" />
      <circle cx="6" cy="18" r="2.5" />
      <circle cx="18" cy="6" r="2.5" />
      <path d="M6 8.5v7M8.5 6h7" />
    </svg>
  );
}

function TitleIcon() {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" aria-hidden="true">
      <path d="M4 7V4h16v3M9 20h6M12 4v16" />
    </svg>
  );
}

function SettingsIcon() {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" aria-hidden="true">
      <circle cx="12" cy="12" r="3" />
      <path d="M19.4 15a1.7 1.7 0 0 0 .34 1.88l.06.06-2.83 2.83-.06-.06A1.7 1.7 0 0 0 15 19.4a1.7 1.7 0 0 0-1 .6 1.7 1.7 0 0 0-.4 1.1V21H9.6v-.1A1.7 1.7 0 0 0 8.5 19.4a1.7 1.7 0 0 0-1.88.34l-.06.06-2.83-2.83.06-.06A1.7 1.7 0 0 0 4.6 15a1.7 1.7 0 0 0-.6-1 1.7 1.7 0 0 0-1.1-.4H3V9.6h.1A1.7 1.7 0 0 0 4.6 8.5a1.7 1.7 0 0 0-.34-1.88l-.06-.06 2.83-2.83.06.06A1.7 1.7 0 0 0 9 4.6a1.7 1.7 0 0 0 1-.6 1.7 1.7 0 0 0 .4-1.1V3h4v.1A1.7 1.7 0 0 0 15.5 4.6a1.7 1.7 0 0 0 1.88-.34l.06-.06 2.83 2.83-.06.06A1.7 1.7 0 0 0 19.4 9c.16.38.38.72.68 1 .3.28.69.42 1.1.4h.1v4h-.1A1.7 1.7 0 0 0 19.4 15Z" />
    </svg>
  );
}

function SearchIcon() {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" aria-hidden="true">
      <circle cx="11" cy="11" r="6" />
      <path d="m16 16 4 4" />
    </svg>
  );
}

function ChevronUpIcon() {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" aria-hidden="true">
      <path d="m6 15 6-6 6 6" />
    </svg>
  );
}

function ChevronDownIcon() {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" aria-hidden="true">
      <path d="m6 9 6 6 6-6" />
    </svg>
  );
}

function CloseIcon() {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" aria-hidden="true">
      <path d="M6 6l12 12M18 6 6 18" />
    </svg>
  );
}
