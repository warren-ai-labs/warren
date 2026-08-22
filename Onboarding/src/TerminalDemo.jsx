import { useEffect, useRef, useState } from "react";
import { FitAddon, init, Terminal } from "ghostty-web";
import { useI18n } from "./i18n.jsx";

const theme = {
  background: "#151110",
  foreground: "#eae8e6",
  cursor: "#e07850",
  cursorAccent: "#151110",
  selectionBackground: "rgba(224, 120, 80, 0.28)",
  black: "#151110",
  red: "#dc6b6b",
  green: "#7ec699",
  yellow: "#e5c07b",
  blue: "#7ec0f5",
  magenta: "#c678dd",
  cyan: "#56b6c2",
  white: "#eae8e6",
  brightBlack: "#5c5856",
  brightRed: "#e88888",
  brightGreen: "#98d1a8",
  brightYellow: "#ecd08f",
  brightBlue: "#7ec0f5",
  brightMagenta: "#d494e6",
  brightCyan: "#73c7d3",
  brightWhite: "#ffffff",
};

const dim = "\x1b[90m";
const green = "\x1b[32m";
const cyan = "\x1b[36m";
const yellow = "\x1b[33m";
const bold = "\x1b[1m";
const reset = "\x1b[0m";

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const helpText = [
  `${dim}usage: warren <command>${reset}`,
  ``,
  `  ${green}ls${reset}         projects & workspaces`,
  `  ${green}sessions${reset}   durable sessions on this host`,
  `  ${green}attach${reset}     attach to a running session`,
  `  ${green}detach${reset}     leave a session running`,
  `  ${green}codex${reset}      open an agent session`,
  `  ${green}claude${reset}     open another agent session`,
  `  ${green}import${reset}     import projects from Superset`,
  `  ${green}neofetch${reset}   host info`,
  `  ${green}clear${reset}      clear the screen`,
].join("\r\n");

function printPrompt(term) {
  term.write(
    `\r\n${bold}${green}warren@mac-studio${reset} ${dim}~/workspace/warren${reset} ${green}main${reset}\r\n${bold}${green}❯${reset} `,
  );
}

function typeText(term, text, speed = 9) {
  return new Promise((resolve) => {
    let index = 0;
    const timer = setInterval(() => {
      term.write(text[index]);
      index += 1;
      if (index >= text.length) {
        clearInterval(timer);
        resolve();
      }
    }, speed);
  });
}

