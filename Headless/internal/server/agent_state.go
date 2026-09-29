package server

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"strings"

	"github.com/abcdlsj/warren/Headless/internal/agent"
	"github.com/abcdlsj/warren/Headless/internal/api"
)

// pendingAgentTurnRequest records a Host-originated request whose transport
// has been accepted but whose Provider terminal observation has not arrived.
// It is deliberately ephemeral: the provider transcript remains the source
// of truth for ending the turn, while this record only lets the Host preserve
// the distinction between a direct TUI interruption and a Host cancel.
type pendingAgentTurnRequest struct {
	turn      uint64
	commandID string
	reason    string
}

func (s *Service) agentStatus(sessionID string) api.AgentStatus {
	s.lazyInit()
	s.agentsMu.Lock()
	entry := s.agents[sessionID]
	s.agentsMu.Unlock()
	if entry == nil {
		return api.AgentStatus{}
	}
	entry.mu.Lock()
	defer entry.mu.Unlock()
	return entry.status
}

func (s *Service) agentTurn(sessionID string) api.AgentTurn {
	s.lazyInit()
	s.agentsMu.Lock()
	entry := s.agents[sessionID]
	s.agentsMu.Unlock()
	if entry == nil {
		return api.AgentTurn{Status: api.AgentTurnIdle}
	}
	entry.mu.Lock()
	defer entry.mu.Unlock()
	turn := entry.turn
	if turn.Status == "" {
		turn.Status = api.AgentTurnIdle
	}
	return turn
}

func terminalAgentTurnStatus(status api.AgentTurnStatus) bool {
	switch status {
	case api.AgentTurnCompleted, api.AgentTurnFailed, api.AgentTurnInterrupted, api.AgentTurnCancelled, api.AgentTurnAborted:
		return true
	default:
		return false
	}
}

// markPendingAgentTurnRequest records a cancellation/steer request only after
// all request validation has passed and immediately before the transport is
// invoked. It must not mutate AgentStatus: acceptance is an intent, not a
// Provider terminal observation.
func (s *Service) markPendingAgentTurnRequest(sessionID string, request api.AgentTurnInterruptRequest) error {
	s.lazyInit()
	s.agentsMu.Lock()
	entry := s.agents[sessionID]
	s.agentsMu.Unlock()
	if entry == nil {
		return fmt.Errorf("turn %d is not active", request.Turn)
	}
	entry.mu.Lock()
	defer entry.mu.Unlock()
	if entry.turn.ID != request.Turn || entry.turn.Status != api.AgentTurnStarted {
		return fmt.Errorf("turn %d is not active", request.Turn)
	}
	// A watcher may publish a ready status immediately before its turn
	// boundary callback. Do not attach a later Host request to that already
	// observed stop; an empty status remains allowed for legacy/native bridges
	// that only publish turn cursors.
	switch entry.status.Activity {
	case "":
	case api.AgentActivityWorking, api.AgentActivityBlocked:
	default:
		return fmt.Errorf("turn %d is not active", request.Turn)
	}
	entry.pendingTurnRequest = &pendingAgentTurnRequest{
		turn:      request.Turn,
		commandID: strings.TrimSpace(request.CommandID),
		reason:    strings.TrimSpace(request.Reason),
	}
	return nil
}

// clearPendingAgentTurnRequest removes an admission record when its transport
// failed. A Provider observation may have consumed it already, so matching is
// intentionally conditional and idempotent.
func (s *Service) clearPendingAgentTurnRequest(sessionID string, turn uint64, commandID string) {
	s.lazyInit()
	s.agentsMu.Lock()
	entry := s.agents[sessionID]
	s.agentsMu.Unlock()
	if entry == nil {
		return
	}
	entry.mu.Lock()
	defer entry.mu.Unlock()
	pending := entry.pendingTurnRequest
	if pending == nil || pending.turn != turn {
		return
	}
	if commandID != "" && pending.commandID != strings.TrimSpace(commandID) {
		return
	}
	entry.pendingTurnRequest = nil
}

