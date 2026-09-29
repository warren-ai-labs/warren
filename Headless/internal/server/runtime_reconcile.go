package server

import (
	"context"
	"log/slog"
	"strings"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/runtime"
	"github.com/abcdlsj/warren/Headless/internal/settings"
)

// metadataLoop refreshes the foreground metadata cache independently of the
// roster broadcast loop. A slow or stalled probe delays only the cache, never
// roster snapshots, so updates cannot pile up behind OS-level metadata work.
func (s *Service) metadataLoop(ctx context.Context) {
	ticker := time.NewTicker(metadataRefreshInterval)
	defer ticker.Stop()
	s.refreshMetadata(ctx)
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			s.refreshMetadata(ctx)
		}
	}
}

func (s *Service) refreshMetadata(ctx context.Context) {
	probeContext, cancel := context.WithTimeout(ctx, metadataProbeTimeout)
	defer cancel()
	running := make(map[string]bool)
	for _, session := range s.Store.Snapshot().Sessions {
		if session.Lifecycle != "running" {
			continue
		}
		running[session.ID] = true
		if session.Kind == sessionKindBrowser || isACPSession(session) {
			// A browser has no foreground process to probe. Its live state is
			// read through the browser API, not through a PTY runtime.
			s.metadataCache.remove(session.ID)
			continue
		}
		provider, ok := s.runtimeFor(session).(runtime.RuntimeMetadataProvider)
		if !ok {
			s.metadataCache.remove(session.ID)
			continue
		}
		metadata, err := provider.Metadata(probeContext, session.Runtime)
		if err != nil {
			continue
		}
		s.metadataCache.set(session.ID, metadata)
	}
	s.metadataCache.prune(running)
}

func (s *Service) reconcile(ctx context.Context) {
	probeContext, cancel := context.WithTimeout(context.WithoutCancel(ctx), 2*time.Second)
	defer cancel()
	running := s.runningSessions(probeContext)
	state := s.Store.Snapshot()
	seenSessions := make(map[string]struct{}, len(state.Sessions))
	for _, session := range state.Sessions {
		if session.Lifecycle != "running" {
			s.stopOutput(session.ID, false)
			s.stopAgent(session.ID)
			continue
		}
		seenSessions[session.ID] = struct{}{}
		if session.Kind == sessionKindBrowser {
			// A browser Session has no Ghostline runtime to probe. Its liveness
			// is whether the manager still holds a Chromium for it, which only
			// the daemon that started it can know.
			if manager := s.browserManagerIfPresent(); manager == nil {
				s.markEnded(session.ID)
			} else if _, running := manager.Session(session.ID); !running {
				s.markEnded(session.ID)
			}
			continue
		}
		if isACPSession(session) {
			// The Session is durable and its agent process is disposable: the
			// handle restarts it on the next prompt (RFC 0023 §5.5).
			_, _ = s.ensureAgentWithState(probeContext, session, &state)
			continue
		}
		if session.RuntimeKind != "" && session.RuntimeKind != settings.RuntimeGhostline {
			// Preserve ownership metadata for removed runtimes. Do not silently
			// reassign or mark such sessions ended during reconciliation.
			s.logWarn("session uses unsupported runtime", "session", session.ID, "runtimeKind", session.RuntimeKind)
			continue
		}
		adopted, changed := s.adoptRuntimeKind(probeContext, session)
		if changed {
			s.persistRuntimeKind(adopted)
		}
		probe := running(adopted)
		if probe.State == RuntimeProbeUnknown {
			// A runtime outage is a loss of knowledge, not evidence of process
			// death. Keep the durable Session and its output ownership intact.
			s.warnRuntimeProbe(session, probe)
			continue
		}
		if probe.State == RuntimeProbeDead {
			// A healthy list can race with a just-created/adopted runtime. Confirm
			// the negative result with the adapter before ending the Session; an
			// unknown confirmation remains non-destructive.
			adapter := s.runtimeFor(adopted)
			if _, canConfirm := adapter.(RuntimeProber); canConfirm {
				confirmation := s.probeRuntime(probeContext, adapter, adopted.Runtime)
				if confirmation.State == RuntimeProbeUnknown {
					s.warnRuntimeProbe(session, confirmation)
					continue
				}
				if confirmation.State == RuntimeProbeAlive {
					// The direct confirmation is authoritative for this race; keep
					// the Session running and continue with normal reconciliation.
				} else {
					s.markEnded(session.ID)
					continue
				}
			} else {
				s.markEnded(session.ID)
				continue
			}
		}
		_, _ = s.ensureOutput(ctx, session)
		s.seedRuntimeSize(probeContext, adopted)
		s.applyAgentState(session)
		_, _ = s.ensureAgentWithState(probeContext, session, &state)
	}
	s.stopMissingAgents(seenSessions)
	// Pane Groups follow Session liveness. A Session that ended while the daemon
	// was down, or one whose owner was removed, is pruned here; the write only
	// happens when an arrangement actually changed, so a steady Host does not
	// rewrite state.json once per tick.
	outdated := s.Store.Snapshot()
	if reconcilePaneGroups(&outdated) {
		_ = s.Store.Update(func(value *api.State) error {
			reconcilePaneGroups(value)
			return nil
		})
	}
}

