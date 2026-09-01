import { useEffect, useLayoutEffect, useRef, useState } from "react";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";

import {
  agentDraftMaximumBytes,
  copyAgentText,
  copyableAgentText,
  formatAgentModel,
  groupAgentEvents,
  loadAgentDraft,
  normalizeAgentEventType,
  projectAgentEvents,
  removeAgentDraft,
  saveAgentDraft,
  validateAgentAttachment,
} from "./agent.js";
import { sessionDisplayTitle } from "./title.js";

// Keep the active-work cue light and human. The phrase is deliberately
// provider-neutral so the composer never grows a second Session/Model rail.
const AGENT_WORKING_PHRASES = [
  "Fermenting…",
  "Fiddle-faddling…",
  "Booping…",
  "Pondering…",
  "Whirring…",
  "Tinkering…",
  "Conjuring…",
  "Mulling…",
  "Warming up…",
  "Plotting…",
  "Wiggling…",
  "Riffing…",
  "Hatching…",
  "Stirring…",
  "Percolating…",
  "Polishing…",
];
export function AgentView({
  session,
  turn = null,
  events = [],
  status = null,
  onSend,
  onRequestControl = () => {},
  onOpenTerminal,
  ready = true,
  hasControl = true,
  hasMore = false,
  loadingMore = false,
  onLoadMore = () => {},
  endpointIdentity = "default",
  capabilities = [],
  actionError = "",
  onCancel = () => {},
  onSendNow = () => {},
  onInteraction = () => {},
  onUploadAttachments = async () => { throw new Error("Attachments are unavailable"); },
  onEditResend = null,
  queueItems = [],
  onQueueEdit = () => {},
  onQueueDelete = () => {},
  onQueueMoveToFront = () => {},
  onQueueReorder = () => {},
  onQueueRetry = () => {},
}) {
  const listRef = useRef(null);
  const inputRef = useRef(null);
  const loadMoreRef = useRef(null);
  const pinnedSessionIDRef = useRef(null);
  const pinToBottomRef = useRef(true);
  const anchorElementRef = useRef(null);
  const anchorOffsetRef = useRef(null);
  const skipFollowRef = useRef(false);
  const [draft, setDraft] = useState(() => loadAgentDraft(localStorage, endpointIdentity, session?.id));
  const [showQueue, setShowQueue] = useState(false);
  const [attachments, setAttachments] = useState([]);
  const [uploadingAttachments, setUploadingAttachments] = useState(false);
  const [copyStatus, setCopyStatus] = useState("");
  const [submitError, setSubmitError] = useState("");
  const [draftWarning, setDraftWarning] = useState("");
  const [workingPhraseIndex, setWorkingPhraseIndex] = useState(0);
  const workingTurnKeyRef = useRef(null);
  const blocks = projectAgentEvents(events.filter(event => !isHiddenAgentEvent(event)));
  const displayTitle = sessionDisplayTitle(session) || "Agent";
  const agentStatus = status || session?.agentStatus || null;
  const attention = agentStatus?.attention || null;
  const modelLabel = formatAgentModel(agentModel(session, events));
  const canCompose = ready && hasControl && canSendForStatus(agentStatus);
  const disabledReason = agentInputDisabledReason({ ready, hasControl, status: agentStatus });
  const canInterrupt = agentStatus?.activity === "working" && capabilities.includes("agent-interrupt-v1");
  const canInteract = capabilities.includes("agent-interactions-v1");
  const canUpload = capabilities.includes("agent-attachments-v1");
  const showWorking = shouldShowWorking(agentStatus, events);
  const workingTurnKey = `${session?.id || ""}:${agentTurnKey(turn || session?.agentTurn, events)}`;
  const showInputMeta = Boolean(disabledReason || queueItems.length > 0 || canInterrupt);
  const lastUserEvent = [...events].reverse().find(isUserAgentEvent) || null;
  const lastUserEventKey = lastUserEvent ? `${lastUserEvent.id || ""}:${lastUserEvent.seq || ""}` : "";

  const copyMessage = async event => {
    const value = copyableAgentText(event);
    if (!value) return;
    const copied = await copyAgentText(value);
    setCopyStatus(copied ? "Copied" : "Copy failed");
    setTimeout(() => setCopyStatus(""), 1600);
  };
  const editAndResend = value => {
    if (onEditResend) onEditResend(value);
    else setDraft(value);
    inputRef.current?.focus();
  };

  useEffect(() => {
    setDraft(loadAgentDraft(localStorage, endpointIdentity, session?.id));
    setAttachments([]);
    setUploadingAttachments(false);
    setSubmitError("");
    setDraftWarning("");
    setWorkingPhraseIndex(0);
    workingTurnKeyRef.current = null;
  }, [endpointIdentity, session?.id]);

  useEffect(() => {
    if (workingTurnKeyRef.current === null) {
      workingTurnKeyRef.current = workingTurnKey;
      return;
    }
    if (workingTurnKeyRef.current === workingTurnKey) return;
    workingTurnKeyRef.current = workingTurnKey;
    // Change the copy at a turn boundary only. A continuously changing label
    // competes with the transcript and makes one turn feel like many.
    setWorkingPhraseIndex(index => (index + 1) % AGENT_WORKING_PHRASES.length);
  }, [workingTurnKey]);

  useEffect(() => {
    const value = String(draft || "");
    const timer = setTimeout(() => {
      if (new TextEncoder().encode(value).length <= agentDraftMaximumBytes) {
        saveAgentDraft(localStorage, endpointIdentity, session?.id, value);
      }
    }, 250);
    return () => clearTimeout(timer);
  }, [draft, endpointIdentity, session?.id]);

  useEffect(() => {
    const flush = () => saveAgentDraft(localStorage, endpointIdentity, session?.id, draft);
    window.addEventListener("pagehide", flush);
    return () => window.removeEventListener("pagehide", flush);
  }, [draft, endpointIdentity, session?.id]);

  useLayoutEffect(() => {
    const list = listRef.current;
    if (!list) return;
    // A fresh agent view (new session, history reset, or re-entering agent
    // mode) should open at the latest messages instead of the top. History
    // pages can arrive after mount, so keep the pin until content actually
    // overflows; after that, loading older pages never yanks the reader.
    if (pinnedSessionIDRef.current !== session?.id || events.length === 0) {
      pinnedSessionIDRef.current = session?.id;
      pinToBottomRef.current = true;
    }
    if (!pinToBottomRef.current) return;
    if (list.scrollHeight - list.clientHeight > 8) {
      list.scrollTop = list.scrollHeight;
      pinToBottomRef.current = false;
    }
  }, [events.length, session?.id]);

  const loadEarlier = () => {
    // Older pages are inserted above the first existing message, so after
    // the response the scroll position must be adjusted to keep that message
    // exactly where the reader left it. The button never moves (new content
    // lands below it), so anchoring it would push the current conversation
    // down and flip the viewport onto the older page.
    const list = listRef.current;
    if (!list) return;
    const anchor = loadMoreRef.current ? list.children[1] : list.children[0];
    if (!anchor) return;
    anchorElementRef.current = anchor;
    anchorOffsetRef.current = anchor.getBoundingClientRect().top - list.getBoundingClientRect().top;
    onLoadMore();
  };

  useLayoutEffect(() => {
    // Wait for the loading flag to clear so the measurement runs against the
    // page that actually landed; while the button is disabled its offset is
    // unchanged and consuming the anchor there would lose it.
    if (anchorElementRef.current === null || loadingMore) return;
    const list = listRef.current;
    const anchor = anchorElementRef.current;
    const target = anchorOffsetRef.current;
    anchorElementRef.current = null;
    anchorOffsetRef.current = null;
    if (!list || !anchor.isConnected) return;
    if (target === null || target === undefined) return;
    const current = anchor.getBoundingClientRect().top - list.getBoundingClientRect().top;
    const delta = current - target;
    if (delta) {
      list.scrollTop += delta;
      // Keep the follow-bottom effect from overriding the anchor on the same
      // render when the remaining content is barely taller than the viewport.
      skipFollowRef.current = true;
    }
  }, [events.length, hasMore, loadingMore]);

  useEffect(() => {
    const list = listRef.current;
    if (!list || pinToBottomRef.current) return;
    if (skipFollowRef.current) {
      skipFollowRef.current = false;
      return;
    }
    const followsBottom = list.scrollHeight - list.scrollTop - list.clientHeight < 160;
    if (followsBottom) list.scrollTop = list.scrollHeight;
  }, [events.length]);

  const addAttachments = files => {
    const values = Array.from(files || []).filter(file => file && typeof file.name === "string");
    if (!values.length) return;
    setAttachments(previous => [
      ...previous,
      ...values.map(file => {
        const validation = validateAgentAttachment(file);
        return {
          file,
          status: validation.ok ? "selected" : "failed",
          progress: 0,
          error: validation.ok ? "" : validation.error,
        };
      }),
    ]);
  };

  const removeAttachment = index => {
    if (uploadingAttachments) return;
    setAttachments(previous => previous.filter((_, itemIndex) => itemIndex !== index));
  };

  const retryAttachment = index => {
    if (uploadingAttachments) return;
    setAttachments(previous => previous.map((item, itemIndex) => (
      itemIndex === index ? { ...item, status: "selected", progress: 0, error: "" } : item
    )));
  };

  const submit = async (sendNow = false) => {
    if (!ready) return;
    const value = draft.trim();
    if (!value) return;
    if (!canCompose || uploadingAttachments) return;
    if (attachments.length > 0 && (!canUpload || attachments.some(item => item.status === "failed"))) return;
    setSubmitError("");
    setUploadingAttachments(attachments.length > 0);
    let refs = [];
    try {
      refs = attachments.length > 0
        ? await onUploadAttachments(
          attachments.map(item => item.file),
          (index, progress, error = "") => {
            setAttachments(previous => previous.map((item, itemIndex) => (
              itemIndex === index
                ? { ...item, status: error ? "failed" : progress >= 1 ? "ready" : "uploading", progress, error }
                : item
            )));
          },
        )
        : [];
    } catch (error) {
      const reason = String(error?.message || error || "Upload failed");
      setAttachments(previous => previous.map(item => ({ ...item, status: "failed", error: reason })));
      setSubmitError(reason);
      setUploadingAttachments(false);
      return;
    }
    try {
      if (sendNow) await onSendNow(value, refs);
      else onSend(value, refs);
    } catch (error) {
      // The atomic Send now request owns the replacement's local queue item.
      // Keep the draft/attachments visible here so a failed request can be
      // retried without silently discarding the user's input.
      const reason = String(error?.message || error || "Send failed");
      setSubmitError(reason);
      setUploadingAttachments(false);
      return;
    }
    setDraft("");
    setDraftWarning("");
    removeAgentDraft(localStorage, endpointIdentity, session?.id);
    setAttachments([]);
    inputRef.current?.focus();
    setUploadingAttachments(false);
  };

  return (
    <div
      className="agent-view"
      onPointerDown={event => event.stopPropagation()}
      onClick={event => event.stopPropagation()}
      onDragOver={event => {
        if (canUpload && event.dataTransfer?.types?.includes("Files")) event.preventDefault();
      }}
      onDrop={event => {
        if (!canUpload) return;
        event.preventDefault();
        addAttachments(event.dataTransfer?.files);
      }}
    >
      <div ref={listRef} className="agent-events" aria-label="Agent conversation">
        {hasMore && (
          <button
            ref={loadMoreRef}
            type="button"
            className="agent-load-more"
            onClick={loadEarlier}
            disabled={loadingMore}
          >
            {loadingMore ? "Loading…" : "Load earlier messages"}
          </button>
        )}
        {blocks.length === 0 ? (
          <div className="agent-empty">
            <div className="agent-empty-mark" aria-hidden="true">✦</div>
            <div className="agent-empty-title">What can I help you with?</div>
            <div className="agent-empty-hint">Messages, tool calls and results will appear here.</div>
          </div>
        ) : (
          blocks.map((block, index) => (
            // Usage remains in the protocol for future analytics, but it is
            // intentionally not a conversation row on mobile or Web.
            block.kind === "usage"
              ? null
              : <AgentBlock
                key={blockKindKey(block, index)}
                block={block}
                onInteraction={onInteraction}
                canInteract={canInteract}
                onCopy={copyMessage}
                onEditResend={editAndResend}
                isLastUser={Boolean(lastUserEventKey && block.event && `${block.event.id || ""}:${block.event.seq || ""}` === lastUserEventKey)}
              />
          ))
        )}
      </div>
      {attention && <AgentAttention attention={attention} onOpenTerminal={onOpenTerminal} />}
      {showWorking && (
        <div className="agent-working" role="status" aria-live="polite">
          <span className="agent-working-shimmer">{AGENT_WORKING_PHRASES[workingPhraseIndex]}</span>
          <span className="agent-working-provider">{displayTitle}</span>
        </div>
      )}
      {(actionError || submitError) && (
        <div className="agent-action-error" role="alert">{actionError || submitError}</div>
      )}
      {draftWarning && (
        <div className="agent-draft-warning" role="status">{draftWarning}</div>
      )}
      {copyStatus && <div className="agent-copy-status" role="status" aria-live="polite">{copyStatus}</div>}
      {showQueue && (
        <AgentQueuePanel
          items={queueItems}
          onClose={() => setShowQueue(false)}
          onEdit={onQueueEdit}
          onDelete={onQueueDelete}
          onMoveToFront={onQueueMoveToFront}
          onReorder={onQueueReorder}
          onRetry={onQueueRetry}
        />
      )}
      {ready ? (
        <form
          className="agent-input"
          onSubmit={event => {
            event.preventDefault();
            void submit();
          }}
        >
          <div className="agent-input-surface">
            {attachments.length > 0 && (
              <div className="agent-attachment-list" aria-label="Selected attachments">
                {attachments.map((item, index) => (
                  <span key={`${item.file.name}-${item.file.lastModified}-${index}`} className={`agent-attachment-chip ${item.status}`}>
                    <span>{item.file.name}</span>
                    {item.status === "uploading" && <small>{Math.round(item.progress * 100)}%</small>}
                    {item.status === "failed" && <><small title={item.error}>Failed</small><button type="button" onClick={() => retryAttachment(index)}>Retry</button></>}
                    {!uploadingAttachments && <button type="button" onClick={() => removeAttachment(index)} aria-label={`Remove ${item.file.name}`}>×</button>}
                  </span>
                ))}
              </div>
            )}
            <div className="agent-input-row">
              <textarea
                ref={inputRef}
                value={draft}
                onChange={event => {
                  const value = event.target.value;
                  setDraft(value);
                  setDraftWarning(
                    new TextEncoder().encode(value).length > agentDraftMaximumBytes
                      ? "Draft is too large to save locally."
                      : "",
                  );
                }}
                onKeyDown={event => {
                  if (event.key === "Enter" && !event.shiftKey && !event.isComposing) {
                    event.preventDefault();
                    void submit();
                  }
                }}
                onPaste={event => {
                  if (!canUpload || !event.clipboardData?.files?.length) return;
                  addAttachments(event.clipboardData.files);
                }}
                onFocus={() => {
                  if (!hasControl && ready && canSendForStatus(agentStatus)) onRequestControl();
                }}
                placeholder="Message…"
                aria-label="Message"
                rows={1}
                enterKeyHint="send"
                autoCapitalize="off"
                autoCorrect="off"
                autoComplete="off"
                spellCheck="false"
                readOnly={!ready || !canSendForStatus(agentStatus)}
                disabled={uploadingAttachments}
              />
            </div>
            <div className="agent-input-controls" aria-label="Agent details">
              <label className="agent-attachment-picker" title="Attach files">
                <span aria-hidden="true">＋</span>
                <input
                  type="file"
                  multiple
                  onChange={event => {
                    addAttachments(event.target.files);
                    event.target.value = "";
                  }}
                  aria-label="Attach files"
                  disabled={!canUpload || uploadingAttachments}
                />
              </label>
              {modelLabel && <code>{modelLabel}</code>}
              <button type="submit" className="agent-send" disabled={!draft.trim() || !canCompose || uploadingAttachments} aria-label="Send">
                <SendIcon />
              </button>
            </div>
          </div>
          {showInputMeta && (
            <div className="agent-input-meta" aria-label="Agent controls">
              {disabledReason && (
                <span className={`agent-input-reason${!hasControl ? " locked" : ""}`}>
                  {!hasControl && <LockIcon />}
                  {disabledReason}
                </span>
              )}
              {queueItems.length > 0 && (
                <button type="button" className="agent-queue-button" onClick={() => setShowQueue(true)}>
                  Queue {queueItems.length}
                </button>
              )}
              {canInterrupt && (
                <>
                  <button type="button" className="agent-cancel-button" onClick={onCancel}>Cancel</button>
                  {draft.trim() && <button type="button" className="agent-send-now-button" disabled={uploadingAttachments} onClick={() => { void submit(true); }}>Send now</button>}
                </>
              )}
            </div>
          )}
        </form>
      ) : (
        <div className="agent-starting">
          {session?.kind === "opencode"
            ? "OpenCode is starting — enter the first prompt in Terminal, then send messages from here."
            : "Agent is starting — finish first-time setup in Terminal, then send messages from here."}
        </div>
      )}
    </div>
  );
}

