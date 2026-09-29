package server

import (
	"context"
	"sort"
	"strings"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/agent"
	"github.com/abcdlsj/warren/Headless/internal/api"
)

func (s *Service) Roster(ctx context.Context) api.State {
	state, _ := s.RosterVersion(ctx)
	return state
}

// agentProviderForRoster resolves only durable/binding metadata. It must not
// wait for the lifecycle reconciler: roster consumers need a stable provider
// identity during the short window after a Host restart or execution rebind.
func (s *Service) agentProviderForRoster(session api.Session) string {
	// Shell/custom Sessions can change provider without changing their Warren
	// kind. Resolve the live binding first so a stale persisted provider from a
	// previous CLI cannot win when the binding is available. The persisted
	// provider remains a short-lived startup fallback: binding files are written
	// atomically by hooks and can be briefly unreadable while the Host is
	// rehydrating after restart.
	shellOverlay := session.Kind == "shell" || session.Kind == "custom"
	if shellOverlay && strings.TrimSpace(session.ID) != "" {
		if binding, err := agent.ReadBinding(agent.BindPath(session.ID)); err == nil && binding != nil {
			if provider := agentProviderForKind(binding.Provider); provider != "" {
				return provider
			}
		}
		if provider := agentProviderForKind(session.AgentProvider); provider != "" {
			return provider
		}
	}
	if !shellOverlay {
		if provider := agentProviderForKind(session.AgentProvider); provider != "" {
			return provider
		}
	}
	if provider := agentProviderForKind(session.Kind); provider != "" {
		return provider
	}
	if s != nil {
		s.lazyInit()
		s.agentsMu.Lock()
		entry := s.agents[session.ID]
		s.agentsMu.Unlock()
		if entry != nil {
			entry.mu.Lock()
			provider := agentProviderForKind(entry.providerKind)
			entry.mu.Unlock()
			if provider != "" {
				return provider
			}
		}
	}
	return ""
}

func (s *Service) RosterVersion(_ context.Context) (api.State, uint64) {
	startedAt := time.Now()
	// Roster projection is observer-facing and may run independently for every
	// connected client. Keep runtime probes and Session lifecycle mutations in
	// the single lifecycle loop so additional observers cannot multiply process
	// launches, runtime RPCs, or Session writes.
	state, revision := s.Store.SnapshotVersion()
	storeElapsed := time.Since(startedAt)
	for index := range state.Tasks {
		state.Tasks[index].CreationRequestID = ""
		state.Tasks[index].CreationRequestHash = ""
	}
	for index := range state.Workspaces {
		state.Workspaces[index].CreationRequestID = ""
		state.Workspaces[index].CreationRequestHash = ""
	}
	// Store revisions begin at zero, while an omitted JSON field means an old
	// server did not support revisioned roster snapshots. Offset the opaque
	// wire token so every current snapshot carries a non-zero revision without
	// persisting it into State.
	state.Revision = revision + 1
	if agentRevision := s.agentRosterRevision.Load(); agentRevision > state.Revision {
		state.Revision = agentRevision
	}
	sortTasks(state.Tasks)
	sortProjects(state.Projects)
	sortWorkspaces(state.Workspaces)
	sortTerminalGroups(state.TerminalGroups)
	// Filter out ended sessions from the roster to reduce payload size and
	// present only active resources. Frontend already filters by lifecycle,
	// so this optimization improves network efficiency without changing semantics.
	state.Sessions = filter(state.Sessions, func(session api.Session) bool {
		return session.Lifecycle != "ended"
	})
	s.initMergeState()
	mergeStates := s.mergeCache.snapshot()
	for i := range state.Workspaces {
		if mergeState, ok := mergeStates[state.Workspaces[i].ID]; ok {
			state.Workspaces[i].MergeState = mergeState
		}
	}
	if s.mergeDirty.Load() || time.Since(time.Unix(0, s.mergeLastRefresh.Load())) > mergeRefreshInterval {
		s.wakeMergeRefresh()
	}
	sort.Slice(state.Sessions, func(i, j int) bool {
		if state.Sessions[i].Pinned != state.Sessions[j].Pinned {
			return state.Sessions[i].Pinned
		}
		return state.Sessions[i].CreatedAt.Before(state.Sessions[j].CreatedAt)
	})
	// A Session's projected directory is the shell-reported pwd when OSC 7 has
	// reported one, otherwise the directory Warren launched it in. Resolving the
	// fallback here keeps every client from re-deriving it, and avoids the
	// filesystem check the create path performs.
	workspacePaths := make(map[string]string, len(state.Workspaces))
	for _, workspace := range state.Workspaces {
		workspacePaths[workspace.ID] = workspace.Path
	}
	groupHomes := make(map[string]string, len(state.TerminalGroups))
	for _, group := range state.TerminalGroups {
		groupHomes[group.ID] = group.Home
	}
	agentsStartedAt := time.Now()
	for i := range state.Sessions {
		session := &state.Sessions[i]
		session.OutputCursor = ""
		if session.Kind == "shell" || session.Kind == "custom" {
			// Shell overlays are binding-driven. Clear a stale persisted provider
			// from the public projection when its binding has disappeared; the
			// lifecycle loop will perform the durable cleanup as well.
			session.AgentProvider = s.agentProviderForRoster(*session)
		} else if provider := s.agentProviderForRoster(*session); provider != "" {
			// Project the binding directly in the roster. The lifecycle loop may
			// still be rehydrating the provider handle, but the client can bind
			// the Session to its correct icon and Agent surface immediately.
			session.AgentProvider = provider
		}
		session.AgentCapabilities = s.agentCapabilitiesForSession(session.ID, *session)
		if handler := s.agentHandlerForSession(session.ID); handler != "" {
			session.AgentHandler = handler
		}
		if session.Scope == "" {
			session.Scope = session.ScopeKind()
		}
		if session.Lifecycle != "running" {
			continue
		}
		if s.metadataCache != nil {
			if metadata, ok := s.metadataCache.get(session.ID); ok {
				session.Process = metadata.Process
				session.CommandLine = metadata.CommandLine
				session.Directory = metadata.Directory
			}
		}
		if session.Directory == "" {
			session.Directory = sessionLaunchDirectory(*session, workspacePaths, groupHomes)
		}
		if status := s.agentStatus(session.ID); status.Activity != "" {
			session.AgentStatus = &status
		} else if session.Kind == "codex" || session.Kind == "claude" || session.Kind == "opencode" || session.Kind == "pi" || session.Kind == "qoder" || session.Kind == "antigravity" {
			session.AgentStatus = &api.AgentStatus{Activity: api.AgentActivityReady}
		}
		if turn := s.agentTurn(session.ID); turn.ID > 0 {
			session.AgentTurn = &turn
		}
	}
	if elapsed := time.Since(startedAt); elapsed >= slowRosterThreshold {
		s.logInfo(
			"slow roster snapshot",
			"duration", elapsed,
			"store", storeElapsed,
			"agents", time.Since(agentsStartedAt),
			"projects", len(state.Projects),
			"workspaces", len(state.Workspaces),
			"sessions", len(state.Sessions),
		)
	}
	return state, revision
}

