import { createContext, memo, useContext, useEffect, useMemo, useRef, useState } from "react";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";

import {
  displayPath,
  formatElapsed,
  isToggleOption,
  stepLine,
  visibleStreamingText,
} from "./conversation.js";

// One turn of an Agent conversation (RFC 0023 §9), shared by every Agent
// Session whatever its transport, and the controls of the composer's lower
// row. Everything is quiet unless it needs the person: work folds into one
// line per turn, reasoning is opt-in, and the answer is the only
// full-contrast text.

/// The Session's directory; step targets and changed files under it are
/// shown relative to it.
export const ConversationRoot = createContext("");

const markdownComponents = {
  a: ({ node, ...props }) => <a {...props} target="_blank" rel="noreferrer noopener" />,
};

const Markdown = memo(function Markdown({ text }) {
  return (
    <div className="agent-markdown conversation-markdown">
      <ReactMarkdown remarkPlugins={[remarkGfm]} components={markdownComponents}>{text}</ReactMarkdown>
    </div>
  );
});

function DiffBlock({ diff }) {
  if (!diff) return null;
  return (
    <pre className="conversation-diff">
      {String(diff).split("\n").map((line, index) => {
        const kind = line.startsWith("+++") || line.startsWith("---") ? "meta"
          : line.startsWith("@@") ? "hunk"
            : line.startsWith("+") ? "add"
              : line.startsWith("-") ? "del" : "";
        return <span key={index} className={kind ? `diff-${kind}` : undefined}>{line}{"\n"}</span>;
      })}
    </pre>
  );
}

function ChangeCount({ additions, deletions }) {
  if (!additions && !deletions) return null;
  return (
    <span className="conversation-change-count">
      <span className="add">+{additions}</span> <span className="del">−{deletions}</span>
    </span>
  );
}

function Step({ step, onOpenSession, sessionExists }) {
  const [open, setOpen] = useState(false);
  const root = useContext(ConversationRoot);
  const [verb, target] = stepLine(step, root);
  const detail = step.kind === "tool" ? (step.diff?.diff ? null : step.error || step.output) : null;
  const expandable = Boolean(detail || step.diff?.diff);
  const failed = step.status === "failed";
  return (
    <li className={`conversation-step${failed ? " failed" : ""}`}>
      <button type="button" className="conversation-step-line" disabled={!expandable} onClick={() => setOpen(value => !value)} aria-expanded={expandable ? open : undefined}>
        <span className="conversation-step-mark" aria-hidden="true" />
        <span className="conversation-step-verb">{verb}</span>
        {target && <span className="conversation-step-target">{target}</span>}
        {step.diff && <ChangeCount additions={Number(step.diff.additions) || 0} deletions={Number(step.diff.deletions) || 0} />}
        {step.kind === "decision" && step.choice && <span className="conversation-step-meta">{step.choice}</span>}
      </button>
      {step.terminalSessionId && sessionExists?.(step.terminalSessionId) && (
        <button type="button" className="conversation-step-link" onClick={() => onOpenSession?.(step.terminalSessionId)}>
          Open terminal
        </button>
      )}
      {open && step.diff?.diff && <DiffBlock diff={step.diff.diff} />}
      {open && detail && <pre className="conversation-step-output">{detail}</pre>}
    </li>
  );
}

function Reasoning({ reasoning, running }) {
  const [open, setOpen] = useState(false);
  if (!reasoning.count) return null;
  const seconds = Math.round((reasoning.endedAt - reasoning.startedAt) / 1000);
  const label = running && !reasoning.done ? "Thinking" : seconds > 0 ? `Thought for ${seconds}s` : "Thought";
  return (
    <div className="conversation-reasoning">
      <button type="button" className="conversation-quiet-toggle" onClick={() => setOpen(value => !value)} aria-expanded={open}>
        <span className={`conversation-caret${open ? " open" : ""}`} aria-hidden="true">›</span>{label}
      </button>
      {open && <div className="conversation-reasoning-text">{reasoning.text}</div>}
    </div>
  );
}

/// Seconds tick for a running turn's elapsed label.
function useNow(active) {
  const [now, setNow] = useState(Date.now());
  useEffect(() => {
    if (!active) return undefined;
    setNow(Date.now());
    const timer = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(timer);
  }, [active]);
  return now;
}

const LIVE_STEP_WINDOW = 3;
const SETTLE_MS = 420;

