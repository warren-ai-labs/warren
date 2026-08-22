package tunnel

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	KindCloudflared  = "cloudflared"
	KindTailscale    = "tailscale"
	KindGnar         = "gnar"
	gnarLoginTimeout = 30 * time.Second
)

// LoginKeyKind selects the gnar v1.7 bootstrap contract. Approval keys are
// the historical enrollment keys; invite keys use gnar's invite-key flow.
type LoginKeyKind string

const (
	LoginKeyApproval LoginKeyKind = "approval"
	LoginKeyInvite   LoginKeyKind = "invite"
)

// Status is the runtime projection of one tunnel. URL is empty until the
// reachability adapter reports a public address.
type Status struct {
	Running bool   `json:"running"`
	URL     string `json:"url,omitempty"`
	Error   string `json:"error,omitempty"`
}

// Manager owns the reachability adapters (cloudflared, Tailscale Serve, gnar)
// that expose the loopback Web server. Each kind maps to at most one adapter;
// start is idempotent and stop tears down the running adapter.
type Manager struct {
	logger          *slog.Logger
	target          string
	cloudflaredPath string
	tailscalePath   string
	gnarPath        string
	// gnarConfigDir is passed only to the gnar child process. A bundled gnar
	// binary uses Warren's private credential store while an explicitly
	// selected/system binary keeps its normal gnar location unless this is set.
	gnarConfigDir   string
	gnarEdge        string
	gnarDefaultEdge string
	pollInterval    time.Duration
	pollAttempts    int

	mu sync.Mutex
	// operationMu serializes lifecycle operations across Public Access and the
	// lower-level compatibility routes. The process state lock alone cannot
	// prevent an enable and a stop from interleaving between child creation and
	// readiness observation.
	operationMu sync.Mutex
	states      map[string]*state
	// gnarAuthenticated is an in-memory presentation hint. The durable token
	// remains owned by gnar; Warren never reads or persists that credential.
	gnarAuthenticated bool
	// lastErrors keeps an actionable failure visible even when a process could
	// not be created (for example a missing gnar binary). It is memory-only.
	lastErrors map[string]string
}

type state struct {
	kind      string
	cmd       *exec.Cmd
	url       string
	err       string
	stopped   bool
	scanDone  chan struct{}
	ready     chan struct{}
	done      chan struct{}
	readyOnce sync.Once
}

func NewManager(
	logger *slog.Logger,
	target string,
	cloudflaredPath string,
	tailscalePath string,
	gnarPath string,
) *Manager {
	if logger == nil {
		logger = slog.Default()
	}
	return &Manager{
		logger:          logger,
		target:          target,
		cloudflaredPath: cloudflaredPath,
		tailscalePath:   tailscalePath,
		gnarPath:        gnarPath,
		pollInterval:    250 * time.Millisecond,
		pollAttempts:    40,
		states:          make(map[string]*state),
		lastErrors:      make(map[string]string),
	}
}

func (m *Manager) Start(kind string) (Status, error) {
	m.operationMu.Lock()
	defer m.operationMu.Unlock()
	return m.start(kind)
}

func (m *Manager) start(kind string) (Status, error) {
	switch kind {
	case KindCloudflared:
		return m.startCloudflared()
	case KindTailscale:
		return m.startTailscale()
	case KindGnar:
		return m.startGnar()
	default:
		return Status{}, fmt.Errorf("unknown tunnel kind %q", kind)
	}
}

func (m *Manager) Stop(kind string) error {
	m.operationMu.Lock()
	defer m.operationMu.Unlock()
	return m.stop(kind)
}

func (m *Manager) stop(kind string) error {
	switch kind {
	case KindCloudflared:
		return m.stopCloudflared()
	case KindTailscale:
		return m.stopTailscale()
	case KindGnar:
		return m.stopGnar()
	default:
		return fmt.Errorf("unknown tunnel kind %q", kind)
	}
}

func (m *Manager) Status() map[string]Status {
	m.mu.Lock()
	defer m.mu.Unlock()
	result := make(map[string]Status, len(m.states))
	for _, kind := range []string{KindCloudflared, KindTailscale, KindGnar} {
		if st := m.states[kind]; st != nil {
			result[kind] = Status{Running: !st.stopped, URL: st.url, Error: st.err}
		} else if message := m.lastErrors[kind]; message != "" {
			result[kind] = Status{Error: message}
		}
	}
	return result
}

// SetGnarEdge changes the edge server used by future gnar starts. An empty
// value lets gnar fall back to its own default.
func (m *Manager) SetGnarEdge(edge string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.gnarEdge = strings.TrimSpace(edge)
	m.gnarAuthenticated = false
}

// SetGnarConfigDir selects the credential directory for gnar child processes.
// Warren never reads the credential store; gnar remains the owner of its
// long-lived account token. An empty value deliberately leaves the child
// environment untouched for system gnar compatibility.
func (m *Manager) SetGnarConfigDir(directory string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	directory = strings.TrimSpace(directory)
	if directory != m.gnarConfigDir {
		m.gnarAuthenticated = false
		delete(m.lastErrors, KindGnar)
	}
	m.gnarConfigDir = directory
}

// GnarConfigDir returns the configured child-process credential directory.
func (m *Manager) GnarConfigDir() string {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.gnarConfigDir
}

