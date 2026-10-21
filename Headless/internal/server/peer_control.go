package server

import (
	"context"
	"time"

	"github.com/abcdlsj/ghostline"
	"github.com/abcdlsj/warren/Headless/internal/api"
)

func (s *Service) detachPeer(peer *wsPeer, sessionID string) {
	s.lazyInit()
	s.stopPeerCursorOutput(peer, sessionID, false)
	peer.removeOutput(sessionID)
	s.outputMu.Lock()
	if peers := s.peers[sessionID]; peers != nil {
		delete(peers, peer)
		if len(peers) == 0 {
			delete(s.peers, sessionID)
		}
	}
	if s.focusedPeers[sessionID] == peer {
		delete(s.focusedPeers, sessionID)
	}
	if s.controlPeers[sessionID] == peer {
		delete(s.controlPeers, sessionID)
	}
	if s.resizePeers[sessionID] == peer {
		delete(s.resizePeers, sessionID)
	}
	s.outputMu.Unlock()
}

func (s *Service) registerAgentPeer(sessionID string, peer *wsPeer) {
	s.lazyInit()
	s.outputMu.Lock()
	defer s.outputMu.Unlock()
	if s.agentPeers[sessionID] == nil {
		s.agentPeers[sessionID] = map[*wsPeer]struct{}{}
	}
	s.agentPeers[sessionID][peer] = struct{}{}
}

func (s *Service) detachAgentPeer(peer *wsPeer, sessionID string) {
	s.lazyInit()
	s.outputMu.Lock()
	if peers := s.agentPeers[sessionID]; peers != nil {
		delete(peers, peer)
		if len(peers) == 0 {
			delete(s.agentPeers, sessionID)
		}
	}
	// Agent subscriptions are passive, but an Agent-only action may have
	// promoted this peer to the per-session mutation lease. A disconnect (or a
	// rapid stream switch) must release that lease or every later client will
	// observe a permanently occupied owner. Preserve the lease when this same
	// peer still owns terminal focus; in that case the terminal subscription is
	// the live owner and should continue to gate input/resize.
	if s.controlPeers[sessionID] == peer && s.focusedPeers[sessionID] != peer {
		delete(s.controlPeers, sessionID)
	}
	s.outputMu.Unlock()
}

func (s *Service) hasAgentPeers(sessionID string) bool {
	s.lazyInit()
	s.outputMu.Lock()
	defer s.outputMu.Unlock()
	return len(s.agentPeers[sessionID]) > 0
}

// registerPeer records a live output subscription. It is intentionally kept
// separate from attachOutputLocked so an attach can claim focus and resize
// the runtime before the first snapshot is captured. A peer may hold
// subscriptions for several sessions at once; the desktop keeps one per
// retained warm surface.
func (s *Service) registerPeer(sessionID string, peer *wsPeer) {
	s.lazyInit()
	peer.addOutput(sessionID)
	s.outputMu.Lock()
	if s.peers[sessionID] == nil {
		s.peers[sessionID] = map[*wsPeer]struct{}{}
	}
	s.peers[sessionID][peer] = struct{}{}
	s.outputMu.Unlock()
}

