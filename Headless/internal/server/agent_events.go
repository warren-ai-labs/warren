package server

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/store"
)

func canonicalStatusPayload(status api.AgentStatus) map[string]any {
	payload := map[string]any{"activity": status.Activity}
	if status.Attention != nil {
		payload["attention"] = status.Attention
	}
	return payload
}

func canonicalProjectionState(status api.AgentStatus, turn api.AgentTurn) map[string]any {
	state := map[string]any{"status": canonicalStatusPayload(status)}
	if turn.ID > 0 {
		state["turnId"] = strconv.FormatUint(turn.ID, 10)
		state["turnStatus"] = string(turn.Status)
	}
	return state
}

// canonicalProjectionFromState decodes the small replaceable checkpoint
// persisted alongside the immutable journal. Checkpoints are JSON maps by
// design, so decoding through the public API types keeps unknown projection
// fields forward-compatible and avoids coupling the store to Service state.
func canonicalProjectionFromState(state map[string]any) (api.AgentStatus, api.AgentTurn) {
	status := api.AgentStatus{}
	turn := api.AgentTurn{Status: api.AgentTurnIdle}
	if len(state) == 0 {
		return status, turn
	}
	encoded, err := json.Marshal(state)
	if err != nil {
		return status, turn
	}
	var value struct {
		Status     api.AgentStatus     `json:"status"`
		TurnID     string              `json:"turnId"`
		TurnStatus api.AgentTurnStatus `json:"turnStatus"`
	}
	if err := json.Unmarshal(encoded, &value); err != nil {
		return status, turn
	}
	status = value.Status
	if value.TurnID != "" {
		if id, err := strconv.ParseUint(value.TurnID, 10, 64); err == nil {
			turn.ID = id
		}
	}
	if value.TurnStatus != "" {
		turn.Status = value.TurnStatus
	}
	return status, turn
}

func canonicalProjectionFromEvent(status api.AgentStatus, turn api.AgentTurn, event api.CanonicalAgentEvent) (api.AgentStatus, api.AgentTurn) {
	switch event.Type {
	case "status.changed":
		var value api.AgentStatus
		encoded, err := json.Marshal(event.Payload)
		if err == nil && json.Unmarshal(encoded, &value) == nil && value.Activity != "" {
			status = value
		}
	case "turn.started", "turn.completed", "turn.failed", "turn.cancelled", "turn.interrupted", "turn.aborted":
		turnID := strings.TrimSpace(event.TurnID)
		if value, ok := event.Payload["turnId"].(string); ok && value != "" {
			turnID = value
		}
		if id, err := strconv.ParseUint(turnID, 10, 64); err == nil && id > 0 {
			turn.ID = id
		}
		if value, ok := event.Payload["status"].(string); ok {
			turn.Status = api.AgentTurnStatus(value)
		} else {
			switch event.Type {
			case "turn.started":
				turn.Status = api.AgentTurnStarted
			case "turn.completed":
				turn.Status = api.AgentTurnCompleted
			case "turn.failed":
				turn.Status = api.AgentTurnFailed
			case "turn.cancelled":
				turn.Status = api.AgentTurnCancelled
			case "turn.interrupted":
				turn.Status = api.AgentTurnInterrupted
			case "turn.aborted":
				turn.Status = api.AgentTurnAborted
			}
		}
	}
	return status, turn
}

