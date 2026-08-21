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
	"time"
)

const (
	KindCloudflared  = "cloudflared"
	KindTailscale    = "tailscale"
	KindGnar         = "gnar"
	gnarLoginTimeout = 30 * time.Second
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
	gnarEdge        string
	gnarDefaultEdge string
	pollInterval    time.Duration
	pollAttempts    int

	mu     sync.Mutex
	states map[string]*state
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
		return
	}
	m.gnarEdge = edge
}

// GnarEdge returns the effective Edge URL selected for future gnar starts.
// It may come from WARREN_GNAR_EDGE or a command-line override and is not a
// credential.
func (m *Manager) GnarEdge() string {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.gnarEdge
}

// GnarDefaultEdge returns the non-persisted fallback used when no custom Edge
// is configured. It may be empty for source builds without release injection.
func (m *Manager) GnarDefaultEdge() string {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.gnarDefaultEdge
}

// StartPublicAccess enrolls gnar when a one-time enrollment key is supplied,
// then starts the normal gnar tunnel. The key is accepted as bytes so callers
// can clear their request buffer immediately after this method returns.
// gnar remains responsible for its long-lived token and credential store.
func (m *Manager) StartPublicAccess(edge, account string, enrollmentKey []byte) (Status, error) {
	if len(enrollmentKey) > 0 {
		defer clearBytes(enrollmentKey)
	}
	edge = strings.TrimSpace(edge)
	if edge != "" {
		if err := ValidateEdgeURL(edge); err != nil {
			return Status{Error: err.Error()}, err
		}
		m.SetGnarEdge(edge)
	}
	if len(enrollmentKey) > 0 {
		path := m.gnarPath
		if path == "" {
			path = findExecutable(gnarCandidates())
		}
		if path == "" {
			err := errors.New("gnar binary not found; install it or set WARREN_GNAR_PATH")
			m.recordError(KindGnar, err.Error())
			return Status{Error: err.Error()}, err
		}
		if edge == "" {
			m.mu.Lock()
			edge = m.gnarEdge
			m.mu.Unlock()
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
		account = strings.TrimSpace(account)
		if account == "" {
			account = "warren"
		}
		for _, character := range account {
			if character < 0x20 || character == 0x7f {
				err := errors.New("gnar account name contains a control character")
				m.recordError(KindGnar, err.Error())
				return Status{Error: err.Error()}, err
			}
		}
		if err := loginGnar(path, edge, account, enrollmentKey); err != nil {
			m.recordError(KindGnar, err.Error())
			return Status{Error: err.Error()}, err
		}
		// The key is bootstrap-only. Clear it before the long-lived tunnel
		// process is started; the deferred clear covers every early return.
		clearBytes(enrollmentKey)
	}
	status, err := m.Start(KindGnar)
	if err != nil {
		return status, err
	}
	if status.Running && status.URL != "" {
		return status, nil
	}
	if status.Error == "" {
		status.Error = "gnar did not report a public endpoint before the startup timeout"
	}
	m.recordError(KindGnar, status.Error)
	return status, errors.New(status.Error)
}

// StopAll tears down every running reachability adapter. The daemon calls it
// on shutdown so a public tunnel never outlives its owner process.
func (m *Manager) StopAll() {
	for _, kind := range []string{KindCloudflared, KindTailscale, KindGnar} {
		_ = m.Stop(kind)
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

	go m.scanCloudflared(st, io.MultiReader(stdout, stderr))
	go m.wait(st)
	return m.Status()[KindCloudflared], nil
}

func (m *Manager) scanCloudflared(st *state, reader io.Reader) {
	scanner := bufio.NewScanner(reader)
	scanner.Buffer(make([]byte, 64*1024), 1024*1024)
	for scanner.Scan() {
		if found := parseCloudflaredURL(scanner.Text()); found != "" {
			m.mu.Lock()
			if st == m.states[st.kind] {
				st.url = found
			}
			m.mu.Unlock()
			m.logger.Info("tunnel ready", "kind", st.kind, "url", found)
			return
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
	reapStaleGnar(m.target)
	if m.gnarEdge != "" {
		if err := ValidateEdgeURL(m.gnarEdge); err != nil {
			m.mu.Unlock()
			m.recordError(KindGnar, err.Error())
			return Status{Error: err.Error()}, err
		}
	}
	args := []string{m.target, "--no-tui", "--json"}
	if m.gnarEdge != "" {
		args = append(args, "--edge", m.gnarEdge)
	}
	args = append(args, gnarNameArgs()...)
	command := exec.Command(path, args...)
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

	go m.scanGnar(st, io.MultiReader(stdout, stderr))
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
				st.err = message
			}
		}
		m.mu.Unlock()
		switch event.Type {
		case "tunnel_ready":
			if endpoint, err := NormalizePublicEndpoint(event.PublicURL); err == nil && endpoint != "" {
				m.logger.Info("tunnel ready", "kind", st.kind, "url", endpoint)
			}
		case "error":
			m.logger.Warn("gnar tunnel error", "kind", st.kind, "error", message)
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
	hostname, err := os.Hostname()
	if err != nil {
		return nil
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
		return nil
	}
	if len(normalized) > 32 {
		normalized = strings.TrimRight(normalized[:32], "-")
	}
	return []string{"--name", "warren-" + normalized}
}

// reapStaleGnar kills gnar processes left behind by a previous daemon that
// was not stopped cleanly. Without this, a restarted daemon would start a
// second client for the same reserved name and both processes would fight
// over one public endpoint.
func reapStaleGnar(target string) {
	data, err := exec.Command("ps", "-axo", "pid=,command=").Output()
	if err != nil {
		return
	}
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
		if !strings.Contains(command, "gnar") ||
			!strings.Contains(command, target) ||
			!strings.Contains(command, "--name warren-") {
			continue
		}
		pid, err := strconv.Atoi(fields[0])
		if err != nil {
			continue
		}
		if process, err := os.FindProcess(pid); err == nil {
			_ = process.Kill()
		}
	}
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

func loginGnar(path, edge, account string, enrollmentKey []byte) error {
	ctx, cancel := context.WithTimeout(context.Background(), gnarLoginTimeout)
	defer cancel()
	command := exec.CommandContext(
		ctx,
		path,
		"login",
		"--edge", edge,
		"--account", account,
		"--enrollment-key-stdin",
		"--json",
	)
	command.Stdin = bytes.NewReader(enrollmentKey)
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
		return fmt.Errorf("%s: %w", redactGnarText(message, string(enrollmentKey)), err)
	}
	if message != "" && strings.HasPrefix(strings.ToLower(message), "error:") {
		return errors.New(redactGnarText(message, string(enrollmentKey)))
	}
	return nil
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

var sensitiveGnarPattern = regexp.MustCompile(`(?i)(enrollment[-_ ]?key|access[-_ ]?token|daemon[-_ ]?token|account[-_ ]?token)(\s*[:=]\s*["']?)[^\s,"'}]+`)
var sensitiveValuePattern = regexp.MustCompile(`(?i)((?:token|secret|credential|enrollment[-_ ]?key)(?:\s+is)?\s*[:=]\s*["']?)[A-Za-z0-9._~+/=-]{8,}`)
var sensitiveBareValuePattern = regexp.MustCompile(`(?i)((?:access[-_ ]?token|daemon[-_ ]?token|account[-_ ]?token|token|secret|credential|enrollment[-_ ]?key)\s+)[A-Za-z0-9._~+/=-]{12,}`)

func clearBytes(value []byte) {
	for index := range value {
		value[index] = 0
	}
}
