package main

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"encoding/base64"
	"errors"
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
	"sync"
	"syscall"
	"time"

	"github.com/abcdlsj/ghostline"
	"github.com/abcdlsj/warren/Headless/internal/agent"
	"github.com/abcdlsj/warren/Headless/internal/relay"
	"github.com/abcdlsj/warren/Headless/internal/runtime"
	"github.com/abcdlsj/warren/Headless/internal/server"
	"github.com/abcdlsj/warren/Headless/internal/settings"
	"github.com/abcdlsj/warren/Headless/internal/store"
	"github.com/abcdlsj/warren/Headless/internal/tlscert"
)

var (
	version  = "dev"
	revision = "unknown"
	dirty    = "false"
)

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
	runtimeMode := flag.String("runtime", env("WARREN_RUNTIME", ""), "runtime kind (ghostline only; overrides settings.json)")
	ghostlineSocket := flag.String("ghostline-socket", env("WARREN_GHOSTLINE_SOCKET", filepath.Join(configDir, "ghostline.sock")), "ghostline server socket path")
	ghostlineServe := flag.Bool("ghostline-serve", false, "internal: run the ghostline session server (spawned by the daemon)")
	ghostlineAdoptFrom := flag.String("adopt-from", "", "internal: adopt sessions from this old server admin socket")
	ghostlineProbeForeground := flag.Bool("ghostline-probe-foreground", envBool("WARREN_GHOSTLINE_PROBE_FOREGROUND", false), "probe OS-level foreground metadata in ghostline (default off)")
	settingsFile := flag.String("settings-file", env("WARREN_SETTINGS_FILE", filepath.Join(configDir, "settings.json")), "headless settings file")
	logFile := flag.String("log-file", env("WARREN_LOG_FILE", filepath.Join(configDir, "headless.log")), "daemon log file (empty disables file logging)")
	worktreeRoot := flag.String("worktree-root", env("WARREN_WORKTREE_ROOT", "~/.warren/worktrees"), "worktree root")
	outputDir := flag.String("output-dir", env("WARREN_OUTPUT_DIR", filepath.Join(configDir, "output")), "runtime output directory")
	relayURL := flag.String("relay-url", env("WARREN_RELAY_URL", ""), "owned Relay URL (optional)")
	relayHostID := flag.String("relay-host-id", env("WARREN_RELAY_HOST_ID", ""), "Relay Host UUID (optional)")
	relayKeyID := flag.String("relay-key-id", env("WARREN_RELAY_KEY_ID", ""), "pinned Relay signing key ID (optional)")
	relayKey := flag.String("relay-key", env("WARREN_RELAY_KEY", ""), "pinned Relay signing public key (base64, optional)")
	showVersion := flag.Bool("version", false, "print version")
	flag.Parse()
	if *showVersion {
		fmt.Println(version)
		return
	}
	// Capture all flag values before replacing the process environment. Warren
	// is often launched from mise/direnv-aware terminals; those task variables
	// must not become Ghostline's inheritance base.
	runtime.ApplyCleanEnvironment()
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
	// RuntimeEnv is intentionally session-scoped. Applying it to the daemon
	// would contaminate the detached Ghostline server and every future session.
	// Launcher overrides are intentionally process-local. Enrollment persists
	// the same non-secret values in settings.json, while this path lets a
	// supervisor or development script bootstrap a daemon before persistence is
	// available. The Host Secret itself is still read only from tokenPath.
	if strings.TrimSpace(*relayURL) != "" {
		loadedSettings.Relay.URL = strings.TrimSpace(*relayURL)
	}
	if strings.TrimSpace(*relayHostID) != "" {
		loadedSettings.Relay.HostID = strings.TrimSpace(*relayHostID)
	}
	if strings.TrimSpace(*relayKeyID) != "" {
		loadedSettings.Relay.RelayKeyID = strings.TrimSpace(*relayKeyID)
	}
	if strings.TrimSpace(*relayKey) != "" {
		loadedSettings.Relay.RelayKey = strings.TrimSpace(*relayKey)
	}

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
	// Ghostline is the sole terminal runtime.
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
		default:
			fatal(fmt.Errorf("unknown runtime %q (supported: ghostline)", *runtimeMode))
		}
	}
	ghostlineTagVersion := ghostlineReleaseVersion()
	ghostlineClient, err := ensureGhostlineClientWithStore(*ghostlineSocket, *outputDir, *ghostlineProbeForeground, ghostlineTagVersion, version, state, logger)
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
			if _, err := agent.EnsureClaudeBindHook(agent.ClaudeConfigDir()); err != nil {
				return err
			}
			_, err := agent.EnsureOpenCodeBindPlugin()
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
	httpHandler.BuildRevision = revision
	httpHandler.BuildDirty = dirty == "true"
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
	relaySupervisor := newRelaySupervisor(service, httpHandler, serviceContext, token, state.Snapshot().Host.Name, strings.TrimSpace(*relayURL), strings.TrimSpace(*relayHostID), logger)
	httpHandler.RelayStart = relaySupervisor.Start
	httpHandler.RelayStop = relaySupervisor.Stop
	httpHandler.RelayRouteClient = relaySupervisor.RouteClient
	if service.Settings.Relay.Enabled || service.Settings.PublicTunnel.Enabled || strings.TrimSpace(*relayURL) != "" {
		if err := relaySupervisor.Start(); err != nil {
			logger.Warn("relay connector disabled", "error", err)
		}
	}
	logger.Info(
		"warren headless ready",
		"listen", listener.Addr().String(),
		"host", state.Snapshot().Host.Name,
		"version", version,
		"revision", revision,
		"dirty", dirty,
		"tokenFile", *tokenPath,
	)
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
	relaySupervisor.Stop()
	stopService()
	service.Shutdown()
}