function AgentAttention({ attention, onOpenTerminal }) {
  const kind = attention.kind || "warning";
  const reason = String(attention.reason || "").trim().toLowerCase();
  const labels = {
    input: ["text-bubble", "Question · Reply in the composer to continue."],
    approval: ["shield-check", "Permission · Review the request in Terminal."],
    warning: ["triangle-exclamation", "Check the Agent in Terminal."],
  };
  const [icon, fallback] = labels[kind] || labels.warning;
  const reasonLabel = {
    question: "Question · Reply in the composer to continue.",
    permission: "Permission · Review the request in Terminal.",
    approval: "Permission · Review the request in Terminal.",
    stalled: "No progress detected · Check the Agent in Terminal.",
    no_progress: "No progress detected · Check the Agent in Terminal.",
    no_progress_detected: "No progress detected · Check the Agent in Terminal.",
    unexpectedabort: "Unexpected interruption · Check the Agent in Terminal.",
    unexpected_abort: "Unexpected interruption · Check the Agent in Terminal.",
  }[reason] || fallback;
  return (
    <div className={`agent-attention ${kind}`} role="status">
      <span className="agent-attention-icon" aria-hidden="true">{icon === "shield-check" ? "✓" : icon === "text-bubble" ? "↵" : "!"}</span>
      <span className="agent-attention-copy">
        <strong>Needs attention</strong>
        <span>{reasonLabel}</span>
      </span>
      {kind === "approval" && onOpenTerminal && (
        <button type="button" className="agent-attention-action" onClick={onOpenTerminal}>
          Terminal
        </button>
      )}
    </div>
  );
}