/// The turn's work. While the turn runs, a live "Working for …" line carries
/// the transcript's only moving highlight, over a rolling window of at most
/// three step lines. When the turn ends the window settles into one line,
/// "Worked for … · Read 4 files", so the answer below it is what remains.
function WorkTrail({ turn, running, waiting, onOpenSession, sessionExists }) {
  const [open, setOpen] = useState(false);
  const root = useContext(ConversationRoot);
  const now = useNow(running);
  const entries = useMemo(() => {
    const rows = [
      ...turn.narration.map(message => ({ type: "note", order: message.order || 0, message })),
      ...turn.steps.map(step => ({ type: "step", order: step.order || 0, step })),
    ];
    return rows.sort((left, right) => left.order - right.order);
  }, [turn.narration, turn.steps]);
  const liveWindow = useMemo(() => turn.steps.slice(-LIVE_STEP_WINDOW), [turn.steps]);
  // The window a finished turn settles from, kept for one short collapse.
  const lastWindowRef = useRef(liveWindow);
  const wasRunningRef = useRef(running);
  const [settling, setSettling] = useState(false);
  useEffect(() => {
    if (running) lastWindowRef.current = liveWindow;
  }, [running, liveWindow]);
  useEffect(() => {
    const wasRunning = wasRunningRef.current;
    wasRunningRef.current = running;
    if (!wasRunning || running) return undefined;
    setSettling(true);
    const timer = setTimeout(() => setSettling(false), SETTLE_MS);
    return () => clearTimeout(timer);
  }, [running]);
  if (!entries.length && !running) return null;
  const additions = turn.files.reduce((sum, file) => sum + file.additions, 0);
  const deletions = turn.files.reduce((sum, file) => sum + file.deletions, 0);
  const failures = turn.steps.filter(step => step.status === "failed" && step.kind === "tool").length;
  const started = turn.startedAt || 0;
  const ended = turn.endedAt || 0;
  const workedFor = started && ended - started >= 1000 ? `Worked for ${formatElapsed(ended - started)}` : "";
  const settledLabel = [workedFor, turn.summary].filter(Boolean).join(" · ") || "Worked";
  const collapsing = settling && !open ? lastWindowRef.current : [];
  return (
    <div className={`conversation-trail${running ? " live" : ""}${settling ? " settling" : ""}`}>
      <button type="button" className="conversation-quiet-toggle conversation-trail-head" onClick={() => setOpen(value => !value)} aria-expanded={open} disabled={!entries.length}>
        {running && waiting && <span className="conversation-trail-label">Waiting</span>}
        {running && !waiting && <span className="conversation-shimmer">Working for {formatElapsed(started ? now - started : 0)}</span>}
        {!running
          && <span className="conversation-trail-label">{settledLabel}</span>}
        {failures > 0 && <span className="conversation-trail-failures">{failures} failed</span>}
        <ChangeCount additions={additions} deletions={deletions} />
        {entries.length > 0 && <span className={`conversation-caret${open ? " open" : ""}`} aria-hidden="true">›</span>}
      </button>
      {running && !open && liveWindow.length > 0 && (
        <ol className="conversation-live-steps" aria-live="off">
          {liveWindow.map((step, index) => {
            const current = index === liveWindow.length - 1 && (step.status === "running" || step.status === "pending");
            return (
              <li key={step.id || index} className={`conversation-live-step${current ? " current" : ""}${step.status === "failed" ? " failed" : ""}`}>
                {stepLine(step, root).filter(Boolean).join(" ")}
              </li>
            );
          })}
        </ol>
      )}
      {collapsing.length > 0 && (
        <div className="conversation-live-collapse" aria-hidden="true">
          <ol className="conversation-live-steps">
            {collapsing.map((step, index) => (
              <li key={step.id || index} className="conversation-live-step">{stepLine(step, root).filter(Boolean).join(" ")}</li>
            ))}
          </ol>
        </div>
      )}
      {open && (
        <ol className="conversation-steps">
          {entries.map((entry, index) => entry.type === "note"
            ? <li key={`note-${index}`} className="conversation-note">{entry.message.text}</li>
            : <Step key={entry.step.id || index} step={entry.step} onOpenSession={onOpenSession} sessionExists={sessionExists} />)}
        </ol>
      )}
      {!running && turn.answer && <div className="conversation-trail-rule" aria-hidden="true" />}
    </div>
  );
}

const FILES_COLLAPSED = 5;

