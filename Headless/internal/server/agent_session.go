package server

import (
	"context"
	"fmt"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/agent"
	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/store"
)

type agentSession struct {
	mu      sync.Mutex
	watcher *agent.Watcher
	// handle is the provider-owned lifecycle object. watcher/tailer remain
	// populated for compatibility with existing tests and the legacy PTY path.
	handle       AgentHandle
	bindingKey   string
	providerKind string
	handlerKind  string
	capabilities CapabilitySet
	// tailer is non-nil only for OpenCode. It owns the read-only projection
	// from the provider's SQLite store into watcher.Path().
	tailer *agent.OpenCodeTailer
	// executionID is the Host-owned identity for this provider conversation.
	// canonicalEvents is an in-memory read-through projection used when an
	// embedder does not configure AgentStore; production Headless persists the
	// same rows in AgentStore before broadcasting them.
	executionID        string
	canonicalEvents    []api.CanonicalAgentEvent
	events             []api.AgentEvent
	status             api.AgentStatus
	turn               api.AgentTurn
	pendingTurnRequest *pendingAgentTurnRequest
	// titleUser and titleAssistant retain only the first real text messages
	// needed for one automatic title suggestion. They are intentionally kept
	// separate from the public transcript projection.
	titleUser              string
	titleUserProvider      string
	titleUserID            string
	titleAssistant         string
	titleAssistantProvider string
	titleAssistantID       string
	titleAssistantComplete bool
	titleGenerationStarted bool
	// hookStateModTime prevents a durable provider hook observation from being
	// re-applied over newer transcript state on every reconcile tick. Hook
	// writes use an atomic rename, so the state file's modification time is a
	// stable change token for one observation.
	hookStateModTime time.Time
	// lastFind throttles transcript discovery while a CLI has not written a
	// transcript yet, so reconcile does not walk the whole CLI directory tree
	// on every one-second tick.
	lastFind time.Time
	// pendingCorrelations binds a client's commandId to the text the Host
	// actually injected into the provider. A provider writes the user message
	// into its own transcript with its own identity, so this is the only way a
	// client can tell which timeline row is the message it just sent. FIFO: a
	// CLI consumes injected input in order. Guarded by mu.
	pendingCorrelations []pendingAgentCorrelation
}

// pendingAgentCorrelation is one outgoing message awaiting its transcript echo.
// text is what the Host injected, which is not always what the client typed:
// an empty prompt is replaced, and attachments rewrite the body.
type pendingAgentCorrelation struct {
	commandID string
	text      string
	sentAt    time.Time
}

// agentCorrelationTTL bounds how long an unmatched outgoing message keeps
// waiting for its echo. A provider that never writes the message (crashed CLI,
// discarded input) must not pin the entry or mislabel a much later message.
const agentCorrelationTTL = 60 * time.Second

// maxPendingAgentCorrelations bounds the table when a provider stops echoing
// entirely. Dropping the oldest keeps the newest messages correlatable.
const maxPendingAgentCorrelations = 64

// ensureAgent starts a transcript watcher for a running Codex/Claude session
// or for a plain shell/custom session that has a live Warren-managed agent
// binding (the user started the CLI manually inside the shell). The watcher
// is best-effort: no transcript yet, an unknown CLI layout, or a missing CLI
// must never make the terminal session fail.
func (s *Service) ensureAgent(ctx context.Context, session api.Session) (*agentSession, error) {
	state := s.Store.Snapshot()
	return s.ensureAgentWithState(ctx, session, &state)
}

