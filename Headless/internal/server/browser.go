package server

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/browser"
	"github.com/abcdlsj/warren/Headless/internal/output"
	"github.com/abcdlsj/warren/Headless/internal/store"
)

// sessionKindBrowser is the Session kind of a Warren Browser.
//
// It doubles as the RuntimeKind. That is deliberate: reconcile treats any
// session whose RuntimeKind is not Ghostline as "preserve, do not probe", which
// is exactly right for a browser — a Chromium is not a Ghostline runtime and
// asking Ghostline whether one exists would be meaningless.
const sessionKindBrowser = "browser"

// browserDefaultTitle is the generated label for an unnamed browser Session. A
// caller-supplied title equal to it is not treated as a user rename, matching
// how terminal kinds behave.
const browserDefaultTitle = "Browser"

// browserNavigateTimeout bounds the optional opening navigation performed
// during create. It is separate from the per-action timeout because create has
// to answer, not stream.
const browserNavigateTimeout = 30 * time.Second

// BrowserCreateOptions describes a browser Session to create.
type BrowserCreateOptions struct {
	WorkspaceID     string
	TerminalGroupID string
	// Title is the user-facing name. Empty uses the generated default.
	Title string
	// URL is opened once Chromium is up. Empty leaves the browser on a blank
	// tab, which is what an agent that navigates itself wants.
	URL string
	// Headless runs Chromium with no window of its own, which is the default: a
	// browser Session is drawn from its screencast inside Warren, and a separate
	// window would render the page where Warren cannot show it.
	Headless bool
	Viewport api.BrowserViewport
}

// browserHeadlessFromParams decides whether a create request runs Chromium with
// no window of its own.
//
// The default is no window. A browser Session is drawn inside Warren from the
// frame stream it publishes, so a Chromium window would put the page somewhere
// Warren does not render and leave the Session's own viewer showing a second
// copy of it. `window` is the opt-in, kept for debugging the browser runtime
// itself, which is the one case where seeing Chrome's own chrome helps.
func browserHeadlessFromParams(params map[string]any) (bool, error) {
	window, _, err := optionalBoolParam(params, "window")
	if err != nil {
		return false, err
	}
	return !window, nil
}

// browserManager returns the Host's Chromium manager, creating it on first use.
//
// The manager is created lazily because a browser Session has no PTY runtime
// and therefore cannot join Runtimes, and because a Host that never opens a
// browser should never need a writable profile directory.
func (s *Service) browserManager() *browser.Manager {
	s.browserMu.Lock()
	defer s.browserMu.Unlock()
	if s.browsers == nil {
		manager := browser.NewManager(s.browserProfileRoot())
		manager.SetFrameHandler(s.publishBrowserFrame)
		manager.SetEndHandler(s.endBrowserSession)
		s.browsers = manager
	}
	return s.browsers
}

// browserManagerIfPresent returns the manager without creating it. Read paths
// use it so listing browsers on a Host that has none allocates nothing.
func (s *Service) browserManagerIfPresent() *browser.Manager {
	s.browserMu.Lock()
	defer s.browserMu.Unlock()
	return s.browsers
}

// browserProfileRoot is the parent of every per-Session Chromium profile.
//
// It is derived from the settings file's directory so a daemon started with an
// explicit config directory keeps browser profiles beside the rest of its state
// instead of scattering them in the invoking user's home.
func (s *Service) browserProfileRoot() string {
	if dir := strings.TrimSpace(s.SettingsPath); dir != "" {
		return filepath.Join(filepath.Dir(dir), "browsers")
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".warren", "browsers")
}