// SetGnarDefaultEdge sets the release/launcher fallback used when the user
// has no persisted Edge override. It never writes settings.json.
func (m *Manager) SetGnarDefaultEdge(edge string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.gnarDefaultEdge = strings.TrimSpace(edge)
}

// SetGnarEdgeOverride applies a user setting while preserving the fallback
// selected by the release or launcher. An empty override deliberately resets
// the effective Edge to that fallback.
func (m *Manager) SetGnarEdgeOverride(edge string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	edge = strings.TrimSpace(edge)
	if edge == "" {
		m.gnarEdge = m.gnarDefaultEdge
		m.gnarAuthenticated = false
		return
	}
	m.gnarEdge = edge
	m.gnarAuthenticated = false
}

// GnarEdge returns the effective Edge URL selected for future gnar starts.
// It may come from WARREN_GNAR_EDGE or a command-line override and is not a
// credential.
func (m *Manager) GnarEdge() string {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.gnarEdge == "" {
		return m.gnarDefaultEdge
	}
	return m.gnarEdge
}

// GnarDefaultEdge returns the non-persisted fallback used when no custom Edge
// is configured. Source builds use the documented tunnel.example.com value;
// release builds may replace it at link time.
func (m *Manager) GnarDefaultEdge() string {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.gnarDefaultEdge
}

// GnarAuthenticated reports whether this manager has completed a gnar login or
// a token-backed connection test during its lifetime. It is intentionally not
// persisted and must not be treated as a credential-store query.
func (m *Manager) GnarAuthenticated() bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.gnarAuthenticated
}

func (m *Manager) setGnarAuthenticated(value bool) {
	m.mu.Lock()
	m.gnarAuthenticated = value
	if value {
		delete(m.lastErrors, KindGnar)
		// A failed start is retained briefly so its actionable error can be
		// reported. Once gnar login succeeds, that stopped state is stale and
		// must not shadow the newly authenticated configuration in Public Access
		// responses.
		if st := m.states[KindGnar]; st != nil && st.stopped {
			delete(m.states, KindGnar)
		}
	}
	m.mu.Unlock()
}

// InvalidateGnarAuthentication clears the presentation hint after a
// non-secret Edge/account change. It does not touch gnar's credential store.
func (m *Manager) InvalidateGnarAuthentication() {
	m.setGnarAuthenticated(false)
}

func (m *Manager) loginGnar(edge, account string, keyKind LoginKeyKind, key []byte) error {
	path := m.gnarPath
	if path == "" {
		path = findExecutable(gnarCandidates())
	}
	if path == "" {
		return errors.New("gnar binary not found; install it or set WARREN_GNAR_PATH")
	}
	return loginGnarWithEnvironment(path, edge, account, keyKind, key, m.gnarEnvironment())
}

func (m *Manager) gnarEnvironment() []string {
	m.mu.Lock()
	directory := m.gnarConfigDir
	m.mu.Unlock()
	return gnarEnvironmentFor(directory)
}

func gnarEnvironmentFor(directory string) []string {
	if directory == "" {
		return nil
	}
	environment := os.Environ()
	filtered := make([]string, 0, len(environment)+1)
	for _, entry := range environment {
		if strings.HasPrefix(entry, "GNAR_CONFIG_DIR=") {
			continue
		}
		filtered = append(filtered, entry)
	}
	return append(filtered, "GNAR_CONFIG_DIR="+directory)
}

// StartPublicAccess preserves the legacy API, treating its key as an approval
// (enrollment) key. New callers should use StartPublicAccessWithKey so invite
// keys select gnar's --key-stdin contract.
func (m *Manager) StartPublicAccess(edge, account string, enrollmentKey []byte) (Status, error) {
	return m.StartPublicAccessWithKey(edge, account, LoginKeyApproval, enrollmentKey)
}

// StartPublicAccessWithKey enrolls gnar when a one-time key is supplied, then
// starts the normal gnar tunnel. The key is accepted as bytes so callers can
// clear their request buffer immediately after this method returns. gnar
// remains responsible for its long-lived token and credential store.
func (m *Manager) StartPublicAccessWithKey(edge, account string, keyKind LoginKeyKind, key []byte) (Status, error) {
	m.operationMu.Lock()
	defer m.operationMu.Unlock()
	return m.startPublicAccessWithKey(edge, account, keyKind, key)
}