// ensureAgentWithState reuses one mutable reconciliation snapshot across the
// running sessions. A deep Store snapshot is intentionally expensive, so the
// lifecycle loop must not take one for every session it inspects.
func (s *Service) ensureAgentWithState(ctx context.Context, session api.Session, state *api.State) (*agentSession, error) {
	if registry := s.agentProviderRegistry(); registry != nil {
		return s.ensureAgentWithRegistry(ctx, session, state, registry)
	}
	if provider := agentProviderForKind(session.Kind); provider != "" {
		s.persistAgentProviderWithState(state, session.ID, provider)
	} else if session.Kind == "shell" || session.Kind == "custom" {
		if binding, err := agent.ReadBinding(agent.BindPath(session.ID)); err == nil && binding != nil {
			s.persistAgentProviderWithState(state, session.ID, binding.Provider)
		}
	}
	dedicated := session.Kind == "codex" || session.Kind == "claude" || session.Kind == "opencode" || session.Kind == "pi" || session.Kind == "qoder" || session.Kind == "antigravity"
	shellOverlay := session.Kind == "shell" || session.Kind == "custom"
	if !dedicated && !shellOverlay {
		return nil, nil
	}
	if dedicated && s.AgentFinder == nil {
		return nil, nil
	}
	if session.Kind == "opencode" {
		s.openCodeBindingMu.Lock()
		defer s.openCodeBindingMu.Unlock()
	}
	// The execution identity is allocated only once a Session is known to be
	// agent-backed. It is independent from the provider conversation ID and is
	// the stream key used by the canonical journal.
	if strings.TrimSpace(session.AgentExecutionID) == "" {
		session.AgentExecutionID = s.ensureAgentExecutionID(state, session.ID, false)
	}

	workspacePath, pathErr := sessionWorkingDirectory(
		*state,
		session.WorkspaceID,
		session.TerminalGroupID,
	)
	if pathErr != nil {
		s.stopAgent(session.ID)
		return nil, nil
	}

	provider := session.Kind
	agentSessionID := session.AgentSessionID
	transcriptPath := ""
	var opencodeBinding *agent.OpenCodeBinding
	if dedicated {
		s.lazyInit()

		// Resolve the current binding before looking at the running watcher:
		// Codex starts a fresh rollout after `/clear`, so the SessionStart
		// hook can report a new session id and transcript path while the
		// daemon is still projecting the old file.
		if session.Kind == "opencode" {
			finder, ok := s.AgentFinder.(agent.BindingFinder)
			if !ok {
				return nil, nil
			}
			var err error
			openCodeSessionID := session.AgentSessionID
			if binding, bErr := agent.ReadBinding(agent.BindPath(session.ID)); bErr == nil && binding != nil && binding.Provider == "opencode" && binding.SessionID != "" {
				openCodeSessionID = binding.SessionID
			}
			if openCodeSessionID != "" {
				opencodeBinding, err = finder.FindBindingBySessionID(ctx, session.ID, workspacePath, openCodeSessionID)
				if err == nil && opencodeBinding == nil {
					// A live projection means the provider was already running in
					// this Warren process. If its row disappears while that process
					// is still alive, allow discovery to pick up an intentional CLI
					// restart; after a daemon restart there is no such signal, so a
					// missing durable ID remains unbound instead of guessing.
					s.agentsMu.Lock()
					entry := s.agents[session.ID]
					hasLiveProjection := entry != nil && entry.watcher != nil
					s.agentsMu.Unlock()
					if hasLiveProjection {
						opencodeBinding, err = s.findOpenCodeBinding(ctx, finder, session.ID, workspacePath, session.CreatedAt)
					}
				}
			} else {
				opencodeBinding, err = s.findOpenCodeBinding(ctx, finder, session.ID, workspacePath, session.CreatedAt)
			}
			if err != nil || opencodeBinding == nil || !opencodeBinding.Valid() {
				return nil, nil
			}
			if opencodeBinding.CachePath == "" {
				opencodeBinding.CachePath = agent.OpenCodeCachePath(session.ID, opencodeBinding.SessionID)
			}
			// Re-read the durable state after taking the binding lock. The caller's
			// reconciliation snapshot may predate another concurrent ensure call.
			if s.openCodeBindingTakenByOtherInState(s.Store.Snapshot(), opencodeBinding.SessionID, session.ID) {
				// A provider conversation cannot safely be assigned to two Warren
				// tabs. Leave this tab unbound until an explicit binding is available
				// instead of leaking another tab's transcript into it.
				return nil, nil
			}
			agentSessionID = opencodeBinding.SessionID
			transcriptPath = opencodeBinding.CachePath
		} else if session.Kind == "pi" {
			// Pi reports its own session id and transcript path through the
			// binding extension on session_start, exactly like the Codex/Claude
			// hooks report their CLI's conversation. Warren launches pi without
			// an injected --session-id (that would make pi warn about a missing
			// history), so the extension's session id is the only stable anchor.
			// The JSONL may not be flushed until pi receives its first message;
			// the extension's target path is a second anchor once it appears.
			if binding, err := agent.ReadBinding(agent.BindPath(session.ID)); err == nil && binding != nil && binding.Provider == "pi" && binding.SessionID != "" {
				agentSessionID = binding.SessionID
				transcriptPath = agent.FindPiTranscript(binding.SessionID)
				if transcriptPath == "" && binding.TranscriptPath != "" {
					if info, statErr := os.Stat(binding.TranscriptPath); statErr == nil && !info.IsDir() {
						transcriptPath = binding.TranscriptPath
					}
				}
			} else if session.AgentSessionID != "" {
				agentSessionID = session.AgentSessionID
				transcriptPath = agent.FindPiTranscript(session.AgentSessionID)
				if transcriptPath == "" && session.TranscriptPath != "" {
					if info, statErr := os.Stat(session.TranscriptPath); statErr == nil && !info.IsDir() {
						transcriptPath = session.TranscriptPath
					}
				}
			}
		} else if session.Kind == "qoder" {
			// Warren injects a deterministic --session-id at launch, so the
			// SessionStart hook payload (session_id/transcript_path) and the
			// deterministic file path both anchor the same conversation. The
			// hook report wins when present; otherwise fall back to the
			// injected-id scan under ~/.qoder/projects.
			if binding, err := agent.ReadBinding(agent.BindPath(session.ID)); err == nil && binding != nil && binding.Provider == "qoder" && binding.SessionID != "" {
				agentSessionID = binding.SessionID
				transcriptPath = binding.TranscriptPath
				if transcriptPath == "" || !regularFileExists(transcriptPath) {
					transcriptPath = agent.FindQoderTranscript(binding.SessionID, workspacePath)
				}
			} else {
				agentSessionID = session.AgentSessionID
				transcriptPath = agent.FindQoderTranscript(session.AgentSessionID, workspacePath)
			}
		} else if session.Kind == "antigravity" {
			if binding, err := agent.ReadBinding(agent.BindPath(session.ID)); err == nil && binding != nil && binding.Provider == "antigravity" && binding.SessionID != "" {
				agentSessionID = binding.SessionID
				transcriptPath = binding.TranscriptPath
				if transcriptPath == "" || !regularFileExists(transcriptPath) {
					transcriptPath = agent.FindAntigravityTranscript(binding.SessionID, workspacePath)
				}
			} else if session.AgentSessionID != "" {
				agentSessionID = session.AgentSessionID
				transcriptPath = agent.FindAntigravityTranscript(session.AgentSessionID, workspacePath)
			}
		} else {
			transcriptPath = s.boundTranscript(session, workspacePath)
			if binding, err := agent.ReadBinding(agent.BindPath(session.ID)); err == nil && binding != nil {
				agentSessionID = binding.SessionID
			}
		}
		s.agentsMu.Lock()
		entry := s.agents[session.ID]
		if entry == nil {
			entry = &agentSession{}
			s.agents[session.ID] = entry
		}
		existingWatcher := entry.watcher
		if existingWatcher != nil && (session.Kind != "opencode" || entry.tailer != nil) {
			s.agentsMu.Unlock()
			if transcriptPath != "" && existingWatcher.Path() != transcriptPath {
				// Re-bind to the CLI's new transcript; startAgentWatcher
				// resets the stale projection before switching files.
				entry = s.startAgentWatcher(session.ID, provider, transcriptPath, false, opencodeBinding)
				s.persistAgentMetaWithState(state, session.ID, agentSessionID, transcriptPath)
				return entry, nil
			}
			return entry, nil
		}
		if time.Since(entry.lastFind) < 5*time.Second {
			s.agentsMu.Unlock()
			return entry, nil
		}
		entry.lastFind = time.Now()
		s.agentsMu.Unlock()

		if transcriptPath == "" {
			found, err := s.AgentFinder.Find(ctx, session.Kind, workspacePath, session.CreatedAt)
			if err != nil || found == "" || s.transcriptTakenByOtherInState(*state, found, session.ID) {
				// Keep the placeholder so reconcile retries at its next tick
				// instead of re-running discovery concurrently from every caller.
				return entry, nil
			}
			transcriptPath = found
		}
	} else {
		binding, err := agent.ReadBinding(agent.BindPath(session.ID))
		if err != nil || binding == nil || (binding.Provider != "codex" && binding.Provider != "claude" && binding.Provider != "opencode" && binding.Provider != "pi" && binding.Provider != "qoder" && binding.Provider != "antigravity") {
			s.clearShellAgentWithState(session, state)
			return nil, nil
		}
		agentState, stateErr := agent.ReadAgentState(agent.StatePath(session.ID))
		if stateErr == nil && agentState.Status.Activity == api.AgentActivityExited {
			// Codex emits SessionEnd when an individual thread runtime is
			// unloaded. Only a matching thread ID can end a shell overlay;
			// otherwise a late event from an older thread must be ignored.
			if binding.Provider != "codex" || agent.StateMatchesBinding(agentState, binding) {
				s.clearShellAgentWithState(session, state)
				return nil, nil
			}
		}
		if binding.Provider == "opencode" {
			// Shell overlay for OpenCode uses the same SQLite binding as dedicated
			// sessions. The plugin writes {provider:"opencode", sessionId} with
			// an empty transcriptPath; Host resolves the cache via the database.
			if s.AgentFinder == nil {
				return nil, nil
			}
			finder, ok := s.AgentFinder.(agent.BindingFinder)
			if !ok {
				return nil, nil
			}
			var err error
			opencodeBinding, err = finder.FindBindingBySessionID(ctx, session.ID, workspacePath, binding.SessionID)
			if err != nil || opencodeBinding == nil || !opencodeBinding.Valid() {
				// Fallback: derive cache path deterministically when DB lookup
				// races with session creation. The tailer will recover on next poll.
				opencodeBinding = &agent.OpenCodeBinding{
					Provider:     "opencode",
					SessionID:    binding.SessionID,
					Backend:      "sqlite",
					DatabasePath: agent.OpenCodeDatabasePath(agent.OpenCodeDataRoot("")),
					CachePath:    agent.OpenCodeCachePath(session.ID, binding.SessionID),
				}
				if !opencodeBinding.Valid() {
					return nil, nil
				}
			}
			if s.openCodeBindingTakenByOtherInState(*state, opencodeBinding.SessionID, session.ID) {
				return nil, nil
			}
			provider = binding.Provider
			agentSessionID = opencodeBinding.SessionID
			transcriptPath = opencodeBinding.CachePath
		} else if binding.Provider == "pi" {
			// Pi shell overlay: the extension writes {provider:"pi",
			// sessionId, transcriptPath} on session_start. Resolve the
			// transcript by the injected session id first; the file may not be
			// flushed until pi receives its first message, so the extension's
			// target path is a second anchor once it appears on disk.
			provider = binding.Provider
			agentSessionID = binding.SessionID
			transcriptPath = agent.FindPiTranscript(binding.SessionID)
			if transcriptPath == "" && binding.TranscriptPath != "" {
				if info, statErr := os.Stat(binding.TranscriptPath); statErr == nil && !info.IsDir() {
					transcriptPath = binding.TranscriptPath
				}
			}
			if transcriptPath == "" {
				return nil, nil
			}
		} else if binding.Provider == "qoder" {
			// Qoder shell overlay: the hook writes {provider:"qoder",
			// sessionId, transcriptPath} on SessionStart. Resolve by the
			// reported transcript first; the injected-id scan under
			// ~/.qoder/projects is a second anchor while the file flushes.
			provider = binding.Provider
			agentSessionID = binding.SessionID
			transcriptPath = binding.TranscriptPath
			if transcriptPath == "" || !regularFileExists(transcriptPath) {
				transcriptPath = agent.FindQoderTranscript(binding.SessionID, workspacePath)
			}
			if transcriptPath == "" {
				return nil, nil
			}
		} else if binding.Provider == "antigravity" {
			provider = binding.Provider
			agentSessionID = binding.SessionID
			transcriptPath = binding.TranscriptPath
			if transcriptPath == "" || !regularFileExists(transcriptPath) {
				transcriptPath = agent.FindAntigravityTranscript(binding.SessionID, workspacePath)
			}
			if transcriptPath == "" {
				return nil, nil
			}
		} else {
			info, statErr := os.Stat(binding.TranscriptPath)
			if statErr != nil || info.IsDir() {
				return nil, nil
			}
			if s.transcriptTakenByOtherInState(*state, binding.TranscriptPath, session.ID) {
				return nil, nil
			}
			provider = binding.Provider
			agentSessionID = binding.SessionID
			transcriptPath = binding.TranscriptPath
		}
	}

	entry := s.startAgentWatcher(session.ID, provider, transcriptPath, !dedicated, opencodeBinding)
	s.persistAgentMetaWithState(state, session.ID, agentSessionID, transcriptPath)
	return entry, nil
}

