package server

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/acp"
	"github.com/abcdlsj/warren/Headless/internal/api"
)

// An ACP agent runs in a holder (acp.Hold) so it survives a Host restart the
// way a terminal Session's PTY survives in Ghostline. The Host detaches on
// shutdown and attaches again on the next Start.

// acpReattachTimeout bounds attaching to a holder during Start.
const acpReattachTimeout = 3 * time.Second

// unixSocketPathLimit is the portable sun_path limit (macOS allows 104 bytes
// including the terminator).
const unixSocketPathLimit = 103

// acpHoldSocket is the holder socket for a Session. The name is derived from
// the Session ID, so a restarted Host finds it without persisted state.
func (s *Service) acpHoldSocket(sessionID string) string {
	sum := sha256.Sum256([]byte(sessionID))
	name := hex.EncodeToString(sum[:8]) + ".sock"
	if s.ACPHoldDir != "" {
		if path := filepath.Join(s.ACPHoldDir, name); len(path) <= unixSocketPathLimit {
			return path
		}
	}
	return filepath.Join(os.TempDir(), fmt.Sprintf("warren-acp-%d", os.Getuid()), name)
}

// startACPHold launches the agent in a new holder and attaches to it.
func (s *Service) startACPHold(ctx context.Context, sessionID string, options acp.LaunchOptions) (*acp.Held, error) {
	socket := s.acpHoldSocket(sessionID)
	// A live holder here belongs to an agent this Host could not take back;
	// end it rather than orphaning it behind the new one.
	if stale, err := acp.Attach(ctx, socket, sessionID); err == nil {
		stale.Close()
	}
	spec := acp.HoldSpec{Socket: socket, Key: sessionID, Launch: options}
	var err error
	if len(s.ACPHoldCommand) > 0 {
		err = acp.SpawnHold(ctx, s.ACPHoldCommand, spec)
	} else {
		err = acp.StartHold(ctx, spec)
	}
	if err != nil {
		return nil, err
	}
	held, err := acp.Attach(ctx, socket, sessionID)
	if err != nil {
		return nil, fmt.Errorf("attach to agent holder: %w", err)
	}
	return held, nil
}

// acpHeldState is what the Host keeps in the holder to resume without asking
// the agent again: its initialize answer and the current selectors.
type acpHeldState struct {
	Initialize acp.InitializeResponse `json:"initialize"`
	Config     []acpHeldConfigOption  `json:"config,omitempty"`
}

type acpHeldConfigOption struct {
	ID           string                  `json:"id"`
	Name         string                  `json:"name"`
	Description  string                  `json:"description,omitempty"`
	Category     string                  `json:"category,omitempty"`
	CurrentValue string                  `json:"currentValue"`
	Choices      []acp.ConfigOptionValue `json:"choices,omitempty"`
	ViaMode      bool                    `json:"viaMode,omitempty"`
}

// saveHeldStateLocked stores the state a restarted Host needs in the holder.
func (handle *acpAgentHandle) saveHeldStateLocked() {
	if handle.proc == nil {
		return
	}
	state := acpHeldState{Initialize: handle.initResult}
	for _, option := range handle.config {
		state.Config = append(state.Config, acpHeldConfigOption{
			ID: option.id, Name: option.name, Description: option.description, Category: option.category,
			CurrentValue: option.currentValue, Choices: option.choices, ViaMode: option.viaMode,
		})
	}
	encoded, err := json.Marshal(state)
	if err != nil {
		return
	}
	handle.proc.SetState(encoded)
}

// interactionIDLocked derives an interaction id from the agent's request id,
// so a request delivered again after a Host restart keeps the id its card was
// journaled under.
func (handle *acpAgentHandle) interactionIDLocked(requestID json.RawMessage) string {
	sum := sha256.Sum256(requestID)
	return "acp-perm-" + handle.holdID + "-" + hex.EncodeToString(sum[:6])
}

// reattach takes back an agent whose holder outlived the previous Host. When
// the journal's open turn is the prompt the agent is still answering, the
// turn is adopted and reported as running; reattach returns whether it was.
func (handle *acpAgentHandle) reattach(ctx context.Context, turn api.AgentTurn) bool {
	attachContext, cancel := context.WithTimeout(ctx, acpReattachTimeout)
	defer cancel()
	held, err := acp.Attach(attachContext, handle.service.acpHoldSocket(handle.sessionID), handle.sessionID)
	if err != nil {
		if errors.Is(err, acp.ErrHoldMismatch) {
			handle.service.logWarn("acp holder mismatch; the agent will start again", "session", handle.sessionID, "error", err)
		}
		return false
	}
	info := held.Info()
	var state acpHeldState
	if len(info.State) == 0 || json.Unmarshal(info.State, &state) != nil || state.Initialize.ProtocolVersion != acp.ProtocolVersion {
		// The previous Host never finished initializing this agent.
		held.Close()
		return false
	}
	var promptID json.RawMessage
	for _, open := range info.Open {
		if open.Method == acp.MethodSessionPrompt {
			promptID = open.ID
		}
	}
	adopt := promptID != nil && turn.ID > 0 && turn.Status == api.AgentTurnStarted

	handle.emitMu.Lock()
	defer handle.emitMu.Unlock()
	handle.mu.Lock()
	if handle.closed {
		handle.mu.Unlock()
		held.Detach()
		return false
	}
	handle.initResult = state.Initialize
	handle.holdID = info.ID
	handle.config = handle.config[:0]
	for _, option := range state.Config {
		handle.config = append(handle.config, acpConfigOption{
			id: option.ID, name: option.Name, description: option.Description, category: option.Category,
			currentValue: option.CurrentValue, choices: option.Choices, viaMode: option.ViaMode,
		})
	}
	// The journal already holds this snapshot.
	if encoded, err := json.Marshal(acpConfigPayload(handle.config)); err == nil {
		handle.configEmitted = string(encoded)
	}
	var open []json.RawMessage
	var promptContext context.Context
	if adopt {
		open = []json.RawMessage{promptID}
		handle.turn = turn.ID
		handle.promptActive = true
		handle.promptDone = make(chan struct{})
		promptContext, handle.promptCancel = context.WithCancel(context.Background())
		handle.streamEpoch = "~" + held.Info().ID
	}
	// Report the turn as running before the connection delivers anything, so
	// a permission request delivered again can block it.
	if adopt {
		emitAgentStatus(handle.sink, api.AgentStatus{Activity: api.AgentActivityWorking})
	}
	conn := acp.NewResumedConn(held.Stdout(), held.Stdin(), handle, info.NextID, open)
	handle.proc, handle.conn = held, conn
	handle.mu.Unlock()
	go handle.watchExit(held, conn)
	if adopt {
		go func() {
			var response acp.PromptResponse
			err := conn.Await(promptContext, promptID, &response)
			handle.finishTurn(turn.ID, response, err)
		}()
	}
	handle.service.logInfo("acp agent reattached", "session", handle.sessionID, "pid", info.PID, "adoptedTurn", adopt)
	return adopt
}
