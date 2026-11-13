import { createRoot } from "react-dom/client";

import App from "./App.jsx";
import { installTooltips } from "./tooltip.js";

const root = document.getElementById("root");

if (!root) {
  throw new Error("Warren Web root element is missing");
}

installTooltips();
createRoot(root).render(<App />);