// startAgentWatcher starts (or reuses) the transcript watcher for one
// session. For shell overlays the ready state is seeded immediately so the
// roster shows a live agent even before the first transcript event arrives.
func (s *Service) startAgentWatcher(sessionID, provider, transcriptPath string, seedReady bool, opencodeBinding *agent.OpenCodeBinding) *agentSession {
	s.lazyInit()
	// Rebinding a provider conversation always starts a fresh execution stream;
	// otherwise retain the persisted identity across daemon restarts.
	s.agentsMu.Lock()
	existingBefore := s.agents[sessionID]
	reuse := false
	if existingBefore != nil && existingBefore.watcher != nil && existingBefore.watcher.Path() == transcriptPath {
		reuse = provider != "opencode" || existingBefore.tailer != nil
	}
	s.agentsMu.Unlock()
	rebinding := existingBefore != nil && existingBefore.watcher != nil && !reuse
	executionID := s.ensureAgentExecutionID(nil, sessionID, rebinding)
	s.agentsMu.Lock()
	existing := s.agents[sessionID]
	state, _ := agent.ReadAgentState(agent.StatePath(sessionID))
	if existing != nil && existing.watcher != nil && existing.watcher.Path() == transcriptPath &&
		(provider != "opencode" || existing.tailer != nil) {
		if seedReady && state.Status.Activity != api.AgentActivityExited {
			existing.mu.Lock()
			if existing.status.Activity == api.AgentActivityExited {
				existing.status = api.AgentStatus{Activity: api.AgentActivityReady}
			}
			existing.mu.Unlock()
		}
		s.agentsMu.Unlock()
		return existing
	}
	rebinding = existing != nil && existing.watcher != nil
	var closing *agent.Watcher
	var closingTailer *agent.OpenCodeTailer
	if rebinding {
		closing = existing.watcher
		closingTailer = existing.tailer
		existing.watcher = nil
		existing.tailer = nil
		existing.mu.Lock()
		existing.events = nil
		existing.canonicalEvents = nil
		existing.executionID = executionID
		existing.status = api.AgentStatus{}
		existing.turn = api.AgentTurn{}
		existing.titleUser = ""
		existing.titleUserProvider = ""
		existing.titleUserID = ""
		existing.titleAssistant = ""
		existing.titleAssistantProvider = ""
		existing.titleAssistantID = ""
		existing.titleAssistantComplete = false
		existing.titleGenerationStarted = false
		existing.hookStateModTime = time.Time{}
		existing.mu.Unlock()
	} else if existing != nil {
		existing.mu.Lock()
		existing.status = api.AgentStatus{}
		existing.hookStateModTime = time.Time{}
		existing.mu.Unlock()
	}
	if existing == nil {
		existing = &agentSession{}
		s.agents[sessionID] = existing
	}
	if existing.executionID == "" {
		existing.executionID = executionID
	}
	if seedReady {
		existing.mu.Lock()
		if existing.status.Activity == "" || existing.status.Activity == api.AgentActivityExited {
			existing.status = api.AgentStatus{Activity: api.AgentActivityReady}
		}
		existing.mu.Unlock()
	}
	applyExitedState := state.Status.Activity == api.AgentActivityExited
	if provider == "codex" {
		// A dedicated Codex TUI owns several thread runtimes. Its
		// SessionEnd hook is therefore not a process-exit signal. Shell
		// overlays still accept a matching end event so they can fall back
		// to the plain terminal when the current CLI exits.
		applyExitedState = seedReady && agentStateMatchesBinding(sessionID, state)
	}
	if applyExitedState {
		existing.mu.Lock()
		existing.status = state.Status
		existing.mu.Unlock()
	}
	s.agentsMu.Unlock()
	if rebinding {
		// A session switch (e.g. `/clear` or `/new`) starts a fresh projection:
		// reset the custom title so a new one can be generated for the fresh conversation,
		// bump the epoch so attached clients drop the old transcript's events,
		// and notify all peers.
		_ = s.Store.Update(func(value *api.State) error {
			for index := range value.Sessions {
				if value.Sessions[index].ID == sessionID {
					value.Sessions[index].CustomTitle = ""
				}
			}
			return nil
		})
		s.bumpAgentEpoch()
		s.bumpAgentRosterRevision()
	}
	var tailer *agent.OpenCodeTailer
	if provider == "opencode" {
		if opencodeBinding == nil {
			if closing != nil {
				closing.Close()
			}
			if closingTailer != nil {
				closingTailer.Close()
			}
			return existing
		}
		var err error
		tailer, err = agent.StartOpenCodeSessionTailer(*opencodeBinding)
		if err != nil {
			s.logWarn("start OpenCode tailer", "session", sessionID, "error", err)
			if closing != nil {
				closing.Close()
			}
			if closingTailer != nil {
				closingTailer.Close()
			}
			return existing
		}
	}
	watcher := agent.Start(
		sessionID,
		provider,
		transcriptPath,
		func(events []api.AgentEvent, status api.AgentStatus) {
			s.recordAgentEvents(sessionID, events, status)
		},
		func(status api.AgentStatus) {
			s.recordAgentStatus(sessionID, status)
		},
		func(turns []api.AgentTurn, replay bool) {
			s.recordAgentTurns(sessionID, turns, !replay || s.hasAgentPeers(sessionID))
		},
	)
	// Agent discovery is complete only after the watcher has replayed the
	// initial transcript. Waiting here makes ensureAgent's return contract
	// deterministic for callers that immediately request canonical history;
	// a missing or unreadable transcript still releases ready promptly because
	// the watcher closes its ready channel after the best-effort first poll.
	_ = watcher.WaitReady(context.Background())
	s.agentsMu.Lock()
	current := s.agents[sessionID]
	if current == nil || current.watcher != nil {
		s.agentsMu.Unlock()
		if tailer != nil {
			tailer.Close()
		}
		if closing != nil {
			closing.Close()
		}
		if closingTailer != nil {
			closingTailer.Close()
		}
		watcher.Close()
		return current
	}
	current.watcher = watcher
	current.tailer = tailer
	s.agentsMu.Unlock()
	s.bumpAgentRosterRevision()
	if closing != nil {
		closing.Close()
	}
	if closingTailer != nil {
		closingTailer.Close()
	}
	return current
}

