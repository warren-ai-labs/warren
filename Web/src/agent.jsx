import { memo, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";

import {
  agentDraftMaximumBytes,
  displayToolName,
  extractExecCommands,
  formatAgentModel,
  basename,
  formatFileList,
  groupAgentEvents,
  isCommandTool,
  latestAgentAction,
  loadAgentDraft,
  normalizeAgentEventType,
  projectAgentEvents,
  removeAgentDraft,
  saveAgentDraft,
  toolSummary,
  truncatePreview,
  validateAgentAttachment,
} from "./agent.js";
import { sessionDisplayTitle } from "./title.js";
import { useFocusTrap } from "./components.jsx";

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
  historyError = "",
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
  const [submitError, setSubmitError] = useState("");
  const [submitStatus, setSubmitStatus] = useState("");
  const [cancelPending, setCancelPending] = useState(false);
  const [draftWarning, setDraftWarning] = useState("");
  const [workingPhraseIndex, setWorkingPhraseIndex] = useState(0);
  const workingTurnKeyRef = useRef(null);
  const sessionIdentity = `${endpointIdentity}:${session?.id || ""}`;
  const sessionIdentityRef = useRef(sessionIdentity);
  const uploadGenerationRef = useRef(0);
  const submissionInFlightRef = useRef(false);
  const submitStatusTimerRef = useRef(null);
  // Render-time identity tracking closes the small gap before effects flush
  // after a tab switch. An upload started for the previous session can then
  // never mutate the new session's chips, draft, or error state.
  if (sessionIdentityRef.current !== sessionIdentity) {
    sessionIdentityRef.current = sessionIdentity;
    uploadGenerationRef.current += 1;
  }
  const blocks = useMemo(
    () => projectAgentEvents(events.filter(event => !isHiddenAgentEvent(event))),
    [events]
  );
  const displayTitle = sessionDisplayTitle(session) || "Agent";
  const agentStatus = status || session?.agentStatus || null;
  const attention = agentStatus?.attention || null;
  const rawModel = agentModel(session, events);
  const modelLabel = formatAgentModel(rawModel) || (session?.kind && session.kind !== "shell" ? displayTitle : "");
  const canCompose = ready && hasControl && canSendForStatus(agentStatus);
  const disabledReason = agentInputDisabledReason({ ready, hasControl, status: agentStatus });
  const canInterrupt = agentStatus?.activity === "working" && capabilities.includes("agent-interrupt-v1");
  const canInteract = capabilities.includes("agent-interactions-v1");
  const canUpload = capabilities.includes("agent-attachments-v1");
  const showWorking = shouldShowWorking(agentStatus, events);
  const latestAction = useMemo(() => latestAgentAction(events), [events]);
  const workingTurnKey = `${session?.id || ""}:${agentTurnKey(turn || session?.agentTurn, events)}`;
  const showInputMeta = Boolean(disabledReason || queueItems.length > 0 || canInterrupt);
  const lastUserEvent = useMemo(() => {
    for (let i = events.length - 1; i >= 0; i -= 1) {
      if (isUserAgentEvent(events[i])) return events[i];
    }
    return null;
  }, [events]);
  const lastUserEventKey = lastUserEvent ? `${lastUserEvent.id || ""}:${lastUserEvent.seq || ""}` : "";

  const editAndResend = value => {
    if (onEditResend) onEditResend(value);
    else setDraft(value);
    inputRef.current?.focus();
  };

  // Let short drafts breathe while keeping long prompts inside the raised
  // surface. Reset before measuring so deleting text shrinks the field again;
  // once the cap is reached, the textarea—not the page—owns the scroll.
  useLayoutEffect(() => {
    const input = inputRef.current;
    if (!input) return;
    input.style.height = "auto";
    const maxHeight = Number.parseFloat(window.getComputedStyle(input).maxHeight);
    const measuredHeight = input.scrollHeight;
    const nextHeight = Number.isFinite(maxHeight)
      ? Math.min(measuredHeight, maxHeight)
      : measuredHeight;
    input.style.height = `${nextHeight}px`;
    input.style.overflowY = measuredHeight > nextHeight ? "auto" : "hidden";
  }, [draft]);

  useEffect(() => {
    setDraft(loadAgentDraft(localStorage, endpointIdentity, session?.id));
    setAttachments([]);
    setUploadingAttachments(false);
    setSubmitError("");
    submissionInFlightRef.current = false;
    if (submitStatusTimerRef.current !== null) {
      clearTimeout(submitStatusTimerRef.current);
      submitStatusTimerRef.current = null;
    }
    setSubmitStatus("");
    setCancelPending(false);
    setDraftWarning("");
    setWorkingPhraseIndex(0);
    workingTurnKeyRef.current = null;
  }, [endpointIdentity, session?.id]);

  useEffect(() => () => {
    if (submitStatusTimerRef.current !== null) clearTimeout(submitStatusTimerRef.current);
  }, []);

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
  }, [events.length, queueItems.length, session?.id]);

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
  }, [events.length, queueItems.length]);

  const addAttachments = files => {
    const values = Array.from(files || []).filter(file => file && typeof file.name === "string");
    if (!values.length) return;
    const invalid = values.find(file => !validateAgentAttachment(file).ok);
    if (invalid) setSubmitError(validateAgentAttachment(invalid).error || "Attachment is not supported");
    else setSubmitError("");
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
    if (!value && attachments.length === 0) return;
    if (!canCompose || uploadingAttachments) return;
    if (attachments.length > 0 && (!canUpload || attachments.some(item => item.status === "failed"))) return;
    if (submissionInFlightRef.current) return;
    submissionInFlightRef.current = true;
    if (submitStatusTimerRef.current !== null) clearTimeout(submitStatusTimerRef.current);
    setSubmitStatus("sending");
    const uploadGeneration = uploadGenerationRef.current;
    const uploadSessionIdentity = sessionIdentity;
    const isCurrentUpload = () => (
      uploadGenerationRef.current === uploadGeneration
      && sessionIdentityRef.current === uploadSessionIdentity
    );
    setSubmitError("");
    setUploadingAttachments(attachments.length > 0);
    let refs = [];
    const selectedAttachments = attachments.map((item, index) => ({ item, index }));
    const pendingAttachments = selectedAttachments.filter(({ item }) => !(item.status === "ready" && item.reference));
    // Keep references by the original chip index as uploads complete. The
    // upload callback can report a later failure after earlier files have
    // already finished; preserving those opaque references lets Retry resume
    // the failed subset instead of re-sending bytes that the Host owns.
    const completedReferencesByIndex = new Map();
    try {
      const uploadedReferences = pendingAttachments.length > 0
        ? await onUploadAttachments(
          pendingAttachments.map(({ item }) => item.file),
          (index, progress, error = "", reference = null) => {
            if (!isCurrentUpload()) return;
            const originalIndex = pendingAttachments[index]?.index;
            if (originalIndex === undefined) return;
            if (reference) completedReferencesByIndex.set(originalIndex, reference);
            setAttachments(previous => previous.map((item, itemIndex) => (
              itemIndex === originalIndex
                ? {
                  ...item,
                  status: error ? "failed" : progress >= 1 ? "ready" : "uploading",
                  progress,
                  error,
                  ...(reference ? { reference } : {}),
                }
                : item
            )));
          },
        )
        : [];
      if (!isCurrentUpload()) {
        submissionInFlightRef.current = false;
        return;
      }
      let uploadedIndex = 0;
      refs = selectedAttachments
        .map(({ item }) => {
          if (item.status === "ready" && item.reference) return item.reference;
          const reference = uploadedReferences[uploadedIndex];
          uploadedIndex += 1;
          return reference;
        })
        .filter(Boolean);
      if (refs.length !== selectedAttachments.length) {
        throw new Error("Host returned invalid attachment references");
      }
    } catch (error) {
      if (!isCurrentUpload()) {
        submissionInFlightRef.current = false;
        return;
      }
      const reason = String(error?.message || error || "Upload failed");
      setAttachments(previous => previous.map((item, itemIndex) => (
        item.status === "ready" && item.reference
          ? item
          : completedReferencesByIndex.has(itemIndex)
            ? {
              ...item,
              status: "ready",
              progress: 1,
              error: "",
              reference: completedReferencesByIndex.get(itemIndex),
            }
            : { ...item, status: "failed", error: item.error || reason }
      )));
      setSubmitError(reason);
      setUploadingAttachments(false);
      submissionInFlightRef.current = false;
      setSubmitStatus("error");
      return;
    }
    try {
      const result = sendNow ? await onSendNow(value, refs) : await onSend(value, refs);
      if (result === false) throw new Error("Send unavailable");
    } catch (error) {
      if (!isCurrentUpload()) {
        submissionInFlightRef.current = false;
        return;
      }
      // The atomic Send now request owns the replacement's local queue item.
      // Keep the draft/attachments visible here so a failed request can be
      // retried without silently discarding the user's input.
      const reason = String(error?.message || error || "Send failed");
      setSubmitError(reason);
      setUploadingAttachments(false);
      submissionInFlightRef.current = false;
      setSubmitStatus("error");
      return;
    }
    if (!isCurrentUpload()) {
      submissionInFlightRef.current = false;
      return;
    }
    setDraft("");
    setDraftWarning("");
    removeAgentDraft(localStorage, endpointIdentity, session?.id);
    setAttachments([]);
    inputRef.current?.focus();
    setUploadingAttachments(false);
    submissionInFlightRef.current = false;
    const isWorking = agentStatus?.activity === "working";
    setSubmitStatus(isWorking ? "queued" : "sent");
    if (listRef.current) listRef.current.scrollTop = listRef.current.scrollHeight;
    submitStatusTimerRef.current = setTimeout(() => {
      submitStatusTimerRef.current = null;
      setSubmitStatus("");
    }, 1400);
  };

  const cancelTurn = () => {
    if (cancelPending) return;
    setCancelPending(true);
    let settled = false;
    const release = () => {
      if (settled) return;
      settled = true;
      setCancelPending(false);
    };
    try {
      const result = onCancel();
      if (result && typeof result.then === "function") {
        Promise.resolve(result).finally(release);
      }
    } catch {
      release();
    }
    setTimeout(release, 1200);
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
        {(hasMore || historyError) && (
          <button
            ref={loadMoreRef}
            type="button"
            className="agent-load-more"
            onClick={loadEarlier}
            disabled={loadingMore}
            aria-label={loadingMore
              ? "Loading earlier messages"
              : historyError
                ? "Retry loading earlier messages"
                : "Load earlier messages"}
          >
            {loadingMore
              ? "Loading…"
              : historyError
                ? `Couldn’t load earlier messages. Try again${historyError ? ` (${historyError})` : ""}`
                : "Load earlier messages"}
          </button>
        )}
        {blocks.length === 0 && queueItems.length === 0 ? (
          <div className="agent-empty">
            <div className="agent-empty-mark" aria-hidden="true">✦</div>
            <div className="agent-empty-title">What can I help you with?</div>
            <div className="agent-empty-hint">Messages, tool calls and results will appear here.</div>
          </div>
        ) : (
          <>
            {blocks.map((block, index) => (
              // Usage remains in the protocol for future analytics, but it is
              // intentionally not a conversation row on mobile or Web.
              block.kind === "usage"
                ? null
                : <AgentBlock
                  key={blockKindKey(block, index)}
                  block={block}
                  onInteraction={onInteraction}
                  canInteract={canInteract}
                  onEditResend={editAndResend}
                  isLastUser={Boolean(lastUserEventKey && block.event && `${block.event.id || ""}:${block.event.seq || ""}` === lastUserEventKey)}
                />
            ))}
            {queueItems.map(item => (
              <div key={item.id} className="agent-message user queued">
                <div className="agent-bubble">
                  <MarkdownContent value={item.text || ""} />
                  {item.attachments?.length > 0 && (
                    <div className="agent-queue-item-attachments" aria-label="Queued attachments">
                      {item.attachments.map((att, idx) => (
                        <span key={idx} className="agent-attachment-chip ready">
                          {att.name || "Attachment"}
                        </span>
                      ))}
                    </div>
                  )}
                </div>
                <div className="agent-message-meta">
                  <span className={`agent-queue-tag ${item.status || "queued"}`}>
                    {item.status === "sending" ? "Sending…" : item.status === "failed" ? "Failed" : "Queued"}
                  </span>
                  {item.failureReason && <span className="agent-queue-error-text">{item.failureReason}</span>}
                  <button
                    type="button"
                    className="agent-queue-inline-delete"
                    title="Remove queued message"
                    onClick={() => onQueueDelete && onQueueDelete(item.id)}
                  >
                    ×
                  </button>
                </div>
              </div>
            ))}
          </>
        )}
      </div>
      {attention && <AgentAttention attention={attention} onOpenTerminal={onOpenTerminal} onFocusComposer={() => inputRef.current?.focus()} />}
      {showWorking && (
        <div className="agent-working" role="status" aria-live="polite">
          <span className="agent-working-shimmer">{AGENT_WORKING_PHRASES[workingPhraseIndex]}</span>
          {latestAction && <span className="agent-working-action">{latestAction}</span>}
          <span className="agent-working-provider">{displayTitle}</span>
        </div>
      )}
      {(actionError || submitError) && (
        <div className="agent-action-error" role="alert">{actionError || submitError}</div>
      )}
      {submitStatus && (
        <div className={`agent-submit-status ${submitStatus}`} role="status" aria-live="polite">
          {submitStatus === "sending"
            ? (uploadingAttachments ? "Uploading…" : "Sending…")
            : submitStatus === "sent" ? "Sent" : submitStatus === "queued" ? "Queued for next turn" : "Send failed — retry"}
        </div>
      )}
      {draftWarning && (
        <div className="agent-draft-warning" role="status">{draftWarning}</div>
      )}
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
          {attachments.length > 0 && (
            <div className="agent-attachment-tray" aria-label="Selected attachments">
              {attachments.map((item, index) => (
                <span key={`${item.file.name}-${item.file.lastModified}-${index}`} className={`agent-attachment-chip ${item.status}`}>
                  <span className="agent-attachment-icon" aria-hidden="true">
                    {item.file.type?.startsWith("image/") ? "🖼️" : "📄"}
                  </span>
                  <span className="agent-attachment-name" title={item.file.name}>{item.file.name}</span>
                  {item.status === "uploading" && <small className="agent-attachment-progress">{Math.round(item.progress * 100)}%</small>}
                  {item.status === "ready" && <span className="agent-attachment-ready" aria-label="Ready">✓</span>}
                  {item.status === "failed" && (
                    <>
                      <small className="agent-attachment-failed" title={item.error}>Failed</small>
                      <button type="button" className="agent-attachment-retry" onClick={() => retryAttachment(index)}>Retry</button>
                    </>
                  )}
                  {!uploadingAttachments && (
                    <button type="button" className="agent-attachment-remove" onClick={() => removeAttachment(index)} aria-label={`Remove ${item.file.name}`}>×</button>
                  )}
                </span>
              ))}
            </div>
          )}
          <div className="agent-input-surface">
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
                disabled={uploadingAttachments || submitStatus === "sending"}
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
                  disabled={!canUpload || uploadingAttachments || submitStatus === "sending"}
                />
              </label>
              {modelLabel && <code className="agent-model-chip">{modelLabel}</code>}
              <button type="submit" className="agent-send" disabled={(!draft.trim() && attachments.length === 0) || !canCompose || uploadingAttachments || submitStatus === "sending"} aria-label="Send">
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
                <button type="button" className="agent-queue-button" onClick={() => setShowQueue(previous => !previous)}>
                  Queue {queueItems.length}
                </button>
              )}
              {canInterrupt && (
                <>
                  <button type="button" className="agent-cancel-button" disabled={cancelPending} onClick={cancelTurn}>{cancelPending ? "Cancelling…" : "Cancel"}</button>
                  {(draft.trim() || attachments.length > 0) && <button type="button" className="agent-send-now-button" disabled={uploadingAttachments || submitStatus === "sending"} onClick={() => { void submit(true); }}>Send now</button>}
                </>
              )}
            </div>
          )}
        </form>
      ) : (
        <div className="agent-starting">
          {session?.kind === "opencode"
            ? "OpenCode is starting — enter the first prompt in Terminal, then send messages from here."
            : session?.kind === "pi"
              ? "Pi is starting — enter the first prompt in Terminal, then send messages from here."
              : "Agent is starting — finish first-time setup in Terminal, then send messages from here."}
        </div>
      )}
    </div>
  );
}

