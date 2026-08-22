package main

import (
	"context"
	"crypto/rand"
	"crypto/tls"
	"encoding/base64"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"runtime/debug"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/abcdlsj/ghostline"
	"github.com/abcdlsj/warren/Headless/internal/agent"
	"github.com/abcdlsj/warren/Headless/internal/runtime"
	"github.com/abcdlsj/warren/Headless/internal/server"
	"github.com/abcdlsj/warren/Headless/internal/settings"
	"github.com/abcdlsj/warren/Headless/internal/store"
	"github.com/abcdlsj/warren/Headless/internal/tlscert"
	"github.com/abcdlsj/warren/Headless/internal/tunnel"
)

var version = "dev"

const tokenRepairInterval = time.Second

const ghostlineModulePath = "github.com/abcdlsj/ghostline"

// ghostlineReleaseVersion returns the module version embedded by the Go
// linker. A local replace or an unversioned development build may not expose a
// tag, so callers should treat an empty result as unknown.
func ghostlineReleaseVersion() string {
	buildInfo, ok := debug.ReadBuildInfo()
	if !ok {
		return ""
	}
	for _, dependency := range buildInfo.Deps {
		if dependency.Path != ghostlineModulePath {
			continue
		}
		if dependency.Replace != nil {
			if dependency.Replace.Version != "" && dependency.Replace.Version != "(devel)" {
				return dependency.Replace.Version
			}
			return ""
		}
		if dependency.Version == "(devel)" {
			return ""
		}
		return dependency.Version
	}
	return ""
}