// clearShellAgentWithState tears down a shell overlay after its agent CLI
// exited and drops the persisted binding so clients stop treating the tab as
// an agent.
func (s *Service) clearShellAgentWithState(session api.Session, state *api.State) {
	if session.Kind == "codex" || session.Kind == "claude" || session.Kind == "opencode" || session.Kind == "pi" || session.Kind == "qoder" {
		return
	}
	s.agentsMu.Lock()
	entry := s.agents[session.ID]
	s.agentsMu.Unlock()
	hasWatcher := entry != nil && entry.watcher != nil
	if !hasWatcher && session.AgentSessionID == "" && session.TranscriptPath == "" && session.AgentProvider == "" {
		return
	}
	s.stopAgent(session.ID)
	if err := s.Store.Update(func(value *api.State) error {
		for index := range value.Sessions {
			if value.Sessions[index].ID == session.ID {
				value.Sessions[index].AgentSessionID = ""
				value.Sessions[index].TranscriptPath = ""
				value.Sessions[index].AgentProvider = ""
			}
		}
		return nil
	}); err != nil {
		return
	}
	for index := range state.Sessions {
		if state.Sessions[index].ID == session.ID {
			state.Sessions[index].AgentSessionID = ""
			state.Sessions[index].TranscriptPath = ""
			state.Sessions[index].AgentProvider = ""
			return
		}
	}
}