func (m *Manager) startPublicAccessWithKey(edge, account string, keyKind LoginKeyKind, key []byte) (Status, error) {
	if len(key) > 0 && keyKind != LoginKeyApproval && keyKind != LoginKeyInvite {
		err := errors.New("unsupported gnar bootstrap key type")
		m.recordError(KindGnar, err.Error())
		clearBytes(key)
		return Status{Error: err.Error()}, err
	}
	if len(key) > 0 {
		defer clearBytes(key)
	}
	edge = strings.TrimSpace(edge)
	if edge != "" {
		if err := ValidateEdgeURL(edge); err != nil {
			return Status{Error: err.Error()}, err
		}
		m.SetGnarEdge(edge)
	}
	if len(key) > 0 {
		if edge == "" {
			edge = m.GnarEdge()
		}
		if edge == "" {
			err := errors.New("an Edge URL is required before enrolling gnar")
			m.recordError(KindGnar, err.Error())
			return Status{Error: err.Error()}, err
		}
		if err := ValidateEdgeURL(edge); err != nil {
			m.recordError(KindGnar, err.Error())
			return Status{Error: err.Error()}, err
		}
		account, err := normalizeGnarAccount(account)
		if err != nil {
			m.recordError(KindGnar, err.Error())
			return Status{Error: err.Error()}, err
		}
		if err := validateBootstrapKey(keyKind, key); err != nil {
			m.recordError(KindGnar, err.Error())
			return Status{Error: err.Error()}, err
		}
		if err := m.loginGnar(edge, account, keyKind, key); err != nil {
			m.recordError(KindGnar, err.Error())
			return Status{Error: err.Error()}, err
		}
		// The key is bootstrap-only. Clear it before the long-lived tunnel
		// process is started; the deferred clear covers every early return.
		clearBytes(key)
	}
	status, err := m.start(KindGnar)
	if err != nil {
		if len(key) == 0 {
			err = actionableGnarStartError(err)
			status.Error = err.Error()
		}
		return status, err
	}
	if status.Running && status.URL != "" {
		m.setGnarAuthenticated(true)
		return status, nil
	}
	if status.Error == "" {
		status.Error = "gnar did not report a public endpoint before the startup timeout"
	}
	if len(key) == 0 {
		status.Error = actionableGnarStartError(errors.New(status.Error)).Error()
	}
	m.recordError(KindGnar, status.Error)
	return status, errors.New(status.Error)
}

// TestPublicAccess authenticates gnar when a bootstrap key is supplied. That
// login is sufficient for the first Save & Test result; the normal tunnel is
// only started and stopped when no key is supplied, which verifies an already
// persisted gnar token without leaving a Public Endpoint live.
func (m *Manager) TestPublicAccess(edge, account string, keyKind LoginKeyKind, key []byte) (Status, error) {
	m.operationMu.Lock()
	defer m.operationMu.Unlock()
	return m.testPublicAccess(edge, account, keyKind, key)
}

func (m *Manager) testPublicAccess(edge, account string, keyKind LoginKeyKind, key []byte) (Status, error) {
	// A failed re-test must not leave the UI claiming that an older connection
	// still authenticates the newly submitted configuration.
	m.InvalidateGnarAuthentication()
	if len(key) > 0 && keyKind != LoginKeyApproval && keyKind != LoginKeyInvite {
		err := errors.New("unsupported gnar bootstrap key type")
		m.recordError(KindGnar, err.Error())
		clearBytes(key)
		return Status{Error: err.Error()}, err
	}
	hasBootstrapKey := len(key) > 0
	if hasBootstrapKey {
		defer clearBytes(key)
	}
	// Start is idempotent by design. A connection test must not accidentally
	// reuse a live process that was started with a different Edge or account.
	if current, ok := m.Status()[KindGnar]; ok && current.Running {
		if err := m.stop(KindGnar); err != nil {
			m.recordError(KindGnar, err.Error())
			return Status{Error: err.Error()}, err
		}
	}
	edge = strings.TrimSpace(edge)
	if edge != "" {
		if err := ValidateEdgeURL(edge); err != nil {
			m.recordError(KindGnar, err.Error())
			return Status{Error: err.Error()}, err
		}
		m.SetGnarEdge(edge)
	}
	if edge == "" {
		edge = m.GnarEdge()
	}
	if edge == "" {
		err := errors.New("an Edge URL is required to test the gnar connection")
		m.recordError(KindGnar, err.Error())
		return Status{Error: err.Error()}, err
	}
	if err := ValidateEdgeURL(edge); err != nil {
		m.recordError(KindGnar, err.Error())
		return Status{Error: err.Error()}, err
	}
	account, err := normalizeGnarAccount(account)
	if err != nil {
		m.recordError(KindGnar, err.Error())
		return Status{Error: err.Error()}, err
	}
	if hasBootstrapKey {
		if err := validateBootstrapKey(keyKind, key); err != nil {
			m.recordError(KindGnar, err.Error())
			return Status{Error: err.Error()}, err
		}
		if err := m.loginGnar(edge, account, keyKind, key); err != nil {
			m.recordError(KindGnar, err.Error())
			return Status{Error: err.Error()}, err
		}
	}
	// A bootstrap login is the connection test. The login command has already
	// contacted the configured Edge and gnar has durably stored its token. Do
	// not make Save & Test depend on the normal tunnel's readiness window: the
	// top Web control starts the live endpoint after the user sees success.
	if hasBootstrapKey {
		m.setGnarAuthenticated(true)
		return Status{}, nil
	}
	status, err := m.start(KindGnar)
	if err != nil {
		err = actionableGnarStartError(err)
		status.Error = err.Error()
		m.recordError(KindGnar, status.Error)
		return status, err
	}
	if !status.Running || status.URL == "" {
		message := status.Error
		if message == "" {
			message = "gnar did not report a public endpoint during the connection test"
		}
		message = actionableGnarStartError(errors.New(message)).Error()
		m.recordError(KindGnar, message)
		_ = m.stop(KindGnar)
		return Status{Error: message}, errors.New(message)
	}
	if err := m.stop(KindGnar); err != nil {
		m.recordError(KindGnar, err.Error())
		return Status{Error: err.Error()}, err
	}
	m.setGnarAuthenticated(true)
	status.Running = false
	status.URL = ""
	status.Error = ""
	return status, nil
}

