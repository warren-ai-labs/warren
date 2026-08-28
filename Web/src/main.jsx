import { createRoot } from "react-dom/client";

import App from "./App.jsx";
import DesktopDiffApp from "./desktop-diff.jsx";

const root = document.getElementById("root");

if (!root) {
  throw new Error("Warren Web root element is missing");
}

const isDesktopDiff = new URLSearchParams(window.location.search).get("desktop-diff") === "1";

createRoot(root).render(isDesktopDiff ? <DesktopDiffApp /> : <App />);
