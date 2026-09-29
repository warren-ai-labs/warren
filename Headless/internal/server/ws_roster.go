package server

import (
	"bytes"
	"context"
	"encoding/json"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/gorilla/websocket"
)

func (p *wsPeer) startRoster(parent context.Context, initial api.State, initialRevision uint64, useDeltas bool) {
	ctx, cancel := context.WithCancel(parent)
	p.rosterCancel = cancel
	go func() {
		ticker := time.NewTicker(750 * time.Millisecond)
		defer ticker.Stop()
		state := initial
		deliveredRevision := initial.Revision
		observedRevision := initialRevision
		last, _ := json.Marshal(makeRoster(initial))
		changes := p.server.Service.Store.ChangesSince(observedRevision)
		var batchTimer *time.Timer
		var batch <-chan time.Time
		defer func() {
			if batchTimer != nil {
				batchTimer.Stop()
			}
		}()

		publish := func(next api.State, revision uint64) bool {
			if useDeltas {
				delta := makeRosterDelta(state, next, deliveredRevision, revision)
				if !delta.hasChanges() {
					return true
				}
				data, err := json.Marshal(delta)
				if err != nil {
					return true
				}
				if !p.enqueue(outboundMessage{kind: websocket.TextMessage, data: data}) {
					p.close()
					return false
				}
				state = next
				deliveredRevision = revision
				return true
			}

			data, err := json.Marshal(makeRoster(next))
			if err != nil {
				return true
			}
			if bytes.Equal(data, last) {
				return true
			}
			last = append(last[:0], data...)
			if !p.enqueue(outboundMessage{kind: websocket.TextMessage, data: data}) {
				p.close()
				return false
			}
			state = next
			deliveredRevision = revision
			return true
		}
		refresh := func() bool {
			next, storeRevision := p.server.Service.RosterVersion(ctx)
			next = projectRosterCapabilities(next, p.capabilitiesList())
			observedRevision = storeRevision
			return publish(next, next.Revision)
		}
		for {
			select {
			case <-ctx.Done():
				return
			case <-changes:
				if !useDeltas {
					if !refresh() {
						return
					}
					changes = p.server.Service.Store.ChangesSince(observedRevision)
					continue
				}
				if batchTimer == nil {
					batchTimer = time.NewTimer(rosterDeltaBatchDelay)
					batch = batchTimer.C
				}
				changes = nil
			case <-batch:
				batchTimer = nil
				batch = nil
				if !refresh() {
					return
				}
				changes = p.server.Service.Store.ChangesSince(observedRevision)
			case <-ticker.C:
				if !refresh() {
					return
				}
				changes = p.server.Service.Store.ChangesSince(observedRevision)
			}
		}
	}()
}

func makeRoster(state api.State) rosterMessage {
	return rosterMessage{Type: "roster", State: state}
}

// projectRosterCapabilities applies the connection-level negotiation to the
// Host-computed Session capability set. The durable/observer roster retains
// provider capabilities; each WebSocket receives only the intersection it can
// actually decode and execute.
func projectRosterCapabilities(state api.State, connection []string) api.State {
	for index := range state.Sessions {
		values := state.Sessions[index].AgentCapabilities
		if values == nil {
			// A roster produced by an older embedded Service has no Session-level
			// field. Treat it as unknown and preserve the established connection
			// capability fallback instead of denying every control.
			values = api.AgentViewCapabilities
		}
		allowed := make([]string, 0, len(values))
		for _, value := range values {
			if api.SupportsCapability(connection, value) {
				allowed = append(allowed, value)
			}
		}
		state.Sessions[index].AgentCapabilities = api.NormalizeCapabilityList(allowed)
	}
	return state
}

func publicSession(session api.Session) api.Session {
	session.OutputCursor = ""
	if session.AgentCapabilities == nil {
		session.AgentCapabilities = []string{}
	}
	return session
}

func publicSessionMovePreflight(value api.SessionMovePreflight) api.SessionMovePreflight {
	value.Session = publicSession(value.Session)
	return value
}