// validateBootstrapKey mirrors gnar v1.7's invite-key contract before a
// network request is made. The invite value is the generated secret, not the
// operator-facing key name; gnar refuses configured invite secrets shorter
// than twelve characters. Approval/enrollment keys have no equivalent local
// length requirement because their policy belongs to the Edge operator.
func validateBootstrapKey(kind LoginKeyKind, key []byte) error {
	value := bytes.TrimSpace(key)
	if len(value) == 0 {
		return errors.New("the bootstrap key must not be empty")
	}
	if kind == LoginKeyInvite && len(value) < 12 {
		return errors.New("Invite Key must be at least 12 characters; enter the invite secret, not its key name")
	}
	return nil
}

func actionableGnarStartError(err error) error {
	if err == nil {
		return nil
	}
	message := err.Error()
	lower := strings.ToLower(message)
	if strings.Contains(lower, "enroll") || strings.Contains(lower, "no persisted gnar token") || strings.Contains(lower, "sign in") || strings.Contains(lower, "login") {
		if !strings.Contains(lower, "approval key") && !strings.Contains(lower, "invite key") {
			return fmt.Errorf("%s; enter an Approval Key or Invite Key in Settings → Public Access", message)
		}
	}
	return err
}

// StopAll tears down every running reachability adapter. The daemon calls it
// on shutdown so a public tunnel never outlives its owner process.
func (m *Manager) StopAll() {
	m.operationMu.Lock()
	defer m.operationMu.Unlock()
	for _, kind := range []string{KindCloudflared, KindTailscale, KindGnar} {
		_ = m.stop(kind)
	}
}

func (m *Manager) startCloudflared() (Status, error) {
	m.mu.Lock()
	if st := m.states[KindCloudflared]; st != nil && !st.stopped {
		status := Status{Running: true, URL: st.url}
		m.mu.Unlock()
		return status, nil
	}
	path := m.cloudflaredPath
	if path == "" {
		path = findExecutable(cloudflaredCandidates)
	}
	if path == "" {
		m.mu.Unlock()
		return Status{}, errors.New("cloudflared binary not found; install it or set WARREN_CLOUDFLARED_PATH")
	}
	command := exec.Command(path, "tunnel", "--url", m.target, "--no-autoupdate")
	stdout, err := command.StdoutPipe()
	if err != nil {
		m.mu.Unlock()
		return Status{}, err
	}
	stderr, err := command.StderrPipe()
	if err != nil {
		m.mu.Unlock()
		return Status{}, err
	}
	if err := command.Start(); err != nil {
		m.mu.Unlock()
		return Status{}, err
	}
	st := &state{kind: KindCloudflared, cmd: command}
	m.states[KindCloudflared] = st
	m.mu.Unlock()

	go m.scanCloudflared(st, mergeProcessOutput(stdout, stderr))
	go m.wait(st)
	return m.Status()[KindCloudflared], nil
}

func (m *Manager) scanCloudflared(st *state, reader io.Reader) {
	if closer, ok := reader.(io.Closer); ok {
		defer closer.Close()
	}
	scanner := bufio.NewScanner(reader)
	scanner.Buffer(make([]byte, 64*1024), 1024*1024)
	ready := false
	for scanner.Scan() {
		if !ready {
			if found := parseCloudflaredURL(scanner.Text()); found != "" {
				m.mu.Lock()
				if st == m.states[st.kind] {
					st.url = found
				}
				m.mu.Unlock()
				m.logger.Info("tunnel ready", "kind", st.kind, "url", found)
				ready = true
			}
		}
	}
}

func (m *Manager) stopCloudflared() error {
	m.mu.Lock()
	st := m.states[KindCloudflared]
	if st != nil {
		st.stopped = true
	}
	m.mu.Unlock()
	if st == nil {
		return nil
	}
	if st.cmd != nil && st.cmd.Process != nil {
		_ = st.cmd.Process.Kill()
	}
	m.waitForStop(KindCloudflared, 2*time.Second)
	return nil
}

func (m *Manager) wait(st *state) {
	_ = st.cmd.Wait()
	if st.scanDone != nil {
		<-st.scanDone
	}
	// Wake a synchronous gnar start when the child exits before emitting a
	// readiness or error event. Without this signal a dead child would make
	// the caller wait for the full startup timeout.
	if st.ready != nil {
		st.readyOnce.Do(func() { close(st.ready) })
	}
	m.mu.Lock()
	if m.states[st.kind] == st {
		if st.kind == KindGnar && !st.stopped && st.err == "" {
			st.err = "gnar exited before the Public Endpoint remained available"
			st.url = ""
			st.stopped = true
		}
		if st.err == "" {
			delete(m.states, st.kind)
		} else {
			// Keep the failed state so callers can see why the adapter exited.
			st.stopped = true
			st.url = ""
		}
	}
	m.mu.Unlock()
	if st.done != nil {
		close(st.done)
	}
}

