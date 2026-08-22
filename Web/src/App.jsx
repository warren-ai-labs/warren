import { lazy, Suspense, useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Terminal } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import { SearchAddon } from "@xterm/addon-search";
import { Unicode11Addon } from "@xterm/addon-unicode11";
import { WebglAddon } from "@xterm/addon-webgl";
import "@xterm/xterm/css/xterm.css";
import "./style.css";

import {
  buildCatalog,
  moveInCatalog,
  rosterFromMessage,
  updateSessionAgentStatus,
  workspaceTabs,
} from "./catalog.js";
import {
  WarrenConnection,
  connectionErrorDetail,
  rejectPendingRequests,
} from "./connection.js";
import {
  captureNavigationPosition,
  createNavigationMemory,
  rememberNavigation,
  resolveNavigationTarget,
  resolveProjectWorkspace,
  resolveRestoredWorkspace,
  restoreNavigationPosition,
  resolveWorkspaceSession,
} from "./navigation.js";
import { runtime, serviceWorkerURL, webSocketURL } from "./runtime.js";
import {
  automaticSessionKind,
  defaultHiddenSessionPresetKinds,
  defaultSessionPresetOrder,
  defaultPresetCommands,
  loadHiddenSessionPresetKinds,
  loadSessionPresetOrder,
  moveSessionPreset,
  orderedSessionPresets,
  releaseWorkspaceSession,
  reserveWorkspaceSession,
  sessionPresets,
  isAgentSession as isSupportedAgentSession,
  shouldAttachCreatedSession,
  visibleSessionPresets,
} from "./session.js";
import {
  defaultTitleTemplate,
  renderCompactTerminalTitle,
  renderTerminalTitle,
  sessionDisplayTitle,
  titlePlaceholders,
} from "./title.js";
import {
  attachTerminalMessage,
  fitTerminalToHost,
  terminalSize,
  waitForTerminalFont,
} from "./terminal.js";
import { mergeAgentEvents } from "./agent.js";
import { AgentView } from "./agent.jsx";
const FileDiffView = lazy(() => import("./filediff.jsx").then(module => ({ default: module.FileDiffView })));
import { handleUnixTextEditingKey, InputQueue, MobileInputDeduper } from "./input.js";
import { OutputBatcher } from "./output.js";
import { decodeOutputFrame, isBinaryEnvelope } from "./wire.js";
import { useKeyboardInset } from "./keyboard.js";
import { projectMenuItems, sessionMenuItems, workspaceMenuItems } from "./contextmenu.js";
import {
  ConfirmationDialog,
  EmptyTerminal,
  ContextMenu,
  MobileShell,
  MobileKeys,
  PresetBar,
  SearchPanel,
  SessionSheet,
  SettingsPage,
  Sidebar,
  TerminalSearch,
  TextInputDialog,
  TopBar,
  WorktreeImportDialog,
} from "./components.jsx";
import { GitPanel } from "./gitpanel.jsx";
import { loadGitPanelUI, saveGitPanelUI, gitPanelUIFileView } from "./gitui.js";
import {
  navigationLocationKey,
  replaceNavigationQuery,
  uiStateFromQuery,
} from "./urlstate.js";
import { enableTerminalTouchScroll } from "./touch.js";

const storageKeys = {
  activeWorkspace: "warren.activeWorkspace",
  activeSession: "warren.activeSession",
  navigationMemory: "warren.navigationMemory",
  expandedProjects: "warren.expandedProjects",
  fontFamily: "warren.terminalFontFamily",
  fontSize: "warren.terminalFontSize",
  titleTemplate: "warren.terminalTitleTemplate",
  presetCommands: "warren.presetCommands",
  presetOrder: "warren.presetOrder",
  hiddenPresets: "warren.hiddenPresets",
};

// How often the open git panel re-fetches remote refs while it stays visible.
const GIT_PANEL_POLL_MS = 5 * 60_000;

const defaultFontFamily = 'ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace';
const defaultFontSize = matchMedia("(max-width: 767px)").matches ? 12 : 13;
const terminalTheme = {
  background: "#151110",
  foreground: "#eae8e6",
  cursor: "#e07850",
  cursorAccent: "#151110",
  selectionBackground: "rgba(224, 120, 80, 0.25)",
  black: "#151110",
  red: "#dc6b6b",
  green: "#7ec699",
  yellow: "#e5c07b",
  blue: "#61afef",
  magenta: "#c678dd",
  cyan: "#56b6c2",
  white: "#eae8e6",
  brightBlack: "#5c5856",
  brightRed: "#e88888",
  brightGreen: "#98d1a8",
  brightYellow: "#ecd08f",
  brightBlue: "#7ec0f5",
  brightMagenta: "#d494e6",
  brightCyan: "#73c7d3",
  brightWhite: "#ffffff",
};
const pendingInputLimit = 64 * 1024;
const terminalSearchDecorations = {
  matchBackground: "#3a3837",
  matchOverviewRuler: "#f59e0b",
  activeMatchBackground: "#e07850",
  activeMatchColorOverviewRuler: "#e07850",
};
const isCoarsePointer = () => (
  typeof window.matchMedia === "function"
    ? window.matchMedia("(pointer: coarse)").matches
    : false
);
const previewSession = {
  title: "Claude",
  process: "claude",
  directory: "/Users/me/Workspace/warren",
  kind: "claude",
};
const previewWorkspace = {
  name: "warren",
  branch: "main",
  path: "/Users/me/Workspace/warren",
};

