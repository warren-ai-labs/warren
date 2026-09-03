import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  // Relative asset URLs let the same build run at the origin root, behind a
  // Relay route (/t/<name>) or behind any reverse-proxy sub-path.
  base: "./",
  plugins: [react()],
  worker: {
    format: "es",
  },
  build: {
    outDir: "dist",
    emptyOutDir: true,
    sourcemap: true,
    cssCodeSplit: false,
    rollupOptions: {
      output: {
        entryFileNames: "assets/app.js",
        chunkFileNames: "assets/[name].js",
        assetFileNames: ({ names = [] }) => names.some(name => name.endsWith(".css"))
          ? "assets/app.css"
          : "assets/[name][extname]",
        manualChunks(id) {
          if (id.includes("vite/preload-helper")) return "react";
          if (!id.includes("/node_modules/")) return;
          if (id.includes("/@xterm/")) return "xterm";
          if (id.includes("/@pierre/")) return "diffs";
          if (/[\\/]node_modules[\\/](react|react-dom|scheduler)[\\/]/.test(id)) return "react";
          if (
            id.includes("/react-markdown/") ||
            id.includes("/remark-") ||
            id.includes("/micromark") ||
            id.includes("/mdast-") ||
            id.includes("/hast-") ||
            id.includes("/unist-") ||
            id.includes("/vfile") ||
            id.includes("/property-information/")
          ) return "agent-markdown";
        },
      },
    },
  },
  server: {
    port: 5173,
    strictPort: true,
    proxy: {
      // The daemon owns the WebSocket endpoint; proxying lets the Vite dev
      // server show the redesigned Web UI against the same local headless
      // Host the Desktop client uses, so both packages can be viewed
      // side by side in one session.
      "/v1/ws": {
        target: "http://127.0.0.1:8789",
        changeOrigin: true,
        ws: true,
      },
    },
  },
});
