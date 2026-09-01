import { useEffect, useLayoutEffect, useRef, useState } from "react";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";

import {
  composerHeightForText,
  agentComposerAction,
  deleteAgentQueueItem,
  editAgentQueueItem,
  enqueueAgentMessage,
  formatAgentModel,
  groupAgentEvents,
  moveAgentQueueItem,
  retryAgentQueueItem,
} from "./agent.js";
import { sessionDisplayTitle } from "./title.js";

export function AgentView({
  session,
  events = [],
  status = null,
  onSend,
  onInterrupt = () => {},
  onOpenTerminal,
  ready = true,
  hasControl = true,
  hasMore = false,
  loadingMore = false,
  onLoadMore = () => {},
}) {
  const listRef = useRef(null);
  const inputRef = useRef(null);
  const loadMoreRef = useRef(null);
  const pinnedSessionIDRef = useRef(null);
  const pinToBottomRef = useRef(true);
  const anchorElementRef = useRef(null);
  const anchorOffsetRef = useRef(null);
  const skipFollowRef = useRef(false);
  const [draft, setDraft] = useState("");
  const [queueBySession, setQueueBySession] = useState({});
  const [showQueue, setShowQueue] = useState(false);
  const [editingQueueID, setEditingQueueID] = useState(null);
  const [queueEditText, setQueueEditText] = useState("");
  const [attachmentNotice, setAttachmentNotice] = useState(false);
  const sessionID = session?.id || "";
  const queueDrainRef = useRef({ sessionID: null, sentWhileReady: false });
  const blocks = groupAgentEvents(events.filter(event => !isHiddenAgentEvent(event)));
  const displayTitle = sessionDisplayTitle(session) || "Agent";
  const agentStatus = status || session?.agentStatus || null;
  const attention = agentStatus?.attention || null;
  const mode = agentModeLabel(session);
  const modelLabel = formatAgentModel(agentModel(session, events));
  const queue = queueBySession[sessionID] || [];
  const canCompose = ready && hasControl && canSendForStatus(agentStatus);
  const activity = String(agentStatus?.activity || "").toLowerCase();
  const composerAction = agentComposerAction(agentStatus, {
    hasControl: canCompose,
    hasText: Boolean(draft.trim()),
  });
  const disabledReason = agentInputDisabledReason({ ready, hasControl, status: agentStatus });
  // The Host projects a session-level lifecycle. "working" is the only state
  // that means the agent is actively producing output; "blocked"/"stalled"
  // are waiting on a human, not running, so they must not show the shim.
  const running = activity === "working";

  useEffect(() => {
    setEditingQueueID(null);
    setQueueEditText("");
    setShowQueue(false);
    setAttachmentNotice(false);
    queueDrainRef.current = { sessionID, sentWhileReady: false };
  }, [sessionID]);

  const updateQueue = updater => {
    setQueueBySession(previous => {
      const current = previous[sessionID] || [];
      const next = updater(current);
      return next.length > 0
        ? { ...previous, [sessionID]: next }
        : Object.fromEntries(Object.entries(previous).filter(([id]) => id !== sessionID));
    });
  };

  const sendQueuedItem = item => {
    if (!item || !canCompose) return;
    if (activity === "ready") {
      queueDrainRef.current = { sessionID, sentWhileReady: true };
    }
    onSend(item.text);
    updateQueue(current => deleteAgentQueueItem(current, item.id));
  };

  useEffect(() => {
    const activity = String(agentStatus?.activity || "").toLowerCase();
    if (queueDrainRef.current.sessionID !== sessionID) {
      queueDrainRef.current = { sessionID, sentWhileReady: false };
    }
    if (activity !== "ready") {
      queueDrainRef.current.sentWhileReady = false;
      return;
    }
    if (!queueDrainRef.current.sentWhileReady && queue.length > 0 && canCompose) {
      sendQueuedItem(queue[0]);
    }
  }, [activity, canCompose, queue, sessionID]);

  useLayoutEffect(() => {
    const input = inputRef.current;
    if (!input) return;
    resizeComposerTextarea(input, draft);
  }, [draft, sessionID]);

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

  useLayoutEffect(() => {
    if (!running) return;
    const list = listRef.current;
    if (!list) return;
    const followsBottom = list.scrollHeight - list.scrollTop - list.clientHeight < 160;
    if (pinToBottomRef.current || followsBottom) list.scrollTop = list.scrollHeight;
  }, [running]);

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

  const submit = () => {
    if (!ready || !canCompose) return;
    const value = draft.trim();
    if (!value) return;
    if (running) {
      updateQueue(current => enqueueAgentMessage(current, value));
    } else if (queue.length > 0) {
      // Preserve FIFO ordering when a local queue already exists. A direct
      // send would otherwise jump ahead of messages the user explicitly
      // queued while the Agent was working.
      updateQueue(current => enqueueAgentMessage(current, value));
    } else {
      onSend(value);
    }
    setDraft("");
    inputRef.current?.focus();
  };

  const primaryAction = () => {
    if (running) {
      onInterrupt();
      return;
    }
    submit();
  };

  return (
    <div
      className="agent-view"
      onPointerDown={event => event.stopPropagation()}
      onClick={event => event.stopPropagation()}
    >
      <div ref={listRef} className="agent-events" aria-label={`${displayTitle} conversation`}>
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
              : <AgentBlock key={blockKindKey(block, index)} block={block} />
          ))
        )}
        {running && (
          <div className="agent-working agent-working-inline" aria-live="polite">
            <span className="codex-caret" aria-hidden="true" />
            <span className="agent-working-shimmer">Working</span>
            <span className="agent-working-provider">{displayTitle}</span>
          </div>
        )}
      </div>
      {attention && <AgentAttention attention={attention} onOpenTerminal={onOpenTerminal} />}
      {ready ? (
        <form
          className="agent-input"
          onSubmit={event => {
            event.preventDefault();
            submit();
          }}
        >
          {attachmentNotice && (
            <div className="agent-attachment-notice" role="status">
              Attachments are not supported by this Host.
            </div>
          )}
          {showQueue && queue.length > 0 && (
            <AgentQueueList
              queue={queue}
              editingID={editingQueueID}
              editText={queueEditText}
              canSendNow={canCompose && !running}
              onBeginEdit={item => {
                setEditingQueueID(item.id);
                setQueueEditText(item.text);
              }}
              onSaveEdit={(id, text) => {
                updateQueue(current => editAgentQueueItem(current, id, text));
                setEditingQueueID(null);
              }}
              onCancelEdit={() => setEditingQueueID(null)}
              onEditText={setQueueEditText}
              onDelete={id => updateQueue(current => deleteAgentQueueItem(current, id))}
              onMove={(from, to) => updateQueue(current => moveAgentQueueItem(current, from, to))}
              onRetry={id => {
                updateQueue(current => retryAgentQueueItem(current, id));
                const item = queue.find(value => value.id === id);
                if (item && canCompose && !running) sendQueuedItem(item);
              }}
            />
          )}
          <div className="agent-input-surface">
            <textarea
              ref={inputRef}
              value={draft}
              onChange={event => {
                setDraft(event.target.value);
                resizeComposerTextarea(event.currentTarget, event.target.value);
              }}
              onKeyDown={event => {
                if (event.key === "Enter" && !event.shiftKey && !event.isComposing) {
                  event.preventDefault();
                  submit();
                }
              }}
              placeholder={`Message ${displayTitle}…`}
              aria-label="Message"
              rows={2}
              enterKeyHint="send"
              autoCapitalize="off"
              autoCorrect="off"
              autoComplete="off"
              spellCheck="false"
              disabled={!canCompose}
            />
          </div>
          <div className="agent-input-controls" aria-label="Agent details">
            <button
              type="button"
              className="agent-attach"
              aria-label="Add image or attachment"
              onClick={() => setAttachmentNotice(value => !value)}
            >
              +
            </button>
            <span>{agentKindLabel(session?.kind) || displayTitle}</span>
            {mode && <span className="agent-mode-badge">{mode}</span>}
            {modelLabel && <code>{modelLabel}</code>}
            {queue.length > 0 && (
              <button type="button" className="agent-queue-toggle" onClick={() => setShowQueue(value => !value)}>
                Queue {queue.length}
              </button>
            )}
            {disabledReason && <span className="agent-input-reason">{disabledReason}</span>}
            <button
              type="button"
              className={`agent-send${composerAction === "interrupt" ? " interrupt" : ""}`}
              disabled={composerAction === "unavailable"}
              aria-label={composerAction === "interrupt" ? "Interrupt Agent" : "Send"}
              onClick={primaryAction}
            >
              {running ? <StopIcon /> : <SendIcon />}
            </button>
          </div>
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

function agentKindLabel(kind) {
  switch (String(kind || "").trim().toLowerCase()) {
  case "codex": return "Codex";
  case "claude":
  case "claude-code": return "Claude";
  case "opencode":
  case "open-code": return "OpenCode";
  default: return "";
  }
}

function agentModel(session, events = []) {
  const model = String(session?.agentModel || [...events].reverse().find(event => event.model)?.model || "").trim();
  return model || "";
}

function agentModeLabel(session) {
  const kind = String(session?.kind || "").trim().toLowerCase();
  const command = String(session?.command || "").trim().toLowerCase();
  if (!kind && !command) return "";
  if (kind === "codex") {
    // Warren's --dangerously-bypass-hook-trust only trusts the managed hook;
    // it does not disable Codex approvals or the sandbox.
    if (command.includes("--dangerously-bypass-approvals-and-sandbox")
      || command.includes("--full-auto")
      || command.includes("--yolo")) return "YOLO";
    if (command.includes("--ask-for-approval")) return "Ask";
  }
  if (kind === "claude" || kind === "claude-code") {
    if (command.includes("--dangerously-skip-permissions") || command.includes("bypasspermissions")) return "YOLO";
    if (command.includes("acceptedits")) return "Edit";
    if (command.includes("permission-mode plan")) return "Plan";
    if (command.includes("permission-mode default")) return "Ask";
    if (command.includes("permission-mode dontask")) return "Auto";
  }
  if (kind === "opencode" || kind === "open-code") {
    if (command.includes("--dangerously") || command.includes("--yolo") || command.includes("--auto-approve")) return "YOLO";
    const match = command.match(/--(?:agent|mode)(?:=|\s+)([^\s]+)/);
    if (match) return match[1].charAt(0).toUpperCase() + match[1].slice(1);
  }
  return "";
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

function AgentQueueList({
  queue,
  editingID,
  editText,
  canSendNow,
  onBeginEdit,
  onSaveEdit,
  onCancelEdit,
  onEditText,
  onDelete,
  onMove,
  onRetry,
}) {
  const editRef = useRef(null);

  useLayoutEffect(() => {
    const input = editRef.current;
    if (!input) return;
    resizeComposerTextarea(input, editText);
  }, [editingID, editText]);

  return (
    <div className="agent-queue" aria-label="Queued messages">
      <div className="agent-queue-heading">
        <span>Queued messages</span>
        <span>Local</span>
      </div>
      {queue.map((item, index) => (
        <div className="agent-queue-item" key={item.id}>
          {editingID === item.id ? (
            <textarea
              ref={editRef}
              value={editText}
              onChange={event => {
                onEditText(event.target.value);
                resizeComposerTextarea(event.currentTarget, event.target.value);
              }}
              rows={2}
              aria-label="Edit queued message"
              autoFocus
            />
          ) : (
            <div className="agent-queue-text">{item.text}</div>
          )}
          <div className="agent-queue-actions">
            {editingID === item.id ? (
              <>
                <button type="button" onClick={() => onSaveEdit(item.id, editText)}>Save</button>
                <button type="button" onClick={onCancelEdit}>Cancel</button>
              </>
            ) : (
              <>
                <button type="button" onClick={() => onBeginEdit(item)} aria-label="Edit queued message">Edit</button>
                <button type="button" onClick={() => onDelete(item.id)} aria-label="Delete queued message">Delete</button>
              </>
            )}
            <button type="button" onClick={() => onMove(index, Math.max(0, index - 1))} disabled={index === 0} aria-label="Move queued message up">↑</button>
            <button type="button" onClick={() => onMove(index, Math.min(queue.length, index + 2))} disabled={index === queue.length - 1} aria-label="Move queued message down">↓</button>
            <button type="button" onClick={() => onRetry(item.id)} disabled={!canSendNow}>Send now</button>
          </div>
        </div>
      ))}
    </div>
  );
}

function canSendForStatus(status) {
  if (!status) return true;
  const activity = String(status.activity || "").toLowerCase();
  if (["failed", "stalled", "exited", "unknown"].includes(activity)) return false;
  if (activity === "blocked" && status.attention?.kind !== "input") return false;
  // An input/question attention is intentionally answerable in the composer;
  // approval and warning attention must be reviewed in the Terminal.
  return !status.attention || status.attention.kind === "input";
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

function resizeComposerTextarea(textarea, text) {
  if (!textarea) return;
  const minimumHeight = composerHeightForText("");
  const maximumHeight = composerHeightForText("", { minLines: 6, maxLines: 6 });
  textarea.style.height = "auto";
  const measured = Number.isFinite(textarea.scrollHeight) ? textarea.scrollHeight : 0;
  const fallback = composerHeightForText(text);
  const height = Math.min(maximumHeight, Math.max(minimumHeight, measured || fallback));
  textarea.style.height = `${height}px`;
  textarea.style.overflowY = measured > height ? "auto" : "hidden";
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

function blockKindKey(block, index) {
  const id = block.call?.id || block.event?.id || block.event?.seq || block.call?.seq;
  const sequence = block.call?.seq || block.event?.seq;
  // Provider IDs identify logical parts, not always individual events (an
  // OpenCode part can emit several deltas). Include the normalized sequence
  // so a fallback or repeated provider ID can never collide in React.
  return `${block.kind}-${id || "event"}-${sequence || index}`;
}

function AgentBlock({ block }) {
  switch (block.kind) {
  case "user":
  case "assistant": {
    const event = block.event;
    const interrupted = isInterrupted(event);
    if (event.type === "user") {
      return (
        <div className={`agent-message user${interrupted ? " interrupted" : ""}`}>
          <div className="agent-bubble">
            <MarkdownContent value={event.content || ""} />
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
      <rect x="6" y="6" width="12" height="12" rx="1.5" />
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