export default function App() {
  const [catalog, setCatalog] = useState(() => buildCatalog());
  const [activeWorkspace, setActiveWorkspace] = useState(() => localStorage.getItem(storageKeys.activeWorkspace));
  const [activeSession, setActiveSession] = useState(() => localStorage.getItem(storageKeys.activeSession));
  const [navigationMemory, setNavigationMemory] = useState(() => loadNavigationMemory());
  const [attachedSession, setAttachedSession] = useState(null);
  const [expandedProjects, setExpandedProjects] = useState(() => loadSet(storageKeys.expandedProjects));
  const [fontFamily, setFontFamily] = useState(() => localStorage.getItem(storageKeys.fontFamily) || defaultFontFamily);
  const [fontSize, setFontSize] = useState(() => Number(localStorage.getItem(storageKeys.fontSize)) || defaultFontSize);
  const [titleTemplate, setTitleTemplate] = useState(() => localStorage.getItem(storageKeys.titleTemplate) || defaultTitleTemplate);
  const [presetCommands, setPresetCommands] = useState(() => loadPresetCommands());
  const [presetOrder, setPresetOrder] = useState(() => loadPresetOrder());
  const [hiddenPresets, setHiddenPresets] = useState(() => loadHiddenPresets());
  const [autoOpenShell, setAutoOpenShell] = useState(false);
  const [autoStartAI, setAutoStartAI] = useState(false);
  const [connectionStatus, setConnectionStatus] = useState({ message: "Connecting…", online: false });
  const [emptyOverride, setEmptyOverride] = useState(null);
  const [drawerOpen, setDrawerOpen] = useState(false);
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [searchOpen, setSearchOpen] = useState(false);
  const [gitOpen, setGitOpen] = useState(false);
  const gitOpenRef = useRef(false);
  const previousGitOpenRef = useRef(false);
  const [gitPanel, setGitPanel] = useState(null);
  const [gitRefreshing, setGitRefreshing] = useState(false);
  const [gitError, setGitError] = useState("");
  const gitLoadingRef = useRef(null);
  const gitNeedsReloadRef = useRef(false);
  const [gitAction, setGitAction] = useState("");
  const [searchQuery, setSearchQuery] = useState("");
  const [terminalSearchOpen, setTerminalSearchOpen] = useState(false);
  const [terminalSearchQuery, setTerminalSearchQuery] = useState("");
  const [terminalSearchIndex, setTerminalSearchIndex] = useState(-1);
  const [terminalSearchCount, setTerminalSearchCount] = useState(0);
  const [terminalSearchFocusNonce, setTerminalSearchFocusNonce] = useState(0);
  const [contextMenu, setContextMenu] = useState(null);
  const [agentStateBySession, setAgentStateBySession] = useState({});
  const [agentViewOverride, setAgentViewOverride] = useState(null);
  const [sessionSheetOpen, setSessionSheetOpen] = useState(false);
  const [worktreeImportDialog, setWorktreeImportDialog] = useState(null);
  const [renameDialog, setRenameDialog] = useState(null);
  const [deleteDialog, setDeleteDialog] = useState(null);

  const connectionRef = useRef(null);
  const mainRef = useRef(null);
  const terminalHostRef = useRef(null);
  const terminalRef = useRef(null);
  const fitAddonRef = useRef(null);
  const searchAddonRef = useRef(null);
  const webglAddonRef = useRef(null);
  const fitTimerRef = useRef(null);
  const resizeTimerRef = useRef(null);
  const pendingTerminalSizeRef = useRef(null);
  const sentTerminalSizeRef = useRef(null);
  const focusedSessionRef = useRef(null);
  const batcherRef = useRef(null);
  const recoveryAnchorRef = useRef(null);
  const pendingStartAnchorRef = useRef(null);
  const reanchorRequiredRef = useRef(false);
  const snapshotPendingRef = useRef(false);
  const messageHandlerRef = useRef(() => {});
  const connectionStateHandlerRef = useRef(() => {});
  const maintenanceTimeoutRef = useRef(null);
  const appStateRef = useRef({});
  const pendingRequestsRef = useRef(new Map());
  const fileDiffNeedsReloadRef = useRef(false);
  const creatingSessionWorkspaceIDsRef = useRef(new Set());
  const settingsLoadedRef = useRef(false);
  const inputQueueRef = useRef(null);
  const navigationBeforeSettingsRef = useRef(null);
  const autoFocusOnAttachRef = useRef(true);
  const projectDragRef = useRef(null);
  const isMobile = useMediaQuery("(max-width: 767px)");
  const orderedPresets = useMemo(() => orderedSessionPresets(presetOrder), [presetOrder]);
  const visiblePresets = useMemo(
    () => visibleSessionPresets(orderedPresets, hiddenPresets),
    [hiddenPresets, orderedPresets],
  );
  useKeyboardInset(mainRef);
  useEffect(() => {
    const handleKeyDown = event => {
      handleUnixTextEditingKey(event);
    };
    // Capture before component handlers so every input shares the same
    // readline vocabulary, while the xterm helper textarea opts out.
    document.addEventListener("keydown", handleKeyDown, true);
    return () => document.removeEventListener("keydown", handleKeyDown, true);
  }, []);
  if (inputQueueRef.current === null) {
    inputQueueRef.current = new InputQueue({
      limit: pendingInputLimit,
      send: data => Boolean(connectionRef.current?.sendBinary(data)),
      onSendFailure: () => connectionRef.current?.reconnectNow(),
    });
  }

  const clearMaintenanceTimeout = useCallback(() => {
    if (maintenanceTimeoutRef.current !== null) {
      clearTimeout(maintenanceTimeoutRef.current);
      maintenanceTimeoutRef.current = null;
    }
  }, []);

  const scheduleMaintenanceTimeout = useCallback(() => {
    clearMaintenanceTimeout();
    maintenanceTimeoutRef.current = setTimeout(() => {
      maintenanceTimeoutRef.current = null;
      setConnectionStatus({ message: "Reconnecting…", online: false });
    }, 10_000);
  }, [clearMaintenanceTimeout]);

  const selectedWorkspaceID = useMemo(() => {
    if (activeWorkspace && catalog.workspaces.some(workspace => workspace.id === activeWorkspace)) {
      return activeWorkspace;
    }
    return catalog.workspaces[0]?.id || null;
  }, [activeWorkspace, catalog.workspaces]);
  const selectedWorkspace = useMemo(
    () => catalog.workspaces.find(workspace => workspace.id === selectedWorkspaceID) || null,
    [catalog.workspaces, selectedWorkspaceID],
  );
  const tabs = useMemo(
    () => selectedWorkspaceID ? workspaceTabs(catalog, selectedWorkspaceID) : [],
    [catalog, selectedWorkspaceID],
  );
  const selectedSession = activeSession ? catalog.sessions.get(activeSession) || null : null;
  const paneTitle = selectedSession
    ? renderTerminalTitle(titleTemplate, selectedSession, selectedWorkspace, catalog.host)
    : "";
  const paneDisplayTitle = selectedSession
    ? renderCompactTerminalTitle(titleTemplate, selectedSession, selectedWorkspace, catalog.host)
    : "";
  const titlePreview = renderTerminalTitle(
    titleTemplate,
    selectedSession || previewSession,
    selectedWorkspace || previewWorkspace,
    catalog.host,
  );

  appStateRef.current = {
    catalog,
    activeWorkspace: selectedWorkspaceID,
    activeSession,
    attachedSession,
    navigationMemory,
  };

  const request = useCallback((method, params = {}, onResult = null, onError = null) => {
    const id = connectionRef.current?.request(method, params);
    if (!id) return false;
    if (onResult || onError) {
      pendingRequestsRef.current.set(id, { onResult, onError });
    }
    return true;
  }, []);

  const applyRemoteSettings = useCallback(result => {
    if (!result || typeof result !== "object") return;
    if (typeof result.autoOpenShell === "boolean") {
      setAutoOpenShell(result.autoOpenShell);
    }
    if (typeof result.autoStartAI === "boolean") {
      setAutoStartAI(result.autoStartAI);
    }
  }, []);

  const loadRemoteSettings = useCallback(() => {
    if (settingsLoadedRef.current) return;
    settingsLoadedRef.current = true;
    if (!request("settings.get", {}, applyRemoteSettings, () => {
      settingsLoadedRef.current = false;
    })) {
      settingsLoadedRef.current = false;
    }
  }, [applyRemoteSettings, request]);

  const setGitOpenState = useCallback(value => {
    gitOpenRef.current = typeof value === "function" ? value(gitOpenRef.current) : value;
    setGitOpen(value);
  }, []);

  const loadGitPanel = useCallback((force = false, requestedWorkspaceID = selectedWorkspaceID) => {
    const workspaceID = requestedWorkspaceID;
    if (!workspaceID || gitLoadingRef.current === workspaceID) return;
    gitLoadingRef.current = workspaceID;
    setGitRefreshing(true);
    setGitError("");
    setGitAction("");
    const finish = () => {
      if (gitLoadingRef.current === workspaceID) {
        gitLoadingRef.current = null;
        setGitRefreshing(false);
      }
    };
    const sent = request("git.panel", { workspace: workspaceID, fetch: true, force }, result => {
      if (appStateRef.current.activeWorkspace !== workspaceID) {
        finish();
        return;
      }
      setGitPanel(result);
      finish();
    }, error => {
      if (appStateRef.current.activeWorkspace !== workspaceID) {
        finish();
        return;
      }
      setGitError(error);
      finish();
    });
    if (!sent) {
      gitNeedsReloadRef.current = true;
      setGitError("Not connected");
      finish();
    }
  }, [request, selectedWorkspaceID]);

  useEffect(() => {
    if (!gitOpen) return;
    const timer = setInterval(() => loadGitPanel(), GIT_PANEL_POLL_MS);
    return () => clearInterval(timer);
  }, [gitOpen, loadGitPanel]);

  const runGitAction = useCallback((method, params) => {
    setGitAction(method);
    setGitError("");
    const sent = request(method, params, () => {
      setGitAction("");
      loadGitPanel();
    }, error => {
      setGitAction("");
      setGitError(error);
    });
    if (!sent) {
      setGitAction("");
      setGitError("Not connected");
    }
  }, [request, loadGitPanel]);

  const runGitCommit = useCallback(message => {
    setGitAction("git.commit");
    setGitError("");
    const sent = request("git.commit", { workspace: selectedWorkspaceID, message }, () => {
      setGitAction("");
      loadGitPanel();
      runGitAction("git.push", { workspace: selectedWorkspaceID });
    }, error => {
      setGitAction("");
      setGitError(error);
    });
    if (!sent) {
      setGitAction("");
      setGitError("Not connected");
    }
  }, [request, loadGitPanel, runGitAction, selectedWorkspaceID]);

  const [fileView, setFileView] = useState(null);
  const [fileDiff, setFileDiff] = useState({ loading: false, diff: "", content: "", error: "" });
  const fileViewKeyRef = useRef(null);
  const fileViewRef = useRef(null);
  const [gitPanelSavedUI, setGitPanelSavedUI] = useState({});
  const gitPanelUIStateRef = useRef({});
  const [fileDiffViewTab, setFileDiffViewTabState] = useState("diff");
  const [fileDiffStyle, setFileDiffStyleState] = useState("unified");
  const fileDiffViewRef = useRef({ viewTab: "diff", diffStyle: "unified" });

  const setCurrentFileView = useCallback(value => {
    if (!value) {
      fileViewKeyRef.current = null;
      fileDiffNeedsReloadRef.current = false;
    }
    fileViewRef.current = value;
    setFileView(value);
  }, []);

  const setFileDiffViewTab = useCallback(value => {
    const next = value === "file" ? "file" : "diff";
    fileDiffViewRef.current = { ...fileDiffViewRef.current, viewTab: next };
    setFileDiffViewTabState(next);
  }, []);

  const setFileDiffStyle = useCallback(value => {
    const next = value === "split" ? "split" : "unified";
    fileDiffViewRef.current = { ...fileDiffViewRef.current, diffStyle: next };
    setFileDiffStyleState(next);
  }, []);

  const setFileDiffView = useCallback(({ viewTab, diffStyle } = {}) => {
    const next = {
      viewTab: viewTab === "file" ? "file" : "diff",
      diffStyle: diffStyle === "split" ? "split" : "unified",
    };
    fileDiffViewRef.current = next;
    setFileDiffViewTabState(next.viewTab);
    setFileDiffStyleState(next.diffStyle);
  }, []);

  const openFileView = useCallback((change, commit = "", workspaceID = selectedWorkspaceID) => {
    const key = commit ? `${workspaceID}:${commit}:${change.path}` : `${workspaceID}:${change.staged ? "s" : "u"}:${change.path}`;
    fileViewKeyRef.current = key;
    setCurrentFileView({ key, path: change.path, staged: change.staged, commit });
    setFileDiff({ loading: true, diff: "", content: "", error: "" });
    const params = { path: change.path, staged: change.staged };
    if (commit) params.commit = commit;
    const sent = request("git.diff", { workspace: workspaceID, ...params }, result => {
      if (fileViewKeyRef.current !== key) return;
      fileDiffNeedsReloadRef.current = false;
      const truncatedParts = [
        result?.diffTruncated ? "diff" : "",
        result?.contentTruncated ? "file content" : "",
      ].filter(Boolean);
      const notice = truncatedParts.length > 0
        ? `Result truncated at the 16 MiB system limit: ${truncatedParts.join(" and ")}.`
        : "";
      setFileDiff({
        loading: false,
        diff: result?.diff || "",
        content: result?.content || "",
        error: "",
        notice,
      });
    }, diffError => {
      if (fileViewKeyRef.current !== key) return;
      setFileDiff({ loading: false, diff: "", content: "", error: diffError });
    });
    if (!sent && fileViewKeyRef.current === key) {
      gitNeedsReloadRef.current = true;
      fileDiffNeedsReloadRef.current = true;
      setFileDiff({ loading: false, diff: "", content: "", error: "Not connected; the diff will retry after reconnecting." });
    }
  }, [request, selectedWorkspaceID, setCurrentFileView]);

  const persistCurrentGitUI = useCallback(workspaceID => {
    if (!workspaceID) return;
    saveGitPanelUI(localStorage, workspaceID, {
      ...gitPanelUIStateRef.current,
      viewTab: fileDiffViewRef.current.viewTab,
      diffStyle: fileDiffViewRef.current.diffStyle,
      fileView: fileViewRef.current ? gitPanelUIFileView(fileViewRef.current) : null,
    });
  }, []);

  const closeFileView = useCallback(() => {
    setCurrentFileView(null);
    persistCurrentGitUI(selectedWorkspaceID);
  }, [persistCurrentGitUI, selectedWorkspaceID, setCurrentFileView]);

  const handleGitUIChange = useCallback(ui => {
    gitPanelUIStateRef.current = ui;
    persistCurrentGitUI(selectedWorkspaceID);
  }, [persistCurrentGitUI, selectedWorkspaceID]);

  const restoreGitUIForWorkspace = useCallback(workspaceID => {
    if (!workspaceID) return;
    const snapshot = loadGitPanelUI(localStorage, workspaceID);
    gitPanelUIStateRef.current = snapshot;
    setGitPanelSavedUI(snapshot);
    setFileDiffView(snapshot);
    if (gitOpenRef.current && snapshot.fileView) {
      openFileView(snapshot.fileView, snapshot.fileView.commit || "", workspaceID);
    } else {
      setCurrentFileView(null);
    }
  }, [openFileView, setCurrentFileView, setFileDiffView]);

  useEffect(() => {
    if (gitOpen) {
      setGitPanel(null);
      loadGitPanel();
    }
  }, [gitOpen, loadGitPanel]);

  const loadAgentHistory = useCallback((sessionID, before = 0) => {
    const params = { session: sessionID, limit: "200" };
    if (before > 0) params.before = String(before);
    setAgentStateBySession(previous => {
      const current = previous[sessionID] || {};
      return {
        ...previous,
        [sessionID]: { ...current, historyLoading: true },
      };
    });
    if (!request("agent.history", params, result => {
        const events = Array.isArray(result?.events) ? result.events : [];
        const cursor = Number(result?.cursor) || 0;
        const hasMore = Boolean(result?.hasMore);
        const epoch = result?.epoch;
        setAgentStateBySession(previous => {
          const current = previous[sessionID] || {};
          const sameEpoch = !epoch || current.epoch === epoch;
          return {
            ...previous,
            [sessionID]: {
              ...current,
              epoch: epoch || current.epoch,
              events: mergeAgentEvents(
                sameEpoch ? current.events : [],
                events,
                // Older pages must never be truncated by the live tail cap:
                // slicing the newest N events here removes a middle chunk of
                // the already-loaded conversation and loses messages.
                { cap: before === 0 },
              ),
              status: current.status || null,
              historyCursor: cursor,
              historyHasMore: hasMore,
              historyLoading: false,
              historyLoaded: true,
            },
          };
        });
      }, () => {
        // A failed history request must not leave the loader spinning; the
        // effect retries after the next state change or reconnect.
        setAgentStateBySession(previous => {
          const current = previous[sessionID] || {};
          return {
            ...previous,
            [sessionID]: { ...current, historyLoading: false },
          };
        });
      })) {
      // Not connected yet; clear the loading flag so the effect can retry
      // once the transport is back.
      setAgentStateBySession(previous => {
        const current = previous[sessionID] || {};
        return {
          ...previous,
          [sessionID]: { ...current, historyLoading: false },
        };
      });
    }
  }, [request]);

  const markAttachReady = useCallback((sessionID, flush = true) => {
    const state = appStateRef.current;
    if (state.activeSession !== sessionID) return;
    // The attach response is ordered before subsequent WebSocket frames, so
    // it is safe to accept input even if a legacy relay omits `attached`.
    state.attachedSession = sessionID;
    setAttachedSession(sessionID);
    if (flush) inputQueueRef.current.flush(sessionID);
    // Touch devices must not pop the software keyboard as a side effect of
    // attaching a session; the user focuses the terminal by tapping it.
    if (autoFocusOnAttachRef.current && !isCoarsePointer()) terminalRef.current?.focus();
  }, []);

  const sendInput = useCallback(data => {
    const state = appStateRef.current;
    if (!data || !state.activeSession) return;
    if (state.attachedSession !== state.activeSession) {
      inputQueueRef.current.enqueue(state.activeSession, data);
      return;
    }
    if (!connectionRef.current?.sendBinary(data)) {
      inputQueueRef.current.enqueue(state.activeSession, data);
      connectionRef.current?.reconnectNow();
    }
  }, []);

  const sendAgentInput = useCallback(text => {
    // The agent process is a TUI: the only input channel is the PTY. Codex
    // reads a literal CR as text (a newline inside the input box), not as a
    // submit key, so the message is written first and the kitty-protocol
    // Enter event (CSI 13 u) is delivered in its own frame afterwards. The
    // small delay keeps the TUI from folding both writes into one paste and
    // dropping the message before the Enter key.
    const state = appStateRef.current;
    const sessionID = state.activeSession;
    if (!sessionID) return;
    sendInput(text.replace(/\n/g, "\r"));
    setTimeout(() => {
      if (appStateRef.current.activeSession === sessionID) {
        sendInput("\x1b[13u");
      }
    }, 80);
  }, [sendInput]);

  const fitTerminal = useCallback(() => {
    if (fitTimerRef.current !== null) {
      clearTimeout(fitTimerRef.current);
      fitTimerRef.current = null;
    }
    const node = terminalHostRef.current;
    fitTerminalToHost(fitAddonRef.current, node);
  }, []);

  const focusTerminal = useCallback(() => {
    const state = appStateRef.current;
    if (state.activeSession && state.attachedSession === state.activeSession) {
      terminalRef.current?.focus();
    }
  }, []);

  const clearTerminalSearch = useCallback(() => {
    setTerminalSearchOpen(false);
    setTerminalSearchQuery("");
    setTerminalSearchIndex(-1);
    setTerminalSearchCount(0);
    searchAddonRef.current?.clearDecorations();
  }, []);

  const openTerminalSearch = useCallback(() => {
    if (isCoarsePointer()) return;
    setTerminalSearchOpen(true);
    setTerminalSearchFocusNonce(value => value + 1);
  }, []);

  const closeTerminalSearch = useCallback(() => {
    clearTerminalSearch();
    terminalRef.current?.focus();
  }, [clearTerminalSearch]);

  const updateTerminalSearchQuery = useCallback(query => {
    setTerminalSearchQuery(query);
    const addon = searchAddonRef.current;
    if (!addon) return;
    if (!query) {
      addon.clearDecorations();
      setTerminalSearchIndex(-1);
      setTerminalSearchCount(0);
      return;
    }
    addon.findNext(query, {
      incremental: true,
      decorations: terminalSearchDecorations,
    });
  }, []);

  const stepTerminalSearch = useCallback(direction => {
    const addon = searchAddonRef.current;
    const query = terminalSearchQuery;
    if (!addon || !query) return;
    const options = { decorations: terminalSearchDecorations };
    if (direction === "next") addon.findNext(query, options);
    else addon.findPrevious(query, options);
  }, [terminalSearchQuery]);

  const refreshTerminal = useCallback(() => {
    const terminal = terminalRef.current;
    if (!terminal || terminal.rows <= 0) return;
    // Re-entering the shell after a page (settings/search) can leave the
    // renderer with a stale frame; force one repaint so the terminal never
    // waits for the next keystroke or click.
    terminal.refresh(0, terminal.rows - 1);
    terminal.scrollToBottom();
  }, []);

  const scheduleTerminalFit = useCallback(() => {
    // Keyboard animations resize the terminal host every frame; fitting on
    // each event makes the canvas re-render continuously and flicker. Wait
    // until the resize stream settles so a single fit lands after the
    // keyboard (or window) stops moving.
    if (fitTimerRef.current !== null) clearTimeout(fitTimerRef.current);
    fitTimerRef.current = setTimeout(() => {
      fitTimerRef.current = null;
      fitTerminal();
    }, 80);
  }, [fitTerminal]);

  const returnFocusToTerminal = useCallback(() => {
    requestAnimationFrame(() => {
      scheduleTerminalFit();
      refreshTerminal();
      if (!isCoarsePointer()) focusTerminal();
    });
  }, [focusTerminal, refreshTerminal, scheduleTerminalFit]);

  const scheduleRemoteResize = useCallback(size => {
    pendingTerminalSizeRef.current = size;
    if (resizeTimerRef.current !== null) return;
    resizeTimerRef.current = setTimeout(() => {
      resizeTimerRef.current = null;
      const next = pendingTerminalSizeRef.current;
      pendingTerminalSizeRef.current = null;
      if (!next || (next.cols === sentTerminalSizeRef.current?.cols && next.rows === sentTerminalSizeRef.current?.rows)) return;
      const state = appStateRef.current;
      if (state.activeSession
        && state.attachedSession === state.activeSession
        && focusedSessionRef.current === state.activeSession) {
        if (request("session.resize", { cols: next.cols, rows: next.rows })) {
          sentTerminalSizeRef.current = next;
        }
      }
    }, 40);
  }, [request]);

  const requestSessionFocus = useCallback((focused, size = null) => {
    const state = appStateRef.current;
    const sessionID = state.activeSession;
    if (!sessionID || state.attachedSession !== sessionID) return false;
    const params = { focused };
    if (focused) {
      const next = size || terminalSize(terminalRef.current);
      if (next) Object.assign(params, next);
    }
    const sent = request("session.focus", params, result => {
      if (appStateRef.current.activeSession !== sessionID
        || appStateRef.current.attachedSession !== sessionID) return;
      if (focused) {
        focusedSessionRef.current = result?.focused ? sessionID : null;
      } else if (focusedSessionRef.current === sessionID) {
        focusedSessionRef.current = null;
      }
    });
    if (!sent) return false;
    focusedSessionRef.current = focused ? sessionID : null;
    return true;
  }, [request]);

  const toggleAgentView = useCallback(view => {
    setAgentViewOverride(view);
    if (view !== "terminal") return;
    // Re-entering the terminal after a chat view must reclaim the shared PTY
    // geometry right away: touch devices keep protocol focus while viewing,
    // and desktop needs DOM focus back once the hidden terminal is visible.
    requestAnimationFrame(() => {
      if (isCoarsePointer()) requestSessionFocus(true);
      else focusTerminal();
    });
  }, [focusTerminal, requestSessionFocus]);

  const recordNavigation = useCallback((catalogValue, workspaceID, sessionID = null) => {
    const state = appStateRef.current;
    const next = rememberNavigation(
      state.navigationMemory,
      catalogValue,
      workspaceID,
      sessionID,
    );
    if (sameNavigationMemory(state.navigationMemory, next)) return;
    state.navigationMemory = next;
    setNavigationMemory(next);
  }, []);

  const attachSession = useCallback((sessionID, force = false, autoFocus = true, explicit = true) => {
    if (!sessionID) return;
    const state = appStateRef.current;
    const workspaceID = state.catalog.sessions.get(sessionID)?.workspace;
    if (workspaceID) recordNavigation(state.catalog, workspaceID, sessionID);
    autoFocusOnAttachRef.current = autoFocus;
    if (!force && sessionID === state.attachedSession) {
      // Roster broadcasts re-enter this branch too, but the session is
      // already attached and streaming. Only an explicit entry (tab click)
      // should force a repaint and reclaim DOM focus; doing that on every
      // roster makes mobile redraw the terminal constantly. Mobile still
      // reclaims protocol focus so a re-adopted runtime gets the phone
      // viewport back; the server now treats same-size claims as no-ops.
      if (explicit) {
        refreshTerminal();
        if (isCoarsePointer()) requestSessionFocus(true);
        else terminalRef.current?.focus();
      } else if (isCoarsePointer()) {
        requestSessionFocus(true);
      }
      return;
    }
    const changed = sessionID !== state.activeSession;
    state.activeSession = sessionID;
    state.attachedSession = null;
    focusedSessionRef.current = null;
    if (changed) inputQueueRef.current.clear();
    setActiveSession(sessionID);
    setAttachedSession(null);
    setEmptyOverride(null);
    sentTerminalSizeRef.current = null;
    if (changed) {
      terminalRef.current?.clear();
      clearTerminalSearch();
      recoveryAnchorRef.current = null;
      reanchorRequiredRef.current = false;
      setAgentViewOverride(null);
    }
    const anchor = (!changed || reanchorRequiredRef.current)
      ? null
      : recoveryAnchorRef.current;
    const message = attachTerminalMessage(sessionID, terminalRef.current, anchor);
    request(message.method, message.params, () => {
      markAttachReady(sessionID);
      // Mobile viewers need the shared PTY geometry before the first tap so
      // the shell reflows to the phone viewport. Claiming protocol focus here
      // does not focus the textarea, so the soft keyboard stays closed.
      if (isCoarsePointer()) requestSessionFocus(true);
    });
  }, [clearTerminalSearch, markAttachReady, recordNavigation, refreshTerminal, request, requestSessionFocus]);

  const createSession = useCallback((kind, targetWorkspaceID = null) => {
    const workspaceID = targetWorkspaceID
      || appStateRef.current.activeWorkspace
      || selectedWorkspaceID;
    if (!reserveWorkspaceSession(creatingSessionWorkspaceIDsRef.current, workspaceID)) {
      return false;
    }
    const finish = () => {
      releaseWorkspaceSession(creatingSessionWorkspaceIDsRef.current, workspaceID);
    };
    const preset = orderedPresets.find(value => value.kind === kind) || orderedPresets[0];
    const sent = request("session.create", {
      workspace: workspaceID,
      kind: preset.kind,
      command: presetCommands[preset.kind] || "",
      title: preset.title,
    }, result => {
      finish();
      const sessionID = result?.id;
      if (sessionID && shouldAttachCreatedSession(
        appStateRef.current.activeWorkspace,
        workspaceID,
      )) {
        attachSession(sessionID);
      }
    }, detail => {
      finish();
      setConnectionStatus({ message: detail, online: false });
      if (appStateRef.current.activeWorkspace === workspaceID) {
        setEmptyOverride({ loading: false, message: detail });
      }
    });
    if (appStateRef.current.activeWorkspace === workspaceID) {
      setEmptyOverride({
        loading: true,
        message: sent ? `Starting ${preset.title}…` : "Waiting for connection…",
      });
    }
    if (!sent) {
      finish();
      connectionRef.current?.reconnectNow();
    }
    return sent;
  }, [attachSession, orderedPresets, presetCommands, request, selectedWorkspaceID]);

  const chooseWorkspace = useCallback((workspaceID, preferredSessionID = null, automaticEntry = true) => {
    const state = appStateRef.current;
    const previousWorkspaceID = state.activeWorkspace;
    if (previousWorkspaceID && previousWorkspaceID !== workspaceID) {
      persistCurrentGitUI(previousWorkspaceID);
    }
    const wasAttached = Boolean(state.activeSession || state.attachedSession);
    const sessionID = resolveWorkspaceSession(
      state.catalog,
      workspaceID,
      state.navigationMemory,
      preferredSessionID,
    );
    const nextTabs = workspaceTabs(state.catalog, workspaceID);
    recordNavigation(state.catalog, workspaceID, sessionID);
    state.activeWorkspace = workspaceID;
    state.activeSession = null;
    state.attachedSession = null;
    focusedSessionRef.current = null;
    setActiveWorkspace(workspaceID);
    if (previousWorkspaceID !== workspaceID) {
      restoreGitUIForWorkspace(workspaceID);
    }
    setActiveSession(null);
    setAttachedSession(null);
    setEmptyOverride(null);
    setAgentViewOverride(null);
    terminalRef.current?.clear();
    clearTerminalSearch();
    recoveryAnchorRef.current = null;
    reanchorRequiredRef.current = false;
    setDrawerOpen(false);

    if (sessionID) attachSession(sessionID, true);
    else if (nextTabs.length) attachSession(nextTabs[0].id, true);
    else {
      if (wasAttached) request("session.detach");
      const automaticKind = automaticSessionKind({
        tabs: nextTabs,
        pending: creatingSessionWorkspaceIDsRef.current.has(workspaceID),
        explicit: automaticEntry,
        autoStartAI,
        presets: visiblePresets,
      });
      if (automaticKind) createSession(automaticKind, workspaceID);
    }
  }, [attachSession, autoStartAI, clearTerminalSearch, createSession, persistCurrentGitUI, recordNavigation, request, restoreGitUIForWorkspace, visiblePresets]);

  const chooseSessionPreset = useCallback(kind => {
    setSessionSheetOpen(false);
    createSession(kind);
  }, [createSession]);

  const updatePresetCommand = useCallback((kind, command) => {
    setPresetCommands(previous => {
      const next = { ...previous, [kind]: command };
      localStorage.setItem(storageKeys.presetCommands, JSON.stringify(next));
      return next;
    });
  }, []);

  const movePreset = useCallback((kind, offset) => {
    setPresetOrder(previous => {
      const next = moveSessionPreset(previous, kind, offset);
      localStorage.setItem(storageKeys.presetOrder, JSON.stringify(next));
      return next;
    });
  }, []);

  const updatePresetVisibility = useCallback((kind, visible) => {
    setHiddenPresets(previous => {
      const hidden = new Set(previous);
      if (visible) hidden.delete(kind);
      else hidden.add(kind);
      const next = sessionPresets.map(preset => preset.kind).filter(value => hidden.has(value));
      localStorage.setItem(storageKeys.hiddenPresets, JSON.stringify(next));
      return next;
    });
  }, []);

  const openWorkspace = useCallback((workspaceID, explicit = false) => {
    // A normal workspace-open gesture is opt-in through Settings. The
    // project-row plus button passes explicit=true and remains a deliberate
    // New Session action regardless of this default.
    chooseWorkspace(workspaceID, null, !explicit);
    const tabs = workspaceTabs(appStateRef.current.catalog, workspaceID);
    if (!creatingSessionWorkspaceIDsRef.current.has(workspaceID)
      && (explicit || (autoOpenShell && tabs.length === 0))) {
      createSession("shell", workspaceID);
    }
  }, [autoOpenShell, chooseWorkspace, createSession]);

  const acceptRoster = useCallback(message => {
    clearMaintenanceTimeout();
    connectionRef.current?.markStable();
    loadRemoteSettings();
    const nextCatalog = buildCatalog(rosterFromMessage(message));
    const state = appStateRef.current;
    const previousWorkspaceID = state.activeWorkspace;
    const nextWorkspaceID = resolveRestoredWorkspace(nextCatalog, state.activeWorkspace, state.activeSession);
    const nextSessionID = nextWorkspaceID
      ? resolveWorkspaceSession(nextCatalog, nextWorkspaceID, state.navigationMemory, state.activeSession)
      : null;
    const nextTabs = nextWorkspaceID ? workspaceTabs(nextCatalog, nextWorkspaceID) : [];
    const activeTabWasRemoved = state.activeSession && !nextTabs.some(tab => tab.id === state.activeSession);

    state.catalog = nextCatalog;
    state.activeWorkspace = nextWorkspaceID;
    setCatalog(nextCatalog);
    setActiveWorkspace(nextWorkspaceID);
    if (previousWorkspaceID !== nextWorkspaceID) {
      if (previousWorkspaceID) persistCurrentGitUI(previousWorkspaceID);
      restoreGitUIForWorkspace(nextWorkspaceID);
    }
    setEmptyOverride(null);
    if (nextWorkspaceID) {
      const workspace = nextCatalog.workspaces.find(value => value.id === nextWorkspaceID);
      if (workspace && !projectDragRef.current) {
        setExpandedProjects(previous => previous.has(workspace.project)
          ? previous
          : new Set([...previous, workspace.project]));
      }
    }

    if (activeTabWasRemoved) {
      state.activeSession = null;
      state.attachedSession = null;
      focusedSessionRef.current = null;
      setActiveSession(null);
      setAttachedSession(null);
      setAgentViewOverride(null);
      terminalRef.current?.clear();
      clearTerminalSearch();
      recoveryAnchorRef.current = null;
      reanchorRequiredRef.current = false;
    }

    setConnectionStatus({ message: "Connected", online: true });
    if (gitNeedsReloadRef.current || fileDiffNeedsReloadRef.current) {
      gitNeedsReloadRef.current = false;
      gitLoadingRef.current = null;
      if (gitOpenRef.current && nextWorkspaceID) {
        loadGitPanel(true, nextWorkspaceID);
        if (fileDiffNeedsReloadRef.current && fileViewRef.current) {
          const pendingView = fileViewRef.current;
          openFileView(pendingView, pendingView.commit || "", nextWorkspaceID);
        }
      }
    }
    if (nextSessionID) {
      const rememberedSessionID = state.navigationMemory?.sessionByWorkspaceID?.[nextWorkspaceID];
      const hasRememberedSession = rememberedSessionID
        && nextTabs.some(tab => tab.id === rememberedSessionID);
      const preferred = (!state.activeSession || activeTabWasRemoved) && !hasRememberedSession
        ? nextTabs.find(tab =>
          isSupportedAgentSession(tab),
        )
        : null;
      const sessionID = preferred?.id || nextSessionID;
      recordNavigation(nextCatalog, nextWorkspaceID, sessionID);
      attachSession(sessionID, false, false, false);
    }
    else if (activeTabWasRemoved) request("session.detach");
  }, [attachSession, clearMaintenanceTimeout, clearTerminalSearch, loadGitPanel, loadRemoteSettings, openFileView, persistCurrentGitUI, recordNavigation, request, restoreGitUIForWorkspace]);

  const acceptMessage = useCallback(event => {
    if (event.data instanceof ArrayBuffer) {
      const bytes = new Uint8Array(event.data);
      const decoded = decodeOutputFrame(bytes);
      const attached = appStateRef.current.attachedSession;
      if (decoded && (!attached || decoded.header.sessionID === attached)) {
        const current = recoveryAnchorRef.current;
        if (current && !snapshotPendingRef.current) {
          if (decoded.header.epoch !== current.epoch || decoded.header.sequence !== current.sequence) {
            // A gap means Host rotated the spool or the ring evicted our
            // anchor; reconnect without an anchor and reanchor from a tmux
            // snapshot instead of silently skipping or duplicating bytes.
            reanchorRequiredRef.current = true;
            connectionRef.current?.reset();
            return;
          }
          if (!batcherRef.current?.hasPending) {
            // Remember the byte position before this batch. If the renderer
            // cannot keep up and the batch is dropped, the reconnect can
            // resume exactly here instead of re-serving the whole ring.
            pendingStartAnchorRef.current = recoveryAnchorRef.current;
          }
          recoveryAnchorRef.current = {
            epoch: decoded.header.epoch,
            sequence: current.sequence + decoded.header.payloadLength,
          };
        }
        batcherRef.current?.enqueue(decoded.payload);
      } else if (decoded) {
        // A stale frame can still be queued while switching sessions. It must
        // not leak into the newly selected terminal.
      } else if (isBinaryEnvelope(bytes)) {
        // The frame claims to be a Warren envelope but cannot be decoded.
        // Rendering it would print binary garbage (DENB headers) into the
        // terminal; treat it as a protocol error and reanchor instead.
        reanchorRequiredRef.current = true;
        connectionRef.current?.reset();
      } else {
        // Legacy raw PTY payload (older daemon builds send bytes without the
        // envelope). Render it as-is.
        batcherRef.current?.enqueue(bytes);
      }
      return;
    }

    // Control messages, exit messages, and recovery markers must never jump
    // ahead of buffered terminal bytes; flush the batch first.
    batcherRef.current?.flush();

    let message;
    try {
      message = JSON.parse(event.data);
    } catch {
      setConnectionStatus({ message: "Protocol error", online: false });
      connectionRef.current?.reset();
      return;
    }

    switch (message.t) {
    case "response": {
      const handler = pendingRequestsRef.current.get(message.id);
      pendingRequestsRef.current.delete(message.id);
      if (!message.ok) {
        const detail = message.error || "Request failed";
        if (handler?.onError) {
          handler.onError(detail);
        } else {
          setConnectionStatus({ message: detail, online: false });
          setEmptyOverride({ loading: false, message: detail });
        }
      } else {
        handler?.onResult?.(message.result);
      }
      break;
    }
    case "roster":
      acceptRoster(message);
      break;
    case "attached": {
      if (appStateRef.current.activeSession !== message.session) break;
      focusedSessionRef.current = null;
      setActiveSession(message.session);
      markAttachReady(message.session);
      setEmptyOverride(null);
      if (message.reanchor) {
        terminalRef.current?.clear();
        snapshotPendingRef.current = true;
      } else {
        snapshotPendingRef.current = false;
      }
      if (Number.isFinite(message.epoch) && Number.isFinite(message.sequence)) {
        recoveryAnchorRef.current = {
          epoch: message.epoch,
          sequence: message.sequence,
        };
      } else {
        // Legacy relay: no recovery metadata, raw payloads only. Keep the
        // anchor null so frame validation stays disabled.
        recoveryAnchorRef.current = null;
      }
      reanchorRequiredRef.current = false;
      requestAnimationFrame(() => {
        fitTerminal();
        terminalRef.current?.scrollToBottom();
        const terminal = terminalRef.current;
        if (autoFocusOnAttachRef.current && terminal && document.hasFocus() && !isCoarsePointer()) {
          terminal.focus();
          if (focusedSessionRef.current !== message.session) requestSessionFocus(true);
        }
      });
      break;
    }
    case "created":
      appStateRef.current.activeSession = null;
      appStateRef.current.attachedSession = null;
      focusedSessionRef.current = null;
      setActiveSession(null);
      setAttachedSession(null);
      setEmptyOverride(null);
      attachSession(message.session);
      break;
    case "synced":
      if (appStateRef.current.attachedSession === message.session) {
        recoveryAnchorRef.current = {
          epoch: message.epoch,
          sequence: message.sequence,
        };
        snapshotPendingRef.current = false;
      }
      break;
    case "agent":
      setAgentStateBySession(previous => {
        const current = previous[message.session];
        const sameEpoch = !message.epoch || current?.epoch === message.epoch;
        if (!sameEpoch) {
          // A new projection epoch means the daemon restarted: drop the old
          // conversation and let the history loader refetch from scratch.
          return {
            ...previous,
            [message.session]: {
              epoch: message.epoch,
              events: mergeAgentEvents([], message.events),
              status: current?.status || null,
              historyCursor: 0,
              historyHasMore: false,
              historyLoading: false,
              historyLoaded: false,
            },
          };
        }
        const base = current?.events || [];
        return {
          ...previous,
          [message.session]: {
            ...current,
            epoch: message.epoch || current?.epoch,
            events: mergeAgentEvents(base, message.events),
            status: current?.status || null,
          },
        };
      });
      break;
    case "agent.status": {
      const status = message.status || null;
      setAgentStateBySession(previous => {
        const current = previous[message.session];
        const sameEpoch = !message.epoch || current?.epoch === message.epoch;
        return {
          ...previous,
          [message.session]: {
            ...current,
            epoch: message.epoch || current?.epoch,
            events: sameEpoch ? current?.events || [] : [],
            status,
            historyCursor: sameEpoch ? current?.historyCursor || 0 : 0,
            historyHasMore: sameEpoch ? Boolean(current?.historyHasMore) : false,
            historyLoading: sameEpoch ? Boolean(current?.historyLoading) : false,
            historyLoaded: sameEpoch ? Boolean(current?.historyLoaded) : false,
          },
        };
      });
      setCatalog(previous => updateSessionAgentStatus(previous, message.session, status));
      break;
    }
    case "runtimeMetadata":
      setCatalog(previous => {
        const session = previous.sessions.get(message.session);
        if (!session) return previous;
        const sessions = new Map(previous.sessions);
        sessions.set(message.session, {
          ...session,
          process: message.process || "",
          directory: message.directory || "",
        });
        return { ...previous, sessions };
      });
      break;
    case "sessionDeleted":
      if (appStateRef.current.activeSession === message.session) {
        appStateRef.current.activeSession = null;
        appStateRef.current.attachedSession = null;
        focusedSessionRef.current = null;
        setActiveSession(null);
        setAttachedSession(null);
        terminalRef.current?.clear();
        clearTerminalSearch();
        recoveryAnchorRef.current = null;
        reanchorRequiredRef.current = false;
        snapshotPendingRef.current = false;
      }
      break;
    case "exited":
      if (appStateRef.current.attachedSession === message.session) {
        appStateRef.current.activeSession = null;
        appStateRef.current.attachedSession = null;
        focusedSessionRef.current = null;
        setActiveSession(null);
        setAttachedSession(null);
        clearTerminalSearch();
        snapshotPendingRef.current = false;
        setEmptyOverride({ loading: false, message: "Session ended" });
      }
      break;
    case "error":
      {
        const detail = connectionErrorDetail(message);
        setConnectionStatus({ message: detail, online: false });
        setEmptyOverride({ loading: false, message: detail });
        // An authorization failure is terminal for this URL/token. Retrying
        // the same fragment forever only produces an Authenticating/
        // Reconnecting loop and hides the actionable failure from the user.
        if (detail === "unauthorized") connectionRef.current?.stop();
      }
      break;
    case "maintenance":
      scheduleMaintenanceTimeout();
      setConnectionStatus({ message: message.message || "Updating Warren…", online: false });
      break;
    default:
      break;
    }
  }, [
    acceptRoster,
    attachSession,
    clearMaintenanceTimeout,
    clearTerminalSearch,
    fitTerminal,
    markAttachReady,
    requestSessionFocus,
    scheduleMaintenanceTimeout,
  ]);

  const acceptConnectionState = useCallback(state => {
    clearMaintenanceTimeout();
    if (state === "connecting") {
      settingsLoadedRef.current = false;
      setConnectionStatus({ message: "Connecting…", online: false });
      return;
    }
    if (state === "open") {
      setConnectionStatus({ message: "Authenticating…", online: false });
      return;
    }
    rejectPendingRequests(pendingRequestsRef.current, "Connection lost; reconnect and retry.");
    gitNeedsReloadRef.current = true;
    if (fileViewRef.current) fileDiffNeedsReloadRef.current = true;
    creatingSessionWorkspaceIDsRef.current.clear();
    appStateRef.current.attachedSession = null;
    focusedSessionRef.current = null;
    setAttachedSession(null);
    sentTerminalSizeRef.current = null;
    batcherRef.current?.reset();
    // The Recovery Anchor survives a transport reconnect; only an explicit
    // reanchor decision (overflow, host adoption, evicted ring) clears it.
    setConnectionStatus({ message: "Reconnecting…", online: false });
  }, [clearMaintenanceTimeout]);

  messageHandlerRef.current = acceptMessage;
  connectionStateHandlerRef.current = acceptConnectionState;

  useEffect(() => clearMaintenanceTimeout, [clearMaintenanceTimeout]);

  useEffect(() => {
    const terminalHost = terminalHostRef.current;
    if (!terminalHost) return undefined;

    const terminal = new Terminal({
      theme: terminalTheme,
      fontFamily,
      fontSize,
      lineHeight: 1.12,
      cursorBlink: true,
      scrollback: 20000,
      allowTransparency: false,
      allowProposedApi: true,
    });
    const fitAddon = new FitAddon();
    terminal.loadAddon(fitAddon);
    terminal.loadAddon(new Unicode11Addon());
    terminal.unicode.activeVersion = "11";
    terminal.open(terminalHost);
    terminalRef.current = terminal;
    fitAddonRef.current = fitAddon;
    const stopTouchScroll = enableTerminalTouchScroll(terminal, terminalHost);
    const textarea = terminal.textarea;
    if (textarea) {
      // Hint mobile keyboards toward the English layout by default; the user
      // can still switch IMEs when they actually need CJK input.
      textarea.lang = "en-US";
      textarea.setAttribute("autocorrect", "off");
      textarea.setAttribute("autocapitalize", "off");
      textarea.setAttribute("spellcheck", "false");
      textarea.setAttribute("autocomplete", "off");
    }
    // Mobile GPUs churn through WebGL contexts while the keyboard resizes
    // the terminal, which reads as flicker. The DOM renderer is steadier on
    // touch devices; desktop keeps WebGL for large outputs.
    if (!isCoarsePointer()) {
      try {
        const webglAddon = new WebglAddon();
        terminal.loadAddon(webglAddon);
        webglAddon.onContextLoss(() => {
          // Desktop GPUs can still drop the context under memory pressure.
          // Dispose and let xterm fall back to its DOM renderer.
          webglAddonRef.current?.dispose();
          webglAddonRef.current = null;
        });
        webglAddonRef.current = webglAddon;
      } catch {
        // WebGL is optional; older browsers and some embedded webviews keep
        // the DOM renderer.
      }
    }
    const searchAddon = new SearchAddon({ highlightLimit: 2000 });
    terminal.loadAddon(searchAddon);
    searchAddonRef.current = searchAddon;
    const searchResultsSubscription = searchAddon.onDidChangeResults(({ resultIndex, resultCount }) => {
      setTerminalSearchIndex(resultIndex);
      setTerminalSearchCount(resultCount);
    });
    let overflowWhileHidden = false;
    const resyncTerminal = () => {
      // Keep the transport alive: re-attach in place and let the daemon
      // replay from the pending anchor (or a fresh snapshot). Dropping the
      // WebSocket here flashes "Connecting…" and re-auths on every output
      // burst while the user scrolls history.
      const sessionID = appStateRef.current.activeSession;
      const start = pendingStartAnchorRef.current;
      pendingStartAnchorRef.current = null;
      recoveryAnchorRef.current = start || null;
      reanchorRequiredRef.current = !start;
      batcher.reset();
      terminal.reset();
      if (!sessionID) return;
      appStateRef.current.attachedSession = null;
      focusedSessionRef.current = null;
      setAttachedSession(null);
      const message = attachTerminalMessage(sessionID, terminal, recoveryAnchorRef.current);
      if (!request(message.method, message.params, () => markAttachReady(sessionID))) {
        // The socket is gone after all; fall back to a full reconnect.
        connectionRef.current?.reset();
      }
    };
    const batcher = new OutputBatcher({
      write: bytes => {
        const buffer = terminal.buffer.active;
        const followsOutput = buffer.viewportY === buffer.baseY;
        terminal.write(bytes);
        // Keep a terminal that is already pinned to the bottom glued to new
        // output; a user who scrolled up keeps their place.
        if (followsOutput) terminal.scrollToBottom();
      },
      // Match the daemon's output ring retention so a dropped batch can
      // always be replayed from its anchor instead of forcing a reanchor.
      maxPending: 8 * 1024 * 1024,
      onOverflow: () => {
        // A hidden tab has no rAF ticks to drain the batcher. Reconnecting
        // there just re-serves the retained tail and overflows again, which
        // reads as a "Connecting…" loop; reset once when the tab is visible.
        if (document.hidden) {
          overflowWhileHidden = true;
          return;
        }
        resyncTerminal();
      },
    });
    batcherRef.current = batcher;
    // Scrolling through history is WebGL's worst case: the renderer rebuilds
    // texture buffers for every row, which can starve the output batcher's
    // animation frames and trigger the overflow resync above. Fall back to
    // the DOM renderer while the user is up in history, then restore WebGL
    // shortly after they return to the live output.
    let webglScrollTimer = null;
    let webglDegraded = false;
    const degradeWebGLForScroll = () => {
      if (webglDegraded || isCoarsePointer()) return;
      const addon = webglAddonRef.current;
      if (!addon) return;
      webglDegraded = true;
      webglAddonRef.current = null;
      addon.dispose();
    };
    const restoreWebGL = () => {
      if (!webglDegraded || isCoarsePointer()) return;
      webglDegraded = false;
      try {
        const addon = new WebglAddon();
        terminal.loadAddon(addon);
        addon.onContextLoss(() => {
          webglAddonRef.current?.dispose();
          webglAddonRef.current = null;
        });
        webglAddonRef.current = addon;
      } catch {
        // The context could not be rebuilt; stay on the DOM renderer.
      }
    };
    const scheduleWebGLForScroll = () => {
      clearTimeout(webglScrollTimer);
      const inHistory = terminal.buffer.active.viewportY < terminal.buffer.active.baseY;
      webglScrollTimer = setTimeout(
        inHistory ? degradeWebGLForScroll : restoreWebGL,
        inHistory ? 250 : 1200
      );
    };
    const scrollSubscription = terminal.onScroll(scheduleWebGLForScroll);
    // xterm opens at its fallback 80x24 grid. Fit once synchronously and once
    // on the next frame so the first focus claim carries the real viewport,
    // even when fonts/layout settle after the DOM mount.
    fitTerminalToHost(fitAddon, terminalHost);
    requestAnimationFrame(() => {
      if (terminalRef.current === terminal) fitTerminalToHost(fitAddon, terminalHost);
    });
    waitForTerminalFont({ fontFamily, fontSize }).then(() => {
      if (terminalRef.current === terminal) scheduleTerminalFit();
    });

    // Mobile soft keyboards and CJK IMEs can fire xterm onData twice for the
    // same keystroke (compositionend plus the following input event). Track
    // composition state and drop exact duplicates inside a short window.
    const isTouch = isCoarsePointer();
    const deduper = new MobileInputDeduper({ isTouch });
    const onCompositionStart = () => {
      deduper.onCompositionStart();
    };
    const onCompositionEnd = () => {
      deduper.onCompositionEnd();
    };
    textarea?.addEventListener("compositionstart", onCompositionStart);
    textarea?.addEventListener("compositionend", onCompositionEnd);
    const sendDeduped = data => {
      if (!data) return;
      if (deduper.shouldSend(data)) sendInput(data);
    };
    const dataSubscription = terminal.onData(sendDeduped);
    const onTextareaInput = event => {
      // Mobile Chinese keyboards can commit full-width punctuation as an
      // `insertCompositionText`/`insertText` input event that xterm ignores
      // (it only forwards keydown and plain insertText). Forward the final
      // committed data ourselves; the deduper absorbs any xterm echo.
      if (deduper.isComposing || !event.data) return;
      const inputType = event.inputType || "";
      // Keep paste/drop/autofill on xterm's own handler so bracketed paste
      // and quoting semantics stay intact.
      if (inputType === "insertFromPaste"
        || inputType === "insertFromDrop"
        || inputType === "insertFromYank"
        || inputType === "insertReplacementText"
        || inputType.startsWith("history")
        || inputType.startsWith("delete")) {
        return;
      }
      sendDeduped(event.data);
    };
    textarea?.addEventListener("input", onTextareaInput);
    const resizeSubscription = terminal.onResize(scheduleRemoteResize);
    const onTerminalFocus = () => requestSessionFocus(true);
    const onTerminalBlur = () => {
      // Touch devices keep the protocol focus after the keyboard closes so
      // later layout changes (rotation, keyboard collapse) still reflow the
      // shell while the user is just viewing.
      if (!isCoarsePointer()) requestSessionFocus(false);
    };
    const copySelectionOnMouseUp = event => {
      // Ghostty on macOS copies a completed selection to the clipboard; mirror
      // that behavior for web mouse users. Touch selection is left to the
      // platform because automatic copying is fragile on mobile.
      if (event.pointerType !== "mouse" || !terminal.hasSelection()) return;
      const text = terminal.getSelection();
      if (text && navigator.clipboard?.writeText) {
        navigator.clipboard.writeText(text).catch(() => {});
      }
    };
    terminal.element?.addEventListener("mouseup", copySelectionOnMouseUp);
    terminal.textarea?.addEventListener("focus", onTerminalFocus);
    terminal.textarea?.addEventListener("blur", onTerminalBlur);
    const releaseWindowFocus = () => {
      if (!isCoarsePointer()) requestSessionFocus(false);
    };
    const claimTerminalFocus = () => {
      // A plain window refocus (no tab visibility change) should not steal
      // the shared PTY while search/settings keeps DOM focus. Only reclaim
      // when the terminal itself still owns DOM focus.
      if (!isCoarsePointer()
        && terminal.element?.contains(document.activeElement)) {
        requestSessionFocus(true);
      }
    };
    const claimAfterVisibility = () => {
      // Another endpoint (usually a phone) can claim the shared PTY while
      // this tab was hidden. Reclaim protocol focus with the current
      // viewport size on return so the shell is not stuck at the other
      // endpoint's geometry. DOM focus is intentionally left alone so an
      // open search/settings input keeps its keyboard focus. Touch devices
      // also reclaim here because they deliberately keep protocol focus
      // while viewing but must re-assert it after a background handoff.
      if (document.hasFocus()) requestSessionFocus(true);
    };
    let wasHidden = false;
    const handleVisibilityChange = () => {
      if (document.hidden) {
        wasHidden = true;
        releaseWindowFocus();
      } else if (wasHidden) {
        wasHidden = false;
        claimAfterVisibility();
      }
    };
    window.addEventListener("blur", releaseWindowFocus);
    window.addEventListener("focus", claimTerminalFocus);
    document.addEventListener("visibilitychange", handleVisibilityChange);
    const resizeObserver = new ResizeObserver(() => scheduleTerminalFit());
    resizeObserver.observe(terminalHost);
    const onVisibilityChange = () => {
      if (document.hidden) return;
      batcherRef.current?.wake();
      if (overflowWhileHidden) {
        overflowWhileHidden = false;
        resyncTerminal();
      }
    };
    document.addEventListener("visibilitychange", onVisibilityChange);

    return () => {
      dataSubscription.dispose();
      resizeSubscription.dispose();
      searchResultsSubscription.dispose();
      terminal.element?.removeEventListener("mouseup", copySelectionOnMouseUp);
      textarea?.removeEventListener("compositionstart", onCompositionStart);
      textarea?.removeEventListener("compositionend", onCompositionEnd);
      textarea?.removeEventListener("input", onTextareaInput);
      terminal.textarea?.removeEventListener("focus", onTerminalFocus);
      terminal.textarea?.removeEventListener("blur", onTerminalBlur);
      window.removeEventListener("blur", releaseWindowFocus);
      window.removeEventListener("focus", claimTerminalFocus);
      document.removeEventListener("visibilitychange", handleVisibilityChange);
      resizeObserver.disconnect();
      document.removeEventListener("visibilitychange", onVisibilityChange);
      clearTimeout(webglScrollTimer);
      scrollSubscription.dispose();
      stopTouchScroll();
      if (fitTimerRef.current !== null) {
        clearTimeout(fitTimerRef.current);
        fitTimerRef.current = null;
      }
      webglAddonRef.current?.dispose();
      webglAddonRef.current = null;
      searchAddon.dispose();
      searchAddonRef.current = null;
      terminal.dispose();
      terminalRef.current = null;
      fitAddonRef.current = null;
      batcher.dispose();
      batcherRef.current = null;
    };
  }, [markAttachReady, request, requestSessionFocus, scheduleRemoteResize, scheduleTerminalFit, sendInput]);

  useEffect(() => {
    const terminal = terminalRef.current;
    if (!terminal) return;
    terminal.options.fontFamily = fontFamily;
    terminal.options.fontSize = fontSize;
    scheduleTerminalFit();
    waitForTerminalFont({ fontFamily, fontSize }).then(() => {
      if (terminalRef.current === terminal) scheduleTerminalFit();
    });
  }, [fontFamily, fontSize, scheduleTerminalFit]);

  useEffect(() => {
    if (activeWorkspace !== selectedWorkspaceID) setActiveWorkspace(selectedWorkspaceID);
  }, [activeWorkspace, selectedWorkspaceID]);

  useEffect(() => {
    if (!selectedWorkspace || projectDragRef.current) return;
    setExpandedProjects(previous => previous.has(selectedWorkspace.project)
      ? previous
      : new Set([...previous, selectedWorkspace.project]));
  }, [selectedWorkspace]);

  useEffect(() => {
    localStorage.setItem(storageKeys.activeWorkspace, selectedWorkspaceID || "");
  }, [selectedWorkspaceID]);

  useEffect(() => {
    localStorage.setItem(storageKeys.activeSession, activeSession || "");
  }, [activeSession]);

  useEffect(() => {
    const wasOpen = previousGitOpenRef.current;
    previousGitOpenRef.current = gitOpen;
    const opened = gitOpen && !wasOpen;
    if (opened && selectedWorkspaceID) {
      restoreGitUIForWorkspace(selectedWorkspaceID);
    } else if (!gitOpen && wasOpen && selectedWorkspaceID) {
      persistCurrentGitUI(selectedWorkspaceID);
    }
  }, [gitOpen, persistCurrentGitUI, restoreGitUIForWorkspace, selectedWorkspaceID]);

  const navigationInitializedRef = useRef(false);
  const navigationApplyKeyRef = useRef(null);
  const navigationApplyFailedRef = useRef(false);
  useEffect(() => {
    if (!navigationInitializedRef.current) {
      navigationInitializedRef.current = true;
      return;
    }
    const navigationState = uiStateFromQuery(window.location.search);
    const navigationKey = navigationLocationKey(window.location.search);
    const hasPendingResourceTarget = navigationState.projectID || navigationState.workspaceID || navigationState.sessionID;
    if (hasPendingResourceTarget && navigationApplyKeyRef.current !== navigationKey) return;
    if (navigationApplyFailedRef.current && navigationApplyKeyRef.current === navigationKey) return;
    if (!selectedWorkspaceID) return;
    const targetState = {
      projectID: selectedWorkspace?.project || null,
      workspaceID: selectedWorkspaceID,
      sessionID: activeSession,
      fileView: gitOpen && fileViewRef.current ? gitPanelUIFileView(fileViewRef.current) : null,
      viewTab: fileDiffViewRef.current.viewTab,
      diffStyle: fileDiffViewRef.current.diffStyle,
    };
    const targetSearch = replaceNavigationQuery(window.location.search, targetState);
    if (window.location.search !== targetSearch) {
      window.history.pushState(
        null,
        "",
        `${window.location.pathname}${targetSearch}${window.location.hash}`,
      );
      navigationApplyKeyRef.current = targetSearch;
      navigationApplyFailedRef.current = false;
    }
  }, [activeSession, fileDiffStyle, fileDiffViewTab, fileView, gitOpen, selectedWorkspace?.project, selectedWorkspaceID]);

  const applyNavigationStateRef = useRef(null);
  applyNavigationStateRef.current = () => {
    const currentSearch = window.location.search;
    const currentKey = navigationLocationKey(currentSearch);
    if (navigationApplyKeyRef.current === currentKey) return;
    const navigationState = uiStateFromQuery(currentSearch);
    const hasResourceTarget = navigationState.projectID || navigationState.workspaceID || navigationState.sessionID;
    if (hasResourceTarget && !connectionStatus.online) return;
    const target = resolveNavigationTarget(catalog, navigationState);
    if (target.error) {
      setEmptyOverride({ loading: false, message: target.error });
      navigationApplyKeyRef.current = currentKey;
      navigationApplyFailedRef.current = true;
      return;
    }
    navigationApplyKeyRef.current = currentKey;
    navigationApplyFailedRef.current = false;
    if (!target.workspaceID) {
      setCurrentFileView(null);
      setFileDiffView(navigationState);
      return;
    }
    chooseWorkspace(target.workspaceID, target.sessionID || null, false);
    if (navigationState.fileView) {
      setGitOpenState(true);
      openFileView(navigationState.fileView, navigationState.fileView.commit || "", target.workspaceID);
    } else {
      setCurrentFileView(null);
    }
    setFileDiffView(navigationState);
  };

  useEffect(() => {
    const listener = () => applyNavigationStateRef.current?.();
    window.addEventListener("popstate", listener);
    listener();
    return () => {
      window.removeEventListener("popstate", listener);
    };
  }, []);

  useEffect(() => {
    applyNavigationStateRef.current?.();
  }, [catalog, connectionStatus.online]);

  useEffect(() => {
    localStorage.setItem(storageKeys.navigationMemory, JSON.stringify(navigationMemory));
  }, [navigationMemory]);

  useEffect(() => {
    localStorage.setItem(storageKeys.expandedProjects, JSON.stringify([...expandedProjects]));
  }, [expandedProjects]);

  useEffect(() => {
    localStorage.setItem(storageKeys.fontFamily, fontFamily);
    localStorage.setItem(storageKeys.fontSize, String(fontSize));
  }, [fontFamily, fontSize]);

  useEffect(() => {
    localStorage.setItem(storageKeys.titleTemplate, titleTemplate);
  }, [titleTemplate]);

  useEffect(() => {
    const connection = new WarrenConnection({
      url: webSocketURL(),
      token: runtime.token,
      onMessage: event => messageHandlerRef.current(event),
      onState: state => connectionStateHandlerRef.current(state),
    });
    connectionRef.current = connection;
    connection.start();
    return () => {
      connection.stop();
      connectionRef.current = null;
    };
  }, []);

  useEffect(() => {
    const reconnect = () => connectionRef.current?.reconnectNow();
    window.addEventListener("online", reconnect);
    return () => window.removeEventListener("online", reconnect);
  }, []);

  useEffect(() => {
    if ("serviceWorker" in navigator && location.protocol !== "file:") {
      navigator.serviceWorker.register(serviceWorkerURL()).catch(() => {});
    }
  }, []);

  const toggleProject = useCallback(projectID => {
    setExpandedProjects(previous => {
      const next = new Set(previous);
      if (next.has(projectID)) next.delete(projectID);
      else next.add(projectID);
      return next;
    });
  }, []);

  const closeContextMenu = useCallback(() => setContextMenu(null), []);

  const showContextMenu = useCallback((event, items) => {
    event.preventDefault();
    setContextMenu({ x: event.clientX, y: event.clientY, items });
  }, []);

  const renameProject = useCallback(project => {
    setRenameDialog({
      kind: "project",
      id: project.id,
      title: "Rename project",
      message: "Choose a new name for this project.",
      fieldLabel: "Project name",
      initialValue: project.name || "",
      confirmLabel: "Rename",
    });
  }, []);

  const renameWorkspace = useCallback(workspace => {
    setRenameDialog({
      kind: "workspace",
      id: workspace.id,
      title: "Rename workspace",
      message: "Choose a new name for this workspace.",
      fieldLabel: "Workspace name",
      initialValue: workspace.name || "",
      confirmLabel: "Rename",
    });
  }, []);

  const renameSession = useCallback(session => {
    setRenameDialog({
      kind: "session",
      id: session.id,
      title: "Rename session",
      message: "Choose a new title for this session.",
      fieldLabel: "Session title",
      initialValue: sessionDisplayTitle(session),
      confirmLabel: "Rename",
    });
  }, []);

  const confirmRename = useCallback(value => {
    const dialog = renameDialog;
    if (!dialog) return;
    const trimmed = value.trim();
    if (!trimmed) return;
    if (dialog.kind === "project") {
      request("project.rename", { id: dialog.id, name: trimmed });
    } else if (dialog.kind === "workspace") {
      request("workspace.rename", { id: dialog.id, name: trimmed });
    } else if (dialog.kind === "session") {
      request("session.rename", { id: dialog.id, title: trimmed });
    }
    setRenameDialog(null);
  }, [renameDialog, request]);

  const toggleProjectPin = useCallback(project => {
    request("project.pin", { id: project.id, pinned: !project.pinned });
  }, [request]);

  const toggleProjectAutoImport = useCallback(project => {
    request("project.autoImportGitWorktrees", {
      project: project.id,
      enabled: !project.autoImportGitWorktrees,
    });
  }, [request]);

  const openWorktreeImport = useCallback(project => {
    setWorktreeImportDialog({
      project,
      candidates: [],
      selectedPaths: [],
      loading: true,
      error: "",
    });
    const sent = request("project.worktrees", { project: project.id }, result => {
      const candidates = Array.isArray(result) ? result : [];
      setWorktreeImportDialog(current => current?.project.id === project.id
        ? { ...current, candidates, loading: false, error: "" }
        : current);
    }, detail => {
      setWorktreeImportDialog(current => current?.project.id === project.id
        ? { ...current, loading: false, error: detail || "Unable to read Git worktrees." }
        : current);
    });
    if (!sent) {
      setWorktreeImportDialog(current => current?.project.id === project.id
        ? { ...current, loading: false, error: "The daemon is not connected. Reconnect and try again." }
        : current);
    }
  }, [request]);

  const toggleWorktreeCandidate = useCallback(path => {
    setWorktreeImportDialog(current => {
      if (!current) return current;
      const candidate = current.candidates.find(value => value.path === path);
      if (!candidate || candidate.imported) return current;
      const selected = new Set(current.selectedPaths);
      if (selected.has(path)) selected.delete(path);
      else selected.add(path);
      return { ...current, selectedPaths: [...selected] };
    });
  }, []);

  const importSelectedWorktrees = useCallback(() => {
    const current = worktreeImportDialog;
    if (!current || !current.selectedPaths.length) return;
    setWorktreeImportDialog(previous => previous ? { ...previous, loading: true, error: "" } : previous);
    const sent = request("project.worktrees.import", {
      project: current.project.id,
      paths: current.selectedPaths,
    }, () => {
      setWorktreeImportDialog(null);
    }, detail => {
      setWorktreeImportDialog(previous => previous
        ? { ...previous, loading: false, error: detail || "Unable to import selected worktrees." }
        : previous);
    });
    if (!sent) {
      setWorktreeImportDialog(previous => previous
        ? { ...previous, loading: false, error: "The daemon is not connected. Reconnect and try again." }
        : previous);
    }
  }, [request, worktreeImportDialog]);

  const toggleWorkspacePin = useCallback(workspace => {
    request("workspace.pin", { id: workspace.id, pinned: !workspace.pinned });
  }, [request]);

  const toggleSessionPin = useCallback(session => {
    request("session.pin", { id: session.id, pinned: !session.pinned });
  }, [request]);

  const projectContextMenu = useCallback((event, project) => {
    showContextMenu(event, projectMenuItems(project, {
      togglePin: toggleProjectPin,
      rename: renameProject,
      openImport: openWorktreeImport,
      toggleAutoImport: toggleProjectAutoImport,
    }));
  }, [openWorktreeImport, renameProject, showContextMenu, toggleProjectAutoImport, toggleProjectPin]);

  const workspaceContextMenu = useCallback((event, workspace) => {
    showContextMenu(event, workspaceMenuItems(workspace, {
      togglePin: toggleWorkspacePin,
      rename: renameWorkspace,
    }));
  }, [renameWorkspace, showContextMenu, toggleWorkspacePin]);

  const deleteSession = useCallback(session => {
    const label = sessionDisplayTitle(session) || session.id;
    setDeleteDialog({
      id: session.id,
      title: "Delete session?",
      message: `“${label}” will be terminated and removed from Warren.`,
      confirmLabel: "Delete",
    });
  }, []);

  const confirmDeleteSession = useCallback(() => {
    const dialog = deleteDialog;
    if (!dialog) return;
    setDeleteDialog(null);
    request("session.delete", { id: dialog.id }, () => {
      // If the deleted session owns the visible terminal, clear it right away
      // instead of waiting for the next roster broadcast. The empty-state
      // overlay is opaque, but the xterm surface behind it must not keep the
      // last agent screen.
      const current = appStateRef.current;
      if (current.activeSession === dialog.id || current.attachedSession === dialog.id) {
        terminalRef.current?.clear();
        recoveryAnchorRef.current = null;
        reanchorRequiredRef.current = false;
      }
    });
  }, [deleteDialog, request]);

  const sessionContextMenu = useCallback((event, session) => {
    showContextMenu(event, sessionMenuItems(session, {
      togglePin: toggleSessionPin,
      rename: renameSession,
      delete: deleteSession,
    }));
  }, [deleteSession, renameSession, showContextMenu, toggleSessionPin]);

  const openSessionMenu = useCallback(() => {
    const state = appStateRef.current;
    const session = state.activeSession ? state.catalog?.sessions.get(state.activeSession) : null;
    if (!session) return;
    // Mobile has no right-click; anchor the session menu near the thumb at
    // the bottom of the screen so it reads as a native action sheet.
    const event = new MouseEvent("contextmenu", {
      clientX: window.innerWidth - 16,
      clientY: window.innerHeight - 96,
      bubbles: true,
      cancelable: true,
    });
    sessionContextMenu(event, session);
  }, [sessionContextMenu]);

  const beginProjectDrag = useCallback(previousExpanded => {
    projectDragRef.current = { previousExpanded };
    setExpandedProjects(new Set());
  }, []);

  const endProjectDrag = useCallback(() => {
    const previous = projectDragRef.current?.previousExpanded;
    projectDragRef.current = null;
    if (previous) setExpandedProjects(previous);
  }, []);

  const moveProject = useCallback((projectID, beforeProjectID) => {
    request("project.move", {
      id: projectID,
      ...(beforeProjectID ? { before: beforeProjectID } : {}),
    });
    setCatalog(current => moveInCatalog(current, "projects", projectID, beforeProjectID));
  }, [request]);

  const moveWorkspace = useCallback((workspaceID, beforeWorkspaceID) => {
    request("workspace.move", {
      id: workspaceID,
      ...(beforeWorkspaceID ? { before: beforeWorkspaceID } : {}),
    });
    setCatalog(current => moveInCatalog(current, "workspaces", workspaceID, beforeWorkspaceID));
  }, [request]);

  const openSettings = useCallback(() => {
    navigationBeforeSettingsRef.current = captureNavigationPosition(appStateRef.current);
    setSearchOpen(false);
    clearTerminalSearch();
    setSettingsOpen(true);
  }, [clearTerminalSearch]);

  const closeSettings = useCallback(() => {
    const previousPosition = navigationBeforeSettingsRef.current;
    navigationBeforeSettingsRef.current = null;
    const restoredPosition = restoreNavigationPosition(previousPosition, appStateRef.current.catalog);
    const state = appStateRef.current;
    const sessionWasInvalidated = Boolean(previousPosition?.sessionID && !restoredPosition?.sessionID);
    if (restoredPosition && (
      restoredPosition.workspaceID !== state.activeWorkspace
      || restoredPosition.sessionID !== state.activeSession
      || state.attachedSession !== restoredPosition.sessionID
      || sessionWasInvalidated
    )) {
      chooseWorkspace(restoredPosition.workspaceID, restoredPosition.sessionID, false);
    }
    setSettingsOpen(false);
    returnFocusToTerminal();
  }, [chooseWorkspace, returnFocusToTerminal]);

  const closeSearch = useCallback(() => {
    setSearchOpen(false);
    returnFocusToTerminal();
  }, [returnFocusToTerminal]);

  useEffect(() => {
    const handleKeyDown = event => {
      const modifier = event.metaKey || event.ctrlKey;
      if (renameDialog || deleteDialog) return;
      if (event.key === "Escape" && terminalSearchOpen) {
        closeTerminalSearch();
        return;
      }
      if (event.key === "Escape" && drawerOpen) {
        setDrawerOpen(false);
        return;
      }
      if (event.key === "Escape" && searchOpen) {
        closeSearch();
        return;
      }
      if (event.key === "Escape" && settingsOpen) {
        closeSettings();
        return;
      }
      if (settingsOpen || searchOpen || !modifier) return;
      if (event.key.toLowerCase() === "k") {
        event.preventDefault();
        setSearchOpen(true);
      } else if (event.key.toLowerCase() === "f") {
        event.preventDefault();
        openTerminalSearch();
      } else if (event.key === ",") {
        event.preventDefault();
        openSettings();
      }
    };
    document.addEventListener("keydown", handleKeyDown);
    return () => document.removeEventListener("keydown", handleKeyDown);
  }, [searchOpen, settingsOpen, drawerOpen, terminalSearchOpen, renameDialog, deleteDialog, openSettings, closeSearch, closeSettings, closeTerminalSearch, openTerminalSearch]);

  const chooseSearchWorkspace = useCallback(workspaceID => {
    closeSearch();
    chooseWorkspace(workspaceID);
  }, [chooseWorkspace, closeSearch]);

  const chooseSearchProject = useCallback(projectID => {
    const workspaceID = resolveProjectWorkspace(
      catalog,
      projectID,
      appStateRef.current.navigationMemory,
    );
    if (workspaceID) chooseSearchWorkspace(workspaceID);
  }, [catalog, chooseSearchWorkspace]);

  const updateFontFamily = useCallback(value => {
    setFontFamily(value.trim() || defaultFontFamily);
  }, []);

  const updateFontSize = useCallback(value => {
    setFontSize(clamp(Number(value) || defaultFontSize, 8, 32));
  }, []);

  const updateTitleTemplate = useCallback(value => {
    setTitleTemplate(value.trim() || defaultTitleTemplate);
  }, []);

  const updateAutoOpenShell = useCallback(enabled => {
    const previous = autoOpenShell;
    setAutoOpenShell(enabled);
    if (!request("settings.put", { autoOpenShell: enabled }, applyRemoteSettings, () => {
      setAutoOpenShell(previous);
    })) {
      setAutoOpenShell(previous);
    }
  }, [applyRemoteSettings, autoOpenShell, request]);

  const updateAutoStartAI = useCallback(enabled => {
    const previous = autoStartAI;
    setAutoStartAI(enabled);
    if (!request("settings.put", { autoStartAI: enabled }, applyRemoteSettings, () => {
      setAutoStartAI(previous);
    })) {
      setAutoStartAI(previous);
    }
  }, [applyRemoteSettings, autoStartAI, request]);

  const appendPlaceholder = useCallback(placeholder => {
    setTitleTemplate(previous => `${previous}${previous && !previous.endsWith(" ") ? " " : ""}${placeholder}`);
  }, []);

  const restoreDefaults = useCallback(() => {
    setTitleTemplate(defaultTitleTemplate);
    setFontFamily(defaultFontFamily);
    setFontSize(defaultFontSize);
    setPresetCommands({ ...defaultPresetCommands });
    setPresetOrder([...defaultSessionPresetOrder]);
    setHiddenPresets([...defaultHiddenSessionPresetKinds]);
    localStorage.removeItem(storageKeys.presetCommands);
    localStorage.removeItem(storageKeys.presetOrder);
    localStorage.removeItem(storageKeys.hiddenPresets);
  }, []);

  const selectedAgentEvents = selectedSession
    ? agentStateBySession[selectedSession.id]?.events || []
    : [];
  const agentModel = useMemo(() => {
    for (let index = selectedAgentEvents.length - 1; index >= 0; index--) {
      if (selectedAgentEvents[index].model) return selectedAgentEvents[index].model;
    }
    return "";
  }, [selectedAgentEvents]);
  const isAgentSession = isSupportedAgentSession(selectedSession);
  // An integrated Codex/Claude session is only safe to message once its CLI
  // has actually started. Before the binding/transcript exists, the TUI may
  // still be on a first-run trust or resume prompt, where typed text is dropped
  // and Enter is treated as a confirmation key instead of a submit.
  const agentViewReady = Boolean(
    selectedSession?.agentSessionId || selectedAgentEvents.length > 0,
  );
  const agentViewActive = Boolean(
    isAgentSession
      && (agentViewOverride === "agent" || agentViewReady)
      && agentViewOverride !== "terminal",
  );

  // Load the first history page when an agent view becomes active. Live
  // batches arrive through the WebSocket, but the full conversation is
  // fetched page by page so a huge transcript never arrives as one message.
  useEffect(() => {
    if (!agentViewActive || !selectedSession) return;
    const state = agentStateBySession[selectedSession.id];
    if (!state?.historyLoaded && !state?.historyLoading) {
      loadAgentHistory(selectedSession.id);
    }
  }, [agentViewActive, selectedSession, agentStateBySession, loadAgentHistory]);

  return (
    <>
      <h1 className="visually-hidden">Warren</h1>
      <div className={`app${drawerOpen ? " drawer-open" : ""}${gitOpen && !isMobile ? " git-panel-open" : ""}`} hidden={settingsOpen}>
        <a className="skip-link" href="#main">Skip to content</a>
        <Sidebar
          catalog={catalog}
          activeWorkspace={selectedWorkspaceID}
          expandedProjects={expandedProjects}
          tabsForWorkspace={workspaceID => workspaceTabs(catalog, workspaceID)}
          connection={connectionStatus}
          onToggleProject={toggleProject}
          onChooseWorkspace={chooseWorkspace}
          onOpenWorkspace={openWorkspace}
          onNewSessionInWorkspace={workspaceID => openWorkspace(workspaceID, true)}
          onNewSession={() => createSession("shell")}
          onOpenSettings={openSettings}
          onProjectContextMenu={projectContextMenu}
          onWorkspaceContextMenu={workspaceContextMenu}
          onMoveProject={moveProject}
          onMoveWorkspace={moveWorkspace}
          onBeginProjectDrag={beginProjectDrag}
          onEndProjectDrag={endProjectDrag}
        />
        <button type="button" className="backdrop" aria-label="Close navigation" onClick={() => setDrawerOpen(false)} />
        <main id="main" className="main" ref={mainRef} tabIndex={-1}>
          {isMobile ? (
            <MobileShell
              workspace={selectedWorkspace}
              tabs={tabs}
              activeSession={activeSession}
              connection={connectionStatus}
              agentSession={isAgentSession ? selectedSession : null}
              agentViewActive={agentViewActive}
              agentModel={agentModel}
              onAttachSession={attachSession}
              onToggleAgentView={toggleAgentView}
              onOpenMenu={() => setDrawerOpen(true)}
              onOpenSearch={() => setSearchOpen(true)}
              onNewSession={() => setSessionSheetOpen(true)}
              onOpenSessionMenu={openSessionMenu}
              onSessionContextMenu={sessionContextMenu}
            />
          ) : (
            <>
              <TopBar
                tabs={tabs}
                activeSession={activeSession}
                workspace={selectedWorkspace}
                onAttachSession={attachSession}
                onNewSession={() => createSession("shell")}
                onOpenMenu={() => setDrawerOpen(true)}
                onOpenSearch={() => setSearchOpen(true)}
                onToggleGit={() => setGitOpenState(open => !open)}
                gitActive={gitOpen}
                onTabContextMenu={sessionContextMenu}
              />
              <PresetBar presets={visiblePresets} onCreateSession={createSession} />
              <div className="pane-title">
                <span
                  title={paneTitle}
                  aria-label={paneTitle}
                  onCopy={event => {
                    if (!paneTitle || !event.clipboardData) return;
                    event.preventDefault();
                    event.clipboardData.setData("text/plain", paneTitle);
                  }}
                >
                  {paneDisplayTitle}
                </span>
                {isAgentSession && (agentModel || selectedSession?.agentSessionId) && (
                  <span className="pane-agent-meta">
                    {agentModel && <span className="pane-agent-model">{agentModel}</span>}
                    {selectedSession?.agentSessionId && (
                      <code
                        className="pane-agent-session"
                        title={selectedSession.agentSessionId}
                      >
                        {selectedSession.agentSessionId}
                      </code>
                    )}
                  </span>
                )}
                {isAgentSession && (agentViewActive ? (
                  <button type="button" className="pane-action" onClick={() => toggleAgentView("terminal")}>
                    Terminal
                  </button>
                ) : (
                  <button type="button" className="pane-action" onClick={() => toggleAgentView("agent")}>
                    Agent
                  </button>
                ))}
              </div>
            </>
          )}
          <section
            className="terminal-shell"
            aria-label="Terminal"
            onPointerDown={event => {
              if (event.pointerType === "mouse" && !(gitOpen && fileView)) focusTerminal();
            }}
            onClick={event => {
              if (!(gitOpen && fileView)) focusTerminal();
            }}
          >
            <div id="terminal" ref={terminalHostRef} hidden={agentViewActive || (gitOpen && Boolean(fileView))} />
            {gitOpen && fileView && (
              <Suspense fallback={<p className="git-empty file-diff-empty">Loading diff viewer…</p>}>
                <FileDiffView
                  path={fileView.path}
                  staged={fileView.staged}
                  commit={fileView.commit}
                  loading={fileDiff.loading}
                  diff={fileDiff.diff}
                  content={fileDiff.content}
                  error={fileDiff.error}
                  notice={fileDiff.notice}
                  onClose={closeFileView}
                  viewTab={fileDiffViewTab}
                  diffStyle={fileDiffStyle}
                  onViewTabChange={setFileDiffViewTab}
                  onDiffStyleChange={setFileDiffStyle}
                />
              </Suspense>
            )}
            {agentViewActive && (
              <AgentView
                session={selectedSession}
                events={selectedAgentEvents}
                onSend={sendAgentInput}
                ready={agentViewReady}
                hasMore={Boolean(agentStateBySession[selectedSession.id]?.historyHasMore)}
                loadingMore={Boolean(agentStateBySession[selectedSession.id]?.historyLoading)}
                onLoadMore={() => {
                  const state = agentStateBySession[selectedSession.id];
                  loadAgentHistory(selectedSession.id, state?.historyCursor || 0);
                }}
              />
            )}
            <TerminalSearch
              open={terminalSearchOpen}
              query={terminalSearchQuery}
              resultIndex={terminalSearchIndex}
              resultCount={terminalSearchCount}
              focusNonce={terminalSearchFocusNonce}
              onQueryChange={updateTerminalSearchQuery}
              onNext={() => stepTerminalSearch("next")}
              onPrevious={() => stepTerminalSearch("previous")}
              onClose={closeTerminalSearch}
            />
            {!(gitOpen && fileView) && (
            <EmptyTerminal
              activeWorkspace={selectedWorkspaceID}
              activeSession={activeSession}
              attachedSession={attachedSession}
              tabCount={tabs.length}
              projectCount={catalog.projects.length}
              override={emptyOverride}
              onNewSession={() => createSession("shell")}
            />
            )}
          </section>
          {!agentViewActive && <MobileKeys onInput={sendInput} />}
        </main>
        {!isMobile && gitOpen && (
          <GitPanel
            key={selectedWorkspaceID}
            workspaceName={selectedWorkspace?.branch || selectedWorkspace?.name}
            panel={gitPanel}
            refreshing={gitRefreshing}
            error={gitError}
            action={gitAction}
            onRefresh={() => loadGitPanel(true)}
            onPull={() => runGitAction("git.pull", { workspace: selectedWorkspaceID })}
            onPush={() => runGitAction("git.push", { workspace: selectedWorkspaceID })}
            onCheckout={(branch, create) => runGitAction("git.checkout", { workspace: selectedWorkspaceID, branch, create })}
            onOpenFile={openFileView}
            onCommit={runGitCommit}
            onCreatePR={(title, body) => runGitAction("git.pr.create", { workspace: selectedWorkspaceID, title, body })}
            onClose={() => setGitOpenState(false)}
            saved={gitPanelSavedUI}
            onUIChange={handleGitUIChange}
          />
        )}
      </div>
      <SettingsPage
        open={settingsOpen}
        fontFamily={fontFamily}
        fontSize={fontSize}
        titleTemplate={titleTemplate}
        presetCommands={presetCommands}
        presets={orderedPresets}
        hiddenPresets={hiddenPresets}
        autoOpenShell={autoOpenShell}
        autoStartAI={autoStartAI}
        titlePreview={titlePreview}
        placeholders={Object.entries(titlePlaceholders)}
        onClose={closeSettings}
        onFontFamilyChange={updateFontFamily}
        onFontSizeChange={updateFontSize}
        onTitleTemplateChange={updateTitleTemplate}
        onPresetCommandChange={updatePresetCommand}
        onPresetVisibilityChange={updatePresetVisibility}
        onAutoOpenShellChange={updateAutoOpenShell}
        onAutoStartAIChange={updateAutoStartAI}
        onMovePreset={movePreset}
        onAppendPlaceholder={appendPlaceholder}
        onRestore={restoreDefaults}
      />
      <SearchPanel
        open={searchOpen}
        query={searchQuery}
        catalog={catalog}
        onQueryChange={setSearchQuery}
        onClose={closeSearch}
        onChooseWorkspace={chooseSearchWorkspace}
        onChooseProject={chooseSearchProject}
      />
      {isMobile && (
        <SessionSheet
          open={sessionSheetOpen}
          presets={visiblePresets}
          onChoose={chooseSessionPreset}
          onClose={() => setSessionSheetOpen(false)}
        />
      )}
      <WorktreeImportDialog
        dialog={worktreeImportDialog}
        onClose={() => setWorktreeImportDialog(null)}
        onToggle={toggleWorktreeCandidate}
        onImport={importSelectedWorktrees}
      />
      {renameDialog && (
        <TextInputDialog
          title={renameDialog.title}
          message={renameDialog.message}
          fieldLabel={renameDialog.fieldLabel}
          initialValue={renameDialog.initialValue}
          confirmLabel={renameDialog.confirmLabel}
          onCancel={() => setRenameDialog(null)}
          onConfirm={confirmRename}
        />
      )}
      {deleteDialog && (
        <ConfirmationDialog
          title={deleteDialog.title}
          message={deleteDialog.message}
          confirmLabel={deleteDialog.confirmLabel}
          onCancel={() => setDeleteDialog(null)}
          onConfirm={confirmDeleteSession}
        />
      )}
      <ContextMenu menu={contextMenu} onClose={closeContextMenu} />
    </>
  );
}

