import { memo, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";

import {
  agentDraftMaximumBytes,
  agentEchoWaitMs,
  isUserAgentEvent,
  loadAgentDraft,
  agentInteractionIdentity,
  latestPendingAgentInteraction,
  removeAgentDraft,
  saveAgentDraft,
  validateAgentAttachment,
} from "./agent.js";
import { useFocusTrap } from "./components.jsx";
import { composerChips, projectConversation, withStateEvents } from "./conversation.js";
import { ContextMeter, ConversationRoot, ModeIcon, PlanStrip, SelectorChip, Turn } from "./conversation.jsx";

const PROVIDER_NAMES = { claude: "Claude", codex: "Codex", opencode: "OpenCode", pi: "Pi", qoder: "Qoder", antigravity: "Antigravity" };

export function AgentView({
  session,
  turn = null,
  events = [],
  stateEvents = [],
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
  queueItems = [],
  onQueueEdit = () => {},
  onQueueDelete = () => {},
  onQueueMoveToFront = () => {},
  onQueueReorder = () => {},
  onQueueRetry = () => {},
  // Chat (ACP) Sessions: selectors, hand-off, and agent terminals.
  onSetConfig = async () => {},
  canHandoff = false,
  onHandoff = async () => {},
  onOpenSession = () => {},
  sessionExists = () => false,
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
  const conversation = useMemo(() => projectConversation(withStateEvents(events, stateEvents)), [events, stateEvents]);
  const turns = conversation.turns;
  const chips = useMemo(() => composerChips(conversation.config), [conversation.config]);
  const canConfigure = capabilities.includes("agent-config-v1");
  const provider = PROVIDER_NAMES[String(session?.agentProvider || session?.kind || "").toLowerCase()] || "the Agent";
  const agentStatus = status || session?.agentStatus || null;
  const attention = agentStatus?.attention || null;
  const activePendingInteraction = useMemo(
    () => latestPendingAgentInteraction(events),
    [events]
  );
  const activePendingInteractionID = agentInteractionIdentity(activePendingInteraction);

  const canCompose = ready && hasControl && canSendForStatus(agentStatus);
  const disabledReason = agentInputDisabledReason({ ready, hasControl, status: agentStatus });
  const canInterrupt = agentStatus?.activity === "working" && capabilities.includes("agent-interrupt-v1");
  const canInteract = capabilities.includes("agent-interactions-v1");
  const canUpload = capabilities.includes("agent-attachments-v1");
  const staleAcceptedIDs = useStaleAcceptedMessages(queueItems);
  const showInputMeta = Boolean(disabledReason || queueItems.length > 0);
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
  }, [endpointIdentity, session?.id]);

  useEffect(() => () => {
    if (submitStatusTimerRef.current !== null) clearTimeout(submitStatusTimerRef.current);
  }, []);

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
    <ConversationRoot.Provider value={session?.directory || session?.cwd || ""}>
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
        {turns.length === 0 && queueItems.length === 0 ? (
          <div className="agent-empty">
            <div className="agent-empty-mark" aria-hidden="true">✦</div>
            <div className="agent-empty-title">What can I help you with?</div>
            <div className="agent-empty-hint">Messages, tool calls and results will appear here.</div>
          </div>
        ) : (
          <>
            {turns.map((turn, index) => (
              <Turn
                key={turn.id}
                turn={turn}
                live={index === turns.length - 1}
                waiting={index === turns.length - 1 && Boolean(activePendingInteraction)}
                onOpenSession={onOpenSession}
                sessionExists={sessionExists}
              />
            ))}
            {queueItems.map(item => (
              <PendingAgentMessage
                key={item.id}
                item={item}
                stale={staleAcceptedIDs.has(item.id)}
                onDelete={onQueueDelete}
                onOpenTerminal={onOpenTerminal}
              />
            ))}
          </>
        )}
      </div>
      {attention && <AgentAttention attention={attention} onOpenTerminal={onOpenTerminal} onFocusComposer={() => inputRef.current?.focus()} />}
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
      {activePendingInteraction && (
        <div className="agent-docked-interaction" role="region" aria-label="Action required">
          <StructuredAgentBlock
            event={activePendingInteraction}
            onInteraction={onInteraction}
            canInteract={canInteract}
            isDocked={true}
          />
        </div>
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
            <PlanStrip plan={conversation.plan} />
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
                placeholder={`Message ${provider}…`}
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
              {canConfigure && chips.mode && (
                <SelectorChip
                  label={chips.mode.currentName.replace(/ \(.*\)$/, "")}
                  icon={<ModeIcon value={chips.mode.currentValue} />}
                  config={[chips.mode]}
                  onSetConfig={onSetConfig}
                />
              )}
              <span className="agent-input-spacer" />
              <ContextMeter context={conversation.context} />
              {canConfigure && chips.modelOptions.length > 0 ? (
                <SelectorChip
                  label={chips.modelSummary || "Model"}
                  config={chips.modelOptions}
                  onSetConfig={onSetConfig}
                  canHandoff={canHandoff}
                  handoffBlocked={agentStatus?.activity === "working" ? "Stop the turn first" : ""}
                  onHandoff={onHandoff}
                />
              ) : canHandoff ? (
                <SelectorChip label="Session" config={[]} canHandoff onHandoff={onHandoff} onSetConfig={onSetConfig} />
              ) : null}
              <div className="agent-submit-controls">
                {canInterrupt && (draft.trim() || attachments.length > 0) && (
                  <button
                    type="button"
                    className="agent-send-now-button"
                    disabled={uploadingAttachments || submitStatus === "sending"}
                    onClick={() => { void submit(true); }}
                  >
                    Send now
                  </button>
                )}
                {canInterrupt && (
                  <button
                    type="button"
                    className="agent-stop-button"
                    disabled={cancelPending}
                    onClick={cancelTurn}
                    aria-label={cancelPending ? "Stopping Agent" : "Stop Agent"}
                    title={cancelPending ? "Stopping Agent" : "Stop Agent"}
                  >
                    <StopIcon />
                    <span>{cancelPending ? "Stopping…" : "Stop"}</span>
                  </button>
                )}
                <button type="submit" className="agent-send" disabled={(!draft.trim() && attachments.length === 0) || !canCompose || uploadingAttachments || submitStatus === "sending"} aria-label="Send">
                  <SendIcon />
                </button>
              </div>
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
    </ConversationRoot.Provider>
  );
}

function AgentAttention({ attention, onOpenTerminal, onFocusComposer }) {
  const kind = attention.kind;
  // Only an explicit provider request renders a banner. A kind this client
  // does not know stays on the base fallback instead of claiming attention.
  const labels = {
    input: ["text-bubble", "Question · Reply in the composer to continue."],
    approval: ["shield-check", "Permission · Review the request in Terminal."],
  };
  const label = labels[kind];
  if (!label) return null;
  const reason = String(attention.reason || "").trim().toLowerCase();
  const [icon, fallback] = label;
  const reasonLabel = {
    question: "Question · Reply in the composer to continue.",
    permission: "Permission · Review the request in Terminal.",
    approval: "Permission · Review the request in Terminal.",
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
  if (["failed", "exited", "unknown"].includes(activity)) return false;
  // An input/question attention is intentionally answerable in the composer.
  return !status.attention || status.attention.kind === "input";
}

function agentInputDisabledReason({ ready, hasControl, status }) {
  if (!ready) return "Agent is starting in Terminal.";
  if (!hasControl) return "";
  const activity = String(status?.activity || "").toLowerCase();
  if (status?.attention?.kind === "approval") return "Permission required — review the request.";
  switch (activity) {
  case "failed": return "Agent failed.";
  case "exited": return "Agent has exited.";
  default: return "";
  }
}

/**
 * Ids of accepted messages whose transcript echo is overdue.
 *
 * Only runs a timer while something is actually waiting, so an idle transcript
 * does not re-render on a clock.
 */
function useStaleAcceptedMessages(queueItems) {
  const [stale, setStale] = useState(() => new Set());
  const pending = useMemo(
    () => queueItems.filter(item => item.status === "accepted" && item.acceptedAt),
    [queueItems],
  );
  useEffect(() => {
    if (pending.length === 0) {
      setStale(previous => (previous.size === 0 ? previous : new Set()));
      return undefined;
    }
    let timer = null;
    const evaluate = () => {
      const now = Date.now();
      const overdue = new Set();
      let soonest = Number.POSITIVE_INFINITY;
      for (const item of pending) {
        const accepted = Date.parse(item.acceptedAt);
        if (!Number.isFinite(accepted)) continue;
        const elapsed = now - accepted;
        if (elapsed >= agentEchoWaitMs) overdue.add(item.id);
        else soonest = Math.min(soonest, agentEchoWaitMs - elapsed);
      }
      setStale(previous => (
        previous.size === overdue.size && [...overdue].every(id => previous.has(id))
          ? previous
          : overdue
      ));
      if (Number.isFinite(soonest)) timer = setTimeout(evaluate, Math.max(250, soonest));
    };
    evaluate();
    return () => {
      if (timer !== null) clearTimeout(timer);
    };
  }, [pending]);
  return stale;
}

/**
 * One outgoing message that the canonical timeline does not own yet.
 *
 * An `accepted` message is deliberately rendered as an ordinary sent bubble: the
 * Host has it, so the only thing still missing is the provider's echo, and
 * making that swap invisible is the entire point. `stale` means the echo has not
 * arrived in a reasonable time, which is worth saying because the Agent may be
 * stuck — but it is not a failure, and resending would duplicate the message.
 */
function PendingAgentMessage({ item, stale, onDelete, onOpenTerminal }) {
  const status = item.status || "queued";
  const accepted = status === "accepted";
  const label = status === "sending"
    ? "Sending…"
    : status === "failed"
      ? "Failed"
      : accepted
        ? (stale ? "Sent · the Agent has not picked it up" : "Sent")
        : "Queued";
  return (
    <div className={`agent-message user queued ${status}`}>
      <div className="agent-bubble">
        <MarkdownContent value={item.text || ""} />
        {item.attachments?.length > 0 && (
          <div className="agent-queue-item-attachments" aria-label="Queued attachments">
            {item.attachments.map((attachment, index) => (
              <span key={index} className="agent-attachment-chip ready">
                {attachment.name || "Attachment"}
              </span>
            ))}
          </div>
        )}
      </div>
      <div className="agent-message-meta">
        <span className={`agent-queue-tag ${status}`} role="status" aria-live="polite">{label}</span>
        {item.failureReason && <span className="agent-queue-error-text">{item.failureReason}</span>}
        {stale && onOpenTerminal && (
          <button type="button" className="agent-queue-inline-action" onClick={onOpenTerminal}>
            Open terminal
          </button>
        )}
        {/* An accepted message already reached the Agent, so removing it early
            would only hide what is about to appear. Once the echo is overdue the
            user must still be able to clear the row: the provider may never
            write it, and the bubble is otherwise permanent. */}
        {((!accepted && status !== "sending") || (accepted && stale)) && (
          <button
            type="button"
            className="agent-queue-inline-delete"
            title="Remove queued message"
            onClick={() => onDelete && onDelete(item.id)}
          >
            ×
          </button>
        )}
      </div>
    </div>
  );
}

function StructuredAgentBlock({ event, onInteraction = () => {}, canInteract = false, isDocked = false }) {
  const type = String(event?.type || "").trim().toLowerCase().replaceAll("-", "_");
  const payload = event?.payload && typeof event.payload === "object" ? event.payload : {};
  const state = String(payload.state || "")
    .replace(/([a-z])([A-Z])/g, "$1_$2")
    .toLowerCase()
    .replaceAll("-", "_");
  const title = payload.title || payload.label || payload.name || type.replaceAll("_", " ");
  const [submitting, setSubmitting] = useState(false);
  const [answers, setAnswers] = useState({});
  const [customAnswers, setCustomAnswers] = useState({});
  const [expanded, setExpanded] = useState(false);
  const requestID = String(payload.requestId || payload.interactionId || event?.requestId || event?.interactionId || "").trim();
  const pendingState = state === "pending" || state === "submitting";
  const pending = pendingState && Boolean(requestID);
  const isInteraction = type === "question" || type === "permission" || type === "confirmation";
  const optionID = option => String(
    option && typeof option === "object" ? (option.id ?? option.value ?? "") : option ?? "",
  ).trim();
  const optionLabel = option => String(
    option && typeof option === "object"
      ? (option.label ?? option.title ?? option.id ?? option.value ?? "")
      : option ?? "",
  ).trim();
  const normalizeOption = (option, index) => {
    const source = option && typeof option === "object" && !Array.isArray(option) ? option : {};
    const rawID = optionID(option);
    const rawLabel = optionLabel(option);
    if (!rawID && !rawLabel) return null;
    const id = rawID || `option-${index}`;
    const label = rawLabel || id;
    return {
      ...source,
      id,
      label,
      ...(source.description !== undefined ? { description: String(source.description) } : {}),
    };
  };
  const questions = type === "question"
    ? (Array.isArray(payload.questions) ? payload.questions : []).map((question, index) => {
      const source = question && typeof question === "object" ? question : { prompt: question };
      return {
        ...source,
        id: String(source.id || `question-${index}`),
        prompt: String(source.prompt || source.question || source.title || source.header || "Question"),
        selection: String(source.selection || (source.multiSelect || source.is_multi_select ? "multiple" : "single")).toLowerCase() === "multiple" ? "multiple" : "single",
        required: source.required !== false,
        allowCustom: source.allowCustom === true,
        options: Array.isArray(source.options) ? source.options.map(normalizeOption).filter(Boolean) : [],
      };
    })
    : [];
  const permissionOptions = (type === "permission" || type === "confirmation") && Array.isArray(payload.options)
    ? payload.options.map(normalizeOption).filter(Boolean)
    : [];
  const isProgressMetadata = type === "plan" || type === "todo" || type === "goal";
  // A plan the Agent proposed for review is a Markdown document, not steps to
  // count; it keeps that shape after the user approves or rejects it.
  const isProposedPlan = type === "plan" && (payload.proposal === true || state === "proposed");
  const progressItems = isProgressMetadata
    ? (Array.isArray(payload.items) ? payload.items : Array.isArray(payload.steps) ? payload.steps : [])
      .map((item, index) => {
        const source = item && typeof item === "object" ? item : { label: item };
        const itemState = String(source.state || source.status || "pending").trim().toLowerCase().replaceAll("-", "_");
        return {
          ...source,
          id: String(source.id || `item-${index}`),
          label: String(source.label || source.title || source.step || source.prompt || ""),
          state: itemState || "pending",
        };
      })
      .filter(item => item.label)
    : [];
  const progressObjective = isProgressMetadata
    ? [payload.objective, payload.summary, payload.description, payload.content]
      .map(value => String(value || "").trim())
      .find(value => value && value !== title)
    : "";
  const progressTotal = progressItems.length > 0
    ? progressItems.length
    : Number(payload.total ?? payload.totalCount ?? 0);
  const progressCompleted = progressItems.length > 0
    ? progressItems.filter(item => ["completed", "complete", "done"].includes(item.state)).length
    : Number(payload.completed ?? payload.completedCount ?? 0);
  const tokenBudget = Number(payload.tokenBudget ?? payload.token_budget ?? 0);
  const tokensUsed = Number(payload.tokensUsed ?? payload.tokens_used ?? 0);
  const progressCount = progressTotal > 0
    ? `${Math.min(Math.max(progressCompleted, 0), progressTotal)}/${progressTotal}`
    : type === "goal" && tokenBudget > 0 && Number.isFinite(tokensUsed)
      ? `${Math.min(Math.max(tokensUsed, 0), tokenBudget)}/${tokenBudget}`
      : "";
  const progressPreview = isProposedPlan
    ? progressObjective.split(/\r?\n/).map(line => line.trim()).find(line => line && !line.startsWith("#")) || ""
    : progressObjective
      ? progressObjective.split(/\r?\n/, 1)[0]
      : progressItems[0]?.label || "";
  // Progress metadata stays compact in the transcript and expands on demand.
  // This mirrors the native client while keeping the full objective and item
  // list available to keyboard and screen-reader users.
  if (isProgressMetadata) {
    const progressState = state || (type === "goal" ? "active" : "pending");
    return (
      <section className={`agent-progress-capsule agent-progress-${type}${expanded ? " open" : ""}`} aria-label={title}>
        <button
          type="button"
          className="agent-progress-capsule-trigger"
          onClick={() => setExpanded(previous => !previous)}
          aria-expanded={expanded}
        >
          <span className="agent-progress-icon" aria-hidden="true">{isProposedPlan ? "▤" : structuredIcon(type)}</span>
          <strong>{title}</strong>
          {!expanded && progressPreview && <span className="agent-progress-preview">{progressPreview}</span>}
          <span className="agent-progress-spacer" />
          {progressCount && <span className="agent-progress-count">{progressCount}</span>}
          <span className={`agent-structured-state ${progressState}`}>{structuredStateLabel(progressState)}</span>
          <span className="agent-progress-caret" aria-hidden="true">{expanded ? "▴" : "▾"}</span>
        </button>
        {expanded && (
          <div className="agent-progress-details">
            {isProposedPlan && payload.feedback && (
              <p className="agent-structured-description"><strong>Feedback</strong> {String(payload.feedback)}</p>
            )}
            {isProposedPlan && progressObjective && <MarkdownContent value={progressObjective} />}
            {!isProposedPlan && progressObjective && <p className="agent-structured-description">{progressObjective}</p>}
            {progressItems.length > 0 && (
              <ul className="agent-structured-items">
                {progressItems.map(item => (
                  <li key={item.id} className={item.state}>
                    <span aria-hidden="true">{["completed", "complete", "done"].includes(item.state) ? "✓" : "○"}</span>
                    {item.label}
                  </li>
                ))}
              </ul>
            )}
            {!progressObjective && progressItems.length === 0 && (
              <p className="agent-structured-summary">No details reported by the Host.</p>
            )}
          </div>
        )}
      </section>
    );
  }

  // Render resolved interaction as a simple collapsible card in the message flow
  if (isInteraction && !pendingState && !isDocked) {
    const categoryLabel = type === "permission" ? "Permission" : type === "confirmation" ? "Confirmation" : "Ask";
    const promptPreview = questions[0]?.prompt || payload.description || payload.title || title;

    let resolutionLabel = "Answered";
    let statusClass = "resolved";
    if (payload.response?.cancelled || state === "cancelled") {
      resolutionLabel = "Cancelled";
      statusClass = "cancelled";
    } else if (type === "permission" || type === "confirmation") {
      const decision = String(payload.response?.decision || payload.decision || "").toLowerCase();
      if (decision === "allow" || decision === "yes" || decision === "approve" || decision === "y") {
        resolutionLabel = "Approved";
        statusClass = "approved";
      } else if (decision === "deny" || decision === "no" || decision === "reject" || decision === "n") {
        resolutionLabel = "Denied";
        statusClass = "denied";
      } else if (decision) {
        resolutionLabel = decision;
        statusClass = "resolved";
      } else {
        resolutionLabel = state === "resolved" || state === "completed" ? "Resolved" : structuredStateLabel(state);
      }
    } else if (type === "question") {
      resolutionLabel = state === "resolved" || state === "completed" ? "Answered" : structuredStateLabel(state);
    }

    return (
      <section className={`agent-interaction-card ${type}${expanded ? " open" : ""}`} aria-label={`${categoryLabel}: ${promptPreview}`}>
        <button
          type="button"
          className="agent-interaction-card-header"
          onClick={() => setExpanded(prev => !prev)}
          aria-expanded={expanded}
        >
          <span className="agent-interaction-card-badge">{categoryLabel}</span>
          <span className="agent-interaction-card-summary">{promptPreview}</span>
          <span className={`agent-interaction-card-status ${statusClass}`}>{resolutionLabel}</span>
          <span className="agent-interaction-card-caret" aria-hidden="true">{expanded ? "▴" : "▾"}</span>
        </button>
        {expanded && (
          <div className="agent-interaction-card-body">
            {payload.description && payload.description !== promptPreview && (
              <p className="agent-interaction-card-desc">{payload.description}</p>
            )}
            {type === "question" && questions.map(q => {
              const answeredList = payload.response?.answers?.[q.id] || [];
              const customAns = payload.response?.customAnswers?.[q.id];
              return (
                <div key={q.id} className="agent-interaction-card-q">
                  {questions.length > 1 && <div className="agent-interaction-card-q-prompt">{q.prompt}</div>}
                  {q.options.length > 0 && (
                    <div className="agent-interaction-card-options">
                      {q.options.map(opt => {
                        const optId = optionID(opt);
                        const isChosen = answeredList.includes(optId);
                        return (
                          <div key={optId} className={`agent-interaction-card-opt${isChosen ? " chosen" : ""}`}>
                            <span className="agent-interaction-opt-marker">{isChosen ? "✓" : "○"}</span>
                            <span>{optionLabel(opt) || optId}</span>
                          </div>
                        );
                      })}
                    </div>
                  )}
                  {customAns && (
                    <div className="agent-interaction-card-custom-ans">
                      <em>Custom answer:</em> {customAns}
                    </div>
                  )}
                </div>
              );
            })}
            {(type === "permission" || type === "confirmation") && (
              <div className="agent-interaction-card-decision">
                <span>Decision:</span> <strong>{resolutionLabel}</strong>
              </div>
            )}
          </div>
        )}
      </section>
    );
  }

  const submitResponse = response => {
    if (!pending || !canInteract || submitting || state !== "pending") return;
    setSubmitting(true);
    try {
      const version = Number(payload.version || event?.version) || 1;
      const result = onInteraction({ requestId: requestID, kind: type, version, response });
      // App-level request adapters return a Promise when the Host rejects the
      // response. Restore the card so a transient failure is retryable.
      Promise.resolve(result).catch(() => setSubmitting(false));
    } catch {
      setSubmitting(false);
    }
  };
  const toggleQuestionOption = (question, optionID) => {
    if (!pending || !canInteract || submitting || state !== "pending") return;
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
  const questionsValid = questions.length > 0 && questions.every(question => {
    if (!question.required) return true;
    return (answers[question.id] || []).length > 0 || String(customAnswers[question.id] || "").trim().length > 0;
  }) && questions.some(question => (
    (answers[question.id] || []).length > 0
    || String(customAnswers[question.id] || "").trim().length > 0
  ));
  const cancelInteraction = () => submitResponse({ cancelled: true });
  const selectPermission = option => submitResponse({ decision: optionID(option) });

  useEffect(() => {
    if (state !== "pending") setSubmitting(false);
  }, [state]);

  // Canonical control-plane events arrive as dotted types (for example
  // `compaction.updated`), while the marker check has always been written with
  // underscore spellings. Fold separators before matching so the canonical
  // row renders as the quiet timeline marker instead of a generic card.
  const markerType = type.replaceAll(".", "_");
  if (["config", "config_updated", "compaction", "compaction_updated"].includes(markerType)) {
    const markerLabel = markerType.startsWith("config") ? "Config" : "Compaction";
    return <div className="agent-metadata-marker" role="note">--- {markerLabel} ---</div>;
  }

  const interactionPending = pending && canInteract && state === "pending";
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
              <span>{optionLabel(option) || id}</span>
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
        <span>{optionLabel(option) || id}</span>
        {option.description && <small>{option.description}</small>}
      </button>
    );
  });

  const responseControls = interactionPending && canInteract && (
    <div className="agent-structured-actions">
      {type === "question" && <button type="button" onClick={submitQuestionAnswers} disabled={submitting || !questionsValid}>Submit</button>}
      {type === "question" && questions.length > 0 && (
        <button type="button" onClick={cancelInteraction} disabled={submitting}>Cancel</button>
      )}
      {(type === "permission" || type === "confirmation") && permissionOptions.length > 0 && (
        <button type="button" onClick={cancelInteraction} disabled={submitting}>Cancel</button>
      )}
    </div>
  );

  return (
    <section className={`agent-structured agent-structured-${type}${isDocked ? " docked" : ""}`} aria-label={title}>
      <div className="agent-structured-head">
        <span className="agent-structured-icon" aria-hidden="true">{structuredIcon(type)}</span>
        <strong>{isInteraction ? (type === "permission" ? "Permission" : type === "confirmation" ? "Confirmation" : "Ask") : title}</strong>
        <span className={`agent-structured-state ${state}`}>{structuredStateLabel(state)}</span>
      </div>
      {payload.description && <p className="agent-structured-description">{payload.description}</p>}
      {pending && type === "question" && questionContent}
      {pending && (type === "permission" || type === "confirmation") && permissionContent.length > 0 && (
        <div className="agent-structured-options" role="group" aria-label={`${title} options`}>{permissionContent}</div>
      )}
      {responseControls}
      {(type === "question" || type === "permission" || type === "confirmation") && pendingState && (
        (!canInteract || ((type === "permission" || type === "confirmation") && permissionOptions.length === 0)) && (
          <p className="agent-structured-readonly" role="status">
            {!canInteract
              ? "This Host does not support responding here."
              : "This request has no options from the Host and is read-only."}
          </p>
        )
      )}
      {(type === "plan" || type === "todo") && Array.isArray(payload.items) && (
        <ul className="agent-structured-items">
          {payload.items.map((item, index) => (
            <li key={item.id || index} className={item.state || "pending"}>
              <span aria-hidden="true">{item.state === "completed" || item.status === "completed" ? "✓" : "○"}</span>
              {item.label || item.title || item.step || item.prompt || ""}
            </li>
          ))}
        </ul>
      )}
      {type !== "question" && type !== "permission" && type !== "confirmation" && type !== "plan" && type !== "todo" && (payload.content || payload.prompt || payload.summary || payload.detail || payload.name) && (
        <p className="agent-structured-summary">{payload.content || payload.prompt || payload.summary || payload.detail || payload.name}</p>
      )}
    </section>
  );
}

function structuredIcon(type) {
  return {
    question: "?",
    permission: "✓",
    confirmation: "!",
    plan: "☷",
    todo: "☑",
    goal: "◎",
    activity: "•",
    plugin: "◆",
    subagent: "◇",
    attachment: "⌕",
    queue: "⌛",
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
    proposed: "Proposed",
    approved: "Approved",
    rejected: "Rejected",
    queued: "Queued",
    dequeued: "Dispatched",
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

function StopIcon() {
  return (
    <svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
      <rect x="5" y="5" width="14" height="14" rx="2" />
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

const REMARK_PLUGINS = [remarkGfm];

const MarkdownContent = memo(function MarkdownContent({ value }) {
  return (
    <div className="agent-markdown">
      <ReactMarkdown remarkPlugins={REMARK_PLUGINS}>{value}</ReactMarkdown>
    </div>
  );
});
