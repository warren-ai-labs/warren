package server

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"sort"
	"strings"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/output"
	"github.com/abcdlsj/warren/Headless/internal/store"
)

func (p *wsPeer) input(ctx context.Context, data []byte) error {
	attached, err := p.controlledSession()
	if err != nil {
		return err
	}
	if !p.server.Service.isFocused(p, attached.ID) {
		return fmt.Errorf("focused control lease required")
	}
	metadata, payload, err := output.DecodeInput(data)
	if err != nil {
		return fmt.Errorf("DENB input required: %w", err)
	}
	if metadata.Version != api.Version {
		return fmt.Errorf("input protocol version mismatch: got %s, want %s", metadata.Version, api.Version)
	}
	if metadata.SessionID != attached.ID {
		return fmt.Errorf("input session mismatch")
	}
	attachmentID := p.attachmentID(attached.ID)
	if attachmentID == "" || metadata.AttachmentID == "" || metadata.AttachmentID != attachmentID {
		return fmt.Errorf("input attachment mismatch")
	}
	if isACPSession(attached) {
		return errSessionHasNoTerminal
	}
	if err := p.server.Service.runtimeFor(attached).Input(ctx, attached.Runtime, payload); err != nil {
		return err
	}
	p.server.Service.noteDirectTerminalInput(attached.ID, payload)
	p.server.Service.PingOutput(attached.ID)
	return nil
}

// claimControl swaps the control lease without touching output
// subscriptions. The desktop keeps its per-surface subscriptions alive
// across tab switches; only input, focus, and resize ownership follow this
// pointer.
func (p *wsPeer) claimControl(session api.Session) {
	p.enqueueMu.Lock()
	previousSessionID := p.controlSession
	p.attached = &session
	p.controlSession = session.ID
	p.enqueueMu.Unlock()
	if p.server != nil && p.server.Service != nil {
		if previousSessionID != "" && previousSessionID != session.ID {
			p.server.Service.releaseControlPeer(p, previousSessionID)
		}
		p.server.Service.claimControlPeer(p, session.ID)
	}
}

// claimAgentControl records a control lease for an Agent-only peer without
// manufacturing a terminal attachment. Agent timelines are passive by
// default; this explicit marker is required before an interaction, goal, or
// interrupt mutation can reach the provider.
func (p *wsPeer) claimAgentControl(sessionID string) {
	p.enqueueMu.Lock()
	previousSessionID := p.controlSession
	p.controlSession = sessionID
	p.enqueueMu.Unlock()
	if previousSessionID != "" && previousSessionID != sessionID && p.server != nil && p.server.Service != nil {
		p.server.Service.releaseControlPeer(p, previousSessionID)
	}
}

func (p *wsPeer) subscribeCanonicalAgent(sessionID, streamID string) error {
	p.enqueueMu.Lock()
	if p.closeFlag {
		p.enqueueMu.Unlock()
		return errors.New("connection is closed")
	}
	// A Session holds one execution stream. Replacing it in place prevents
	// events from a retired execution from passing the peer filter after
	// `/new`, `/clear`, or a provider restart rebinds the Session to a new
	// execution ID. Without agent-streams-v1 the connection holds one stream
	// in total, so subscribing replaces every other Session's stream too.
	var replaced []string
	if !api.SupportsCapability(p.capabilities, api.CapabilityAgentStreams) {
		for previous := range p.agentStreams {
			if previous != sessionID {
				replaced = append(replaced, previous)
			}
		}
		p.agentStreams = nil
	}
	if p.agentStreams == nil {
		p.agentStreams = map[string]string{}
	}
	p.agentStreams[sessionID] = streamID
	p.enqueueMu.Unlock()
	for _, previous := range replaced {
		p.server.Service.detachAgentPeer(p, previous)
	}
	p.server.Service.registerAgentPeer(sessionID, p)
	p.enqueueMu.Lock()
	closed := p.closeFlag || p.agentStreams[sessionID] != streamID
	p.enqueueMu.Unlock()
	if closed {
		p.server.Service.detachAgentPeer(p, sessionID)
		return errors.New("connection closed while subscribing to agent")
	}
	return nil
}

