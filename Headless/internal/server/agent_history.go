package server

import (
	"context"
	"errors"
	"sort"
	"strings"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/store"
)

// forceAgentStatus records a state transition that must override an exited
// marker, such as a new SessionStart resetting the shell overlay to ready.
func (s *Service) forceAgentStatus(sessionID string, status api.AgentStatus) {
	s.setAgentStatus(sessionID, status, true)
}

func (s *Service) setAgentStatus(sessionID string, status api.AgentStatus, force bool) {
	s.setAgentStatusForHandle(sessionID, nil, status, force)
}

func (s *Service) setAgentStatusForHandle(sessionID string, expected AgentHandle, status api.AgentStatus, force bool) {
	if expected != nil {
		lock := s.agentLock(sessionID)
		lock.Lock()
		defer lock.Unlock()
	}
	s.lazyInit()
	s.agentsMu.Lock()
	entry := s.agents[sessionID]
	if entry == nil {
		entry = &agentSession{}
		s.agents[sessionID] = entry
	}
	entry.mu.Lock()
	if expected != nil && entry.handle != expected {
		entry.mu.Unlock()
		s.agentsMu.Unlock()
		return
	}
	if !force && entry.status.Activity == api.AgentActivityExited && status.Activity != api.AgentActivityExited {
		entry.mu.Unlock()
		s.agentsMu.Unlock()
		return
	}
	status = withoutSettledPlanPrompt(entry, status)
	if status.Activity == "" || (!force && entry.status.Equal(status)) {
		entry.mu.Unlock()
		s.agentsMu.Unlock()
		return
	}
	streamID := strings.TrimSpace(entry.executionID)
	if streamID == "" {
		if s.Store != nil {
			streamID = s.ensureAgentExecutionID(nil, sessionID, false)
		} else {
			streamID = store.NewID()
		}
		entry.executionID = streamID
	}
	canonical, appendErr := s.appendCanonicalEventsLockedWithCheckpoint(sessionID, entry, []api.CanonicalAgentEvent{
		canonicalStatusEvent(status, streamID, streamID),
	}, canonicalProjectionState(status, entry.turn))
	if appendErr != nil {
		entry.mu.Unlock()
		s.agentsMu.Unlock()
		s.logWarn("append canonical agent status", "session", sessionID, "error", appendErr)
		return
	}
	entry.status = status
	entry.mu.Unlock()
	s.agentsMu.Unlock()
	if expected != nil {
		s.broadcastCanonicalAgentIncrementsLocked(sessionID, canonical, streamID, streamID)
	} else {
		s.broadcastCanonicalAgentIncrements(sessionID, canonical, streamID, streamID)
	}
	s.wakeLiveActivity()
}

func (s *Service) agentHistory(sessionID string) []api.AgentEvent {
	s.lazyInit()
	s.agentsMu.Lock()
	entry := s.agents[sessionID]
	s.agentsMu.Unlock()
	if entry == nil {
		return nil
	}
	entry.mu.Lock()
	defer entry.mu.Unlock()
	return append([]api.AgentEvent(nil), entry.events...)
}

