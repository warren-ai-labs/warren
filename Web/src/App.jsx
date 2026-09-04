import { lazy, Suspense, useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Terminal } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import { SearchAddon } from "@xterm/addon-search";
import { Unicode11Addon } from "@xterm/addon-unicode11";
import { WebglAddon } from "@xterm/addon-webgl";
import "@xterm/xterm/css/xterm.css";
import "./style.css";

import {
  applyRosterDelta,
  buildCatalog,
  moveInCatalog,
  rosterFromMessage,
  updateSessionAgentStatus,
  workspaceTabs,
} from "./catalog.js";
import {
  WarrenConnection,
  agentCapabilities,
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
import { runtime, serviceWorkerURL, tokenReady, webSocketURL } from "./runtime.js";
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
import {
  AgentMessageQueue,
  agentAttachmentReference,
  agentQueueKey,
  encodeAgentAttachmentChunk,
  mergeAgentEvents,
  removeAgentDraft,
  validateAgentAttachment,
} from "./agent.js";
import {
  saveAgentEvents,
  loadRecentAgentEvents,
  getAgentMaxSequence,
  clearAgentSession,
} from "./agent-store.js";
import { AgentView } from "./agent.jsx";
import {
  AgentCompletionEventChannel,
  AgentCompletionSound,
  AgentTurnCompletionTracker,
  loadAgentCompletionSoundEnabled,
  saveAgentCompletionSoundEnabled,
} from "./notifications.js";

function supportsSessionAgentCapability(catalog, connectionCapabilities, sessionID, capability) {
  if (!connectionCapabilities?.has(capability)) return false;
  const session = catalog?.sessions?.get?.(sessionID);
  if (!session || !Array.isArray(session.agentCapabilities)) return true;
  return session.agentCapabilities.includes(capability);
}

function sessionAgentCapabilities(catalog, connectionCapabilities, sessionID) {
  const session = catalog?.sessions?.get?.(sessionID);
  if (!session || !Array.isArray(session.agentCapabilities)) {
    return [...(connectionCapabilities || [])];
  }
  return session.agentCapabilities.filter(capability => connectionCapabilities?.has(capability));
}
const FileDiffView = lazy(() => import("./filediff.jsx").then(module => ({ default: module.FileDiffView })));
import { handleUnixTextEditingKey, InputQueue, MobileInputDeduper } from "./input.js";
import { OutputBatcher } from "./output.js";
import { decodeFrame, isBinaryEnvelope } from "./wire.js";
import { useKeyboardInset } from "./keyboard.js";
import { projectMenuItems, sessionMenuItems, taskMenuItems, workspaceMenuItems } from "./contextmenu.js";
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
  TransientFeedback,
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
  expandedTasks: "warren.expandedTasks",
  expandedProjects: "warren.expandedProjects",
  tasksCollapsed: "warren.tasksCollapsed",
  fontFamily: "warren.terminalFontFamily",
  fontSize: "warren.terminalFontSize",
  titleTemplate: "warren.terminalTitleTemplate",
  presetCommands: "warren.presetCommands",
  presetOrder: "warren.presetOrder",
  hiddenPresets: "warren.hiddenPresets",
};

// How often the open git panel re-fetches remote refs while it stays visible.
const GIT_PANEL_POLL_MS = 5 * 60_000;
// A request can outlive a healthy WebSocket when the Host is busy or has
// stopped processing control messages. Keep every UI pending state finite so
// callers receive an actionable failure instead of a permanent spinner.
const REQUEST_TIMEOUT_MS = 30_000;

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
const terminalRecoveryTimeoutMs = 15_000;
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

function clearPendingRequest(pending, id) {
  if (!id) return;
  const handler = pending.get(id);
  if (handler?.timer !== undefined && handler?.timer !== null) {
    clearTimeout(handler.timer);
  }
  pending.delete(id);
}