// unsubscribeCanonicalAgent drops the Session that holds streamID, if this
// connection holds it. It reports whether a stream was dropped.
func (p *wsPeer) unsubscribeCanonicalAgent(streamID string) bool {
	p.enqueueMu.Lock()
	sessionID := ""
	for candidate, held := range p.agentStreams {
		if held == streamID {
			sessionID = candidate
			break
		}
	}
	if sessionID != "" {
		delete(p.agentStreams, sessionID)
	}
	p.enqueueMu.Unlock()
	if sessionID == "" {
		return false
	}
	p.server.Service.detachAgentPeer(p, sessionID)
	return true
}

func (p *wsPeer) hasCanonicalAgentStream(streamID string) bool {
	p.enqueueMu.Lock()
	defer p.enqueueMu.Unlock()
	for _, held := range p.agentStreams {
		if held == streamID {
			return true
		}
	}
	return false
}

func (p *wsPeer) detach() {
	p.enqueueMu.Lock()
	attached := p.attached
	controlSessionID := p.controlSession
	p.attached = nil
	p.controlSession = ""
	p.enqueueMu.Unlock()
	if attached != nil {
		p.server.Service.detachPeer(p, attached.ID)
	}
	if controlSessionID != "" && p.server != nil && p.server.Service != nil {
		// Agent-only focus has no attached terminal session, so detachPeer cannot
		// release its mutation lease. The service-side identity check makes this
		// safe when the attached path already removed the same lease.
		p.server.Service.releaseControlPeer(p, controlSessionID)
	}
}

// detachIfAttached releases the control lease only when it still belongs to
// the requested session. Slow lifecycle mutations run concurrently with
// attach/focus requests, so a separate check followed by detach could remove
// a newer session's lease.
func (p *wsPeer) detachIfAttached(sessionID string) {
	p.enqueueMu.Lock()
	attachedID := ""
	if p.attached != nil {
		attachedID = p.attached.ID
	}
	if attachedID != sessionID && p.controlSession != sessionID {
		p.enqueueMu.Unlock()
		return
	}
	if attachedID == sessionID {
		p.attached = nil
	}
	if p.controlSession == sessionID {
		p.controlSession = ""
	}
	p.enqueueMu.Unlock()
	if attachedID == sessionID {
		p.server.Service.detachPeer(p, sessionID)
	}
	if p.server != nil && p.server.Service != nil {
		p.server.Service.releaseControlPeer(p, sessionID)
	}
}

func (p *wsPeer) attachedSession() (api.Session, bool) {
	p.enqueueMu.Lock()
	defer p.enqueueMu.Unlock()
	if p.attached == nil {
		return api.Session{}, false
	}
	return *p.attached, true
}

func (p *wsPeer) attachedSessionID() string {
	session, ok := p.attachedSession()
	if !ok {
		return ""
	}
	return session.ID
}

func (p *wsPeer) controlledSession() (api.Session, error) {
	p.enqueueMu.Lock()
	if p.attached == nil {
		p.enqueueMu.Unlock()
		return api.Session{}, fmt.Errorf("no attached session")
	}
	if p.controlSession != p.attached.ID {
		p.enqueueMu.Unlock()
		return api.Session{}, fmt.Errorf("control lease required")
	}
	attached := *p.attached
	p.enqueueMu.Unlock()
	if p.server != nil && p.server.Service != nil && !p.server.Service.hasControlPeer(p, attached.ID) {
		return api.Session{}, fmt.Errorf("control lease required")
	}
	return attached, nil
}