/// What the turn changed, as a card: a summary header and one row per file
/// that opens its diff.
function FilesChanged({ files }) {
  const [showAll, setShowAll] = useState(false);
  if (!files.length) return null;
  const additions = files.reduce((sum, file) => sum + file.additions, 0);
  const deletions = files.reduce((sum, file) => sum + file.deletions, 0);
  const visible = showAll ? files : files.slice(0, FILES_COLLAPSED);
  return (
    <section className="conversation-files" aria-label="Files changed">
      <header className="conversation-files-head">
        <span className="conversation-files-title">{files.length === 1 ? "Edited 1 file" : `Edited ${files.length} files`}</span>
        <ChangeCount additions={additions} deletions={deletions} />
      </header>
      {visible.map(file => <FileRow key={file.file} file={file} />)}
      {files.length > FILES_COLLAPSED && (
        <button type="button" className="conversation-files-more" onClick={() => setShowAll(value => !value)}>
          <span className={`conversation-caret${showAll ? " open" : ""}`} aria-hidden="true">›</span>
          {showAll ? "Show fewer files" : `Show ${files.length - FILES_COLLAPSED} more files`}
        </button>
      )}
    </section>
  );
}

function FileRow({ file }) {
  const [open, setOpen] = useState(false);
  const root = useContext(ConversationRoot);
  const hasDiff = file.diffs.some(Boolean);
  return (
    <div className="conversation-file">
      <button type="button" className="conversation-file-row" disabled={!hasDiff} onClick={() => setOpen(value => !value)} aria-expanded={hasDiff ? open : undefined}>
        <span className="conversation-file-name" title={file.file}>{displayPath(file.file, root)}</span>
        <ChangeCount additions={file.additions} deletions={file.deletions} />
        {hasDiff && <span className={`conversation-caret down${open ? " open" : ""}`} aria-hidden="true">›</span>}
      </button>
      {open && file.diffs.map((diff, index) => <DiffBlock key={index} diff={diff} />)}
    </div>
  );
}

/// Copy and the time the answer landed, quiet under the answer.
function AnswerFooter({ answer, endedAt }) {
  const [copied, setCopied] = useState(false);
  const copy = async () => {
    try {
      await navigator.clipboard.writeText(answer);
      setCopied(true);
      setTimeout(() => setCopied(false), 1200);
    } catch {
      setCopied(false);
    }
  };
  return (
    <div className="conversation-answer-footer">
      <button type="button" className="conversation-icon-button" onClick={copy} aria-label={copied ? "Copied" : "Copy answer"} title="Copy answer">
        {copied ? "✓" : <CopyIcon />}
      </button>
      {endedAt > 0 && <time dateTime={new Date(endedAt).toISOString()}>{formatAnswerTime(endedAt)}</time>}
    </div>
  );
}

function formatAnswerTime(milliseconds) {
  const date = new Date(milliseconds);
  const today = new Date();
  const sameDay = date.toDateString() === today.toDateString();
  return sameDay
    ? date.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })
    : date.toLocaleString([], { weekday: "short", hour: "2-digit", minute: "2-digit" });
}

function CopyIcon() {
  return (
    <svg viewBox="0 0 16 16" width="13" height="13" aria-hidden="true" fill="none" stroke="currentColor" strokeWidth="1.3">
      <rect x="5" y="5" width="8.5" height="8.5" rx="1.8" />
      <path d="M10.5 5V3.8A1.8 1.8 0 0 0 8.7 2H3.8A1.8 1.8 0 0 0 2 3.8v4.9a1.8 1.8 0 0 0 1.8 1.8H5" />
    </svg>
  );
}

export const Turn = memo(function Turn({ turn, live, waiting, onOpenSession, sessionExists }) {
  const running = live && turn.status === "running";
  const answer = running ? visibleStreamingText(turn.answer, turn.answerComplete) : turn.answer;
  return (
    <article className="conversation-turn" data-turn={turn.id}>
      {turn.user && (
        <div className="conversation-prompt">
          <div className="conversation-prompt-text">{turn.user.text}</div>
          {turn.user.attachments?.length > 0 && (
            <div className="conversation-prompt-meta">{turn.user.attachments.map(item => item?.name).filter(Boolean).join(", ")}</div>
          )}
        </div>
      )}
      <Reasoning reasoning={{ ...turn.reasoning, done: Boolean(turn.answer || turn.steps.length) }} running={running} />
      <WorkTrail turn={turn} running={running} waiting={waiting} onOpenSession={onOpenSession} sessionExists={sessionExists} />
      {answer && <Markdown text={answer} />}
      {turn.notices.map(notice => <p key={notice.id} className="conversation-notice">{notice.text}</p>)}
      {turn.errors.map(error => <p key={error.id} className="conversation-error" role="alert">{error.text}</p>)}
      {!running && turn.status === "cancelled" && !turn.errors.length && <p className="conversation-notice">Stopped.</p>}
      <FilesChanged files={turn.files} />
      {!running && turn.answer && <AnswerFooter answer={turn.answer} endedAt={turn.endedAt || 0} />}
    </article>
  );
});