// focusPeerLocked updates focus ownership and optionally resizes the shared
// runtime. The caller must hold the session broadcast lock. Keeping both
// operations under that lock prevents an old endpoint's resize from racing a
// focus handoff.
func (s *Service) focusPeerLocked(
	ctx context.Context,
	peer *wsPeer,
	session api.Session,
	focused bool,
	columns, rows int,
	resizeSpecified bool,
	deferResize bool,
) (resized bool, err error) {
	s.lazyInit()
	s.outputMu.Lock()
	_, registered := s.peers[session.ID][peer]
	owner := s.focusedPeers[session.ID]
	s.outputMu.Unlock()
	if !registered {
		return false, nil
	}
	if !focused {
		s.outputMu.Lock()
		if owner == peer {
			if s.focusedPeers[session.ID] == peer {
				delete(s.focusedPeers, session.ID)
			}
			if s.controlPeers[session.ID] == peer {
				delete(s.controlPeers, session.ID)
			}
		}
		// A pane may have adopted the viewport owner without ever taking
		// keyboard focus, so release that adoption on blur as well.
		if s.resizePeers[session.ID] == peer {
			delete(s.resizePeers, session.ID)
		}
		s.outputMu.Unlock()
		return false, nil
	}
	if resizeSpecified && !deferResize {
		resized, err = s.resizeRuntime(ctx, session, columns, rows)
		if err != nil {
			return false, err
		}
	}
	s.outputMu.Lock()
	// A peer can disconnect while Runtime.Resize is in flight. Do not hand
	// focus back to a socket that has already been removed from the roster.
	if _, stillRegistered := s.peers[session.ID][peer]; !stillRegistered {
		s.outputMu.Unlock()
		return false, nil
	}
	s.focusedPeers[session.ID] = peer
	s.controlPeers[session.ID] = peer
	// Focus owns the viewport, so the keyboard target is also the pane whose
	// size the shared runtime follows while it stays focused.
	s.resizePeers[session.ID] = peer
	s.outputMu.Unlock()
	if resizeSpecified && deferResize {
		// The lease is already granted, so the focus reply never waits on a
		// slow PTY resize; the queued worker applies the size afterwards.
		size := ghostline.Size{Columns: columns, Rows: rows}
		if current, known := s.runtimeSizeFor(session.ID); !known || current != size {
			s.enqueueResize(session, size)
			resized = true
		}
	}
	return resized, nil
}

// resizeFocusedLocked arbitrates the shared runtime size independently of the
// input lease.
//
// A split window shows several Sessions at once, so a pane that is not the
// keyboard target still has to follow its own viewport. The peer that last
// resized owns the size (matching tmux's "latest active client" default); any
// output subscriber may adopt an unowned size. Taking the size never grants
// keyboard input or control, so resizing a passive pane can never mute another
// client that is actively typing into the same Session. A non-owner receives a
// successful no-op so stale browser resize callbacks do not surface as terminal
// errors.
func (s *Service) resizeFocusedLocked(
	ctx context.Context,
	peer *wsPeer,
	session api.Session,
	columns, rows int,
) (bool, error) {
	s.lazyInit()
	size := ghostline.Size{Columns: columns, Rows: rows}
	s.outputMu.Lock()
	owner := s.resizePeers[session.ID]
	_, registered := s.peers[session.ID][peer]
	current, known := s.runtimeSizes[session.ID]
	if !registered || (owner != nil && owner != peer) {
		s.outputMu.Unlock()
		return false, nil
	}
	if known && current == size {
		// Do not adopt an unowned size for a same-size request; a no-op must
		// not hand viewport ownership to a random subscriber.
		s.outputMu.Unlock()
		return false, nil
	}
	if s.resizePeers[session.ID] == nil {
		s.resizePeers[session.ID] = peer
	}
	s.outputMu.Unlock()
	// Runtime.Resize can block for seconds on a remote host. Queue it instead
	// of running it on the WebSocket reader, where it would delay the next
	// session.subscribe and leave that terminal black.
	s.enqueueResize(session, size)
	return true, nil
}

// focusPeer grants or releases the control lease. It never waits on the
// session's broadcast lock: the resize it carries is queued to the per-session
// worker, which takes that lock when it applies it. Keeping this off the lock is
// what stops a slow PTY resize from delaying the focus reply or the next
// command on the WebSocket reader.
func (s *Service) focusPeer(
	ctx context.Context,
	peer *wsPeer,
	session api.Session,
	focused bool,
	columns, rows int,
	resizeSpecified bool,
	deferResize bool,
) (bool, bool, error) {
	resized, err := s.focusPeerLocked(ctx, peer, session, focused, columns, rows, resizeSpecified, deferResize)
	if err != nil {
		return false, false, err
	}
	return s.isFocused(peer, session.ID), resized, nil
}