function canSendForStatus(status) {
  if (!status) return true;
  const activity = String(status.activity || "").toLowerCase();
  if (["failed", "stalled", "exited", "unknown"].includes(activity)) return false;
  // An input/question attention is intentionally answerable in the composer;
  // approval and warning attention must be reviewed in the Terminal.
  return !status.attention || status.attention.kind === "input";
}

function shouldShowWorking(status, events) {
  if (status?.activity !== "working") return false;
  const visible = (events || []).filter(event => !isHiddenAgentEvent(event));
  const last = visible.at(-1);
  if (!last) return true;
  // A completed assistant message is the stronger visual signal. Hosts can
  // publish a trailing working status while the final transcript event is
  // still settling, so do not leave a cue under already-finished prose.
  const type = normalizeAgentEventType(last.type);
  const role = normalizeAgentEventType(last.role);
  const assistant = type === "assistant" || role === "assistant";
  return !(assistant && String(last.content || "").trim());
}

function agentTurnID(turn, events) {
  const explicit = typeof turn === "object" ? turn?.id : turn;
  const explicitID = Number(explicit);
  if (Number.isSafeInteger(explicitID) && explicitID > 0) return explicitID;
  for (const event of [...(events || [])].reverse()) {
    const eventID = Number(event?.turn);
    if (Number.isSafeInteger(eventID) && eventID > 0) return eventID;
  }
  return 0;
}