/// A quiet chip in the composer's lower row that opens the selectors it
/// stands for (RFC 0023 §6.11) above the composer, and, on the model chip,
/// the way out to the provider's own terminal UI (§6.12).
export function SelectorChip({ label, icon = null, config, onSetConfig, canHandoff = false, handoffBlocked = "", onHandoff = async () => {} }) {
  const [open, setOpen] = useState(false);
  const [pending, setPending] = useState("");
  const [error, setError] = useState("");
  const [filter, setFilter] = useState("");
  const rootRef = useRef(null);
  useEffect(() => {
    if (!open) return undefined;
    const close = event => {
      if (event.type === "keydown" && event.key !== "Escape") return;
      if (event.type === "pointerdown" && rootRef.current?.contains(event.target)) return;
      setOpen(false);
    };
    document.addEventListener("pointerdown", close);
    document.addEventListener("keydown", close);
    return () => {
      document.removeEventListener("pointerdown", close);
      document.removeEventListener("keydown", close);
    };
  }, [open]);
  useEffect(() => {
    if (!open) {
      setError("");
      setFilter("");
    }
  }, [open]);
  if (!config.length && !canHandoff) return null;
  const choose = async (option, value) => {
    if (pending || value === option.currentValue) return;
    setPending(`${option.id}\u0000${value}`);
    setError("");
    try {
      await onSetConfig(option.id, value);
      setOpen(false);
    } catch (reason) {
      setError(String(reason?.message || reason || "The agent did not accept the change"));
    } finally {
      setPending("");
    }
  };
  const handoff = async () => {
    if (pending || handoffBlocked) return;
    setPending("handoff");
    setError("");
    try {
      await onHandoff();
      setOpen(false);
    } catch (reason) {
      setError(String(reason?.message || reason || "The terminal did not start"));
    } finally {
      setPending("");
    }
  };
  const query = filter.trim().toLowerCase();
  return (
    <div className="composer-chip-root" ref={rootRef}>
      <button type="button" className={`composer-chip${open ? " open" : ""}`} onClick={() => setOpen(value => !value)} aria-haspopup="menu" aria-expanded={open}>
        {icon}
        <span className="composer-chip-label">{label}</span>
        <span className="composer-chip-chevron" aria-hidden="true">⌄</span>
      </button>
      {open && (
        <div className="conversation-menu" role="menu" aria-label="Agent settings">
          {config.map(option => {
            if (isToggleOption(option)) {
              const on = option.currentValue.toLowerCase() === "on";
              const next = option.options.find(choice => choice.value.toLowerCase() === (on ? "off" : "on"));
              return (
                <section key={option.id} className="conversation-menu-section" aria-label={option.name}>
                  <button
                    type="button"
                    role="menuitemcheckbox"
                    aria-checked={on}
                    className="conversation-menu-item conversation-menu-toggle"
                    disabled={Boolean(pending) || !next}
                    onClick={() => next && choose(option, next.value)}
                  >
                    <span className="conversation-menu-label">{option.name}</span>
                    <span className={`conversation-switch${on ? " on" : ""}`} aria-hidden="true" />
                  </button>
                </section>
              );
            }
            const long = option.options.length > 12;
            const visible = long && query
              ? option.options.filter(choice => `${choice.name} ${choice.group} ${choice.value}`.toLowerCase().includes(query))
              : option.options;
            let group = null;
            return (
              <section key={option.id} className="conversation-menu-section" aria-label={option.name}>
                <div className="conversation-menu-heading">{option.name}</div>
                {long && (
                  <input
                    className="conversation-menu-filter"
                    type="search"
                    value={filter}
                    placeholder={`Filter ${option.name.toLowerCase()}`}
                    onChange={event => setFilter(event.target.value)}
                    aria-label={`Filter ${option.name}`}
                  />
                )}
                <div className={`conversation-menu-options${long ? " long" : ""}`}>
                  {visible.map(choice => {
                    const header = choice.group && choice.group !== group ? choice.group : null;
                    group = choice.group || group;
                    const checked = choice.value === option.currentValue;
                    return (
                      <div key={choice.value}>
                        {header && <div className="conversation-menu-group">{header}</div>}
                        <button
                          type="button"
                          role="menuitemradio"
                          aria-checked={checked}
                          className="conversation-menu-item"
                          disabled={Boolean(pending)}
                          aria-busy={pending === `${option.id}\u0000${choice.value}` || undefined}
                          title={choice.description || undefined}
                          onClick={() => choose(option, choice.value)}
                        >
                          <span className="conversation-menu-text">
                            <span className="conversation-menu-label">{choice.name}</span>
                            {choice.description && choice.description !== choice.name && <span className="conversation-menu-description">{choice.description}</span>}
                          </span>
                          <span className="conversation-menu-check" aria-hidden="true">{checked ? "✓" : ""}</span>
                        </button>
                      </div>
                    );
                  })}
                  {visible.length === 0 && <p className="conversation-menu-empty">No match</p>}
                </div>
              </section>
            );
          })}
          {canHandoff && (
            <section className="conversation-menu-section">
              <button
                type="button"
                role="menuitem"
                className="conversation-menu-item"
                disabled={Boolean(pending) || Boolean(handoffBlocked)}
                aria-busy={pending === "handoff" || undefined}
                onClick={handoff}
              >
                <span className="conversation-menu-check" aria-hidden="true" />
                <span className="conversation-menu-label">Continue in terminal</span>
              </button>
              {handoffBlocked && <p className="conversation-menu-note">{handoffBlocked}</p>}
            </section>
          )}
          {error && <p className="conversation-error" role="alert">{error}</p>}
        </div>
      )}
    </div>
  );
}