// relaySupervisor owns the single outbound Host connection. It is deliberately
// independent from Service lifecycle so changing Relay/public-tunnel settings
// cannot tear down Sessions or PTYs. A changed URL, Host ID, or pinned key
// rebuilds the connector only after the previous one has stopped.
type relaySupervisor struct {
	mu          sync.Mutex
	lifecycleMu sync.Mutex
	service     *server.Service
	httpHandler *server.HTTPServer
	context     context.Context
	token       string
	hostName    string
	overrideURL string
	overrideID  string
	logger      *slog.Logger
	connector   *relay.Connector
	configKey   string
}

func newRelaySupervisor(service *server.Service, handler *server.HTTPServer, context context.Context, token, hostName, overrideURL, overrideID string, logger *slog.Logger) *relaySupervisor {
	return &relaySupervisor{
		service: service, httpHandler: handler, context: context, token: token,
		hostName: hostName, overrideURL: overrideURL, overrideID: overrideID, logger: logger,
	}
}

func (supervisor *relaySupervisor) desiredSettings() (settings.RelaySettings, string, error) {
	if supervisor.service == nil {
		return settings.RelaySettings{}, "", errors.New("Relay service is unavailable")
	}
	value := supervisor.service.RelaySettingsSnapshot()
	urlValue := strings.TrimSpace(value.URL)
	hostID := strings.TrimSpace(value.HostID)
	if supervisor.overrideURL != "" {
		urlValue = supervisor.overrideURL
	}
	if supervisor.overrideID != "" {
		hostID = supervisor.overrideID
	}
	if urlValue == "" || hostID == "" {
		return value, "", errors.New("Relay URL and Host ID are required")
	}
	// Do not persist secrets in the key used for lifecycle comparison. The
	// pinned public key is non-secret and changes must still rebuild the socket.
	configKey := strings.Join([]string{urlValue, hostID, strings.TrimSpace(value.RelayKeyID), strings.TrimSpace(value.RelayKey)}, "\x00")
	return value, configKey, nil
}

func (supervisor *relaySupervisor) Start() error {
	supervisor.lifecycleMu.Lock()
	defer supervisor.lifecycleMu.Unlock()
	value, configKey, err := supervisor.desiredSettings()
	if err != nil {
		return err
	}
	supervisor.mu.Lock()
	if supervisor.connector != nil && supervisor.configKey == configKey {
		supervisor.mu.Unlock()
		return nil
	}
	previous := supervisor.connector
	supervisor.connector = nil
	supervisor.configKey = ""
	supervisor.mu.Unlock()
	if previous != nil {
		previous.Stop()
	}
	publicKeys := relayPublicKeys(value)
	if len(publicKeys) == 0 {
		return errors.New("pinned Relay signing key is required")
	}
	urlValue := strings.TrimSpace(value.URL)
	hostID := strings.TrimSpace(value.HostID)
	if supervisor.overrideURL != "" {
		urlValue = supervisor.overrideURL
	}
	if supervisor.overrideID != "" {
		hostID = supervisor.overrideID
	}
	var candidate *relay.Connector
	candidate, err = relay.New(relay.Config{
		URL: urlValue, HostID: hostID, Name: supervisor.hostName, Secret: supervisor.token,
		Handler: supervisor.httpHandler.Handler(), RelayPublicKeys: publicKeys,
		OnState: func(state string) {
			if supervisor.logger != nil {
				supervisor.logger.Info("relay connector state", "state", state)
			}
		},
		OnControl: func(ctx context.Context, open relay.StreamOpen, frame relay.Frame) error {
			return supervisor.httpHandler.HandleRelayControl(ctx, open, frame, candidate.Send)
		},
	})
	if err != nil {
		return err
	}
	supervisor.mu.Lock()
	supervisor.connector = candidate
	supervisor.configKey = configKey
	supervisor.mu.Unlock()
	candidate.Start(supervisor.context)
	return nil
}