// A few older Hosts publish agent events without a turn field. Use the
// explicit turn when available, then the latest user event as the stable
// boundary for a new turn. Do not use the latest arbitrary event: reasoning
// and tool deltas would make the working copy change several times per turn.
function agentTurnKey(turn, events) {
  const explicit = agentTurnID(turn, []);
  if (explicit) return `turn:${explicit}`;
  const values = Array.isArray(events) ? events : [];
  const latestUser = [...values].reverse().find(isUserAgentEvent);
  if (latestUser) {
    const eventTurn = Number(latestUser.turn);
    if (Number.isSafeInteger(eventTurn) && eventTurn > 0) return `turn:${eventTurn}`;
    const identity = String(latestUser.id || latestUser.seq || latestUser.timestamp || "").trim();
    if (identity) return `user:${identity}`;
  }
  const eventTurn = agentTurnID(null, values);
  return eventTurn ? `turn:${eventTurn}` : "unknown";
}

function agentInputDisabledReason({ ready, hasControl, status }) {
  if (!ready) return "Agent is starting in Terminal.";
  if (!hasControl) return "Terminal control is held by another client.";
  const activity = String(status?.activity || "").toLowerCase();
  if (status?.attention?.kind === "approval") return "Approval is required in Terminal.";
  if (status?.attention && status.attention.kind !== "input") return "Check the Agent in Terminal.";
  switch (activity) {
  case "stalled": return "Agent is stalled.";
  case "failed": return "Agent failed.";
  case "exited": return "Agent has exited.";
  case "unknown": return "Agent status is unavailable.";
  default: return "";
  }
}

function agentModel(session, events = []) {
  const model = String(session?.agentModel || [...events].reverse().find(event => event.model)?.model || "").trim();
  return model || "";
}

function isHiddenAgentEvent(event) {
  const type = String(event?.type || "").toLowerCase().replaceAll("-", "_");
  return type === "usage"
    || type === "token_usage"
    || type === "token_count"
    || type.endsWith("_usage")
    || type === "system_instructions"
    || (event?.usage && String(event?.content || "").trim().toLowerCase() === "token usage");
}

function isUserAgentEvent(event) {
  return normalizeAgentEventType(event?.type) === "user"
    || normalizeAgentEventType(event?.role) === "user";
}

function blockKindKey(block, index) {
  const id = block.call?.id || block.event?.id || block.event?.seq || block.call?.seq;
  const sequence = block.call?.seq || block.event?.seq;
  // Provider IDs identify logical parts, not always individual events (an
  // OpenCode part can emit several deltas). Include the normalized sequence
  // so a fallback or repeated provider ID can never collide in React.
  return `${block.kind}-${id || "event"}-${sequence || index}`;
}