func sortTasks(tasks []api.Task) {
	sort.Slice(tasks, func(i, j int) bool {
		if tasks[i].Pinned != tasks[j].Pinned {
			return tasks[i].Pinned
		}
		if tasks[i].Order != tasks[j].Order {
			return tasks[i].Order < tasks[j].Order
		}
		if tasks[i].Name != tasks[j].Name {
			return tasks[i].Name < tasks[j].Name
		}
		return tasks[i].CreatedAt.Before(tasks[j].CreatedAt)
	})
}

func sortProjects(projects []api.Project) {
	sort.Slice(projects, func(i, j int) bool {
		if projects[i].Pinned != projects[j].Pinned {
			return projects[i].Pinned
		}
		if projects[i].Order != projects[j].Order {
			return projects[i].Order < projects[j].Order
		}
		if projects[i].Name != projects[j].Name {
			return projects[i].Name < projects[j].Name
		}
		return projects[i].CreatedAt.Before(projects[j].CreatedAt)
	})
}

func sortWorkspaces(workspaces []api.Workspace) {
	sort.Slice(workspaces, func(i, j int) bool {
		if workspaces[i].Pinned != workspaces[j].Pinned {
			return workspaces[i].Pinned
		}
		if workspaces[i].ProjectID != workspaces[j].ProjectID {
			return workspaces[i].ProjectID < workspaces[j].ProjectID
		}
		if workspaces[i].Order != workspaces[j].Order {
			return workspaces[i].Order < workspaces[j].Order
		}
		if workspaces[i].CreatedAt != workspaces[j].CreatedAt {
			return workspaces[i].CreatedAt.Before(workspaces[j].CreatedAt)
		}
		return workspaces[i].ID < workspaces[j].ID
	})
}

func sortTerminalGroups(groups []api.TerminalGroup) {
	sort.Slice(groups, func(i, j int) bool {
		if groups[i].Order != groups[j].Order {
			return groups[i].Order < groups[j].Order
		}
		if groups[i].CreatedAt != groups[j].CreatedAt {
			return groups[i].CreatedAt.Before(groups[j].CreatedAt)
		}
		return groups[i].ID < groups[j].ID
	})
}