func main() {
	configDir := defaultConfigDirectory()
	listen := flag.String("listen", env("WARREN_LISTEN", "0.0.0.0:8789"), "listen address (all interfaces by default for LAN access; token-protected, do not expose to the public internet)")
	lanHTTPS := flag.String("lan-https", env("WARREN_LAN_HTTPS", "0.0.0.0:8788"), "LAN HTTPS listen address (empty disables; local CA generated on first start)")
	tlsDir := flag.String("tls-dir", env("WARREN_TLS_DIR", filepath.Join(configDir, "tls")), "directory for the local CA and server certificate")
	statePath := flag.String("state", env("WARREN_STATE", filepath.Join(configDir, "state.json")), "state file")
	tokenPath := flag.String("token-file", env("WARREN_TOKEN_FILE", filepath.Join(configDir, "token")), "authentication token file")
	hostName := flag.String("name", env("WARREN_HOST_NAME", ""), "host display name")
	// tmux-socket is only consulted by the tmux runtime.
	tmuxSocket := flag.String("tmux-socket", env("WARREN_TMUX_SOCKET", "warren-headless"), "tmux socket name")
	runtimeMode := flag.String("runtime", env("WARREN_RUNTIME", ""), "default runtime kind: ghostline or tmux (overrides settings.json)")
	ghostlineSocket := flag.String("ghostline-socket", env("WARREN_GHOSTLINE_SOCKET", filepath.Join(configDir, "ghostline.sock")), "ghostline server socket path")
	ghostlineServe := flag.Bool("ghostline-serve", false, "internal: run the ghostline session server (spawned by the daemon)")
	ghostlineAdoptFrom := flag.String("adopt-from", "", "internal: adopt sessions from this old server admin socket")
	ghostlineProbeForeground := flag.Bool("ghostline-probe-foreground", envBool("WARREN_GHOSTLINE_PROBE_FOREGROUND", false), "probe OS-level foreground metadata in ghostline (default off)")
	settingsFile := flag.String("settings-file", env("WARREN_SETTINGS_FILE", filepath.Join(configDir, "settings.json")), "headless settings file")
	logFile := flag.String("log-file", env("WARREN_LOG_FILE", filepath.Join(configDir, "headless.log")), "daemon log file (empty disables file logging)")
	worktreeRoot := flag.String("worktree-root", env("WARREN_WORKTREE_ROOT", "~/.warren/worktrees"), "worktree root")
	outputDir := flag.String("output-dir", env("WARREN_OUTPUT_DIR", filepath.Join(configDir, "output")), "per-session tmux output spool directory")
	cloudflaredPath := flag.String("cloudflared-path", os.Getenv("WARREN_CLOUDFLARED_PATH"), "cloudflared binary path")
	tailscalePath := flag.String("tailscale-path", os.Getenv("WARREN_TAILSCALE_PATH"), "tailscale binary path")
	gnarPath := flag.String("gnar-path", os.Getenv("WARREN_GNAR_PATH"), "gnar binary path")
	gnarConfigDir := flag.String("gnar-config-dir", os.Getenv("WARREN_GNAR_CONFIG_DIR"), "gnar credential directory (bundled gnar defaults to ~/.warren/gnar)")
	gnarEdge := flag.String("gnar-edge", env("WARREN_GNAR_EDGE", ""), "gnar edge URL (overrides settings.json and the release default)")
	showVersion := flag.Bool("version", false, "print version")
	flag.Parse()
	if *showVersion {
		fmt.Println(version)
		return
	}
	gnarPathExplicit := strings.TrimSpace(os.Getenv("WARREN_GNAR_PATH")) != ""
	gnarConfigDirExplicit := strings.TrimSpace(os.Getenv("WARREN_GNAR_CONFIG_DIR")) != ""
	flag.Visit(func(entry *flag.Flag) {
		switch entry.Name {
		case "gnar-path":
			gnarPathExplicit = true
		case "gnar-config-dir":
			gnarConfigDirExplicit = true
		}
	})
	if !gnarPathExplicit {
		if bundled := bundledGnarPath(); bundled != "" {
			*gnarPath = bundled
			if !gnarConfigDirExplicit && strings.TrimSpace(*gnarConfigDir) == "" {
				*gnarConfigDir = filepath.Join(configDir, "gnar")
			}
		}
	}
	ghostlineSocketExplicit := os.Getenv("WARREN_GHOSTLINE_SOCKET") != ""
	flag.Visit(func(entry *flag.Flag) {
		if entry.Name == "ghostline-socket" {
			ghostlineSocketExplicit = true
		}
	})
	if err := validateGhostlinePaths(configDir, *statePath, *outputDir, *ghostlineSocket, ghostlineSocketExplicit); err != nil {
		fatal(err)
	}

	// Internal subprocess mode: the daemon spawns this binary with
	// --ghostline-serve so PTY sessions are owned by an independent process
	// that survives daemon upgrades and restarts.
	if *ghostlineServe {
		runGhostlineServe(*ghostlineSocket, *outputDir, *ghostlineAdoptFrom, *ghostlineProbeForeground)
		return
	}

	loadedSettings, err := settings.Load(*settingsFile)
	if err != nil {
		fatal(err)
	}
	builtInGnarEdge := settings.BuiltInGnarEdge()
	if builtInGnarEdge != "" {
		if err := tunnel.ValidateEdgeURL(builtInGnarEdge); err != nil {
			fatal(fmt.Errorf("invalid release gnar Edge: %w", err))
		}
	}
	// A launcher override remains useful for development and operators. When
	// it is absent, the release-injected Edge is the non-persisted fallback.
	gnarDefaultEdge := strings.TrimSpace(*gnarEdge)
	if gnarDefaultEdge == "" {
		gnarDefaultEdge = builtInGnarEdge
	}
	gnarEdgeValue := loadedSettings.GnarEdge
	gnarEdgeExplicit := false
	flag.Visit(func(entry *flag.Flag) {
		if entry.Name == "gnar-edge" {
			gnarEdgeExplicit = true
		}
	})
	if gnarEdgeExplicit {
		gnarEdgeValue = *gnarEdge
	} else if gnarEdgeValue == "" {
		// Fall back to the launcher environment, then the release default, when
		// settings.json does not pin an Edge. The source-build default is a safe
		// documented placeholder and release builds may replace it at link time.
		gnarEdgeValue = gnarDefaultEdge
	}
	// Strip launcher-only pager/TERM semantics (agent/CI shells export
	// GIT_PAGER=cat, PAGER=cat, TERM=dumb) before ghostline/tmux children
	// inherit the daemon environment, then let settings.json override the
	// result so explicit user values always win. The ghostline serve child
	// inherits this final environment and must not re-sanitize it.
	runtime.SanitizeEnvironment()
	loadedSettings.ApplyRuntimeEnv()

	logger := newLogger(*logFile)
	ghostlineCleanupContext, stopGhostlineCleanup := context.WithCancel(context.Background())
	defer stopGhostlineCleanup()
	go maintainGhostlineArtifactCleanup(ghostlineCleanupContext, *ghostlineSocket, logger)

	token, err := loadOrCreateToken(*tokenPath)
	if err != nil {
		fatal(err)
	}
	tokenContext, stopTokenRepair := context.WithCancel(context.Background())
	defer stopTokenRepair()
	go maintainTokenFile(tokenContext, *tokenPath, token, logger)

	state, err := store.Open(*statePath, *hostName)
	if err != nil {
		fatal(err)
	}
	// Runtime selection is a headless-side decision. Both engines are always
	// registered so existing sessions keep working no matter which engine
	// created them; DefaultRuntime only picks the engine for new sessions.
	defaultKind := loadedSettings.Normalized()
	runtimeSet := false
	flag.Visit(func(entry *flag.Flag) {
		if entry.Name == "runtime" {
			runtimeSet = true
		}
	})
	if runtimeSet {
		switch *runtimeMode {
		case settings.RuntimeGhostline, "pty": // "pty" is the historical alias.
			defaultKind = settings.RuntimeGhostline
		case settings.RuntimeTmux:
			defaultKind = settings.RuntimeTmux
		default:
			fatal(fmt.Errorf("unknown runtime %q (supported: ghostline, tmux)", *runtimeMode))
		}
	}
	ghostlineTagVersion := ghostlineReleaseVersion()
	ghostlineClient, err := ensureGhostlineClient(*ghostlineSocket, *outputDir, *ghostlineProbeForeground, ghostlineTagVersion, logger)
	if err != nil {
		fatal(err)
	}
	ghostlineRPCVersion, err := ghostlineClient.Version(context.Background())
	if err != nil {
		logger.Warn("unable to read running ghostline version", "error", err)
		ghostlineRPCVersion = ""
	}
	runtimes := map[string]server.Runtime{
		settings.RuntimeGhostline: server.NewGhostlineRuntime(ghostlineClient),
	}
	tmuxAdapter := &runtime.Tmux{Socket: *tmuxSocket, OutputDir: *outputDir}
	if err := tmuxAdapter.Check(nil); err != nil {
		logger.Warn("tmux runtime unavailable", "error", err)
	} else {
		runtimes[settings.RuntimeTmux] = tmuxAdapter
	}
	runtimeAdapter := runtimes[defaultKind]
	if runtimeAdapter == nil {
		fatal(fmt.Errorf("default runtime %q is not available", defaultKind))
	}
	service := &server.Service{
		Store:           state,
		HostName:        state.Snapshot().Host.Name,
		Runtime:         runtimeAdapter,
		Runtimes:        runtimes,
		DefaultRuntime:  defaultKind,
		Logger:          logger,
		ColorQuery:      server.WarrenColorQuery,
		ProbeForeground: *ghostlineProbeForeground,
		Settings:        loadedSettings,
		SettingsPath:    *settingsFile,
		WorktreeRoot:    *worktreeRoot,
		AgentFinder:     agent.DefaultFinder{},
		AgentHooks: func() error {
			if _, err := agent.EnsureCodexBindHook(agent.CodexHome()); err != nil {
				return err
			}
			_, err := agent.EnsureClaudeBindHook(agent.ClaudeConfigDir())
			return err
		},
	}
	serviceContext, stopService := context.WithCancel(context.Background())
	service.Start(serviceContext)
	defer func() {
		stopService()
		service.Shutdown()
	}()
	httpHandler := server.NewHTTPServer(service, token, logger)
	httpHandler.BuildVersion = version
	httpHandler.GhostlineVersion = ghostlineRPCVersion
	httpHandler.GhostlineRPCVersion = ghostlineRPCVersion
	httpHandler.GhostlineTagVersion = ghostlineTagVersion
	var lanHTTPServer *http.Server
	if *lanHTTPS != "" {
		certStore := tlscert.NewStore(*tlsDir)
		cert, err := certStore.ServerCertificate()
		if err != nil {
			fatal(err)
		}
		httpHandler.CACertPath = certStore.CAPEMPath()
		lanHTTPServer = &http.Server{
			Addr:              *lanHTTPS,
			Handler:           httpHandler.Handler(),
			TLSConfig:         &tls.Config{MinVersion: tls.VersionTLS12, Certificates: []tls.Certificate{cert}},
			ReadHeaderTimeout: 10 * time.Second,
			IdleTimeout:       90 * time.Second,
		}
	}
	httpServer := &http.Server{Addr: *listen, Handler: httpHandler.Handler(), ReadHeaderTimeout: 10 * time.Second, IdleTimeout: 90 * time.Second}
	listener, err := net.Listen("tcp", *listen)
	if err != nil {
		fatal(err)
	}
	webBaseURL := "http://127.0.0.1:" + listenerPort(listener)
	tunnelManager := tunnel.NewManager(logger, webBaseURL, *cloudflaredPath, *tailscalePath, *gnarPath)
	tunnelManager.SetGnarConfigDir(*gnarConfigDir)
	// Only the bundled worker's default store belongs to Warren. An explicit
	// gnar path/config directory may be a system installation and must survive
	// Public Access reset.
	tunnelManager.SetGnarConfigDirOwned(!gnarPathExplicit && !gnarConfigDirExplicit)
	tunnelManager.SetGnarDefaultEdge(gnarDefaultEdge)
	tunnelManager.SetGnarEdge(gnarEdgeValue)
	// Restore the tunnels the user left running before the previous daemon
	// exited, so the Public Endpoint survives Warren restarts and upgrades. Start is
	// asynchronous: the daemon must not block readiness on a slow edge.
	for _, kind := range []string{tunnel.KindGnar, tunnel.KindCloudflared, tunnel.KindTailscale} {
		if !loadedSettings.TunnelEnabled[kind] {
			continue
		}
		go func() {
			status, err := tunnelManager.Start(kind)
			if err != nil {
				logger.Warn("restore tunnel failed", "kind", kind, "error", err)
				return
			}
			if kind == tunnel.KindGnar && (!status.Running || status.URL == "") {
				logger.Warn("restore tunnel did not produce a public endpoint", "kind", kind, "error", status.Error)
				return
			}
			logger.Info("restored tunnel", "kind", kind)
		}()
	}
	httpHandler.Tunnels = tunnelManager
	logger.Info("warren headless ready", "listen", listener.Addr().String(), "host", state.Snapshot().Host.Name, "version", version, "tokenFile", *tokenPath)
	go func() {
		if err := httpServer.Serve(listener); err != nil && err != http.ErrServerClosed {
			fatal(err)
		}
	}()
	if lanHTTPServer != nil {
		lanListener, err := net.Listen("tcp", *lanHTTPS)
		if err != nil {
			fatal(err)
		}
		tlsListener := tls.NewListener(lanListener, lanHTTPServer.TLSConfig)
		logger.Info(
			"warren LAN HTTPS ready",
			"listen", lanListener.Addr().String(),
			"ca", httpHandler.CACertPath,
			"ca_url", "http://127.0.0.1:"+listenerPort(listener)+"/tls/ca.pem",
		)
		go func() {
			if err := lanHTTPServer.Serve(tlsListener); err != nil && err != http.ErrServerClosed {
				fatal(err)
			}
		}()
	}
	// Shutting down the control plane must never terminate the ghostline
	// serve process: it owns the PTY sessions and survives daemon restarts
	// and upgrades (the next start reuses or adopts it via its admin socket).
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	<-stop
	_ = httpServer.Close()
	if lanHTTPServer != nil {
		_ = lanHTTPServer.Close()
	}
	// A public tunnel must never outlive its daemon: stop every reachability
	// adapter so the Public Endpoint stops working as soon as the owner exits.
	tunnelManager.StopAll()
	stopService()
	service.Shutdown()
}

