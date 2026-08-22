package server

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/abcdlsj/ghostline"
	"github.com/abcdlsj/warren/Headless/internal/agent"
	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/git"
	"github.com/abcdlsj/warren/Headless/internal/output"
	"github.com/abcdlsj/warren/Headless/internal/runtime"
	"github.com/abcdlsj/warren/Headless/internal/settings"
	"github.com/abcdlsj/warren/Headless/internal/store"
	"github.com/abcdlsj/warren/Headless/internal/tunnel"
)

const (
	defaultRingCapacity     = 256
	defaultRingMaxBytes     = 8 * 1024 * 1024
	defaultMaxSpool         = 8 * 1024 * 1024
	defaultCommandTimeout   = 10 * time.Second
	broadcastLockWait       = 100 * time.Millisecond
	metadataRefreshInterval = 750 * time.Millisecond
	metadataProbeTimeout    = 2 * time.Second
	cursorPersistEvery      = 256 * 1024
	orphanReapInterval      = 30 * time.Second
	// agentMessageMaxBytes bounds one pushed agent batch so a large
	// transcript never produces a single WebSocket message that exceeds
	// client limits (URLSession's default maximumMessageSize is 1 MiB).
	agentMessageMaxBytes = 256 * 1024
	// agentAttachHistoryMaxEvents and agentAttachHistoryMaxBytes bound the
	// initial agent replay sent during attach. Clients that need the full
	// conversation fetch it page by page through agent.history.
	agentAttachHistoryMaxEvents = 64
	agentAttachHistoryMaxBytes  = 256 * 1024
	agentHistoryDefaultLimit    = 200
	agentHistoryMaxLimit        = 500
	// orphanReapGrace protects a session between tmux creation and its state
	// record becoming durable, so a concurrent reaper cannot kill a brand-new
	// runtime while CreateSession is still persisting it.
	// orphanReapGrace protects sessions across daemon upgrades: an install can
	// briefly overlap two daemons, and a legacy session must survive a slow
	// first reconcile instead of being reaped minutes after being marked
	// ended. Five minutes of grace is a safe trade-off for orphan cleanup.
	orphanReapGrace = 5 * time.Minute
	// operationAuditLimit keeps the durable safety log bounded. Only entries
	// with a compare-and-swap undo representation are retained.
	operationAuditLimit = 256
	// defaultWorktreeRoot is also the compatibility fallback used when an
	// embedded Service does not provide an explicit worktree root.
	defaultWorktreeRoot = "~/.warren/worktrees"
)

type Service struct {
	Store *store.Store
	// HostName is the Warren Host/system name used for the default gnar
	// account. It is injected by the daemon from --name/WARREN_HOST_NAME;
	// embedded callers may leave it empty and use os.Hostname as a fallback.
	HostName string
	// Runtime is the adapter for DefaultRuntime, kept for compatibility with
	// existing construction sites and tests.
	Runtime Runtime
	// Runtimes maps runtime kind ("ghostline", "tmux") to its adapter.
	Runtimes map[string]Runtime
	// DefaultRuntime is the engine used for sessions created without an
	// explicit kind.
	DefaultRuntime string
	// Settings holds the persisted headless settings (default runtime and
	// runtime environment overrides) and is returned by the settings API.
	Settings settings.Settings
	// SettingsPath persists settings changes made over the API.
	SettingsPath string
	// panelCache lazily caches git panel snapshots per workspace so multiple
	// clients share one snapshot instead of each loading git state itself.
	panelCache     *panelCache
	panelLoad      *panelLoad
	panelCacheOnce sync.Once
	// Logger receives lifecycle warnings. A nil logger falls back to slog's
	// process-wide default so tests and embedders do not need to configure one.
	Logger *slog.Logger
	// ColorQuery supplies terminal foreground and background colors for
	// capability queries answered while no client is attached.
	ColorQuery   ghostline.ColorQueryCallback
	WorktreeRoot string
	// AgentFinder locates Codex/Claude transcript files. When nil, agent
	// projection is disabled and sessions behave exactly as before.
	AgentFinder agent.Finder
	// AgentHooks installs the Warren-managed Codex hook that reports the
	// CLI session ID and transcript path. Nil disables installation; the
	// finder then remains the best-effort fallback.
	AgentHooks    func() error
	MaxSpoolBytes int64
	// MaxSpoolReplayBytes bounds raw spool replay during attach. Gaps larger
	// than this fall back to a screen-resetting snapshot reanchor instead of
	// feeding tens of megabytes of raw bytes to the client's terminal. Zero
	// uses the in-memory ring byte limit.
	MaxSpoolReplayBytes int64
	RingCapacity        int
	RingMaxBytes        int
	// CommandTimeout bounds tmux commands run during attach and adoption. A
	// stuck tmux client must fail the attach and release the session broadcast
	// lock and paused output watcher instead of wedging the session until the
	// daemon restarts.
	CommandTimeout time.Duration
	// ProbeForeground enables live foreground process metadata from runtime
	// adapters that support it. Disabled by default so roster snapshots stay
	// cheap; clients fall back to launch command and workspace path.
	ProbeForeground bool
	// ClientsActive reports whether any client can observe roster snapshots.
	// The merge projection only refreshes while clients are connected; nil
	// means "always active" for tests and embedders.
	ClientsActive func() bool

	metadataCache    *metadataCache
	mergeOnce        sync.Once
	mergeCache       *mergeStateCache
	mergeWake        chan struct{}
	mergeDirty       atomic.Bool
	mergeLastRefresh atomic.Int64

	outputMu sync.Mutex
	// terminalGroupLifecycleMu serializes Group deletion with Group Session
	// creation. Runtime creation and its durable Session record must observe
	// the same Group snapshot, otherwise a concurrent forced deletion can
	// leave an orphan runtime or a Session whose Group no longer exists.
	terminalGroupLifecycleMu sync.Mutex
	// workspaceLifecycleMu protects the lazily-created per-project lifecycle
	// locks. A project write lock serializes workspace/project lifecycle changes;
	// workspace session creation takes a read lock so independent workspaces in
	// the same project do not serialize their runtime startup.
	workspaceLifecycleMu  sync.Mutex
	projectLifecycleLocks map[string]*sync.RWMutex
	gitMutationMu         sync.Mutex
	gitMutationLocks      map[string]*sync.Mutex
	outputs               map[string]*outputSession
	peers                 map[string]map[*wsPeer]struct{}
	agentPeers            map[string]map[*wsPeer]struct{}
	focusedPeers          map[string]*wsPeer
	runtimeSizes          map[string]ghostline.Size
	broadcastLocks        map[string]*sessionLock
	agentsMu              sync.Mutex
	agents                map[string]*agentSession
	agentEpoch            uint64

	lifecycleOnce   sync.Once
	lifecycleCancel context.CancelFunc
}

type outputSession struct {
	mu                sync.Mutex
	sessionID         string
	runtimeName       string
	runtimeKind       string
	ring              *output.Ring
	watcher           *ghostline.SpoolWatcher
	responder         *ghostline.QueryResponder
	prepareLock       *sessionLock
	persistedSequence uint64
	reanchorRequired  bool
}

type agentSession struct {
	mu      sync.Mutex
	watcher *agent.Watcher
	events  []api.AgentEvent
	status  api.AgentStatus
	turn    api.AgentTurn
	// lastFind throttles transcript discovery while a CLI has not written a
	// transcript yet, so reconcile does not walk the whole CLI directory tree
	// on every one-second tick.
	lastFind time.Time
}

type Runtime interface {
	Create(context.Context, string, string, string, []string) error
	Exists(context.Context, string) bool
	Capture(context.Context, string) ([]byte, error)
	Input(context.Context, string, []byte) error
	Resize(context.Context, string, int, int) error
	Kill(context.Context, string) error
}

// SpoolRecoverer serves raw spool bytes when the in-memory ring no longer
// retains a client's anchor. The ghostline adapter implements it through the
// session handle; the tmux adapter does not.
type SpoolRecoverer interface {
	Recover(context.Context, string, int64, int64) ([]byte, error)
}

type RuntimeLister interface {
	List(context.Context) (map[string]bool, error)
}

// RuntimeCreatedLister is implemented by the tmux adapter and lets the
// lifecycle loop reclaim sessions that are no longer tracked in state.
type RuntimeCreatedLister interface {
	ListCreated(context.Context) (map[string]time.Time, error)
}

// OutputRuntime is implemented by the tmux adapter: pipe-pane installs an
// idempotent raw byte pipe and the service owns one SpoolWatcher per session.
type OutputRuntime interface {
	Runtime
	EnsurePipe(context.Context, string) error
	SpoolPath(string) string
	SpoolSize(context.Context, string) (int64, error)
	TruncateSpool(context.Context, string) error
	ArchiveSpool(context.Context, string) error
	RemoveSpool(string)
}

// runtimeKindFor resolves the engine for a session, falling back to the
// daemon default. Runtime selection is a headless-side decision.
func (s *Service) runtimeKindFor(session api.Session) string {
	if session.RuntimeKind != "" {
		return session.RuntimeKind
	}
	if s.DefaultRuntime != "" {
		return s.DefaultRuntime
	}
	return settings.DefaultRuntimeKind
}

// runtimeFor resolves the adapter that owns a session.
func (s *Service) runtimeFor(session api.Session) Runtime {
	return s.runtimeForKind(s.runtimeKindFor(session))
}

func (s *Service) runtimeForKind(kind string) Runtime {
	if adapter := s.Runtimes[kind]; adapter != nil {
		return adapter
	}
	return s.Runtime
}

func (s *Service) outputAdapterFor(session api.Session) OutputRuntime {
	adapter, _ := s.runtimeFor(session).(OutputRuntime)
	return adapter
}

func (s *Service) newQueryResponder() *ghostline.QueryResponder {
	return ghostline.NewQueryResponderWithColorQuery(s.ColorQuery)
}

func (s *Service) lazyInit() {
	s.outputMu.Lock()
	defer s.outputMu.Unlock()
	s.lazyInitLocked()
}

func (s *Service) lazyInitLocked() {
	if s.outputs == nil {
		s.outputs = map[string]*outputSession{}
	}
	if s.peers == nil {
		s.peers = map[string]map[*wsPeer]struct{}{}
	}
	if s.agentPeers == nil {
		s.agentPeers = map[string]map[*wsPeer]struct{}{}
	}
	if s.focusedPeers == nil {
		s.focusedPeers = map[string]*wsPeer{}
	}
	if s.runtimeSizes == nil {
		s.runtimeSizes = map[string]ghostline.Size{}
	}
	if s.broadcastLocks == nil {
		s.broadcastLocks = map[string]*sessionLock{}
	}
	if s.agents == nil {
		s.agents = map[string]*agentSession{}
	}
	if s.agentEpoch == 0 {
		s.agentEpoch = uint64(time.Now().UnixNano())
	}
	if s.metadataCache == nil {
		s.metadataCache = &metadataCache{}
	}
}

// initMergeState initializes the merge projection fields exactly once. Every
// reader and writer enters through it so lazy initialization can never race
// with roster snapshots or the background merge loop.
func (s *Service) initMergeState() {
	s.mergeOnce.Do(func() {
		if s.mergeCache == nil {
			s.mergeCache = &mergeStateCache{}
		}
		if s.mergeWake == nil {
			s.mergeWake = make(chan struct{}, 1)
		}
	})
}

// Start runs the single lifecycle watcher. One goroutine probes tmux for all
// managed sessions; it never creates a polling task per Session.
func (s *Service) Start(parent context.Context) {
	s.lifecycleOnce.Do(func() {
		s.lazyInit()
		s.migrateLegacyWorktreeOwnership()
		s.initMergeState()
		if installAgentHooks := s.AgentHooks; installAgentHooks != nil {
			// Best-effort: the managed hook makes Codex binding precise, but
			// an unwritable config directory must not stop the daemon; the
			// finder fallback still works. Hook installation touches user
			// configuration files, so it must not delay daemon readiness.
			go func() {
				if err := installAgentHooks(); err != nil {
					s.logWarn("install agent hooks", "error", err)
				}
			}()
		}
		ctx, cancel := context.WithCancel(context.WithoutCancel(parent))
		s.lifecycleCancel = cancel
		go s.lifecycleLoop(ctx)
		go s.mergeLoop(ctx)
		if s.ProbeForeground {
			go s.metadataLoop(ctx)
		}
	})
}

// migrateLegacyWorktreeOwnership upgrades workspace records written before
// ManagedWorktree was persisted. Only paths below Warren's configured
// worktree root are adopted; imported checkouts elsewhere remain user-owned.
// The marker makes the migration idempotent and prevents a later restart from
// reclassifying a newly imported checkout that happens to live below that
// root.
func (s *Service) migrateLegacyWorktreeOwnership() {
	if s.Store == nil {
		return
	}
	state := s.Store.Snapshot()
	if state.WorktreeOwnershipMigrated {
		return
	}
	root := strings.TrimSpace(s.WorktreeRoot)
	if root == "" {
		root = defaultWorktreeRoot
	}
	root = resolvePath(expandHome(root))
	if root == "" || root == "." {
		return
	}

	legacyCandidates := make(map[string]struct{})
	for _, workspace := range state.Workspaces {
		if workspace.Kind == "worktree" && !workspace.ManagedWorktree &&
			!samePath(root, workspace.Path) && pathWithin(root, workspace.Path) {
			legacyCandidates[workspace.ID] = struct{}{}
		}
	}
	migrated := 0
	err := s.Store.Update(func(value *api.State) error {
		if value.WorktreeOwnershipMigrated {
			return nil
		}
		for index := range value.Workspaces {
			workspace := &value.Workspaces[index]
			if _, ok := legacyCandidates[workspace.ID]; !ok {
				continue
			}
			workspace.ManagedWorktree = true
			migrated++
		}
		value.WorktreeOwnershipMigrated = true
		return nil
	})
	if err != nil {
		s.logWarn("migrate legacy worktree ownership", "error", err)
		return
	}
	if migrated > 0 {
		logger := s.Logger
		if logger == nil {
			logger = slog.Default()
		}
		logger.Info("migrated legacy Warren worktree ownership", "count", migrated, "root", root)
	}
}

func (s *Service) Shutdown() {
	if s.lifecycleCancel != nil {
		s.lifecycleCancel()
	}
	s.outputMu.Lock()
	outputs := make([]*outputSession, 0, len(s.outputs))
	for _, outputSession := range s.outputs {
		outputs = append(outputs, outputSession)
	}
	s.outputMu.Unlock()
	for _, outputSession := range outputs {
		outputSession.watcher.Close()
		outputSession.mu.Lock()
		_ = s.persistCursorLocked(outputSession)
		outputSession.mu.Unlock()
	}
	s.agentsMu.Lock()
	agents := make([]*agentSession, 0, len(s.agents))
	for _, agentSession := range s.agents {
		agents = append(agents, agentSession)
	}
	s.agentsMu.Unlock()
	for _, agentSession := range agents {
		if agentSession.watcher != nil {
			agentSession.watcher.Close()
		}
	}
}

func (s *Service) lifecycleLoop(ctx context.Context) {
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	reaper := time.NewTicker(orphanReapInterval)
	defer reaper.Stop()
	s.reconcile(ctx)
	s.reapOrphans(ctx)
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			s.reconcile(ctx)
		case <-reaper.C:
			s.reapOrphans(ctx)
		}
	}
}

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
	for _, session := range s.Store.Snapshot().Sessions {
		if session.Lifecycle != "running" {
			s.stopOutput(session.ID, false)
			continue
		}
		adopted, changed := s.adoptRuntimeKind(probeContext, session)
		if changed {
			s.persistRuntimeKind(adopted)
		}
		if !running(adopted) && !s.anyRuntimeOwns(probeContext, adopted) {
			s.markEnded(session.ID)
			continue
		}
		_, _ = s.ensureOutput(ctx, session)
		s.applyAgentState(session)
		_, _ = s.ensureAgent(probeContext, session)
	}
}