// requireAgentControl keeps all mutating Agent View requests behind the same
// per-session control lease as terminal input and resize. Agent subscriptions
// are intentionally passive, so merely seeing a transcript must never grant a
// client the ability to answer an interaction or submit a message.
func (p *wsPeer) requireAgentControl(sessionID string) error {
	sessionID = strings.TrimSpace(sessionID)
	if sessionID == "" {
		// Let the Service return its canonical validation error for malformed
		// requests; no provider call can be made without a session identity.
		return nil
	}
	p.enqueueMu.Lock()
	localSession := p.controlSession
	p.enqueueMu.Unlock()
	if localSession != sessionID {
		return fmt.Errorf("control lease required for session: %s", sessionID)
	}
	// A focus/control handoff can replace the service-level owner while the
	// previous peer still has its local pointer. Consult the authoritative owner
	// map so a stale socket cannot mutate Agent state after the lease moved to
	// another client. Agent-only claims do not need a terminal output
	// subscription and therefore are not represented by the focused-peer map.
	if p.server != nil && p.server.Service != nil && !p.server.Service.hasControlPeer(p, sessionID) {
		return fmt.Errorf("control lease required for session: %s", sessionID)
	}
	return nil
}

func (p *wsPeer) addOutput(sessionID string) {
	p.enqueueMu.Lock()
	if p.outputs == nil {
		p.outputs = map[string]struct{}{}
	}
	p.outputs[sessionID] = struct{}{}
	p.enqueueMu.Unlock()
}

// ensureAttachment returns the stable identity for the current output
// subscription. It is generated only after authentication and never persisted.
func (p *wsPeer) ensureAttachment(sessionID string) string {
	p.enqueueMu.Lock()
	defer p.enqueueMu.Unlock()
	if p.attachments == nil {
		p.attachments = make(map[string]string)
	}
	if value := p.attachments[sessionID]; value != "" {
		return value
	}
	value := store.NewID()
	p.attachments[sessionID] = value
	return value
}

func (p *wsPeer) attachmentID(sessionID string) string {
	p.enqueueMu.Lock()
	defer p.enqueueMu.Unlock()
	return p.attachments[sessionID]
}

func (p *wsPeer) removeOutput(sessionID string) {
	p.enqueueMu.Lock()
	delete(p.outputs, sessionID)
	delete(p.attachments, sessionID)
	p.enqueueMu.Unlock()
}

func (p *wsPeer) hasOutput(sessionID string) bool {
	p.enqueueMu.Lock()
	defer p.enqueueMu.Unlock()
	_, ok := p.outputs[sessionID]
	return ok
}

// isClosed reports peer teardown without taking enqueueMu, so callers holding
// another lock can check it safely.
func (p *wsPeer) isClosed() bool {
	select {
	case <-p.closed:
		return true
	default:
		return false
	}
}

func (p *wsPeer) setScreenSessions(sessions []string) error {
	seen := make(map[string]struct{}, len(sessions))
	validated := make([]string, 0, len(sessions))
	for _, raw := range sessions {
		id := strings.TrimSpace(raw)
		if id == "" {
			continue
		}
		if _, duplicate := seen[id]; duplicate {
			continue
		}
		session, ok := p.server.Service.Session(id)
		if !ok {
			return fmt.Errorf("screen session not found: %s", id)
		}
		if session.Lifecycle != "running" {
			return fmt.Errorf("screen session is not running: %s", id)
		}
		seen[id] = struct{}{}
		validated = append(validated, id)
	}
	p.screenMu.Lock()
	defer p.screenMu.Unlock()
	if p.isClosed() {
		return errors.New("connection is closed")
	}
	p.screenSessions = validated
	p.screenGeneration++
	p.screenReportedAt = time.Now()
	return nil
}