func (m *Manager) waitForStop(kind string, timeout time.Duration) {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		m.mu.Lock()
		_, exists := m.states[kind]
		m.mu.Unlock()
		if !exists {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func waitForStateDone(st *state, timeout time.Duration) {
	if st == nil || st.done == nil {
		return
	}
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case <-st.done:
	case <-timer.C:
	}
}

func (m *Manager) startTailscale() (Status, error) {
	kind := KindTailscale
	m.mu.Lock()
	if st := m.states[kind]; st != nil && !st.stopped {
		status := Status{Running: true, URL: st.url}
		m.mu.Unlock()
		return status, nil
	}
	path := m.tailscalePath
	if path == "" {
		path = findExecutable(tailscaleCandidates)
	}
	if path == "" {
		m.mu.Unlock()
		return Status{}, errors.New("tailscale binary not found; install it or set WARREN_TAILSCALE_PATH")
	}
	port, err := targetPort(m.target)
	if err != nil {
		m.mu.Unlock()
		return Status{}, err
	}
	command := exec.Command(path, "serve", "--bg", port)
	output, err := command.CombinedOutput()
	if err != nil {
		m.mu.Unlock()
		return Status{}, fmt.Errorf("start tailscale: %w: %s", err, strings.TrimSpace(string(output)))
	}
	st := &state{kind: kind}
	m.states[kind] = st
	m.mu.Unlock()

	for attempt := 0; attempt < m.pollAttempts; attempt++ {
		statusCommand := exec.Command(path, "serve", "status", "--json")
		statusOutput, err := statusCommand.Output()
		if err == nil {
			if candidate := parseTailscaleURL(statusOutput); candidate != "" {
				m.mu.Lock()
				st.url = candidate
				m.mu.Unlock()
				m.logger.Info("tunnel ready", "kind", kind, "url", candidate)
				return m.Status()[kind], nil
			}
		}
		time.Sleep(m.pollInterval)
	}
	return m.Status()[kind], nil
}

func (m *Manager) stopTailscale() error {
	kind := KindTailscale
	m.mu.Lock()
	st := m.states[kind]
	if st != nil {
		st.stopped = true
	}
	m.mu.Unlock()
	if st == nil {
		return nil
	}
	path := m.tailscalePath
	if path == "" {
		path = findExecutable(tailscaleCandidates)
	}
	if path != "" {
		command := exec.Command(path, "serve", "--https=443", "off")
		if output, err := command.CombinedOutput(); err != nil {
			m.logger.Warn("stop tailscale", "kind", kind, "error", err, "output", strings.TrimSpace(string(output)))
		}
	}
	m.mu.Lock()
	if m.states[kind] == st {
		delete(m.states, kind)
	}
	m.mu.Unlock()
	return nil
}

func (m *Manager) startGnar() (Status, error) {
	m.mu.Lock()
	if st := m.states[KindGnar]; st != nil && !st.stopped {
		status := Status{Running: true, URL: st.url, Error: st.err}
		m.mu.Unlock()
		return status, nil
	}
	path := m.gnarPath
	if path == "" {
		path = findExecutable(gnarCandidates())
	}
	if path == "" {
		m.mu.Unlock()
		err := errors.New("gnar binary not found; install it or set WARREN_GNAR_PATH")
		m.recordError(KindGnar, err.Error())
		return Status{Error: err.Error()}, err
	}
	nameArgs := gnarNameArgs()
	reapStaleGnar(m.target, gnarProcessName())
	edge := m.gnarEdge
	if edge == "" {
		edge = m.gnarDefaultEdge
	}
	if edge != "" {
		if err := ValidateEdgeURL(edge); err != nil {
			m.mu.Unlock()
			m.recordError(KindGnar, err.Error())
			return Status{Error: err.Error()}, err
		}
	}
	args := []string{m.target, "--no-tui", "--json"}
	if edge != "" {
		args = append(args, "--edge", edge)
	}
	args = append(args, nameArgs...)
	command := exec.Command(path, args...)
	command.Env = gnarEnvironmentFor(m.gnarConfigDir)
	stdout, err := command.StdoutPipe()
	if err != nil {
		m.mu.Unlock()
		m.recordError(KindGnar, err.Error())
		return Status{Error: err.Error()}, err
	}
	stderr, err := command.StderrPipe()
	if err != nil {
		m.mu.Unlock()
		m.recordError(KindGnar, err.Error())
		return Status{Error: err.Error()}, err
	}
	if err := command.Start(); err != nil {
		m.mu.Unlock()
		m.recordError(KindGnar, err.Error())
		return Status{Error: err.Error()}, err
	}
	st := &state{
		kind:     KindGnar,
		cmd:      command,
		scanDone: make(chan struct{}),
		ready:    make(chan struct{}),
		done:     make(chan struct{}),
	}
	m.states[KindGnar] = st
	m.mu.Unlock()

	go m.scanGnar(st, mergeProcessOutput(stdout, stderr))
	go m.wait(st)
	// Start is synchronous for the caller: wait for the first tunnel_ready or
	// error event so the client can show the public endpoint immediately. A
	// process that never answers is terminated instead of being reported live.
	select {
	case <-st.ready:
	case <-time.After(time.Duration(m.pollAttempts) * m.pollInterval):
	}
	// A child can emit tunnel_ready and exit in the same scheduling window.
	// Give wait a short grace period to observe that exit before returning a
	// live endpoint to Public Access callers.
	if st.done != nil {
		select {
		case <-st.done:
		case <-time.After(50 * time.Millisecond):
		}
	}
	status := m.Status()[KindGnar]
	if status.URL != "" {
		m.mu.Lock()
		delete(m.lastErrors, KindGnar)
		m.mu.Unlock()
		m.setGnarAuthenticated(true)
	}
	if status.URL == "" {
		if status.Error == "" {
			status.Error = "gnar did not report a public endpoint before the startup timeout"
			m.mu.Lock()
			if m.states[KindGnar] == st {
				st.err = status.Error
				st.stopped = true
				st.url = ""
			}
			m.mu.Unlock()
		} else {
			m.mu.Lock()
			if m.states[KindGnar] == st {
				st.stopped = true
				st.url = ""
			}
			m.mu.Unlock()
		}
		if st.cmd != nil && st.cmd.Process != nil {
			_ = st.cmd.Process.Kill()
		}
		waitForStateDone(st, 2*time.Second)
		status.Running = false
		status.URL = ""
	}
	return status, nil
}

func (m *Manager) scanGnar(st *state, reader io.Reader) {
	defer close(st.scanDone)
	if closer, ok := reader.(io.Closer); ok {
		defer closer.Close()
	}
	scanner := bufio.NewScanner(reader)
	scanner.Buffer(make([]byte, 64*1024), 1024*1024)
	for scanner.Scan() {
		var event struct {
			Type      string `json:"type"`
			PublicURL string `json:"public_url"`
			Message   string `json:"message"`
		}
		if json.Unmarshal(scanner.Bytes(), &event) != nil {
			continue
		}
		message := redactGnarText(event.Message)
		actionable := actionableGnarStartError(errors.New(message)).Error()
		m.mu.Lock()
		if m.states[st.kind] == st {
			switch event.Type {
			case "tunnel_ready":
				if event.PublicURL != "" {
					if endpoint, err := NormalizePublicEndpoint(event.PublicURL); err == nil {
						st.url = endpoint
					} else {
						st.err = "gnar returned an invalid public endpoint"
					}
				}
			case "error":
				st.err = actionable
			}
		}
		m.mu.Unlock()
		switch event.Type {
		case "tunnel_ready":
			if endpoint, err := NormalizePublicEndpoint(event.PublicURL); err == nil && endpoint != "" {
				m.logger.Info("tunnel ready", "kind", st.kind, "url", endpoint)
			}
		case "error":
			m.logger.Warn("gnar tunnel error", "kind", st.kind, "error", actionable)
		}
		if event.Type == "tunnel_ready" || event.Type == "error" {
			st.readyOnce.Do(func() { close(st.ready) })
		}
	}
}

func (m *Manager) stopGnar() error {
	m.mu.Lock()
	st := m.states[KindGnar]
	if st != nil {
		st.stopped = true
	}
	m.mu.Unlock()
	if st == nil {
		m.mu.Lock()
		delete(m.lastErrors, KindGnar)
		m.mu.Unlock()
		return nil
	}
	if st.cmd != nil && st.cmd.Process != nil {
		_ = st.cmd.Process.Kill()
	}
	waitForStateDone(st, 2*time.Second)
	m.mu.Lock()
	if m.states[KindGnar] == st {
		delete(m.states, KindGnar)
	}
	delete(m.lastErrors, KindGnar)
	m.mu.Unlock()
	m.waitForStop(KindGnar, 2*time.Second)
	return nil
}

func (m *Manager) recordError(kind, message string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.lastErrors[kind] = redactGnarText(message)
}

var (
	cloudflaredCandidates = []string{
		"/opt/homebrew/bin/cloudflared",
		"/usr/local/bin/cloudflared",
		"/usr/bin/cloudflared",
	}
	tailscaleCandidates = []string{
		"/usr/local/bin/tailscale",
		"/Applications/Tailscale.app/Contents/MacOS/Tailscale",
	}
	cloudflaredURLPattern = regexp.MustCompile(`https://[a-zA-Z0-9-]+\.trycloudflare\.com`)
)

func gnarCandidates() []string {
	candidates := []string{"/opt/homebrew/bin/gnar", "/usr/local/bin/gnar", "/usr/bin/gnar"}
	if home, err := os.UserHomeDir(); err == nil {
		candidates = append([]string{filepath.Join(home, ".local", "bin", "gnar")}, candidates...)
	}
	return candidates
}

func gnarNameArgs() []string {
	name := gnarProcessName()
	if name == "" {
		return nil
	}
	return []string{"--name", name}
}

func gnarProcessName() string {
	hostname, err := os.Hostname()
	if err != nil {
		return ""
	}
	var name strings.Builder
	for _, character := range strings.ToLower(hostname) {
		if (character >= 'a' && character <= 'z') || (character >= '0' && character <= '9') {
			name.WriteRune(character)
		} else if name.Len() > 0 && !strings.HasSuffix(name.String(), "-") {
			name.WriteByte('-')
		}
	}
	normalized := strings.Trim(name.String(), "-")
	if normalized == "" {
		return ""
	}
	if len(normalized) > 32 {
		normalized = strings.TrimRight(normalized[:32], "-")
	}
	return "warren-" + normalized
}

// reapStaleGnar kills gnar processes left behind by a previous daemon that
// was not stopped cleanly. Without this, a restarted daemon would start a
// second client for the same reserved name and both processes would fight
// over one public endpoint.
func reapStaleGnar(target, name string) {
	data, err := exec.Command("ps", "-axo", "pid=,command=").Output()
	if err != nil {
		return
	}
	var stalePIDs []int
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		fields := strings.SplitN(line, " ", 2)
		if len(fields) != 2 {
			continue
		}
		command := fields[1]
		arguments := strings.Fields(command)
		if !strings.Contains(command, "gnar") || !isGnarProcess(arguments) {
			continue
		}
		if name != "" {
			if !hasArgumentValue(arguments, "--name", name) {
				continue
			}
		} else if target == "" || !strings.Contains(command, target) {
			continue
		}
		pid, err := strconv.Atoi(fields[0])
		if err != nil {
			continue
		}
		if process, err := os.FindProcess(pid); err == nil {
			if err := process.Kill(); err == nil {
				stalePIDs = append(stalePIDs, pid)
			}
		}
	}
	for _, pid := range stalePIDs {
		terminateStaleProcess(pid)
	}
}