func listenerPort(listener net.Listener) string {
	if address, ok := listener.Addr().(*net.TCPAddr); ok {
		return strconv.Itoa(address.Port)
	}
	return "8789"
}

// maxLogFileBytes bounds the daemon log before it rotates to headless.log.1.
const maxLogFileBytes = 5 * 1024 * 1024

// newLogger writes structured logs to stderr and, when a path is configured,
// to a 0600 append-only file. Only high-signal events reach the file: daemon
// start/stop, tunnel starts, restores, and errors. The file rotates once it
// exceeds maxLogFileBytes so a long-running daemon never grows without bound.
func newLogger(path string) *slog.Logger {
	writers := []io.Writer{os.Stderr}
	if path != "" {
		if file, err := openLogFile(path); err == nil {
			writers = append(writers, file)
		}
	}
	return slog.New(slog.NewTextHandler(io.MultiWriter(writers...), nil))
}

func openLogFile(path string) (*os.File, error) {
	if info, err := os.Stat(path); err == nil && info.Size() > maxLogFileBytes {
		_ = os.Rename(path, path+".1")
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, err
	}
	return os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
}

// runGhostlineServe owns PTY sessions in a child process. The daemon spawns
// it detached with --ghostline-serve; it listens on the Unix socket until
// terminated, so daemon upgrades and restarts never end sessions.
func runGhostlineServe(socketPath, outputDir, adoptFrom string, probeForeground bool) {
	pidPath := socketPath + ".pid"
	if err := os.WriteFile(pidPath, []byte(strconv.Itoa(os.Getpid())+"\n"), 0o600); err != nil {
		fmt.Fprintln(os.Stderr, "ghostline serve: write pid:", err)
	}
	defer os.Remove(pidPath)
	server, err := ghostline.NewServer(ghostline.Options{
		OutputDir:       outputDir,
		ProbeForeground: probeForeground,
	})
	if err != nil {
		fmt.Fprintln(os.Stderr, "ghostline serve:", err)
		os.Exit(1)
	}
	if adoptFrom != "" {
		adoptContext, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		adopted, adoptErr := server.Adopt(adoptContext, adoptFrom)
		cancel()
		if adoptErr != nil {
			fmt.Fprintf(os.Stderr, "ghostline serve: adopt from %s: %v\n", adoptFrom, adoptErr)
			// Commit transfers ownership before Adopt performs the old server's
			// best-effort retirement. The old endpoint may close the admin socket
			// without replying, so an error can still mean that sessions are
			// already safely owned by this process. Never tear down a server that
			// has adopted sessions just because retirement confirmation failed.
			if ghostlineAdoptionFatal(adopted, adoptErr) {
				os.Exit(1)
			}
			fmt.Fprintf(os.Stderr, "ghostline serve: continuing with %d adopted session(s) despite retirement error\n", adopted)
		} else if adopted > 0 {
			fmt.Fprintf(os.Stderr, "ghostline serve: adopted %d session(s)\n", adopted)
		}
	}
	if err := server.Serve(context.Background(), socketPath); err != nil {
		fmt.Fprintln(os.Stderr, "ghostline serve:", err)
		os.Exit(1)
	}
}

