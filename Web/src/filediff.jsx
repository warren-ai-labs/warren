import { memo, useMemo } from "react";
import { File, PatchDiff, Virtualizer, WorkerPoolContextProvider } from "@pierre/diffs/react";
import PierreDiffWorker from "@pierre/diffs/worker/worker.js?worker&type=module";

const DIFF_THEME = "pierre-dark";

const DIFF_LANGUAGES = [
  "text", "ansi", "js", "jsx", "ts", "tsx", "json", "css", "html", "xml",
  "go", "python", "shell", "markdown", "yaml", "toml", "sql",
  "java", "c", "cpp", "rust", "diff", "ini", "dockerfile", "graphql",
];

function diffOptions(diffStyle) {
  return {
    theme: DIFF_THEME,
    themeType: "dark",
    diffStyle,
    diffIndicators: "classic",
    lineDiffType: "word",
    disableFileHeader: true,
    enableLineSelection: true,
    lineHoverHighlight: "number",
  };
}

const fileOptions = {
  theme: DIFF_THEME,
  themeType: "dark",
  disableFileHeader: true,
};

function DiffSurface({ children }) {
  return (
    <WorkerPoolContextProvider
      poolOptions={{ poolSize: 2, workerFactory: () => new PierreDiffWorker() }}
      highlighterOptions={{ langs: DIFF_LANGUAGES, theme: DIFF_THEME }}
    >
      {children}
    </WorkerPoolContextProvider>
  );
}

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
  onViewTabChange,
  onDiffStyleChange,
}) {
  const options = useMemo(() => diffOptions(diffStyle), [diffStyle]);

  return (
    <section className="file-diff-view" aria-label="File diff">
      <header className="file-diff-header">
        <div className="file-diff-title">
          <code className="file-diff-path">{path}</code>
          {staged && <span className="file-diff-badge">staged</span>}
          {commit && <code className="file-diff-commit">{commit}</code>}
        </div>
        <div className="file-diff-actions">
          <button type="button" className="chrome-button" aria-label="Close file diff" onClick={onClose}>
            ✕
          </button>
        </div>
      </header>
      {loading ? (
        <p className="git-empty file-diff-empty">Loading diff…</p>
      ) : error ? (
        <p className="git-error file-diff-empty">{error}</p>
      ) : (
        <>
          {notice && <p className="git-notice file-diff-notice" role="status">{notice}</p>}
          <DiffSurface>
            <div className="file-diff-tabs" role="tablist" aria-label="File diff view">
              <button
                type="button"
                className={viewTab === "diff" ? "file-diff-tab active" : "file-diff-tab"}
                aria-selected={viewTab === "diff"}
                role="tab"
                onClick={() => onViewTabChange?.("diff")}
              >
                Diff
              </button>
              <button
                type="button"
                className={viewTab === "file" ? "file-diff-tab active" : "file-diff-tab"}
                aria-selected={viewTab === "file"}
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
                      onClick={() => onDiffStyleChange?.("split")}
                    >
                      Highlight
                    </button>
                    <button
                      type="button"
                      className={diffStyle === "unified" ? "file-diff-style-button active" : "file-diff-style-button"}
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
                  <File file={{ name: path, contents: content }} options={fileOptions} />
                </Virtualizer>
              )}
            </div>
          </DiffSurface>
        </>
      )}
    </section>
  );
});