function loadSet(key) {
  try {
    return new Set(JSON.parse(localStorage.getItem(key) || "[]"));
  } catch {
    return new Set();
  }
}

function loadNavigationMemory() {
  try {
    return createNavigationMemory(
      JSON.parse(localStorage.getItem(storageKeys.navigationMemory) || "{}"),
    );
  } catch {
    return createNavigationMemory();
  }
}

function sameNavigationMemory(left, right) {
  const compare = (leftMap, rightMap) => {
    const leftKeys = Object.keys(leftMap || {});
    const rightKeys = Object.keys(rightMap || {});
    return leftKeys.length === rightKeys.length
      && leftKeys.every(key => leftMap[key] === rightMap[key]);
  };
  return compare(left?.workspaceByProjectID, right?.workspaceByProjectID)
    && compare(left?.sessionByWorkspaceID, right?.sessionByWorkspaceID);
}

function useMediaQuery(query) {
  const [matches, setMatches] = useState(() => window.matchMedia(query).matches);
  useEffect(() => {
    const media = window.matchMedia(query);
    const onChange = event => setMatches(event.matches);
    media.addEventListener("change", onChange);
    setMatches(media.matches);
    return () => media.removeEventListener("change", onChange);
  }, [query]);
  return matches;
}

function loadPresetCommands() {
  try {
    return { ...defaultPresetCommands, ...JSON.parse(localStorage.getItem(storageKeys.presetCommands) || "{}") };
  } catch {
    return { ...defaultPresetCommands };
  }
}

function loadPresetOrder() {
  return loadSessionPresetOrder(localStorage, storageKeys.presetOrder);
}

function loadHiddenPresets() {
  return loadHiddenSessionPresetKinds(localStorage, storageKeys.hiddenPresets);
}

function shortSessionID(id) {
  return id.length > 18 ? `${id.slice(0, 8)}…${id.slice(-6)}` : id;
}

function clamp(value, minimum, maximum) {
  return Math.min(maximum, Math.max(minimum, value));
}
