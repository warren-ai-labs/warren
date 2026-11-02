// Package remote runs Warren's serverless remote access on top of Bolthole.
//
// The Host holds one 32-byte connect code in its own 0600 file. From it
// Bolthole derives the routing token a relay sees and the PSK that keys the
// end-to-end Noise handshake, so a relay (the official Worker, a self-hosted
// one, or none at all on the LAN) only ever forwards ciphertext and stores
// nothing. Who may act on the Host is still decided by the Host: a client
// that completed the handshake must then present a paired-client token on
// `/v1/ws`, exactly as on the LAN.
//
// The same agent serves two paths:
//
//   - relayed: an outbound WebSocket to the configured relay, started only
//     while remote access is enabled;
//   - direct: `/.bolthole/e2e` mounted on the Host's own listener, so a client
//     on the same network (or a tailnet) reaches it without any relay.
//
// Both run the identical handshake, which is what lets clients switch
// between LAN and relay freely without re-pairing.
package remote

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/abcdlsj/bolthole/agent"
	"github.com/abcdlsj/bolthole/e2e"
	"github.com/abcdlsj/bolthole/kinds/wskind"
	"github.com/abcdlsj/bolthole/mux"
)

// DirectPath is the E2E entry point a direct listener serves.
const DirectPath = e2e.Path

// WebSocketHandler serves one `ws` stream that arrived over an encrypted
// session (relayed or direct).
type WebSocketHandler func(ctx context.Context, conn *wskind.Conn, meta wskind.OpenMeta)

// Config describes how a Supervisor reaches the Host's own services.
type Config struct {
	// CodePath is the connect-code file, created with mode 0600 on first use.
	CodePath string
	// Name is shown to clients inside the encrypted hello.
	Name string
	// HTTP serves `http` streams.
	HTTP http.Handler
	// WebSocket serves `ws` streams.
	WebSocket WebSocketHandler
	// DirectURLs lists ws:// URLs where the Host serves DirectPath itself.
	// They travel only inside the encrypted hello.
	DirectURLs func() []string
	// RelayKey is an optional key or JWT for relays that gate registration.
	RelayKey string
	Logger   *slog.Logger
}

// Status is the supervisor's view for /healthz and settings.
type Status struct {
	Enabled   bool   `json:"enabled"`
	RelayURL  string `json:"relayURL,omitempty"`
	Connected bool   `json:"connected"`
	State     string `json:"state"`
	LastError string `json:"lastError,omitempty"`
}

// Supervisor owns the connect code and the relayed agent's lifecycle. The
// direct entry point works whether or not a relay is running.
type Supervisor struct {
	config Config
	parent context.Context

	mu     sync.Mutex
	code   e2e.Code
	loaded bool
	agent  *agent.Agent // current code's agent; serves direct and relayed sessions
	// agentCtx scopes every session of the current code. Rotation cancels it,
	// so clients that knew the old code are cut off, not just refused later.
	agentCtx    context.Context
	agentCancel context.CancelFunc
	relayURL    string
	cancel      context.CancelFunc
	done        chan struct{}
	status      Status
}

// New returns a stopped supervisor bound to parent.
func New(parent context.Context, config Config) *Supervisor {
	if config.Logger == nil {
		config.Logger = slog.New(slog.DiscardHandler)
	}
	return &Supervisor{config: config, parent: parent, status: Status{State: "disabled"}}
}

func (s *Supervisor) ensureLoadedLocked() error {
	if s.loaded {
		return nil
	}
	code, err := loadOrCreateCode(s.config.CodePath)
	if err != nil {
		return err
	}
	s.code = code
	s.loaded = true
	s.renewAgentContextLocked()
	s.agent = s.newAgentLocked("")
	return nil
}

func (s *Supervisor) renewAgentContextLocked() {
	if s.agentCancel != nil {
		s.agentCancel()
	}
	s.agentCtx, s.agentCancel = context.WithCancel(s.parent)
}

func (s *Supervisor) newAgentLocked(relayURL string) *agent.Agent {
	router := agent.NewRouter()
	if s.config.HTTP != nil {
		router.HTTP(s.config.HTTP)
	}
	if s.config.WebSocket != nil {
		handler := s.config.WebSocket
		router.WebSocket(func(ctx context.Context, conn *wskind.Conn, meta wskind.OpenMeta, info agent.Info) {
			if !info.Encrypted {
				// The agent already refuses plaintext streams in E2E mode;
				// this guards against a future Public flag being set by mistake.
				conn.Stream().Reset(mux.CodeE2ERequired, "")
				return
			}
			handler(ctx, conn, meta)
		})
	}
	var direct []string
	if s.config.DirectURLs != nil {
		direct = s.config.DirectURLs()
	}
	return &agent.Agent{
		Relay:   relayURL,
		Code:    s.code,
		Name:    s.config.Name,
		Auth:    s.config.RelayKey,
		Handler: router,
		Direct:  direct,
		Logger:  s.config.Logger,
	}
}

// Start connects to relayURL, replacing any running connection. An empty
// relayURL is rejected; use Stop to go LAN-only.
func (s *Supervisor) Start(relayURL string) error {
	relayURL, err := NormalizeRelayURL(relayURL)
	if err != nil {
		return err
	}
	s.mu.Lock()
	if err := s.ensureLoadedLocked(); err != nil {
		s.mu.Unlock()
		return err
	}
	if s.cancel != nil && s.relayURL == relayURL {
		s.mu.Unlock()
		return nil
	}
	s.stopLocked()
	s.startLocked(relayURL)
	s.mu.Unlock()
	return nil
}