// restoreCanonicalProjection rebuilds the replaceable in-memory projection
// after a Host restart. The durable checkpoint is the fast path; any events
// committed after it are replayed from the same journal before the projection
// becomes visible to command validation and roster consumers.
func (s *Service) restoreCanonicalProjection(executionID string) (api.AgentStatus, api.AgentTurn, bool) {
	agentStore := s.agentStore()
	if agentStore == nil || strings.TrimSpace(executionID) == "" {
		return api.AgentStatus{}, api.AgentTurn{Status: api.AgentTurnIdle}, false
	}
	status := api.AgentStatus{}
	turn := api.AgentTurn{Status: api.AgentTurnIdle}
	var after uint64
	if checkpoint, ok, err := agentStore.CanonicalCheckpoint(context.Background(), executionID); err == nil && ok {
		status, turn = canonicalProjectionFromState(checkpoint.State)
		after = checkpoint.Sequence
	}
	result, err := agentStore.QueryCanonicalEvents(context.Background(), executionID, after, 0, agentHistoryMaxLimit)
	if err != nil {
		// A checkpoint at or before the retention boundary can be rebuilt from
		// the retained tail. Do not make a cold start fail merely because the
		// cache was pruned between the two reads.
		if _, boundary := err.(*store.CanonicalHistoryBoundary); boundary {
			result, err = agentStore.QueryCanonicalEvents(context.Background(), executionID, 0, 0, agentHistoryMaxLimit)
		}
	}
	if err != nil {
		return status, turn, status.Activity != "" || turn.ID > 0
	}
	for _, event := range result.Events {
		status, turn = canonicalProjectionFromEvent(status, turn, event)
	}
	return status, turn, status.Activity != "" || turn.ID > 0
}

func canonicalTurnEvent(turn api.AgentTurn, streamID, executionID string, requests ...*pendingAgentTurnRequest) api.CanonicalAgentEvent {
	var request *pendingAgentTurnRequest
	if len(requests) > 0 {
		request = requests[0]
	}
	eventType := "turn." + string(turn.Status)
	if turn.Status == api.AgentTurnAborted {
		eventType = "turn.aborted"
	}
	if turn.Status == api.AgentTurnInterrupted {
		eventType = "turn.interrupted"
	}
	if turn.Status == api.AgentTurnCancelled {
		eventType = "turn.cancelled"
	}
	payload := map[string]any{
		"turnId": strconv.FormatUint(turn.ID, 10),
		"status": string(turn.Status),
	}
	var causedBy string
	if turn.Status == api.AgentTurnInterrupted {
		payload["cause"] = "interrupt"
	}
	if turn.Status == api.AgentTurnCancelled {
		cause := "cancel"
		if request != nil && request.reason != "" {
			cause = request.reason
		}
		payload["cause"] = cause
		if request != nil {
			causedBy = strings.TrimSpace(request.commandID)
		}
	}
	return api.CanonicalAgentEvent{
		EventID:     fmt.Sprintf("turn:%d:%s", turn.ID, turn.Status),
		StreamID:    streamID,
		ExecutionID: executionID,
		TurnID:      strconv.FormatUint(turn.ID, 10),
		Type:        eventType,
		OccurredAt:  time.Now().UTC(),
		CausedBy:    causedBy,
		Origin: api.AgentEventOrigin{
			Kind:       "host",
			Confidence: "derived",
		},
		Payload: payload,
	}
}

func canonicalStatusEvent(status api.AgentStatus, streamID, executionID string) api.CanonicalAgentEvent {
	return api.CanonicalAgentEvent{
		EventID:     store.NewID(),
		StreamID:    streamID,
		ExecutionID: executionID,
		Type:        "status.changed",
		OccurredAt:  time.Now().UTC(),
		Origin: api.AgentEventOrigin{
			Kind:       "host",
			Confidence: "derived",
		},
		Payload: canonicalStatusPayload(status),
	}
}

// recordAgentMessageCorrelation remembers that commandID was injected into the
// session's provider as text, so the user event the provider later writes into
// its transcript can carry that identity back to clients as CausedBy.
func (s *Service) recordAgentMessageCorrelation(sessionID, commandID, text string) {
	commandID = strings.TrimSpace(commandID)
	if s == nil || commandID == "" {
		return
	}
	s.lazyInit()
	s.agentsMu.Lock()
	entry := s.agents[sessionID]
	if entry == nil {
		s.agentsMu.Unlock()
		return
	}
	entry.mu.Lock()
	now := time.Now()
	entry.pendingCorrelations = pruneAgentCorrelations(entry.pendingCorrelations, now)
	entry.pendingCorrelations = append(entry.pendingCorrelations, pendingAgentCorrelation{
		commandID: commandID,
		text:      strings.TrimSpace(text),
		sentAt:    now,
	})
	if overflow := len(entry.pendingCorrelations) - maxPendingAgentCorrelations; overflow > 0 {
		entry.pendingCorrelations = append(
			[]pendingAgentCorrelation(nil), entry.pendingCorrelations[overflow:]...,
		)
	}
	entry.mu.Unlock()
	s.agentsMu.Unlock()
}