// ghostlineAdoptionFatal reports whether an adoption error happened before
// any session was committed. Once at least one session was committed, the
// new server must stay alive even if the old server's retirement handshake
// failed.
func ghostlineAdoptionFatal(adopted int, adoptErr error) bool {
	return adoptErr != nil && adopted <= 0
}

// ensureGhostlineClient connects to the session server, spawning it detached
// when the socket is not yet accepting. Sessions survive daemon restarts
// because the server process owns them; the returned client is intentionally
// never closed by the daemon so the server keeps running.
func ensureGhostlineClient(socketPath, outputDir string, probeForeground bool, expectedTag string, logger *slog.Logger) (*ghostline.Client, error) {
	client, err := connectGhostlineClient(socketPath, outputDir)
	if err != nil {
		return nil, err
	}
	serverVersion, versionErr := client.VersionInfo(context.Background())
	needsUpgrade, trigger := ghostlineVersionNeedsUpgrade(serverVersion, expectedTag, versionErr)
	if !needsUpgrade {
		return client, nil
	}
	// A protocol mismatch is a forced rolling upgrade. A tag mismatch means
	// the wire contract is compatible but the detached server still runs an
	// older implementation. Both paths adopt every session before the old
	// process exits; if adoption fails, keep serving from the old process.
	upgradeArgs := []any{
		"from_version", serverVersion.ProtocolVersion,
		"to_version", ghostline.ProtocolVersion,
		"from_tag", serverVersion.TagVersion,
		"to_tag", expectedTag,
		"trigger", trigger,
	}
	if versionErr != nil {
		upgradeArgs = append(upgradeArgs, "version_error", versionErr)
	}
	logger.Warn("ghostline server requires rolling upgrade", upgradeArgs...)
	upgraded, upgradeErr := rollingUpgradeGhostlineClientWithMetadata(socketPath, outputDir, probeForeground, logger, serverVersion.ProtocolVersion, serverVersion.TagVersion, expectedTag, versionErr)
	if upgradeErr == nil {
		return upgraded, nil
	}
	logger.Warn("ghostline rolling upgrade failed; keeping current server",
		"from_version", serverVersion.ProtocolVersion, "to_version", ghostline.ProtocolVersion,
		"from_tag", serverVersion.TagVersion, "to_tag", expectedTag,
		"trigger", trigger, "error", upgradeErr)
	return client, nil
}