func (s *Service) openCodeBindingTakenByOtherInState(state api.State, openCodeSessionID, sessionID string) bool {
	for _, other := range state.Sessions {
		if other.ID != sessionID && other.Lifecycle == "running" && other.Kind == "opencode" && other.AgentSessionID == openCodeSessionID {
			return true
		}
	}
	return false
}

// findOpenCodeBinding chooses the first provider conversation that is not
// already claimed by another running Warren session. DefaultFinder exposes all
// matching rows so concurrent launches in one workspace can make progress;
// third-party finders retain the original single-binding behavior.
func (s *Service) findOpenCodeBinding(
	ctx context.Context,
	finder agent.BindingFinder,
	warrenSessionID, workspacePath string,
	after time.Time,
) (*agent.OpenCodeBinding, error) {
	if candidatesFinder, ok := finder.(agent.BindingCandidatesFinder); ok {
		candidates, err := candidatesFinder.FindBindings(ctx, warrenSessionID, "opencode", workspacePath, after)
		if err != nil {
			return nil, err
		}
		state := s.Store.Snapshot()
		for _, candidate := range candidates {
			if candidate == nil || !candidate.Valid() || s.openCodeBindingTakenByOtherInState(state, candidate.SessionID, warrenSessionID) {
				continue
			}
			return candidate, nil
		}
		return nil, nil
	}

	binding, err := finder.FindBinding(ctx, warrenSessionID, "opencode", workspacePath, after)
	if err != nil || binding == nil || !binding.Valid() {
		return binding, err
	}
	if s.openCodeBindingTakenByOtherInState(s.Store.Snapshot(), binding.SessionID, warrenSessionID) {
		return nil, nil
	}
	return binding, nil
}