function AgentBlock({ block, onInteraction = () => {}, onCopy = () => {}, onEditResend = () => {}, isLastUser = false, canInteract = false }) {
  switch (block.kind) {
  case "structured":
    return <StructuredAgentBlock event={block.event} onInteraction={onInteraction} canInteract={canInteract} />;
  case "user":
  case "assistant": {
    const event = block.event;
    const interrupted = isInterrupted(event);
    if (isUserAgentEvent(event)) {
      return (
        <div className={`agent-message user${interrupted ? " interrupted" : ""}`}>
          <div className="agent-bubble">
            <MarkdownContent value={event.content || ""} />
          </div>
          <div className="agent-message-actions">
            <button type="button" onClick={() => onCopy(event)} aria-label="Copy message" title="Copy message">
              <CopyIcon />
            </button>
            {isLastUser && (
              <button type="button" onClick={() => onEditResend(event.content || "")} aria-label="Edit and resend message" title="Edit and resend message">
                <EditIcon />
              </button>
            )}
          </div>
          <div className="agent-message-meta">
            {interrupted && <span className="agent-interrupted-tag">Interrupted</span>}
            {formatMessageTime(event.timestamp)}
          </div>
        </div>
      );
    }
    return (
      <div className={`agent-message assistant${interrupted ? " interrupted" : ""}`}>
        <MarkdownContent value={event.content || ""} />
        <div className="agent-message-actions">
          <button type="button" onClick={() => onCopy(event)} aria-label="Copy message" title="Copy message">
            <CopyIcon />
          </button>
        </div>
        <div className="agent-message-meta">
          {interrupted && <span className="agent-interrupted-tag">Interrupted</span>}
          {event.durationMs ? formatDuration(event.durationMs) : ""}
          {event.durationMs && event.timestamp ? " · " : ""}
          {formatMessageTime(event.timestamp)}
        </div>
      </div>
    );
  }
  case "activity_group":
    return <ActivityGroup block={block} />;
  case "tool_output": {
    const event = block.event;
    return (
      <div className={`agent-tool-card ${event.toolStatus || "success"}`}>
        <div className="agent-tool-head">
          <span className="agent-tool-chevron open" aria-hidden="true"><ChevronRightIcon /></span>
          <span className="agent-tool-name">{displayToolName(event.toolName)}</span>
          <span className="agent-tool-status">{statusText(event.toolStatus)}</span>
        </div>
        <ToolOutputBody event={event} />
      </div>
    );
  }
  case "system_instructions":
    return null;
  case "usage":
    return null;
  case "error":
    return (
      <div className="agent-error">
        <pre className="agent-body">{block.event.error || block.event.content || ""}</pre>
      </div>
    );
  case "attachment":
    return (
      <div className="agent-attachment">
        <pre className="agent-body">{block.event.content || ""}</pre>
      </div>
    );
  case "system":
    return (
      <div className="agent-system">
        {block.event.content || "System"}
        {block.event.durationMs ? ` · ${formatDuration(block.event.durationMs)}` : ""}
      </div>
    );
  default:
    return (
      <details className="agent-unknown">
        <summary>Unknown event</summary>
        <pre className="agent-body">{JSON.stringify(block.event, null, 2)}</pre>
      </details>
    );
  }
}

