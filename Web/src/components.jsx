import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { webAssetURL } from "./runtime.js";
import { terminalSearchSummary } from "./terminal.js";
import { terminalTabTitle } from "./title.js";
import { shouldDismissOnBackdrop } from "./presentation.js";

const activityLabels = {
  working: "Working",
  blocked: "Needs attention",
  stalled: "Needs attention",
  failed: "Failed",
  ready: "Ready",
  exited: "Exited",
  connecting: "Connecting",
};

const activityPriority = {
  failed: 6,
  blocked: 5,
  stalled: 4,
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

const agentChatIcon = (
  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" aria-hidden="true">
    <path d="M4 5.5A2.5 2.5 0 0 1 6.5 3h11A2.5 2.5 0 0 1 20 5.5v7a2.5 2.5 0 0 1-2.5 2.5H11l-4.5 4v-4.2A2.5 2.5 0 0 1 4 12.5z" />
    <path d="M8 8h8M8 11h5" />
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
  <svg className="git-icon" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.1" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
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

// App-owned overlays move focus into their first meaningful control. Keep the
// invoking control as the focus owner when the overlay goes away so Escape,
// Cancel, and a completed action never strand keyboard users at document.body.
function useFocusRestore(active) {
  const previousFocusRef = useRef(null);

  useEffect(() => {
    if (!active) return undefined;
    const current = document.activeElement;
    previousFocusRef.current = typeof HTMLElement !== "undefined"
      && current instanceof HTMLElement
      && current !== document.body
      ? current
      : null;
    return () => {
      const target = previousFocusRef.current;
      previousFocusRef.current = null;
      if (!target?.isConnected) return;
      queueMicrotask(() => {
        if (!target.isConnected) return;
        // A menu action can mount the next app-owned surface in the same
        // render. Let that surface own focus instead of racing it from the
        // closing overlay's cleanup task.
        const nextSurface = document.querySelector('[role="dialog"][aria-modal="true"], [role="menu"]');
        if (nextSurface && !nextSurface.contains(target)) return;
        const active = document.activeElement;
        if (active && active !== document.body && active !== target) return;
        target.focus({ preventScroll: true });
      });
    };
  }, [active]);
}

// Keep keyboard focus inside an app-owned dialog, sheet, or menu while it is
// open. Native browser focus can otherwise move behind the scrim after the
// initial focus lands, which is especially disorienting on compact screens.
export function useFocusTrap(active, containerRef) {
  useEffect(() => {
    if (!active) return undefined;
    const container = containerRef.current;
    if (!container) return undefined;
    const selector = [
      'a[href]',
      'area[href]',
      'button:not([disabled])',
      'input:not([disabled])',
      'select:not([disabled])',
      'textarea:not([disabled])',
      '[tabindex]:not([tabindex="-1"])',
    ].join(",");
    const focusable = () => Array.from(container.querySelectorAll(selector))
      .filter(element => !element.hasAttribute("aria-hidden"));
    const handleKeyDown = event => {
      if (event.key !== "Tab") return;
      const items = focusable();
      if (!items.length) return;
      const first = items[0];
      const last = items[items.length - 1];
      const current = document.activeElement;
      if (!container.contains(current)) {
        event.preventDefault();
        (event.shiftKey ? last : first).focus();
      } else if (event.shiftKey && current === first) {
        event.preventDefault();
        last.focus();
      } else if (!event.shiftKey && current === last) {
        event.preventDefault();
        first.focus();
      }
    };
    document.addEventListener("keydown", handleKeyDown, true);
    return () => document.removeEventListener("keydown", handleKeyDown, true);
  }, [active, containerRef]);
}

// Fixed app-owned surfaces must own scrolling while they are visible. A shared
// counter keeps nested overlays from restoring the body's previous style while
// another surface still owns the lock.
let bodyScrollLockCount = 0;
let bodyScrollLockPreviousOverflow = null;

function useBodyScrollLock(active) {
  useEffect(() => {
    if (!active) return undefined;
    if (bodyScrollLockCount === 0) {
      bodyScrollLockPreviousOverflow = document.body.style.overflow;
    }
    bodyScrollLockCount += 1;
    document.body.style.overflow = "hidden";
    return () => {
      bodyScrollLockCount = Math.max(0, bodyScrollLockCount - 1);
      if (bodyScrollLockCount === 0) {
        document.body.style.overflow = bodyScrollLockPreviousOverflow || "";
        bodyScrollLockPreviousOverflow = null;
      }
    };
  }, [active]);
}

function statusActivity(status) {
  return status?.activity || "";
}

function statusLabel(status) {
  const activity = statusActivity(status);
  if (activity === "failed") return activityLabels.failed;
  if (status?.attention || activity === "blocked" || activity === "stalled") return "Needs attention";
  return activityLabels[activity];
}

export function ActivityDot({ status }) {
  const activity = statusActivity(status);
  const label = statusLabel(status);
  if (!label) return null;
  const attention = activity !== "failed" && status?.attention ? " attention" : "";
  // Working is the only state that moves. Attention, blocked, and failed
  // states stay still so an actionable explanation is easier to read.
  const pulse = activity === "working" ? " pulse" : "";
  return <span className={`activity ${activity}${attention}${pulse}`} title={label} aria-label={label} />;
}

function mergedBadgeTitle(tabs) {
  const count = tabs.length;
  const parts = ["Merged to default branch"];
  if (count) parts.push(`${count} active`);
  const activity = statusLabel(highestStatus(tabs));
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
  expandedTasks,
  expandedProjects,
  tasksCollapsed = false,
  tabsForWorkspace,
  connection,
  onToggleTasksCollapsed,
  onToggleTask,
  onFocusTask,
  onNewTask,
  onToggleProject,
  onChooseWorkspace,
  onOpenWorkspace,
  onNewSessionInWorkspace,
  onNewSession,
  onOpenSettings,
  onTaskContextMenu,
  onProjectContextMenu,
  onWorkspaceContextMenu,
  onMoveProject,
  onMoveWorkspace,
  onBeginProjectDrag,
  onEndProjectDrag,
  creatingWorkspaceIDs = new Set(),
  creatingSession = false,
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
    <aside className="sidebar" aria-label="Tasks, projects, and workspaces">
      <div className="brand">
        <img className="brand-mark" src={webAssetURL("icon.svg")} alt="Warren" />
        {isBuild && <span className="build-badge">Build</span>}
        <span className={`connection${connection.online ? " online" : ""}`}>
          <span className="connection-dot" />
          <span>{connection.message}</span>
        </span>
      </div>
      <div className="sidebar-scroll">
        <div className="section-label-row">
          <button
            type="button"
            className="section-label-toggle"
            aria-expanded={!tasksCollapsed}
            aria-label={tasksCollapsed ? "Expand Tasks" : "Collapse Tasks"}
            onClick={onToggleTasksCollapsed}
          >
            <span className="section-label">Tasks</span>
            <span className={`chevron${!tasksCollapsed ? " open" : ""}`}>{ChevronRightIcon}</span>
          </button>
          <button type="button" className="section-add" aria-label="New task" title="New task" onClick={onNewTask}>
            <PlusIcon />
          </button>
        </div>
        {!tasksCollapsed && (catalog.tasks.length ? catalog.tasks.map(task => {
          const workspaces = catalog.workspacesByTask.get(task.id) || [];
          const open = expandedTasks.has(task.id);
          return (
            <section className={`project task${open ? " open" : ""}`} key={task.id} id={`task-${task.id}`}>
              <div className="project-toggle" onContextMenu={event => onTaskContextMenu(event, task)}>
                <button
                  type="button"
                  className="project-toggle-main"
                  aria-expanded={open}
                  onClick={() => onToggleTask(task.id)}
                >
                  <span className="branch">{task.name}</span>
                  {task.pinned && <span className="pin-icon" title="Pinned">{pinIcon}</span>}
                  <span className="project-count">({workspaces.length})</span>
                </button>
                <button
                  type="button"
                  className="project-chevron"
                  aria-label={open ? `Collapse ${task.name}` : `Expand ${task.name}`}
                  onClick={() => onToggleTask(task.id)}
                >
                  <span className="chevron">{ChevronRightIcon}</span>
                </button>
              </div>
              <div className="workspace-list">
                {workspaces.length ? workspaces.map(workspace => {
                  const project = catalog.projectsByID.get(workspace.project);
                  return (
                    <button
                      type="button"
                      className={`workspace-row${workspace.id === activeWorkspace ? " active" : ""}${creatingWorkspaceIDs.has(workspace.id) ? " pending" : ""}`}
                      disabled={creatingWorkspaceIDs.has(workspace.id)}
                      aria-busy={creatingWorkspaceIDs.has(workspace.id) || undefined}
                      key={workspace.id}
                      onClick={() => onChooseWorkspace(workspace.id)}
                      onDoubleClick={() => onOpenWorkspace(workspace.id)}
                      onContextMenu={event => onWorkspaceContextMenu(event, workspace)}
                    >
                      <ActivityDot status={highestStatus(tabsForWorkspace(workspace.id))} />
                      <span className="branch">{project?.name || "Project"} · {workspace.branch || workspace.name || "Workspace"}</span>
                      {creatingWorkspaceIDs.has(workspace.id) && <span className="workspace-pending" role="status">Creating…</span>}
                    </button>
                  );
                }) : <div className="workspace-row task-empty">No linked workspaces</div>}
              </div>
            </section>
          );
        }) : <div className="workspace-row task-empty">No tasks</div>)}
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
                    disabled={creatingSession || creatingWorkspaceIDs.has(workspaces[0].id)}
                    aria-busy={creatingWorkspaceIDs.has(workspaces[0].id) || undefined}
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
                {workspaces.map(workspace => {
                  const task = workspace.task
                    ? catalog.tasks.find(value => value.id === workspace.task)
                    : null;
                  const creating = creatingWorkspaceIDs.has(workspace.id);
                  return (
                    <div
                      className={`workspace-row${workspace.id === activeWorkspace ? " active" : ""}${creating ? " pending" : ""}${dragOverID === workspace.id ? " drag-over" : ""}`}
                      key={workspace.id}
                      aria-busy={creating || undefined}
                      onContextMenu={event => onWorkspaceContextMenu(event, workspace)}
                      draggable
                      onDragStart={event => beginDrag("workspace", workspace.id, workspace.project, event)}
                      onDragEnd={endDrag}
                      onDragOver={event => workspaceDragOver(workspace, event)}
                      onDrop={event => dropWorkspace(workspace, event)}
                    >
                      <button
                        type="button"
                        className="workspace-row-main"
                        disabled={creating}
                        aria-busy={creating || undefined}
                        onClick={() => onChooseWorkspace(workspace.id)}
                        onDoubleClick={() => onOpenWorkspace(workspace.id)}
                      >
                        {workspace.mergeState === "merged"
                          ? <MergedBadge tabs={tabsForWorkspace(workspace.id)} />
                          : <ActivityDot status={highestStatus(tabsForWorkspace(workspace.id))} />}
                        {workspace.pinned && <span className="pin-icon" title="Pinned">{pinIcon}</span>}
                        <span className="branch">{workspace.branch || workspace.name || "Workspace"}</span>
                      </button>
                      {creating && <span className="workspace-pending" role="status">Creating…</span>}
                      {task && (
                        <button
                          type="button"
                          className="workspace-task-link"
                          aria-label={`Open task ${task.name}`}
                          title={`Task: ${task.name}`}
                          disabled={creating}
                          onClick={event => {
                            event.stopPropagation();
                            onFocusTask(task.id);
                          }}
                        >
                          T
                        </button>
                      )}
                    </div>
                  );
                })}
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
          disabled={!activeWorkspace || creatingSession}
          aria-busy={creatingSession || undefined}
          onClick={onNewSession}
        >
          <PlusIcon />
          <span>{creatingSession ? "Starting…" : "New session"}</span>
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
  pendingSessionID = null,
  creatingSession = false,
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
    if (pendingSessionID || creatingSession) return;
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
            const pending = session.id === pendingSessionID;
            return (
              <button
                type="button"
                role="tab"
                aria-selected={active}
                className={`tab${active ? " active" : ""}${pending ? " pending" : ""}`}
                disabled={Boolean(pendingSessionID) || creatingSession}
                aria-busy={pending || undefined}
                key={session.id}
                onClick={() => onAttachSession(session.id)}
                onContextMenu={event => onTabContextMenu(event, session)}
                ref={node => {
                  if (node) tabRefs.current.set(session.id, node);
                  else tabRefs.current.delete(session.id);
                }}
              >
                <ActivityDot status={session.agentStatus} />
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
      <button type="button" className="new-session" aria-label="New shell" disabled={creatingSession} aria-busy={creatingSession || undefined} onClick={onNewSession}>
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
  projectName,
  tabs,
  activeSession,
  connection,
  agentSession,
  agentViewActive,
  onAttachSession,
  onToggleAgentView,
  onOpenMenu,
  onOpenSearch,
  onToggleGit,
  gitActive,
  onNewSession,
  onOpenSessionMenu,
  onSessionContextMenu,
  pendingSessionID = null,
  creatingSession = false,
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
    if (pendingSessionID || creatingSession) return;
    onAttachSession(session.id);
    document.querySelector(`.mobile-tab[data-session="${session.id}"]`)?.focus();
  };

  return (
    <header className="mobile-shell">
      <div className="mobile-command">
        <button type="button" className="menu-button" aria-label="Open navigation" onClick={onOpenMenu}>{MenuIcon}</button>
        <div className="mobile-workspace" title={connection.message}>
          <div className="mobile-workspace-context" aria-label="Project, workspace and branch">
            {projectName && (
              <>
                <span className="mobile-breadcrumb-item project">{projectName}</span>
                <span className="mobile-breadcrumb-separator" aria-hidden="true">›</span>
              </>
            )}
            <span className="mobile-breadcrumb-item workspace">{workspace?.name || "Workspace"}</span>
            {workspace?.branch && workspace.branch !== workspace.name && (
              <>
                <span className="mobile-breadcrumb-separator" aria-hidden="true">›</span>
                <span className="mobile-breadcrumb-item branch">{workspace.branch}</span>
              </>
            )}
          </div>
          <span className={`mobile-connection${connection.online ? " online" : ""}`} aria-label={connection.message}>
            <span className="connection-dot" />
          </span>
        </div>
        {agentSession && (
          <div className="agent-view-toggle" role="group" aria-label="View">
            <button
              type="button"
              className={agentViewActive ? undefined : "active"}
              aria-pressed={!agentViewActive}
              aria-label="Terminal"
              title="Terminal"
              onClick={() => onToggleAgentView("terminal")}
            >
              {terminalIcon}
            </button>
            <button
              type="button"
              className={agentViewActive ? "active" : undefined}
              aria-pressed={agentViewActive}
              aria-label="Agent chat"
              title="Agent chat"
              onClick={() => onToggleAgentView("agent")}
            >
              {agentChatIcon}
            </button>
          </div>
        )}
        <div className="chrome-spacer" />
        {activeSession && (
          <button type="button" className="chrome-button" aria-label="Session actions" onClick={onOpenSessionMenu}>
            {moreIcon}
          </button>
        )}
        {onToggleGit && (
          <button
            type="button"
            className={`chrome-button${gitActive ? " active" : ""}`}
            aria-label="Toggle Git panel"
            aria-pressed={gitActive}
            onClick={onToggleGit}
          >
            {GitIcon}
          </button>
        )}
        <button type="button" className="chrome-button" aria-label="Search projects" onClick={onOpenSearch}>
          <SearchIcon />
        </button>
        <button type="button" className="new-session" aria-label="New session" disabled={creatingSession} aria-busy={creatingSession || undefined} onClick={onNewSession}>
          <PlusIcon />
        </button>
      </div>
      <nav className="mobile-tabs" role="tablist" aria-label="Sessions" onKeyDown={handleTabListKeyDown}>
        {tabs.map(session => {
          const active = session.id === activeSession;
          const pending = session.id === pendingSessionID;
          return (
            <button
              type="button"
              role="tab"
              data-session={session.id}
              aria-selected={active}
              className={`mobile-tab${active ? " active" : ""}${pending ? " pending" : ""}`}
              disabled={Boolean(pendingSessionID) || creatingSession}
              aria-busy={pending || undefined}
              key={session.id}
              onClick={() => onAttachSession(session.id)}
              onContextMenu={event => onSessionContextMenu?.(event, session)}
            >
              <ActivityDot status={session.agentStatus} />
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
  const onCloseRef = useRef(onClose);
  onCloseRef.current = onClose;
  const [mobile, setMobile] = useState(() => window.matchMedia("(max-width: 767px)").matches);
  useFocusRestore(Boolean(menu));
  useFocusTrap(Boolean(menu), menuRef);
  useBodyScrollLock(Boolean(menu) && mobile);

  useEffect(() => {
    const media = window.matchMedia("(max-width: 767px)");
    const onChange = event => setMobile(event.matches);
    media.addEventListener("change", onChange);
    return () => media.removeEventListener("change", onChange);
  }, []);

  useEffect(() => {
    if (!menu) return undefined;
    const items = () => Array.from(menuRef.current?.querySelectorAll(
      mobile ? 'button:not(:disabled)' : '[role="menuitem"]:not(:disabled)',
    ) || [])
      .filter(item => item.getAttribute("aria-disabled") !== "true");
    const first = items()[0] || menuRef.current?.querySelector("button:not(:disabled)");
    first?.focus();
    const handlePointerDown = event => {
      if (!menuRef.current?.contains(event.target)) onCloseRef.current();
    };
    const handleKeyDown = event => {
      if (event.key === "Escape") {
        event.preventDefault();
        event.stopPropagation();
        onCloseRef.current();
      }
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
    const handleBlur = () => onCloseRef.current();
    window.addEventListener("pointerdown", handlePointerDown);
    window.addEventListener("keydown", handleKeyDown);
    window.addEventListener("blur", handleBlur);
    return () => {
      window.removeEventListener("pointerdown", handlePointerDown);
      window.removeEventListener("keydown", handleKeyDown);
      window.removeEventListener("blur", handleBlur);
    };
  }, [Boolean(menu), mobile]);

  if (!menu) return null;
  return (
    <>
      {mobile && (
        <div
          className="context-menu-scrim"
          aria-hidden="true"
          onPointerDown={event => {
            event.stopPropagation();
            onCloseRef.current();
          }}
        />
      )}
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
            disabled={item.disabled}
            aria-disabled={item.disabled ? "true" : undefined}
            onClick={() => {
              if (item.disabled) return;
              onCloseRef.current();
              item.action();
            }}
          >
            {item.label}
          </button>
        ))}
      </div>
    </>
  );
}

export function PresetBar({ presets, onCreateSession, creatingKind = null }) {
  return (
    <nav className="presetbar" aria-label="Session presets">
      {presets.map(preset => (
        <button
          type="button"
          className={`preset${creatingKind === preset.kind ? " pending" : ""}`}
          key={preset.kind}
          disabled={Boolean(creatingKind)}
          aria-busy={creatingKind === preset.kind || undefined}
          onClick={() => onCreateSession(preset.kind)}
        >
          <SessionPresetIcon kind={preset.kind} />
          <span>{creatingKind === preset.kind ? "Starting…" : preset.label}</span>
        </button>
      ))}
    </nav>
  );
}

export function EmptyTerminal({
  activeWorkspace,
  activeSession,
  terminalReadySession,
  tabCount,
  projectCount,
  override,
  onNewSession,
}) {
  let content;
  let hidden = false;

  if (override) {
    content = override.loading ? <Loading message={override.message} /> : <span>{override.message}</span>;
  } else if (activeSession && terminalReadySession === activeSession) {
    hidden = true;
    content = null;
  } else if (activeSession) {
    // Keep the terminal surface quiet while a new subscription is warming.
    // A static status avoids a spinner flash over the cached renderer.
    content = <span className="terminal-switching" role="status" aria-live="polite">Switching session…</span>;
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

  const switching = Boolean(activeSession && terminalReadySession !== activeSession && !override);
  return <div className={`terminal-empty${switching ? " switching" : ""}`} hidden={hidden}>{content}</div>;
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
      event.stopPropagation();
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

export function SessionSheet({ open, presets, onChoose, onClose, pendingKind = null }) {
  const firstItemRef = useRef(null);
  const cancelRef = useRef(null);
  const sheetRef = useRef(null);
  const dragStartYRef = useRef(null);
  const onCloseRef = useRef(onClose);
  onCloseRef.current = onClose;
  const pendingKindRef = useRef(pendingKind);
  pendingKindRef.current = pendingKind;
  useFocusRestore(open);
  useFocusTrap(open, sheetRef);
  useBodyScrollLock(open);

  useEffect(() => {
    if (!open) return undefined;
    (firstItemRef.current || cancelRef.current)?.focus();
    const handleKeyDown = event => {
      if (event.key === "Escape") {
        event.preventDefault();
        event.stopPropagation();
        if (!pendingKindRef.current) onCloseRef.current();
      }
    };
    document.addEventListener("keydown", handleKeyDown);
    return () => {
      document.removeEventListener("keydown", handleKeyDown);
    };
  }, [open]);

  if (!open) return null;
  return (
    <div
      className="session-sheet-overlay"
      onClick={event => {
        if (event.target === event.currentTarget && !pendingKindRef.current) onCloseRef.current();
      }}
    >
      <div
        ref={sheetRef}
        className="session-sheet"
        role="dialog"
        aria-modal="true"
        aria-label="New session"
        onClick={event => event.stopPropagation()}
      >
        <div
          className="session-sheet-handle"
          role="button"
          tabIndex={0}
          aria-label="Close new session sheet"
          onPointerDown={event => {
            if (event.pointerType === "touch") {
              dragStartYRef.current = event.clientY;
              event.currentTarget.setPointerCapture?.(event.pointerId);
            }
          }}
          onPointerUp={event => {
            const start = dragStartYRef.current;
            dragStartYRef.current = null;
            event.currentTarget.releasePointerCapture?.(event.pointerId);
            if (start !== null && event.clientY - start > 56 && !pendingKindRef.current) onCloseRef.current();
          }}
          onPointerCancel={event => {
            dragStartYRef.current = null;
            event.currentTarget.releasePointerCapture?.(event.pointerId);
          }}
          onKeyDown={event => {
            if (event.key === "Enter" || event.key === " ") {
              event.preventDefault();
              if (!pendingKindRef.current) onCloseRef.current();
            }
          }}
        />
        <div className="session-sheet-title">New session</div>
        {presets.map((preset, index) => (
          <button
            type="button"
            className="session-sheet-item"
            key={preset.kind}
            ref={index === 0 ? firstItemRef : undefined}
            disabled={Boolean(pendingKind)}
            aria-busy={pendingKind === preset.kind || undefined}
            onClick={() => onChoose(preset.kind)}
          >
            <SessionPresetIcon kind={preset.kind} />
            <span>{pendingKind === preset.kind ? "Starting…" : preset.label}</span>
          </button>
        ))}
        <button
          ref={cancelRef}
          type="button"
          className="session-sheet-cancel"
          disabled={Boolean(pendingKind)}
          onClick={() => { if (!pendingKind) onCloseRef.current(); }}
        >
          Cancel
        </button>
      </div>
    </div>
  );
}

export function WorktreeImportDialog({ dialog, onClose, onToggle, onImport }) {
  const firstItemRef = useRef(null);
  const closeButtonRef = useRef(null);
  const dialogRef = useRef(null);
  const dialogStateRef = useRef(dialog);
  dialogStateRef.current = dialog;
  const onCloseRef = useRef(onClose);
  onCloseRef.current = onClose;
  useFocusRestore(Boolean(dialog));
  useFocusTrap(Boolean(dialog), dialogRef);

  useEffect(() => {
    if (!dialog) return undefined;
    (firstItemRef.current || closeButtonRef.current)?.focus();
    const handleKeyDown = event => {
      if (event.key === "Escape") {
        event.preventDefault();
        event.stopPropagation();
        const current = dialogStateRef.current;
        const selectedCount = current?.selectedPaths?.length || 0;
        if (current && !current.loading && selectedCount === 0) onCloseRef.current();
      }
    };
    document.addEventListener("keydown", handleKeyDown);
    return () => document.removeEventListener("keydown", handleKeyDown);
  }, [Boolean(dialog)]);

  useBodyScrollLock(Boolean(dialog));

  if (!dialog) return null;
  const candidates = Array.isArray(dialog.candidates) ? dialog.candidates : [];
  const selected = new Set(dialog.selectedPaths || []);
  const availableCount = candidates.filter(candidate => !candidate.imported).length;
  const firstAvailableIndex = candidates.findIndex(candidate => !candidate.imported);

  return (
    <div
      className="worktree-dialog-overlay"
      onClick={() => {
        if (shouldDismissOnBackdrop("sheet", dialog.loading || selected.size > 0)) onClose();
      }}
    >
      <div
        ref={dialogRef}
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
          <button ref={closeButtonRef} type="button" className="worktree-dialog-close" aria-label="Close" onClick={onClose}>×</button>
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
                    ref={index === firstAvailableIndex ? firstItemRef : undefined}
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
  pending = false,
  error = "",
}) {
  const inputRef = useRef(null);
  const dialogRef = useRef(null);
  const [text, setText] = useState(initialValue || "");
  const pendingRef = useRef(pending);
  pendingRef.current = pending;
  const onCancelRef = useRef(onCancel);
  onCancelRef.current = onCancel;
  useFocusRestore(true);
  useFocusTrap(true, dialogRef);
  useBodyScrollLock(true);

  useEffect(() => {
    inputRef.current?.focus();
    const handleKeyDown = event => {
      if (event.key === "Escape") {
        event.preventDefault();
        event.stopPropagation();
        if (!pendingRef.current) onCancelRef.current();
      }
    };
    document.addEventListener("keydown", handleKeyDown);
    return () => document.removeEventListener("keydown", handleKeyDown);
  }, []);

  const submit = () => {
    const trimmed = text.trim();
    if (trimmed) onConfirm(trimmed);
  };

  return (
    <div className="warren-dialog-overlay">
      <div
        ref={dialogRef}
        className="warren-dialog"
        role="dialog"
        aria-modal="true"
        aria-labelledby="warren-dialog-title"
      >
        <h2 id="warren-dialog-title" className="warren-dialog-title">{title}</h2>
        {message && <p className="warren-dialog-message">{message}</p>}
        {error && <p className="warren-dialog-error" role="alert">{error}</p>}
        <label className="warren-dialog-field">
          <span>{fieldLabel}</span>
          <input
            ref={inputRef}
            value={text}
            onChange={event => setText(event.target.value)}
            onKeyDown={event => {
              if (event.key === "Enter") {
                event.preventDefault();
                if (!pending) submit();
              }
            }}
            autoComplete="off"
            spellCheck="false"
          />
        </label>
        <div className="warren-dialog-actions">
          <button type="button" className="warren-dialog-button secondary" disabled={pending} onClick={onCancel}>
            Cancel
          </button>
          <button
            type="button"
            className={`warren-dialog-button ${destructive ? "danger" : "primary"}`}
            disabled={!text.trim() || pending}
            onClick={submit}
          >
            {pending ? "Saving…" : confirmLabel}
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
  pending = false,
  error = "",
}) {
  const cancelRef = useRef(null);
  const dialogRef = useRef(null);
  const onCancelRef = useRef(onCancel);
  onCancelRef.current = onCancel;
  const pendingRef = useRef(pending);
  pendingRef.current = pending;
  useFocusRestore(true);
  useFocusTrap(true, dialogRef);
  useBodyScrollLock(true);

  useEffect(() => {
    cancelRef.current?.focus();
    const handleKeyDown = event => {
      if (event.key === "Escape") {
        event.preventDefault();
        event.stopPropagation();
        if (!pendingRef.current) onCancelRef.current();
      }
    };
    document.addEventListener("keydown", handleKeyDown);
    return () => document.removeEventListener("keydown", handleKeyDown);
  }, []);

  return (
    <div className="warren-dialog-overlay">
      <div
        ref={dialogRef}
        className="warren-dialog"
        role="dialog"
        aria-modal="true"
        aria-labelledby="warren-dialog-title"
      >
        <h2 id="warren-dialog-title" className="warren-dialog-title">{title}</h2>
        {message && <p className="warren-dialog-message">{message}</p>}
        {error && <p className="warren-dialog-error" role="alert">{error}</p>}
        <div className="warren-dialog-actions">
          <button
            ref={cancelRef}
            type="button"
            className="warren-dialog-button secondary"
            disabled={pending}
            onClick={onCancel}
          >
            Cancel
          </button>
          <button type="button" className="warren-dialog-button danger" disabled={pending} onClick={onConfirm}>
            {pending ? "Working…" : confirmLabel}
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
  openaiBaseURL = "",
  openaiModel = "",
  openaiTitleEnabled = false,
  agentCompletionSoundEnabled,
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
  onOpenAISettingChange,
  onAgentCompletionSoundChange,
  onPreviewAgentCompletionSound,
  onMovePreset,
  onAppendPlaceholder,
  onRestore,
}) {
  const [activeSection, setActiveSection] = useState("font");
  const [searchQuery, setSearchQuery] = useState("");
  useBodyScrollLock(open);

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
      keywords: ["preset", "command", "launch", "shell", "claude", "codex", "opencode", "pi", "qoder", "antigravity", "trae", "agent", "visible", "hidden"],
    },
    {
      id: "workspaces",
      label: "Workspaces",
      description: "Control project import and workspace entry defaults.",
      keywords: ["workspace", "project", "git", "worktree", "import", "shell", "open"],
    },
    {
      id: "notifications",
      label: "Notifications",
      description: "Choose how Warren alerts you when an Agent completes.",
      keywords: ["notification", "sound", "audio", "chime", "agent", "complete", "background"],
    },
    {
      id: "openai",
      label: "AI titles",
      description: "Generate session titles with an OpenAI-compatible endpoint.",
      keywords: ["openai", "ai", "title", "model", "base", "key", "summary"],
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
  const terminalSections = visibleSections.filter(section => section.id !== "notifications");
  const notificationSections = visibleSections.filter(section => section.id === "notifications");

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
          {terminalSections.length > 0 && <div className="settings-nav-label">Terminal</div>}
          {terminalSections.map(section => (
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
          {notificationSections.length > 0 && (
            <>
              <div className="settings-nav-label">Notifications</div>
              {notificationSections.map(section => (
                <button
                  type="button"
                  className={`settings-nav-item${activeSection === section.id ? " active" : ""}`}
                  aria-current={activeSection === section.id ? "true" : undefined}
                  key={section.id}
                  onClick={() => setActiveSection(section.id)}
                >
                  <BellIcon />
                  <span>{section.label}</span>
                </button>
              ))}
            </>
          )}
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
            ) : activeSection === "notifications" ? (
              <section className="settings-section">
                <header className="settings-page-heading">
                  <h2>Agent completion sound</h2>
                  <p>Hear a short chime when a background Agent finishes successfully.</p>
                </header>
                <div className="settings-options">
                  <label className="settings-toggle">
                    <input
                      type="checkbox"
                      checked={agentCompletionSoundEnabled}
                      onChange={event => onAgentCompletionSoundChange(event.target.checked)}
                    />
                    <span>
                      <strong>Play a sound when an Agent completes</strong>
                      <small>Warren stays silent for failed and aborted turns, and for the Agent you are actively viewing.</small>
                    </span>
                  </label>
                  <button
                    type="button"
                    className="settings-test-sound"
                    disabled={!agentCompletionSoundEnabled}
                    onClick={onPreviewAgentCompletionSound}
                  >
                    Play test sound
                  </button>
                  <p className="settings-note">Your browser must allow audio after an interaction. The chime uses the system output volume.</p>
                </div>
              </section>
            ) : activeSection === "openai" ? (
              <section className="settings-section">
                <header className="settings-page-heading">
                  <h2>AI session titles</h2>
                  <p>Use an OpenAI-compatible API to suggest a concise title from the opening exchange.</p>
                </header>
                <div className="settings-fields">
                  <label>API base URL<input value={openaiBaseURL} onChange={event => onOpenAISettingChange("openaiBaseURL", event.target.value)} placeholder="https://api.openai.com/v1" autoComplete="off" /></label>
                  <label>Model<input value={openaiModel} onChange={event => onOpenAISettingChange("openaiModel", event.target.value)} placeholder="gpt-4o-mini" autoComplete="off" /></label>
                  <label>API key<input type="password" onChange={event => onOpenAISettingChange("openaiKey", event.target.value)} placeholder="Leave blank to keep the saved key" autoComplete="off" /></label>
                </div>
                <label className="settings-toggle">
                  <input type="checkbox" checked={openaiTitleEnabled} onChange={event => onOpenAISettingChange("openaiTitleEnabled", event.target.checked)} />
                  <span><strong>Generate titles automatically</strong><small>Disabled by default. The key is stored only by the Warren host and is never sent back to clients.</small></span>
                </label>
              </section>
            ) : (
              <section className="settings-section">
                <header className="settings-page-heading">
                  <h2>Pane auxiliary title</h2>
                  <p>Tab owns the primary title. This template drives the auxiliary bar below the preset row (session name · directory · command by default). Custom session names fill the {"{session}"} placeholder; each value is shortened to fit the pane.</p>
                </header>
                <label>
                  Auxiliary template
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

function BellIcon() {
  return (
    <svg viewBox="0 0 16 16" width="15" height="15" aria-hidden="true">
      <path d="M8 1.8a3.2 3.2 0 0 0-3.2 3.2v2.1c0 .9-.25 1.77-.72 2.53L3.2 11h9.6l-.88-1.37a4.7 4.7 0 0 1-.72-2.53V5A3.2 3.2 0 0 0 8 1.8Zm-1.35 10.5a1.4 1.4 0 0 0 2.7 0h-2.7Z" fill="currentColor" />
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
  const panelRef = useRef(null);
  const itemRefs = useRef(new Map());
  const [activeIndex, setActiveIndex] = useState(0);
  const [debouncedQuery, setDebouncedQuery] = useState("");
  useFocusRestore(open);
  useFocusTrap(open, panelRef);
  useBodyScrollLock(open);

  useEffect(() => {
    if (open) {
      inputRef.current?.focus();
      setActiveIndex(0);
    }
  }, [open]);

  useEffect(() => {
    if (!query) {
      setDebouncedQuery("");
      return undefined;
    }
    const timer = setTimeout(() => setDebouncedQuery(query), 80);
    return () => clearTimeout(timer);
  }, [query]);

  useEffect(() => {
    setActiveIndex(0);
  }, [debouncedQuery]);

  const needle = debouncedQuery.trim().toLowerCase();
  const groups = useMemo(() => {
    const matches = value => !needle || String(value || "").toLowerCase().includes(needle);
    const result = [];
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
      result.push({ project, rows });
    }
    return result;
  }, [catalog, needle]);

  const flatRows = useMemo(() => groups.flatMap(group => group.rows), [groups]);
  const rowCount = flatRows.length;
  const activeRow = flatRows[activeIndex] || null;

  useEffect(() => {
    const node = itemRefs.current.get(activeIndex);
    node?.scrollIntoView({ block: "nearest" });
  }, [activeIndex, debouncedQuery]);

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
      event.stopPropagation();
      onClose();
    }
  };

  return (
    <div
      className={`search-overlay${open ? " open" : ""}`}
      onPointerDown={event => {
        if (event.target === event.currentTarget) onClose();
      }}
    >
      <section ref={panelRef} className="search-panel" role="dialog" aria-modal="true" aria-label="Project search">
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

/** A short, app-owned acknowledgement for actions that otherwise complete
 * outside the current surface (session switches, Git actions, and uploads). */
export function TransientFeedback({ feedback }) {
  if (!feedback?.message) return null;
  const kind = feedback.kind || "success";
  return (
    <div
      key={feedback.id}
      className={`transient-feedback ${kind}`}
      role={kind === "error" ? "alert" : "status"}
      aria-live={kind === "error" ? "assertive" : "polite"}
    >
      <span className="transient-feedback-mark" aria-hidden="true">
        {kind === "error" ? "!" : kind === "pending" ? "…" : "✓"}
      </span>
      <span>{feedback.message}</span>
    </div>
  );
}

function highestStatus(sessions) {
  return sessions.reduce((highest, session) => {
    const priority = statusPriority(session.agentStatus);
    const highestPriority = statusPriority(highest);
    return priority > highestPriority
      ? session.agentStatus
      : highest;
  }, null);
}

function statusPriority(status) {
  if (!status) return 0;
  const activity = statusActivity(status);
  if (activity === "failed") return 6;
  if (status.attention || activity === "blocked") return 5;
  if (activity === "stalled") return 4;
  return activityPriority[activity] || 0;
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
