import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  // Relative asset URLs let the same build run at the origin root, behind a
  // gnar tunnel (/t/<name>), or behind any reverse proxy sub-path.
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
          if (!id.includes("/node_modules/")) return;
          if (id.includes("/@xterm/")) return "xterm";
          if (id.includes("/react/") || id.includes("/react-dom/")) return "react";
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