function AgentAttention({ attention, onOpenTerminal, onFocusComposer }) {
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
      {kind === "input" && onFocusComposer && (
        <button type="button" className="agent-attention-action" onClick={onFocusComposer} title="Focus composer to reply">
          Reply ↵
        </button>
      )}
      {kind !== "input" && onOpenTerminal && (
        <button type="button" className="agent-attention-action" onClick={onOpenTerminal} title="Open Terminal to resolve">
          Terminal ↗
        </button>
      )}
    </div>
  );
}

function canSendForStatus(status) {
  if (!status) return true;
  const activity = String(status.activity || "").toLowerCase();
  if (["failed", "stalled", "exited", "unknown"].includes(activity)) return false;
  // An input/question attention is intentionally answerable in the composer.
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
  if (!hasControl) return "";
  const activity = String(status?.activity || "").toLowerCase();
  if (status?.attention?.kind === "approval") return "Permission required — review the request.";
  if (status?.attention && status.attention.kind !== "input") return "Agent needs your attention.";
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
  return type === "compaction"
    || type === "compact"
    || type === "compacted"
    || type === "usage"
    || type === "token_usage"
    || type === "token_count"
    || type.endsWith("_usage")
    || type === "system_instructions";
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

function AgentBlock({ block, onInteraction = () => {}, onEditResend = () => {}, isLastUser = false, canInteract = false }) {
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
          {isLastUser && (
            <div className="agent-message-actions">
              <button type="button" onClick={() => onEditResend(event.content || "")} aria-label="Edit and resend message" title="Edit and resend message">
                <EditIcon />
              </button>
            </div>
          )}
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
  const closeButtonRef = useRef(null);
  const onCloseRef = useRef(onClose);
  onCloseRef.current = onClose;
  const previousFocusRef = useRef(null);
  const panelRef = useRef(null);
  useFocusTrap(true, panelRef);

  useEffect(() => {
    const current = document.activeElement;
    previousFocusRef.current = typeof HTMLElement !== "undefined"
      && current instanceof HTMLElement
      && current !== document.body
      ? current
      : null;
    closeButtonRef.current?.focus();
    const handleKeyDown = event => {
      if (event.key !== "Escape") return;
      event.preventDefault();
      event.stopPropagation();
      onCloseRef.current();
    };
    const handlePointerDown = event => {
      if (event.target instanceof Element && event.target.closest(".agent-queue-button")) return;
      if (!panelRef.current?.contains(event.target)) onCloseRef.current();
    };
    window.addEventListener("keydown", handleKeyDown);
    window.addEventListener("pointerdown", handlePointerDown, true);
    return () => {
      window.removeEventListener("keydown", handleKeyDown);
      window.removeEventListener("pointerdown", handlePointerDown, true);
      const target = previousFocusRef.current;
      previousFocusRef.current = null;
      if (target?.isConnected) queueMicrotask(() => {
        if (target.isConnected) target.focus({ preventScroll: true });
      });
    };
  }, []);

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
    <div ref={panelRef} className="agent-queue-panel" role="dialog" aria-modal="true" aria-label="Queued messages">
      <div className="agent-queue-panel-head"><strong>Queued messages</strong><button ref={closeButtonRef} type="button" onClick={onClose} aria-label="Close queue">×</button></div>
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
        <span className={`agent-tool-chevron${open ? " open" : ""}`} aria-hidden="true"><ChevronRightIcon /></span>
        <span className="agent-activity-title">{activityTitle(reasoning.length, tools.length, tools)}</span>
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
              {coalesceToolBlocks(toolItems).map((group, index) => {
                if (group.blocks.length === 1) {
                  return <ToolCard key={blockKindKey(group.blocks[0], index)} block={group.blocks[0]} />;
                }
                return <CoalescedToolCard key={`coalesced-${group.toolName}-${index}`} group={group} />;
              })}
            </div>
          )}
        </div>
      )}
    </div>
  );
}