func (s *Service) waitAgentReady(ctx context.Context, sessionID string) error {
	s.lazyInit()
	session, sessionExists := s.Session(sessionID)
	s.agentsMu.Lock()
	entry := s.agents[sessionID]
	var watcher *agent.Watcher
	var handle AgentHandle
	if entry != nil {
		watcher = entry.watcher
		entry.mu.Lock()
		handle = entry.handle
		entry.mu.Unlock()
	}
	s.agentsMu.Unlock()
	if handle != nil {
		return nil
	}
	if watcher == nil {
		// A dedicated Agent TUI is input-ready before its first prompt creates
		// a transcript binding. Allow the initial subscription so agent send can
		// deliver that prompt and let reconciliation attach the watcher later.
		if sessionExists && session.Lifecycle == "running" &&
			(session.Kind == "codex" || session.Kind == "claude" || session.Kind == "opencode" || session.Kind == "pi" || session.Kind == "qoder" || session.Kind == "antigravity") {
			return nil
		}
		return fmt.Errorf("agent is still starting for session %s; finish first-time setup in Terminal and retry", sessionID)
	}
	return watcher.WaitReady(ctx)
}

// applyAgentState reflects the managed provider hook's state file on the
// status light. Hook observations are edge-triggered by file modification
// time: once a transcript watcher has observed newer progress, the same
// durable hook snapshot must not overwrite it on every one-second reconcile.
func (s *Service) applyAgentState(session api.Session) {
	kind := session.Kind
	if kind == "shell" || kind == "custom" {
		if binding, err := agent.ReadBinding(agent.BindPath(session.ID)); err == nil && binding != nil && binding.Provider != "" {
			kind = binding.Provider
		}
	}
	if kind != "codex" && kind != "claude" && kind != "opencode" && kind != "qoder" && kind != "antigravity" {
		return
	}
	state, err := agent.ReadAgentState(agent.StatePath(session.ID))
	if err != nil || state.Status.Activity == "" {
		return
	}
	if state.Status.Activity == api.AgentActivityExited && kind == "codex" {
		// Codex's SessionEnd is scoped to a thread runtime. A dedicated TUI
		// can keep running with another thread, so its hook must not gray the
		// Warren session. Shell overlays require an exact binding match before
		// accepting the event for the current CLI thread.
		if session.Kind == "codex" || !agentStateMatchesBinding(session.ID, state) {
			return
		}
	}
	info, err := os.Stat(agent.StatePath(session.ID))
	if err != nil {
		return
	}
	s.agentsMu.Lock()
	entry := s.agents[session.ID]
	if entry == nil {
		entry = &agentSession{}
		s.agents[session.ID] = entry
	}
	entry.mu.Lock()
	if !entry.hookStateModTime.IsZero() && entry.hookStateModTime.Equal(info.ModTime()) {
		entry.mu.Unlock()
		s.agentsMu.Unlock()
		return
	}
	entry.hookStateModTime = info.ModTime()
	current := entry.status
	entry.mu.Unlock()
	s.agentsMu.Unlock()
	switch state.Status.Activity {
	case api.AgentActivityExited:
		if current.Activity != state.Status.Activity {
			s.recordAgentStatus(session.ID, state.Status)
		}
	case api.AgentActivityReady:
		if current.Activity == api.AgentActivityExited || current.Activity == api.AgentActivityFailed {
			s.forceAgentStatus(session.ID, state.Status)
		} else if current.Activity != state.Status.Activity && !current.Equal(state.Status) {
			// Stop/session.idle hooks are the provider's explicit turn boundary.
			// They must clear a transcript status that is still working when the
			// final assistant event and the hook arrive in different poll ticks.
			s.recordAgentStatus(session.ID, state.Status)
		}
	case api.AgentActivityWorking:
		if current.Activity != api.AgentActivityExited && current.Activity != api.AgentActivityFailed && !current.Equal(state.Status) {
			s.recordAgentStatus(session.ID, state.Status)
		}
	case api.AgentActivityBlocked:
		if current.Activity != api.AgentActivityExited && current.Activity != api.AgentActivityFailed && !current.Equal(state.Status) {
			s.recordAgentStatus(session.ID, state.Status)
		}
	case api.AgentActivityFailed:
		if current.Activity != state.Status.Activity {
			s.recordAgentStatus(session.ID, state.Status)
		}
	}
}

func agentStateMatchesBinding(sessionID string, state agent.AgentState) bool {
	binding, err := agent.ReadBinding(agent.BindPath(sessionID))
	return err == nil && agent.StateMatchesBinding(state, binding)
}