// transcriptTakenByOtherInState prevents the cwd+mtime fallback from
// assigning one transcript to several Warren sessions. A transcript that
// another running session already projects must never be stolen.
func (s *Service) transcriptTakenByOtherInState(state api.State, transcriptPath, sessionID string) bool {
	for _, other := range state.Sessions {
		if other.ID != sessionID && other.Lifecycle == "running" && other.TranscriptPath == transcriptPath {
			return true
		}
	}
	return false
}

// boundTranscript prefers the deterministic per-session binding (Claude's
// injected session ID and the Codex hook's report) over cwd+mtime scanning.
func (s *Service) boundTranscript(session api.Session, workspacePath string) string {
	binding, err := agent.ReadBinding(agent.BindPath(session.ID))
	if err == nil && binding != nil && binding.Provider == session.Kind {
		if info, statErr := os.Stat(binding.TranscriptPath); statErr == nil && !info.IsDir() {
			return binding.TranscriptPath
		}
		if session.Kind == "claude" && binding.SessionID != "" {
			path := agent.ClaudeTranscriptPath(agent.ClaudeProjectsRoot(), workspacePath, binding.SessionID)
			if info, statErr := os.Stat(path); statErr == nil && !info.IsDir() {
				return path
			}
		}
	}
	// A Session moved between a Workspace and a Terminal Group keeps its old
	// transcript: the persisted path outlives cwd-based discovery and is the
	// only anchor that still points at the CLI's rollout after the move.
	if session.TranscriptPath != "" {
		if info, err := os.Stat(session.TranscriptPath); err == nil && !info.IsDir() {
			return session.TranscriptPath
		}
	}
	if session.Kind == "claude" && session.AgentSessionID != "" {
		path := agent.ClaudeTranscriptPath(agent.ClaudeProjectsRoot(), workspacePath, session.AgentSessionID)
		if info, err := os.Stat(path); err == nil && !info.IsDir() {
			return path
		}
	}
	return ""
}