func isGnarProcess(arguments []string) bool {
	for _, argument := range arguments {
		if strings.HasSuffix(argument, "/gnar") || argument == "gnar" {
			return true
		}
	}
	return false
}

func hasArgumentValue(arguments []string, flag, value string) bool {
	for index := 0; index+1 < len(arguments); index++ {
		if arguments[index] == flag && arguments[index+1] == value {
			return true
		}
	}
	return false
}

func terminateStaleProcess(pid int) {
	for attempt := 0; attempt < 3; attempt++ {
		process, err := os.FindProcess(pid)
		if err != nil {
			return
		}
		_ = process.Kill()
		if waitForProcessExit(pid, 500*time.Millisecond) {
			return
		}
	}
}

func waitForProcessExit(pid int, timeout time.Duration) bool {
	process, err := os.FindProcess(pid)
	if err != nil {
		return true
	}
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if err := process.Signal(syscall.Signal(0)); err != nil {
			return true
		}
		time.Sleep(25 * time.Millisecond)
	}
	return false
}

// mergeProcessOutput drains stdout and stderr concurrently while preserving
// line boundaries for the JSON event scanner. A serial io.MultiReader can
// leave stderr unread forever when gnar keeps stdout open, eventually filling
// the stderr pipe and blocking the child.
func mergeProcessOutput(readers ...io.Reader) io.ReadCloser {
	reader, writer := io.Pipe()
	var writers sync.WaitGroup
	var writeMu sync.Mutex
	writers.Add(len(readers))
	for _, source := range readers {
		go func(source io.Reader) {
			defer writers.Done()
			scanner := bufio.NewScanner(source)
			scanner.Buffer(make([]byte, 64*1024), 8*1024*1024)
			for scanner.Scan() {
				line := append([]byte(nil), scanner.Bytes()...)
				line = append(line, '\n')
				writeMu.Lock()
				_, err := writer.Write(line)
				writeMu.Unlock()
				if err != nil {
					return
				}
			}
		}(source)
	}
	go func() {
		writers.Wait()
		_ = writer.Close()
	}()
	return reader
}

