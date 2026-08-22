import { useEffect, useMemo, useState } from "react";
import {
  normalizeGitPanel,
  relativeTime,
  statusLabel,
  statusSymbol,
  diffSummary,
} from "./git.js";

function DiffCounts({ added, deleted }) {
  if (!added && !deleted) return null;
  return (
    <span className="git-diff-counts">
      {added > 0 && <span className="git-diff-added">+{added}</span>}
      {deleted > 0 && <span className="git-diff-deleted">-{deleted}</span>}
    </span>
  );
}

function changeKey(change, commit = "") {
  return commit ? `${commit}:${change.path}` : `${change.staged ? "s" : "u"}:${change.path}`;
}

function GitActionIcon({ kind }) {
  if (kind === "refresh") {
    return (
      <svg className="git-action-icon" viewBox="0 0 16 16" aria-hidden="true">
        <path d="M13 5V2.5M13 2.5h-2.5M13 2.5A5.5 5.5 0 1 0 13.2 9" />
      </svg>
    );
  }
  if (kind === "pull") {
    return (
      <svg className="git-action-icon" viewBox="0 0 16 16" aria-hidden="true">
        <path d="M8 2v10M4.5 8.5 8 12l3.5-3.5" />
      </svg>
    );
  }
  return (
    <svg className="git-action-icon" viewBox="0 0 16 16" aria-hidden="true">
      <path d="M8 14V4M4.5 7.5 8 4l3.5 3.5" />
    </svg>
  );
}

function PullRequestIcon() {
  return (
    <svg className="git-pane-icon" viewBox="0 0 16 16" aria-hidden="true">
      <circle cx="4" cy="4" r="1.5" />
      <circle cx="4" cy="12" r="1.5" />
      <circle cx="12" cy="12" r="1.5" />
      <path d="M4 5.5v5M5.5 4H8a4 4 0 0 1 4 4v2.5" />
    </svg>
  );
}

function BranchIcon() {
  return (
    <svg className="git-pane-icon" viewBox="0 0 16 16" aria-hidden="true">
      <circle cx="4" cy="4" r="1.5" />
      <circle cx="4" cy="12" r="1.5" />
      <circle cx="12" cy="6" r="1.5" />
      <path d="M4 5.5v5M4 5.5c2.5.4 4.5 1.8 5.2 4.1M12 7.5v.2a2.2 2.2 0 0 1-2.2 2.2" />
    </svg>
  );
}

function ChangeRow({ change, commit = "", selected, onOpenFile }) {
  return (
    <li>
      <button
        type="button"
        className={`git-change${selected ? " selected" : ""}`}
        aria-pressed={selected}
        onClick={() => onOpenFile(change, commit)}
      >
        <span className={`git-status git-status-${change.status}`} title={statusLabel(change.status)}>
          {statusSymbol(change.status)}
        </span>
        <span className="git-change-path">
          {change.path}
          {change.renameFrom && <span className="git-rename-from"> ← {change.renameFrom}</span>}
        </span>
        <DiffCounts added={change.added} deleted={change.deleted} />
      </button>
    </li>
  );
}

const operationLabels = {
  rebase: "Rebase",
  merge: "Merge",
  "cherry-pick": "Cherry-pick",
  revert: "Revert",
};

const actionLabels = {
  "git.pull": "Pulling",
  "git.push": "Pushing",
  "git.checkout": "Switching branches",
  "git.commit": "Committing",
  "git.pr.create": "Creating pull request",
};

const prStateLabels = {
  open: "Open",
  merged: "Merged",
  closed: "Closed",
};