// persistAgentMetaWithState records the CLI session ID and transcript path on
// the Session so roster consumers and a daemon restart keep the exact binding.
func (s *Service) persistAgentMetaWithState(state *api.State, sessionID, agentSessionID, transcriptPath string) {
	for index := range state.Sessions {
		session := &state.Sessions[index]
		if session.ID != sessionID {
			continue
		}
		if session.AgentSessionID == agentSessionID && session.TranscriptPath == transcriptPath {
			return
		}
		if err := s.Store.Update(func(value *api.State) error {
			for index := range value.Sessions {
				if value.Sessions[index].ID == sessionID {
					value.Sessions[index].AgentSessionID = agentSessionID
					value.Sessions[index].TranscriptPath = transcriptPath
				}
			}
			return nil
		}); err != nil {
			return
		}
		session.AgentSessionID = agentSessionID
		session.TranscriptPath = transcriptPath
		return
	}
}

// persistAgentProviderWithState stores the provider family as soon as a
// binding is observed. This keeps the next roster snapshot self-describing
// even when the provider handle has not finished starting yet.
func (s *Service) persistAgentProviderWithState(state *api.State, sessionID, provider string) {
	provider = agentProviderForKind(provider)
	if s == nil || s.Store == nil || state == nil || provider == "" || strings.TrimSpace(sessionID) == "" {
		return
	}
	for index := range state.Sessions {
		session := &state.Sessions[index]
		if session.ID != sessionID {
			continue
		}
		if agentProviderForKind(session.AgentProvider) == provider {
			return
		}
		if err := s.Store.Update(func(value *api.State) error {
			for index := range value.Sessions {
				if value.Sessions[index].ID == sessionID {
					value.Sessions[index].AgentProvider = provider
				}
			}
			return nil
		}); err != nil {
			return
		}
		session.AgentProvider = provider
		return
	}
}