function StructuredAgentBlock({ event, onInteraction = () => {}, canInteract = false }) {
  const type = String(event?.type || "").trim().toLowerCase().replaceAll("-", "_");
  const payload = event?.payload && typeof event.payload === "object" ? event.payload : {};
  const state = String(payload.state || "").toLowerCase();
  const title = payload.title || payload.label || payload.name || type.replaceAll("_", " ");
  const [submitting, setSubmitting] = useState(false);
  const [answers, setAnswers] = useState({});
  const [customAnswers, setCustomAnswers] = useState({});
  const requestID = String(payload.requestId || "").trim();
  const pending = canInteract && (state === "pending" || state === "submitting") && requestID;
  const questions = type === "question"
    ? (Array.isArray(payload.questions) ? payload.questions : []).map((question, index) => ({
      ...question,
      id: String(question?.id || `question-${index}`),
      prompt: String(question?.prompt || question?.title || "Question"),
      selection: String(question?.selection || "single").toLowerCase() === "multiple" ? "multiple" : "single",
      required: question?.required !== false,
      allowCustom: Boolean(question?.allowCustom),
      options: Array.isArray(question?.options) ? question.options : [],
    }))
    : [];
  const permissionOptions = type === "permission" && Array.isArray(payload.options) ? payload.options : [];
  const submitResponse = response => {
    if (!pending || submitting || state !== "pending") return;
    setSubmitting(true);
    try {
      const result = onInteraction({ requestId: requestID, kind: type, response });
      // App-level request adapters return a Promise when the Host rejects the
      // response. Restore the card so a transient failure is retryable.
      Promise.resolve(result).catch(() => setSubmitting(false));
    } catch {
      setSubmitting(false);
    }
  };
  const toggleQuestionOption = (question, optionID) => {
    if (!pending || submitting || state !== "pending") return;
    setAnswers(previous => {
      const selected = new Set(previous[question.id] || []);
      if (question.selection === "multiple") {
        if (selected.has(optionID)) selected.delete(optionID);
        else selected.add(optionID);
      } else {
        selected.clear();
        selected.add(optionID);
      }
      return { ...previous, [question.id]: [...selected] };
    });
  };
  const submitQuestionAnswers = () => {
    const normalized = {};
    const custom = {};
    for (const question of questions) {
      const selected = Array.isArray(answers[question.id]) ? answers[question.id] : [];
      const customValue = String(customAnswers[question.id] || "").trim();
      if (selected.length > 0 || customValue) normalized[question.id] = selected;
      if (customValue) custom[question.id] = customValue;
    }
    submitResponse({ answers: normalized, ...(Object.keys(custom).length ? { customAnswers: custom } : {}) });
  };
  const questionsValid = questions.every(question => {
    if (!question.required) return true;
    return (answers[question.id] || []).length > 0 || String(customAnswers[question.id] || "").trim().length > 0;
  });
  const cancelInteraction = () => submitResponse({ cancelled: true });
  const selectPermission = option => submitResponse({ decision: option.id || option.value });
  const optionID = option => String(option?.id || option?.value || "");

  useEffect(() => {
    if (state !== "pending") setSubmitting(false);
  }, [state]);

  const interactionPending = pending && state === "pending";
  const isSelected = (questionID, id) => (answers[questionID] || []).includes(id);

  const questionContent = questions.map(question => (
    <fieldset className="agent-question" key={question.id}>
      <legend>{question.prompt}</legend>
      <div className="agent-structured-options" role={question.selection === "multiple" ? "group" : "radiogroup"} aria-label={question.prompt}>
        {question.options.map((option, index) => {
          const id = optionID(option) || `option-${index}`;
          const selected = isSelected(question.id, id);
          return (
            <button
              key={`${question.id}-${id}`}
              type="button"
              className={selected ? "selected" : ""}
              onClick={() => toggleQuestionOption(question, id)}
              disabled={!interactionPending}
              aria-pressed={selected}
            >
              <span>{option.label || option.id || option.value || id}</span>
              {option.description && <small>{option.description}</small>}
            </button>
          );
        })}
      </div>
      {question.allowCustom && (
        <input
          className="agent-question-custom"
          value={customAnswers[question.id] || ""}
          onChange={event => setCustomAnswers(previous => ({ ...previous, [question.id]: event.target.value }))}
          placeholder="Custom answer"
          aria-label={`${question.prompt} custom answer`}
          disabled={!interactionPending}
        />
      )}
    </fieldset>
  ));

  const permissionContent = permissionOptions.map((option, index) => {
    const id = optionID(option) || `option-${index}`;
    return (
      <button key={id} type="button" onClick={() => selectPermission(option)} disabled={!interactionPending}>
        <span>{option.label || option.id || option.value || id}</span>
        {option.description && <small>{option.description}</small>}
      </button>
    );
  });

  const responseControls = interactionPending && canInteract && (
    <div className="agent-structured-actions">
      {type === "question" && <button type="button" onClick={submitQuestionAnswers} disabled={submitting || !questionsValid}>Submit</button>}
      {(type === "question" || type === "permission") && <button type="button" onClick={cancelInteraction} disabled={submitting}>Cancel</button>}
    </div>
  );

  return (
    <section className={`agent-structured agent-structured-${type}`} aria-label={title}>
      <div className="agent-structured-head">
        <span className="agent-structured-icon" aria-hidden="true">{structuredIcon(type)}</span>
        <strong>{title}</strong>
        <span className={`agent-structured-state ${state}`}>{structuredStateLabel(state)}</span>
      </div>
      {payload.description && <p className="agent-structured-description">{payload.description}</p>}
      {pending && type === "question" && questionContent}
      {pending && type === "permission" && permissionContent.length > 0 && (
        <div className="agent-structured-options" role="group" aria-label={`${title} options`}>{permissionContent}</div>
      )}
      {responseControls}
      {!canInteract && (type === "question" || type === "permission") && (state === "pending" || state === "submitting") && (
        <p className="agent-structured-readonly" role="status">This Host does not support responding here.</p>
      )}
      {(type === "plan" || type === "todo") && Array.isArray(payload.items) && (
        <ul className="agent-structured-items">
          {payload.items.map((item, index) => (
            <li key={item.id || index} className={item.state || "pending"}>
              <span aria-hidden="true">{item.state === "completed" ? "✓" : "○"}</span>
              {item.label || item.title || item.prompt || ""}
            </li>
          ))}
        </ul>
      )}
      {type !== "question" && type !== "permission" && type !== "plan" && type !== "todo" && (payload.summary || payload.detail || payload.name) && (
        <p className="agent-structured-summary">{payload.summary || payload.detail || payload.name}</p>
      )}
    </section>
  );
}

function structuredIcon(type) {
  return {
    question: "?",
    permission: "✓",
    plan: "☷",
    todo: "☑",
    activity: "•",
    plugin: "◆",
    subagent: "◇",
    attachment: "⌕",
  }[type] || "•";
}

function structuredStateLabel(state) {
  return {
    pending: "Pending",
    submitting: "Submitting…",
    resolved: "Resolved",
    completed: "Completed",
    cancelled: "Cancelled",
    canceled: "Cancelled",
    failed: "Failed",
    in_progress: "In progress",
  }[state] || (state ? state.replaceAll("_", " ") : "Details");
}

function AgentQueuePanel({ items, onClose, onEdit, onDelete, onMoveToFront, onReorder, onRetry }) {
  const [editingID, setEditingID] = useState(null);
  const [editingText, setEditingText] = useState("");
  const [deleteID, setDeleteID] = useState(null);
  const [draggingID, setDraggingID] = useState(null);

  const beginEdit = item => {
    setEditingID(item.id);
    setEditingText(item.text);
    setDeleteID(null);
  };

  const saveEdit = item => {
    const value = editingText.trim();
    if (value) onEdit(item.id, value, item.attachments || []);
    setEditingID(null);
    setEditingText("");
  };

  return (
    <div className="agent-queue-panel" role="dialog" aria-modal="true" aria-label="Queued messages">
      <div className="agent-queue-panel-head"><strong>Queued messages</strong><button type="button" onClick={onClose} aria-label="Close queue">×</button></div>
      {items.length === 0 ? <p>No queued messages.</p> : items.map(item => (
        <div
          className={`agent-queue-item ${item.status || "queued"}`}
          key={item.id}
          draggable={item.status !== "sending"}
          onDragStart={() => setDraggingID(item.id)}
          onDragEnd={() => setDraggingID(null)}
          onDragOver={event => {
            if (draggingID && draggingID !== item.id && item.status !== "sending") event.preventDefault();
          }}
          onDrop={event => {
            event.preventDefault();
            if (draggingID && draggingID !== item.id && item.status !== "sending") onReorder(draggingID, item.id);
            setDraggingID(null);
          }}
        >
          {editingID === item.id ? (
            <textarea
              className="agent-queue-edit"
              value={editingText}
              onChange={event => setEditingText(event.target.value)}
              aria-label="Edit queued message"
              autoFocus
            />
          ) : (
            <div className="agent-queue-item-text">{item.text}</div>
          )}
          {item.attachments?.length > 0 && (
            <div className="agent-queue-item-attachments" aria-label="Queued attachments">
              {item.attachments.map(attachment => <span key={attachment.attachmentId}>{attachment.name || attachment.attachmentId}</span>)}
            </div>
          )}
          {item.failureReason && <div className="agent-queue-error">{item.failureReason}</div>}
          <div className="agent-queue-actions">
            {editingID === item.id ? (
              <>
                <button type="button" onClick={() => saveEdit(item)} disabled={!editingText.trim()}>Save</button>
                <button type="button" onClick={() => setEditingID(null)}>Cancel</button>
              </>
            ) : item.status === "failed" && <button type="button" onClick={() => onRetry(item.id)}>Retry</button>}
            {item.status !== "sending" && editingID !== item.id && (
              <button type="button" className="agent-icon-button" onClick={() => beginEdit(item)} aria-label="Edit queued message" title="Edit queued message">
                <EditIcon />
              </button>
            )}
            {item.status !== "sending" && editingID !== item.id && <button type="button" onClick={() => onMoveToFront(item.id)}>Move to front</button>}
            {item.status !== "sending" && editingID !== item.id && (deleteID === item.id ? (
              <>
                <span className="agent-queue-delete-confirm">Delete?</span>
                <button type="button" onClick={() => { onDelete(item.id); setDeleteID(null); }}>Confirm</button>
                <button type="button" onClick={() => setDeleteID(null)}>Keep</button>
              </>
            ) : <button type="button" onClick={() => setDeleteID(item.id)}>Delete</button>)}
            {item.status === "sending" && <span aria-live="polite">Sending…</span>}
          </div>
        </div>
      ))}
    </div>
  );
}