function coalesceToolBlocks(toolItems = []) {
  const groups = [];
  for (const item of toolItems) {
    const block = item.block;
    const name = (block.call?.toolName || "").toLowerCase();
    const prev = groups.at(-1);
    if (prev && prev.toolName === name) {
      prev.blocks.push(block);
    } else {
      groups.push({ toolName: name, blocks: [block] });
    }
  }
  return groups;
}

function CoalescedToolCard({ group, defaultOpen = false }) {
  const [open, setOpen] = useState(defaultOpen);
  const status = groupStatus(group.blocks);
  const count = group.blocks.length;
  const isCommand = isCommandTool(group.toolName);
  const name = isCommand ? `$ × ${count}` : `${displayToolName(group.toolName)} × ${count}`;
  const summaries = group.blocks
    .map(b => toolSummary(b.call))
    .filter(Boolean);
  const unique = [...new Set(summaries)];
  const preview = unique.join(", ");

  return (
    <div className={`agent-tool-card ${status}`}>
      <button type="button" className="agent-tool-head" onClick={() => setOpen(!open)} aria-expanded={open}>
        <span className={`agent-tool-chevron${open ? " open" : ""}`} aria-hidden="true"><ChevronRightIcon /></span>
        <span className="agent-tool-name">{name}</span>
        {preview && <code className="agent-tool-summary">{preview}</code>}
        <span className="agent-tool-status">{statusText(status)}</span>
      </button>
      {open && (
        <div className="agent-tool-detail">
          <div className="agent-tool-sublist">
            {group.blocks.map((block, idx) => {
              const summary = toolSummary(block.call);
              const bStatus = block.call.toolStatus || (block.outputs.length ? "success" : "running");
              return (
                <div key={blockKindKey(block, idx)} className="agent-tool-subitem">
                  <div className="agent-tool-subitem-head">
                    {isCommand ? (
                      <span className="agent-tool-prompt">$ </span>
                    ) : (
                      <span className="agent-tool-bullet">•</span>
                    )}
                    {summary && <code className="agent-tool-summary">{summary}</code>}
                    <span className="agent-tool-status">{statusText(bStatus)}</span>
                  </div>
                  {!isCommand && (
                    <>
                      {block.outputs.map((out, oIdx) => (
                        <ToolOutputBody key={out.seq ?? oIdx} event={out} />
                      ))}
                      {block.call.files?.length > 0 && <FileList files={block.call.files} />}
                    </>
                  )}
                </div>
              );
            })}
          </div>
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
  const isCommand = isCommandTool(call.toolName, call.toolInput);
  const preview = summary || "exec";
  if (isCommand) {
    return (
      <div className={`agent-tool-card command ${status}`}>
        <code className="agent-tool-command">
          <span className="agent-tool-prompt">$ </span>
          {preview}
        </code>
        {call.files?.length > 0 && (
          <span className="agent-tool-files-preview">({formatFileList(call.files)})</span>
        )}
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
          {summary && (
            <pre className="agent-tool-code">{summary}</pre>
          )}
          {status === "running" && block.outputs.length === 0 && !summary && (
            <span className="agent-tool-waiting">Running…</span>
          )}
          {block.outputs.map((output, idx) => (
            <ToolOutputBody key={output.seq ?? idx} event={output} />
          ))}
          {call.files?.length > 0 && <FileList files={call.files} />}
        </div>
      )}
    </div>
  );
}

function activityTitle(reasoningCount, toolsCount, tools = []) {
  const parts = [];
  if (reasoningCount > 0) parts.push(reasoningCount === 1 ? "Thinking" : `Thinking × ${reasoningCount}`);
  if (toolsCount > 0) {
    if (toolsCount === 1 && tools[0]?.call?.toolName) {
      parts.push(displayToolName(tools[0].call.toolName));
    } else {
      const toolNames = new Set(tools.map(t => (t.call?.toolName || "").toLowerCase()));
      if (toolNames.size === 1) {
        const [singleType] = toolNames;
        switch (singleType) {
        case "read":
        case "view_file":
        case "viewfile":
          parts.push(`Read ${toolsCount} files`);
          break;
        case "edit":
        case "write":
        case "apply_patch":
        case "replace_file_content":
        case "write_to_file":
          parts.push(`Edited ${toolsCount} files`);
          break;
        case "grep":
        case "glob":
        case "find_by_name":
        case "grep_search":
        case "web_search":
          parts.push(`Searched ${toolsCount} times`);
          break;
        case "shell":
        case "exec":
        case "run_command":
          parts.push(`Ran ${toolsCount} commands`);
          break;
        default:
          parts.push(`${displayToolName(singleType)} × ${toolsCount}`);
        }
      } else {
        parts.push(`Tools × ${toolsCount}`);
      }
    }
  }
  return parts.join(" · ") || "Activity";
}

function toolGroupSummary(items) {
  if (!Array.isArray(items) || items.length === 0) return "";
  const summaries = items
    .map(item => toolSummary(item?.call))
    .filter(Boolean);
  if (summaries.length === 0) return "";
  const unique = [...new Set(summaries)];
  return truncatePreview(unique.join(" · "), 140);
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

// A message was cut short by a user interruption. All providers surface
// this through event.stopReason; the parser normalizes provider-specific
// sentinels (e.g. Claude's "[Request interrupted..." user message) into
// the same shape.
function isInterrupted(event) {
  return Boolean(event) && event.stopReason === "interrupted";
}

function ChevronRightIcon() {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" aria-hidden="true">
      <path d="m9 6 6 6-6 6" />
    </svg>
  );
}

function toolDisplay(call, status) {
  if (call.toolName !== "web_search") return toolSummary(call);
  const target = toolSummary(call);
  if (status === "running") return `Searching the web${target ? ` for ${target}` : ""}…`;
  if (status === "success") return `Searched the web for ${target || "results"}`;
  if (status === "error") return `Web search failed${target ? ` · ${target}` : ""}`;
  if (status === "interrupted") return `Web search interrupted${target ? ` · ${target}` : ""}`;
  return target || "Web search";
}

const REMARK_PLUGINS = [remarkGfm];

const MarkdownContent = memo(function MarkdownContent({ value }) {
  return (
    <div className="agent-markdown">
      <ReactMarkdown remarkPlugins={REMARK_PLUGINS}>{value}</ReactMarkdown>
    </div>
  );
});

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