func (s *Service) stopAgent(sessionID string) {
	s.lazyInit()
	s.agentsMu.Lock()
	entry := s.agents[sessionID]
	delete(s.agents, sessionID)
	var watcher *agent.Watcher
	var tailer *agent.OpenCodeTailer
	var handle AgentHandle
	hadAgent := false
	if entry != nil {
		watcher = entry.watcher
		tailer = entry.tailer
		hadAgent = watcher != nil || tailer != nil
		entry.mu.Lock()
		handle = entry.handle
		hadAgent = hadAgent || handle != nil
		entry.handle = nil
		entry.bindingKey = ""
		entry.providerKind = ""
		entry.handlerKind = ""
		entry.capabilities = nil
		entry.mu.Unlock()
	}
	s.agentsMu.Unlock()
	if watcher != nil {
		watcher.Close()
	}
	if tailer != nil {
		tailer.Close()
	}
	if handle != nil {
		_ = handle.Close()
	}
	if hadAgent {
		s.bumpAgentRosterRevision()
	}
	s.wakeLiveActivity()
}

func splitCanonicalAgentEvents(events []api.CanonicalAgentEvent, maxBytes int) [][]api.CanonicalAgentEvent {
	if len(events) == 0 {
		return nil
	}
	if maxBytes <= 0 {
		maxBytes = agentMessageMaxBytes
	}
	var batches [][]api.CanonicalAgentEvent
	var current []api.CanonicalAgentEvent
	total := 0
	for _, event := range events {
		size, _ := json.Marshal(event)
		if len(current) > 0 && total+len(size) > maxBytes {
			batches = append(batches, current)
			current = nil
			total = 0
		}
		current = append(current, event)
		total += len(size)
	}
	if len(current) > 0 {
		batches = append(batches, current)
	}
	return batches
}

func encodeCanonicalAgentBatches(
	streamID, executionID string,
	batches [][]api.CanonicalAgentEvent,
) ([][]byte, error) {
	if len(batches) == 0 {
		return nil, nil
	}
	encoded := make([][]byte, 0, len(batches))
	for _, batch := range batches {
		data, err := json.Marshal(api.CanonicalAgentEventsMessage{
			Type:        "agent.events",
			StreamID:    streamID,
			ExecutionID: executionID,
			Events:      batch,
		})
		if err != nil {
			return nil, err
		}
		encoded = append(encoded, data)
	}
	return encoded, nil
}

func (s *Service) broadcastCanonicalAgentIncrements(sessionID string, events []api.CanonicalAgentEvent, streamID, executionID string) {
	lock := s.agentLock(sessionID)
	lock.Lock()
	defer lock.Unlock()
	s.broadcastCanonicalAgentIncrementsLocked(sessionID, events, streamID, executionID)
}

func (s *Service) broadcastCanonicalAgentIncrementsLocked(sessionID string, events []api.CanonicalAgentEvent, streamID, executionID string) {
	if len(events) == 0 {
		return
	}
	var (
		prepared  bool
		batches   [][]api.CanonicalAgentEvent
		encoded   [][]byte
		encodeErr error
	)
	s.broadcastAgentLocked(func(peer *wsPeer) error {
		if !peer.hasCanonicalAgentStream(streamID) {
			return nil
		}
		if !prepared {
			batches = splitCanonicalAgentEvents(events, agentMessageMaxBytes)
			encoded, encodeErr = encodeCanonicalAgentBatches(streamID, executionID, batches)
			prepared = true
			if encodeErr != nil {
				// Keep the old per-peer path for malformed payloads so one bad event
				// retains the existing peer error and detach behavior.
				s.logWarn("encode canonical agent events", "session", sessionID, "error", encodeErr)
			}
		}
		if encodeErr != nil {
			for _, batch := range batches {
				if err := peer.enqueueCanonicalAgentEvents(streamID, executionID, batch); err != nil {
					return err
				}
			}
			return nil
		}
		for _, data := range encoded {
			// data is immutable after encoding and is intentionally shared by
			// every peer queue; the queue and writer retain the slice safely.
			if err := peer.writeText(data); err != nil {
				return err
			}
		}
		return nil
	}, sessionID)
}

// broadcastAgentLocked delivers one canonical Agent batch to terminal peers
// and event subscribers. The caller holds the session Agent lock.
func (s *Service) broadcastAgentLocked(send func(*wsPeer) error, sessionID string) {
	s.outputMu.Lock()
	unique := make(map[*wsPeer]struct{}, len(s.peers[sessionID])+len(s.agentPeers[sessionID]))
	for peer := range s.peers[sessionID] {
		unique[peer] = struct{}{}
	}
	for peer := range s.agentPeers[sessionID] {
		unique[peer] = struct{}{}
	}
	peers := make([]*wsPeer, 0, len(unique))
	for peer := range unique {
		peers = append(peers, peer)
	}
	s.outputMu.Unlock()
	for _, peer := range peers {
		if err := send(peer); err != nil {
			s.detachPeer(peer, sessionID)
			s.detachAgentPeer(peer, sessionID)
		}
	}
}