// screenSessionsSnapshot removes ended Sessions lazily so a peer that remains
// connected cannot report stale panes after a Host-side deletion.
//
// Session lookup takes the service lock, so it happens outside screenMu. The
// generation counter makes the write-back safe: a concurrent screen.report
// bumps the generation and its list wins over this stale filtered copy.
func (p *wsPeer) screenSessionsSnapshot() []string {
	p.screenMu.Lock()
	ids := append([]string(nil), p.screenSessions...)
	generation := p.screenGeneration
	p.screenMu.Unlock()
	valid := make([]string, 0, len(ids))
	for _, id := range ids {
		if session, ok := p.server.Service.Session(id); ok && session.Lifecycle == "running" {
			valid = append(valid, id)
		}
	}
	p.screenMu.Lock()
	if p.screenGeneration == generation && !p.isClosed() {
		p.screenSessions = append([]string(nil), valid...)
	} else {
		valid = append([]string(nil), p.screenSessions...)
	}
	p.screenMu.Unlock()
	return valid
}

// screenLayouts returns every connected client screen that currently displays
// the Session, ordered most recently reported first.
//
// The read deliberately crosses peers. Screen state is owned by the client that
// reported it, but the question "which pane am I" comes from a CLI running
// inside the Session, on its own short-lived connection with no screen of its
// own; answering from the asking peer would always say "nowhere". Writes stay
// per-peer, so one window still cannot overwrite another's layout.
func (s *HTTPServer) screenLayouts(sessionID string) []api.ScreenLayout {
	sessionID = strings.TrimSpace(sessionID)
	if sessionID == "" {
		return nil
	}
	s.peersMu.Lock()
	peers := make([]*wsPeer, 0, len(s.peers))
	for peer := range s.peers {
		peers = append(peers, peer)
	}
	s.peersMu.Unlock()
	type reportedScreen struct {
		sessions   []string
		reportedAt time.Time
		clientID   string
	}
	reported := make([]reportedScreen, 0, len(peers))
	for _, peer := range peers {
		// Snapshotting takes the service lock, so it runs outside peersMu.
		sessions := peer.screenSessionsSnapshot()
		if !slices.Contains(sessions, sessionID) {
			continue
		}
		peer.screenMu.Lock()
		reportedAt := peer.screenReportedAt
		peer.screenMu.Unlock()
		reported = append(reported, reportedScreen{
			sessions:   sessions,
			reportedAt: reportedAt,
			clientID:   peer.clientID,
		})
	}
	// The client ID breaks ties so two windows that reported in the same clock
	// tick still produce a stable order across calls.
	sort.Slice(reported, func(first, second int) bool {
		if !reported[first].reportedAt.Equal(reported[second].reportedAt) {
			return reported[first].reportedAt.After(reported[second].reportedAt)
		}
		return reported[first].clientID < reported[second].clientID
	})
	layouts := make([]api.ScreenLayout, 0, len(reported))
	for _, screen := range reported {
		panes := make([]api.ScreenPane, 0, len(screen.sessions))
		position := 0
		for index, id := range screen.sessions {
			pane := api.ScreenPane{
				Index:     index + 1,
				SessionID: id,
				Current:   id == sessionID,
			}
			if session, ok := s.Service.Session(id); ok {
				if title := strings.TrimSpace(session.CustomTitle); title != "" {
					pane.Title = title
				} else {
					pane.Title = session.Title
				}
			}
			if pane.Current {
				position = pane.Index
			}
			panes = append(panes, pane)
		}
		layouts = append(layouts, api.ScreenLayout{
			Position:  position,
			PaneCount: len(panes),
			Panes:     panes,
		})
	}
	return layouts
}

// releaseControl keeps the output subscription alive while dropping the
// control lease. A later explicit session.focus can promote the same target
// again without replaying the terminal state.
func (p *wsPeer) releaseControl(sessionID string) {
	if p.server != nil && p.server.Service != nil {
		p.server.Service.releaseControlPeer(p, sessionID)
	}
	p.enqueueMu.Lock()
	if p.controlSession == sessionID {
		p.controlSession = ""
	}
	p.enqueueMu.Unlock()
}