func (s *Supervisor) startLocked(relayURL string) {
	runner := s.newAgentLocked(relayURL)
	runner.OnStatus = func(value agent.Status) { s.onStatus(runner, value) }
	s.agent = runner
	ctx, cancel := context.WithCancel(s.agentCtx)
	done := make(chan struct{})
	s.relayURL = relayURL
	s.cancel = cancel
	s.done = done
	s.status = Status{Enabled: true, RelayURL: relayURL, State: "connecting"}
	go func() {
		defer close(done)
		if err := runner.Run(ctx); err != nil && !errors.Is(err, context.Canceled) {
			s.config.Logger.Warn("remote access stopped", "error", err)
			s.onStatus(runner, agent.Status{Err: err})
		}
	}()
}

func (s *Supervisor) onStatus(runner *agent.Agent, value agent.Status) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.agent != runner || s.cancel == nil {
		return // a stale agent reporting after a restart
	}
	s.status.Connected = value.Connected
	switch {
	case value.Connected:
		s.status.State = "connected"
		s.status.LastError = ""
	case value.Err != nil:
		s.status.State = "disconnected"
		s.status.LastError = value.Err.Error()
		var permanent *agent.PermanentError
		if errors.As(value.Err, &permanent) {
			s.status.State = "error"
		}
	default:
		s.status.State = "connecting"
	}
}

// Stop disconnects from the relay. Direct sessions keep working.
func (s *Supervisor) Stop() {
	s.mu.Lock()
	s.stopLocked()
	s.mu.Unlock()
}

func (s *Supervisor) stopLocked() {
	if s.cancel == nil {
		return
	}
	s.cancel()
	done := s.done
	s.cancel, s.done, s.relayURL = nil, nil, ""
	s.status = Status{State: "disabled"}
	s.mu.Unlock()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
	}
	s.mu.Lock()
}

// Rotate replaces the connect code. Every connection string, QR code and
// client that knew the old code stops working; paired-client tokens are
// cleared separately by the caller when it wants a full reset.
func (s *Supervisor) Rotate() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	code := e2e.NewCode()
	if err := writeCode(s.config.CodePath, code); err != nil {
		return err
	}
	relayURL := s.relayURL
	running := s.cancel != nil
	s.stopLocked()
	s.code = code
	s.loaded = true
	s.renewAgentContextLocked()
	if running {
		s.startLocked(relayURL)
	} else {
		s.agent = s.newAgentLocked("")
	}
	return nil
}

// ConnString returns the connection string for relayURL (which need not be
// the running relay) with extra fragment parameters appended. The code is
// only ever placed in the fragment, which clients never send to a server.
func (s *Supervisor) ConnString(relayURL string, extra url.Values) (string, error) {
	relayURL, err := NormalizeRelayURL(relayURL)
	if err != nil {
		return "", err
	}
	s.mu.Lock()
	err = s.ensureLoadedLocked()
	code := s.code
	s.mu.Unlock()
	if err != nil {
		return "", err
	}
	value, err := e2e.FormatConnString(relayURL, code)
	if err != nil {
		return "", err
	}
	if len(extra) > 0 {
		value += "&" + extra.Encode()
	}
	return value, nil
}

// Status reports the relayed connection.
func (s *Supervisor) Status() Status {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.status
}

// DirectHandler serves DirectPath for the Host's own listener. It follows
// code rotation without being re-mounted.
func (s *Supervisor) DirectHandler() http.Handler {
	return http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		s.mu.Lock()
		err := s.ensureLoadedLocked()
		current := s.agent
		ctx := s.agentCtx
		s.mu.Unlock()
		if err != nil || current == nil {
			http.Error(writer, "remote access is unavailable", http.StatusServiceUnavailable)
			return
		}
		current.DirectHandler(ctx).ServeHTTP(writer, request)
	})
}

// NormalizeRelayURL accepts an http(s) relay base URL without credentials,
// query or fragment and returns it without a trailing slash.
func NormalizeRelayURL(raw string) (string, error) {
	parsed, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || parsed.Host == "" || parsed.User != nil || parsed.RawQuery != "" || parsed.Fragment != "" || parsed.Opaque != "" {
		return "", errors.New("invalid relay URL")
	}
	if parsed.Scheme != "https" && parsed.Scheme != "http" {
		return "", errors.New("relay URL must use https (or http for local development)")
	}
	parsed.Path = strings.TrimRight(parsed.Path, "/")
	parsed.RawPath = ""
	return parsed.String(), nil
}

func loadOrCreateCode(path string) (e2e.Code, error) {
	if strings.TrimSpace(path) == "" {
		return e2e.Code{}, errors.New("remote access code path is not configured")
	}
	data, err := os.ReadFile(path)
	if err == nil {
		code, parseErr := e2e.ParseCode(strings.TrimSpace(string(data)))
		if parseErr != nil {
			return e2e.Code{}, fmt.Errorf("read remote access code: %w", parseErr)
		}
		return code, nil
	}
	if !errors.Is(err, os.ErrNotExist) {
		return e2e.Code{}, err
	}
	code := e2e.NewCode()
	return code, writeCode(path, code)
}

// writeCode replaces the code file atomically with mode 0600.
func writeCode(path string, code e2e.Code) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	temp, err := os.CreateTemp(filepath.Dir(path), ".remote-code-*")
	if err != nil {
		return err
	}
	name := temp.Name()
	defer os.Remove(name)
	if err := temp.Chmod(0o600); err != nil {
		temp.Close()
		return err
	}
	if _, err := temp.WriteString(code.String() + "\n"); err != nil {
		temp.Close()
		return err
	}
	if err := temp.Close(); err != nil {
		return err
	}
	return os.Rename(name, path)
}
