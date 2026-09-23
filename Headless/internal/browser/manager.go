package browser

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

// Manager owns every managed Chromium instance on this Host.
//
// It is deliberately independent of the PTY runtime machinery: a browser
// Session has no PTY, so reusing the terminal runtime would mean teaching a
// terminal engine about a component that does not have one.
type Manager struct {
	root string

	mu       sync.Mutex
	sessions map[string]*Session

	// onFrame, when set, receives every screencast frame together with the
	// Session it belongs to. The server uses it to wrap frames in the binary
	// browserFrame envelope; nil disables streaming to clients.
	onFrame func(sessionID string, sequence uint64, payload []byte)
	// onEnd, when set, runs when a Session's Chromium dies, so the server can
	// reconcile the durable Session record.
	onEnd func(sessionID string)
}

// NewManager creates a manager that stores per-Session Chromium profiles under
// root. An empty root disables profile persistence and is only for tests.
func NewManager(root string) *Manager {
	return &Manager{root: root, sessions: make(map[string]*Session)}
}

// SetFrameHandler installs the screencast sink. It is set once by the server
// before any Session starts.
func (m *Manager) SetFrameHandler(handler func(sessionID string, sequence uint64, payload []byte)) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.onFrame = handler
}

// frameHandler returns the installed screencast sink, or nil when streaming to
// clients is disabled.
func (m *Manager) frameHandler() func(sessionID string, sequence uint64, payload []byte) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.onFrame
}

// SetEndHandler installs the Session-end sink.
func (m *Manager) SetEndHandler(handler func(sessionID string)) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.onEnd = handler
}

// StartOptions describes a browser Session to create.
type StartOptions struct {
	SessionID       string
	WorkspaceID     string
	TerminalGroupID string
	Scope           string
	Headless        bool
	Viewport        api.BrowserViewport
}

// Start creates the runtime for one Warren Session and launches Chromium. It is
// synchronous: a caller that needs to know whether the browser actually came up
// waits here, which is what makes browser.create able to report failure instead
// of a Session that is permanently "starting".
func (m *Manager) Start(ctx context.Context, options StartOptions) (*Session, error) {
	if options.SessionID == "" {
		return nil, errors.New("browser: session id is required")
	}
	m.mu.Lock()
	if _, exists := m.sessions[options.SessionID]; exists {
		m.mu.Unlock()
		return nil, fmt.Errorf("browser session already running: %s", options.SessionID)
	}
	session := newSession(m, options.SessionID, options.WorkspaceID, options.TerminalGroupID, options.Scope, options.Headless, options.Viewport)
	m.sessions[options.SessionID] = session
	m.mu.Unlock()

	if err := session.Start(ctx); err != nil {
		m.remove(options.SessionID)
		return nil, err
	}
	return session, nil
}

// Session returns the running runtime for a Warren Session ID.
func (m *Manager) Session(id string) (*Session, bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	session, ok := m.sessions[id]
	return session, ok
}

// Sessions returns every running runtime, ordered by Session ID so a roster
// projection is stable across calls.
func (m *Manager) Sessions() []*Session {
	m.mu.Lock()
	defer m.mu.Unlock()
	sessions := make([]*Session, 0, len(m.sessions))
	for _, session := range m.sessions {
		sessions = append(sessions, session)
	}
	sortSessions(sessions)
	return sessions
}

func sortSessions(sessions []*Session) {
	for i := 1; i < len(sessions); i++ {
		for j := i; j > 0 && sessions[j].id < sessions[j-1].id; j-- {
			sessions[j], sessions[j-1] = sessions[j-1], sessions[j]
		}
	}
}

// remove drops a Session from the manager. It is called from Session.close, so
// it must not call back into close.
func (m *Manager) remove(id string) {
	m.mu.Lock()
	_, existed := m.sessions[id]
	delete(m.sessions, id)
	onEnd := m.onEnd
	m.mu.Unlock()
	if !existed {
		return
	}
	if onEnd != nil {
		onEnd(id)
	}
}

// Close ends every managed Chromium.
func (m *Manager) Close() {
	m.mu.Lock()
	sessions := make([]*Session, 0, len(m.sessions))
	for _, session := range m.sessions {
		sessions = append(sessions, session)
	}
	m.mu.Unlock()
	for _, session := range sessions {
		session.close()
	}
}

// userDataDir returns the per-Session Chromium profile directory, creating it
// on first use.
//
// The directory is per Session rather than shared, which is what makes browser
// Sessions scoped to different Workspaces unable to see each other's cookies or
// storage.
func (m *Manager) userDataDir(sessionID string) (string, error) {
	if m.root == "" {
		return "", errors.New("browser: profile root is not configured")
	}
	// Session IDs are generated hex; anything unexpected is still sanitized so a
	// crafted ID cannot escape the profile root.
	dir := filepath.Join(m.root, sanitizePathSegment(sessionID))
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", fmt.Errorf("create browser profile: %w", err)
	}
	return dir, nil
}

// RemoveProfile deletes a Session's profile directory. Called when a browser
// Session ends: a Session's cookies are Session state, not Host state.
func (m *Manager) RemoveProfile(sessionID string) error {
	if m.root == "" {
		return nil
	}
	dir := filepath.Join(m.root, sanitizePathSegment(sessionID))
	if err := os.RemoveAll(dir); err != nil {
		return fmt.Errorf("remove browser profile: %w", err)
	}
	return nil
}

func sanitizePathSegment(value string) string {
	replacer := strings.NewReplacer("/", "_", "\\", "_", "..", "__", string(os.PathSeparator), "_")
	return replacer.Replace(value)
}
