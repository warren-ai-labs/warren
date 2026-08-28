import { lazy, Suspense, useEffect, useState } from "react";
import "./style.css";

const FileDiffView = lazy(() => import("./filediff.jsx").then(module => ({ default: module.FileDiffView })));

const EVENT_NAME = "warren-desktop-diff";
const INITIAL_STATE_KEY = "__WARREN_DESKTOP_DIFF__";

function postMessage(type, value) {
  const handler = window.webkit?.messageHandlers?.warrenDesktopDiff;
  if (!handler) return;
  handler.postMessage(value === undefined ? { type } : { type, value });
}

export default function DesktopDiffApp() {
  const [state, setState] = useState(() => window[INITIAL_STATE_KEY] || null);

  useEffect(() => {
    const receiveState = event => setState(event.detail || window[INITIAL_STATE_KEY] || null);
    window.addEventListener(EVENT_NAME, receiveState);
    return () => window.removeEventListener(EVENT_NAME, receiveState);
  }, []);

  if (!state) {
    return <p className="git-empty file-diff-empty">Loading diff…</p>;
  }

  return (
    <Suspense fallback={<p className="git-empty file-diff-empty">Loading diff viewer…</p>}>
      <FileDiffView
        path={state.path || ""}
        staged={Boolean(state.staged)}
        commit={state.commit || ""}
        loading={Boolean(state.loading)}
        diff={state.diff || ""}
        content={state.content || ""}
        error={state.error || ""}
        notice={state.notice || ""}
        viewTab={state.viewTab === "file" ? "file" : "diff"}
        diffStyle={state.diffStyle === "split" ? "split" : "unified"}
        onClose={() => postMessage("close")}
        onViewTabChange={value => postMessage("viewTab", value)}
        onDiffStyleChange={value => postMessage("diffStyle", value)}
      />
    </Suspense>
  );
}