// adoptRuntimeKind assigns a definitive engine to a legacy session created
// before sessions recorded runtimeKind. Whichever registered runtime still
// owns the session name wins, so old tmux sessions survive a default-runtime
// switch instead of being mistaken for ghostline ones (or vice versa).
func (s *Service) adoptRuntimeKind(ctx context.Context, session api.Session) (api.Session, bool) {
	if session.RuntimeKind != "" {
		return session, false
	}
	// Legacy sessions predate runtimeKind; tmux was the only engine then, so
	// check it first and deterministically instead of ranging over a map.
	if tmuxAdapter := s.Runtimes[settings.RuntimeTmux]; tmuxAdapter != nil && tmuxAdapter.Exists(ctx, session.Runtime) {
		session.RuntimeKind = settings.RuntimeTmux
		return session, true
	}
	for kind, adapter := range s.Runtimes {
		if adapter != nil && adapter.Exists(ctx, session.Runtime) {
			session.RuntimeKind = kind
			return session, true
		}
	}
	return session, false
}

// anyRuntimeOwns is a second, direct existence check used when the cached
// runningSessions probe failed for a session. A transient probe failure must
// not end a live session: ending it would let the orphan reaper kill the
// underlying process minutes later.
func (s *Service) anyRuntimeOwns(ctx context.Context, session api.Session) bool {
	for _, adapter := range s.Runtimes {
		if adapter != nil && adapter.Exists(ctx, session.Runtime) {
			return true
		}
	}
	return false
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
		} else {
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
			if output, ok := adapter.(OutputRuntime); ok {
				output.RemoveSpool(name)
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

func (s *Service) Roster(ctx context.Context) api.State {
	state, _ := s.RosterVersion(ctx)
	return state
}

func (s *Service) RosterVersion(ctx context.Context) (api.State, uint64) {
	s.migrateLegacyWorktreeOwnership()
	state, revision := s.Store.SnapshotVersion()
	changed := false
	now := time.Now().UTC()
	// A roster request can be cancelled when a WebSocket disconnects. That
	// cancellation says nothing about the tmux process: using the cancelled
	// request context for the probe makes List fail and Exists return false,
	// which incorrectly ends a session that was just created or is still alive.
	// Keep the probe independent of the observer lifecycle, but bounded so a
	// broken runtime cannot hold roster reconciliation forever.
	probeContext, cancel := context.WithTimeout(context.WithoutCancel(ctx), 2*time.Second)
	defer cancel()
	running := s.runningSessions(probeContext)
	for i := range state.Sessions {
		adopted, _ := s.adoptRuntimeKind(probeContext, state.Sessions[i])
		if adopted.RuntimeKind != "" && state.Sessions[i].RuntimeKind == "" {
			state.Sessions[i].RuntimeKind = adopted.RuntimeKind
		}
		if state.Sessions[i].Lifecycle == "running" && !running(adopted) {
			state.Sessions[i].Lifecycle = "ended"
			state.Sessions[i].EndedAt = &now
			changed = true
		}
	}
	if changed {
		ended := make(map[string]time.Time)
		for _, session := range state.Sessions {
			if session.EndedAt != nil {
				ended[session.ID] = *session.EndedAt
			}
		}
		_ = s.Store.Update(func(value *api.State) error {
			for index := range value.Sessions {
				if endedAt, ok := ended[value.Sessions[index].ID]; ok && value.Sessions[index].Lifecycle == "running" {
					value.Sessions[index].Lifecycle = "ended"
					value.Sessions[index].EndedAt = &endedAt
				}
			}
			return nil
		})
		for sessionID := range ended {
			s.stopOutput(sessionID, true)
		}
		state, revision = s.Store.SnapshotVersion()
	}
	sortProjects(state.Projects)
	sortWorkspaces(state.Workspaces)
	sortTerminalGroups(state.TerminalGroups)
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
	for i := range state.Sessions {
		session := &state.Sessions[i]
		if session.Scope == "" {
			session.Scope = session.ScopeKind()
		}
		if session.Lifecycle != "running" {
			continue
		}
		if s.ProbeForeground && s.metadataCache != nil {
			if metadata, ok := s.metadataCache.get(session.ID); ok {
				session.Process = metadata.Process
				session.Directory = metadata.Directory
			}
		}
		if status := s.agentStatus(session.ID); status.Activity != "" {
			session.AgentStatus = &status
		} else if session.Kind == "codex" || session.Kind == "claude" {
			session.AgentStatus = &api.AgentStatus{Activity: api.AgentActivityReady}
		}
	}
	return state, revision
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

func (s *Service) runningSessions(ctx context.Context) func(api.Session) bool {
	lists := make(map[string]map[string]bool)
	for kind, adapter := range s.Runtimes {
		if lister, ok := adapter.(RuntimeLister); ok {
			if sessions, err := lister.List(ctx); err == nil {
				lists[kind] = sessions
			}
		}
	}
	if len(lists) == 0 && s.Runtime != nil {
		if lister, ok := s.Runtime.(RuntimeLister); ok {
			if sessions, err := lister.List(ctx); err == nil {
				lists[""] = sessions
			}
		}
	}
	return func(session api.Session) bool {
		kind := s.runtimeKindFor(session)
		if _, ok := lists[kind]; !ok {
			kind = ""
		}
		if sessions := lists[kind]; sessions != nil {
			return sessions[session.Runtime]
		}
		return s.runtimeFor(session).Exists(ctx, session.Runtime)
	}
}

func (s *Service) AddProject(path, name string) (api.Project, error) {
	return s.AddProjectWithOptions(path, name, false)
}

// AddProjectWithOptions adds a project and optionally imports every existing
// Git worktree for that project. The option is persisted on the Project, not
// in host-wide settings, so repositories can opt in independently.
func (s *Service) AddProjectWithOptions(path, name string, autoImportGitWorktrees bool) (api.Project, error) {
	selected, err := filepath.Abs(expandHome(strings.TrimSpace(path)))
	if err != nil {
		return api.Project{}, err
	}
	info, err := os.Stat(selected)
	if err != nil || !info.IsDir() {
		return api.Project{}, fmt.Errorf("project path is not a directory: %s", selected)
	}
	worktrees, err := listGitWorktrees(selected)
	if err != nil {
		return api.Project{}, fmt.Errorf("project is not a Git repository: %s: %w", selected, err)
	}
	createdAt := time.Now().UTC()
	project := api.Project{
		ID:                     store.NewID(),
		Path:                   filepath.Clean(worktrees[0].Path),
		AutoImportGitWorktrees: autoImportGitWorktrees,
		CreatedAt:              createdAt,
	}
	if name == "" {
		name = filepath.Base(project.Path)
	}
	project.Name = name
	workspaces, err := workspacesForGitWorktrees(
		project.ID,
		createdAt,
		worktrees,
		os.Stat,
		project.AutoImportGitWorktrees,
	)
	if err != nil {
		return api.Project{}, err
	}
	err = s.Store.Update(func(state *api.State) error {
		for _, value := range state.Projects {
			if samePath(value.Path, project.Path) {
				return fmt.Errorf("project already exists: %s", project.Path)
			}
		}
		project.Order = len(state.Projects)
		state.Projects = append(state.Projects, project)
		state.Workspaces = append(state.Workspaces, workspaces...)
		return nil
	})
	if err == nil {
		s.invalidateMerge()
	}
	return project, err
}

// ListProjectWorktrees returns existing external Git worktrees for a project.
// Already registered worktrees stay in the result so clients can render them
// disabled and explain that import is a one-time operation.
func (s *Service) ListProjectWorktrees(projectID string) ([]api.WorktreeCandidate, error) {
	state := s.Store.Snapshot()
	var project api.Project
	found := false
	for _, value := range state.Projects {
		if value.ID == projectID {
			project = value
			found = true
			break
		}
	}
	if !found {
		return nil, fmt.Errorf("project not found: %s", projectID)
	}
	return projectWorktreeCandidates(project, state.Workspaces)
}

// ImportProjectWorktrees registers selected existing Git worktrees as
// workspaces. It never creates, moves, or removes a checkout on disk.
func (s *Service) ImportProjectWorktrees(projectID string, paths []string) ([]api.Workspace, error) {
	state := s.Store.Snapshot()
	var project api.Project
	found := false
	for _, value := range state.Projects {
		if value.ID == projectID {
			project = value
			found = true
			break
		}
	}
	if !found {
		return nil, fmt.Errorf("project not found: %s", projectID)
	}
	candidates, err := projectWorktreeCandidates(project, state.Workspaces)
	if err != nil {
		return nil, err
	}
	requested := make(map[string]struct{}, len(paths))
	for _, path := range paths {
		path = filepath.Clean(strings.TrimSpace(path))
		if path != "." && path != "" {
			requested[normalizedPathKey(path)] = struct{}{}
		}
	}
	if len(requested) == 0 {
		return nil, errors.New("at least one worktree path is required")
	}

	selected := make([]api.WorktreeCandidate, 0, len(requested))
	for _, candidate := range candidates {
		if _, ok := requested[normalizedPathKey(candidate.Path)]; !ok {
			continue
		}
		if candidate.Imported {
			continue
		}
		selected = append(selected, candidate)
		delete(requested, normalizedPathKey(candidate.Path))
	}
	if len(requested) > 0 {
		return nil, fmt.Errorf("worktree is not an importable checkout: %s", firstMapKey(requested))
	}
	created := make([]api.Workspace, 0, len(selected))
	err = s.Store.Update(func(value *api.State) error {
		for _, candidate := range selected {
			duplicate := false
			for _, workspace := range value.Workspaces {
				if workspace.ProjectID == projectID && samePath(workspace.Path, candidate.Path) {
					duplicate = true
					break
				}
			}
			if duplicate {
				continue
			}
			workspace := api.Workspace{
				ID:             store.NewID(),
				ProjectID:      projectID,
				Name:           candidate.Name,
				Path:           filepath.Clean(candidate.Path),
				Branch:         candidate.Branch,
				Kind:           "worktree",
				WorktreeLocked: candidate.Locked,
				Order:          nextWorkspaceOrder(value.Workspaces, projectID),
				CreatedAt:      time.Now().UTC(),
			}
			if err := branchAlreadyHasWorkspace(value, projectID, workspace.Branch); err != nil {
				return err
			}
			value.Workspaces = append(value.Workspaces, workspace)
			created = append(created, workspace)
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	if len(created) > 0 {
		s.invalidateMerge()
	}
	return created, nil
}

// SetProjectAutoImportGitWorktrees changes one project's automatic import
// policy. Enabling it also imports currently visible external worktrees once;
// this is deliberately non-interactive and leaves imported checkouts on disk.
func (s *Service) SetProjectAutoImportGitWorktrees(projectID string, enabled bool) (api.Project, error) {
	state := s.Store.Snapshot()
	var project api.Project
	found := false
	for _, value := range state.Projects {
		if value.ID == projectID {
			project = value
			found = true
			break
		}
	}
	if !found {
		return api.Project{}, fmt.Errorf("project not found: %s", projectID)
	}
	project.AutoImportGitWorktrees = enabled
	if err := s.Store.Update(func(value *api.State) error {
		for index := range value.Projects {
			if value.Projects[index].ID == projectID {
				value.Projects[index].AutoImportGitWorktrees = enabled
				return nil
			}
		}
		return fmt.Errorf("project not found: %s", projectID)
	}); err != nil {
		return api.Project{}, err
	}
	if enabled {
		candidates, err := projectWorktreeCandidates(project, state.Workspaces)
		if err != nil {
			return api.Project{}, err
		}
		paths := make([]string, 0, len(candidates))
		for _, candidate := range candidates {
			if !candidate.Imported {
				paths = append(paths, candidate.Path)
			}
		}
		if len(paths) > 0 {
			if _, err := s.ImportProjectWorktrees(projectID, paths); err != nil {
				return api.Project{}, err
			}
		}
	}
	return project, nil
}

func projectWorktreeCandidates(project api.Project, workspaces []api.Workspace) ([]api.WorktreeCandidate, error) {
	worktrees, err := listGitWorktrees(project.Path)
	if err != nil {
		return nil, err
	}
	importedByPath := make(map[string]api.Workspace)
	for _, workspace := range workspaces {
		if workspace.ProjectID == project.ID {
			importedByPath[normalizedPathKey(workspace.Path)] = workspace
		}
	}
	candidates := make([]api.WorktreeCandidate, 0, len(worktrees))
	for _, worktree := range worktrees {
		path := filepath.Clean(worktree.Path)
		if worktree.Bare || samePath(path, project.Path) || worktree.Prunable {
			continue
		}
		info, err := os.Stat(path)
		if err != nil {
			if os.IsNotExist(err) {
				continue
			}
			return nil, fmt.Errorf("inspect Git worktree %s: %w", path, err)
		}
		if !info.IsDir() {
			continue
		}
		name := worktree.Branch
		if name == "" {
			name = filepath.Base(path)
		}
		candidate := api.WorktreeCandidate{
			Path:   path,
			Name:   name,
			Branch: worktree.Branch,
			Locked: worktree.Locked,
		}
		if workspace, ok := importedByPath[normalizedPathKey(path)]; ok {
			candidate.Imported = true
			candidate.WorkspaceID = workspace.ID
		}
		candidates = append(candidates, candidate)
	}
	return candidates, nil
}

func normalizedPathKey(path string) string {
	path = strings.TrimSpace(expandHome(path))
	if absolute, err := filepath.Abs(path); err == nil {
		path = absolute
	}
	if resolved, err := filepath.EvalSymlinks(path); err == nil {
		path = resolved
	}
	return filepath.Clean(path)
}

func firstMapKey(values map[string]struct{}) string {
	for value := range values {
		return value
	}
	return ""
}

// MoveProject moves one project before another project (or to the end when
// before is empty) and renumbers the stored sidebar order.
func (s *Service) MoveProject(id, before string) error {
	return s.Store.Update(func(state *api.State) error {
		sortProjects(state.Projects)
		index := -1
		for i := range state.Projects {
			if state.Projects[i].ID == id {
				index = i
				break
			}
		}
		if index < 0 {
			return fmt.Errorf("project not found: %s", id)
		}
		target := len(state.Projects)
		if before != "" {
			found := false
			for i := range state.Projects {
				if state.Projects[i].ID == before {
					target = i
					found = true
					break
				}
			}
			if !found {
				return fmt.Errorf("before project not found: %s", before)
			}
		}
		project := state.Projects[index]
		state.Projects = append(state.Projects[:index], state.Projects[index+1:]...)
		if index < target {
			target--
		}
		state.Projects = slices.Insert(state.Projects, target, project)
		for i := range state.Projects {
			state.Projects[i].Order = i
		}
		return nil
	})
}

// MoveWorkspace moves one workspace before another workspace inside the same
// project (or to the end when before is empty) and renumbers the stored
// per-project sidebar order.
func (s *Service) MoveWorkspace(id, before string) error {
	return s.Store.Update(func(state *api.State) error {
		sortWorkspaces(state.Workspaces)
		index := -1
		projectID := ""
		for i := range state.Workspaces {
			if state.Workspaces[i].ID == id {
				index = i
				projectID = state.Workspaces[i].ProjectID
				break
			}
		}
		if index < 0 {
			return fmt.Errorf("workspace not found: %s", id)
		}
		var ids []string
		for _, workspace := range state.Workspaces {
			if workspace.ProjectID == projectID {
				ids = append(ids, workspace.ID)
			}
		}
		target := len(ids)
		if before != "" {
			found := false
			for i, workspaceID := range ids {
				if workspaceID == before {
					target = i
					found = true
					break
				}
			}
			if !found {
				return fmt.Errorf("before workspace not found: %s", before)
			}
		}
		source := -1
		for i, workspaceID := range ids {
			if workspaceID == id {
				source = i
				break
			}
		}
		ids = append(ids[:source], ids[source+1:]...)
		if source < target {
			target--
		}
		ids = slices.Insert(ids, target, id)
		orders := make(map[string]int, len(ids))
		for i, workspaceID := range ids {
			orders[workspaceID] = i
		}
		for i := range state.Workspaces {
			if state.Workspaces[i].ProjectID == projectID {
				state.Workspaces[i].Order = orders[state.Workspaces[i].ID]
			}
		}
		return nil
	})
}

func (s *Service) CreateTerminalGroup(name, home string) (api.TerminalGroup, error) {
	name = strings.TrimSpace(name)
	if name == "" {
		name = "Terminal Group"
	}
	home, err := normalizeTerminalGroupHome(home)
	if err != nil {
		return api.TerminalGroup{}, err
	}
	group := api.TerminalGroup{
		ID:        store.NewID(),
		Name:      name,
		Home:      home,
		CreatedAt: time.Now().UTC(),
	}
	err = s.Store.Update(func(state *api.State) error {
		group.Order = len(state.TerminalGroups)
		state.TerminalGroups = append(state.TerminalGroups, group)
		return nil
	})
	return group, err
}

func (s *Service) RenameTerminalGroup(id, name string) error {
	name = strings.TrimSpace(name)
	if name == "" {
		return errors.New("terminal group name cannot be empty")
	}
	return s.Store.Update(func(state *api.State) error {
		for index := range state.TerminalGroups {
			if state.TerminalGroups[index].ID == id {
				state.TerminalGroups[index].Name = name
				return nil
			}
		}
		return fmt.Errorf("terminal group not found: %s", id)
	})
}

func (s *Service) SetTerminalGroupHome(id, home string) error {
	home, err := normalizeTerminalGroupHome(home)
	if err != nil {
		return err
	}
	return s.Store.Update(func(state *api.State) error {
		for index := range state.TerminalGroups {
			if state.TerminalGroups[index].ID == id {
				state.TerminalGroups[index].Home = home
				return nil
			}
		}
		return fmt.Errorf("terminal group not found: %s", id)
	})
}

func (s *Service) MoveTerminalGroup(id, before string) error {
	return s.Store.Update(func(state *api.State) error {
		sortTerminalGroups(state.TerminalGroups)
		index := -1
		for i := range state.TerminalGroups {
			if state.TerminalGroups[i].ID == id {
				index = i
				break
			}
		}
		if index < 0 {
			return fmt.Errorf("terminal group not found: %s", id)
		}
		target := len(state.TerminalGroups)
		if before != "" {
			found := false
			for i := range state.TerminalGroups {
				if state.TerminalGroups[i].ID == before {
					target = i
					found = true
					break
				}
			}
			if !found {
				return fmt.Errorf("before terminal group not found: %s", before)
			}
		}
		group := state.TerminalGroups[index]
		state.TerminalGroups = append(state.TerminalGroups[:index], state.TerminalGroups[index+1:]...)
		if index < target {
			target--
		}
		state.TerminalGroups = slices.Insert(state.TerminalGroups, target, group)
		for i := range state.TerminalGroups {
			state.TerminalGroups[i].Order = i
		}
		return nil
	})
}

func (s *Service) RemoveTerminalGroup(ctx context.Context, id string, force bool) error {
	s.terminalGroupLifecycleMu.Lock()
	defer s.terminalGroupLifecycleMu.Unlock()

	state := s.Store.Snapshot()
	found := false
	for _, group := range state.TerminalGroups {
		if group.ID == id {
			found = true
			break
		}
	}
	if !found {
		return fmt.Errorf("terminal group not found: %s", id)
	}
	for _, session := range state.Sessions {
		if session.TerminalGroupID == id && !force {
			return errors.New("terminal group has sessions; use --force")
		}
	}
	if force {
		s.removeTerminalGroupRuntimes(ctx, state, id)
	}
	return s.Store.Update(func(value *api.State) error {
		value.TerminalGroups = filter(value.TerminalGroups, func(group api.TerminalGroup) bool {
			return group.ID != id
		})
		value.Sessions = filter(value.Sessions, func(session api.Session) bool {
			return session.TerminalGroupID != id
		})
		for index := range value.TerminalGroups {
			value.TerminalGroups[index].Order = index
		}
		return nil
	})
}

func (s *Service) ensureTerminalGroup() (api.TerminalGroup, error) {
	state := s.Store.Snapshot()
	if len(state.TerminalGroups) > 0 {
		sortTerminalGroups(state.TerminalGroups)
		return state.TerminalGroups[0], nil
	}
	var group api.TerminalGroup
	err := s.Store.Update(func(state *api.State) error {
		if len(state.TerminalGroups) == 0 {
			group = api.TerminalGroup{
				ID:        store.NewID(),
				Name:      "Inbox",
				Order:     0,
				CreatedAt: time.Now().UTC(),
			}
			state.TerminalGroups = append(state.TerminalGroups, group)
		} else {
			sortTerminalGroups(state.TerminalGroups)
			group = state.TerminalGroups[0]
		}
		return nil
	})
	return group, err
}

func (s *Service) projectLifecycleLock(projectID string) *sync.RWMutex {
	s.workspaceLifecycleMu.Lock()
	defer s.workspaceLifecycleMu.Unlock()
	if s.projectLifecycleLocks == nil {
		s.projectLifecycleLocks = make(map[string]*sync.RWMutex)
	}
	if lock := s.projectLifecycleLocks[projectID]; lock != nil {
		return lock
	}
	lock := &sync.RWMutex{}
	s.projectLifecycleLocks[projectID] = lock
	return lock
}

func (s *Service) lockWorkspaceForSession(workspaceID string) *sync.RWMutex {
	state := s.Store.Snapshot()
	for _, workspace := range state.Workspaces {
		if workspace.ID != workspaceID {
			continue
		}
		lock := s.projectLifecycleLock(workspace.ProjectID)
		lock.RLock()
		return lock
	}
	return nil
}

func (s *Service) lockWorkspaceLifecycle(workspaceID string) *sync.RWMutex {
	state := s.Store.Snapshot()
	for _, workspace := range state.Workspaces {
		if workspace.ID != workspaceID {
			continue
		}
		lock := s.projectLifecycleLock(workspace.ProjectID)
		lock.Lock()
		return lock
	}
	return nil
}

func (s *Service) lockGitMutation(workspaceID string) func() {
	s.gitMutationMu.Lock()
	if s.gitMutationLocks == nil {
		s.gitMutationLocks = make(map[string]*sync.Mutex)
	}
	lock := s.gitMutationLocks[workspaceID]
	if lock == nil {
		lock = &sync.Mutex{}
		s.gitMutationLocks[workspaceID] = lock
	}
	s.gitMutationMu.Unlock()
	lock.Lock()
	return lock.Unlock
}

func (s *Service) RemoveProject(id string, force bool) error {
	projectLock := s.projectLifecycleLock(id)
	projectLock.Lock()
	state := s.Store.Snapshot()
	found := false
	workspaceIDs := make([]string, 0)
	for _, workspace := range state.Workspaces {
		if workspace.ProjectID != id {
			continue
		}
		workspaceIDs = append(workspaceIDs, workspace.ID)
		for _, session := range state.Sessions {
			if session.WorkspaceID == workspace.ID && session.Lifecycle == "running" && !force {
				projectLock.Unlock()
				return errors.New("project has running sessions; use --force")
			}
		}
	}
	for _, project := range state.Projects {
		if project.ID == id {
			found = true
			break
		}
	}
	if !found {
		projectLock.Unlock()
		return fmt.Errorf("project not found: %s", id)
	}
	err := s.Store.Update(func(value *api.State) error {
		workspaceIDs := map[string]bool{}
		value.Projects = filter(value.Projects, func(p api.Project) bool { return p.ID != id })
		value.Workspaces = filter(value.Workspaces, func(w api.Workspace) bool {
			if w.ProjectID == id {
				workspaceIDs[w.ID] = true
				return false
			}
			return true
		})
		value.Sessions = filter(value.Sessions, func(session api.Session) bool { return !workspaceIDs[session.WorkspaceID] })
		for i := range value.Projects {
			value.Projects[i].Order = i
		}
		return nil
	})
	projectLock.Unlock()
	if err != nil {
		return err
	}
	s.invalidateMerge()
	if force {
		for _, workspaceID := range workspaceIDs {
			_ = s.removeWorkspaceRuntime(context.Background(), state, workspaceID)
		}
	}
	return nil
}

func (s *Service) RenameProject(id, name string) error {
	name = strings.TrimSpace(name)
	if name == "" {
		return errors.New("project name cannot be empty")
	}
	return s.Store.Update(func(state *api.State) error {
		for index := range state.Projects {
			if state.Projects[index].ID == id {
				state.Projects[index].Name = name
				return nil
			}
		}
		return fmt.Errorf("project not found: %s", id)
	})
}

func (s *Service) RenameWorkspace(id, name string) error {
	name = strings.TrimSpace(name)
	if name == "" {
		return errors.New("workspace name cannot be empty")
	}
	return s.Store.Update(func(state *api.State) error {
		for index := range state.Workspaces {
			if state.Workspaces[index].ID == id {
				state.Workspaces[index].Name = name
				return nil
			}
		}
		return fmt.Errorf("workspace not found: %s", id)
	})
}

func (s *Service) RenameSession(id, title string) error {
	title = strings.TrimSpace(title)
	if title == "" {
		return errors.New("session title cannot be empty")
	}
	return s.Store.Update(func(state *api.State) error {
		for index := range state.Sessions {
			if state.Sessions[index].ID == id {
				state.Sessions[index].CustomTitle = title
				return nil
			}
		}
		return fmt.Errorf("session not found: %s", id)
	})
}

func (s *Service) SetProjectPinned(id string, pinned bool) error {
	return s.Store.Update(func(state *api.State) error {
		for index := range state.Projects {
			if state.Projects[index].ID == id {
				state.Projects[index].Pinned = pinned
				return nil
			}
		}
		return fmt.Errorf("project not found: %s", id)
	})
}

func (s *Service) SetWorkspacePinned(id string, pinned bool) error {
	return s.Store.Update(func(state *api.State) error {
		for index := range state.Workspaces {
			if state.Workspaces[index].ID == id {
				state.Workspaces[index].Pinned = pinned
				return nil
			}
		}
		return fmt.Errorf("workspace not found: %s", id)
	})
}

func (s *Service) SetSessionPinned(id string, pinned bool) error {
	return s.Store.Update(func(state *api.State) error {
		for index := range state.Sessions {
			if state.Sessions[index].ID == id {
				state.Sessions[index].Pinned = pinned
				return nil
			}
		}
		return fmt.Errorf("session not found: %s", id)
	})
}

func (s *Service) CreateWorkspace(projectID, branch, name, path string) (api.WorkspaceCreateResult, error) {
	projectLock := s.projectLifecycleLock(projectID)
	projectLock.Lock()
	defer projectLock.Unlock()

	state := s.Store.Snapshot()
	var project *api.Project
	for i := range state.Projects {
		if state.Projects[i].ID == projectID {
			project = &state.Projects[i]
			break
		}
	}
	if project == nil {
		return api.WorkspaceCreateResult{}, fmt.Errorf("project not found: %s", projectID)
	}
	branch = strings.TrimSpace(branch)
	if branch == "" {
		return api.WorkspaceCreateResult{}, errors.New("branch is required")
	}
	if err := branchAlreadyHasWorkspace(&state, projectID, branch); err != nil {
		return api.WorkspaceCreateResult{}, err
	}
	id := store.NewID()
	if name == "" {
		name = branch
	}
	gitCreated := false
	if path != "" {
		if resolved, err := filepath.Abs(expandHome(path)); err == nil {
			if info, statErr := os.Stat(resolved); statErr == nil && info.IsDir() {
				if output, gitErr := exec.Command("git", "-C", resolved, "rev-parse", "--show-toplevel").Output(); gitErr == nil {
					root := strings.TrimSpace(string(output))
					if samePath(root, project.Path) {
						if branch == "" {
							branch = gitOutput(resolved, "branch", "--show-current")
						}
						if name == "" {
							name = defaultValue(branch, "main")
						}
						workspace := api.Workspace{
							ID: id, ProjectID: projectID, Name: name, Path: resolved,
							Branch: branch, Kind: "root", CreatedAt: time.Now().UTC(),
						}
						if err := s.Store.Update(func(value *api.State) error {
							if err := branchAlreadyHasWorkspace(value, projectID, branch); err != nil {
								return err
							}
							workspace.Order = nextWorkspaceOrder(value.Workspaces, projectID)
							value.Workspaces = append(value.Workspaces, workspace)
							return nil
						}); err != nil {
							return api.WorkspaceCreateResult{}, err
						}
						s.invalidateMerge()
						return api.WorkspaceCreateResult{Workspace: workspace, Created: true}, nil
					}
					if name == "" {
						name = filepath.Base(resolved)
					}
					workspace := api.Workspace{
						ID: id, ProjectID: projectID, Name: name, Path: resolved,
						Branch: branch, Kind: "worktree", CreatedAt: time.Now().UTC(),
					}
					if err := s.Store.Update(func(value *api.State) error {
						if err := branchAlreadyHasWorkspace(value, projectID, branch); err != nil {
							return err
						}
						workspace.Order = nextWorkspaceOrder(value.Workspaces, projectID)
						value.Workspaces = append(value.Workspaces, workspace)
						return nil
					}); err != nil {
						return api.WorkspaceCreateResult{}, err
					}
					s.invalidateMerge()
					return api.WorkspaceCreateResult{Workspace: workspace, Created: true}, nil
				}
			}
		}
	}
	if path == "" {
		path = filepath.Join(expandHome(s.WorktreeRoot), project.ID[:8], id[:8]+"-"+safeName(branch))
	}
	path, _ = filepath.Abs(expandHome(path))
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return api.WorkspaceCreateResult{}, err
	}
	args := []string{"-C", project.Path, "worktree", "add", path, branch}
	if exec.Command("git", "-C", project.Path, "show-ref", "--verify", "--quiet", "refs/heads/"+branch).Run() != nil {
		args = []string{"-C", project.Path, "worktree", "add", "-b", branch, path}
	}
	if output, err := exec.Command("git", args...).CombinedOutput(); err != nil {
		return api.WorkspaceCreateResult{}, fmt.Errorf("git worktree add: %s: %w", strings.TrimSpace(string(output)), err)
	}
	gitCreated = true
	workspace := api.Workspace{
		ID: id, ProjectID: projectID, Name: name, Path: path,
		Branch: branch, Kind: "worktree", ManagedWorktree: true,
		CreatedAt: time.Now().UTC(),
	}
	if err := s.Store.Update(func(value *api.State) error {
		if err := branchAlreadyHasWorkspace(value, projectID, branch); err != nil {
			return err
		}
		workspace.Order = nextWorkspaceOrder(value.Workspaces, projectID)
		value.Workspaces = append(value.Workspaces, workspace)
		return nil
	}); err != nil {
		_, _ = exec.Command("git", "-C", project.Path, "worktree", "remove", "--force", path).CombinedOutput()
		return api.WorkspaceCreateResult{}, err
	}
	s.invalidateMerge()
	return api.WorkspaceCreateResult{Workspace: workspace, Created: true, GitWorktree: gitCreated}, nil
}

// branchAlreadyHasWorkspace enforces the invariant that a project has at most
// one workspace per Git branch, regardless of whether the workspace is a root
// checkout or a git worktree.
func branchAlreadyHasWorkspace(state *api.State, projectID, branch string) error {
	// Detached Git worktrees do not have a branch name. Multiple detached
	// checkouts are valid and must not collide on the empty string.
	if strings.TrimSpace(branch) == "" {
		return nil
	}
	for i := range state.Workspaces {
		workspace := state.Workspaces[i]
		if workspace.ProjectID == projectID && workspace.Branch == branch {
			return fmt.Errorf("workspace already exists for branch %q (workspace %s)", branch, workspace.ID)
		}
	}
	return nil
}

type RemoveWorkspaceOptions struct {
	Force bool
	// RemoveWorktree controls whether a Git worktree directory is removed
	// together with its Warren workspace. It only applies to worktree-backed
	// workspaces; main checkouts are never deleted from disk.
	RemoveWorktree bool
}

func (s *Service) RemoveWorkspace(ctx context.Context, id string, options RemoveWorkspaceOptions) error {
	projectLock := s.lockWorkspaceLifecycle(id)
	if projectLock == nil {
		return fmt.Errorf("workspace not found: %s", id)
	}
	state := s.Store.Snapshot()
	var workspace *api.Workspace
	for i := range state.Workspaces {
		if state.Workspaces[i].ID == id {
			workspace = &state.Workspaces[i]
			break
		}
	}
	if workspace == nil {
		projectLock.Unlock()
		return fmt.Errorf("workspace not found: %s", id)
	}
	for _, session := range state.Sessions {
		if session.WorkspaceID == id && session.Lifecycle == "running" && !options.Force {
			projectLock.Unlock()
			return errors.New("workspace has running sessions; use --force")
		}
	}
	workspaceValue := *workspace
	err := s.Store.Update(func(value *api.State) error {
		projectID := workspaceValue.ProjectID
		value.Workspaces = filter(value.Workspaces, func(w api.Workspace) bool { return w.ID != id })
		value.Sessions = filter(value.Sessions, func(session api.Session) bool { return session.WorkspaceID != id })
		order := 0
		for i := range value.Workspaces {
			if value.Workspaces[i].ProjectID == projectID {
				value.Workspaces[i].Order = order
				order++
			}
		}
		return nil
	})
	projectLock.Unlock()
	if err != nil {
		return err
	}
	s.invalidateMerge()

	// Publish the removal before doing best-effort runtime and filesystem
	// cleanup. This keeps the roster responsive and prevents a new session from
	// racing with a workspace that is already gone from durable state.
	if options.Force {
		_ = s.removeWorkspaceRuntime(ctx, state, id)
	}
	// Imported and locked worktrees are never removed from disk. The caller may
	// still delete Warren's workspace record, but filesystem ownership must be
	// explicit and a Git lock must be respected.
	if workspaceValue.Kind == "worktree" && options.RemoveWorktree && workspaceValue.ManagedWorktree && !workspaceValue.WorktreeLocked {
		s.removeWorktreeDirectory(workspaceValue, state.Projects)
	}
	return nil
}

// removeWorktreeDirectory is best-effort physical cleanup of a worktree-backed
// workspace. Removing the Warren workspace record must never depend on git
// succeeding: a stale registration, an already-removed directory, or a busy
// file must not leave the workspace stuck in state. Every failure is logged and
// the operation proceeds; a leftover directory (and possibly its git
// registration) is left on disk and would only be re-imported by an explicit
// `project add`.
func (s *Service) removeWorktreeDirectory(workspace api.Workspace, projects []api.Project) {
	var project api.Project
	for _, value := range projects {
		if value.ID == workspace.ProjectID {
			project = value
			break
		}
	}
	// External shells (Codex, Claude, ...) keep their cwd inside the worktree.
	// Terminate them before the git remove so deleting the directory cannot
	// strand their exec sessions on a removed cwd.
	if _, err := terminateProcessesUnder(workspace.Path); err != nil {
		s.logWarn("terminate worktree processes during workspace removal", "workspace", workspace.ID, "error", err)
	}
	if _, err := os.Stat(workspace.Path); err != nil {
		if !errors.Is(err, os.ErrNotExist) {
			s.logWarn("stat worktree path during workspace removal", "workspace", workspace.ID, "error", err)
		}
		// The worktree was already removed outside Warren. Converge on state
		// cleanup instead of failing on git's "not a worktree".
		return
	}
	if project.Path == "" {
		// The owning project was itself removed, so its git metadata is gone
		// with it. Leave the directory and let state cleanup proceed.
		return
	}
	if output, err := exec.Command("git", "-C", project.Path, "worktree", "remove", "--force", workspace.Path).CombinedOutput(); err != nil {
		// "not a working tree", a stale registration, or a busy file: leave the
		// directory on disk rather than failing the deletion the user asked for.
		s.logWarn("git worktree remove during workspace removal", "workspace", workspace.ID, "output", strings.TrimSpace(string(output)), "error", err)
	}
}

func (s *Service) logWarn(message string, keyValues ...any) {
	logger := s.Logger
	if logger == nil {
		logger = slog.Default()
	}
	logger.Warn(message, keyValues...)
}

func findWorkspace(state api.State, id string) (api.Workspace, error) {
	for _, workspace := range state.Workspaces {
		if workspace.ID == id {
			return workspace, nil
		}
	}
	return api.Workspace{}, fmt.Errorf("workspace not found: %s", id)
}

func (s *Service) GitPanel(ctx context.Context, workspaceID string, fetch, force bool) (api.GitPanel, error) {
	workspace, err := findWorkspace(s.Store.Snapshot(), workspaceID)
	if err != nil {
		return api.GitPanel{}, err
	}
	cache := s.panelCacheFor()
	if !force {
		if panel, ok := cache.Get(workspaceID); ok {
			if cache.ShouldRevalidate(workspaceID, panelRevalidateAfter) {
				go s.revalidatePanel(workspaceID, workspace.Path)
				panel.Refreshing = true
			}
			return panel, nil
		}
	}
	version := cache.Version(workspaceID)
	// panelLoad coalesces callers for one workspace. Detach the actual load
	// from one observer's WebSocket so a reconnect cannot cancel the shared
	// operation and poison every waiter with context.Canceled.
	loadContext, cancel := context.WithTimeout(context.WithoutCancel(ctx), panelLoadTimeout)
	defer cancel()
	panel, err := s.panelLoad.Do(workspaceID, func() (api.GitPanel, error) {
		return s.loadGitPanel(loadContext, workspaceID, workspace.Path, fetch)
	})
	if err != nil {
		return api.GitPanel{}, err
	}
	cache.SetIfVersion(workspaceID, panel, version)
	return panel, nil
}

func (s *Service) panelCacheFor() *panelCache {
	s.panelCacheOnce.Do(func() {
		s.panelCache = newPanelCache(panelCacheCapacity)
		s.panelLoad = newPanelLoad()
	})
	return s.panelCache
}

func (s *Service) revalidatePanel(workspaceID, path string) {
	ctx, cancel := context.WithTimeout(context.Background(), panelRevalidateTimeout)
	defer cancel()
	cache := s.panelCacheFor()
	version := cache.Version(workspaceID)
	panel, err := s.loadGitPanel(ctx, workspaceID, path, true)
	if err == nil {
		cache.SetIfVersion(workspaceID, panel, version)
	}
	cache.FinishRevalidate(workspaceID)
}

func (s *Service) invalidatePanelCache(workspaceID string) {
	s.panelCacheFor().Remove(workspaceID)
}

func (s *Service) loadGitPanel(ctx context.Context, workspaceID, path string, fetch bool) (api.GitPanel, error) {
	if fetch {
		unlock := s.lockGitMutation(workspaceID)
		defer unlock()
		// Refresh the remote refs before comparing against origin/main. A
		// failed fetch (offline, no remote) must not block the panel; the
		// comparison then uses the last fetched refs.
		_ = git.Fetch(ctx, path)
	}
	mainBranch := git.MainBranch(ctx, path)
	status, err := git.StatusFor(ctx, path)
	if err != nil {
		return api.GitPanel{}, err
	}
	commits, err := git.Log(ctx, path, 20)
	if err != nil {
		return api.GitPanel{}, err
	}
	branches, err := git.Branches(ctx, path)
	if err != nil {
		return api.GitPanel{}, err
	}
	remote, _ := git.RemoteURL(ctx, path)
	panel := api.GitPanel{
		WorkspaceID: workspaceID,
		Branch:      status.Branch,
		Upstream:    status.Upstream,
		Ahead:       status.Ahead,
		Behind:      status.Behind,
		Remote:      remote,
		MainBranch:  strings.TrimPrefix(mainBranch, "refs/remotes/"),
		Operation:   git.OperationState(ctx, path),
		Changes:     apiGitChanges(status.Changes),
		Commits:     apiGitCommits(commits),
		Branches:    apiGitBranches(branches),
	}
	if remote != "" {
		pr, prErr := git.PullRequestForBranch(ctx, path)
		if prErr != nil && !errors.Is(prErr, git.ErrNoPullRequest) {
			panel.PullRequestError = prErr.Error()
		} else if pr != nil {
			panel.PullRequest = apiGitPullRequest(pr)
		}
	}
	if mainBranch != "" {
		if merged, err := git.IsMerged(ctx, path, mainBranch); err == nil {
			panel.Merged = merged
		}
		if !panel.Merged {
			if unmerged, err := git.LogRange(ctx, path, mainBranch); err == nil {
				panel.UnmergedCommits = apiGitCommits(unmerged)
			}
		}
		if ahead, _, err := git.AheadBehind(ctx, path, mainBranch); err == nil {
			panel.AheadOfMain = ahead
		}
	}
	return panel, nil
}

// GitDiff returns the full content and unified diff of one path in a
// workspace, either in the working tree (staged selects the index) or for a
// specific commit.
func (s *Service) GitDiff(ctx context.Context, workspaceID, path string, staged bool, commit string) (api.GitDiff, error) {
	workspace, err := findWorkspace(s.Store.Snapshot(), workspaceID)
	if err != nil {
		return api.GitDiff{}, err
	}
	view, err := git.Show(ctx, workspace.Path, path, staged, commit)
	if err != nil {
		return api.GitDiff{}, err
	}
	return api.GitDiff{
		Diff: view.Diff, Content: view.Content,
		DiffTruncated: view.DiffTruncated, ContentTruncated: view.ContentTruncated,
	}, nil
}

func (s *Service) GitCheckout(ctx context.Context, workspaceID, branch string, create bool) (api.GitCommandResult, error) {
	unlock := s.lockGitMutation(workspaceID)
	defer unlock()
	workspace, err := findWorkspace(s.Store.Snapshot(), workspaceID)
	if err != nil {
		return api.GitCommandResult{}, err
	}
	if err := git.Checkout(ctx, workspace.Path, branch, create); err != nil {
		return api.GitCommandResult{}, err
	}
	current, err := git.CurrentBranch(ctx, workspace.Path)
	if err != nil {
		return api.GitCommandResult{}, err
	}
	if err := s.Store.Update(func(value *api.State) error {
		for i := range value.Workspaces {
			if value.Workspaces[i].ID == workspaceID {
				value.Workspaces[i].Branch = current
				return nil
			}
		}
		return fmt.Errorf("workspace not found: %s", workspaceID)
	}); err != nil {
		return api.GitCommandResult{}, err
	}
	s.invalidatePanelCache(workspaceID)
	return api.GitCommandResult{Message: "Checked out " + current}, nil
}

func (s *Service) GitPull(ctx context.Context, workspaceID string) (api.GitCommandResult, error) {
	unlock := s.lockGitMutation(workspaceID)
	defer unlock()
	workspace, err := findWorkspace(s.Store.Snapshot(), workspaceID)
	if err != nil {
		return api.GitCommandResult{}, err
	}
	output, err := git.Pull(ctx, workspace.Path)
	if err != nil {
		return api.GitCommandResult{}, err
	}
	s.invalidatePanelCache(workspaceID)
	return api.GitCommandResult{Message: strings.TrimSpace(output)}, nil
}

func (s *Service) GitPush(ctx context.Context, workspaceID string) (api.GitCommandResult, error) {
	unlock := s.lockGitMutation(workspaceID)
	defer unlock()
	workspace, err := findWorkspace(s.Store.Snapshot(), workspaceID)
	if err != nil {
		return api.GitCommandResult{}, err
	}
	output, err := git.Push(ctx, workspace.Path)
	if err != nil {
		return api.GitCommandResult{}, err
	}
	s.invalidatePanelCache(workspaceID)
	return api.GitCommandResult{Message: strings.TrimSpace(output)}, nil
}

func (s *Service) GitCommit(ctx context.Context, workspaceID, message string) (api.GitCommandResult, error) {
	unlock := s.lockGitMutation(workspaceID)
	defer unlock()
	workspace, err := findWorkspace(s.Store.Snapshot(), workspaceID)
	if err != nil {
		return api.GitCommandResult{}, err
	}
	output, err := git.CommitAll(ctx, workspace.Path, message)
	if err != nil {
		return api.GitCommandResult{}, err
	}
	s.invalidatePanelCache(workspaceID)
	return api.GitCommandResult{Message: strings.TrimSpace(output)}, nil
}

// GitCreatePullRequest pushes the workspace branch if needed and opens a
// pull request against the repository's main branch.
func (s *Service) GitCreatePullRequest(ctx context.Context, workspaceID, title, body string) (api.GitPullRequest, error) {
	unlock := s.lockGitMutation(workspaceID)
	defer unlock()
	workspace, err := findWorkspace(s.Store.Snapshot(), workspaceID)
	if err != nil {
		return api.GitPullRequest{}, err
	}
	pr, err := git.CreatePullRequest(ctx, workspace.Path, title, body)
	if err != nil {
		return api.GitPullRequest{}, err
	}
	s.invalidatePanelCache(workspaceID)
	return *apiGitPullRequest(pr), nil
}

func apiGitChanges(changes []git.Change) []api.GitChange {
	result := make([]api.GitChange, 0, len(changes))
	for _, change := range changes {
		result = append(result, api.GitChange{
			Path:       change.Path,
			Status:     change.Status,
			Staged:     change.Staged,
			RenameFrom: change.RenameFrom,
			Added:      change.Added,
			Deleted:    change.Deleted,
		})
	}
	return result
}

func apiGitCommits(commits []git.Commit) []api.GitCommit {
	result := make([]api.GitCommit, 0, len(commits))
	for _, commit := range commits {
		files := make([]api.GitChange, 0, len(commit.Files))
		for _, file := range commit.Files {
			files = append(files, api.GitChange{
				Path:       file.Path,
				Status:     file.Status,
				RenameFrom: file.RenameFrom,
				Added:      file.Added,
				Deleted:    file.Deleted,
			})
		}
		result = append(result, api.GitCommit{
			Hash:    commit.Hash,
			Short:   commit.Short,
			Subject: commit.Subject,
			Author:  commit.Author,
			Email:   commit.Email,
			Time:    commit.Time,
			Files:   files,
		})
	}
	return result
}

func apiGitBranches(list git.BranchList) []api.GitBranch {
	result := make([]api.GitBranch, 0, len(list.Local)+len(list.Remote))
	for _, name := range list.Local {
		result = append(result, api.GitBranch{Name: name})
	}
	for _, name := range list.Remote {
		result = append(result, api.GitBranch{Name: name, Remote: true})
	}
	return result
}

func apiGitPullRequest(pr *git.PullRequest) *api.GitPullRequest {
	return &api.GitPullRequest{
		Number: pr.Number,
		Title:  pr.Title,
		Body:   pr.Body,
		State:  pr.State,
		Draft:  pr.Draft,
		URL:    pr.URL,
		Author: pr.Author,
		Base:   pr.Base,
		Head:   pr.Head,
	}
}

func (s *Service) CreateSession(ctx context.Context, workspaceID, command, kind, title, runtimeKind string) (api.Session, error) {
	if workspaceID != "" {
		if projectLock := s.lockWorkspaceForSession(workspaceID); projectLock != nil {
			defer projectLock.RUnlock()
		}
	}
	return s.createSession(ctx, workspaceID, "", command, kind, title, runtimeKind)
}

func (s *Service) CreateGroupSession(ctx context.Context, groupID, command, kind, title, runtimeKind string) (api.Session, error) {
	s.terminalGroupLifecycleMu.Lock()
	defer s.terminalGroupLifecycleMu.Unlock()
	return s.createSession(ctx, "", groupID, command, kind, title, runtimeKind)
}

// CreateDefaultGroupSession creates a standalone shell in the first ordered
// Group, recreating Inbox when a Host has no Groups left.
func (s *Service) CreateDefaultGroupSession(ctx context.Context, command, kind, title, runtimeKind string) (api.Session, error) {
	s.terminalGroupLifecycleMu.Lock()
	defer s.terminalGroupLifecycleMu.Unlock()

	group, err := s.ensureTerminalGroup()
	if err != nil {
		return api.Session{}, err
	}
	return s.createSession(ctx, "", group.ID, command, kind, title, runtimeKind)
}

func (s *Service) createSession(ctx context.Context, workspaceID, groupID, command, kind, title, runtimeKind string) (api.Session, error) {
	if workspaceID == "" && groupID == "" {
		return api.Session{}, errors.New("workspace or terminal group is required")
	}
	if workspaceID != "" && groupID != "" {
		return api.Session{}, errors.New("workspace and terminal group are mutually exclusive")
	}
	state := s.Store.Snapshot()
	var workspace *api.Workspace
	var group *api.TerminalGroup
	if workspaceID != "" {
		for i := range state.Workspaces {
			if state.Workspaces[i].ID == workspaceID {
				workspace = &state.Workspaces[i]
				break
			}
		}
		if workspace == nil {
			return api.Session{}, fmt.Errorf("workspace not found: %s", workspaceID)
		}
	} else {
		for i := range state.TerminalGroups {
			if state.TerminalGroups[i].ID == groupID {
				group = &state.TerminalGroups[i]
				break
			}
		}
		if group == nil {
			return api.Session{}, fmt.Errorf("terminal group not found: %s", groupID)
		}
	}
	workingDirectory, err := sessionWorkingDirectory(state, workspaceID, groupID)
	if err != nil {
		return api.Session{}, err
	}
	id := store.NewID()
	runtimeName := "warren_" + strings.ReplaceAll(id, "-", "")
	if kind == "" {
		kind = "shell"
	}
	customTitle := strings.TrimSpace(title)
	defaultTitle := map[string]string{
		"shell": "Shell", "codex": "Codex", "claude": "Claude Code", "trae": "Trae",
	}[kind]
	if defaultTitle == "" {
		fields := strings.Fields(command)
		if len(fields) > 0 {
			defaultTitle = fields[0]
		} else {
			defaultTitle = "Shell"
		}
	}
	sessionKind := runtimeKind
	if sessionKind == "" {
		sessionKind = s.DefaultRuntime
	}
	if sessionKind == "" {
		sessionKind = settings.DefaultRuntimeKind
	}
	adapter := s.runtimeFor(api.Session{RuntimeKind: sessionKind})
	if adapter == nil {
		return api.Session{}, fmt.Errorf("runtime %q is not available", sessionKind)
	}
	// The Claude transcript path is derived from the session ID we inject,
	// so the daemon can bind it without a hook round-trip.
	injectedClaude := false
	if kind == "claude" {
		injected := agent.InjectClaudeSessionID(command, id)
		if injected != command {
			command = injected
			injectedClaude = true
		}
	}
	// Every session gets the binding environment so a CLI started manually
	// inside a plain shell is bound to the same Warren session by its own
	// lifecycle hooks.
	env := agent.BindEnvironment(id, kind)
	if err := adapter.Create(ctx, runtimeName, workingDirectory, command, env); err != nil {
		return api.Session{}, err
	}
	session := api.Session{
		ID:              id,
		WorkspaceID:     workspaceID,
		TerminalGroupID: groupID,
		Scope:           api.SessionScopeWorkspace,
		Title:           defaultTitle,
		CustomTitle:     customTitle,
		Kind:            kind,
		Command:         command,
		Runtime:         runtimeName,
		RuntimeKind:     sessionKind,
		Lifecycle:       "running",
		CreatedAt:       time.Now().UTC(),
	}
	if groupID != "" {
		session.Scope = api.SessionScopeTerminalGroup
	}
	if injectedClaude {
		session.AgentSessionID = id
	}
	if err := s.Store.Update(func(value *api.State) error { value.Sessions = append(value.Sessions, session); return nil }); err != nil {
		_ = adapter.Kill(ctx, runtimeName)
		return api.Session{}, err
	}
	if _, err := s.ensureOutput(ctx, session); err != nil {
		_ = adapter.Kill(ctx, runtimeName)
		_ = s.Store.Update(func(value *api.State) error {
			value.Sessions = filter(value.Sessions, func(item api.Session) bool { return item.ID != id })
			return nil
		})
		if output := s.outputAdapterFor(session); output != nil {
			output.RemoveSpool(runtimeName)
		}
		return api.Session{}, err
	}
	_, _ = s.ensureAgent(ctx, session)
	return session, nil
}

// SetDefaultRuntime changes the engine used for newly created sessions while
// preserving the configured runtime environment overrides.
func (s *Service) SetDefaultRuntime(kind string) error {
	return s.UpdateSettings(kind, s.Settings.RuntimeEnv, s.Settings.GnarEdge)
}

// UpdateSettings changes the engine used for newly created sessions and the
// runtime environment overrides and the gnar edge, persisting them when a
// settings file is configured. Existing sessions keep their own runtimeKind.
func (s *Service) UpdateSettings(kind string, runtimeEnv map[string]string, gnarEdge string) error {
	gnarEdge = strings.TrimSpace(gnarEdge)
	if gnarEdge != "" {
		if err := tunnel.ValidateEdgeURL(gnarEdge); err != nil {
			return err
		}
	}
	if kind == "" {
		kind = s.DefaultRuntime
	}
	if kind == "" {
		kind = s.Settings.Normalized()
	}
	switch kind {
	case settings.RuntimeGhostline, settings.RuntimeTmux:
	default:
		return fmt.Errorf("unsupported runtime %q (supported: ghostline, tmux)", kind)
	}
	if s.Runtimes[kind] == nil && s.Runtime == nil {
		return fmt.Errorf("runtime %q is not available on this host", kind)
	}
	s.DefaultRuntime = kind
	s.Settings.DefaultRuntime = kind
	s.Settings.RuntimeEnv = runtimeEnv
	s.Settings.GnarEdge = gnarEdge
	if s.SettingsPath != "" {
		return settings.Save(s.SettingsPath, s.Settings)
	}
	return nil
}

// UpdatePublicAccessConfig persists the non-secret gnar Edge configuration.
// Invite and approval keys are intentionally not accepted here; they belong
// only to the in-memory enable request and are forwarded to gnar over stdin.
func (s *Service) UpdatePublicAccessConfig(edge, account string) error {
	edge = strings.TrimSpace(edge)
	if edge != "" {
		if err := tunnel.ValidateEdgeURL(edge); err != nil {
			return err
		}
	}
	normalizedAccount, err := settings.NormalizeConfiguredGnarAccount(account)
	if err != nil {
		return err
	}
	s.Settings.GnarEdge = edge
	// An omitted account is intentional: keep the system-name default dynamic
	// instead of persisting a machine-specific value as a user override.
	s.Settings.GnarAccount = normalizedAccount
	if s.SettingsPath != "" {
		return settings.Save(s.SettingsPath, s.Settings)
	}
	return nil
}

// EffectiveGnarAccount returns the account label Warren will pass to gnar for
// a bootstrap login. The value is never a credential.
func (s *Service) EffectiveGnarAccount() string {
	return settings.EffectiveGnarAccount(s.Settings.GnarAccount, s.HostName)
}

// ConfiguredGnarAccount returns only a user-provided account override.
func (s *Service) ConfiguredGnarAccount() string {
	return settings.ConfiguredGnarAccount(s.Settings.GnarAccount)
}

// PublicAccessEnabled reports the persisted user intent independently of the
// current gnar process. This distinction lets recovery retry after a daemon
// restart without claiming that an endpoint is already live.
func (s *Service) PublicAccessEnabled() bool {
	return s.Settings.TunnelEnabled != nil && s.Settings.TunnelEnabled[tunnel.KindGnar]
}

// SetAutoOpenShell records whether opening an empty workspace creates a Shell
// session by default. Explicit session actions are unaffected.
func (s *Service) SetAutoOpenShell(enabled bool) error {
	s.Settings.AutoOpenShell = enabled
	if s.SettingsPath != "" {
		return settings.Save(s.SettingsPath, s.Settings)
	}
	return nil
}

// SetAutoStartAI records whether entering an empty workspace starts the first
// AI preset. Explicit session actions are unaffected.
func (s *Service) SetAutoStartAI(enabled bool) error {
	s.Settings.AutoStartAI = enabled
	if s.SettingsPath != "" {
		return settings.Save(s.SettingsPath, s.Settings)
	}
	return nil
}

// UpdateTunnelEnabled records whether a reachability adapter should be
// restored after a daemon restart, persisting the intent when a settings file
// is configured. A tunnel that fails to start still keeps its intent so the
// next daemon retries; only an explicit stop clears it.
func (s *Service) UpdateTunnelEnabled(kind string, enabled bool) error {
	switch kind {
	case tunnel.KindCloudflared, tunnel.KindTailscale, tunnel.KindGnar:
	default:
		return fmt.Errorf("unknown tunnel kind %q", kind)
	}
	if s.Settings.TunnelEnabled == nil {
		s.Settings.TunnelEnabled = map[string]bool{}
	}
	if enabled {
		s.Settings.TunnelEnabled[kind] = true
	} else {
		delete(s.Settings.TunnelEnabled, kind)
	}
	if s.SettingsPath != "" {
		return settings.Save(s.SettingsPath, s.Settings)
	}
	return nil
}

func (s *Service) DeleteSession(ctx context.Context, id string) error {
	state := s.Store.Snapshot()
	var session *api.Session
	for i := range state.Sessions {
		if state.Sessions[i].ID == id {
			session = &state.Sessions[i]
			break
		}
	}
	if session == nil {
		// Deleting a missing session is a successful no-op. The desktop can
		// emit a second close for a tab whose roster update has not arrived
		// yet; treating that duplicate as an error makes rapid close actions
		// surface as failures.
		return nil
	}
	// Only explicit Close Tab / Terminate Session reaches kill-session.
	adapter := s.runtimeFor(*session)
	if err := adapter.Kill(ctx, session.Runtime); err != nil {
		return err
	}
	s.stopOutput(id, true)
	if output := s.outputAdapterFor(*session); output != nil {
		output.RemoveSpool(session.Runtime)
	}
	agent.RemoveBinding(id)
	return s.Store.Update(func(value *api.State) error {
		value.Sessions = filter(value.Sessions, func(item api.Session) bool { return item.ID != id })
		return nil
	})
}

func (s *Service) Session(id string) (api.Session, bool) {
	for _, session := range s.Store.Snapshot().Sessions {
		if session.ID == id {
			return session, true
		}
	}
	return api.Session{}, false
}

// SessionMoveExpectations are optional compare-and-swap guards. A nil pointer
// means the caller did not observe that piece of source context and therefore
// does not ask the Host to guard it. A non-nil pointer, including an empty
// string, is an explicit expectation.
type SessionMoveExpectations struct {
	WorkspaceID    *string
	AgentSessionID *string
}

// MoveSession changes the Host scope of a Session between a Workspace and a
// Terminal Group. The compatibility wrapper keeps existing API callers
// working; new callers should use MoveSessionWithExpectations.
func (s *Service) MoveSession(ctx context.Context, id, workspaceID, groupID string) (api.Session, error) {
	return s.MoveSessionWithExpectations(ctx, id, workspaceID, groupID, SessionMoveExpectations{})
}

// MoveSessionWithExpectations performs an atomic move with optional source
// context guards and records a reversible operation audit entry. The runtime,
// working directory, output history, and Session ID are all preserved.
func (s *Service) MoveSessionWithExpectations(_ context.Context, id, workspaceID, groupID string, expectations SessionMoveExpectations) (api.Session, error) {
	if workspaceID == "" && groupID == "" {
		return api.Session{}, errors.New("workspace or terminal group is required")
	}
	if workspaceID != "" && groupID != "" {
		return api.Session{}, errors.New("workspace and terminal group are mutually exclusive")
	}
	s.terminalGroupLifecycleMu.Lock()
	defer s.terminalGroupLifecycleMu.Unlock()

	var moved api.Session
	var operationID string
	err := s.Store.Update(func(value *api.State) error {
		index := -1
		for candidate := range value.Sessions {
			if value.Sessions[candidate].ID == id {
				index = candidate
				break
			}
		}
		if index < 0 {
			return fmt.Errorf("session not found: %s", id)
		}
		session := value.Sessions[index]
		if expectations.WorkspaceID != nil && session.WorkspaceID != *expectations.WorkspaceID {
			return fmt.Errorf("stale session context for %s: expected workspace %q, found %q; refresh session list and retry", id, *expectations.WorkspaceID, session.WorkspaceID)
		}
		if expectations.AgentSessionID != nil && session.AgentSessionID != *expectations.AgentSessionID {
			return fmt.Errorf("stale agent session context for %s: expected agent session %q, found %q; refresh session list and retry", id, *expectations.AgentSessionID, session.AgentSessionID)
		}
		if workspaceID != "" {
			if !workspaceExists(value, workspaceID) {
				return fmt.Errorf("workspace not found: %s", workspaceID)
			}
		} else if !terminalGroupExists(value, groupID) {
			return fmt.Errorf("terminal group not found: %s", groupID)
		}
		if session.WorkspaceID == workspaceID && session.TerminalGroupID == groupID {
			moved = session
			return nil
		}

		beforeWorkspaceID := session.WorkspaceID
		beforeGroupID := session.TerminalGroupID
		session.WorkspaceID = workspaceID
		session.TerminalGroupID = groupID
		session.Scope = api.SessionScopeWorkspace
		if groupID != "" {
			session.Scope = api.SessionScopeTerminalGroup
		}
		value.Sessions[index] = session
		operationID = store.NewID()
		value.Operations = append(value.Operations, api.OperationAudit{
			ID: operationID, Kind: "session.move", Resource: "session", ResourceID: id,
			BeforeWorkspaceID: beforeWorkspaceID, BeforeTerminalGroupID: beforeGroupID,
			AfterWorkspaceID: workspaceID, AfterTerminalGroupID: groupID,
			AgentSessionID: session.AgentSessionID,
			CreatedAt:      time.Now().UTC(),
		})
		if len(value.Operations) > operationAuditLimit {
			value.Operations = append([]api.OperationAudit(nil), value.Operations[len(value.Operations)-operationAuditLimit:]...)
		}
		moved = session
		return nil
	})
	if err != nil {
		return api.Session{}, err
	}
	moved.OperationID = operationID
	return moved, nil
}

func workspaceExists(state *api.State, id string) bool {
	for _, workspace := range state.Workspaces {
		if workspace.ID == id {
			return true
		}
	}
	return false
}

func terminalGroupExists(state *api.State, id string) bool {
	for _, group := range state.TerminalGroups {
		if group.ID == id {
			return true
		}
	}
	return false
}

// PreflightSessionMove validates a move without changing durable state. It
// uses the same context checks as the atomic mutation path so dry-run output
// is actionable rather than a best-effort local guess.
func (s *Service) PreflightSessionMove(id, workspaceID, groupID string, expectations SessionMoveExpectations) (api.SessionMovePreflight, error) {
	if workspaceID == "" && groupID == "" {
		return api.SessionMovePreflight{}, errors.New("workspace or terminal group is required")
	}
	if workspaceID != "" && groupID != "" {
		return api.SessionMovePreflight{}, errors.New("workspace and terminal group are mutually exclusive")
	}
	state := s.Store.Snapshot()
	var session api.Session
	found := false
	for _, candidate := range state.Sessions {
		if candidate.ID == id {
			session = candidate
			found = true
			break
		}
	}
	if !found {
		return api.SessionMovePreflight{}, fmt.Errorf("session not found: %s", id)
	}
	if expectations.WorkspaceID != nil && session.WorkspaceID != *expectations.WorkspaceID {
		return api.SessionMovePreflight{}, fmt.Errorf("stale session context for %s: expected workspace %q, found %q; refresh session list and retry", id, *expectations.WorkspaceID, session.WorkspaceID)
	}
	if expectations.AgentSessionID != nil && session.AgentSessionID != *expectations.AgentSessionID {
		return api.SessionMovePreflight{}, fmt.Errorf("stale agent session context for %s: expected agent session %q, found %q; refresh session list and retry", id, *expectations.AgentSessionID, session.AgentSessionID)
	}
	if workspaceID != "" && !workspaceExists(&state, workspaceID) {
		return api.SessionMovePreflight{}, fmt.Errorf("workspace not found: %s", workspaceID)
	}
	if groupID != "" && !terminalGroupExists(&state, groupID) {
		return api.SessionMovePreflight{}, fmt.Errorf("terminal group not found: %s", groupID)
	}
	result := api.SessionMovePreflight{
		Allowed: true, Session: session,
		SourceWorkspaceID: session.WorkspaceID, SourceTerminalGroupID: session.TerminalGroupID,
		DestinationWorkspaceID: workspaceID, DestinationTerminalGroupID: groupID,
	}
	if expectations.WorkspaceID != nil {
		result.ExpectedWorkspaceID = *expectations.WorkspaceID
	}
	if expectations.AgentSessionID != nil {
		result.ExpectedAgentSessionID = *expectations.AgentSessionID
	}
	return result, nil
}

// UndoSessionMove reverts a recorded move only while the session still has
// the exact post-move ownership recorded by the operation. Any intervening
// change fails closed and leaves both state and audit history untouched.
func (s *Service) UndoSessionMove(operationID string) (api.Session, error) {
	if strings.TrimSpace(operationID) == "" {
		return api.Session{}, errors.New("operation ID is required")
	}
	s.terminalGroupLifecycleMu.Lock()
	defer s.terminalGroupLifecycleMu.Unlock()
	var moved api.Session
	var reversalID string
	err := s.Store.Update(func(state *api.State) error {
		operationIndex := -1
		for index := len(state.Operations) - 1; index >= 0; index-- {
			if state.Operations[index].ID == operationID {
				operationIndex = index
				break
			}
		}
		if operationIndex < 0 {
			return fmt.Errorf("operation not found: %s", operationID)
		}
		operation := state.Operations[operationIndex]
		if operation.Kind != "session.move" || operation.Resource != "session" {
			return fmt.Errorf("operation is not an undoable session move: %s", operationID)
		}
		if operation.RevertedAt != nil {
			return fmt.Errorf("operation already reverted: %s", operationID)
		}
		sessionIndex := -1
		for index := range state.Sessions {
			if state.Sessions[index].ID == operation.ResourceID {
				sessionIndex = index
				break
			}
		}
		if sessionIndex < 0 {
			return fmt.Errorf("session not found for operation %s: %s", operationID, operation.ResourceID)
		}
		current := state.Sessions[sessionIndex]
		if current.WorkspaceID != operation.AfterWorkspaceID || current.TerminalGroupID != operation.AfterTerminalGroupID || current.AgentSessionID != operation.AgentSessionID {
			return fmt.Errorf("cannot undo operation %s: session context changed; expected workspace %q/group %q/agent %q, found workspace %q/group %q/agent %q", operationID, operation.AfterWorkspaceID, operation.AfterTerminalGroupID, operation.AgentSessionID, current.WorkspaceID, current.TerminalGroupID, current.AgentSessionID)
		}
		current.WorkspaceID = operation.BeforeWorkspaceID
		current.TerminalGroupID = operation.BeforeTerminalGroupID
		current.Scope = api.SessionScopeWorkspace
		if current.TerminalGroupID != "" {
			current.Scope = api.SessionScopeTerminalGroup
		}
		state.Sessions[sessionIndex] = current
		now := time.Now().UTC()
		state.Operations[operationIndex].RevertedAt = &now
		reversalID = store.NewID()
		state.Operations = append(state.Operations, api.OperationAudit{
			ID: reversalID, Kind: "session.move.revert", Resource: "session", ResourceID: current.ID,
			BeforeWorkspaceID: operation.AfterWorkspaceID, BeforeTerminalGroupID: operation.AfterTerminalGroupID,
			AfterWorkspaceID: operation.BeforeWorkspaceID, AfterTerminalGroupID: operation.BeforeTerminalGroupID,
			AgentSessionID:     operation.AgentSessionID,
			RevertsOperationID: operationID, CreatedAt: now,
		})
		if len(state.Operations) > operationAuditLimit {
			state.Operations = append([]api.OperationAudit(nil), state.Operations[len(state.Operations)-operationAuditLimit:]...)
		}
		moved = current
		return nil
	})
	if err != nil {
		return api.Session{}, err
	}
	moved.OperationID = reversalID
	return moved, nil
}

func (s *Service) removeWorkspaceRuntime(ctx context.Context, state api.State, workspaceID string) error {
	for _, session := range state.Sessions {
		if session.WorkspaceID == workspaceID {
			_ = s.runtimeFor(session).Kill(ctx, session.Runtime)
			s.stopOutput(session.ID, true)
			if output := s.outputAdapterFor(session); output != nil {
				output.RemoveSpool(session.Runtime)
			}
			agent.RemoveBinding(session.ID)
		}
	}
	return nil
}

func (s *Service) removeTerminalGroupRuntimes(ctx context.Context, state api.State, groupID string) {
	for _, session := range state.Sessions {
		if session.TerminalGroupID != groupID || session.Lifecycle != "running" {
			continue
		}
		_ = s.runtimeFor(session).Kill(ctx, session.Runtime)
		s.stopOutput(session.ID, true)
		if output := s.outputAdapterFor(session); output != nil {
			output.RemoveSpool(session.Runtime)
		}
		agent.RemoveBinding(session.ID)
	}
}

func sessionWorkingDirectory(state api.State, workspaceID, groupID string) (string, error) {
	if groupID != "" {
		for _, group := range state.TerminalGroups {
			if group.ID != groupID {
				continue
			}
			home := group.Home
			if home == "" {
				var err error
				home, err = os.UserHomeDir()
				if err != nil {
					return "", fmt.Errorf("resolve host home directory: %w", err)
				}
			}
			info, err := os.Stat(home)
			if err != nil || !info.IsDir() {
				return "", fmt.Errorf("terminal group home is not a directory: %s", home)
			}
			return home, nil
		}
		return "", fmt.Errorf("terminal group not found: %s", groupID)
	}
	for _, workspace := range state.Workspaces {
		if workspace.ID == workspaceID {
			return workspace.Path, nil
		}
	}
	return "", fmt.Errorf("workspace not found: %s", workspaceID)
}

// ensureOutput adopts a running Session: idempotently installs the output
// pipe, opens the spool watcher from the persisted offset, and creates the
// output ring. Repeating attach/adopt never stacks another pipe.
func (s *Service) ensureOutput(ctx context.Context, session api.Session) (*outputSession, error) {
	s.lazyInit()
	s.outputMu.Lock()
	if existing := s.outputs[session.ID]; existing != nil {
		s.outputMu.Unlock()
		return existing, nil
	}
	s.outputMu.Unlock()

	adapter := s.outputAdapterFor(session)
	if adapter == nil {
		ring := output.NewRing(session.Epoch, s.ringCapacity(), s.ringMaxBytes(), session.Sequence)
		outputSession := &outputSession{
			sessionID:   session.ID,
			runtimeName: session.Runtime,
			runtimeKind: s.runtimeKindFor(session),
			ring:        ring,
			responder:   s.newQueryResponder(),
			prepareLock: newSessionLock(),
		}
		s.outputMu.Lock()
		s.outputs[session.ID] = outputSession
		s.outputMu.Unlock()
		return outputSession, nil
	}
	pipeContext, cancelPipe := context.WithTimeout(ctx, s.commandTimeout())
	defer cancelPipe()
	if err := adapter.EnsurePipe(pipeContext, session.Runtime); err != nil {
		return nil, err
	}
	spoolOffset := int64(session.Sequence)
	if size, err := adapter.SpoolSize(ctx, session.Runtime); err == nil && size < spoolOffset {
		spoolOffset = 0
	}
	// Adoption always reanchors the next client once: tmux may have emitted
	// bytes while this Host was down and the spool could not capture them.
	// A snapshot restores the screen without pretending the byte stream has
	// no gap.
	outputSession := &outputSession{
		sessionID:         session.ID,
		runtimeName:       session.Runtime,
		runtimeKind:       s.runtimeKindFor(session),
		responder:         s.newQueryResponder(),
		prepareLock:       newSessionLock(),
		persistedSequence: session.Sequence,
		reanchorRequired:  true,
	}
	watcher, err := ghostline.NewSpoolWatcher(
		adapter.SpoolPath(session.Runtime),
		spoolOffset,
		func(data []byte) { s.recordOutput(session.ID, data) },
		func() { s.rotated(session.ID) },
		func() { s.compactSpool(session.ID) },
	)
	if err != nil {
		return nil, fmt.Errorf("watch output spool: %w", err)
	}
	watcher.SetMaxBytes(s.maxSpoolBytes())
	watcher.Start()
	outputSession.watcher = watcher
	outputSession.ring = output.NewRing(session.Epoch, s.ringCapacity(), s.ringMaxBytes(), session.Sequence)

	s.outputMu.Lock()
	if previous := s.outputs[session.ID]; previous != nil {
		s.outputMu.Unlock()
		watcher.Close()
		return previous, nil
	}
	s.outputs[session.ID] = outputSession
	s.outputMu.Unlock()
	return outputSession, nil
}

// ensureAgent starts a transcript watcher for a running Codex/Claude session
// or for a plain shell/custom session that has a live Warren-managed agent
// binding (the user started the CLI manually inside the shell). The watcher
// is best-effort: no transcript yet, an unknown CLI layout, or a missing CLI
// must never make the terminal session fail.
func (s *Service) ensureAgent(ctx context.Context, session api.Session) (*agentSession, error) {
	dedicated := session.Kind == "codex" || session.Kind == "claude"
	shellOverlay := session.Kind == "shell" || session.Kind == "custom"
	if !dedicated && !shellOverlay {
		return nil, nil
	}
	if dedicated && s.AgentFinder == nil {
		return nil, nil
	}

	workspacePath, pathErr := sessionWorkingDirectory(
		s.Store.Snapshot(),
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
	if dedicated {
		s.lazyInit()

		// Resolve the current binding before looking at the running watcher:
		// Codex starts a fresh rollout after `/clear`, so the SessionStart
		// hook can report a new session id and transcript path while the
		// daemon is still projecting the old file.
		transcriptPath = s.boundTranscript(session, workspacePath)
		if binding, err := agent.ReadBinding(agent.BindPath(session.ID)); err == nil && binding != nil {
			agentSessionID = binding.SessionID
		}

		s.agentsMu.Lock()
		entry := s.agents[session.ID]
		if entry == nil {
			entry = &agentSession{}
			s.agents[session.ID] = entry
		}
		if entry.watcher != nil {
			s.agentsMu.Unlock()
			if transcriptPath != "" && entry.watcher.Path() != transcriptPath {
				// Re-bind to the CLI's new transcript; startAgentWatcher
				// resets the stale projection before switching files.
				entry = s.startAgentWatcher(session.ID, provider, transcriptPath, false)
				s.persistAgentMeta(session.ID, agentSessionID, transcriptPath)
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
			if err != nil || found == "" || s.transcriptTakenByOther(found, session.ID) {
				// Keep the placeholder so reconcile retries at its next tick
				// instead of re-running discovery concurrently from every caller.
				return entry, nil
			}
			transcriptPath = found
		}
	} else {
		binding, err := agent.ReadBinding(agent.BindPath(session.ID))
		if err != nil || binding == nil || (binding.Provider != "codex" && binding.Provider != "claude") {
			s.clearShellAgent(session)
			return nil, nil
		}
		state, stateErr := agent.ReadAgentStatus(agent.StatePath(session.ID))
		if stateErr == nil && state.Activity == api.AgentActivityExited {
			s.clearShellAgent(session)
			return nil, nil
		}
		info, statErr := os.Stat(binding.TranscriptPath)
		if statErr != nil || info.IsDir() {
			return nil, nil
		}
		if s.transcriptTakenByOther(binding.TranscriptPath, session.ID) {
			return nil, nil
		}
		provider = binding.Provider
		agentSessionID = binding.SessionID
		transcriptPath = binding.TranscriptPath
	}

	entry := s.startAgentWatcher(session.ID, provider, transcriptPath, !dedicated)
	s.persistAgentMeta(session.ID, agentSessionID, transcriptPath)
	return entry, nil
}

// startAgentWatcher starts (or reuses) the transcript watcher for one
// session. For shell overlays the ready state is seeded immediately so the
// roster shows a live agent even before the first transcript event arrives.
func (s *Service) startAgentWatcher(sessionID, provider, transcriptPath string, seedReady bool) *agentSession {
	s.lazyInit()
	s.agentsMu.Lock()
	existing := s.agents[sessionID]
	state, _ := agent.ReadAgentStatus(agent.StatePath(sessionID))
	if existing != nil && existing.watcher != nil && existing.watcher.Path() == transcriptPath {
		if seedReady && state.Activity != api.AgentActivityExited {
			existing.mu.Lock()
			if existing.status.Activity == api.AgentActivityExited {
				existing.status = api.AgentStatus{Activity: api.AgentActivityReady}
			}
			existing.mu.Unlock()
		}
		s.agentsMu.Unlock()
		return existing
	}
	rebinding := existing != nil && existing.watcher != nil
	var closing *agent.Watcher
	if rebinding {
		closing = existing.watcher
		existing.watcher = nil
		existing.mu.Lock()
		existing.events = nil
		existing.status = api.AgentStatus{}
		existing.turn = api.AgentTurn{}
		existing.mu.Unlock()
	} else if existing != nil {
		existing.mu.Lock()
		existing.status = api.AgentStatus{}
		existing.mu.Unlock()
	}
	if existing == nil {
		existing = &agentSession{}
		s.agents[sessionID] = existing
	}
	if seedReady {
		existing.mu.Lock()
		if existing.status.Activity == "" || existing.status.Activity == api.AgentActivityExited {
			existing.status = api.AgentStatus{Activity: api.AgentActivityReady}
		}
		existing.mu.Unlock()
	}
	if state.Activity == api.AgentActivityExited {
		existing.mu.Lock()
		existing.status = state
		existing.mu.Unlock()
	}
	s.agentsMu.Unlock()
	if rebinding {
		// A session switch (e.g. `/clear`) starts a fresh projection: bump
		// the epoch so attached clients drop the old transcript's events and
		// refetch the new rollout from history.
		s.bumpAgentEpoch()
		s.broadcastAgentReset(sessionID)
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
	s.agentsMu.Lock()
	current := s.agents[sessionID]
	if current == nil || current.watcher != nil {
		s.agentsMu.Unlock()
		if closing != nil {
			closing.Close()
		}
		watcher.Close()
		return current
	}
	current.watcher = watcher
	s.agentsMu.Unlock()
	if closing != nil {
		closing.Close()
	}
	return current
}

// clearShellAgent tears down a shell overlay after its agent CLI exited and
// drops the persisted binding so clients stop treating the tab as an agent.
func (s *Service) clearShellAgent(session api.Session) {
	if session.Kind == "codex" || session.Kind == "claude" {
		return
	}
	s.agentsMu.Lock()
	entry := s.agents[session.ID]
	s.agentsMu.Unlock()
	hasWatcher := entry != nil && entry.watcher != nil
	if !hasWatcher && session.AgentSessionID == "" && session.TranscriptPath == "" {
		return
	}
	s.stopAgent(session.ID)
	_ = s.Store.Update(func(state *api.State) error {
		for index := range state.Sessions {
			if state.Sessions[index].ID == session.ID {
				state.Sessions[index].AgentSessionID = ""
				state.Sessions[index].TranscriptPath = ""
			}
		}
		return nil
	})
}

// transcriptTakenByOther prevents the cwd+mtime fallback from assigning one
// transcript to several Warren sessions. A transcript that another running
// session already projects must never be stolen.
func (s *Service) transcriptTakenByOther(transcriptPath, sessionID string) bool {
	for _, other := range s.Store.Snapshot().Sessions {
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

// persistAgentMeta records the CLI session ID and transcript path on the
// Session so roster consumers and a daemon restart keep the exact binding.
func (s *Service) persistAgentMeta(sessionID, agentSessionID, transcriptPath string) {
	for _, session := range s.Store.Snapshot().Sessions {
		if session.ID != sessionID {
			continue
		}
		if session.AgentSessionID == agentSessionID && session.TranscriptPath == transcriptPath {
			return
		}
		_ = s.Store.Update(func(value *api.State) error {
			for index := range value.Sessions {
				if value.Sessions[index].ID == sessionID {
					value.Sessions[index].AgentSessionID = agentSessionID
					value.Sessions[index].TranscriptPath = transcriptPath
				}
			}
			return nil
		})
		return
	}
}

// recordAgentEvents stores a bounded event history and forwards the batch to
// every peer attached to the session.
func (s *Service) recordAgentEvents(sessionID string, events []api.AgentEvent, status api.AgentStatus) {
	if len(events) == 0 {
		return
	}
	s.lazyInit()
	s.agentsMu.Lock()
	effectiveStatus := status
	if entry := s.agents[sessionID]; entry != nil {
		entry.mu.Lock()
		entry.events = append(entry.events, events...)
		if len(entry.events) > 2000 {
			entry.events = append([]api.AgentEvent(nil), entry.events[len(entry.events)-2000:]...)
		}
		if entry.status.Activity == api.AgentActivityExited && status.Activity != api.AgentActivityExited {
			effectiveStatus = entry.status
		} else {
			entry.status = status
			effectiveStatus = entry.status
		}
		entry.mu.Unlock()
	}
	s.agentsMu.Unlock()
	s.broadcastAgentIncrements(sessionID, events, effectiveStatus)
}

// recordAgentStatus forwards a status change that arrived without new
// transcript events, such as a liveness warning.
func (s *Service) recordAgentStatus(sessionID string, status api.AgentStatus) {
	s.setAgentStatus(sessionID, status, false)
}

// recordAgentTurns stores the latest turn cursor and optionally broadcasts
// live boundaries. Historical replay updates the snapshot without waking a
// waiter for work that completed before it subscribed.
func (s *Service) recordAgentTurns(sessionID string, turns []api.AgentTurn, broadcast bool) {
	if len(turns) == 0 {
		return
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
		entry.turn = turn
		entry.mu.Unlock()
		s.agentsMu.Unlock()
		if broadcast {
			s.broadcastAgentTurn(sessionID, turn)
		}
	}
}

// forceAgentStatus records a state transition that must override an exited
// marker, such as a new SessionStart resetting the shell overlay to ready.
func (s *Service) forceAgentStatus(sessionID string, status api.AgentStatus) {
	s.setAgentStatus(sessionID, status, true)
}

func (s *Service) setAgentStatus(sessionID string, status api.AgentStatus, force bool) {
	s.lazyInit()
	s.agentsMu.Lock()
	entry := s.agents[sessionID]
	if entry == nil {
		entry = &agentSession{}
		s.agents[sessionID] = entry
	}
	entry.mu.Lock()
	if !force && entry.status.Activity == api.AgentActivityExited && status.Activity != api.AgentActivityExited {
		entry.mu.Unlock()
		s.agentsMu.Unlock()
		return
	}
	entry.status = status
	entry.mu.Unlock()
	s.agentsMu.Unlock()
	s.broadcastAgentStatus(sessionID, status)
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

// agentHistoryPage returns the newest `limit` events with sequence strictly
// below `before` (zero means the newest page). Cursor in the result is the
// first event's sequence and can be passed back as `before` to page further
// into the past.
func (s *Service) agentHistoryPage(sessionID string, before uint64, limit int) api.AgentHistoryResult {
	if limit <= 0 {
		limit = agentHistoryDefaultLimit
	}
	if limit > agentHistoryMaxLimit {
		limit = agentHistoryMaxLimit
	}
	s.lazyInit()
	s.agentsMu.Lock()
	entry := s.agents[sessionID]
	s.agentsMu.Unlock()
	result := api.AgentHistoryResult{Epoch: s.currentAgentEpoch()}
	if entry == nil {
		return result
	}
	entry.mu.Lock()
	events := entry.events
	entry.mu.Unlock()
	if len(events) == 0 {
		return result
	}
	var page []api.AgentEvent
	start := 0
	if before > 0 {
		// Events are stored in sequence order. Find the first event at or
		// above the bound and take the `limit` events immediately before it.
		index := sort.Search(len(events), func(i int) bool {
			return events[i].Sequence >= before
		})
		start = max(0, index-limit)
		page = events[start:index]
	} else {
		start = max(0, len(events)-limit)
		page = events[start:]
	}
	if len(page) == 0 {
		return result
	}
	result.Events = append([]api.AgentEvent(nil), page...)
	result.Cursor = page[0].Sequence
	result.HasMore = start > 0
	return result
}

// agentTail returns the newest events fitting both the event-count and
// serialized-byte budgets. It is used for the bounded initial replay during
// attach; clients fetch the full conversation through agent.history.
func (s *Service) agentTail(sessionID string, maxEvents, maxBytes int) []api.AgentEvent {
	if maxEvents <= 0 || maxBytes <= 0 {
		return nil
	}
	s.lazyInit()
	s.agentsMu.Lock()
	entry := s.agents[sessionID]
	s.agentsMu.Unlock()
	if entry == nil {
		return nil
	}
	entry.mu.Lock()
	events := entry.events
	entry.mu.Unlock()
	sizes := make([]int, len(events))
	for index := range events {
		if encoded, err := json.Marshal(events[index]); err == nil {
			sizes[index] = len(encoded)
		}
	}
	start := len(events)
	total := 0
	for index := len(events) - 1; index >= 0 && len(events)-start < maxEvents; index-- {
		// The newest event always joins the tail even when a single event is
		// itself over budget, so a huge event still renders immediately.
		if total > 0 && total+sizes[index] > maxBytes {
			break
		}
		start = index
		total += sizes[index]
	}
	if start == len(events) {
		return nil
	}
	return append([]api.AgentEvent(nil), events[start:]...)
}

// splitAgentEvents greedily groups events so every returned batch serializes
// to at most maxBytes. A single event larger than the budget forms its own
// batch instead of being dropped or split mid-event.
func splitAgentEvents(events []api.AgentEvent, maxBytes int) [][]api.AgentEvent {
	var batches [][]api.AgentEvent
	var current []api.AgentEvent
	total := 0
	for _, event := range events {
		encoded, err := json.Marshal(event)
		size := 0
		if err == nil {
			size = len(encoded)
		}
		if len(current) > 0 && total+size > maxBytes {
			batches = append(batches, current)
			current = nil
			total = 0
		}
		current = append(current, event)
		total += size
	}
	if len(current) > 0 {
		batches = append(batches, current)
	}
	return batches
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

func (s *Service) agentSnapshot(sessionID string) api.AgentSnapshotResult {
	result := api.AgentSnapshotResult{
		Epoch: s.currentAgentEpoch(),
		Turn:  s.agentTurn(sessionID),
	}
	if history := s.agentHistory(sessionID); len(history) > 0 {
		result.Sequence = history[len(history)-1].Sequence
	}
	return result
}

func (s *Service) agentTurnEvents(sessionID string, turn uint64) []api.AgentEvent {
	history := s.agentHistory(sessionID)
	events := make([]api.AgentEvent, 0)
	for _, event := range history {
		if event.Turn == turn {
			events = append(events, event)
		}
	}
	return events
}

func (s *Service) waitAgentReady(ctx context.Context, sessionID string) error {
	s.lazyInit()
	s.agentsMu.Lock()
	entry := s.agents[sessionID]
	var watcher *agent.Watcher
	if entry != nil {
		watcher = entry.watcher
	}
	s.agentsMu.Unlock()
	if watcher == nil {
		return fmt.Errorf("agent is still starting for session %s; finish first-time setup in Terminal and retry", sessionID)
	}
	return watcher.WaitReady(ctx)
}

// applyAgentState reflects the managed hook's SessionEnd state on the status
// light: the agent CLI is gone, but the Warren session is still a shell.
func (s *Service) applyAgentState(session api.Session) {
	if session.Kind != "codex" && session.Kind != "claude" {
		return
	}
	state, err := agent.ReadAgentStatus(agent.StatePath(session.ID))
	if err != nil || state.Activity == "" {
		return
	}
	current := s.agentStatus(session.ID)
	switch state.Activity {
	case api.AgentActivityExited:
		if current.Activity != state.Activity {
			s.recordAgentStatus(session.ID, state)
		}
	case api.AgentActivityReady:
		if current.Activity == api.AgentActivityExited {
			s.forceAgentStatus(session.ID, state)
		}
	}
}

func (s *Service) stopAgent(sessionID string) {
	s.lazyInit()
	s.agentsMu.Lock()
	entry := s.agents[sessionID]
	delete(s.agents, sessionID)
	s.agentsMu.Unlock()
	if entry != nil && entry.watcher != nil {
		entry.watcher.Close()
	}
}

// broadcastAgentIncrements pushes a live batch of agent events to attached
// peers, splitting the batch so no single WebSocket message exceeds
// agentMessageMaxBytes, then broadcasts the accompanying complete status as
// its own lightweight message.
func (s *Service) broadcastAgentIncrements(sessionID string, events []api.AgentEvent, status api.AgentStatus) {
	if len(events) > 0 {
		for _, batch := range splitAgentEvents(events, agentMessageMaxBytes) {
			s.broadcastAgentBatch(sessionID, batch)
		}
	}
	if status.Activity != "" {
		s.broadcastAgentStatus(sessionID, status)
	}
}

func (s *Service) broadcastAgentBatch(sessionID string, events []api.AgentEvent) {
	s.broadcastAgent(func(peer *wsPeer) error {
		return peer.enqueueAgentEvents(sessionID, events)
	}, sessionID)
}

// broadcastAgentReset tells attached peers that the session switched to a
// new transcript. The empty batch with a new epoch makes clients drop their
// stale event projection and refetch history from the replacement rollout.
func (s *Service) broadcastAgentReset(sessionID string) {
	s.broadcastAgent(func(peer *wsPeer) error {
		return peer.writeJSON(api.AgentMessage{
			Type:    "agent",
			Session: sessionID,
			Epoch:   s.currentAgentEpoch(),
			Events:  []api.AgentEvent{},
		})
	}, sessionID)
}

func (s *Service) broadcastAgentStatus(sessionID string, status api.AgentStatus) {
	if status.Activity == "" {
		return
	}
	s.broadcastAgent(func(peer *wsPeer) error {
		return peer.enqueueAgentStatus(sessionID, status)
	}, sessionID)
}

func (s *Service) broadcastAgentTurn(sessionID string, turn api.AgentTurn) {
	if turn.Status == "" {
		return
	}
	s.broadcastAgent(func(peer *wsPeer) error {
		return peer.enqueueAgentTurn(sessionID, turn)
	}, sessionID)
}

// broadcastAgent delivers one outbound message to terminal peers and
// agent-only subscribers under the session broadcast lock.
func (s *Service) broadcastAgent(send func(*wsPeer) error, sessionID string) {
	lock := s.broadcastLock(sessionID)
	lock.Lock()
	defer lock.Unlock()
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

func (s *Service) currentAgentEpoch() uint64 {
	s.outputMu.Lock()
	defer s.outputMu.Unlock()
	return s.agentEpoch
}

// bumpAgentEpoch advances the projection generation so clients that were
// attached to the previous transcript reset instead of merging sequences.
func (s *Service) bumpAgentEpoch() {
	s.outputMu.Lock()
	s.agentEpoch++
	s.outputMu.Unlock()
}

func (s *Service) ringCapacity() int {
	if s.RingCapacity > 0 {
		return s.RingCapacity
	}
	return defaultRingCapacity
}

func (s *Service) ringMaxBytes() int {
	if s.RingMaxBytes > 0 {
		return s.RingMaxBytes
	}
	return defaultRingMaxBytes
}

func (s *Service) maxSpoolBytes() int64 {
	if s.MaxSpoolBytes > 0 {
		return s.MaxSpoolBytes
	}
	return defaultMaxSpool
}

func (s *Service) maxSpoolReplayBytes() int64 {
	if s.MaxSpoolReplayBytes > 0 {
		return s.MaxSpoolReplayBytes
	}
	return int64(s.ringMaxBytes())
}

func (s *Service) commandTimeout() time.Duration {
	if s.CommandTimeout > 0 {
		return s.CommandTimeout
	}
	return defaultCommandTimeout
}

func (s *Service) recordOutput(sessionID string, data []byte) {
	s.outputMu.Lock()
	outputSession := s.outputs[sessionID]
	attached := len(s.peers[sessionID]) > 0
	s.outputMu.Unlock()
	if outputSession == nil {
		return
	}
	var replies [][]byte
	for _, chunk := range output.SplitPayload(data) {
		outputSession.mu.Lock()
		frame, err := outputSession.ring.Append(sessionID, chunk)
		epoch := outputSession.ring.Epoch
		sequence := outputSession.ring.Upper()
		if !attached {
			replies = append(replies, outputSession.responder.Feed(chunk)...)
		}
		outputSession.mu.Unlock()
		if err != nil {
			continue
		}
		// Ring first, then clients: recovery is always authoritative even when
		// a peer cannot keep up and has to reconnect.
		s.broadcastFrame(frame)
		s.maybePersistCursor(sessionID, epoch, sequence)
	}
	for _, reply := range replies {
		_ = s.runtimeForKind(outputSession.runtimeKind).Input(context.Background(), outputSession.runtimeName, reply)
	}
}

func (s *Service) maybePersistCursor(sessionID string, epoch, sequence uint64) {
	s.outputMu.Lock()
	outputSession := s.outputs[sessionID]
	s.outputMu.Unlock()
	if outputSession == nil {
		return
	}
	outputSession.mu.Lock()
	if sequence-outputSession.persistedSequence < cursorPersistEvery {
		outputSession.mu.Unlock()
		return
	}
	outputSession.persistedSequence = sequence
	err := s.persistCursorLocked(outputSession)
	outputSession.mu.Unlock()
	_ = err
}

func (s *Service) persistCursorLocked(outputSession *outputSession) error {
	epoch := outputSession.ring.Epoch
	sequence := outputSession.ring.Upper()
	return s.Store.Update(func(value *api.State) error {
		for index := range value.Sessions {
			if value.Sessions[index].ID == outputSession.sessionID && value.Sessions[index].Lifecycle == "running" {
				value.Sessions[index].Epoch = epoch
				value.Sessions[index].Sequence = sequence
			}
		}
		return nil
	})
}

func (s *Service) broadcastFrame(frame output.Frame) {
	encoded, err := output.EncodeOutput(frame.SessionID, frame.Epoch, frame.Sequence, frame.Payload)
	if err != nil {
		return
	}
	lock := s.broadcastLock(frame.SessionID)
	if !lock.TryLock() {
		// Focus and resize briefly hold the same lock while the runtime applies a
		// PTY size. Do not reset a healthy WebSocket for that normal contention:
		// waiting for a bounded interval preserves frame ordering and lets the
		// current frame reach the client. A genuinely wedged attach/focus still
		// falls through to the existing reanchor path after the deadline.
		ctx, cancel := context.WithTimeout(context.Background(), broadcastLockWait)
		err := lock.LockContext(ctx)
		cancel()
		if err != nil {
			s.forceSessionReanchor(frame.SessionID)
			return
		}
	}
	defer lock.Unlock()
	s.outputMu.Lock()
	peers := make([]*wsPeer, 0, len(s.peers[frame.SessionID]))
	for peer := range s.peers[frame.SessionID] {
		peers = append(peers, peer)
	}
	s.outputMu.Unlock()
	for _, peer := range peers {
		if !peer.enqueueBinary(encoded) {
			s.detachPeer(peer, frame.SessionID)
		}
	}
}

func (s *Service) broadcastLock(sessionID string) *sessionLock {
	s.outputMu.Lock()
	defer s.outputMu.Unlock()
	s.lazyInitLocked()
	lock := s.broadcastLocks[sessionID]
	if lock == nil {
		lock = newSessionLock()
		s.broadcastLocks[sessionID] = lock
	}
	return lock
}

// forceSessionReanchor drops slow or stale peers when output cannot acquire
// the session broadcast lock. The ring remains authoritative, so reconnecting
// peers receive a fresh snapshot and do not lose terminal state.
func (s *Service) forceSessionReanchor(sessionID string) {
	s.lazyInit()
	s.outputMu.Lock()
	outputSession := s.outputs[sessionID]
	peers := make([]*wsPeer, 0, len(s.peers[sessionID]))
	for peer := range s.peers[sessionID] {
		peers = append(peers, peer)
	}
	s.outputMu.Unlock()
	if outputSession == nil || len(peers) == 0 {
		return
	}
	outputSession.mu.Lock()
	outputSession.reanchorRequired = true
	outputSession.mu.Unlock()
	for _, peer := range peers {
		peer.close()
	}
}

// attachOutput prepares a peer's subscription under the session broadcast
// lock, so recovery replay can never interleave with newer live output.
func (s *Service) attachOutput(ctx context.Context, peer *wsPeer, session api.Session, anchor *output.Anchor) error {
	lock, resume, err := s.prepareAttach(ctx, session)
	if err != nil {
		return err
	}
	defer func() {
		lock.Unlock()
		resume()
	}()
	return s.attachOutputLocked(ctx, peer, session, anchor)
}

// prepareAttach pauses the session's spool watcher before taking the
// broadcast lock. A paused watcher cannot read or broadcast, so a reanchor
// snapshot is an atomic point in the byte stream: bytes at or below the
// snapshot are represented exactly once.
func (s *Service) prepareAttach(ctx context.Context, session api.Session) (*sessionLock, func(), error) {
	// The desktop client has a shorter request timeout than the daemon's
	// command timeout. Bound the entire preparation phase independently so a
	// stalled adoption, watcher, or lock cannot keep a WebSocket command
	// handler occupied forever.
	prepareContext, cancelPrepare := context.WithTimeout(ctx, s.commandTimeout())
	defer cancelPrepare()

	outputSession, err := s.ensureOutput(prepareContext, session)
	if err != nil {
		return nil, nil, err
	}
	s.outputMu.Lock()
	if outputSession.prepareLock == nil {
		outputSession.prepareLock = newSessionLock()
	}
	prepareLock := outputSession.prepareLock
	s.outputMu.Unlock()

	if err := prepareLock.LockContext(prepareContext); err != nil {
		return nil, nil, fmt.Errorf("lock attach preparation: %w", err)
	}

	var releaseOnce sync.Once
	release := func() {
		releaseOnce.Do(func() {
			if outputSession.watcher != nil {
				outputSession.watcher.Resume()
			}
			prepareLock.Unlock()
		})
	}
	if outputSession.watcher != nil {
		paused := make(chan struct{})
		go func() {
			outputSession.watcher.Pause()
			close(paused)
		}()
		select {
		case <-paused:
		case <-prepareContext.Done():
			// Pause has no cancellation-aware API in the current Ghostline
			// release. Finish it in the background and immediately resume the
			// watcher once it is safe, while unblocking this request now.
			go func() {
				<-paused
				release()
			}()
			return nil, nil, fmt.Errorf("pause output watcher: %w", prepareContext.Err())
		}
	}
	lock := s.broadcastLock(session.ID)
	if err := lock.LockContext(prepareContext); err != nil {
		release()
		return nil, nil, fmt.Errorf("lock session output: %w", err)
	}
	return lock, release, nil
}

func (s *Service) attachOutputLocked(ctx context.Context, peer *wsPeer, session api.Session, anchor *output.Anchor) error {
	s.lazyInit()
	s.outputMu.Lock()
	outputSession := s.outputs[session.ID]
	s.outputMu.Unlock()

	s.registerPeer(session.ID, peer)

	outputSession.mu.Lock()
	recovery := outputSession.ring.Recovery(anchor)
	reanchorRequired := outputSession.reanchorRequired
	outputSession.mu.Unlock()

	if !recovery.Reanchor && !reanchorRequired {
		// The attached cursor must point at the first frame the client is
		// about to receive. For a tail recovery the frames are trimmed to
		// start at the requested anchor, which can be after the ring's oldest
		// retained frame; reporting the lower bound would make a valid tail
		// look like a gap and trigger a reconnect loop.
		sequence := recovery.Upper
		if len(recovery.Frames) > 0 {
			sequence = recovery.Frames[0].Sequence
		}
		if err := peer.enqueueAttached(session.ID, recovery.Epoch, sequence, false); err != nil {
			return err
		}
		for _, frame := range recovery.Frames {
			encoded, encodeErr := output.EncodeOutput(frame.SessionID, frame.Epoch, frame.Sequence, frame.Payload)
			if encodeErr != nil {
				return encodeErr
			}
			if !peer.enqueueBinary(encoded) {
				return errors.New("outbound queue overflow during recovery")
			}
		}
		return peer.enqueueSynced(session.ID, recovery.Epoch, recovery.Upper)
	}

	// Spool recovery: when the ring evicted the client's anchor, the PTY
	// runtime can still serve the exact tail from its append-only spool.
	// Rendering those bytes as ordinary output avoids the screen reset and
	// full replay that otherwise flashes black on every reattach. Large gaps
	// are bounded by maxSpoolReplayBytes and fall through to the snapshot
	// reanchor instead of replaying tens of megabytes of raw output.
	if !reanchorRequired && anchor != nil && anchor.Epoch == recovery.Epoch {
		if recoverer, ok := s.runtimeFor(session).(SpoolRecoverer); ok && outputSession != nil && outputSession.watcher != nil {
			adapter := s.outputAdapterFor(session)
			size, sizeErr := adapter.SpoolSize(ctx, session.Runtime)
			if sizeErr == nil && anchor.Sequence <= uint64(size) {
				gap := size - int64(anchor.Sequence)
				if gap <= s.maxSpoolReplayBytes() {
					data, recoverErr := recoverer.Recover(ctx, session.Runtime, int64(anchor.Sequence), size)
					if recoverErr == nil && len(data) > 0 {
						if err := outputSession.watcher.SkipTo(size); err != nil {
							return err
						}
						upper := uint64(size)
						outputSession.mu.Lock()
						outputSession.ring.Reset(recovery.Epoch, upper)
						outputSession.persistedSequence = upper
						outputSession.reanchorRequired = false
						outputSession.mu.Unlock()
						if err := peer.enqueueAttached(session.ID, recovery.Epoch, uint64(anchor.Sequence), false); err != nil {
							return err
						}
						sequence := uint64(anchor.Sequence)
						for _, chunk := range output.SplitPayload(data) {
							encoded, encodeErr := output.EncodeOutput(session.ID, recovery.Epoch, sequence, chunk)
							if encodeErr != nil {
								return encodeErr
							}
							if !peer.enqueueBinary(encoded) {
								return errors.New("outbound queue overflow during spool recovery")
							}
							sequence += uint64(len(chunk))
						}
						return peer.enqueueSynced(session.ID, recovery.Epoch, upper)
					}
				}
			}
		}
	}

	// Reanchor: capture the real tmux screen and replay it as a snapshot
	// reset. Snapshot frames reuse the current upper sequence; clients do not
	// advance their anchor until the synced marker arrives.
	captureContext, cancelCapture := context.WithTimeout(ctx, s.commandTimeout())
	defer cancelCapture()
	snapshot, err := s.runtimeFor(session).Capture(captureContext, session.Runtime)
	if err != nil {
		return err
	}
	upper := recovery.Upper
	epoch := recovery.Epoch
	if outputSession != nil && outputSession.watcher != nil {
		// The capture snapshot is a rendered screen, not a byte position in
		// the append-only spool: capture-pane output can be much larger than
		// the raw PTY bytes (clear sequences, cursor restore, padded rows).
		// Skipping to len(snapshot) would overshoot the spool and make the
		// watcher misread every attach as an in-place compaction. Measure the
		// spool size before capturing and re-anchor the byte stream there.
		adapter := s.outputAdapterFor(session)
		size, sizeErr := adapter.SpoolSize(ctx, session.Runtime)
		if sizeErr != nil {
			return fmt.Errorf("read output spool size before reanchor: %w", sizeErr)
		}
		if err := outputSession.watcher.SkipTo(size); err != nil {
			return err
		}
		upper = uint64(size)
	}
	if outputSession != nil {
		outputSession.mu.Lock()
		outputSession.ring.Reset(epoch, upper)
		outputSession.persistedSequence = upper
		outputSession.reanchorRequired = false
		outputSession.mu.Unlock()
	}
	if err := peer.enqueueAttached(session.ID, epoch, upper, true); err != nil {
		return err
	}
	for _, chunk := range output.SplitPayload(snapshot) {
		encoded, encodeErr := output.EncodeOutput(session.ID, epoch, upper, chunk)
		if encodeErr != nil {
			return encodeErr
		}
		if !peer.enqueueBinary(encoded) {
			return errors.New("outbound queue overflow during reanchor")
		}
	}
	if err := peer.enqueueSynced(session.ID, epoch, upper); err != nil {
		return err
	}
	// The initial agent replay is intentionally bounded: the full history is
	// fetched page by page through agent.history, and the activity status is
	// its own lightweight message. Sending every retained event here would
	// create one oversized WebSocket message for transcripts with thousands
	// of events (and would burden clients that only render the status light).
	if status := s.agentStatus(session.ID); status.Activity != "" {
		if err := peer.enqueueAgentStatus(session.ID, status); err != nil {
			return err
		}
	}
	if tail := s.agentTail(session.ID, agentAttachHistoryMaxEvents, agentAttachHistoryMaxBytes); len(tail) > 0 {
		return peer.enqueueAgentEvents(session.ID, tail)
	}
	return nil
}

func (s *Service) PingOutput(sessionID string) {
	s.lazyInit()
	s.outputMu.Lock()
	outputSession := s.outputs[sessionID]
	s.outputMu.Unlock()
	if outputSession != nil && outputSession.watcher != nil {
		outputSession.watcher.Ping()
	}
}

func (s *Service) detachPeer(peer *wsPeer, sessionID string) {
	s.lazyInit()
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
	defer s.outputMu.Unlock()
	if peers := s.agentPeers[sessionID]; peers != nil {
		delete(peers, peer)
		if len(peers) == 0 {
			delete(s.agentPeers, sessionID)
		}
	}
}

func (s *Service) hasAgentPeers(sessionID string) bool {
	s.lazyInit()
	s.outputMu.Lock()
	defer s.outputMu.Unlock()
	return len(s.agentPeers[sessionID]) > 0
}

// registerPeer records a live output subscription. It is intentionally kept
// separate from attachOutputLocked so an attach can claim focus and resize
// the runtime before the first snapshot is captured.
func (s *Service) registerPeer(sessionID string, peer *wsPeer) {
	s.lazyInit()
	s.outputMu.Lock()
	defer s.outputMu.Unlock()
	if s.peers[sessionID] == nil {
		s.peers[sessionID] = map[*wsPeer]struct{}{}
	}
	s.peers[sessionID][peer] = struct{}{}
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
		if owner == peer {
			s.outputMu.Lock()
			if s.focusedPeers[session.ID] == peer {
				delete(s.focusedPeers, session.ID)
			}
			s.outputMu.Unlock()
		}
		return false, nil
	}
	if resizeSpecified {
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
	s.outputMu.Unlock()
	return resized, nil
}

// resizeFocusedLocked only lets the current focused peer mutate the shared
// tmux/PTY size. A background endpoint receives a successful no-op so stale
// browser resize callbacks do not surface as terminal errors.
func (s *Service) resizeFocusedLocked(
	ctx context.Context,
	peer *wsPeer,
	session api.Session,
	columns, rows int,
) (bool, error) {
	s.lazyInit()
	s.outputMu.Lock()
	focused := s.focusedPeers[session.ID] == peer
	s.outputMu.Unlock()
	if !focused {
		return false, nil
	}
	return s.resizeRuntime(ctx, session, columns, rows)
}

// resizeRuntime applies a new viewport to the shared runtime and records the
// size we last applied. Ghostline sends SIGWINCH to the child on every
// Resize, even when the dimensions are unchanged, so repeated claims of the
// same viewport (roster-driven focus requests, duplicate browser callbacks)
// make TUIs redraw and flicker. The recorded size also lets the server
// answer same-size focus/resize requests as accurate no-ops.
func (s *Service) resizeRuntime(ctx context.Context, session api.Session, columns, rows int) (bool, error) {
	size := ghostline.Size{Columns: columns, Rows: rows}
	s.lazyInit()
	s.outputMu.Lock()
	current, known := s.runtimeSizes[session.ID]
	s.outputMu.Unlock()
	if known && current == size {
		return false, nil
	}
	if err := s.runtimeFor(session).Resize(ctx, session.Runtime, columns, rows); err != nil {
		return false, err
	}
	s.outputMu.Lock()
	s.runtimeSizes[session.ID] = size
	s.outputMu.Unlock()
	s.updateResponderSize(session.ID, columns, rows)
	return true, nil
}

func (s *Service) updateResponderSize(sessionID string, columns, rows int) {
	s.outputMu.Lock()
	defer s.outputMu.Unlock()
	if outputSession := s.outputs[sessionID]; outputSession != nil {
		outputSession.responder.Resize(columns, rows)
	}
}

func (s *Service) focusPeer(
	ctx context.Context,
	peer *wsPeer,
	session api.Session,
	focused bool,
	columns, rows int,
	resizeSpecified bool,
) (bool, bool, error) {
	lock := s.broadcastLock(session.ID)
	lock.Lock()
	defer lock.Unlock()
	resized, err := s.focusPeerLocked(ctx, peer, session, focused, columns, rows, resizeSpecified)
	if err != nil {
		return false, false, err
	}
	return s.isFocused(peer, session.ID), resized, nil
}

func (s *Service) resizeFocused(
	ctx context.Context,
	peer *wsPeer,
	session api.Session,
	columns, rows int,
) (bool, error) {
	lock := s.broadcastLock(session.ID)
	lock.Lock()
	defer lock.Unlock()
	return s.resizeFocusedLocked(ctx, peer, session, columns, rows)
}

func (s *Service) isFocused(peer *wsPeer, sessionID string) bool {
	s.outputMu.Lock()
	defer s.outputMu.Unlock()
	return s.focusedPeers[sessionID] == peer
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
	delete(s.runtimeSizes, sessionID)
	s.outputMu.Unlock()
	if outputSession != nil && outputSession.watcher != nil {
		outputSession.watcher.Close()
	}
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
		return nil
	})
	if changed {
		s.stopOutput(sessionID, true)
	}
}

func (s *Service) compactSpool(sessionID string) {
	state := s.Store.Snapshot()
	var session api.Session
	for _, value := range state.Sessions {
		if value.ID == sessionID {
			session = value
			break
		}
	}
	if session.ID == "" {
		return
	}
	adapter := s.outputAdapterFor(session)
	if adapter == nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = adapter.ArchiveSpool(ctx, session.Runtime)
	_ = adapter.TruncateSpool(ctx, session.Runtime)
}

// rotated runs when the spool watcher observes an in-place compaction. Host
// bumps the epoch, resets the ring, persists the cursor, and reanchors every
// attached peer with a fresh tmux snapshot.
func (s *Service) rotated(sessionID string) {
	s.lazyInit()
	state := s.Store.Snapshot()
	var session api.Session
	for _, value := range state.Sessions {
		if value.ID == sessionID {
			session = value
			break
		}
	}
	if session.ID == "" {
		return
	}
	s.outputMu.Lock()
	outputSession := s.outputs[sessionID]
	s.outputMu.Unlock()
	if outputSession == nil {
		return
	}
	lock := s.broadcastLock(sessionID)
	lock.Lock()
	defer lock.Unlock()
	outputSession.mu.Lock()
	outputSession.ring.Reset(outputSession.ring.Epoch+1, 0)
	outputSession.persistedSequence = 0
	_ = s.persistCursorLocked(outputSession)
	outputSession.mu.Unlock()

	captureContext, cancelCapture := context.WithTimeout(context.Background(), s.commandTimeout())
	defer cancelCapture()
	snapshot, err := s.runtimeFor(session).Capture(captureContext, session.Runtime)
	if err != nil {
		return
	}
	s.outputMu.Lock()
	peers := make([]*wsPeer, 0, len(s.peers[sessionID]))
	for peer := range s.peers[sessionID] {
		peers = append(peers, peer)
	}
	s.outputMu.Unlock()
	epoch := outputSession.ring.Epoch
	for _, peer := range peers {
		_ = peer.enqueueAttached(session.ID, epoch, 0, true)
		for _, chunk := range output.SplitPayload(snapshot) {
			if encoded, encodeErr := output.EncodeOutput(session.ID, epoch, 0, chunk); encodeErr == nil {
				if !peer.enqueueBinary(encoded) {
					s.detachPeer(peer, sessionID)
				}
			}
		}
		_ = peer.enqueueSynced(session.ID, epoch, 0)
	}
}

func gitOutput(path string, args ...string) string {
	return strings.TrimSpace(string(mustOutput(exec.Command("git", append([]string{"-C", path}, args...)...))))
}
func mustOutput(command *exec.Cmd) []byte { output, _ := command.Output(); return output }
func defaultValue(value, fallback string) string {
	if value == "" {
		return fallback
	}
	return value
}
func expandHome(path string) string {
	if path == "~" {
		home, _ := os.UserHomeDir()
		return home
	}
	if strings.HasPrefix(path, "~/") {
		home, _ := os.UserHomeDir()
		return filepath.Join(home, path[2:])
	}
	return path
}

func normalizeTerminalGroupHome(home string) (string, error) {
	home = strings.TrimSpace(home)
	if home == "" {
		return "", nil
	}
	resolved, err := filepath.Abs(expandHome(home))
	if err != nil {
		return "", err
	}
	info, err := os.Stat(resolved)
	if err != nil || !info.IsDir() {
		return "", fmt.Errorf("terminal group home is not a directory: %s", resolved)
	}
	return resolved, nil
}
func samePath(left, right string) bool {
	return normalizedPathKey(left) == normalizedPathKey(right)
}
func safeName(value string) string {
	replacer := strings.NewReplacer("/", "-", " ", "-", "..", "-")
	return strings.Trim(replacer.Replace(value), ".-")
}
func nextWorkspaceOrder(workspaces []api.Workspace, projectID string) int {
	order := 0
	for _, workspace := range workspaces {
		if workspace.ProjectID == projectID {
			order++
		}
	}
	return order
}
func filter[T any](values []T, keep func(T) bool) []T {
	result := make([]T, 0, len(values))
	for _, value := range values {
		if keep(value) {
			result = append(result, value)
		}
	}
	return result
}