export default function TerminalDemo() {
  const { t } = useI18n();
  const hostRef = useRef(null);
  const termRef = useRef(null);
  const fitRef = useRef(null);
  const commandRef = useRef("");
  const busyRef = useRef(true);
  const [status, setStatus] = useState("loading");

  useEffect(() => {
    let cancelled = false;
    let term = null;
    let fit = null;
    const host = hostRef.current;

    async function boot() {
      const lines = [
        `${dim}warren-headless${reset} v0.8.1 ${dim}(ghostline v0.6.4 runtime)${reset}`,
        `${dim}host${reset} ${cyan}mac-studio${reset} ${dim}· ws://127.0.0.1:8789${reset}`,
        `${green}✓${reset} ${dim}restored${reset} ${cyan}warren/dev${reset} ${dim}· survived 2 detaches${reset}`,
        `${dim}terminal${reset} ${cyan}ghostty-wasm${reset} ${dim}· same VT parser as desktop${reset}`,
        ``,
        `${dim}type ${bold}help${reset}${dim} to explore${reset}`,
      ];
      for (const line of lines) {
        await typeText(term, line + "\r\n");
      }
      busyRef.current = false;
      printPrompt(term);
    }

    async function runCommand(term, raw) {
      const trimmed = raw.trim();
      if (!trimmed) {
        printPrompt(term);
        return;
      }
      const parts = trimmed.split(/\s+/);
      const cmd = parts[0] === "warren" ? (parts[1] || "help") : parts[0];
      const args = parts.slice(cmd === parts[0] ? 1 : 2);

      if (cmd === "help") {
        term.write(helpText + "\r\n");
      } else if (cmd === "ls") {
        term.write(
          [
            `${dim}projects/${reset}`,
            `  ${cyan}warren${reset}      ${dim}main · ~/Workspace/warren${reset}`,
            `    ${dim}workspaces:${reset}`,
            `      ${green}warren${reset}  ${dim}git worktree · main${reset}`,
            `      ${green}docs${reset}    ${dim}git worktree · docs/cleanup${reset}`,
            `  ${cyan}ghostline${reset}    ${dim}main · ~/Workspace/ghostline${reset}`,
          ].join("\r\n") + "\r\n",
        );
      } else if (cmd === "sessions") {
        term.write(
          [
            `${dim}ID            SCOPE       STATUS     RUNTIME${reset}`,
            `sess_9f2c     warren/dev  ${green}running${reset}    ghostline`,
            `sess_71ab     docs        ${green}running${reset}    ghostline`,
            `sess_03de     terminal    ${yellow}detached${reset}  tmux`,
            `${dim}3 sessions retained by host${reset}`,
          ].join("\r\n") + "\r\n",
        );
      } else if (cmd === "attach") {
        const target = args[0] || "warren/dev";
        term.write(`${dim}attaching to${reset} ${cyan}${target}${reset} ...\r\n`);
        await sleep(280);
        term.write(`${green}✓${reset} attached — scrollback restored, cursor at line 1184\r\n`);
        term.write(`${dim}warren/dev${reset} $ git status\r\n`);
        term.write(`${dim}On branch main${reset}\r\n${green}nothing to commit, working tree clean${reset}\r\n`);
      } else if (cmd === "detach") {
        const target = args[0] || "warren/dev";
        term.write(`${dim}detaching${reset} ${cyan}${target}${reset} ...\r\n`);
        await sleep(360);
        term.write(`${green}✓${reset} detached — session retained by host\r\n`);
        await sleep(360);
        term.write(`${dim}reattaching${reset} ...\r\n`);
        await sleep(280);
        term.write(
          `${green}✓${reset} resumed in 1.2s — work kept running while you were away:\r\n` +
            `${dim}  [00:00:04] npm test — 24 passed, 0 failed${reset}\r\n` +
            `${dim}  [00:00:11] git worktree add docs/cleanup${reset}\r\n`,
        );
      } else if (cmd === "codex") {
        term.write(
          [
            `${dim}warren codex${reset}`,
            `${yellow}▶${reset} task: add durable session restore test`,
            `${cyan}●${reset} agent working in warren/dev · attached`,
            `${green}✔${reset} 3 files changed, 1 test added`,
            `${green}✔${reset} session kept running after tab close`,
          ].join("\r\n") + "\r\n",
        );
      } else if (cmd === "claude") {
        term.write(
          [
            `${dim}warren claude${reset}`,
            `${yellow}▶${reset} task: workspace-first git worktrees`,
            `${cyan}●${reset} writing design note · 6 min`,
            `${green}✔${reset} PR #128 ready for review`,
          ].join("\r\n") + "\r\n",
        );
      } else if (cmd === "import") {
        term.write(`${dim}importing Superset metadata${reset} ...\r\n`);
        await sleep(360);
        term.write(`${green}✓${reset} 3 projects, 12 workspaces imported\r\n`);
        term.write(`${dim}receipt: import-2026-08-18 · runs once, no re-import${reset}\r\n`);
      } else if (cmd === "neofetch") {
        term.write(
          [
            `${cyan}warren@mac-studio${reset}`,
            `${dim}--------------------------${reset}`,
            `${green}OS${reset}:        macOS 26.0`,
            `${green}Runtime${reset}:   ghostline v0.6.4`,
            `${green}Terminal${reset}:  Ghostty VT parser (wasm)`,
            `${green}Uptime${reset}:    4 days, 2 hours`,
            `${green}Sessions${reset}:  3 durable`,
          ].join("\r\n") + "\r\n",
        );
      } else if (cmd === "clear") {
        term.clear();
      } else if (cmd === "exit") {
        term.write(
          `\r\nThis demo is a session. Close the tab — the host keeps it.\r\n` +
            `${bold}${green}Sessions belong to the host${reset}.\r\n`,
        );
      } else if (cmd === "whoami") {
        term.write(`you · this browser · ${bold}welcome${reset}\r\n`);
      } else {
        term.write(`${yellow}warren${reset}: command not found: ${cyan}${cmd}${reset}\r\n${dim}try 'help'${reset}\r\n`);
      }
    }

    function handleInput(term, data) {
      if (busyRef.current) return;
      const current = commandRef.current;

      if (data === "\r") {
        term.write("\r\n");
        const cmd = current;
        commandRef.current = "";
        busyRef.current = true;
        void runCommand(term, cmd).finally(() => {
          busyRef.current = false;
          if (cmd.trim() !== "clear") printPrompt(term);
          else {
            term.clear();
            printPrompt(term);
          }
        });
        return;
      }

      if (data === "\x7f" || data === "\b") {
        if (current.length > 0) {
          commandRef.current = current.slice(0, -1);
          term.write("\b \b");
        }
        return;
      }

      if (data === "\x03") {
        commandRef.current = "";
        term.write("^C\r\n");
        printPrompt(term);
        return;
      }

      if (/^[\x20-\x7e]$/.test(data)) {
        commandRef.current = current + data;
        term.write(data);
      }
    }

    async function start() {
      try {
        await init();
        if (cancelled || !host) return;
        term = new Terminal({
          fontSize: 13,
          fontFamily: 'ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace',
          cursorBlink: true,
          cursorStyle: "block",
          scrollback: 2000,
          theme,
        });
        fit = new FitAddon();
        term.loadAddon(fit);
        term.open(host);
        fit.fit();
        termRef.current = term;
        fitRef.current = fit;
        term.onData((data) => handleInput(term, data));
        setStatus("ready");
        void boot();
      } catch (error) {
        console.error("ghostty-web failed to start", error);
        setStatus("error");
      }
    }

    void start();

    const observer = new ResizeObserver(() => {
      fitRef.current?.fit();
    });
    if (host) observer.observe(host);

    return () => {
      cancelled = true;
      observer.disconnect();
      term?.dispose();
      termRef.current = null;
      fitRef.current = null;
    };
  }, []);

  return (
    <section id="demo" className="section terminal">
      <div className="section-head">
        <p className="kicker">{t("terminal.kicker")}</p>
        <h2>{t("terminal.title")}</h2>
        <p className="section-lede">{t("terminal.lede")}</p>
      </div>
      <div className="terminal-frame" onClick={() => termRef.current?.focus()}>
        <div className="terminal-bar">
          <span className="terminal-dots" aria-hidden="true">
            <i />
            <i />
            <i />
          </span>
          <span className="terminal-title">warren@mac-studio — ghostline · ghostty-wasm</span>
          <span className="terminal-badge">{t("terminal.badge")}</span>
        </div>
        <div className="terminal-screen" ref={hostRef}>
          {status !== "ready" && (
            <div className="terminal-loading">
              {status === "error"
                ? "ghostty-wasm failed to load"
                : "loading ghostty-wasm…"}
            </div>
          )}
        </div>
      </div>
      <div className="terminal-hint">
        <span className="terminal-hint-item">
          <span className="status-dot" aria-hidden="true" />
          {t("terminal.hint")}
        </span>
        <span className="terminal-hint-sep" aria-hidden="true">
          ·
        </span>
        <span className="terminal-hint-item">{t("terminal.engineNote")}</span>
      </div>
    </section>
  );
}