func findExecutable(candidates []string) string {
	for _, candidate := range candidates {
		if info, err := os.Stat(candidate); err == nil && !info.IsDir() && info.Mode()&0o111 != 0 {
			return candidate
		}
	}
	return ""
}

func targetPort(target string) (string, error) {
	parsed, err := url.Parse(target)
	if err != nil || parsed.Port() == "" {
		return "", fmt.Errorf("tunnel target %q must include a port", target)
	}
	return parsed.Port(), nil
}

func parseCloudflaredURL(line string) string {
	return cloudflaredURLPattern.FindString(line)
}

func parseTailscaleURL(data []byte) string {
	var object map[string]any
	if json.Unmarshal(data, &object) != nil {
		return ""
	}
	section, ok := object["Web"].(map[string]any)
	if !ok {
		return ""
	}
	for host := range section {
		return "https://" + strings.SplitN(host, ":", 2)[0] + "/"
	}
	return ""
}

// ValidateEdgeURL accepts only absolute HTTP(S) URLs. Credentials, queries,
// and fragments are rejected so an Edge configuration can never smuggle a
// secret into a child command or a public endpoint.
func ValidateEdgeURL(raw string) error {
	value := strings.TrimSpace(raw)
	if value == "" {
		return errors.New("Edge URL is required")
	}
	parsed, err := url.Parse(value)
	if err != nil || parsed.Host == "" || parsed.Hostname() == "" ||
		(parsed.Scheme != "http" && parsed.Scheme != "https") ||
		parsed.User != nil || parsed.RawQuery != "" || parsed.ForceQuery ||
		parsed.Fragment != "" || strings.Contains(value, "#") || strings.Contains(value, "?") || parsed.Opaque != "" {
		return fmt.Errorf("Edge URL must be an absolute HTTP(S) URL without credentials, query, or fragment")
	}
	return nil
}

// NormalizePublicEndpoint validates a gnar endpoint and preserves a trailing
// slash for path-mode endpoints. The root host form intentionally remains
// without a slash to avoid changing gnar's reserved URL display.
func NormalizePublicEndpoint(raw string) (string, error) {
	value := strings.TrimSpace(raw)
	if err := ValidateEdgeURL(value); err != nil {
		return "", fmt.Errorf("invalid public endpoint: %w", err)
	}
	parsed, err := url.Parse(value)
	if err != nil {
		return "", err
	}
	if parsed.Path != "" && parsed.Path != "/" && !strings.HasSuffix(parsed.Path, "/") {
		parsed.Path += "/"
	}
	return parsed.String(), nil
}

func loginGnar(path, edge, account string, keyKind LoginKeyKind, key []byte) error {
	return loginGnarWithEnvironment(path, edge, account, keyKind, key, nil)
}