// ensureAgentExecutionID returns the durable Host-owned execution identity for
// a Session. force starts a new execution stream when a provider conversation
// is replaced; the old stream remains immutable in the journal.
func (s *Service) ensureAgentExecutionID(state *api.State, sessionID string, force bool) string {
	if s == nil || strings.TrimSpace(sessionID) == "" {
		return ""
	}
	var current string
	if state != nil {
		for _, session := range state.Sessions {
			if session.ID == sessionID {
				current = strings.TrimSpace(session.AgentExecutionID)
				break
			}
		}
	}
	if current == "" && s.Store != nil {
		for _, session := range s.Store.Snapshot().Sessions {
			if session.ID == sessionID {
				current = strings.TrimSpace(session.AgentExecutionID)
				break
			}
		}
	}
	if current != "" && !force {
		return current
	}
	id := store.NewID()
	if s.Store == nil {
		return id
	}
	if err := s.Store.Update(func(value *api.State) error {
		for index := range value.Sessions {
			if value.Sessions[index].ID == sessionID {
				value.Sessions[index].AgentExecutionID = id
				return nil
			}
		}
		return fmt.Errorf("session not found: %s", sessionID)
	}); err != nil {
		return current
	}
	if state != nil {
		for index := range state.Sessions {
			if state.Sessions[index].ID == sessionID {
				state.Sessions[index].AgentExecutionID = id
				break
			}
		}
	}
	return id
}

// canonicalExecutionID returns the Host-owned stream identity for one active
// Agent session. Embedded Services without a durable State store still get a
// process-local identity so their event reducer follows the same contract.
func (s *Service) canonicalExecutionID(sessionID string) string {
	if strings.TrimSpace(sessionID) == "" {
		return ""
	}
	s.lazyInit()
	s.agentsMu.Lock()
	entry := s.agents[sessionID]
	if entry == nil {
		entry = &agentSession{}
		s.agents[sessionID] = entry
	}
	entry.mu.Lock()
	executionID := strings.TrimSpace(entry.executionID)
	entry.mu.Unlock()
	s.agentsMu.Unlock()
	if executionID != "" {
		return executionID
	}
	if s.Store != nil {
		executionID = s.ensureAgentExecutionID(nil, sessionID, false)
	} else {
		executionID = store.NewID()
	}
	s.agentsMu.Lock()
	entry = s.agents[sessionID]
	if entry == nil {
		entry = &agentSession{}
		s.agents[sessionID] = entry
	}
	entry.mu.Lock()
	if entry.executionID == "" {
		entry.executionID = executionID
	}
	executionID = entry.executionID
	entry.mu.Unlock()
	s.agentsMu.Unlock()
	return executionID
}