func (s *Service) canonicalHistoryPage(ctx context.Context, streamID string, after, before uint64, limit int) (api.AgentEventsHistoryResult, error) {
	if agentStore := s.agentStore(); agentStore != nil {
		result, err := agentStore.QueryCanonicalEvents(ctx, streamID, after, before, limit)
		if boundary, ok := err.(*store.CanonicalHistoryBoundary); ok {
			// Older databases may have journal rows but no checkpoint row. Resolve
			// the active Session projection as a compatibility fallback; the
			// returned error remains structured and clients can install it without
			// inventing a cursor.
			if boundary.Checkpoint == nil {
				if session, found := s.sessionForCanonicalStream(streamID); found {
					checkpoint := s.canonicalProjectionCheckpoint(session.ID, boundary.HeadSequence)
					boundary.CheckpointSequence = checkpoint.Sequence
					boundary.Checkpoint = checkpoint.State
				}
			}
			if boundary.CheckpointSequence == 0 {
				boundary.CheckpointSequence = boundary.HeadSequence
			}
		}
		return result, err
	}
	streamID = strings.TrimSpace(streamID)
	if streamID == "" {
		return api.AgentEventsHistoryResult{}, errors.New("canonical agent streamId is required")
	}
	if limit <= 0 {
		limit = agentHistoryDefaultLimit
	}
	if limit > agentHistoryMaxLimit {
		limit = agentHistoryMaxLimit
	}
	s.lazyInit()
	s.agentsMu.Lock()
	var entry *agentSession
	for _, candidate := range s.agents {
		candidate.mu.Lock()
		if candidate.executionID == streamID {
			entry = candidate
			candidate.mu.Unlock()
			break
		}
		candidate.mu.Unlock()
	}
	s.agentsMu.Unlock()
	result := api.AgentEventsHistoryResult{StreamID: streamID}
	if entry == nil {
		return result, nil
	}
	entry.mu.Lock()
	events := append([]api.CanonicalAgentEvent(nil), entry.canonicalEvents...)
	result.ExecutionID = entry.executionID
	entry.mu.Unlock()
	if len(events) == 0 {
		return result, nil
	}
	result.HeadSequence = events[len(events)-1].Sequence
	result.RetainedFrom = events[0].Sequence
	if after > 0 && after+1 < result.RetainedFrom {
		return api.AgentEventsHistoryResult{}, &store.CanonicalHistoryBoundary{
			StreamID: streamID, RetainedFromSequence: result.RetainedFrom,
			HeadSequence: result.HeadSequence,
		}
	}
	start := 0
	end := len(events)
	if after > 0 {
		start = sort.Search(len(events), func(index int) bool { return events[index].Sequence > after })
	}
	if before > 0 {
		end = sort.Search(len(events), func(index int) bool { return events[index].Sequence >= before })
	}
	if start > end {
		start = end
	}
	if end-start > limit {
		if after == 0 {
			start = end - limit
		} else {
			end = start + limit
		}
		result.HasMore = true
	} else if before > 0 {
		result.HasMore = start > 0
	} else if after == 0 {
		result.HasMore = start > 0
	}
	result.Events = append([]api.CanonicalAgentEvent(nil), events[start:end]...)
	if len(result.Events) > 0 {
		result.NextAfterSequence = result.Events[len(result.Events)-1].Sequence
	}
	result.StateEvents = api.LatestCanonicalStateEvents(events, api.StateEventsBound(result.Events, after, result.HeadSequence))
	return result, nil
}

func (s *Service) canonicalExecutionForSession(sessionID string) (api.AgentExecution, bool) {
	session, ok := s.Session(sessionID)
	if !ok {
		return api.AgentExecution{}, false
	}
	executionID := strings.TrimSpace(session.AgentExecutionID)
	s.lazyInit()
	s.agentsMu.Lock()
	entry := s.agents[sessionID]
	s.agentsMu.Unlock()
	var provider, driver string
	var capabilities []string
	var status api.AgentStatus
	var turn api.AgentTurn
	if entry != nil {
		entry.mu.Lock()
		if executionID == "" {
			executionID = entry.executionID
		}
		provider, driver = entry.providerKind, entry.handlerKind
		capabilities = entry.capabilities.Strings()
		status, turn = entry.status, entry.turn
		entry.mu.Unlock()
	}
	if executionID == "" {
		executionID = s.canonicalExecutionID(sessionID)
	}
	if status.Activity == "" && s.agentStore() != nil {
		restoredStatus, restoredTurn, restored := s.restoreCanonicalProjection(executionID)
		if restored {
			status, turn = restoredStatus, restoredTurn
			if entry != nil {
				entry.mu.Lock()
				if entry.status.Activity == "" {
					entry.status = restoredStatus
				}
				if entry.turn.ID == 0 {
					entry.turn = restoredTurn
				}
				status, turn = entry.status, entry.turn
				entry.mu.Unlock()
			}
		}
	}
	if provider == "" {
		provider = normalizeProviderKind(session.Kind)
	}
	if driver == "" {
		driver = AgentHandlerTUI
	}
	if driver == AgentHandlerCLI {
		driver = AgentHandlerTUI
	}
	state := api.AgentExecutionReady
	switch status.Activity {
	case api.AgentActivityWorking:
		state = api.AgentExecutionWorking
	case api.AgentActivityBlocked:
		state = api.AgentExecutionBlocked
	case api.AgentActivityFailed:
		state = api.AgentExecutionFailed
	case api.AgentActivityExited:
		state = api.AgentExecutionClosed
	}
	result := api.AgentExecution{
		ID: executionID, StreamID: executionID,
		Target:       api.AgentTargetRef{Kind: "terminal_session", ID: sessionID},
		Provider:     provider,
		Conversation: api.AgentProviderConversationRef{ID: session.AgentSessionID},
		Driver:       driver, Capabilities: capabilities, State: state, Status: status,
	}
	if turn.ID > 0 {
		result.ActiveTurn = &turn
	}
	if history, err := s.canonicalHistoryPage(context.Background(), executionID, 0, 0, agentHistoryMaxLimit); err == nil {
		result.HeadSequence = history.HeadSequence
	}
	return result, true
}