func loginGnarWithEnvironment(path, edge, account string, keyKind LoginKeyKind, key []byte, environment []string) error {
	ctx, cancel := context.WithTimeout(context.Background(), gnarLoginTimeout)
	defer cancel()
	args := []string{"login", "--edge", edge, "--account", account}
	switch keyKind {
	case LoginKeyApproval:
		args = append(args, "--enrollment-key-stdin")
	case LoginKeyInvite:
		args = append(args, "--key-stdin")
	default:
		return errors.New("unsupported gnar bootstrap key type")
	}
	args = append(args, "--json")
	command := exec.CommandContext(
		ctx,
		path,
		args...,
	)
	if len(environment) > 0 {
		command.Env = environment
	}
	command.Stdin = bytes.NewReader(key)
	var stdout, stderr bytes.Buffer
	command.Stdout = &stdout
	command.Stderr = &stderr
	err := command.Run()
	combined := append(stdout.Bytes(), stderr.Bytes()...)
	message := gnarLoginMessage(combined)
	if ctx.Err() == context.DeadlineExceeded {
		return errors.New("gnar login timed out; check the Edge URL and try again")
	}
	if err != nil {
		if message == "" {
			message = "gnar login failed"
		}
		return fmt.Errorf("%s: %w", redactGnarText(message, string(key)), err)
	}
	if message != "" && strings.HasPrefix(strings.ToLower(message), "error:") {
		return errors.New(redactGnarText(message, string(key)))
	}
	return nil
}

func normalizeGnarAccount(value string) (string, error) {
	normalized := strings.ToLower(strings.TrimSpace(value))
	if normalized == "" {
		normalized = defaultGnarAccount()
	}
	if normalized == "" {
		normalized = "warren"
	}
	if len(normalized) == 0 || len(normalized) > 16 {
		return "", errors.New("gnar account name must be 1 to 16 lowercase letters, numbers, or hyphens")
	}
	for index, character := range normalized {
		if (character >= 'a' && character <= 'z') ||
			(character >= '0' && character <= '9') || character == '-' {
			if (index == 0 || index == len(normalized)-1) && character == '-' {
				return "", errors.New("gnar account name must start and end with a letter or number")
			}
			continue
		}
		return "", errors.New("gnar account name must be 1 to 16 lowercase letters, numbers, or hyphens")
	}
	return normalized, nil
}

func defaultGnarAccount() string {
	hostName, err := os.Hostname()
	if err != nil {
		return ""
	}
	var builder strings.Builder
	for _, character := range strings.ToLower(strings.TrimSpace(hostName)) {
		if (character >= 'a' && character <= 'z') || (character >= '0' && character <= '9') {
			builder.WriteRune(character)
			continue
		}
		if builder.Len() > 0 && !strings.HasSuffix(builder.String(), "-") {
			builder.WriteByte('-')
		}
	}
	normalized := strings.Trim(builder.String(), "-")
	if len(normalized) > 16 {
		normalized = strings.TrimRight(normalized[:16], "-")
	}
	return normalized
}

func gnarLoginMessage(data []byte) string {
	var fallback string
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		var event struct {
			Type    string `json:"type"`
			Message string `json:"message"`
			Error   string `json:"error"`
			OK      *bool  `json:"ok"`
			Success *bool  `json:"success"`
		}
		if json.Unmarshal([]byte(line), &event) != nil {
			fallback = line
			continue
		}
		message := strings.TrimSpace(event.Message)
		if message == "" {
			message = strings.TrimSpace(event.Error)
		}
		if event.Type == "error" || (event.OK != nil && !*event.OK) || (event.Success != nil && !*event.Success) {
			if message == "" {
				message = "gnar login failed"
			}
			return "error: " + message
		}
		if message != "" {
			fallback = message
		}
	}
	return fallback
}

func redactGnarText(value string, secrets ...string) string {
	for _, secret := range secrets {
		if secret != "" {
			value = strings.ReplaceAll(value, secret, "<redacted>")
		}
	}
	value = sensitiveGnarPattern.ReplaceAllString(value, `$1$2<redacted>`)
	value = sensitiveValuePattern.ReplaceAllString(value, `$1<redacted>`)
	return sensitiveBareValuePattern.ReplaceAllString(value, `$1<redacted>`)
}

var sensitiveGnarPattern = regexp.MustCompile(`(?i)(enrollment[-_ ]?key|approval[-_ ]?key|invite[-_ ]?key|access[-_ ]?token|daemon[-_ ]?token|account[-_ ]?token)(\s*[:=]\s*["']?)[^\s,"'}]+`)
var sensitiveValuePattern = regexp.MustCompile(`(?i)((?:token|secret|credential|enrollment[-_ ]?key|approval[-_ ]?key|invite[-_ ]?key)(?:\s+is)?\s*[:=]\s*["']?)[A-Za-z0-9._~+/=-]{8,}`)
var sensitiveBareValuePattern = regexp.MustCompile(`(?i)((?:access[-_ ]?token|daemon[-_ ]?token|account[-_ ]?token|token|secret|credential|enrollment[-_ ]?key|approval[-_ ]?key|invite[-_ ]?key)\s+)[A-Za-z0-9._~+/=-]{12,}`)

func clearBytes(value []byte) {
	for index := range value {
		value[index] = 0
	}
}