// rollingUpgradeGhostlineClient starts a fresh server on a temporary socket,
// lets it adopt every session from the old server, and then points the stable
// socket path at the new server with a symlink. The old server exits itself
// after adoption, so its children survive the upgrade.
func rollingUpgradeGhostlineClient(socketPath, outputDir string, probeForeground bool, logger *slog.Logger) (*ghostline.Client, error) {
	return rollingUpgradeGhostlineClientWithMetadata(socketPath, outputDir, probeForeground, logger, "", "", ghostlineReleaseVersion(), nil)
}

func rollingUpgradeGhostlineClientWithVersion(socketPath, outputDir string, probeForeground bool, logger *slog.Logger, fromVersion string, versionErr error) (upgraded *ghostline.Client, returnErr error) {
	return rollingUpgradeGhostlineClientWithMetadata(socketPath, outputDir, probeForeground, logger, fromVersion, "", ghostlineReleaseVersion(), versionErr)
}

func rollingUpgradeGhostlineClientWithMetadata(socketPath, outputDir string, probeForeground bool, logger *slog.Logger, fromVersion, fromTag, toTag string, versionErr error) (upgraded *ghostline.Client, returnErr error) {
	adminSocket := socketPath + ".admin"
	logFile, err := os.OpenFile(
		filepath.Join(filepath.Dir(socketPath), "ghostline.log"),
		os.O_CREATE|os.O_APPEND|os.O_WRONLY,
		0o600,
	)
	if err != nil {
		return nil, fmt.Errorf("open ghostline log: %w", err)
	}
	defer func() {
		if returnErr != nil {
			if err := writeGhostlineUpgradeLogWithTags(logFile, "failed", fromVersion, ghostline.ProtocolVersion, fromTag, toTag, ghostlineUpgradeTriggerForVersion(fromVersion, fromTag, toTag, versionErr), returnErr); err != nil {
				logger.Warn("unable to write ghostline upgrade failure log", "error", err)
			}
		}
		if err := logFile.Close(); err != nil {
			logger.Warn("unable to close ghostline log", "error", err)
		}
	}()
	if err := writeGhostlineUpgradeLogWithTags(logFile, "start", fromVersion, ghostline.ProtocolVersion, fromTag, toTag, ghostlineUpgradeTriggerForVersion(fromVersion, fromTag, toTag, versionErr), versionErr); err != nil {
		logger.Warn("unable to write ghostline upgrade start log", "error", err)
	}
	if !ghostline.Ping(adminSocket) {
		return nil, fmt.Errorf("old server has no admin socket at %s", adminSocket)
	}
	nextSocket := filepath.Join(
		filepath.Dir(socketPath),
		fmt.Sprintf("ghostline-%d.sock", time.Now().UnixNano()),
	)
	executable, err := os.Executable()
	if err != nil {
		return nil, fmt.Errorf("resolve daemon executable: %w", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	client, err := ghostline.Connect(ctx, ghostline.ConnectOptions{
		Socket: nextSocket,
		Spawn: []string{
			executable,
			"--ghostline-serve",
			"--ghostline-socket", nextSocket,
			"--output-dir", outputDir,
			"--adopt-from", adminSocket,
			"--ghostline-probe-foreground=" + strconv.FormatBool(probeForeground),
		},
		Log:          logFile,
		ReadyTimeout: 15 * time.Second,
	})
	if err != nil {
		return nil, fmt.Errorf("start upgraded server: %w", err)
	}
	// The new server only binds its socket after adoption finishes, so a
	// successful Connect means every session moved over. Wait for the old
	// server to exit before replacing the stable path, otherwise its cleanup
	// would unlink the new symlink.
	if err := waitForGhostlineExit(adminSocket, 5*time.Second); err != nil {
		// Adoption already committed; the old server has no sessions left, so
		// stopping it via its pid file is safe even if the exit handshake was
		// lost.
		logger.Warn("old ghostline server did not exit after adoption; stopping it", "error", err)
		if stopErr := stopGhostlineServer(socketPath); stopErr != nil {
			_ = client.Close()
			return nil, fmt.Errorf("old server did not exit after adoption: %v (stop: %w)", err, stopErr)
		}
	}
	if err := replaceWithSymlink(socketPath, nextSocket); err != nil {
		_ = client.Close()
		return nil, fmt.Errorf("point stable socket at upgraded server: %w", err)
	}
	if pid := client.PID(); pid > 0 {
		pidPath := socketPath + ".pid"
		if err := os.WriteFile(pidPath, []byte(strconv.Itoa(pid)+"\n"), 0o600); err != nil {
			logger.Warn("unable to record upgraded server pid", "path", pidPath, "error", err)
		}
	}
	if err := writeGhostlineUpgradeLogWithTags(logFile, "complete", fromVersion, ghostline.ProtocolVersion, fromTag, toTag, ghostlineUpgradeTriggerForVersion(fromVersion, fromTag, toTag, versionErr), nil); err != nil {
		logger.Warn("unable to write ghostline upgrade completion log", "error", err)
	}
	logger.Info("ghostline server upgraded in place",
		"from_version", fromVersion, "to_version", ghostline.ProtocolVersion,
		"from_tag", fromTag, "to_tag", toTag,
		"socket", socketPath, "server", nextSocket)
	return client, nil
}

func ghostlineUpgradeTrigger(versionErr error) string {
	if versionErr != nil {
		return "version_query_failed"
	}
	return "protocol_mismatch"
}

func ghostlineVersionNeedsUpgrade(serverVersion ghostline.VersionInfo, expectedTag string, versionErr error) (bool, string) {
	if versionErr != nil {
		return true, "version_query_failed"
	}
	if serverVersion.ProtocolVersion != ghostline.ProtocolVersion {
		return true, "protocol_mismatch"
	}
	if expectedTag != "" && serverVersion.TagVersion != expectedTag {
		return true, "tag_mismatch"
	}
	return false, ""
}

func ghostlineUpgradeTriggerForVersion(fromVersion, fromTag, toTag string, versionErr error) string {
	if versionErr != nil {
		return "version_query_failed"
	}
	if fromVersion != ghostline.ProtocolVersion {
		return "protocol_mismatch"
	}
	if toTag != "" && fromTag != toTag {
		return "tag_mismatch"
	}
	return ghostlineUpgradeTrigger(versionErr)
}

func writeGhostlineUpgradeLog(w io.Writer, phase, fromVersion, toVersion, trigger string, upgradeErr error) error {
	return writeGhostlineUpgradeLogWithTags(w, phase, fromVersion, toVersion, "", "", trigger, upgradeErr)
}

func writeGhostlineUpgradeLogWithTags(w io.Writer, phase, fromVersion, toVersion, fromTag, toTag, trigger string, upgradeErr error) error {
	if upgradeErr != nil {
		_, err := fmt.Fprintf(w, "ghostline upgrade phase=%s from_version=%q to_version=%q from_tag=%q to_tag=%q trigger=%q error=%q\n", phase, fromVersion, toVersion, fromTag, toTag, trigger, upgradeErr)
		return err
	}
	_, err := fmt.Fprintf(w, "ghostline upgrade phase=%s from_version=%q to_version=%q from_tag=%q to_tag=%q trigger=%q\n", phase, fromVersion, toVersion, fromTag, toTag, trigger)
	return err
}

// waitForGhostlineExit waits for the old server's admin socket to disappear.
func waitForGhostlineExit(adminSocket string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for ghostline.Ping(adminSocket) && time.Now().Before(deadline) {
		time.Sleep(50 * time.Millisecond)
	}
	if ghostline.Ping(adminSocket) {
		return fmt.Errorf("admin socket %s still accepting", adminSocket)
	}
	return nil
}

// replaceWithSymlink atomically points stable at target by creating a
// temporary symlink and renaming it over the old socket path.
func replaceWithSymlink(stable, target string) error {
	if err := os.Remove(stable); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("remove old socket: %w", err)
	}
	temp := stable + ".tmp"
	_ = os.Remove(temp)
	if err := os.Symlink(filepath.Base(target), temp); err != nil {
		return fmt.Errorf("create socket symlink: %w", err)
	}
	if err := os.Rename(temp, stable); err != nil {
		_ = os.Remove(temp)
		return fmt.Errorf("install socket symlink: %w", err)
	}
	return nil
}

func connectGhostlineClient(socketPath, outputDir string) (*ghostline.Client, error) {
	logFile, err := os.OpenFile(
		filepath.Join(filepath.Dir(socketPath), "ghostline.log"),
		os.O_CREATE|os.O_APPEND|os.O_WRONLY,
		0o600,
	)
	if err != nil {
		return nil, fmt.Errorf("open ghostline log: %w", err)
	}
	defer logFile.Close()
	executable, err := os.Executable()
	if err != nil {
		return nil, fmt.Errorf("resolve daemon executable: %w", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	client, err := ghostline.Connect(ctx, ghostline.ConnectOptions{
		Socket: socketPath,
		Spawn: []string{
			executable,
			"--ghostline-serve",
			"--ghostline-socket", socketPath,
			"--output-dir", outputDir,
		},
		Log:          logFile,
		ReadyTimeout: 5 * time.Second,
	})
	if err != nil {
		return nil, fmt.Errorf("connect ghostline server: %w", err)
	}
	return client, nil
}

// stopGhostlineServer terminates the running server via its pid file and
// waits for the socket to disappear.
func stopGhostlineServer(socketPath string) error {
	pidPath := socketPath + ".pid"
	data, err := os.ReadFile(pidPath)
	if err != nil {
		// Servers started before per-socket pid files wrote the shared
		// ghostline.pid; keep that path as a compatibility fallback.
		data, err = os.ReadFile(filepath.Join(filepath.Dir(socketPath), "ghostline.pid"))
	}
	if err == nil {
		if pid, parseErr := strconv.Atoi(strings.TrimSpace(string(data))); parseErr == nil && pid > 0 {
			_ = syscall.Kill(pid, syscall.SIGTERM)
		}
	}
	deadline := time.Now().Add(5 * time.Second)
	for ghostline.Ping(socketPath) && time.Now().Before(deadline) {
		time.Sleep(100 * time.Millisecond)
	}
	if ghostline.Ping(socketPath) {
		return fmt.Errorf("ghostline server did not stop after restart request")
	}
	return nil
}

func loadOrCreateToken(path string) (string, error) {
	if data, err := os.ReadFile(path); err == nil {
		value := strings.TrimSpace(string(data))
		if value != "" {
			return value, nil
		}
	}
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		return "", err
	}
	value := base64.RawURLEncoding.EncodeToString(raw)
	if err := writeTokenFile(path, value); err != nil {
		return "", err
	}
	return value, nil
}

// maintainTokenFile keeps the token that an already-running daemon owns
// available to new desktop and CLI clients. The daemon keeps the token in
// memory, so restoring a deleted or replaced file is safe and prevents a
// second daemon from publishing a different token for the same port.
func maintainTokenFile(ctx context.Context, path, token string, logger *slog.Logger) {
	repair := func() {
		if err := ensureTokenFile(path, token); err != nil {
			logger.Warn("unable to repair token file", "path", path, "error", err)
		}
	}
	repair()
	ticker := time.NewTicker(tokenRepairInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			repair()
		}
	}
}

func ensureTokenFile(path, token string) error {
	data, err := os.ReadFile(path)
	if err == nil && strings.TrimSpace(string(data)) == token {
		return nil
	}
	return writeTokenFile(path, token)
}

func writeTokenFile(path, token string) error {
	directory := filepath.Dir(path)
	if err := os.MkdirAll(directory, 0o700); err != nil {
		return fmt.Errorf("create token directory: %w", err)
	}
	temporary, err := os.CreateTemp(directory, ".warren-token-*")
	if err != nil {
		return fmt.Errorf("create temporary token file: %w", err)
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)
	if err := temporary.Chmod(0o600); err != nil {
		_ = temporary.Close()
		return fmt.Errorf("set token permissions: %w", err)
	}
	if _, err := temporary.WriteString(token + "\n"); err != nil {
		_ = temporary.Close()
		return fmt.Errorf("write token: %w", err)
	}
	if err := temporary.Close(); err != nil {
		return fmt.Errorf("close temporary token file: %w", err)
	}
	if err := os.Rename(temporaryPath, path); err != nil {
		return fmt.Errorf("commit token: %w", err)
	}
	return nil
}

func defaultConfigDirectory() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".warren")
}

