import { memo, useMemo, useRef } from "react";
import { File, PatchDiff, Virtualizer, WorkerPoolContextProvider } from "@pierre/diffs/react";
import PierreDiffWorker from "@pierre/diffs/worker/worker.js?worker&type=module";
import { rovingIndex } from "./roving.js";

const DIFF_THEMES = {
  dark: "pierre-dark",
  light: "pierre-light",
};

const DIFF_LANGUAGES = [
  "text", "ansi", "js", "jsx", "ts", "tsx", "json", "css", "html", "xml",
  "go", "python", "shell", "markdown", "yaml", "toml", "sql",
  "java", "c", "cpp", "rust", "diff", "ini", "dockerfile", "graphql",
];

function diffOptions(diffStyle, themeType = "dark") {
  return {
    theme: DIFF_THEMES,
    themeType: themeType === "light" ? "light" : "dark",
    diffStyle,
    diffIndicators: "classic",
    lineDiffType: "word",
    disableFileHeader: true,
    enableLineSelection: true,
    lineHoverHighlight: "number",
  };
}

function fileOptionsFor(themeType = "dark") {
  return {
    theme: DIFF_THEMES,
    themeType: themeType === "light" ? "light" : "dark",
    disableFileHeader: true,
  };
}

const POOL_OPTIONS = {
  poolSize: 2,
  workerFactory: () => new PierreDiffWorker(),
};

const HIGHLIGHTER_OPTIONS = {
  langs: DIFF_LANGUAGES,
  theme: DIFF_THEMES,
};

export function DiffWorkerProvider({ children }) {
  return (
    <WorkerPoolContextProvider
      poolOptions={POOL_OPTIONS}
      highlighterOptions={HIGHLIGHTER_OPTIONS}
    >
      {children}
    </WorkerPoolContextProvider>
  );
}

const VIEW_TABS = ["diff", "file"];

export const FileDiffView = memo(function FileDiffView({
  path,
  staged,
  commit,
  loading,
  diff,
  content,
  error,
  notice,
  onClose,
  viewTab = "diff",
  diffStyle = "unified",
  theme = "dark",
  onViewTabChange,
  onDiffStyleChange,
}) {
  const diffTabRef = useRef(null);
  const fileTabRef = useRef(null);
  const options = useMemo(() => diffOptions(diffStyle, theme), [diffStyle, theme]);
  const fileOptions = useMemo(() => fileOptionsFor(theme), [theme]);
  const fileObject = useMemo(() => ({ name: path, contents: content }), [path, content]);

  const handleTabKeyDown = event => {
    const current = VIEW_TABS.indexOf(viewTab);
    const next = rovingIndex(event.key, current < 0 ? 0 : current, VIEW_TABS.length, { orientation: "horizontal" });
    if (next < 0) return;
    event.preventDefault();
    const nextTab = VIEW_TABS[next];
    onViewTabChange?.(nextTab);
    (nextTab === "diff" ? diffTabRef : fileTabRef).current?.focus();
  };

  return (
    <section className="file-diff-view" aria-label="File diff">
      <header className="file-diff-header">
        <div className="file-diff-title">
          <code className="file-diff-path">{path}</code>
          {staged && <span className="file-diff-badge">staged</span>}
          {commit && <code className="file-diff-commit">{commit}</code>}
        </div>
        <div className="file-diff-actions">
          <button type="button" className="chrome-button" aria-label="Close file diff" data-tooltip="Close" data-tooltip-shortcut="esc" onClick={onClose}>
            ✕
          </button>
        </div>
      </header>
      {loading ? (
        <p className="git-empty file-diff-empty">Loading diff…</p>
      ) : error ? (
        <p className="git-error file-diff-empty" role="alert">{error}</p>
      ) : (
        <>
          {notice && <p className="git-notice file-diff-notice" role="status">{notice}</p>}
          <div className="file-diff-tabs" role="tablist" aria-label="File diff view" onKeyDown={handleTabKeyDown}>
            <button
              ref={diffTabRef}
              type="button"
              className={viewTab === "diff" ? "file-diff-tab active" : "file-diff-tab"}
              data-label="Diff"
              aria-selected={viewTab === "diff"}
              tabIndex={viewTab === "diff" ? 0 : -1}
              role="tab"
              onClick={() => onViewTabChange?.("diff")}
            >
              Diff
            </button>
            <button
              ref={fileTabRef}
              type="button"
              className={viewTab === "file" ? "file-diff-tab active" : "file-diff-tab"}
              data-label="File"
              aria-selected={viewTab === "file"}
              tabIndex={viewTab === "file" ? 0 : -1}
              role="tab"
              onClick={() => onViewTabChange?.("file")}
            >
              File
            </button>
          </div>
          <div className="file-diff-body">
            {viewTab === "diff" ? (
              <>
                <div className="file-diff-style-toggle" role="group" aria-label="Diff layout">
                  <button
                    type="button"
                    className={diffStyle === "split" ? "file-diff-style-button active" : "file-diff-style-button"}
                    aria-pressed={diffStyle === "split"}
                    onClick={() => onDiffStyleChange?.("split")}
                  >
                    Split
                  </button>
                  <button
                    type="button"
                    className={diffStyle === "unified" ? "file-diff-style-button active" : "file-diff-style-button"}
                    aria-pressed={diffStyle === "unified"}
                    onClick={() => onDiffStyleChange?.("unified")}
                  >
                    Unified
                  </button>
                </div>
                <Virtualizer className="file-diff-pane-scroll">
                  <PatchDiff patch={diff} options={options} />
                </Virtualizer>
              </>
            ) : (
              <Virtualizer className="file-diff-pane-scroll">
                <File file={fileObject} options={fileOptions} />
              </Virtualizer>
            )}
          </div>
        </>
      )}
    </section>
  );
});

/// Keeps the diff worker pool alive across open/close cycles once the lazy
/// chunk has loaded, avoiding repeated worker teardown and startup.
export function FileDiffHost({ active, ...props }) {
  return (
    <DiffWorkerProvider>
      {active ? <FileDiffView {...props} /> : null}
    </DiffWorkerProvider>
  );
}