func pruneAgentCorrelations(pending []pendingAgentCorrelation, now time.Time) []pendingAgentCorrelation {
	kept := pending[:0]
	for _, value := range pending {
		if now.Sub(value.sentAt) <= agentCorrelationTTL {
			kept = append(kept, value)
		}
	}
	return kept
}

// takeAgentCorrelation claims the commandId for one echoed user message. FIFO
// order is the primary signal because a CLI consumes injected input in order;
// the content check only guards against claiming an unrelated message, and must
// tolerate a provider parser clipping long content to its own limit.
// Callers hold entry.mu.
func takeAgentCorrelation(entry *agentSession, content string) string {
	if entry == nil || len(entry.pendingCorrelations) == 0 {
		return ""
	}
	entry.pendingCorrelations = pruneAgentCorrelations(entry.pendingCorrelations, time.Now())
	if len(entry.pendingCorrelations) == 0 {
		return ""
	}
	content = strings.TrimSpace(content)
	head := entry.pendingCorrelations[0]
	if !agentCorrelationContentMatches(head.text, content) {
		return ""
	}
	entry.pendingCorrelations = append(
		[]pendingAgentCorrelation(nil), entry.pendingCorrelations[1:]...,
	)
	return head.commandID
}

// agentCorrelationContentMatches decides whether an echoed transcript line is
// the message the Host injected. A provider never lengthens user text, so an
// echo longer than the injection is a different message: accepting a plain
// prefix in that direction would make "run" claim the echo of "run the tests".
// Clipping is the one legitimate shortening, and it is self-announcing because
// truncate appends an ellipsis.
func agentCorrelationContentMatches(injected, echoed string) bool {
	if echoed == "" {
		return false
	}
	if injected == echoed {
		return true
	}
	if clipped, ok := strings.CutSuffix(echoed, "…"); ok {
		return clipped != "" && strings.HasPrefix(injected, clipped)
	}
	// Some providers reflow whitespace when storing the message.
	return strings.Join(strings.Fields(injected), " ") == strings.Join(strings.Fields(echoed), " ")
}

// isCanonicalUserMessage reports whether a canonical event is a complete user
// message, which is the only row an outgoing message can be correlated with.
func isCanonicalUserMessage(event api.CanonicalAgentEvent) bool {
	if event.Type != "message.created" {
		return false
	}
	role, _ := event.Payload["role"].(string)
	return strings.EqualFold(strings.TrimSpace(role), "user")
}

// canonicalProviderEvent turns one provider observation into an immutable
// event row. Provider IDs identify a message/tool in the provider projection;
// they are not event IDs because a provider may reuse them across deltas or
// lifecycle updates. The stable observation hash therefore includes the
// provider sequence and is used as the canonical event identity, while the
// provider ID is retained only in the typed payload for correlation.
func canonicalProviderEvent(source api.AgentEvent, streamID, executionID string) api.CanonicalAgentEvent {
	providerID := source.ID
	eventID := api.StableAgentEventID(source)
	canonical := api.CanonicalAgentEventFromObservation(source, streamID, executionID, 0, time.Now().UTC())
	canonical.EventID = eventID
	canonical.Sequence = 0
	if providerID != "" {
		if canonical.Payload == nil {
			canonical.Payload = make(map[string]any)
		}
		switch canonical.Type {
		case "message.created", "message.delta", "message.completed", "reasoning.delta":
			if _, exists := canonical.Payload["messageId"]; !exists {
				canonical.Payload["messageId"] = providerID
			}
		case "tool.started", "tool.updated", "tool.completed", "tool.failed":
			if _, exists := canonical.Payload["callId"]; !exists {
				canonical.Payload["callId"] = providerID
			}
		case "interaction.requested", "interaction.resolved", "interaction.expired":
			if _, exists := canonical.Payload["interactionId"]; !exists {
				canonical.Payload["interactionId"] = providerID
			}
		default:
			canonical.Payload["sourceId"] = providerID
		}
	}
	// A provider sequence is only an idempotency input. Canonical sequence is
	// assigned by the journal and must remain zero until that commit.
	if canonical.Type == "message.created" && source.StopReason != "" {
		canonical.Type = "message.completed"
	}
	return canonical
}