function PullRequestView({ pr }) {
  return (
    <div className="git-pr">
      <div className="git-pr-header">
        <PullRequestIcon />
        <span className="git-pr-number">#{pr.number}</span>
        <span className={`git-pr-state git-pr-state-${pr.state}`}>{prStateLabels[pr.state] || pr.state}</span>
        {pr.draft && <span className="git-pr-draft">Draft</span>}
      </div>
      <p className="git-pr-title">{pr.title}</p>
      <p className="git-pr-meta">
        {pr.author} · {pr.base} ← {pr.head}
      </p>
      {pr.body && <p className="git-pr-body">{pr.body}</p>}
      <a className="chrome-button git-pr-link" href={pr.url} target="_blank" rel="noreferrer">
        Open pull request ↗
      </a>
    </div>
  );
}

function GitPane({ title, open, onToggle, className = "", children }) {
  return (
    <div className={`git-pane${open ? "" : " collapsed"}${className ? ` ${className}` : ""}`}>
      <button
        type="button"
        className="git-pane-header"
        aria-expanded={open}
        onClick={onToggle}
      >
        <span className="git-pane-header-title">{title}</span>
        <span className="git-pane-chevron" aria-hidden="true">{open ? "▾" : "▸"}</span>
      </button>
      {open && <div className="git-pane-content">{children}</div>}
    </div>
  );
}

function ChangeSection({ title, changes, selectedKey, onOpenFile, showTitle = true }) {
  if (!changes.length) return null;
  const summary = diffSummary(changes);
  return (
    <section className="git-section">
      {showTitle && (
        <h3 className="git-section-title">
          {title} ({changes.length})
          <DiffCounts added={summary.added} deleted={summary.deleted} />
        </h3>
      )}
      <ul className="git-change-list">
        {changes.map((change, index) => (
          <ChangeRow
            key={`${change.path}-${change.status}-${change.staged}-${index}`}
            change={change}
            selected={selectedKey === changeKey(change)}
            onOpenFile={onOpenFile}
          />
        ))}
      </ul>
    </section>
  );
}