// bundledGnarPath returns the gnar binary shipped beside the headless daemon
// in a Warren.app bundle. Development checkouts intentionally fall back to
// normal system discovery, so a missing release asset never makes source
// builds unusable.
func bundledGnarPath() string {
	executable, err := os.Executable()
	if err != nil {
		return ""
	}
	return bundledGnarPathFor(executable)
}

func bundledGnarPathFor(executable string) string {
	if resolved, resolveErr := filepath.EvalSymlinks(executable); resolveErr == nil {
		executable = resolved
	}
	macOSDirectory := filepath.Dir(executable)
	if filepath.Base(macOSDirectory) != "MacOS" ||
		filepath.Base(filepath.Dir(macOSDirectory)) != "Contents" {
		return ""
	}
	candidate := filepath.Join(macOSDirectory, "..", "Resources", "gnar")
	info, err := os.Stat(candidate)
	if err != nil || info.IsDir() || info.Mode()&0o111 == 0 {
		return ""
	}
	return candidate
}

// validateGhostlinePaths prevents a temporary or alternate Warren state from
// accidentally connecting to the default Ghostline server. The default
// socket is shared by the production daemon, so custom state/output paths
// require an explicitly selected, non-default socket of their own.
func validateGhostlinePaths(configDir, statePath, outputDir, socketPath string, socketExplicit bool) error {
	defaultState := filepath.Join(configDir, "state.json")
	defaultOutput := filepath.Join(configDir, "output")
	defaultSocket := filepath.Join(configDir, "ghostline.sock")
	customState := !samePath(statePath, defaultState)
	customOutput := !samePath(outputDir, defaultOutput)
	if !customState && !customOutput {
		return nil
	}
	if !socketExplicit || strings.TrimSpace(socketPath) == "" {
		return fmt.Errorf("custom state or output paths require an explicit --ghostline-socket; refusing to use default %s", defaultSocket)
	}
	if samePath(socketPath, defaultSocket) {
		return fmt.Errorf("custom state or output paths cannot use the default Ghostline socket %s; choose a dedicated --ghostline-socket", defaultSocket)
	}
	return nil
}

func samePath(left, right string) bool {
	leftAbs, leftErr := filepath.Abs(left)
	rightAbs, rightErr := filepath.Abs(right)
	if leftErr != nil || rightErr != nil {
		return filepath.Clean(left) == filepath.Clean(right)
	}
	return filepath.Clean(leftAbs) == filepath.Clean(rightAbs)
}

func env(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}

func envBool(key string, fallback bool) bool {
	value := os.Getenv(key)
	if value == "" {
		return fallback
	}
	parsed, err := strconv.ParseBool(value)
	if err != nil {
		return fallback
	}
	return parsed
}
func fatal(err error) { fmt.Fprintln(os.Stderr, "warren-headless:", err); os.Exit(1) }