// resizeFocused queues a viewport-only resize. It does not take the broadcast
// lock: the worker applies the size, and the reader stays free.
func (s *Service) resizeFocused(
	ctx context.Context,
	peer *wsPeer,
	session api.Session,
	columns, rows int,
) (bool, error) {
	return s.resizeFocusedLocked(ctx, peer, session, columns, rows)
}

func (s *Service) isFocused(peer *wsPeer, sessionID string) bool {
	s.outputMu.Lock()
	defer s.outputMu.Unlock()
	return s.focusedPeers[sessionID] == peer
}

// claimControlPeer transfers the mutation lease without requiring a terminal
// output subscription. This is used by Agent-only Stop/interaction actions;
// terminal focus still remains separately gated by the output roster.
func (s *Service) claimControlPeer(peer *wsPeer, sessionID string) bool {
	s.lazyInit()
	s.outputMu.Lock()
	s.controlPeers[sessionID] = peer
	s.outputMu.Unlock()
	return true
}

// claimAgentControlPeer acknowledges an Agent-only focus request.
// Agent View operations operate through structured, idempotent RPCs and do not
// contend with or require the single-tenant Terminal PTY control lease.
func (s *Service) claimAgentControlPeer(peer *wsPeer, sessionID string) bool {
	return true
}

func (s *Service) releaseControlPeer(peer *wsPeer, sessionID string) {
	s.lazyInit()
	s.outputMu.Lock()
	if s.controlPeers[sessionID] == peer {
		delete(s.controlPeers, sessionID)
	}
	s.outputMu.Unlock()
}

func (s *Service) hasControlPeer(peer *wsPeer, sessionID string) bool {
	s.outputMu.Lock()
	defer s.outputMu.Unlock()
	return s.controlPeers[sessionID] == peer
}

func (s *Service) hasFocusedPeer(sessionID string) bool {
	s.outputMu.Lock()
	defer s.outputMu.Unlock()
	return s.focusedPeers[sessionID] != nil
}

func (s *Service) stopOutput(sessionID string, notify bool) {
	s.lazyInit()
	s.stopAgent(sessionID)
	s.outputMu.Lock()
	outputSession := s.outputs[sessionID]
	delete(s.outputs, sessionID)
	uniquePeers := make(map[*wsPeer]struct{}, len(s.peers[sessionID])+len(s.agentPeers[sessionID]))
	for peer := range s.peers[sessionID] {
		uniquePeers[peer] = struct{}{}
	}
	for peer := range s.agentPeers[sessionID] {
		uniquePeers[peer] = struct{}{}
	}
	peers := make([]*wsPeer, 0, len(uniquePeers))
	for peer := range uniquePeers {
		peers = append(peers, peer)
	}
	delete(s.peers, sessionID)
	delete(s.agentPeers, sessionID)
	delete(s.focusedPeers, sessionID)
	delete(s.controlPeers, sessionID)
	delete(s.resizePeers, sessionID)
	delete(s.runtimeSizes, sessionID)
	s.outputMu.Unlock()
	for _, peer := range peers {
		s.stopPeerCursorOutput(peer, sessionID, false)
	}
	s.stopCursorOutput(outputSession)
	if notify {
		for _, peer := range peers {
			_ = peer.enqueueExited(sessionID)
		}
	}
}

func (s *Service) markEnded(sessionID string) {
	now := time.Now().UTC()
	changed := false
	_ = s.Store.Update(func(value *api.State) error {
		for index := range value.Sessions {
			if value.Sessions[index].ID == sessionID && value.Sessions[index].Lifecycle == "running" {
				value.Sessions[index].Lifecycle = "ended"
				value.Sessions[index].EndedAt = &now
				changed = true
			}
		}
		// The arrangement loses the pane of the Session that just ended.
		if reconcilePaneGroups(value) {
			changed = true
		}
		return nil
	})
	if changed {
		s.stopOutput(sessionID, true)
		s.wakeLiveActivity()
	}
}