function ActivityGroup({ block }) {
  const { reasoning, tools, order } = block;
  const [open, setOpen] = useState(false);
  const status = groupStatus(tools);
  let step = 0;
  const toolItems = order.filter(item => item.kind === "tool");
  return (
    <div className={`agent-activity-group ${status}`}>
      <button type="button" className="agent-activity-head" onClick={() => setOpen(!open)} aria-expanded={open}>
        <span className="agent-activity-title">{activityTitle(reasoning.length, tools.length)}</span>
        {!open && toolGroupSummary(tools) && <code className="agent-tool-summary">{toolGroupSummary(tools)}</code>}
        <span className="agent-tool-status">{statusText(status)}</span>
      </button>
      {open && (
        <div className="agent-activity-body">
          {order.map((item, index) => {
            if (item.kind === "reasoning") {
              step += 1;
              return (
                <div className="agent-reasoning-item" key={item.event.seq ?? index}>
                  {reasoning.length > 1 && (
                    <div className="agent-reasoning-item-label">Step {step}</div>
                  )}
                  <MarkdownContent value={item.event.content || ""} />
                </div>
              );
            }
            return null;
          })}
          {toolItems.length > 0 && (
            <div className="agent-tool-group">
              {toolItems.map((item, index) => (
                <ToolCard key={blockKindKey(item.block, index)} block={item.block} />
              ))}
            </div>
          )}
        </div>
      )}
    </div>
  );
}

function ToolCard({ block, defaultOpen = false }) {
  const call = block.call;
  const status = call.toolStatus || (block.outputs.length ? "success" : "running");
  const [open, setOpen] = useState(defaultOpen);
  const summary = toolDisplay(call, status);
  const isWebSearch = call.toolName === "web_search";
  const isShell = call.toolName === "Bash" || call.toolName === "shell";
  const shellCommand = isShell ? call.toolInput?.command : null;
  const isCommand = Boolean(
    shellCommand
    || call.toolName === "exec"
    || call.toolName === "Exec"
    || call.toolInput?.cmd
    || call.toolInput?.command,
  );
  const preview = shellCommand || summary;
  if (isCommand) {
    return (
      <div className={`agent-tool-card command ${status}`}>
        <code className="agent-tool-command">
          <span className="agent-tool-prompt">$ </span>
          {preview}
        </code>
        {!isWebSearch && <span className="agent-tool-status">{statusText(status)}</span>}
      </div>
    );
  }
  return (
    <div className={`agent-tool-card ${status}`}>
      <button type="button" className="agent-tool-head" onClick={() => setOpen(!open)} aria-expanded={open}>
        <span className={`agent-tool-chevron${open ? " open" : ""}`} aria-hidden="true"><ChevronRightIcon /></span>
        <span className="agent-tool-name">{displayToolName(call.toolName)}</span>
        {summary && <code className="agent-tool-summary">{summary}</code>}
        {!isWebSearch && <span className="agent-tool-status">{statusText(status)}</span>}
      </button>
      {open && (
        <div className="agent-tool-detail">
          {shellCommand ? (
            <pre className="agent-tool-code agent-tool-shell">
              <span className="agent-tool-prompt">$ </span>
              {shellCommand}
            </pre>
          ) : preview ? (
            <pre className="agent-tool-code">{preview}</pre>
          ) : (
            <span className="agent-tool-waiting">Waiting for output…</span>
          )}
          {call.files?.length > 0 && <FileList files={call.files} />}
        </div>
      )}
    </div>
  );
}

function activityTitle(reasoningCount, toolsCount) {
  const parts = [];
  if (reasoningCount > 0) parts.push(`Thinking × ${reasoningCount}`);
  if (toolsCount > 0) parts.push(`Tools × ${toolsCount}`);
  return parts.join(" · ") || "Activity";
}

function toolGroupSummary(items) {
  const first = items[0]?.call;
  if (!first) return "";
  const summary = toolSummary(first);
  if (summary) return summary;
  if (items.length > 1) {
    const second = items[1]?.call;
    if (second) return toolSummary(second);
  }
  return "";
}