export default function App() {
  const [catalog, setCatalog] = useState(() => buildCatalog());
  const [activeWorkspace, setActiveWorkspace] = useState(() => localStorage.getItem(storageKeys.activeWorkspace));
  const [activeSession, setActiveSession] = useState(() => localStorage.getItem(storageKeys.activeSession));
  const [navigationMemory, setNavigationMemory] = useState(() => loadNavigationMemory());
  const [attachedSession, setAttachedSession] = useState(null);
  // Transport readiness and presentation readiness are deliberately separate.
  // The daemon acknowledges a subscription before it sends the atomic state;
  // accepting input at that point keeps PTY interaction responsive, while the
  // neutral overlay remains in place until the snapshot and its live tail have
  // rendered completely.
  const [terminalReadySession, setTerminalReadySession] = useState(null);
  const [hasNewTerminalOutput, setHasNewTerminalOutput] = useState(false);
  const [expandedTasks, setExpandedTasks] = useState(() => loadSet(storageKeys.expandedTasks));
  const [expandedProjects, setExpandedProjects] = useState(() => loadSet(storageKeys.expandedProjects));
  const [tasksCollapsed, setTasksCollapsed] = useState(() => {
    try {
      const raw = localStorage.getItem(storageKeys.tasksCollapsed);
      return raw ? JSON.parse(raw) : false;
    } catch { return false; }
  });
  const [fontFamily, setFontFamily] = useState(() => localStorage.getItem(storageKeys.fontFamily) || defaultFontFamily);
  const [fontSize, setFontSize] = useState(() => Number(localStorage.getItem(storageKeys.fontSize)) || defaultFontSize);
  const [titleTemplate, setTitleTemplate] = useState(() => localStorage.getItem(storageKeys.titleTemplate) || defaultTitleTemplate);
  const [presetCommands, setPresetCommands] = useState(() => loadPresetCommands());
  const [presetOrder, setPresetOrder] = useState(() => loadPresetOrder());
  const [hiddenPresets, setHiddenPresets] = useState(() => loadHiddenPresets());
  const [autoOpenShell, setAutoOpenShell] = useState(false);
  const [autoStartAI, setAutoStartAI] = useState(false);
  const [openaiBaseURL, setOpenaiBaseURL] = useState("");
  const [openaiModel, setOpenaiModel] = useState("");
  const [openaiTitleEnabled, setOpenaiTitleEnabled] = useState(false);
  const [agentCompletionSoundEnabled, setAgentCompletionSoundEnabled] = useState(() => (
    loadAgentCompletionSoundEnabled()
  ));
  const [connectionStatus, setConnectionStatus] = useState({ message: "Connecting…", online: false });
  const [feedback, setFeedback] = useState(null);
  const [pendingSessionID, setPendingSessionID] = useState(null);
  const [creatingSessionKind, setCreatingSessionKind] = useState(null);
  const [creatingWorkspaceIDs, setCreatingWorkspaceIDs] = useState(() => new Set());
  const [focusedSessionID, setFocusedSessionID] = useState(null);
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
  const gitLoadGenerationRef = useRef(0);
  const gitWorkspaceGenerationRef = useRef(0);
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
  const [agentQueueBySession, setAgentQueueBySession] = useState({});
  const [agentActionError, setAgentActionError] = useState("");
  const agentCapabilitiesRef = useRef(new Set());
  const agentQueueRef = useRef({});
  const agentInterruptInFlightRef = useRef(new Set());
  const [agentViewOverride, setAgentViewOverride] = useState(null);
  const [sessionSheetOpen, setSessionSheetOpen] = useState(false);
  const [worktreeImportDialog, setWorktreeImportDialog] = useState(null);
  const [renameDialog, setRenameDialog] = useState(null);
  const [deleteDialog, setDeleteDialog] = useState(null);
  const [renamePending, setRenamePending] = useState(false);
  const [deletePending, setDeletePending] = useState(false);

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
  const recoveryTimeoutRef = useRef(null);
  const subscriptionRef = useRef({
    sessionID: null,
    status: "idle",
    generation: 0,
    requestID: null,
    cancelRequestID: null,
  });
  const subscriptionCleanupRef = useRef(() => {});
  const snapshotPendingRef = useRef(false);
  const recoveryApplyingRef = useRef(false);
  const pendingAtomicStateRef = useRef(null);
  const stagedRecoveryOutputRef = useRef([]);
  const messageHandlerRef = useRef(() => {});
  const connectionStateHandlerRef = useRef(() => {});
  const maintenanceTimeoutRef = useRef(null);
  const feedbackTimerRef = useRef(null);
  const pendingSessionRef = useRef(null);
  const pendingSessionFeedbackRef = useRef(false);
  const creatingSessionKindRef = useRef(null);
  const renamePendingRef = useRef(false);
  const deletePendingRef = useRef(false);
  const renameOperationRef = useRef(null);
  const deleteOperationRef = useRef(null);
  const gitActionRef = useRef(null);
  const focusRequestGenerationRef = useRef(0);
  const agentQueueGenerationRef = useRef(0);
  const agentMessageRequestRef = useRef(new Map());
  const agentHistoryRequestRef = useRef(new Map());
  const agentHistoryRequestSequenceRef = useRef(0);
  const agentInterruptGenerationRef = useRef(0);
  const worktreeImportInFlightRef = useRef(false);
  const worktreeLoadRequestRef = useRef(null);
  const worktreeImportRequestRef = useRef(null);
  const connectionOnlineRef = useRef(false);
  const appStateRef = useRef({});
  const pendingRequestsRef = useRef(new Map());
  const rosterRef = useRef(null);
  const rosterRefreshInFlightRef = useRef(false);
  const relayRefreshInFlightRef = useRef(false);
  const fileDiffNeedsReloadRef = useRef(false);
  const creatingSessionWorkspaceIDsRef = useRef(new Set());
  const settingsLoadedRef = useRef(false);
  const inputQueueRef = useRef(null);
  const navigationBeforeSettingsRef = useRef(null);
  const autoFocusOnAttachRef = useRef(true);
  const projectDragRef = useRef(null);
  const agentTurnCompletionTrackerRef = useRef(null);
  const agentCompletionEventsRef = useRef(null);
  const agentCompletionSoundRef = useRef(null);
  const agentCompletionSoundEnabledRef = useRef(agentCompletionSoundEnabled);
  const isMobile = useMediaQuery("(max-width: 767px)");
  const orderedPresets = useMemo(() => orderedSessionPresets(presetOrder), [presetOrder]);
  const visiblePresets = useMemo(
    () => visibleSessionPresets(orderedPresets, hiddenPresets),
    [hiddenPresets, orderedPresets],
  );
  useKeyboardInset(mainRef);
  if (agentTurnCompletionTrackerRef.current === null) {
    agentTurnCompletionTrackerRef.current = new AgentTurnCompletionTracker();
  }
  if (agentCompletionEventsRef.current === null) {
    agentCompletionEventsRef.current = new AgentCompletionEventChannel();
  }
  if (agentCompletionSoundRef.current === null) {
    agentCompletionSoundRef.current = new AgentCompletionSound();
  }
  agentCompletionSoundEnabledRef.current = agentCompletionSoundEnabled;
  useEffect(() => {
    const handleKeyDown = event => {
      handleUnixTextEditingKey(event);
    };
    // Capture before component handlers so every input shares the same
    // readline vocabulary, while the xterm helper textarea opts out.
    document.addEventListener("keydown", handleKeyDown, true);
    return () => document.removeEventListener("keydown", handleKeyDown, true);
  }, []);

  useEffect(() => {
    const armSound = () => {
      void agentCompletionSoundRef.current?.arm();
    };
    window.addEventListener("pointerdown", armSound, { passive: true });
    window.addEventListener("keydown", armSound);
    return () => {
      window.removeEventListener("pointerdown", armSound);
      window.removeEventListener("keydown", armSound);
    };
  }, []);

  useEffect(() => {
    const channel = agentCompletionEventsRef.current;
    if (!channel) return undefined;
    return channel.subscribe(event => {
      if (!agentCompletionSoundEnabledRef.current) return;
      const pageIsFocused = document.visibilityState === "visible" && document.hasFocus();
      if (!pageIsFocused || appStateRef.current.activeSession !== event.sessionID) {
        void agentCompletionSoundRef.current?.play();
      }
    });
  }, []);
  if (inputQueueRef.current === null) {
    inputQueueRef.current = new InputQueue({
      limit: pendingInputLimit,
      send: data => Boolean(connectionRef.current?.sendBinary(data)),
      onSendFailure: () => connectionRef.current?.reconnectNow(),
    });
  }

  const announceFeedback = useCallback((message, kind = "success", duration = 1800) => {
    const value = String(message || "").trim();
    if (!value) return;
    if (feedbackTimerRef.current !== null) {
      clearTimeout(feedbackTimerRef.current);
      feedbackTimerRef.current = null;
    }
    setFeedback({ id: `${Date.now()}-${Math.random()}`, message: value, kind });
    if (duration > 0) {
      feedbackTimerRef.current = setTimeout(() => {
        feedbackTimerRef.current = null;
        setFeedback(null);
      }, duration);
    }
  }, []);

  const clearPendingSession = useCallback(() => {
    pendingSessionRef.current = null;
    pendingSessionFeedbackRef.current = false;
    setPendingSessionID(null);
    setFeedback(previous => previous?.kind === "pending" ? null : previous);
  }, []);

  useEffect(() => () => {
    if (feedbackTimerRef.current !== null) clearTimeout(feedbackTimerRef.current);
  }, []);

  const markWorkspaceCreation = useCallback((workspaceID, active) => {
    if (!workspaceID) return;
    setCreatingWorkspaceIDs(previous => {
      const next = new Set(previous);
      if (active) next.add(workspaceID);
      else next.delete(workspaceID);
      return next;
    });
  }, []);

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
      const timer = setTimeout(() => {
        const pending = pendingRequestsRef.current.get(id);
        if (!pending) return;
        pendingRequestsRef.current.delete(id);
        pending.onError?.(`${method} timed out; retry.`);
      }, REQUEST_TIMEOUT_MS);
      pendingRequestsRef.current.set(id, { onResult, onError, timer });
    }
    return true;
  }, []);

  const requestAgent = useCallback((method, params = {}) => new Promise((resolve, reject) => {
    const sent = request(method, params, resolve, reject);
    if (!sent) reject(new Error("Connection unavailable"));
  }), [request]);

  const uploadAgentAttachments = useCallback(async (files, onProgress = () => {}) => {
    const sessionID = appStateRef.current.activeSession;
    if (!sessionID || !supportsSessionAgentCapability(appStateRef.current.catalog, agentCapabilitiesRef.current, sessionID, "agent-attachments-v1")) {
      throw new Error("This Host does not support attachments");
    }
    const ensureCurrentSession = () => {
      if (appStateRef.current.activeSession !== sessionID) {
        throw new Error("Session changed; attachment upload canceled.");
      }
    };
    const references = [];
    for (let index = 0; index < files.length; index += 1) {
      const file = files[index];
      const validation = validateAgentAttachment(file);
      if (!validation.ok) throw new Error(validation.error);
      let uploadID = "";
      try {
        const data = await file.arrayBuffer();
        ensureCurrentSession();
        const digest = globalThis.crypto?.subtle
          ? await globalThis.crypto.subtle.digest("SHA-256", data)
          : null;
        ensureCurrentSession();
        const sha256 = digest
          ? [...new Uint8Array(digest)].map(value => value.toString(16).padStart(2, "0")).join("")
          : "";
        const prepared = await requestAgent("agent.attachment.prepare", {
          session: sessionID,
          name: file.name,
          mime: file.type,
          size: file.size,
          ...(sha256 ? { sha256 } : {}),
        });
        ensureCurrentSession();
        const attachmentID = String(prepared?.attachmentId || "").trim();
        uploadID = String(prepared?.uploadId || "").trim();
        const chunkSize = Number(prepared?.chunkSize) > 0 ? Number(prepared.chunkSize) : 256 * 1024;
        if (!attachmentID || !uploadID) throw new Error("Host returned an invalid attachment upload");
        let sentBytes = 0;
        for (let sequence = 0; sentBytes < data.byteLength || (data.byteLength === 0 && sequence === 0); sequence += 1) {
          ensureCurrentSession();
          const chunk = new Uint8Array(data, sentBytes, Math.min(chunkSize, data.byteLength - sentBytes));
          const chunkDigest = globalThis.crypto?.subtle
            ? await globalThis.crypto.subtle.digest("SHA-256", chunk)
            : null;
          const chunkSHA = chunkDigest
            ? [...new Uint8Array(chunkDigest)].map(value => value.toString(16).padStart(2, "0")).join("")
            : "";
          const chunkResult = await requestAgent("agent.attachment.chunk", {
            session: sessionID,
            uploadId: uploadID,
            sequence,
            length: chunk.byteLength,
            ...(chunkSHA ? { sha256: chunkSHA } : {}),
            data: encodeAgentAttachmentChunk(chunk),
          });
          ensureCurrentSession();
          if (!chunkResult?.accepted) {
            throw new Error(chunkResult?.error || "Host rejected an attachment chunk");
          }
          sentBytes += chunk.byteLength;
          onProgress(index, data.byteLength === 0 ? 1 : sentBytes / data.byteLength);
          if (data.byteLength === 0) break;
        }
        const completed = await requestAgent("agent.attachment.complete", {
          session: sessionID,
          uploadId: uploadID,
          length: data.byteLength,
          ...(sha256 ? { sha256 } : {}),
        });
        ensureCurrentSession();
        if (!completed?.accepted || String(completed.attachmentId || attachmentID).trim() !== attachmentID) {
          throw new Error(completed?.error || "Host rejected attachment completion");
        }
        const reference = agentAttachmentReference({ attachmentId: attachmentID }, file);
        if (!reference) throw new Error("Host returned an invalid attachment reference");
        references.push(reference);
        onProgress(index, 1, "", reference);
      } catch (error) {
        if (uploadID) {
          try { await requestAgent("agent.attachment.abort", { session: sessionID, uploadId: uploadID }); } catch { /* best effort */ }
        }
        onProgress(index, 0, String(error?.message || error || "Upload failed"));
        throw error;
      }
    }
    return references;
  }, [requestAgent]);

  const applyRemoteSettings = useCallback(result => {
    if (!result || typeof result !== "object") return;
    if (typeof result.autoOpenShell === "boolean") {
      setAutoOpenShell(result.autoOpenShell);
    }
    if (typeof result.autoStartAI === "boolean") {
      setAutoStartAI(result.autoStartAI);
    }
    if (typeof result.openaiBaseURL === "string") setOpenaiBaseURL(result.openaiBaseURL);
    if (typeof result.openaiModel === "string") setOpenaiModel(result.openaiModel);
    if (typeof result.openaiTitleEnabled === "boolean") setOpenaiTitleEnabled(result.openaiTitleEnabled);
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
    const generation = ++gitLoadGenerationRef.current;
    gitLoadingRef.current = workspaceID;
    setGitRefreshing(true);
    setGitError("");
    // A background refresh must not erase the pending label for an explicit
    // Git mutation. The action ref is the duplicate-submission guard and is
    // intentionally authoritative while the request is in flight.
    if (!gitActionRef.current) setGitAction("");
    const finish = () => {
      if (gitLoadingRef.current === workspaceID && gitLoadGenerationRef.current === generation) {
        gitLoadingRef.current = null;
        setGitRefreshing(false);
      }
    };
    const sent = request("git.panel", { workspace: workspaceID, fetch: true, force }, result => {
      if (appStateRef.current.activeWorkspace !== workspaceID
        || gitLoadGenerationRef.current !== generation) {
        finish();
        return;
      }
      setGitPanel(result);
      finish();
    }, error => {
      if (appStateRef.current.activeWorkspace !== workspaceID
        || gitLoadGenerationRef.current !== generation) {
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
    // A workspace can be left and re-entered before a Git request settles.
    // Bump the scope generation so that an old response is never mistaken for
    // the result of the newly mounted panel.
    gitWorkspaceGenerationRef.current += 1;
    gitLoadGenerationRef.current += 1;
    gitLoadingRef.current = null;
    setGitRefreshing(false);
    const action = gitActionRef.current;
    if (action && action.workspaceID !== selectedWorkspaceID) {
      // A mutation may finish after the user changes workspaces. Drop only
      // its visual gate; the request callback still carries the original
      // workspace and is ignored for the newly selected panel.
      gitActionRef.current = null;
      setGitAction("");
    }
  }, [selectedWorkspaceID]);

  useEffect(() => {
    if (!gitOpen) return;
    const timer = setInterval(() => loadGitPanel(), GIT_PANEL_POLL_MS);
    return () => clearInterval(timer);
  }, [gitOpen, loadGitPanel]);

  const runGitAction = useCallback((method, params, options = {}) => {
    const workspaceID = params?.workspace || appStateRef.current.activeWorkspace || selectedWorkspaceID;
    if (!workspaceID) return false;
    const startsInCurrentWorkspace = appStateRef.current.activeWorkspace === workspaceID;
    const showVisualState = options.visual !== false && startsInCurrentWorkspace;
    if (showVisualState && gitActionRef.current?.workspaceID === workspaceID) return false;
    const workspaceGeneration = gitWorkspaceGenerationRef.current;
    const token = { method, workspaceID, workspaceGeneration };
    const isCurrentWorkspace = () => appStateRef.current.activeWorkspace === workspaceID;
    const isCurrentOperation = () => isCurrentWorkspace()
      && gitWorkspaceGenerationRef.current === workspaceGeneration;
    if (showVisualState) {
      gitActionRef.current = token;
      setGitAction(method);
      setGitError("");
    }
    const finish = () => {
      if (gitActionRef.current !== token) return;
      gitActionRef.current = null;
      setGitAction("");
    };
    const sent = request(method, { ...params, workspace: workspaceID }, () => {
      if (!isCurrentOperation()) {
        finish();
        return;
      }
      finish();
      announceFeedback(`${gitActionLabel(method)} complete`, "success");
      loadGitPanel(false, workspaceID);
    }, error => {
      if (!isCurrentOperation()) {
        finish();
        return;
      }
      finish();
      setGitError(error);
      announceFeedback(error || `${gitActionLabel(method)} failed`, "error");
    });
    if (!sent) {
      finish();
      if (isCurrentOperation()) {
        setGitError("Not connected");
        announceFeedback("Git action unavailable while disconnected", "error");
      }
    }
    return sent;
  }, [announceFeedback, loadGitPanel, request, selectedWorkspaceID]);

  const runGitCommit = useCallback(message => {
    const workspaceID = selectedWorkspaceID || appStateRef.current.activeWorkspace;
    if (!workspaceID) return false;
    if (gitActionRef.current?.workspaceID === workspaceID) return false;
    const workspaceGeneration = gitWorkspaceGenerationRef.current;
    const token = { method: "git.commit", workspaceID, workspaceGeneration };
    gitActionRef.current = token;
    const isCurrentWorkspace = () => appStateRef.current.activeWorkspace === workspaceID;
    const isCurrentOperation = () => isCurrentWorkspace()
      && gitWorkspaceGenerationRef.current === workspaceGeneration;
    if (isCurrentWorkspace()) {
      setGitAction("git.commit");
      setGitError("");
    }
    const finish = () => {
      if (gitActionRef.current !== token) return;
      gitActionRef.current = null;
      setGitAction("");
    };
    const sent = request("git.commit", { workspace: workspaceID, message }, () => {
      if (!isCurrentOperation()) {
        finish();
        // Preserve the requested Commit & Push sequence without allowing the
        // background push to claim the newly selected workspace's UI state.
        runGitAction("git.push", { workspace: workspaceID }, { visual: false });
        return;
      }
      finish();
      announceFeedback("Commit complete", "success");
      loadGitPanel(false, workspaceID);
      runGitAction("git.push", { workspace: workspaceID });
    }, error => {
      if (!isCurrentOperation()) {
        finish();
        return;
      }
      finish();
      setGitError(error);
      announceFeedback(error || "Commit failed", "error");
    });
    if (!sent) {
      finish();
      if (isCurrentOperation()) {
        setGitError("Not connected");
        announceFeedback("Commit unavailable while disconnected", "error");
      }
    }
    return sent;
  }, [announceFeedback, loadGitPanel, request, runGitAction, selectedWorkspaceID]);

  const [fileView, setFileView] = useState(null);
  const [fileDiff, setFileDiff] = useState({ loading: false, diff: "", content: "", error: "" });
  const fileViewKeyRef = useRef(null);
  const fileViewRef = useRef(null);
  const fileDiffRequestRef = useRef(null);
  const [gitPanelSavedUI, setGitPanelSavedUI] = useState({});
  const gitPanelUIStateRef = useRef({});
  const [fileDiffViewTab, setFileDiffViewTabState] = useState("diff");
  const [fileDiffStyle, setFileDiffStyleState] = useState("unified");
  const fileDiffViewRef = useRef({ viewTab: "diff", diffStyle: "unified" });

  const setCurrentFileView = useCallback(value => {
    if (!value) {
      fileViewKeyRef.current = null;
      fileDiffRequestRef.current = null;
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
    const requestToken = { key, workspaceID };
    fileDiffRequestRef.current = requestToken;
    fileViewKeyRef.current = key;
    setCurrentFileView({ key, path: change.path, staged: change.staged, commit });
    setFileDiff({ loading: true, diff: "", content: "", error: "" });
    const params = { path: change.path, staged: change.staged };
    if (commit) params.commit = commit;
    const sent = request("git.diff", { workspace: workspaceID, ...params }, result => {
      if (fileViewKeyRef.current !== key || fileDiffRequestRef.current !== requestToken) return;
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
      if (fileViewKeyRef.current !== key || fileDiffRequestRef.current !== requestToken) return;
      setFileDiff({ loading: false, diff: "", content: "", error: diffError });
    });
    if (!sent && fileViewKeyRef.current === key && fileDiffRequestRef.current === requestToken) {
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
    const params = { session: sessionID, limit: "200", priority: "conversation", wireOptions: { omitFields: ["output"] } };
    if (before > 0) params.before = String(before);
    const token = {
      id: ++agentHistoryRequestSequenceRef.current,
      sessionID,
      before,
    };
    agentHistoryRequestRef.current.set(sessionID, token);
    setAgentStateBySession(previous => {
      const current = previous[sessionID] || {};
      return {
        ...previous,
        [sessionID]: { ...current, historyLoading: true, historyError: "" },
      };
    });
    if (!request("agent.history", params, result => {
        if (agentHistoryRequestRef.current.get(sessionID) !== token) return;
        const events = Array.isArray(result?.events) ? result.events : [];
        const cursor = Number(result?.cursor) || 0;
        const hasMore = Boolean(result?.hasMore);
        const epoch = result?.epoch;
        if (events.length > 0) {
          saveAgentEvents(sessionID, epoch, events);
        }
        setAgentStateBySession(previous => {
          if (agentHistoryRequestRef.current.get(sessionID) !== token) return previous;
          const current = previous[sessionID] || {};
          const epochNumber = Number(epoch);
          const currentEpochNumber = Number(current.epoch);
          const staleEpoch = epoch && current.epoch
            && String(epoch) !== String(current.epoch)
            && (!Number.isFinite(epochNumber)
              || !Number.isFinite(currentEpochNumber)
              || epochNumber < currentEpochNumber);
          if (staleEpoch) {
            return {
              ...previous,
              [sessionID]: { ...current, historyLoading: false },
            };
          }
          const sameEpoch = !epoch || !current.epoch || String(current.epoch) === String(epoch);
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
              historyError: "",
            },
          };
        });
      }, error => {
        if (agentHistoryRequestRef.current.get(sessionID) !== token) return;
        // A failed history request must not leave the loader spinning. Keep an
        // actionable retry affordance in the conversation surface instead of
        // silently dropping the user's only way to load older messages.
        setAgentStateBySession(previous => {
          if (agentHistoryRequestRef.current.get(sessionID) !== token) return previous;
          const current = previous[sessionID] || {};
          return {
            ...previous,
            [sessionID]: {
              ...current,
              historyLoading: false,
              historyError: String(error || "Unable to load Agent history. Try again."),
            },
          };
        });
      })) {
      // Not connected yet; clear the loading flag so the effect can retry
      // once the transport is back.
      setAgentStateBySession(previous => {
        if (agentHistoryRequestRef.current.get(sessionID) !== token) return previous;
        const current = previous[sessionID] || {};
        return {
          ...previous,
          [sessionID]: {
            ...current,
            historyLoading: false,
            historyError: "The daemon is not connected. Reconnect and try again.",
          },
        };
      });
    }
  }, [request]);

  const markAttachReady = useCallback((sessionID, flush = true, focus = true) => {
    const state = appStateRef.current;
    if (state.activeSession !== sessionID) return;
    // The attach response is ordered before subsequent WebSocket frames, so
    // it is safe to accept input even while the presentation gate is still
    // holding the terminal behind the neutral recovery surface.
    state.attachedSession = sessionID;
    setAttachedSession(sessionID);
    if (flush) inputQueueRef.current.flush(sessionID);
    // Touch devices must not pop the software keyboard as a side effect of
    // attaching a session; the user focuses the terminal by tapping it.
    if (focus && autoFocusOnAttachRef.current && !isCoarsePointer()) terminalRef.current?.focus();
  }, []);

  const markPresentationReady = useCallback(sessionID => {
    const subscription = subscriptionRef.current;
    if (appStateRef.current.activeSession !== sessionID
      || subscription.sessionID !== sessionID
      || subscription.status !== "applying") return;
    subscription.status = "synced";
    if (recoveryTimeoutRef.current !== null) {
      clearTimeout(recoveryTimeoutRef.current);
      recoveryTimeoutRef.current = null;
    }
    setTerminalReadySession(sessionID);
    if (pendingSessionRef.current === sessionID) {
      pendingSessionRef.current = null;
      setPendingSessionID(null);
      if (pendingSessionFeedbackRef.current) announceFeedback("Session ready", "success");
      pendingSessionFeedbackRef.current = false;
    }
  }, [announceFeedback]);

  const clearRecoveryTimeout = useCallback(() => {
    if (recoveryTimeoutRef.current !== null) {
      clearTimeout(recoveryTimeoutRef.current);
      recoveryTimeoutRef.current = null;
    }
  }, []);

  const clearRecoveryState = useCallback(() => {
    clearRecoveryTimeout();
    snapshotPendingRef.current = true;
    recoveryApplyingRef.current = false;
    pendingAtomicStateRef.current = null;
    stagedRecoveryOutputRef.current = [];
    recoveryAnchorRef.current = null;
    batcherRef.current?.reset();
    setTerminalReadySession(null);
  }, [clearRecoveryTimeout]);

  const cancelSubscription = useCallback((sendUnsubscribe = true) => {
    const previous = subscriptionRef.current;
    const previousSessionID = previous.sessionID;
    if (previous.requestID) clearPendingRequest(pendingRequestsRef.current, previous.requestID);
    if (previous.cancelRequestID) clearPendingRequest(pendingRequestsRef.current, previous.cancelRequestID);
    focusRequestGenerationRef.current += 1;
    agentQueueGenerationRef.current += 1;
    agentInterruptGenerationRef.current += 1;
    agentInterruptInFlightRef.current.clear();
    subscriptionRef.current = {
      sessionID: null,
      status: "idle",
      generation: previous.generation + 1,
      requestID: null,
      cancelRequestID: null,
    };
    clearRecoveryState();
    if (sendUnsubscribe && previousSessionID) {
      // Unsubscribe is best effort. The generation check below makes a late
      // response harmless even when the socket closes before it is answered.
      request("session.unsubscribe", { id: previousSessionID });
    }
    return previousSessionID;
  }, [clearRecoveryState, request]);

  // Keep an always-current cleanup callback for effects whose lifetime is
  // intentionally independent from React render dependencies (the terminal
  // and WebSocket are long-lived resources).
  subscriptionCleanupRef.current = cancelSubscription;

  const beginSubscription = useCallback((sessionID, terminal) => {
    if (!sessionID) return false;
    const previous = subscriptionRef.current;
    const generation = previous.generation + 1;
    const previousSessionID = previous.sessionID;
    const state = {
      sessionID,
      status: previousSessionID ? "cancelling" : "subscribing",
      generation,
      requestID: null,
      cancelRequestID: null,
    };
    subscriptionRef.current = state;
    if (previous.requestID) clearPendingRequest(pendingRequestsRef.current, previous.requestID);
    if (previous.cancelRequestID) clearPendingRequest(pendingRequestsRef.current, previous.cancelRequestID);
    clearRecoveryState();

    const sendSubscribe = () => {
      if (subscriptionRef.current !== state
        || state.generation !== subscriptionRef.current.generation
        || appStateRef.current.activeSession !== sessionID) return false;
      state.status = "subscribing";
      const message = attachTerminalMessage(
        sessionID,
        terminal,
        null,
        !document.hidden && document.hasFocus(),
      );
      const sent = request(message.method, message.params, () => {
        if (subscriptionRef.current !== state
          || appStateRef.current.activeSession !== sessionID) return;
        state.status = "acknowledged";
        // The Host registers the output subscription before acknowledging the
        // request. Accepting input here keeps the PTY responsive while the
        // atomic state is still behind the presentation gate.
        markAttachReady(sessionID, true, false);
      }, detail => {
        if (subscriptionRef.current !== state
          || appStateRef.current.activeSession !== sessionID) return;
        state.status = "failed";
        clearRecoveryTimeout();
        setConnectionStatus({ message: detail, online: false });
        setEmptyOverride({ loading: false, message: detail });
        if (pendingSessionRef.current === sessionID) {
          pendingSessionRef.current = null;
          setPendingSessionID(null);
          pendingSessionFeedbackRef.current = false;
          announceFeedback(detail || "Session unavailable", "error");
        }
      });
      state.requestID = sent || null;
      if (!sent) {
        state.status = "failed";
        if (pendingSessionRef.current === sessionID) {
          pendingSessionRef.current = null;
          setPendingSessionID(null);
          pendingSessionFeedbackRef.current = false;
          announceFeedback("Session switch unavailable", "error");
        }
        connectionRef.current?.reconnectNow();
        return false;
      }
      clearRecoveryTimeout();
      recoveryTimeoutRef.current = setTimeout(() => {
        if (subscriptionRef.current !== state || state.status === "synced") return;
        state.status = "failed";
        setConnectionStatus({ message: "Terminal recovery timed out", online: false });
        if (pendingSessionRef.current === sessionID) {
          pendingSessionRef.current = null;
          setPendingSessionID(null);
          pendingSessionFeedbackRef.current = false;
          announceFeedback("Session recovery timed out", "error");
        }
        connectionRef.current?.reset();
      }, terminalRecoveryTimeoutMs);
      return true;
    };

    if (previousSessionID) {
      // `session.subscribe` runs in a background handler on the Host. Wait for
      // the explicit unsubscribe response before starting the replacement so
      // rapid same-session switches cannot let old markers win the queue.
      const sent = request(
        "session.unsubscribe",
        { id: previousSessionID },
        () => sendSubscribe(),
        () => sendSubscribe(),
      );
      state.cancelRequestID = sent || null;
      if (!sent) return sendSubscribe();
      return true;
    }
    return sendSubscribe();
  }, [announceFeedback, clearRecoveryState, clearRecoveryTimeout, markAttachReady, request]);

  const sendInput = useCallback(data => {
    const state = appStateRef.current;
    if (!data || !state.activeSession) return false;
    if (state.attachedSession !== state.activeSession) {
      inputQueueRef.current.enqueue(state.activeSession, data);
      return false;
    }
    if (!connectionRef.current?.sendBinary(data)) {
      inputQueueRef.current.enqueue(state.activeSession, data);
      connectionRef.current?.reconnectNow();
      return false;
    }
    return true;
  }, []);

  const sendAgentInput = useCallback(async text => {
    // The agent process is a TUI: the only input channel is the PTY. Codex
    // reads a literal CR as text (a newline inside the input box), not as a
    // submit key, so the message is written first and the kitty-protocol
    // Enter event (CSI 13 u) is delivered in its own frame afterwards. The
    // small delay keeps the TUI from folding both writes into one paste and
    // dropping the message before the Enter key.
    const state = appStateRef.current;
    const sessionID = state.activeSession;
    if (!sessionID || state.attachedSession !== sessionID) return false;
    const generation = agentQueueGenerationRef.current;
    const connection = connectionRef.current;
    if (!connection?.sendBinary(text.replace(/\n/g, "\r"))) {
      connection?.reconnectNow();
      return false;
    }
    await new Promise(resolve => setTimeout(resolve, 80));
    if (appStateRef.current.activeSession !== sessionID
      || appStateRef.current.attachedSession !== sessionID
      || agentQueueGenerationRef.current !== generation
      || connectionRef.current !== connection) {
      return false;
    }
    const entered = connection.sendBinary("\x1b[13u");
    if (!entered) connection.reconnectNow();
    return entered;
  }, []);

  const publishAgentQueue = useCallback((sessionID, queue) => {
    const items = queue.items.map(item => ({ ...item, attachments: [...(item.attachments || [])] }));
    setAgentQueueBySession(previous => ({ ...previous, [sessionID]: items }));
  }, []);

  const drainAgentQueue = useCallback(sessionID => {
    // A queue belongs to both its endpoint and Session. Only the focused
    // Session owns the PTY/control lease, so a ready event from an old tab
    // must never drain another Session's local messages.
    if (appStateRef.current.activeSession !== sessionID
      || appStateRef.current.attachedSession !== sessionID
      || focusedSessionRef.current !== sessionID) return;
    const state = agentStateBySession[sessionID];
    const activity = String(state?.status?.activity || "").toLowerCase();
    const inputAttention = state?.status?.attention?.kind === "input";
    if (activity !== "ready" && !(activity === "blocked" && inputAttention)) return;
    const queueKey = agentQueueKey(webSocketURL(), sessionID);
    const queue = agentQueueRef.current[queueKey];
    if (!queue) return;
    const inFlight = agentMessageRequestRef.current.get(queueKey);
    if (queue.items.some(item => item.status === "sending")) {
      // A focus/session generation change makes the old request's delivery
      // ambiguous. Re-queue it before trying again; the stable client ID lets
      // the Host deduplicate a late success.
      if (!inFlight || inFlight.generation !== agentQueueGenerationRef.current) {
        queue.items
          .filter(item => item.status === "sending")
          .forEach(item => queue.markQueued(item.id));
        if (inFlight) agentMessageRequestRef.current.delete(queueKey);
        publishAgentQueue(sessionID, queue);
      }
      return;
    }
    const item = queue.items.find(value => value.status === "queued");
    if (!item) return;
    queue.markSending(item.id);
    publishAgentQueue(sessionID, queue);
    const requestToken = {
      itemID: item.id,
      sessionID,
      generation: agentQueueGenerationRef.current,
      endpoint: webSocketURL(),
    };
    agentMessageRequestRef.current.set(queueKey, requestToken);
    const isCurrentRequest = () => (
      agentMessageRequestRef.current.get(queueKey) === requestToken
      && requestToken.generation === agentQueueGenerationRef.current
      && appStateRef.current.activeSession === sessionID
      && focusedSessionRef.current === sessionID
    );
    const delivered = () => {
      if (agentMessageRequestRef.current.get(queueKey) !== requestToken) return;
      if (!isCurrentRequest()) {
        if (queue.items.some(value => value.id === item.id && value.status === "sending")) {
          queue.markQueued(item.id);
          publishAgentQueue(sessionID, queue);
        }
        agentMessageRequestRef.current.delete(queueKey);
        return;
      }
      agentMessageRequestRef.current.delete(queueKey);
      queue.deliver(item.id);
      publishAgentQueue(sessionID, queue);
      drainAgentQueue(sessionID);
    };
    const failed = detail => {
      if (agentMessageRequestRef.current.get(queueKey) !== requestToken) return;
      if (!isCurrentRequest()) {
        if (queue.items.some(value => value.id === item.id && value.status === "sending")) {
          queue.markQueued(item.id);
          publishAgentQueue(sessionID, queue);
        }
        agentMessageRequestRef.current.delete(queueKey);
        return;
      }
      agentMessageRequestRef.current.delete(queueKey);
      const stillFocused = appStateRef.current.activeSession === sessionID
        && focusedSessionRef.current === sessionID;
      if (stillFocused) queue.markFailed(item.id, detail);
      else queue.markQueued(item.id);
      publishAgentQueue(sessionID, queue);
    };
    if (item.attachments?.length > 0 && !supportsSessionAgentCapability(appStateRef.current.catalog, agentCapabilitiesRef.current, sessionID, "agent-attachments-v1")) {
      failed("This Host does not support attachments");
    } else if (supportsSessionAgentCapability(appStateRef.current.catalog, agentCapabilitiesRef.current, sessionID, "agent-timeline-v1") || item.attachments?.length > 0) {
      const sent = request(
        "agent.message.send",
        {
          session: sessionID,
          clientMessageId: item.id,
          text: item.text,
          ...(item.attachments?.length ? { attachments: item.attachments } : {}),
        },
        result => result?.accepted ? delivered() : failed("Host did not accept the message"),
        failed,
      );
      if (!sent) failed("Connection unavailable");
    } else {
      void sendAgentInput(item.text).then(sent => {
        if (sent) delivered();
        else failed("Agent input was interrupted; retry.");
      });
    }
  }, [agentStateBySession, publishAgentQueue, request, sendAgentInput]);

  const queueAgentMessage = useCallback((sessionID, text, attachments = []) => {
    const queueKey = agentQueueKey(webSocketURL(), sessionID);
    const queue = agentQueueRef.current[queueKey] || new AgentMessageQueue();
    agentQueueRef.current[queueKey] = queue;
    const item = queue.enqueue({ text, attachments });
    publishAgentQueue(sessionID, queue);
    return item;
  }, [publishAgentQueue]);

  const sendAgentMessageFromView = useCallback((text, attachments = []) => {
    const sessionID = appStateRef.current.activeSession;
    if (!sessionID) return false;
    // Every composer submission gets a stable local ID first. The drain then
    // selects structured `agent.message.send` or the legacy PTY fallback
    // according to the negotiated capabilities, avoiding a second send path
    // that could race the queue or lose idempotency.
    queueAgentMessage(sessionID, text, attachments);
    drainAgentQueue(sessionID);
    return true;
  }, [drainAgentQueue, queueAgentMessage]);

  const editAgentQueueItem = useCallback((sessionID, itemID, text, attachments) => {
    const queue = agentQueueRef.current[agentQueueKey(webSocketURL(), sessionID)];
    if (!queue || !queue.edit(itemID, text, attachments)) return;
    publishAgentQueue(sessionID, queue);
    drainAgentQueue(sessionID);
  }, [drainAgentQueue, publishAgentQueue]);

  const deleteAgentQueueItem = useCallback((sessionID, itemID) => {
    const queue = agentQueueRef.current[agentQueueKey(webSocketURL(), sessionID)];
    if (!queue || !queue.remove(itemID)) return;
    publishAgentQueue(sessionID, queue);
  }, [publishAgentQueue]);

  const moveAgentQueueItemToFront = useCallback((sessionID, itemID) => {
    const queue = agentQueueRef.current[agentQueueKey(webSocketURL(), sessionID)];
    if (!queue || !queue.moveToFront(itemID)) return;
    publishAgentQueue(sessionID, queue);
    drainAgentQueue(sessionID);
  }, [drainAgentQueue, publishAgentQueue]);

  const reorderAgentQueueItem = useCallback((sessionID, itemID, beforeID) => {
    const queue = agentQueueRef.current[agentQueueKey(webSocketURL(), sessionID)];
    if (!queue || !queue.reorder(itemID, beforeID)) return;
    publishAgentQueue(sessionID, queue);
    drainAgentQueue(sessionID);
  }, [drainAgentQueue, publishAgentQueue]);

  const retryAgentQueueItem = useCallback((sessionID, itemID) => {
    const queue = agentQueueRef.current[agentQueueKey(webSocketURL(), sessionID)];
    if (!queue || !queue.retry(itemID)) return;
    publishAgentQueue(sessionID, queue);
    drainAgentQueue(sessionID);
  }, [drainAgentQueue, publishAgentQueue]);

  useEffect(() => {
    for (const [sessionID, state] of Object.entries(agentStateBySession)) {
      if (state?.status?.activity === "ready"
        || (state?.status?.activity === "blocked" && state?.status?.attention?.kind === "input")) {
        drainAgentQueue(sessionID);
      }
    }
  }, [agentStateBySession, drainAgentQueue]);

  useEffect(() => {
    // Focus is granted asynchronously after the composer/terminal request;
    // retry the active Session's queue at that exact control boundary.
    if (focusedSessionID) drainAgentQueue(focusedSessionID);
  }, [focusedSessionID, drainAgentQueue]);

  const activeAgentTurn = useCallback(sessionID => {
    const state = agentStateBySession[sessionID];
    const explicit = state?.turn?.id || state?.turn;
    if (Number(explicit) > 0) return Number(explicit);
    const events = state?.events || [];
    const value = [...events].reverse().find(event => Number(event?.turn) > 0)?.turn;
    return Number(value) || 0;
  }, [agentStateBySession]);

  const cancelAgentTurn = useCallback(sessionID => {
    if (!supportsSessionAgentCapability(appStateRef.current.catalog, agentCapabilitiesRef.current, sessionID, "agent-interrupt-v1")) return;
    const turn = activeAgentTurn(sessionID);
    if (!turn || agentInterruptInFlightRef.current.has(sessionID)) return;
    agentInterruptInFlightRef.current.add(sessionID);
    const requestGeneration = agentInterruptGenerationRef.current;
    setAgentActionError("");
    const sent = request(
      "agent.turn.interrupt",
      { session: sessionID, turn, reason: "cancel" },
      () => {
        if (agentInterruptGenerationRef.current === requestGeneration) {
          agentInterruptInFlightRef.current.delete(sessionID);
        }
      },
      error => {
        if (agentInterruptGenerationRef.current === requestGeneration) {
          agentInterruptInFlightRef.current.delete(sessionID);
        }
        if (appStateRef.current.activeSession === sessionID) {
          setAgentActionError(String(error || "Cancel failed"));
        }
      },
    );
    if (!sent) {
      if (agentInterruptGenerationRef.current === requestGeneration) {
        agentInterruptInFlightRef.current.delete(sessionID);
      }
      if (appStateRef.current.activeSession === sessionID) {
        setAgentActionError("Connection unavailable");
      }
    }
  }, [activeAgentTurn, request]);

  const sendAgentMessageNow = useCallback((sessionID, text, attachments = []) => {
    if (!supportsSessionAgentCapability(appStateRef.current.catalog, agentCapabilitiesRef.current, sessionID, "agent-interrupt-v1")) {
      return Promise.reject(new Error("This Host does not support interrupting turns"));
    }
    if (attachments.length > 0 && !supportsSessionAgentCapability(appStateRef.current.catalog, agentCapabilitiesRef.current, sessionID, "agent-attachments-v1")) {
      return Promise.reject(new Error("This Host does not support attachments"));
    }
    const turn = activeAgentTurn(sessionID);
    const value = String(text || "").trim();
    if (!turn || (!value && attachments.length === 0) || agentInterruptInFlightRef.current.has(sessionID)) {
      return Promise.reject(new Error("The active Agent turn is unavailable"));
    }
    const item = queueAgentMessage(sessionID, value, attachments);
    const queueKey = agentQueueKey(webSocketURL(), sessionID);
    const queue = agentQueueRef.current[queueKey];
    const requestGeneration = agentInterruptGenerationRef.current;
    queue.markSending(item.id);
    publishAgentQueue(sessionID, queue);
    agentInterruptInFlightRef.current.add(sessionID);
    setAgentActionError("");
    return new Promise((resolve, reject) => {
      const finish = (result, error = "") => {
        const currentInterrupt = requestGeneration === agentInterruptGenerationRef.current;
        if (currentInterrupt) agentInterruptInFlightRef.current.delete(sessionID);
        const stillFocused = appStateRef.current.activeSession === sessionID
          && focusedSessionRef.current === sessionID
          && currentInterrupt;
        if (error || !result?.accepted) {
          if (stillFocused) queue.markFailed(item.id, error || "Host did not accept Send now");
          else queue.markQueued(item.id);
          publishAgentQueue(sessionID, queue);
          const detail = error || "Host did not accept Send now";
          if (appStateRef.current.activeSession === sessionID) {
            setAgentActionError(detail);
          }
          reject(new Error(detail));
          return;
        }
        queue.deliver(item.id);
        publishAgentQueue(sessionID, queue);
        resolve(result);
      };
      const sent = request(
        "agent.turn.interrupt",
        {
          session: sessionID,
          turn,
          reason: "send_now",
          replacement: {
            session: sessionID,
            clientMessageId: item.id,
            text: value,
            ...(attachments.length ? { attachments } : {}),
          },
        },
        result => finish(result),
        error => finish(null, String(error || "Send now failed")),
      );
      if (!sent) finish(null, "Connection unavailable");
    });
  }, [activeAgentTurn, publishAgentQueue, queueAgentMessage, request]);

  const respondAgentInteraction = useCallback((sessionID, value) => {
    if (!supportsSessionAgentCapability(appStateRef.current.catalog, agentCapabilitiesRef.current, sessionID, "agent-interactions-v1")) {
      return Promise.reject(new Error("This Host does not support interactions"));
    }
    setAgentActionError("");
    return new Promise((resolve, reject) => {
      const failed = detail => {
        const error = String(detail || "Interaction response failed");
        if (appStateRef.current.activeSession === sessionID) {
          setAgentActionError(error);
        }
        reject(new Error(error));
      };
      const sent = request(
        "agent.interaction.respond",
        {
          session: sessionID,
          requestId: value.requestId,
          kind: value.kind,
          response: value.response,
        },
        resolve,
        failed,
      );
      if (!sent) failed("Connection unavailable");
    });
  }, [request]);

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
    const generation = ++focusRequestGenerationRef.current;
    // A passive Web subscription deliberately does not claim control during
    // background/hidden-page attach. Carry the session id so the Host can
    // promote that already-registered subscription when the page becomes
    // visible again; omitting it would make `session.focus` depend on the
    // legacy attached pointer and leave the page unable to send input after a
    // background handoff.
    const params = { focused, id: sessionID };
    if (focused) {
      const next = size || terminalSize(terminalRef.current);
      if (next) Object.assign(params, next);
    }
    const sent = request("session.focus", params, result => {
      if (appStateRef.current.activeSession !== sessionID
        || appStateRef.current.attachedSession !== sessionID
        || focusRequestGenerationRef.current !== generation) return;
      if (focused) {
        focusedSessionRef.current = result?.focused ? sessionID : null;
        setFocusedSessionID(result?.focused ? sessionID : null);
      } else if (focusedSessionRef.current === sessionID) {
        focusedSessionRef.current = null;
        setFocusedSessionID(null);
      }
    }, () => {
      if (appStateRef.current.activeSession !== sessionID
        || appStateRef.current.attachedSession !== sessionID
        || focusRequestGenerationRef.current !== generation) return;
      focusedSessionRef.current = null;
      setFocusedSessionID(null);
    });
    if (!sent) return false;
    focusedSessionRef.current = focused ? sessionID : null;
    setFocusedSessionID(focused ? sessionID : null);
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
    if (!force && pendingSessionRef.current === sessionID) return;
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
    pendingSessionRef.current = sessionID;
    setPendingSessionID(sessionID);
    setHasNewTerminalOutput(false);
    pendingSessionFeedbackRef.current = explicit;
    if (explicit) announceFeedback("Switching session…", "pending", 0);
    const changed = sessionID !== state.activeSession;
    state.activeSession = sessionID;
    state.attachedSession = null;
    focusRequestGenerationRef.current += 1;
    if (changed) {
      agentQueueGenerationRef.current += 1;
      agentInterruptGenerationRef.current += 1;
      agentInterruptInFlightRef.current.clear();
    }
    setTerminalReadySession(null);
    snapshotPendingRef.current = true;
    recoveryApplyingRef.current = false;
    pendingAtomicStateRef.current = null;
    stagedRecoveryOutputRef.current = [];
    batcherRef.current?.reset();
    focusedSessionRef.current = null;
    setFocusedSessionID(null);
    if (changed) inputQueueRef.current.clear();
    setActiveSession(sessionID);
    setAttachedSession(null);
    setEmptyOverride(null);
    sentTerminalSizeRef.current = null;
    if (changed) {
      terminalRef.current?.clear();
      clearTerminalSearch();
      recoveryAnchorRef.current = null;
      setAgentViewOverride(null);
    }
    beginSubscription(sessionID, terminalRef.current);
  }, [announceFeedback, beginSubscription, clearTerminalSearch, recordNavigation, refreshTerminal]);

  const createSession = useCallback((kind, targetWorkspaceID = null) => {
    const workspaceID = targetWorkspaceID
      || appStateRef.current.activeWorkspace
      || selectedWorkspaceID;
    if (!reserveWorkspaceSession(creatingSessionWorkspaceIDsRef.current, workspaceID)) {
      return false;
    }
    const preset = orderedPresets.find(value => value.kind === kind) || orderedPresets[0];
    const creationToken = { workspaceID, kind: preset.kind };
    markWorkspaceCreation(workspaceID, true);
    const finish = () => {
      releaseWorkspaceSession(creatingSessionWorkspaceIDsRef.current, workspaceID);
      markWorkspaceCreation(workspaceID, false);
      if (creatingSessionKindRef.current === creationToken) {
        creatingSessionKindRef.current = null;
        setCreatingSessionKind(null);
      }
    };
    if (appStateRef.current.activeWorkspace === workspaceID) {
      creatingSessionKindRef.current = creationToken;
      setCreatingSessionKind(preset.kind);
    }
    // The preset title is presentation copy for the button and the starting
    // message; it must not become the session's user-set custom title, which
    // would suppress automatic AI title generation. The Host derives the
    // default display title from the kind when no explicit title is given.
    const sent = request("session.create", {
      workspace: workspaceID,
      kind: preset.kind,
      command: presetCommands[preset.kind] || "",
    }, result => {
      finish();
      const isCurrentWorkspace = appStateRef.current.activeWorkspace === workspaceID;
      if (isCurrentWorkspace) {
        setSessionSheetOpen(false);
        announceFeedback(`${preset.title} session created`, "success");
      }
      const sessionID = result?.id;
      if (sessionID && shouldAttachCreatedSession(
        appStateRef.current.activeWorkspace,
        workspaceID,
      )) {
        attachSession(sessionID);
      }
    }, detail => {
      finish();
      const isCurrentWorkspace = appStateRef.current.activeWorkspace === workspaceID;
      if (isCurrentWorkspace) {
        setConnectionStatus({ message: detail, online: false });
        announceFeedback(detail || `Unable to create ${preset.title} session`, "error");
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
      if (appStateRef.current.activeWorkspace === workspaceID) {
        announceFeedback("Session creation unavailable while disconnected", "error");
      }
      connectionRef.current?.reconnectNow();
    }
    return sent;
  }, [announceFeedback, attachSession, markWorkspaceCreation, orderedPresets, presetCommands, request, selectedWorkspaceID]);

  const chooseWorkspace = useCallback((workspaceID, preferredSessionID = null, automaticEntry = true) => {
    const state = appStateRef.current;
    // A workspace gesture supersedes an in-flight tab handoff. Clear its
    // visual gate before rendering the new workspace so a stale tab ID cannot
    // disable the next workspace's controls.
    clearPendingSession();
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
    setTerminalReadySession(null);
    focusedSessionRef.current = null;
    setFocusedSessionID(null);
    setActiveWorkspace(workspaceID);
    if (previousWorkspaceID !== workspaceID) {
      if (creatingSessionKindRef.current?.workspaceID === previousWorkspaceID) {
        creatingSessionKindRef.current = null;
        setCreatingSessionKind(null);
      }
      restoreGitUIForWorkspace(workspaceID);
    }
    setActiveSession(null);
    setAttachedSession(null);
    setEmptyOverride(null);
    setAgentViewOverride(null);
    batcherRef.current?.reset();
    terminalRef.current?.clear();
    clearTerminalSearch();
    recoveryAnchorRef.current = null;
    snapshotPendingRef.current = true;
    recoveryApplyingRef.current = false;
    pendingAtomicStateRef.current = null;
    stagedRecoveryOutputRef.current = [];
    setDrawerOpen(false);

    if (sessionID) attachSession(sessionID, true);
    else if (nextTabs.length) attachSession(nextTabs[0].id, true);
    else {
      cancelSubscription();
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
  }, [attachSession, autoStartAI, cancelSubscription, clearPendingSession, clearTerminalSearch, createSession, persistCurrentGitUI, recordNavigation, request, restoreGitUIForWorkspace, visiblePresets]);

  const chooseSessionPreset = useCallback(kind => {
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
    const isDelta = message?.t === "roster.delta";
    const nextRoster = isDelta
      ? applyRosterDelta(rosterRef.current, message)
      : rosterFromMessage(message);
    if (!nextRoster) {
      // A delta without the matching baseline (or with a revision gap) is not
      // safe to merge. Ask the Host for a fresh authoritative snapshot once;
      // reconnecting is reserved for an actually broken transport.
      if (!rosterRefreshInFlightRef.current) {
        rosterRefreshInFlightRef.current = true;
        const sent = request("roster", {}, result => {
          rosterRefreshInFlightRef.current = false;
          acceptRoster(result);
        }, detail => {
          rosterRefreshInFlightRef.current = false;
          setConnectionStatus({ message: detail || "Unable to refresh roster", online: false });
        });
        if (!sent) rosterRefreshInFlightRef.current = false;
      }
      return;
    }
    // A full snapshot is authoritative. Delta responses can race a recovery
    // request, so never roll a known revision backwards.
    const previousRoster = rosterRef.current;
    if (!isDelta && previousRoster?.revision !== null && nextRoster.revision !== null
      && nextRoster.revision < previousRoster.revision) {
      rosterRefreshInFlightRef.current = false;
      return;
    }
    rosterRef.current = nextRoster;
    if (!isDelta) rosterRefreshInFlightRef.current = false;
    clearMaintenanceTimeout();
    connectionRef.current?.markStable();
    if (!connectionOnlineRef.current) announceFeedback("Connected", "success");
    connectionOnlineRef.current = true;
    loadRemoteSettings();
    const nextCatalog = buildCatalog(nextRoster);
    const state = appStateRef.current;
    const completedSessions = agentTurnCompletionTrackerRef.current.observe(nextCatalog.sessions.values());
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
        if (workspace.task) {
          setTasksCollapsed(false);
          setExpandedTasks(previous => previous.has(workspace.task)
            ? previous
            : new Set([...previous, workspace.task]));
        }
      }
    }

    if (activeTabWasRemoved) {
      state.activeSession = null;
      state.attachedSession = null;
      setTerminalReadySession(null);
      focusedSessionRef.current = null;
      setFocusedSessionID(null);
      setActiveSession(null);
      setAttachedSession(null);
      setAgentViewOverride(null);
      batcherRef.current?.reset();
      terminalRef.current?.clear();
      clearTerminalSearch();
      recoveryAnchorRef.current = null;
      snapshotPendingRef.current = true;
      recoveryApplyingRef.current = false;
      pendingAtomicStateRef.current = null;
      stagedRecoveryOutputRef.current = [];
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
    else if (activeTabWasRemoved) {
      cancelSubscription();
      request("session.detach");
    }
    for (const sessionID of completedSessions) {
      agentCompletionEventsRef.current.emit({ sessionID });
    }
  }, [announceFeedback, applyRosterDelta, attachSession, cancelSubscription, clearMaintenanceTimeout, clearTerminalSearch, loadGitPanel, loadRemoteSettings, openFileView, persistCurrentGitUI, recordNavigation, request, restoreGitUIForWorkspace]);

  const acceptMessage = useCallback(event => {
    if (event.data instanceof ArrayBuffer) {
      const bytes = new Uint8Array(event.data);
      const decoded = decodeFrame(bytes);
      const active = appStateRef.current.activeSession;
      const subscription = subscriptionRef.current;
      if (decoded?.type === "atomicState") {
        if (active !== decoded.header.sessionID
          || subscription.sessionID !== decoded.header.sessionID
          || !["syncing", "applying"].includes(subscription.status)) return;
        if (decoded.header.format !== "ghostline-vt-replay-v1") {
          setConnectionStatus({ message: "Unsupported terminal state", online: false });
          connectionRef.current?.stop();
          return;
        }
        // The state is installed only at the synced boundary. Keeping it
        // opaque here prevents a renderer from exposing a partial snapshot.
        pendingAtomicStateRef.current = decoded;
        snapshotPendingRef.current = true;
        return;
      }
      if (decoded?.type === "output"
        && active === decoded.header.sessionID
        && subscription.sessionID === decoded.header.sessionID
        && ["syncing", "applying", "synced"].includes(subscription.status)) {
        const current = recoveryAnchorRef.current;
        if (snapshotPendingRef.current || recoveryApplyingRef.current) {
          stagedRecoveryOutputRef.current.push(decoded);
          return;
        }
        if (current) {
          if (decoded.header.epoch !== current.epoch || decoded.header.sequence !== current.sequence) {
            // Protocol 2 recovery always starts from a fresh atomic state;
            // never render an out-of-order frame into the visible surface.
            connectionRef.current?.reset();
            return;
          }
          recoveryAnchorRef.current = {
            epoch: decoded.header.epoch,
            sequence: current.sequence + decoded.header.payloadLength,
          };
        }
        batcherRef.current?.enqueue(decoded.payload);
      } else if (isBinaryEnvelope(bytes)) {
        // Every protocol-2 binary message is a DENB frame. Raw PTY bytes and
        // malformed envelopes are rejected instead of being fed to xterm.
        connectionRef.current?.reset();
      } else {
        connectionRef.current?.reset();
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
    case "welcome":
      agentCapabilitiesRef.current = new Set(
        Array.isArray(message.capabilities)
          ? message.capabilities.filter(value => typeof value === "string")
          : [],
      );
      break;
    case "response": {
      const handler = pendingRequestsRef.current.get(message.id);
      clearPendingRequest(pendingRequestsRef.current, message.id);
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
    case "roster.delta":
      acceptRoster(message);
      break;
    case "attached": {
      const subscription = subscriptionRef.current;
      if (appStateRef.current.activeSession !== message.session
        || subscription.sessionID !== message.session
        || subscription.status !== "acknowledged") break;
      subscription.status = "syncing";
      focusedSessionRef.current = null;
      setFocusedSessionID(null);
      setActiveSession(message.session);
      // `attached` only acknowledges the subscription. The terminal remains
      // behind the neutral loading surface until the atomic state has been
      // written and the matching `synced` marker has rendered.
      terminalRef.current?.reset();
      batcherRef.current?.reset();
      pendingAtomicStateRef.current = null;
      stagedRecoveryOutputRef.current = [];
      recoveryApplyingRef.current = false;
      snapshotPendingRef.current = true;
      // Input may be sent as soon as the subscription is acknowledged. The
      // terminal itself remains covered until the matching synced marker has
      // finished applying the atomic state below.
      markAttachReady(message.session, true, false);
      setTerminalReadySession(null);
      setEmptyOverride(null);
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
      break;
    }
    case "created":
      appStateRef.current.activeSession = null;
      appStateRef.current.attachedSession = null;
      setTerminalReadySession(null);
      focusedSessionRef.current = null;
      setFocusedSessionID(null);
      setActiveSession(null);
      setAttachedSession(null);
      setEmptyOverride(null);
      attachSession(message.session);
      break;
    case "synced": {
      const subscription = subscriptionRef.current;
      if (appStateRef.current.activeSession !== message.session
        || subscription.sessionID !== message.session
        || subscription.status !== "syncing") break;
      subscription.status = "applying";
      const generation = subscription.generation;
      const state = pendingAtomicStateRef.current;
      if (!state
        || state.header.sessionID !== message.session
        || state.header.epoch !== message.epoch
        || state.header.sequence !== message.sequence) {
        subscription.status = "failed";
        connectionRef.current?.reset();
        break;
      }
      pendingAtomicStateRef.current = null;
      recoveryApplyingRef.current = true;
      snapshotPendingRef.current = true;
      const terminal = terminalRef.current;
      if (!terminal) {
        subscription.status = "failed";
        connectionRef.current?.reset();
        break;
      }
      terminal.reset();
      const write = (payload, callback) => {
        // xterm does not guarantee that an empty write invokes its callback;
        // an empty Ghostline checkpoint is still a valid atomic state and
        // must release the gate at the same boundary as a non-empty one.
        if (payload.length === 0) {
          queueMicrotask(callback);
        } else {
          terminal.write(payload, callback);
        }
      };
      const finish = () => {
        if (subscriptionRef.current !== subscription
          || subscription.generation !== generation
          || appStateRef.current.activeSession !== message.session
          || subscription.status !== "applying") {
          recoveryApplyingRef.current = false;
          return;
        }
        const staged = stagedRecoveryOutputRef.current;
        stagedRecoveryOutputRef.current = [];
        if (staged.length > 0) {
          let total = 0;
          for (const frame of staged) total += frame.payload.length;
          const merged = new Uint8Array(total);
          let offset = 0;
          for (const frame of staged) {
            if (frame.header.epoch !== message.epoch
              || frame.header.sequence !== message.sequence + offset) {
              subscription.status = "failed";
              connectionRef.current?.reset();
              return;
            }
            merged.set(frame.payload, offset);
            offset += frame.payload.length;
          }
          write(merged, finish);
          return;
        }
        recoveryAnchorRef.current = {
          epoch: message.epoch,
          sequence: message.sequence,
        };
        recoveryApplyingRef.current = false;
        snapshotPendingRef.current = false;
        requestAnimationFrame(() => {
          if (subscriptionRef.current !== subscription
            || subscription.generation !== generation
            || appStateRef.current.activeSession !== message.session
            || subscription.status !== "applying") return;
          fitTerminal();
          terminal.scrollToBottom();
          // The write callback means xterm has consumed the bytes; release
          // the neutral surface one frame later so its renderer has also
          // painted the restored grid before the overlay disappears.
          markPresentationReady(message.session);
          if (autoFocusOnAttachRef.current && document.hasFocus() && !isCoarsePointer()) {
            terminal.focus();
            if (focusedSessionRef.current !== message.session) requestSessionFocus(true);
          }
        });
      };
      write(state.payload, finish);
      break;
    }
    case "agent":
      if (Array.isArray(message.events) && message.events.length > 0) {
        saveAgentEvents(message.session, message.epoch, message.events);
      }
      setAgentStateBySession(previous => {
        const current = previous[message.session];
        const sameEpoch = !message.epoch || current?.epoch === message.epoch;
        if (!sameEpoch) {
          clearAgentSession(message.session);
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
              historyError: "",
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
            historyError: sameEpoch ? current?.historyError || "" : "",
          },
        };
      });
      setCatalog(previous => updateSessionAgentStatus(previous, message.session, status));
      break;
    }
    case "agent.turn": {
      const turn = Number(message.turn) || 0;
      if (!turn) break;
      setAgentStateBySession(previous => {
        const current = previous[message.session] || {};
        const sameEpoch = !message.epoch || !current.epoch || current.epoch === message.epoch;
        return {
          ...previous,
          [message.session]: {
            ...current,
            epoch: message.epoch || current.epoch,
            turn: { id: turn, status: message.status || "unknown" },
            events: sameEpoch ? current.events || [] : [],
          },
        };
      });
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
        cancelSubscription();
        appStateRef.current.activeSession = null;
        appStateRef.current.attachedSession = null;
        setTerminalReadySession(null);
        focusedSessionRef.current = null;
        setFocusedSessionID(null);
        setActiveSession(null);
        setAttachedSession(null);
        batcherRef.current?.reset();
        terminalRef.current?.clear();
        clearTerminalSearch();
        recoveryAnchorRef.current = null;
        snapshotPendingRef.current = false;
        recoveryApplyingRef.current = false;
        pendingAtomicStateRef.current = null;
        stagedRecoveryOutputRef.current = [];
      }
      break;
    case "exited":
      if (appStateRef.current.activeSession === message.session
        || appStateRef.current.attachedSession === message.session) {
        cancelSubscription();
        appStateRef.current.activeSession = null;
        appStateRef.current.attachedSession = null;
        setTerminalReadySession(null);
        focusedSessionRef.current = null;
        setFocusedSessionID(null);
        setActiveSession(null);
        setAttachedSession(null);
        batcherRef.current?.reset();
        clearTerminalSearch();
        snapshotPendingRef.current = false;
        recoveryApplyingRef.current = false;
        pendingAtomicStateRef.current = null;
        stagedRecoveryOutputRef.current = [];
        terminalRef.current?.clear();
        setEmptyOverride({ loading: false, message: "Session ended" });
      }
      break;
    case "error":
      {
        const detail = connectionErrorDetail(message);
        setConnectionStatus({ message: detail, online: false });
        setEmptyOverride({ loading: false, message: detail });
        connectionOnlineRef.current = false;
        clearPendingSession();
        announceFeedback(detail || "Connection failed", "error");
        if (detail === "unauthorized") {
          // Relay access capabilities are intentionally short lived. Rotate
          // through the HttpOnly refresh cookie once before treating an
          // unauthorized socket as terminal; the shareable pairing link is
          // not needed again while this refresh family remains valid.
          if (runtime.usesControlPlane && !relayRefreshInFlightRef.current) {
            relayRefreshInFlightRef.current = true;
            runtime.refresh().then(token => {
              relayRefreshInFlightRef.current = false;
              const connection = connectionRef.current;
              if (!token || !connection) {
                connection?.stop();
                return;
              }
              connection.token = token;
              connection.reset();
            }).catch(() => {
              relayRefreshInFlightRef.current = false;
              connectionRef.current?.stop();
            });
          } else if (!runtime.usesControlPlane) {
            connectionRef.current?.stop();
          }
        }
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
    announceFeedback,
    attachSession,
    cancelSubscription,
    clearMaintenanceTimeout,
    clearPendingSession,
    clearTerminalSearch,
    fitTerminal,
    markAttachReady,
    markPresentationReady,
    requestSessionFocus,
    scheduleMaintenanceTimeout,
  ]);

  const acceptConnectionState = useCallback(state => {
    clearMaintenanceTimeout();
    if (state === "connecting") {
      // A new socket cannot carry the previous peer's subscriptions. Invalidate
      // every recovery callback before the reconnect roster reattaches the
      // selected session; do not send an unsubscribe over the closing socket.
      cancelSubscription(false);
      rosterRef.current = null;
      rosterRefreshInFlightRef.current = false;
      settingsLoadedRef.current = false;
      agentCapabilitiesRef.current = new Set();
      setConnectionStatus({ message: "Connecting…", online: false });
      clearPendingSession();
      if (connectionOnlineRef.current) announceFeedback("Reconnecting…", "pending");
      connectionOnlineRef.current = false;
      return;
    }
    if (state === "open") {
      setConnectionStatus({ message: "Authenticating…", online: false });
      return;
    }
    cancelSubscription(false);
    rejectPendingRequests(pendingRequestsRef.current, "Connection lost; reconnect and retry.");
    clearPendingSession();
    // A reconnect's first roster is a baseline. Do not ring for work that
    // finished while this browser was disconnected.
    agentTurnCompletionTrackerRef.current?.reset();
    gitNeedsReloadRef.current = true;
    if (fileViewRef.current) fileDiffNeedsReloadRef.current = true;
    creatingSessionWorkspaceIDsRef.current.clear();
    setCreatingWorkspaceIDs(new Set());
    creatingSessionKindRef.current = null;
    setCreatingSessionKind(null);
    appStateRef.current.attachedSession = null;
    focusedSessionRef.current = null;
    setFocusedSessionID(null);
    setAttachedSession(null);
    setTerminalReadySession(null);
    sentTerminalSizeRef.current = null;
    batcherRef.current?.reset();
    snapshotPendingRef.current = true;
    recoveryApplyingRef.current = false;
    pendingAtomicStateRef.current = null;
    stagedRecoveryOutputRef.current = [];
    recoveryAnchorRef.current = null;
    setConnectionStatus({ message: "Reconnecting…", online: false });
    if (connectionOnlineRef.current) announceFeedback("Reconnecting…", "pending");
    connectionOnlineRef.current = false;
  }, [announceFeedback, cancelSubscription, clearMaintenanceTimeout, clearPendingSession]);

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
      recoveryAnchorRef.current = null;
      snapshotPendingRef.current = true;
      recoveryApplyingRef.current = false;
      pendingAtomicStateRef.current = null;
      stagedRecoveryOutputRef.current = [];
      batcher.reset();
      terminal.reset();
      if (!sessionID) return;
      appStateRef.current.attachedSession = null;
      focusedSessionRef.current = null;
      setFocusedSessionID(null);
      setAttachedSession(null);
      setTerminalReadySession(null);
      if (!beginSubscription(sessionID, terminal)) {
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
        if (followsOutput) {
          terminal.scrollToBottom();
          setHasNewTerminalOutput(false);
        } else {
          setHasNewTerminalOutput(true);
        }
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
    const onTerminalScroll = () => {
      scheduleWebGLForScroll();
      const buffer = terminal.buffer.active;
      if (buffer.viewportY >= buffer.baseY) setHasNewTerminalOutput(false);
    };
    const scrollSubscription = terminal.onScroll(onTerminalScroll);
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
      // Invalidate callbacks before disposing xterm. A queued write callback
      // may run after this cleanup when a tab is replaced or the component is
      // unmounted; the subscription generation then makes it harmless.
      subscriptionCleanupRef.current(false);
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
  }, [beginSubscription, request, requestSessionFocus, scheduleRemoteResize, scheduleTerminalFit, sendInput]);

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
    // A new Session starts with a clean output affordance. If output arrives
    // while the user is already in its terminal, the renderer callback below
    // decides whether the prompt is needed from the actual viewport position.
    setHasNewTerminalOutput(false);
  }, [activeSession]);

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
    localStorage.setItem(storageKeys.expandedTasks, JSON.stringify([...expandedTasks]));
  }, [expandedTasks]);

  useEffect(() => {
    localStorage.setItem(storageKeys.expandedProjects, JSON.stringify([...expandedProjects]));
  }, [expandedProjects]);

  useEffect(() => {
    localStorage.setItem(storageKeys.tasksCollapsed, JSON.stringify(tasksCollapsed));
  }, [tasksCollapsed]);

  useEffect(() => {
    localStorage.setItem(storageKeys.fontFamily, fontFamily);
    localStorage.setItem(storageKeys.fontSize, String(fontSize));
  }, [fontFamily, fontSize]);

  useEffect(() => {
    localStorage.setItem(storageKeys.titleTemplate, titleTemplate);
  }, [titleTemplate]);

  useEffect(() => {
    let connection;
    let cancelled = false;
    tokenReady.then(() => {
      if (cancelled) return;
      connection = new WarrenConnection({
        url: webSocketURL(),
        token: runtime.token,
        clientID: runtime.clientID,
        getToken: () => runtime.token,
        capabilities: ["roster-delta", ...agentCapabilities],
        onMessage: event => messageHandlerRef.current(event),
        onState: state => connectionStateHandlerRef.current(state),
      });
      connectionRef.current = connection;
      connection.start();
    });
    return () => {
      cancelled = true;
      subscriptionCleanupRef.current(false);
      connection?.stop();
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

  const toggleTask = useCallback(taskID => {
    setExpandedTasks(previous => {
      const next = new Set(previous);
      if (next.has(taskID)) next.delete(taskID);
      else next.add(taskID);
      return next;
    });
  }, []);

  const toggleTasksCollapsed = useCallback(() => {
    setTasksCollapsed(previous => !previous);
  }, []);

  const focusTask = useCallback(taskID => {
    setTasksCollapsed(false);
    setExpandedTasks(previous => new Set([...previous, taskID]));
    requestAnimationFrame(() => {
      const section = document.getElementById(`task-${taskID}`);
      section?.scrollIntoView({
        behavior: window.matchMedia("(prefers-reduced-motion: reduce)").matches
          ? "auto"
          : "smooth",
        block: "center",
      });
      requestAnimationFrame(() => {
        const target = section?.querySelector(".project-toggle-main");
        if (target instanceof HTMLElement) target.focus({ preventScroll: true });
      });
    });
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
    // Context-menu events do not consistently move focus (notably on
    // trackpads and touch adapters). Claim the invoking control before the
    // menu mounts so its focus is restored after Escape, outside-click, or an
    // action closes the surface.
    const focusableSelector = [
      "button:not(:disabled)",
      "a[href]",
      "input:not(:disabled)",
      "select:not(:disabled)",
      "textarea:not(:disabled)",
      '[tabindex]:not([tabindex="-1"])',
    ].join(",");
    const nearestFocusable = node => {
      if (!(node instanceof HTMLElement)) return null;
      if (node.matches(focusableSelector)) return node;
      return node.closest(focusableSelector) || node.querySelector(focusableSelector);
    };
    const target = nearestFocusable(event.target)
      || nearestFocusable(event.currentTarget)
      || (document.activeElement instanceof HTMLElement ? document.activeElement : null);
    target?.focus({ preventScroll: true });
    setContextMenu({ x: event.clientX, y: event.clientY, items });
  }, []);

  const newTask = useCallback(() => {
    setRenameDialog({
      kind: "task-create",
      title: "New task",
      message: "Create a work context that can contain workspaces from several projects.",
      fieldLabel: "Task name",
      initialValue: "",
      confirmLabel: "Create",
    });
  }, []);

  const renameTask = useCallback(task => {
    setRenameDialog({
      kind: "task",
      id: task.id,
      title: "Rename task",
      message: "Choose a new name for this task.",
      fieldLabel: "Task name",
      initialValue: task.name || "",
      confirmLabel: "Rename",
    });
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
    if (!dialog || renamePendingRef.current) return false;
    const trimmed = value.trim();
    if (!trimmed) return false;
    const operation = { kind: dialog.kind, id: dialog.id || "" };
    renameOperationRef.current = operation;
    renamePendingRef.current = true;
    setRenamePending(true);
    const label = dialog.kind === "session" ? "Session" : dialog.kind === "workspace" ? "Workspace" : dialog.kind === "project" ? "Project" : "Task";
    const succeed = () => {
      if (renameOperationRef.current !== operation) return;
      renameOperationRef.current = null;
      renamePendingRef.current = false;
      setRenamePending(false);
      setRenameDialog(null);
      announceFeedback(`${label} renamed`, "success");
    };
    const showError = detail => {
      if (renameOperationRef.current !== operation) return;
      renameOperationRef.current = null;
      renamePendingRef.current = false;
      setRenamePending(false);
      setConnectionStatus({ message: detail, online: false });
      setRenameDialog(current => current ? { ...current, error: detail || `Unable to rename ${label.toLowerCase()}.` } : current);
      announceFeedback(detail || `Unable to rename ${label.toLowerCase()}.`, "error");
    };
    let sent = false;
    if (dialog.kind === "task-create") {
      sent = request("task.create", { name: trimmed }, task => {
        if (task?.id) {
          setTasksCollapsed(false);
          setExpandedTasks(previous => new Set([...previous, task.id]));
        }
        succeed();
      }, showError);
    } else if (dialog.kind === "task") {
      sent = request("task.rename", { id: dialog.id, name: trimmed }, succeed, showError);
    } else if (dialog.kind === "project") {
      sent = request("project.rename", { id: dialog.id, name: trimmed }, succeed, showError);
    } else if (dialog.kind === "workspace") {
      sent = request("workspace.rename", { id: dialog.id, name: trimmed }, succeed, showError);
    } else if (dialog.kind === "session") {
      sent = request("session.rename", { id: dialog.id, title: trimmed }, succeed, showError);
    }
    if (!sent) showError("Not connected");
    return sent;
  }, [announceFeedback, renameDialog, request]);

  const toggleTaskPin = useCallback(task => {
    request("task.pin", { id: task.id, pinned: !task.pinned }, null, detail => {
      setConnectionStatus({ message: detail, online: false });
      setEmptyOverride({ loading: false, message: detail });
    });
  }, [request]);

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
    if (worktreeImportInFlightRef.current) return;
    const token = { projectID: project.id, sequence: Date.now() };
    worktreeLoadRequestRef.current = token;
    setWorktreeImportDialog({
      project,
      candidates: [],
      selectedPaths: [],
      loading: true,
      error: "",
    });
    const sent = request("project.worktrees", { project: project.id }, result => {
      if (worktreeLoadRequestRef.current !== token) return;
      worktreeLoadRequestRef.current = null;
      const candidates = Array.isArray(result) ? result : [];
      setWorktreeImportDialog(current => current?.project.id === project.id
        ? { ...current, candidates, loading: false, error: "" }
        : current);
    }, detail => {
      if (worktreeLoadRequestRef.current !== token) return;
      worktreeLoadRequestRef.current = null;
      setWorktreeImportDialog(current => current?.project.id === project.id
        ? { ...current, loading: false, error: detail || "Unable to read Git worktrees." }
        : current);
    });
    if (!sent) {
      if (worktreeLoadRequestRef.current === token) worktreeLoadRequestRef.current = null;
      setWorktreeImportDialog(current => current?.project.id === project.id
        ? { ...current, loading: false, error: "The daemon is not connected. Reconnect and try again." }
        : current);
    }
  }, [request]);

  const closeWorktreeImport = useCallback(() => {
    worktreeLoadRequestRef.current = null;
    // Closing the dialog does not cancel a Host-side import. Keep the
    // duplicate-submission gate until that request settles, otherwise a quick
    // reopen can submit the same paths twice while the first import is still
    // being processed.
    if (!worktreeImportInFlightRef.current) {
      worktreeImportRequestRef.current = null;
    }
    setWorktreeImportDialog(null);
  }, []);

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
    if (!current || !current.selectedPaths.length || worktreeImportInFlightRef.current) return;
    worktreeImportInFlightRef.current = true;
    const token = { projectID: current.project.id, sequence: Date.now() };
    worktreeImportRequestRef.current = token;
    worktreeLoadRequestRef.current = null;
    setWorktreeImportDialog(previous => previous ? { ...previous, loading: true, error: "" } : previous);
    const sent = request("project.worktrees.import", {
      project: current.project.id,
      paths: current.selectedPaths,
    }, () => {
      if (worktreeImportRequestRef.current !== token) return;
      worktreeImportRequestRef.current = null;
      worktreeImportInFlightRef.current = false;
      setWorktreeImportDialog(previous => previous?.project.id === current.project.id ? null : previous);
    }, detail => {
      if (worktreeImportRequestRef.current !== token) return;
      worktreeImportRequestRef.current = null;
      worktreeImportInFlightRef.current = false;
      setWorktreeImportDialog(previous => previous?.project.id === current.project.id
          ? { ...previous, loading: false, error: detail || "Unable to import selected worktrees." }
          : previous);
    });
    if (!sent) {
      if (worktreeImportRequestRef.current === token) worktreeImportRequestRef.current = null;
      worktreeImportInFlightRef.current = false;
      setWorktreeImportDialog(previous => previous?.project.id === current.project.id
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

  const deleteTask = useCallback(task => {
    setDeleteDialog({
      kind: "task",
      id: task.id,
      title: "Delete task?",
      message: `“${task.name}” will be removed. Its workspaces and sessions will remain available under Projects.`,
      confirmLabel: "Delete",
    });
  }, []);

  const taskContextMenu = useCallback((event, task) => {
    showContextMenu(event, taskMenuItems(task, {
      togglePin: toggleTaskPin,
      rename: renameTask,
      delete: deleteTask,
    }));
  }, [deleteTask, renameTask, showContextMenu, toggleTaskPin]);

  const projectContextMenu = useCallback((event, project) => {
    showContextMenu(event, projectMenuItems(project, {
      togglePin: toggleProjectPin,
      rename: renameProject,
      openImport: openWorktreeImport,
      toggleAutoImport: toggleProjectAutoImport,
    }));
  }, [openWorktreeImport, renameProject, showContextMenu, toggleProjectAutoImport, toggleProjectPin]);

  const workspaceContextMenu = useCallback((event, workspace) => {
    const showError = detail => {
      setConnectionStatus({ message: detail, online: false });
      setEmptyOverride({ loading: false, message: detail });
    };
    showContextMenu(event, workspaceMenuItems(workspace, {
      togglePin: toggleWorkspacePin,
      rename: renameWorkspace,
      tasks: catalog.tasks,
      attach: (value, task) => request("task.attach", { id: task.id, workspace: value.id }, null, showError),
      detach: value => request("task.detach", { id: value.task, workspace: value.id }, null, showError),
    }));
  }, [catalog.tasks, renameWorkspace, request, showContextMenu, toggleWorkspacePin]);

  const deleteSession = useCallback(session => {
    const label = sessionDisplayTitle(session) || session.id;
    setDeleteDialog({
      kind: "session",
      id: session.id,
      title: "Delete session?",
      message: `“${label}” will be terminated and removed from Warren.`,
      confirmLabel: "Delete",
    });
  }, []);

  const confirmDelete = useCallback(() => {
    const dialog = deleteDialog;
    if (!dialog || deletePendingRef.current) return false;
    const operation = { kind: dialog.kind, id: dialog.id || "" };
    deleteOperationRef.current = operation;
    deletePendingRef.current = true;
    setDeletePending(true);
    const label = dialog.kind === "session" ? "Session" : dialog.kind === "task" ? "Task" : "Item";
    const succeed = () => {
      if (deleteOperationRef.current !== operation) return;
      deleteOperationRef.current = null;
      deletePendingRef.current = false;
      setDeletePending(false);
      setDeleteDialog(null);
      announceFeedback(`${label} deleted`, "success");
    };
    const failed = detail => {
      if (deleteOperationRef.current !== operation) return;
      deleteOperationRef.current = null;
      deletePendingRef.current = false;
      setDeletePending(false);
      const message = detail || `Unable to delete ${label.toLowerCase()}.`;
      setConnectionStatus({ message, online: false });
      setDeleteDialog(current => current ? { ...current, error: message } : current);
      announceFeedback(message, "error");
    };
    if (dialog.kind === "task") {
      const sent = request("task.remove", { id: dialog.id }, succeed, failed);
      if (!sent) failed("Not connected");
      return sent;
    }
    // Capture the endpoint identity at mutation start. A delayed response
    // from an old Host must clear only that Host's local queue and draft.
    const endpointIdentity = webSocketURL();
    const queueKey = agentQueueKey(endpointIdentity, dialog.id);
    const sent = request("session.delete", { id: dialog.id }, () => {
      if (deleteOperationRef.current !== operation) return;
      agentMessageRequestRef.current.delete(queueKey);
      delete agentQueueRef.current[queueKey];
      setAgentQueueBySession(previous => {
        if (!(dialog.id in previous)) return previous;
        const next = { ...previous };
        delete next[dialog.id];
        return next;
      });
      removeAgentDraft(localStorage, endpointIdentity, dialog.id);
      // If the deleted session owns the visible terminal, clear it right away
      // instead of waiting for the next roster broadcast. The empty-state
      // overlay is opaque, but the xterm surface behind it must not keep the
      // last agent screen.
      const current = appStateRef.current;
      if (current.activeSession === dialog.id || current.attachedSession === dialog.id) {
        cancelSubscription();
        current.activeSession = null;
        current.attachedSession = null;
        setActiveSession(null);
        setAttachedSession(null);
        terminalRef.current?.clear();
        batcherRef.current?.reset();
        recoveryAnchorRef.current = null;
        setTerminalReadySession(null);
        snapshotPendingRef.current = false;
        recoveryApplyingRef.current = false;
        pendingAtomicStateRef.current = null;
        stagedRecoveryOutputRef.current = [];
      }
      succeed();
    }, failed);
    if (!sent) failed("Not connected");
    return sent;
  }, [announceFeedback, cancelSubscription, deleteDialog, request]);

  const sessionContextMenu = useCallback((event, session) => {
    showContextMenu(event, sessionMenuItems(session, {
      togglePin: toggleSessionPin,
      rename: renameSession,
      search: openTerminalSearch,
      delete: deleteSession,
    }));
  }, [deleteSession, openTerminalSearch, renameSession, showContextMenu, toggleSessionPin]);

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

  const updateOpenAISetting = useCallback((key, value) => {
    const params = { [key]: value };
    request("settings.put", params, applyRemoteSettings);
    if (key === "openaiBaseURL") setOpenaiBaseURL(value);
    if (key === "openaiModel") setOpenaiModel(value);
    if (key === "openaiTitleEnabled") setOpenaiTitleEnabled(value);
  }, [applyRemoteSettings, request]);

  const updateAgentCompletionSound = useCallback(enabled => {
    const next = Boolean(enabled);
    setAgentCompletionSoundEnabled(next);
    saveAgentCompletionSoundEnabled(next);
  }, []);

  const previewAgentCompletionSound = useCallback(() => {
    void agentCompletionSoundRef.current?.play();
  }, []);

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
    const sessionID = selectedSession.id;

    loadRecentAgentEvents(sessionID, 100).then(cached => {
      if (cached && cached.length > 0) {
        setAgentStateBySession(prev => {
          const cur = prev[sessionID] || {};
          if (!cur.events || cur.events.length === 0) {
            return { ...prev, [sessionID]: { ...cur, events: cached } };
          }
          return prev;
        });
      }
    });

    const state = agentStateBySession[sessionID];
    getAgentMaxSequence(sessionID, state?.epoch).then(lastSeq => {
      const params = { session: sessionID, wireOptions: { omitFields: ["output"] } };
      if (lastSeq > 0) params.lastSequence = String(lastSeq);
      if (state?.epoch) params.epoch = String(state.epoch);
      request("agent.subscribe", params, result => {
        const epoch = result?.snapshot?.epoch;
        const gapEvents = result?.gapEvents || [];
        if (gapEvents.length > 0) {
          saveAgentEvents(sessionID, epoch, gapEvents);
          setAgentStateBySession(prev => {
            const cur = prev[sessionID] || {};
            return {
              ...prev,
              [sessionID]: {
                ...cur,
                epoch: epoch || cur.epoch,
                events: mergeAgentEvents(cur.events || [], gapEvents),
              },
            };
          });
        } else if (result?.snapshot?.sequence > lastSeq && (result.snapshot.sequence - lastSeq) > 0) {
          request("agent.history", {
            session: sessionID,
            since: String(lastSeq + 1),
            before: String(result.snapshot.sequence + 1),
            limit: "100",
            maxOutput: "4096",
          }, page => {
            if (page?.events?.length > 0) {
              saveAgentEvents(sessionID, page.epoch || epoch, page.events);
              setAgentStateBySession(prev => {
                const cur = prev[sessionID] || {};
                return {
                  ...prev,
                  [sessionID]: {
                    ...cur,
                    events: mergeAgentEvents(cur.events || [], page.events),
                  },
                };
              });
            }
          });
        }
      });
    });

    if (!state?.historyLoaded && !state?.historyLoading && !state?.historyError) {
      loadAgentHistory(sessionID);
    }
  }, [agentViewActive, selectedSession?.id]);

  return (
    <>
      <TransientFeedback feedback={feedback} />
      <h1 className="visually-hidden">Warren</h1>
      <div className={`app${drawerOpen ? " drawer-open" : ""}${gitOpen && !isMobile ? " git-panel-open" : ""}`} hidden={settingsOpen}>
        <a className="skip-link" href="#main">Skip to content</a>
        <Sidebar
          catalog={catalog}
          activeWorkspace={selectedWorkspaceID}
          expandedTasks={expandedTasks}
          expandedProjects={expandedProjects}
          tasksCollapsed={tasksCollapsed}
          tabsForWorkspace={workspaceID => workspaceTabs(catalog, workspaceID)}
          connection={connectionStatus}
          onToggleTasksCollapsed={toggleTasksCollapsed}
          onToggleTask={toggleTask}
          onFocusTask={focusTask}
          onNewTask={newTask}
          onToggleProject={toggleProject}
          onChooseWorkspace={chooseWorkspace}
          onOpenWorkspace={openWorkspace}
          onNewSessionInWorkspace={workspaceID => openWorkspace(workspaceID, true)}
          onNewSession={() => createSession("shell")}
          onOpenSettings={openSettings}
          onTaskContextMenu={taskContextMenu}
          onProjectContextMenu={projectContextMenu}
          onWorkspaceContextMenu={workspaceContextMenu}
          onMoveProject={moveProject}
          onMoveWorkspace={moveWorkspace}
          onBeginProjectDrag={beginProjectDrag}
          onEndProjectDrag={endProjectDrag}
          creatingWorkspaceIDs={creatingWorkspaceIDs}
          creatingSession={Boolean(creatingSessionKind)}
        />
        <button type="button" className="backdrop" aria-label="Close navigation" onClick={() => setDrawerOpen(false)} />
        <main id="main" className="main" ref={mainRef} tabIndex={-1}>
          {isMobile ? (
            <MobileShell
              workspace={selectedWorkspace}
              projectName={selectedWorkspace ? catalog.projectsByID.get(selectedWorkspace.project)?.name || "" : ""}
              tabs={tabs}
              activeSession={activeSession}
              connection={connectionStatus}
              agentSession={isAgentSession ? selectedSession : null}
              agentViewActive={agentViewActive}
              onAttachSession={attachSession}
              onToggleAgentView={toggleAgentView}
              onOpenMenu={() => setDrawerOpen(true)}
              onOpenSearch={() => setSearchOpen(true)}
              onToggleGit={() => setGitOpenState(open => !open)}
              gitActive={gitOpen}
              onNewSession={() => setSessionSheetOpen(true)}
              onOpenSessionMenu={openSessionMenu}
              onSessionContextMenu={sessionContextMenu}
              pendingSessionID={pendingSessionID}
              creatingSession={Boolean(creatingSessionKind)}
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
                pendingSessionID={pendingSessionID}
                creatingSession={Boolean(creatingSessionKind)}
              />
              <PresetBar presets={visiblePresets} onCreateSession={createSession} creatingKind={creatingSessionKind} />
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
                {isAgentSession && (agentViewActive ? (
                  <button type="button" className="pane-action" onClick={() => toggleAgentView("terminal")}>
                    Terminal
                  </button>
                ) : (
                  <button
                    type="button"
                    className={`pane-action${agentStateBySession[selectedSession?.id]?.status?.attention ? " has-attention" : ""}`}
                    onClick={() => toggleAgentView("agent")}
                    title={agentStateBySession[selectedSession?.id]?.status?.attention ? "Agent needs attention" : "Switch to Agent"}
                  >
                    Agent{agentStateBySession[selectedSession?.id]?.status?.attention ? " •" : ""}
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
                turn={agentStateBySession[selectedSession.id]?.turn || selectedSession.agentTurn || null}
                events={selectedAgentEvents}
                status={agentStateBySession[selectedSession.id]?.status || null}
                onSend={sendAgentMessageFromView}
                onRequestControl={() => requestSessionFocus(true)}
                onOpenTerminal={() => toggleAgentView("terminal")}
                ready={agentViewReady}
                hasControl={focusedSessionID === selectedSession.id}
                endpointIdentity={webSocketURL()}
                capabilities={sessionAgentCapabilities(catalog, agentCapabilitiesRef.current, selectedSession.id)}
                actionError={agentActionError}
                onCancel={() => cancelAgentTurn(selectedSession.id)}
                onSendNow={(text, attachments) => sendAgentMessageNow(selectedSession.id, text, attachments)}
                onInteraction={value => respondAgentInteraction(selectedSession.id, value)}
                onUploadAttachments={uploadAgentAttachments}
                queueItems={agentQueueBySession[selectedSession.id] || []}
                onQueueEdit={(itemID, text, attachments) => editAgentQueueItem(selectedSession.id, itemID, text, attachments)}
                onQueueDelete={itemID => deleteAgentQueueItem(selectedSession.id, itemID)}
                onQueueMoveToFront={itemID => moveAgentQueueItemToFront(selectedSession.id, itemID)}
                onQueueReorder={(itemID, beforeID) => reorderAgentQueueItem(selectedSession.id, itemID, beforeID)}
                onQueueRetry={itemID => retryAgentQueueItem(selectedSession.id, itemID)}
                hasMore={Boolean(agentStateBySession[selectedSession.id]?.historyHasMore)}
                loadingMore={Boolean(agentStateBySession[selectedSession.id]?.historyLoading)}
                historyError={agentStateBySession[selectedSession.id]?.historyError || ""}
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
            {!agentViewActive
              && hasNewTerminalOutput
              && terminalReadySession === activeSession
              && !(gitOpen && fileView)
              && (
              <button
                type="button"
                className="terminal-new-output"
                aria-label="Jump to latest output"
                onPointerDown={event => event.stopPropagation()}
                onClick={event => {
                  event.stopPropagation();
                  terminalRef.current?.scrollToBottom();
                  setHasNewTerminalOutput(false);
                }}
              >
                ↓ New output
              </button>
            )}
            {!(gitOpen && fileView) && (
            <EmptyTerminal
              activeWorkspace={selectedWorkspaceID}
              activeSession={activeSession}
              terminalReadySession={terminalReadySession}
              tabCount={tabs.length}
              projectCount={catalog.projects.length}
              override={emptyOverride}
              onNewSession={() => createSession("shell")}
            />
            )}
          </section>
          {!agentViewActive && <MobileKeys onInput={sendInput} />}
        </main>
        {gitOpen && (!isMobile || !fileView) && (
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
        openaiBaseURL={openaiBaseURL}
        openaiModel={openaiModel}
        openaiTitleEnabled={openaiTitleEnabled}
        agentCompletionSoundEnabled={agentCompletionSoundEnabled}
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
        onOpenAISettingChange={updateOpenAISetting}
        onAgentCompletionSoundChange={updateAgentCompletionSound}
        onPreviewAgentCompletionSound={previewAgentCompletionSound}
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
          pendingKind={creatingSessionKind}
        />
      )}
      <WorktreeImportDialog
        dialog={worktreeImportDialog}
        onClose={closeWorktreeImport}
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
          error={renameDialog.error || ""}
          pending={renamePending}
          onCancel={() => { if (!renamePendingRef.current) setRenameDialog(null); }}
          onConfirm={confirmRename}
        />
      )}
      {deleteDialog && (
        <ConfirmationDialog
          title={deleteDialog.title}
          message={deleteDialog.message}
          confirmLabel={deleteDialog.confirmLabel}
          error={deleteDialog.error || ""}
          pending={deletePending}
          onCancel={() => { if (!deletePendingRef.current) setDeleteDialog(null); }}
          onConfirm={confirmDelete}
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

function gitActionLabel(method) {
  return {
    "git.pull": "Pull",
    "git.push": "Push",
    "git.checkout": "Branch switch",
    "git.commit": "Commit",
    "git.pr.create": "Pull request",
  }[method] || "Git action";
}