export function GitPanel({
  workspaceName,
  panel,
  refreshing,
  error,
  action,
  onRefresh,
  onPull,
  onPush,
  onCheckout,
  onOpenFile,
  onCommit,
  onCreatePR,
  onClose,
  saved = null,
  onUIChange = null,
}) {
  const data = useMemo(() => (panel ? normalizeGitPanel(panel) : null), [panel]);
  const [branch, setBranch] = useState(saved?.branch || "");
  const [branchTouched, setBranchTouched] = useState(Boolean(saved?.branch));
  const [newBranch, setNewBranch] = useState("");
  const [createMode, setCreateMode] = useState(false);
  const [expanded, setExpanded] = useState(() => new Set(saved?.expanded || []));
  const [openPanes, setOpenPanes] = useState(() => new Set(
    saved?.openPanes ? saved.openPanes : ["checkout", "pr", "changes", "history"],
  ));
  const [selectedKey, setSelectedKey] = useState(saved?.selectedKey || null);
  const [commitOpen, setCommitOpen] = useState(false);
  const [commitMessage, setCommitMessage] = useState("");
  const [prOpen, setPrOpen] = useState(false);
  const [prTitle, setPrTitle] = useState("");
  const [prBody, setPrBody] = useState("");
  const [asyncNotice, setAsyncNotice] = useState(false);
  const busy = Boolean(action);
  const panelTitle = data?.branch || workspaceName || "Git";
  const changeCount = (data?.staged?.length || 0) + (data?.unstaged?.length || 0);
  const historyCommits = data?.mainBranch && !data.operation ? (data.unmergedCommits || []) : (data?.commits || []);
  const mainShort = data?.mainBranch?.includes("/") ? data.mainBranch.slice(data.mainBranch.indexOf("/") + 1) : data?.mainBranch || "";
  const canCreatePR = Boolean(
    data && data.remote && data.branch && data.mainBranch &&
    data.branch !== mainShort && !data.merged && !data.operation &&
    !data.pullRequest && !data.pullRequestError && data.unmergedCommits.length > 0,
  );

  useEffect(() => {
    if (!data?.refreshing) return;
    setAsyncNotice(true);
    const timer = setTimeout(() => setAsyncNotice(false), 2000);
    return () => clearTimeout(timer);
  }, [data?.refreshing]);

  const openCommit = () => {
    setCommitMessage("");
    setCommitOpen(true);
  };

  const submitCommit = () => {
    const message = commitMessage.trim();
    if (!message) return;
    setCommitOpen(false);
    onCommit(message);
  };

  const openCreatePR = () => {
    const commits = data?.unmergedCommits || [];
    setPrTitle(commits[0]?.subject || data?.branch || "");
    setPrBody(commits.map(commit => `- ${commit.subject} (${commit.short})`).join("\n"));
    setPrOpen(true);
  };

  const submitCreatePR = () => {
    const title = prTitle.trim();
    if (!title) return;
    setPrOpen(false);
    onCreatePR(title, prBody.trim());
  };

  useEffect(() => {
    if (!branchTouched && data?.branch && data.branches.local.includes(data.branch)) {
      setBranch(data.branch);
    }
  }, [branchTouched, data]);

  const openFile = (change, commit = "") => {
    const key = changeKey(change, commit);
    setSelectedKey(previous => (previous === key ? null : key));
    onOpenFile(change, commit);
  };

  const toggleCommit = hash => {
    setExpanded(previous => {
      const next = new Set(previous);
      if (next.has(hash)) next.delete(hash);
      else next.add(hash);
      return next;
    });
  };

  const togglePane = key => {
    setOpenPanes(previous => {
      const next = new Set(previous);
      if (next.has(key)) next.delete(key);
      else next.add(key);
      return next;
    });
  };

  useEffect(() => {
    if (!onUIChange) return;
    onUIChange({
      openPanes: [...openPanes],
      selectedKey,
      expanded: [...expanded],
      branch: branchTouched ? branch : null,
    });
  }, [onUIChange, openPanes, selectedKey, expanded, branchTouched, branch]);

  const submitCheckout = () => {
    if (createMode) {
      const name = newBranch.trim();
      if (name) onCheckout(name, true);
    } else if (branch) {
      onCheckout(branch, false);
    }
  };

  return (
    <aside className="git-panel" aria-label="Git">
      <header className="git-panel-header">
        <strong className="git-panel-title" title={panelTitle}>{panelTitle}</strong>
        <div className="git-panel-header-actions">
          {(refreshing && data) || asyncNotice ? (
            <span className="git-spinner" title={asyncNotice ? "Refreshing in the background" : "Refreshing"} aria-label="Refreshing" />
          ) : null}
          <button type="button" className="chrome-button" aria-label="Close Git panel" onClick={onClose}>
            ✕
          </button>
        </div>
      </header>

      {error && <div className="git-error">{error}</div>}

      <div className="git-panel-body">
        {refreshing && !data && (
          <div className="git-loading">
            <span className="git-spinner" aria-hidden="true" />
            {action ? `${actionLabels[action] || "Running git command"}…` : "Loading…"}
          </div>
        )}
        <div className="git-scroll">
        <section className="git-section git-fixed-section git-branch-section">
          {data?.operation && (
            <div className="git-operation-warning">
              {operationLabels[data.operation] || data.operation} in progress — resolve it before pushing or pulling
            </div>
          )}
          {data?.upstream && (
            <div className="git-tracking-line">
              <span className="git-tracking-label">Tracks</span>
              <span className="git-upstream">{data.upstream}</span>
            </div>
          )}
          {data?.mainBranch && !data.operation && data.merged && (
            <div className="git-merged-badge">Merged into {data.mainBranch}</div>
          )}
          {data?.upstream && (
            <div className="git-ahead-behind">
              {data.ahead > 0 && <span className="git-ahead">↑ {data.ahead} ahead</span>}
              {data.behind > 0 && <span className="git-behind">↓ {data.behind} behind</span>}
              {data.ahead <= 0 && data.behind <= 0 && (
                <span className="git-synced">Synced with {data.upstream}</span>
              )}
            </div>
          )}
          {data?.remote && <div className="git-remote">{data.remote}</div>}
          <div className="git-actions" role="group" aria-label="Git actions">
            <button type="button" className="chrome-button git-action-refresh" onClick={onRefresh} disabled={busy}>
              <GitActionIcon kind="refresh" />
              Refresh
            </button>
            <button type="button" className="chrome-button git-action-pull" onClick={onPull} disabled={busy || !data}>
              <GitActionIcon kind="pull" />
              {action === "git.pull" ? "Pulling…" : "Pull"}
            </button>
            <button
              type="button"
              className="chrome-button git-action-push"
              onClick={() => {
                if (data && (data.staged.length || data.unstaged.length)) openCommit();
                else onPush();
              }}
              disabled={busy || !data}
            >
              <GitActionIcon kind="push" />
              {action === "git.push" ? "Pushing…" : "Push"}
            </button>
          </div>
          {commitOpen && (
            <div className="git-commit-box">
              <p className="git-commit-hint">Commit changes before pushing</p>
              <input
                className="git-input"
                value={commitMessage}
                onChange={event => setCommitMessage(event.target.value)}
                placeholder="Commit message"
                autoFocus
                onKeyDown={event => {
                  if (event.key === "Enter") submitCommit();
                  if (event.key === "Escape") setCommitOpen(false);
                }}
              />
              <div className="git-commit-actions">
                <button type="button" className="chrome-button" onClick={submitCommit} disabled={!commitMessage.trim() || busy}>
                  {action === "git.commit" ? "Committing…" : "Commit & Push"}
                </button>
                <button type="button" className="chrome-button" onClick={() => setCommitOpen(false)}>
                  Cancel
                </button>
              </div>
            </div>
          )}
        </section>

        <GitPane
          title={<><BranchIcon />Checkout</>}
          className="git-pane-checkout"
          open={openPanes.has("checkout")}
          onToggle={() => togglePane("checkout")}
        >
          <div className="git-checkout-row">
            {createMode ? (
              <input
                className="git-input"
                value={newBranch}
                onChange={event => setNewBranch(event.target.value)}
                placeholder="New branch name"
                onKeyDown={event => {
                  if (event.key === "Enter") submitCheckout();
                }}
              />
            ) : (
              <select
                className="git-select"
                aria-label="Branch"
                value={branch}
                onChange={event => {
                  setBranch(event.target.value);
                  setBranchTouched(true);
                }}
                disabled={!data?.branches.local.length && !data?.branches.remote.length}
              >
                <option value="">Switch to a branch…</option>
                {data?.branches.local.map(name => <option key={`l-${name}`} value={name}>{name}</option>)}
                {data?.branches.remote.map(name => <option key={`r-${name}`} value={name}>{name} (remote)</option>)}
              </select>
            )}
            <div className="git-checkout-actions">
              <button type="button" className="chrome-button git-checkout-submit" onClick={submitCheckout} disabled={busy || (createMode ? !newBranch.trim() : !branch)}>
                {action === "git.checkout" ? "Switching…" : createMode ? "Create branch" : "Switch branch"}
              </button>
              <button
                type="button"
                className="chrome-button git-checkout-toggle"
                disabled={busy}
                onClick={() => {
                  setCreateMode(!createMode);
                  setNewBranch("");
                }}
              >
                {createMode ? "Existing branch" : "New branch"}
              </button>
            </div>
          </div>
        </GitPane>

        {data?.remote && (
          <GitPane title={<><PullRequestIcon />Pull Request</>} className="git-pane-pr" open={openPanes.has("pr")} onToggle={() => togglePane("pr")}>
            {data.aheadOfMain > 0 && data.mainBranch && (
              <p className="git-pr-meta git-pr-ahead">
                <span className="git-ahead">↑ {data.aheadOfMain} commit{data.aheadOfMain === 1 ? "" : "s"} ahead of {data.mainBranch}</span>
              </p>
            )}
            {data.pullRequest ? (
              <PullRequestView pr={data.pullRequest} />
            ) : data.pullRequestError ? (
              <p className="git-pr-error">{data.pullRequestError}</p>
            ) : canCreatePR ? (
              prOpen ? (
                <div className="git-pr-form">
                  <input
                    className="git-input"
                    value={prTitle}
                    onChange={event => setPrTitle(event.target.value)}
                    placeholder="Pull request title"
                    autoFocus
                    onKeyDown={event => {
                      if (event.key === "Enter") submitCreatePR();
                      if (event.key === "Escape") setPrOpen(false);
                    }}
                  />
                  <textarea
                    className="git-textarea"
                    value={prBody}
                    onChange={event => setPrBody(event.target.value)}
                    placeholder="Description"
                    rows={4}
                  />
                  <p className="git-commit-hint">
                    Merge into {data.mainBranch} from {data.branch}
                  </p>
                  <div className="git-commit-actions">
                    <button
                      type="button"
                      className="chrome-button git-pr-create-button"
                      onClick={submitCreatePR}
                      disabled={!prTitle.trim() || busy}
                    >
                      {action === "git.pr.create" ? "Creating…" : "Create pull request"}
                    </button>
                    <button type="button" className="chrome-button" onClick={() => setPrOpen(false)}>
                      Cancel
                    </button>
                  </div>
                </div>
              ) : (
                <button type="button" className="chrome-button git-pr-create-button" onClick={openCreatePR} disabled={busy}>
                  Create pull request
                </button>
              )
            ) : (
              <p className="git-empty">No pull request</p>
            )}
          </GitPane>
        )}

        <GitPane
          title={<>Changes{changeCount > 0 && ` (${changeCount})`}</>}
          className="git-pane-changes"
          open={openPanes.has("changes")}
          onToggle={() => togglePane("changes")}
        >
          <ChangeSection title="Staged" changes={data?.staged || []} selectedKey={selectedKey} onOpenFile={openFile} />
          <ChangeSection title="Changes" changes={data?.unstaged || []} selectedKey={selectedKey} onOpenFile={openFile} showTitle={false} />
        </GitPane>

        <GitPane
          title={<>History{data?.mainBranch && !data.merged && !data.operation && <span className="git-history-scope">not in {data.mainBranch}</span>}</>}
          className="git-pane-history"
          open={openPanes.has("history")}
          onToggle={() => togglePane("history")}
        >
          {!historyCommits.length && (
            <p className="git-empty">
              {data?.mainBranch && !data.operation ? `All commits are in ${data.mainBranch}` : "No commits"}
            </p>
          )}
          <ul className="git-commit-list">
            {historyCommits.map(commit => (
              <li key={commit.hash} className="git-commit">
                <button type="button" className="git-commit-summary" aria-expanded={expanded.has(commit.hash)} onClick={() => toggleCommit(commit.hash)}>
                  <span className="git-commit-subject">{commit.subject}</span>
                  <span className="git-commit-meta">
                    <code>{commit.short}</code> · {commit.author} · {relativeTime(commit.time)}
                    <DiffCounts {...diffSummary(commit.files)} />
                  </span>
                </button>
                {expanded.has(commit.hash) && (
                  <ul className="git-change-list">
                    {commit.files.map((file, index) => (
                      <ChangeRow
                        key={`${commit.hash}-${file.path}-${index}`}
                        change={file}
                        commit={commit.hash}
                        selected={selectedKey === changeKey(file, commit.hash)}
                        onOpenFile={openFile}
                      />
                    ))}
                  </ul>
                )}
              </li>
            ))}
          </ul>
        </GitPane>

        </div>
      </div>
    </aside>
  );
}