// usageAttributionForStream maps a canonical stream to the project its spend
// belongs to.
//
// This runs inside the journal's append transaction, which the caller enters
// while holding the agent entry's own mutex. It therefore reads only the durable
// state snapshot and must never reach for agentsMu or an entry mutex the way
// sessionForCanonicalStream does on its fallback path, because Go mutexes are
// not reentrant and that would deadlock the append.
//
// An unresolvable stream yields an empty project rather than no row at all.
// Filing spend as unattributed keeps the panel's total honest; dropping it would
// make the total quietly disagree with what the Agents actually consumed.
func (s *Service) usageAttributionForStream(streamID string) store.UsageAttribution {
	streamID = strings.TrimSpace(streamID)
	if streamID == "" || s.Store == nil {
		return store.UsageAttribution{}
	}
	state := s.Store.Snapshot()
	workspaceID := ""
	for _, session := range state.Sessions {
		if session.AgentExecutionID == streamID {
			workspaceID = strings.TrimSpace(session.WorkspaceID)
			break
		}
	}
	if workspaceID == "" {
		return store.UsageAttribution{}
	}
	for _, workspace := range state.Workspaces {
		if workspace.ID == workspaceID {
			return store.UsageAttribution{ProjectID: strings.TrimSpace(workspace.ProjectID)}
		}
	}
	return store.UsageAttribution{}
}

func (s *Service) sessionForCanonicalStream(streamID string) (api.Session, bool) {
	streamID = strings.TrimSpace(streamID)
	if streamID == "" {
		return api.Session{}, false
	}
	if s.Store != nil {
		state := s.Store.Snapshot()
		for _, session := range state.Sessions {
			if session.AgentExecutionID == streamID {
				return session, true
			}
		}
	}
	s.agentsMu.Lock()
	defer s.agentsMu.Unlock()
	for sessionID, entry := range s.agents {
		entry.mu.Lock()
		matched := entry.executionID == streamID
		entry.mu.Unlock()
		if matched && s.Store != nil {
			if session, ok := s.Session(sessionID); ok {
				return session, true
			}
		}
	}
	return api.Session{}, false
}

func (s *Service) canonicalProjectionCheckpoint(sessionID string, sequence uint64) api.AgentProjectionCheckpoint {
	if agentStore := s.agentStore(); agentStore != nil {
		if checkpoint, ok, err := agentStore.CanonicalCheckpoint(context.Background(), s.canonicalExecutionID(sessionID)); err == nil && ok &&
			(checkpoint.Sequence == sequence || sequence == 0) {
			return checkpoint
		}
	}
	status := s.agentStatus(sessionID)
	turn := s.agentTurn(sessionID)
	return api.AgentProjectionCheckpoint{Sequence: sequence, State: canonicalProjectionState(status, turn)}
}