// stopMissingAgents closes provider handles whose Session was deleted from
// the durable roster. Without this sweep a forced Session delete could leave
// a transcript watcher alive forever because no future reconcile visits its
// old ID.
func (s *Service) stopMissingAgents(seen map[string]struct{}) {
	s.lazyInit()
	var stale []string
	s.agentsMu.Lock()
	for sessionID := range s.agents {
		if _, ok := seen[sessionID]; !ok {
			stale = append(stale, sessionID)
		}
	}
	s.agentsMu.Unlock()
	for _, sessionID := range stale {
		s.stopAgent(sessionID)
	}
}

func (s *Service) warnRuntimeProbe(session api.Session, result RuntimeProbeResult) {
	key := session.ID + "|" + result.Evidence
	now := time.Now()
	s.runtimeProbeMu.Lock()
	if s.runtimeProbeLog == nil {
		s.runtimeProbeLog = make(map[string]time.Time)
	}
	last := s.runtimeProbeLog[key]
	if !last.IsZero() && now.Sub(last) < runtimeProbeWarningInterval {
		s.runtimeProbeMu.Unlock()
		return
	}
	s.runtimeProbeLog[key] = now
	s.runtimeProbeMu.Unlock()
	s.logWarn("runtime probe unavailable; preserving session", "session", session.ID, "runtime", session.Runtime, "evidence", result.Evidence, "error", result.Err)
}

// adoptRuntimeKind assigns Ghostline to legacy sessions created before
// sessions recorded runtimeKind.
func (s *Service) adoptRuntimeKind(ctx context.Context, session api.Session) (api.Session, bool) {
	if session.RuntimeKind != "" {
		return session, false
	}
	if adapter := s.Runtimes[settings.RuntimeGhostline]; adapter != nil && s.probeRuntime(ctx, adapter, session.Runtime).State == RuntimeProbeAlive {
		session.RuntimeKind = settings.RuntimeGhostline
		return session, true
	}
	return session, false
}

func (s *Service) probeRuntime(ctx context.Context, adapter Runtime, name string) RuntimeProbeResult {
	if adapter == nil {
		return RuntimeProbeResult{State: RuntimeProbeUnknown, Evidence: "adapter_unavailable"}
	}
	if prober, ok := adapter.(RuntimeProber); ok {
		result := prober.Probe(ctx, name)
		switch result.State {
		case RuntimeProbeAlive, RuntimeProbeDead, RuntimeProbeUnknown:
			return result
		default:
			return RuntimeProbeResult{
				State:    RuntimeProbeUnknown,
				Evidence: "invalid_probe_state",
				Err:      result.Err,
			}
		}
	}
	// Compatibility adapters only expose Exists. Preserve their historical
	// behavior, but keep the fallback isolated so production adapters can no
	// longer collapse transport errors into a destructive false result.
	if adapter.Exists(ctx, name) {
		return RuntimeProbeResult{State: RuntimeProbeAlive, Evidence: "legacy_exists"}
	}
	return RuntimeProbeResult{State: RuntimeProbeDead, Evidence: "legacy_not_exists"}
}

func (s *Service) persistRuntimeKind(session api.Session) {
	_ = s.Store.Update(func(value *api.State) error {
		for i := range value.Sessions {
			if value.Sessions[i].ID == session.ID && value.Sessions[i].RuntimeKind == "" {
				value.Sessions[i].RuntimeKind = session.RuntimeKind
			}
		}
		return nil
	})
}