// appendCanonicalEventsLockedWithCheckpoint commits one immutable batch and
// returns the exact Host-assigned rows. The caller owns entry.mu. The memory
// path mirrors the SQLite journal for tests and embedders that do not
// configure AgentStore.
func (s *Service) appendCanonicalEventsLockedWithCheckpoint(sessionID string, entry *agentSession, events []api.CanonicalAgentEvent, checkpoint map[string]any) ([]api.CanonicalAgentEvent, error) {
	if len(events) == 0 {
		return nil, nil
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
	if agentStore := s.agentStore(); agentStore != nil {
		assigned, err := agentStore.AppendCanonicalEventsWithCheckpoint(context.Background(), streamID, streamID, events, checkpoint)
		if err != nil {
			return nil, err
		}
		entry.canonicalEvents = append(entry.canonicalEvents, assigned...)
		return assigned, nil
	}
	assigned := make([]api.CanonicalAgentEvent, 0, len(events))
	var head uint64
	if len(entry.canonicalEvents) > 0 {
		head = entry.canonicalEvents[len(entry.canonicalEvents)-1].Sequence
	}
	for _, source := range events {
		event := source
		event.StreamID = streamID
		if event.ExecutionID == "" {
			event.ExecutionID = streamID
		}
		if event.EventID == "" {
			event.EventID = store.NewID()
		}
		var existing *api.CanonicalAgentEvent
		for index := range entry.canonicalEvents {
			candidate := &entry.canonicalEvents[index]
			if candidate.EventID == event.EventID || (event.Sequence > 0 && candidate.Sequence == event.Sequence) {
				existing = candidate
				break
			}
		}
		if existing != nil {
			causedBy, ok := api.MergeCanonicalCausation(existing.CausedBy, event.CausedBy)
			if !ok || !canonicalEventsEquivalent(*existing, event) {
				return nil, fmt.Errorf("canonical agent event conflict at %s", event.EventID)
			}
			// Late-bound annotation: a re-observation may supply the causation
			// the first one lacked, and never clears it.
			existing.CausedBy = causedBy
			assigned = append(assigned, *existing)
			continue
		}
		if event.Sequence == 0 {
			head++
			event.Sequence = head
		} else if event.Sequence > head {
			head = event.Sequence
		}
		if event.RecordedAt.IsZero() {
			event.RecordedAt = time.Now().UTC()
		}
		if event.OccurredAt.IsZero() {
			event.OccurredAt = event.RecordedAt
		}
		entry.canonicalEvents = append(entry.canonicalEvents, event)
		assigned = append(assigned, event)
	}
	return assigned, nil
}

func canonicalEventsEquivalent(existing, incoming api.CanonicalAgentEvent) bool {
	existing.Sequence = 0
	incoming.Sequence = 0
	existing.OccurredAt = time.Time{}
	incoming.OccurredAt = time.Time{}
	existing.RecordedAt = time.Time{}
	incoming.RecordedAt = time.Time{}
	// CausedBy is reconciled separately by api.MergeCanonicalCausation: it is
	// late-bound provenance, so its absence on a re-observation is not a
	// semantic difference.
	existing.CausedBy = ""
	incoming.CausedBy = ""
	left, leftErr := json.Marshal(existing)
	right, rightErr := json.Marshal(incoming)
	if leftErr != nil || rightErr != nil {
		return false
	}
	left, leftErr = normalizeCanonicalJSON(left)
	right, rightErr = normalizeCanonicalJSON(right)
	return leftErr == nil && rightErr == nil && bytes.Equal(left, right)
}

func normalizeCanonicalJSON(encoded []byte) ([]byte, error) {
	decoder := json.NewDecoder(bytes.NewReader(encoded))
	decoder.UseNumber()
	var value any
	if err := decoder.Decode(&value); err != nil {
		return nil, err
	}
	return json.Marshal(value)
}

// recordAgentEvents stores a bounded event history and forwards the batch to
// every peer attached to the session.
func (s *Service) recordAgentEvents(sessionID string, events []api.AgentEvent, status api.AgentStatus) {
	s.recordAgentEventsForHandle(sessionID, nil, events, status)
}

// recordAgentEventsForHandle is the provider callback path. The handle
// identity is checked while the projection lock is held, so a callback that
// races a rebind cannot append events from the retired transcript to the new
// Agent session.
func (s *Service) recordAgentEventsForHandle(sessionID string, expected AgentHandle, events []api.AgentEvent, status api.AgentStatus) {
	if len(events) == 0 {
		return
	}
	if expected != nil {
		lock := s.agentLock(sessionID)
		lock.Lock()
		defer lock.Unlock()
	}
	s.lazyInit()
	s.agentsMu.Lock()
	effectiveStatus := status
	shouldTryTitle := false
	entry := s.agents[sessionID]
	if entry == nil {
		s.agentsMu.Unlock()
		return
	}
	entry.mu.Lock()
	if expected != nil && entry.handle != expected {
		entry.mu.Unlock()
		s.agentsMu.Unlock()
		return
	}
	streamID := strings.TrimSpace(entry.executionID)
	if streamID == "" {
		// recordAgentEventsForHandle already owns agentsMu and entry.mu. Calling
		// canonicalExecutionID here would try to acquire agentsMu a second time
		// and deadlock the provider callback on its first event. Allocate the
		// identity inline while the existing critical section is held.
		if s.Store != nil {
			streamID = s.ensureAgentExecutionID(nil, sessionID, false)
		} else {
			streamID = store.NewID()
		}
		entry.executionID = streamID
	}
	// A native interaction response is recorded locally before a provider may
	// echo its terminal observation through the transcript watcher. Suppress
	// that semantic duplicate while retaining all unrelated observations.
	filteredEvents := make([]api.AgentEvent, 0, len(events))
	for _, source := range events {
		canonicalType := canonicalProviderEvent(source, streamID, streamID).Type
		if strings.HasPrefix(canonicalType, "interaction.") && canonicalType != "interaction.requested" {
			interactionID := canonicalInteractionEventID(source)
			if canonicalEntryHasTerminalInteraction(entry, interactionID) {
				continue
			}
		}
		filteredEvents = append(filteredEvents, source)
	}
	events = filteredEvents
	status = withoutSettledPlanPrompt(entry, status)
	effectiveStatus = entry.status
	if entry.status.Activity == api.AgentActivityExited && status.Activity != api.AgentActivityExited {
		status = entry.status
	} else if status.Activity != "" {
		effectiveStatus = status
	}
	canonical := make([]api.CanonicalAgentEvent, 0, len(events)+1)
	for _, source := range events {
		// Provider sequence numbers are projection metadata. The canonical
		// journal assigns a fresh Host sequence at commit time.
		if source.ID == "" {
			source.ID = api.StableAgentEventID(source)
		}
		canonicalEvent := canonicalProviderEvent(source, streamID, streamID)
		if entry.handlerKind == AgentHandlerACP {
			// ACP observations are the provider's own protocol messages, not
			// a projection of a transcript file.
			canonicalEvent.Origin.Driver = AgentHandlerACP
			canonicalEvent.Origin.Channel = "rpc"
			canonicalEvent.Origin.Confidence = "native"
		}
		if canonicalEvent.CausedBy == "" && isCanonicalUserMessage(canonicalEvent) {
			// CausedBy is not part of StableAgentEventID, which hashes the
			// provider observation. Attributing the echo therefore does not
			// change the event identity clients dedupe on.
			canonicalEvent.CausedBy = takeAgentCorrelation(entry, source.Content)
		}
		if strings.HasPrefix(canonicalEvent.Type, "interaction.") {
			// Provider terminal observations often contain only requestId/state.
			// Carry the immutable request schema forward so a resolved card can
			// still be expanded and audited after a reconnect.
			mergeCanonicalInteractionContext(entry.canonicalEvents, &canonicalEvent)
			if canonicalEvent.Type != "interaction.requested" &&
				canonicalEntryHasTerminalInteraction(entry, canonicalInteractionCanonicalID(canonicalEvent)) {
				continue
			}
		}
		canonical = append(canonical, canonicalEvent)
	}
	statusChanged := status.Activity != "" && !entry.status.Equal(status)
	if statusChanged {
		canonical = append(canonical, canonicalStatusEvent(status, streamID, streamID))
	}
	assignedCanonical, appendErr := s.appendCanonicalEventsLockedWithCheckpoint(
		sessionID, entry, canonical, canonicalProjectionState(effectiveStatus, entry.turn),
	)
	if appendErr != nil {
		entry.mu.Unlock()
		s.agentsMu.Unlock()
		s.logWarn("append canonical agent events", "session", sessionID, "error", appendErr)
		return
	}
	entry.events = append(entry.events, events...)
	if len(entry.events) > 2000 {
		entry.events = append([]api.AgentEvent(nil), entry.events[len(entry.events)-2000:]...)
	}
	if status.Activity != "" {
		entry.status = effectiveStatus
	}
	for _, event := range events {
		if event.Sidechain {
			continue
		}
		switch event.Type {
		case "user":
			content := strings.TrimSpace(event.Content)
			if content == "" || isTitleSystemContext(content) {
				continue
			}
			appendTitleMessage(&entry.titleUser, &entry.titleUserProvider, &entry.titleUserID, event)
		case "assistant":
			appendTitleMessage(&entry.titleAssistant, &entry.titleAssistantProvider, &entry.titleAssistantID, event)
			// Codex and Claude emit complete assistant messages as ordinary
			// events. OpenCode emits an initial snapshot followed by deltas;
			// its turn-complete callback is the completion boundary unless a
			// terminal finish reason is attached directly to this event.
			if entry.titleAssistant != "" && (event.StopReason != "" || (!event.ContentDelta && event.Provider != "opencode")) {
				entry.titleAssistantComplete = true
			}
		}
	}
	shouldTryTitle = entry.titleAssistantComplete
	entry.mu.Unlock()
	s.agentsMu.Unlock()
	if expected != nil {
		s.broadcastCanonicalAgentIncrementsLocked(sessionID, assignedCanonical, streamID, streamID)
	} else {
		s.broadcastCanonicalAgentIncrements(sessionID, assignedCanonical, streamID, streamID)
	}
	if shouldTryTitle {
		s.tryStartSessionTitle(sessionID)
	}
	s.wakeLiveActivity()
}

// recordAgentStatus forwards a status change that arrived without new
// transcript events, such as a liveness warning.
func (s *Service) recordAgentStatus(sessionID string, status api.AgentStatus) {
	s.setAgentStatusForHandle(sessionID, nil, status, false)
}

func (s *Service) recordAgentStatusForHandle(sessionID string, handle AgentHandle, status api.AgentStatus) {
	s.setAgentStatusForHandle(sessionID, handle, status, false)
}

// recordAgentTurns stores the latest turn cursor and optionally broadcasts
// live boundaries. Historical replay updates the snapshot without waking a
// waiter for work that completed before it subscribed.
func (s *Service) recordAgentTurns(sessionID string, turns []api.AgentTurn, broadcast bool) {
	s.recordAgentTurnsForHandle(sessionID, nil, turns, broadcast)
}

func (s *Service) recordAgentTurnsForHandle(sessionID string, expected AgentHandle, turns []api.AgentTurn, broadcast bool) {
	if len(turns) == 0 {
		return
	}
	if expected != nil {
		lock := s.agentLock(sessionID)
		lock.Lock()
		defer lock.Unlock()
	}
	s.lazyInit()
	for _, turn := range turns {
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
		if turn.Status == "" || turn.Status == api.AgentTurnIdle {
			entry.mu.Unlock()
			s.agentsMu.Unlock()
			continue
		}
		// Turn callbacks can be replayed or arrive out of order around a
		// provider callback. Once this turn has a terminal boundary, never let a
		// duplicate or stale observation regress its semantic status.
		if entry.turn.ID > turn.ID ||
			(entry.turn.ID == turn.ID && terminalAgentTurnStatus(entry.turn.Status)) {
			entry.mu.Unlock()
			s.agentsMu.Unlock()
			continue
		}
		observedTurn := turn
		var terminationRequest *pendingAgentTurnRequest
		consumePendingRequest := false
		if turn.Status == api.AgentTurnInterrupted || turn.Status == api.AgentTurnAborted {
			if pending := entry.pendingTurnRequest; pending != nil && pending.turn == turn.ID {
				copy := *pending
				terminationRequest = &copy
				observedTurn.Status = api.AgentTurnCancelled
				consumePendingRequest = true
			} else {
				// Provider adapters report the fact of an interruption. A Host
				// cancellation is only inferred when it matches an outstanding
				// request for this exact turn.
				observedTurn.Status = api.AgentTurnInterrupted
				if pending := entry.pendingTurnRequest; pending != nil && pending.turn < turn.ID {
					entry.pendingTurnRequest = nil
				}
			}
		} else if pending := entry.pendingTurnRequest; pending != nil && turn.ID > pending.turn {
			// A newer turn supersedes a request whose target never produced a
			// terminal observation. Do not attribute the new turn to that request.
			entry.pendingTurnRequest = nil
		}
		if pending := entry.pendingTurnRequest; pending != nil && pending.turn == turn.ID &&
			(turn.Status == api.AgentTurnCompleted || turn.Status == api.AgentTurnFailed) {
			// A normal Provider terminal boundary wins over an outstanding Host
			// request. The request was accepted, but it did not cause this
			// completion, so it must not leak into a later interruption.
			entry.pendingTurnRequest = nil
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
		changed := entry.turn.ID != observedTurn.ID || entry.turn.Status != observedTurn.Status
		var canonical []api.CanonicalAgentEvent
		if changed {
			var appendErr error
			canonical, appendErr = s.appendCanonicalEventsLockedWithCheckpoint(sessionID, entry, []api.CanonicalAgentEvent{
				canonicalTurnEvent(observedTurn, streamID, streamID, terminationRequest),
			}, canonicalProjectionState(entry.status, observedTurn))
			if appendErr != nil {
				entry.mu.Unlock()
				s.agentsMu.Unlock()
				s.logWarn("append canonical agent turn", "session", sessionID, "error", appendErr)
				return
			}
		}
		if consumePendingRequest {
			entry.pendingTurnRequest = nil
		}
		entry.turn = observedTurn
		if observedTurn.Status == api.AgentTurnCompleted && strings.TrimSpace(entry.titleAssistant) != "" {
			entry.titleAssistantComplete = true
		}
		entry.mu.Unlock()
		s.agentsMu.Unlock()
		if broadcast {
			if expected != nil {
				if len(canonical) > 0 {
					s.broadcastCanonicalAgentIncrementsLocked(sessionID, canonical, streamID, streamID)
				}
			} else {
				if len(canonical) > 0 {
					s.broadcastCanonicalAgentIncrements(sessionID, canonical, streamID, streamID)
				}
			}
		}
		if observedTurn.Status == api.AgentTurnCompleted {
			s.tryStartSessionTitle(sessionID)
		}
	}
	s.wakeLiveActivity()
}