// CreateBrowserSession launches Chromium and records the durable Session.
//
// The Chromium is started before the record is written, and the record is
// written before the optional opening navigation, so a failure at any step
// leaves nothing behind: no record for a browser that died, and no browser for a
// record that was rolled back.
func (s *Service) CreateBrowserSession(ctx context.Context, options BrowserCreateOptions) (api.Session, error) {
	if options.WorkspaceID == "" && options.TerminalGroupID == "" {
		return api.Session{}, errors.New("workspace or terminal group is required")
	}
	if options.WorkspaceID != "" && options.TerminalGroupID != "" {
		return api.Session{}, errors.New("workspace and terminal group are mutually exclusive")
	}
	if err := s.checkBrowserScope(options.WorkspaceID, options.TerminalGroupID); err != nil {
		return api.Session{}, err
	}

	id := store.NewID()
	scope := api.SessionScopeTerminalGroup
	if options.WorkspaceID != "" {
		scope = api.SessionScopeWorkspace
	}
	title := strings.TrimSpace(options.Title)
	customTitle := ""
	if title != "" && title != browserDefaultTitle {
		customTitle = title
	}
	session := api.Session{
		ID:              id,
		WorkspaceID:     options.WorkspaceID,
		TerminalGroupID: options.TerminalGroupID,
		Scope:           scope,
		Title:           browserDefaultTitle,
		CustomTitle:     customTitle,
		Kind:            sessionKindBrowser,
		RuntimeKind:     sessionKindBrowser,
		Lifecycle:       "running",
		CreatedAt:       time.Now().UTC(),
	}

	chromium, err := s.browserManager().Start(ctx, browser.StartOptions{
		SessionID:       id,
		WorkspaceID:     options.WorkspaceID,
		TerminalGroupID: options.TerminalGroupID,
		Scope:           scope,
		Headless:        options.Headless,
		Viewport:        options.Viewport,
	})
	if err != nil {
		return api.Session{}, err
	}
	if err := s.Store.Update(func(value *api.State) error {
		value.Sessions = append(value.Sessions, session)
		return nil
	}); err != nil {
		chromium.Close()
		_ = s.browserManager().RemoveProfile(id)
		return api.Session{}, err
	}
	if url := strings.TrimSpace(options.URL); url != "" {
		navigateContext, cancel := context.WithTimeout(ctx, browserNavigateTimeout)
		_, navigateErr := chromium.Perform(navigateContext, api.BrowserAction{Action: api.BrowserActionNavigate, URL: url})
		cancel()
		if navigateErr != nil {
			// The browser is live and usable, so the Session stays. The caller
			// is told the opening navigation failed rather than being handed a
			// browser that silently sits on a blank tab.
			s.logWarn("browser opening navigation failed", "session", id, "url", url, "error", navigateErr)
		}
	}
	s.wakeLiveActivity()
	return session, nil
}

// checkBrowserScope confirms the named owner still exists.
func (s *Service) checkBrowserScope(workspaceID, groupID string) error {
	state := s.Store.Snapshot()
	if workspaceID != "" {
		for _, workspace := range state.Workspaces {
			if workspace.ID == workspaceID {
				return nil
			}
		}
		return fmt.Errorf("workspace not found: %s", workspaceID)
	}
	for _, group := range state.TerminalGroups {
		if group.ID == groupID {
			return nil
		}
	}
	return fmt.Errorf("terminal group not found: %s", groupID)
}

// BrowserSessions projects every running browser Session in one scope. Both
// filters empty means every browser Session on this Host.
func (s *Service) BrowserSessions(workspaceID, groupID string) []api.BrowserSession {
	manager := s.browserManagerIfPresent()
	projections := make([]api.BrowserSession, 0, 4)
	for _, session := range s.Store.Snapshot().Sessions {
		if session.Kind != sessionKindBrowser || session.Lifecycle != "running" {
			continue
		}
		if workspaceID != "" && session.WorkspaceID != workspaceID {
			continue
		}
		if groupID != "" && session.TerminalGroupID != groupID {
			continue
		}
		projections = append(projections, browserProjection(manager, session))
	}
	return projections
}

// BrowserSession projects one browser Session, or reports that it is not a
// running browser on this Host.
func (s *Service) BrowserSession(id string) (api.BrowserSession, error) {
	session, ok := s.Session(id)
	if !ok || session.Kind != sessionKindBrowser {
		return api.BrowserSession{}, fmt.Errorf("browser session not found: %s", id)
	}
	return browserProjection(s.browserManagerIfPresent(), session), nil
}

// browserProjection overlays the live Chromium state on the durable record.
//
// The record is the identity; the runtime is the truth about the page. When the
// runtime is gone — a daemon restart, or a Chromium that died without its end
// handler running — the projection says so instead of reporting a stale URL.
func browserProjection(manager *browser.Manager, session api.Session) api.BrowserSession {
	title := session.CustomTitle
	if title == "" {
		title = session.Title
	}
	projection := api.BrowserSession{
		ID:              session.ID,
		WorkspaceID:     session.WorkspaceID,
		TerminalGroupID: session.TerminalGroupID,
		Scope:           session.Scope,
		Title:           title,
		Phase:           browser.PhaseUnavailable,
		Error:           "the browser is not running on this Host",
	}
	if manager == nil {
		return projection
	}
	chromium, ok := manager.Session(session.ID)
	if !ok {
		return projection
	}
	projection = chromium.Projection()
	projection.Title = title
	return projection
}

// PerformBrowserAction runs one normalized action against a browser Session.
func (s *Service) PerformBrowserAction(ctx context.Context, id string, action api.BrowserAction) (api.BrowserActionResult, error) {
	session, ok := s.Session(id)
	if !ok || session.Kind != sessionKindBrowser {
		return api.BrowserActionResult{}, fmt.Errorf("browser session not found: %s", id)
	}
	manager := s.browserManagerIfPresent()
	if manager == nil {
		return api.BrowserActionResult{}, fmt.Errorf("browser session is not running: %s", id)
	}
	chromium, ok := manager.Session(id)
	if !ok {
		return api.BrowserActionResult{}, fmt.Errorf("browser session is not running: %s", id)
	}
	return chromium.Perform(ctx, action)
}