// reapOrphans kills runtimes that are explicitly recorded in state and no
// longer running. Unknown runtimes are deliberately left alone: a daemon can
// be pointed at a shared runtime socket with a new, empty, or unrelated state
// file, and that state must never grant permission to terminate its sessions.
func (s *Service) reapOrphans(ctx context.Context) {
	probeContext, cancel := context.WithTimeout(context.WithoutCancel(ctx), 2*time.Second)
	defer cancel()
	createdByRuntime := make(map[string]map[string]time.Time)
	for kind, adapter := range s.Runtimes {
		lister, ok := adapter.(RuntimeCreatedLister)
		if !ok {
			continue
		}
		created, err := lister.ListCreated(probeContext)
		if err != nil {
			continue
		}
		createdByRuntime[kind] = created
	}
	if len(createdByRuntime) == 0 && s.Runtime != nil {
		// Compatibility path: constructions that only set Runtime manage a
		// single engine under the empty kind.
		if lister, ok := s.Runtime.(RuntimeCreatedLister); ok {
			if created, err := lister.ListCreated(probeContext); err == nil {
				createdByRuntime[""] = created
			}
		}
	}
	managed := make(map[string]bool)
	ended := make(map[string]bool)
	for _, session := range s.Store.Snapshot().Sessions {
		if session.Runtime == "" {
			continue
		}
		if session.Lifecycle == "running" {
			managed[session.Runtime] = true
		} else if session.Lifecycle == "ended" && session.EndedAt != nil {
			// A timestamp is the minimum durable provenance for an ended
			// Session. Legacy records without it are protected until an
			// explicit operator migration establishes ownership evidence.
			ended[session.Runtime] = true
		}
	}
	now := time.Now()
	for kind, created := range createdByRuntime {
		adapter := s.Runtimes[kind]
		if adapter == nil {
			adapter = s.Runtime
		}
		for name, createdAt := range created {
			if managed[name] || !ended[name] || !isWarrenRuntimeName(name) || now.Sub(createdAt) < orphanReapGrace {
				if isWarrenRuntimeName(name) && !managed[name] && !ended[name] {
					s.warnUnknownRuntime(name, kind)
				}
				continue
			}
			if err := adapter.Kill(probeContext, name); err != nil {
				continue
			}
		}
	}
}

func (s *Service) warnUnknownRuntime(name, kind string) {
	logger := s.Logger
	if logger == nil {
		logger = slog.Default()
	}
	logger.Warn("skipping unknown runtime during orphan reap", "runtime", name, "kind", kind)
}

func isWarrenRuntimeName(name string) bool {
	return strings.HasPrefix(name, "warren_") || strings.HasPrefix(name, "warren-")
}

type runtimeListResult struct {
	sessions map[string]bool
	state    RuntimeProbeState
	err      error
}

func (s *Service) runningSessions(ctx context.Context) func(api.Session) RuntimeProbeResult {
	lists := make(map[string]runtimeListResult)
	for kind, adapter := range s.Runtimes {
		if lister, ok := adapter.(RuntimeLister); ok {
			sessions, err := lister.List(ctx)
			if err != nil {
				lists[kind] = runtimeListResult{state: RuntimeProbeUnknown, err: err}
				continue
			}
			lists[kind] = runtimeListResult{sessions: sessions, state: RuntimeProbeAlive}
		}
	}
	if len(lists) == 0 && s.Runtime != nil {
		if lister, ok := s.Runtime.(RuntimeLister); ok {
			sessions, err := lister.List(ctx)
			if err != nil {
				lists[""] = runtimeListResult{state: RuntimeProbeUnknown, err: err}
			} else {
				lists[""] = runtimeListResult{sessions: sessions, state: RuntimeProbeAlive}
			}
		}
	}
	return func(session api.Session) RuntimeProbeResult {
		kind := s.runtimeKindFor(session)
		if listed, ok := lists[kind]; ok {
			if listed.state == RuntimeProbeUnknown {
				return RuntimeProbeResult{State: RuntimeProbeUnknown, Evidence: "list_failed", Err: listed.err}
			}
			if listed.sessions[session.Runtime] {
				return RuntimeProbeResult{State: RuntimeProbeAlive, Evidence: "healthy_list"}
			}
			return RuntimeProbeResult{State: RuntimeProbeDead, Evidence: "healthy_list_missing"}
		}
		// Compatibility constructions often set only Runtime while the
		// default kind is "ghostline". Reuse the untyped list only when there
		// is no explicit runtime registry; never let a different kind's list
		// decide this Session's lifecycle.
		if kind != "" && len(s.Runtimes) == 0 {
			if listed, ok := lists[""]; ok {
				if listed.state == RuntimeProbeUnknown {
					return RuntimeProbeResult{State: RuntimeProbeUnknown, Evidence: "list_failed", Err: listed.err}
				}
				if listed.sessions[session.Runtime] {
					return RuntimeProbeResult{State: RuntimeProbeAlive, Evidence: "healthy_legacy_list"}
				}
				return RuntimeProbeResult{State: RuntimeProbeDead, Evidence: "healthy_legacy_list_missing"}
			}
		}
		adapter := s.runtimeFor(session)
		return s.probeRuntime(ctx, adapter, session.Runtime)
	}
}