func (supervisor *relaySupervisor) Stop() {
	supervisor.lifecycleMu.Lock()
	defer supervisor.lifecycleMu.Unlock()
	supervisor.mu.Lock()
	connector := supervisor.connector
	supervisor.connector = nil
	supervisor.configKey = ""
	supervisor.mu.Unlock()
	if connector != nil {
		connector.Stop()
	}
}

// RouteClient returns a short-lived authenticated client for Relay's route
// lifecycle API. Route changes use the same Host Secret as the single BRLY/2
// connector; no second credential or transport is created.
func (supervisor *relaySupervisor) RouteClient() (*relay.RouteClient, error) {
	value, _, err := supervisor.desiredSettings()
	if err != nil {
		return nil, err
	}
	urlValue := strings.TrimSpace(value.URL)
	hostID := strings.TrimSpace(value.HostID)
	if supervisor.overrideURL != "" {
		urlValue = supervisor.overrideURL
	}
	if supervisor.overrideID != "" {
		hostID = supervisor.overrideID
	}
	return relay.NewRouteClient(urlValue, hostID, supervisor.token)
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
// start/stop, Relay route changes, and errors. The file rotates once it
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
		report, adoptErr := server.AdoptWithReport(adoptContext, adoptFrom)
		adopted := report.Adopted
		cancel()
		if adoptErr != nil {
			fmt.Fprintf(os.Stderr, "ghostline serve: adopt from %s: %v\n", adoptFrom, adoptErr)
			if len(report.Skipped) > 0 {
				fmt.Fprintf(os.Stderr, "ghostline serve: skipped %d session(s): %v\n", len(report.Skipped), report.Skipped)
			}
			// Commit transfers ownership before Adopt performs the old server's
			// best-effort retirement. The old endpoint may close the admin socket
			// without replying, so an error can still mean that sessions are
			// already safely owned by this process. Never tear down a server that
			// has adopted sessions just because retirement confirmation failed.
			if ghostlineAdoptionFatal(adopted, len(report.Skipped), adoptErr) {
				os.Exit(1)
			}
			fmt.Fprintf(os.Stderr, "ghostline serve: continuing with %d adopted session(s) despite retirement error\n", adopted)
		} else {
			if len(report.Skipped) > 0 {
				fmt.Fprintf(os.Stderr, "ghostline serve: adopted %d session(s), skipped %d: %v\n", adopted, len(report.Skipped), report.Skipped)
			} else if adopted > 0 {
				fmt.Fprintf(os.Stderr, "ghostline serve: adopted %d session(s)\n", adopted)
			}
		}
	}
	if err := server.Serve(context.Background(), socketPath); err != nil {
		fmt.Fprintln(os.Stderr, "ghostline serve:", err)
		os.Exit(1)
	}
}

// ghostlineAdoptionFatal reports errors that happened before any session was
// committed and were not classified as per-session adoption failures.
func ghostlineAdoptionFatal(adopted, skipped int, adoptErr error) bool {
	return adoptErr != nil && adopted <= 0 && skipped == 0
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

func relayPublicKeys(value settings.RelaySettings) map[string]ed25519.PublicKey {
	keyText := strings.TrimSpace(value.RelayKey)
	if keyText == "" {
		return nil
	}
	data, err := base64.RawStdEncoding.DecodeString(keyText)
	if err != nil {
		data, err = base64.StdEncoding.DecodeString(keyText)
	}
	if err != nil || len(data) != ed25519.PublicKeySize {
		return nil
	}
	keyID := strings.TrimSpace(value.RelayKeyID)
	if keyID == "" {
		digest := sha256.Sum256(data)
		keyID = base64.RawURLEncoding.EncodeToString(digest[:8])
	}
	return map[string]ed25519.PublicKey{keyID: ed25519.PublicKey(data)}
}