// CloseBrowserSession ends the Chromium, deletes its profile, and drops the
// durable record. A profile is Session state, not Host state: it holds the
// cookies and storage of whatever the Session browsed.
// refreshBrowserFrame renders one frame for a browser Session.
//
// Called when a peer subscribes. A settled page paints on its own only when
// something changes it, so without this the first viewer of an idle page is
// handed a stream that never sends anything.
func (s *Service) refreshBrowserFrame(id string) {
	manager := s.browserManagerIfPresent()
	if manager == nil {
		return
	}
	chromium, running := manager.Session(id)
	if !running {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_ = chromium.Refresh(ctx)
}

func (s *Service) CloseBrowserSession(ctx context.Context, id string) error {
	session, ok := s.Session(id)
	if !ok || session.Kind != sessionKindBrowser {
		return nil
	}
	s.stopOutput(id, true)
	if manager := s.browserManagerIfPresent(); manager != nil {
		if chromium, running := manager.Session(id); running {
			chromium.Close()
		}
		_ = manager.RemoveProfile(id)
	}
	err := s.Store.Update(func(value *api.State) error {
		value.Sessions = filter(value.Sessions, func(item api.Session) bool { return item.ID != id })
		reconcilePaneGroups(value)
		return nil
	})
	if err == nil {
		s.wakeLiveActivity()
	}
	return err
}

// publishBrowserFrame hands one screencast frame to every peer subscribed to
// that browser Session.
//
// Frames go out as DENB browserFrame envelopes, never as terminal output, so no
// client can route them into a VT parser.
func (s *Service) publishBrowserFrame(sessionID string, sequence uint64, payload []byte) {
	s.lazyInit()
	s.outputMu.Lock()
	peers := make([]*wsPeer, 0, len(s.peers[sessionID]))
	for peer := range s.peers[sessionID] {
		peers = append(peers, peer)
	}
	s.outputMu.Unlock()
	if len(peers) == 0 {
		return
	}
	encoded, err := output.EncodeBrowserFrame(sessionID, 0, sequence, payload)
	if err != nil {
		s.logWarn("encode browser frame", "session", sessionID, "error", err)
		return
	}
	for _, peer := range peers {
		peer.enqueueDroppableBinary(encoded)
	}
}

// endBrowserSession runs when a Chromium dies on its own. The durable record is
// marked ended so the roster stops offering a browser that is gone, and the
// profile is removed because the Session that owned it is over.
//
// reconcile covers the other direction — a record whose Chromium did not survive
// the daemon — so a browser Session can never sit in the roster as running while
// no Chromium backs it.
func (s *Service) endBrowserSession(sessionID string) {
	s.markEnded(sessionID)
	if manager := s.browserManagerIfPresent(); manager != nil {
		_ = manager.RemoveProfile(sessionID)
	}
}

// subscribeBrowser registers one peer for a browser Session's frame stream.
//
// It is a separate path from session.subscribe because a browser Session has no
// PTY: there is no attach, no resize, no recovery anchor, and no output ring to
// replay. Registering the peer for frame delivery is the whole subscription.
func (p *wsPeer) subscribeBrowser(commandID, sessionID string) error {
	session, ok := p.server.Service.Session(sessionID)
	if !ok || session.Kind != sessionKindBrowser {
		return p.writeCanonicalError(commandID, fmt.Errorf("browser session not found: %s", sessionID))
	}
	p.server.Service.registerPeer(session.ID, p)
	// A settled page will not paint again on its own, so the subscribing viewer
	// would receive nothing until something changed the page.
	p.server.Service.refreshBrowserFrame(session.ID)
	return p.writeResult(commandID, map[string]any{
		"subscribed":   true,
		"attachmentId": p.ensureAttachment(session.ID),
	})
}

// decodeParam re-encodes one request parameter into a typed value.
//
// The RPC layer carries params as map[string]any because the command envelope is
// generic. A method with a structured parameter needs its own shape back, and
// going through JSON is what guarantees the field names and types match the
// protocol schema instead of drifting per call site.
func decodeParam(values map[string]any, key string, target any) error {
	raw, ok := values[key]
	if !ok || raw == nil {
		return nil
	}
	encoded, err := json.Marshal(raw)
	if err != nil {
		return fmt.Errorf("encode %s: %w", key, err)
	}
	if err := json.Unmarshal(encoded, target); err != nil {
		return fmt.Errorf("decode %s: %w", key, err)
	}
	return nil
}