/// How full the agent's context is: a small ring and the percentage.
export function ContextMeter({ context }) {
  if (!context?.size) return null;
  const fraction = Math.min(1, Math.max(0, context.used / context.size));
  const percent = Math.round(fraction * 100);
  const radius = 5;
  const circumference = 2 * Math.PI * radius;
  const format = value => value >= 1_000_000 ? `${(value / 1_000_000).toFixed(1).replace(/\.0$/, "")}M` : value >= 1000 ? `${Math.round(value / 1000)}k` : String(value);
  return (
    <span className={`composer-context${fraction > 0.85 ? " high" : ""}`} title={`Context ${percent}% · ${format(context.used)} of ${format(context.size)} tokens`} aria-label={`Context ${percent} percent used`}>
      <svg viewBox="0 0 14 14" width="12" height="12" aria-hidden="true">
        <circle cx="7" cy="7" r={radius} className="composer-context-track" />
        <circle cx="7" cy="7" r={radius} className="composer-context-fill" strokeDasharray={`${circumference * fraction} ${circumference}`} transform="rotate(-90 7 7)" />
      </svg>
      {percent}%
    </span>
  );
}

/// The agent's plan on the composer's top edge: progress and the current
/// step, opening into the checklist.
export function PlanStrip({ plan }) {
  const [open, setOpen] = useState(false);
  if (!plan || !plan.total) return null;
  return (
    <div className="composer-plan">
      <button type="button" className="composer-plan-toggle" onClick={() => setOpen(value => !value)} aria-expanded={open}>
        <span className="composer-plan-count">Plan {plan.done}/{plan.total}</span>
        {plan.current && plan.done < plan.total && <span className="composer-plan-current">{plan.current}</span>}
        <span className={`conversation-caret down${open ? " open" : ""}`} aria-hidden="true">›</span>
      </button>
      {open && (
        <ol className="composer-plan-list">
          {plan.entries.map((entry, index) => (
            <li key={index} className={`plan-${entry.state}`}>{entry.title}</li>
          ))}
        </ol>
      )}
    </div>
  );
}

const MODE_ICONS = {
  plan: "M3 3.5h10M3 8h10M3 12.5h6",
  default: "M8 2.5v6M5.5 5v4.5a2.5 2.5 0 0 0 5 0V5",
  acceptedits: "M3 13l1-3.5L11 2.5 13.5 5 6.5 12z",
  bypasspermissions: "M8 2l5 2v4c0 3-2.2 5.2-5 6-2.8-.8-5-3-5-6V4zM8 5.5v3M8 10.5v.1",
};

/// The permission mode's glyph: a shield unless the mode says otherwise.
export function ModeIcon({ value }) {
  const path = MODE_ICONS[String(value || "").toLowerCase()] || "M8 2l5 2v4c0 3-2.2 5.2-5 6-2.8-.8-5-3-5-6V4zM5.8 8l1.6 1.6L10.4 6.5";
  return (
    <svg viewBox="0 0 16 16" width="13" height="13" aria-hidden="true" fill="none" stroke="currentColor" strokeWidth="1.3" strokeLinecap="round" strokeLinejoin="round">
      <path d={path} />
    </svg>
  );
}