function groupStatus(items) {
  const statuses = new Set(items.map(item => {
    const lastOutput = item.outputs.at(-1);
    return lastOutput?.toolStatus || item.call?.toolStatus || (item.outputs.length ? "success" : "running");
  }));
  if (statuses.has("error")) return "error";
  if (statuses.has("interrupted")) return "interrupted";
  if (statuses.has("running")) return "running";
  return "success";
}

function ToolOutputBody({ event }) {
  return (
    <div className="agent-tool-output">
      {event.error && <div className="agent-tool-error">{event.error}</div>}
      {event.files?.length > 0 && <FileList files={event.files} />}
    </div>
  );
}

function statusText(status) {
  switch (status) {
  case "error": return "Failed";
  case "interrupted": return "Interrupted";
  case "running": return "Running…";
  default: return "Completed";
  }
}

// A message was cut short by a user interruption. OpenCode reports this on the
// assistant event's stopReason; Claude Code emits a sentinel user message that
// begins with "[Request interrupted".
function isInterrupted(event) {
  if (!event) return false;
  if (event.stopReason === "interrupted") return true;
  const content = event.content || "";
  return /^\[Request interrupted/i.test(content.trim());
}

function displayToolName(name) {
  const names = {
    Bash: "Shell",
    shell: "Shell",
    Edit: "Edit file",
    Read: "Read file",
    Grep: "Search files",
    Glob: "Find files",
    WebSearch: "Web search",
    web_search: "Web search",
    ApplyPatch: "Apply patch",
    apply_patch: "Apply patch",
    Task: "Subagent",
    Write: "Write file",
  };
  return names[name] || name || "Tool";
}

function CopyIcon() {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <rect x="8" y="8" width="11" height="12" rx="2" />
      <path d="M16 8V6a2 2 0 0 0-2-2H7a2 2 0 0 0-2 2v9a2 2 0 0 0 2 2h1" />
    </svg>
  );
}

function EditIcon() {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d="m4 16.5-.8 4.3 4.3-.8L19 8.5a2.1 2.1 0 0 0-3-3z" />
      <path d="m14.5 7.5 2 2" />
    </svg>
  );
}

function SendIcon() {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" aria-hidden="true">
      <path d="M4 20.5 21 12 4 3.5l1.8 6.9 8.5 1.6-8.5 1.6z" />
    </svg>
  );
}

function LockIcon() {
  return (
    <svg className="agent-lock-icon" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.4" aria-hidden="true">
      <rect x="3.5" y="7" width="9" height="6" rx="1.2" />
      <path d="M5.5 7V5a2.5 2.5 0 0 1 5 0v2" />
    </svg>
  );
}

function ChevronRightIcon() {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" aria-hidden="true">
      <path d="m9 6 6 6-6 6" />
    </svg>
  );
}

function toolSummary(call) {
  const input = call.toolInput;
  if (!input || typeof input !== "object") return "";
  // Codex's exec tool wraps commands in a JavaScript payload; extract the
  // actual commands so the preview answers "what did it run?" instead of
  // showing nothing.
  if (typeof input.raw === "string") {
    const commands = extractExecCommands(input.raw);
    if (commands.length > 0) {
      const first = truncatePreview(commands[0]);
      return commands.length > 1
        ? `${first}  (+${commands.length - 1} more)`
        : first;
    }
    return input.raw.length > 200
      ? `${input.raw.slice(0, 200)}…`
      : input.raw;
  }
  if (typeof input.command === "string") return truncatePreview(input.command);
  if (typeof input.cmd === "string") return truncatePreview(input.cmd);
  if (typeof input.file_path === "string") return input.file_path;
  if (typeof input.path === "string") return input.path;
  if (typeof input.query === "string") return input.query;
  if (typeof input.pattern === "string") return input.pattern;
  if (typeof input.prompt === "string") return input.prompt;
  if (typeof input.url === "string") return input.url;
  if (Array.isArray(input.queries)) return input.queries.join(", ");
  return "";
}

function truncatePreview(value, maxLength = 140) {
  if (value.length <= maxLength) return value;
  return `${value.slice(0, maxLength)}…`;
}

function extractExecCommands(raw) {
  const commands = [];
  const pattern = /exec_command\(\s*\{\s*cmd\s*:\s*"(?:[^"\\]|\\.)*"/g;
  let match;
  while ((match = pattern.exec(raw))) {
    const body = match[0];
    const value = body.match(/cmd\s*:\s*"((?:[^"\\]|\\.)*)"/);
    if (value) {
      commands.push(value[1].replace(/\\(["\\])/g, "$1"));
    }
  }
  return commands;
}

function toolDisplay(call, status) {
  if (call.toolName !== "web_search") return toolSummary(call);
  const input = call.toolInput || {};
  const target = toolSummary(call);
  if (status === "running") return `Searching the web${target ? ` for ${target}` : ""}…`;
  if (status === "success") return `Searched the web for ${target || "results"}`;
  if (status === "error") return `Web search failed${target ? ` · ${target}` : ""}`;
  if (status === "interrupted") return `Web search interrupted${target ? ` · ${target}` : ""}`;
  return target || "Web search";
}

function basename(path) {
  const index = Math.max(path.lastIndexOf("/"), path.lastIndexOf("\\"));
  return index >= 0 ? path.slice(index + 1) : path;
}

function MarkdownContent({ value }) {
  return (
    <div className="agent-markdown">
      <ReactMarkdown remarkPlugins={[remarkGfm]}>{value}</ReactMarkdown>
    </div>
  );
}

function FileList({ files }) {
  return (
    <div className="agent-files">
      {files.map((file, index) => (
        <span className="agent-file" key={`${file}-${index}`}>{basename(file)}</span>
      ))}
    </div>
  );
}

function formatDuration(milliseconds) {
  const seconds = Math.round(milliseconds / 1000);
  if (seconds < 60) return `${seconds}s`;
  const minutes = Math.floor(seconds / 60);
  return `${minutes}m ${seconds % 60}s`;
}

function formatMessageTime(value) {
  if (!value) return "";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "";
  return date.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
}
