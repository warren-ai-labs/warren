package server

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
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
	defaultCommandTimeout   = 10 * time.Second
	broadcastLockWait       = 100 * time.Millisecond
	metadataRefreshInterval = 750 * time.Millisecond
	metadataProbeTimeout    = 2 * time.Second
	slowRosterThreshold     = 50 * time.Millisecond
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
	// agentTranscriptChunkBytes keeps the explicit raw-transcript escape hatch
	// streamable. The CLI writes each response before asking for the next one,
	// so neither the Host nor the client has to retain the complete JSONL.
	agentTranscriptChunkBytes = 256 * 1024
	// orphanReapGrace protects a session between runtime creation and its state
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
	// Runtimes maps runtime kind to its adapter. Ghostline is the only runtime.
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
	// Logger receives lifecycle warnings and performance diagnostics. A nil
	// logger falls back to slog's process-wide default for warnings; optional
	// informational diagnostics stay disabled for tests and embedders.
	Logger *slog.Logger
	// ColorQuery supplies terminal foreground and background colors for
	// capability queries answered while no client is attached.
	ColorQuery   ghostline.ColorQueryCallback
	WorktreeRoot string
	// beforeWorkspaceInsert is a narrow test seam for failures between a
	// managed Git worktree creation and its final Store insertion.
	beforeWorkspaceInsert func()
	// AgentFinder locates Codex/Claude transcript files. When nil, agent
	// projection is disabled and sessions behave exactly as before.
	AgentFinder agent.Finder
	// AgentHooks installs the Warren-managed Codex hook that reports the
	// CLI session ID and transcript path. Nil disables installation; the
	// finder then remains the best-effort fallback.
	AgentHooks   func() error
	RingCapacity int
	RingMaxBytes int
	// CommandTimeout bounds runtime operations during attach and adoption. A
	// stuck runtime must fail the attach and release the session broadcast
	// lock instead of wedging the session until the
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
	// peerOutputs owns one Ghostline cursor reader per protocol-2 terminal
	// subscription. Independent readers let a cold peer start exactly at its
	// snapshot cursor; the shared reader is paused only for the short checkpoint
	// boundary so existing subscribers never receive a partial recovery.
	peerOutputs    map[*wsPeer]map[string]*peerOutputStream
	agentPeers     map[string]map[*wsPeer]struct{}
	focusedPeers   map[string]*wsPeer
	runtimeSizes   map[string]ghostline.Size
	broadcastLocks map[string]*sessionLock
	agentsMu       sync.Mutex
	// OpenCode session discovery and metadata persistence must be one critical
	// section. A concurrent reconcile can otherwise observe the same provider
	// row before either Warren session has persisted its binding.
	openCodeBindingMu sync.Mutex
	agents            map[string]*agentSession
	agentEpoch        uint64

	lifecycleOnce   sync.Once
	lifecycleCancel context.CancelFunc
}

type outputSession struct {
	mu                sync.Mutex
	sessionID         string
	runtimeName       string
	runtimeKind       string
	ring              *output.Ring
	reader            CursorOutputReader
	readerDone        chan struct{}
	readerCancel      context.CancelFunc
	outputCursor      ghostline.Cursor
	hasOutputCursor   bool
	responder         *ghostline.QueryResponder
	prepareLock       *sessionLock
	persistedSequence uint64
}

type peerOutputStream struct {
	reader CursorOutputReader
	cancel context.CancelFunc
	done   chan struct{}
}

type agentSession struct {
	mu      sync.Mutex
	watcher *agent.Watcher
	// tailer is non-nil only for OpenCode. It owns the read-only projection
	// from the provider's SQLite store into watcher.Path().
	tailer *agent.OpenCodeTailer
	events []api.AgentEvent
	status api.AgentStatus
	turn   api.AgentTurn
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

type RuntimeLister interface {
	List(context.Context) (map[string]bool, error)
}

type RuntimeCreatedLister interface {
	ListCreated(context.Context) (map[string]time.Time, error)
}

// CursorOutputRuntime is implemented by Ghostline v1. The service owns one
// reader per session and treats Cursor as an opaque durable token; the
// browser-facing output protocol deliberately continues to use its own
// lightweight sequence anchors.
type CursorOutputRuntime interface {
	Runtime
	Checkpoint(context.Context, string) (ghostline.Checkpoint, error)
	OpenOutput(context.Context, string, ghostline.Cursor) (CursorOutputReader, error)
}

// CursorOutputReader is the small portion of Ghostline's reader contract that
// Warren needs. Keeping the service boundary interface-shaped lets tests and
// embedders provide deterministic readers without depending on Ghostline's
// concrete reader constructor; GhostlineRuntime still returns the native
// *ghostline.OutputReader behind this interface.
type CursorOutputReader interface {
	io.Reader
	io.Closer
	Cursor() ghostline.Cursor
}

// AtomicStateRuntime is the optional native-state recovery capability. The
// payload remains owned and versioned by Ghostline; Warren only pairs it with
// the browser-facing recovery anchor and transports it as an opaque frame.
type AtomicStateRuntime interface {
	CursorOutputRuntime
	AtomicState(context.Context, string) (ghostline.AtomicState, error)
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
	if kind != "" && kind != settings.RuntimeGhostline && len(s.Runtimes) > 0 {
		return nil
	}
	return s.Runtime
}

func (s *Service) cursorOutputRuntimeFor(session api.Session) CursorOutputRuntime {
	adapter, _ := s.runtimeFor(session).(CursorOutputRuntime)
	return adapter
}

func (s *Service) atomicStateRuntimeFor(session api.Session) AtomicStateRuntime {
	adapter, _ := s.runtimeFor(session).(AtomicStateRuntime)
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
	if s.peerOutputs == nil {
		s.peerOutputs = map[*wsPeer]map[string]*peerOutputStream{}
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

// Start runs the single lifecycle watcher. One goroutine probes all
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
		s.stopCursorOutput(outputSession)
		outputSession.mu.Lock()
		if s.Store != nil {
			_ = s.persistCursorLocked(outputSession)
		}
		outputSession.mu.Unlock()
	}
	// Protocol-2 subscriptions own independent Ghostline readers. They are
	// not represented by outputSession.reader, so a service shutdown must
	// close and join them explicitly; otherwise a test or embedded daemon can
	// leave blocked reader goroutines behind after the shared reader stops.
	s.outputMu.Lock()
	peerSubscriptions := make([]struct {
		peer      *wsPeer
		sessionID string
	}, 0)
	for peer, streams := range s.peerOutputs {
		for sessionID := range streams {
			peerSubscriptions = append(peerSubscriptions, struct {
				peer      *wsPeer
				sessionID string
			}{peer: peer, sessionID: sessionID})
		}
	}
	s.outputMu.Unlock()
	for _, subscription := range peerSubscriptions {
		s.stopPeerCursorOutput(subscription.peer, subscription.sessionID, true)
	}
	s.agentsMu.Lock()
	agentWatchers := make([]*agent.Watcher, 0, len(s.agents))
	agentTailers := make([]*agent.OpenCodeTailer, 0, len(s.agents))
	for _, agentSession := range s.agents {
		if agentSession == nil {
			continue
		}
		if agentSession.watcher != nil {
			agentWatchers = append(agentWatchers, agentSession.watcher)
		}
		if agentSession.tailer != nil {
			agentTailers = append(agentTailers, agentSession.tailer)
		}
	}
	s.agentsMu.Unlock()
	for _, watcher := range agentWatchers {
		watcher.Close()
	}
	for _, tailer := range agentTailers {
		tailer.Close()
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
	state := s.Store.Snapshot()
	for _, session := range state.Sessions {
		if session.Lifecycle != "running" {
			s.stopOutput(session.ID, false)
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
		if !running(adopted) && !s.anyRuntimeOwns(probeContext, adopted) {
			s.markEnded(session.ID)
			continue
		}
		_, _ = s.ensureOutput(ctx, session)
		s.applyAgentState(session)
		_, _ = s.ensureAgentWithState(probeContext, session, &state)
	}
}

// adoptRuntimeKind assigns Ghostline to legacy sessions created before
// sessions recorded runtimeKind.
func (s *Service) adoptRuntimeKind(ctx context.Context, session api.Session) (api.Session, bool) {
	if session.RuntimeKind != "" {
		return session, false
	}
	if adapter := s.Runtimes[settings.RuntimeGhostline]; adapter != nil && adapter.Exists(ctx, session.Runtime) {
		session.RuntimeKind = settings.RuntimeGhostline
		return session, true
	}
	return session, false
}

// anyRuntimeOwns is a second, direct existence check used when the cached
// runningSessions probe failed for a session. A transient probe failure must
// not end a live session: ending it would let the orphan reaper kill the
// underlying process minutes later.
func (s *Service) anyRuntimeOwns(ctx context.Context, session api.Session) bool {
	if adapter := s.Runtimes[settings.RuntimeGhostline]; adapter != nil && adapter.Exists(ctx, session.Runtime) {
		return true
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

func (s *Service) RosterVersion(_ context.Context) (api.State, uint64) {
	startedAt := time.Now()
	s.migrateLegacyWorktreeOwnership()
	// Roster projection is observer-facing and may run independently for every
	// connected client. Keep runtime probes and Session lifecycle mutations in
	// the single lifecycle loop so additional observers cannot multiply process
	// launches, runtime RPCs, or Session writes.
	state, revision := s.Store.SnapshotVersion()
	for index := range state.Tasks {
		state.Tasks[index].CreationRequestID = ""
		state.Tasks[index].CreationRequestHash = ""
	}
	for index := range state.Workspaces {
		state.Workspaces[index].CreationRequestID = ""
		state.Workspaces[index].CreationRequestHash = ""
	}
	// The store also carries Ghostline's local recovery data. Browser and CLI
	// clients only need logical Warren identities, never a daemon socket path
	// or an opaque output cursor.
	state.GhostlineMigration = nil
	// Store revisions begin at zero, while an omitted JSON field means an old
	// server did not support revisioned roster snapshots. Offset the opaque
	// wire token so every current snapshot carries a non-zero revision without
	// persisting it into State.
	state.Revision = revision + 1
	sortTasks(state.Tasks)
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
		session.OutputCursor = ""
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
		} else if session.Kind == "codex" || session.Kind == "claude" || session.Kind == "opencode" {
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
		adapter := s.runtimeFor(session)
		return adapter != nil && adapter.Exists(ctx, session.Runtime)
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
	result, err := s.createWorkspace(projectID, "", branch, name, path, "")
	return withoutWorkspaceCreationMetadata(result), err
}

func (s *Service) CreateTaskWorkspace(projectID, taskID, branch, name, path string) (api.WorkspaceCreateResult, error) {
	result, err := s.createWorkspace(projectID, taskID, branch, name, path, "")
	return withoutWorkspaceCreationMetadata(result), err
}

func (s *Service) CreateTaskWorkspaceWithRequestID(projectID, taskID, branch, name, path, requestID string) (api.WorkspaceCreateResult, error) {
	result, err := s.createWorkspace(projectID, taskID, branch, name, path, requestID)
	return withoutWorkspaceCreationMetadata(result), err
}

func (s *Service) createWorkspace(projectID, taskID, branch, name, path, requestID string) (api.WorkspaceCreateResult, error) {
	var err error
	requestID, err = normalizeCreationRequestID(requestID)
	if err != nil {
		return api.WorkspaceCreateResult{}, err
	}
	branch = strings.TrimSpace(branch)
	if branch == "" {
		return api.WorkspaceCreateResult{}, errors.New("branch is required")
	}
	if name == "" {
		name = branch
	}
	requestPath := path
	if requestPath != "" {
		requestPath, _ = filepath.Abs(expandHome(requestPath))
	}
	requestHash := ""
	if requestID != "" {
		requestHash = creationRequestHash("workspace.create", projectID, taskID, branch, name, requestPath)
	}

	projectLock := s.projectLifecycleLock(projectID)
	projectLock.Lock()
	defer projectLock.Unlock()

	state := s.Store.Snapshot()
	if replay, found, err := workspaceCreationReplay(&state, requestID, requestHash); err != nil {
		return api.WorkspaceCreateResult{}, err
	} else if found {
		return replay, nil
	}
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
	if err := taskExists(&state, taskID); err != nil {
		return api.WorkspaceCreateResult{}, err
	}
	if err := branchAlreadyHasWorkspace(&state, projectID, branch); err != nil {
		return api.WorkspaceCreateResult{}, err
	}
	id := store.NewID()
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
							ID: id, ProjectID: projectID, TaskID: taskID, Name: name, Path: resolved,
							Branch: branch, Kind: "root", CreationRequestID: requestID,
							CreationRequestHash: requestHash, CreatedAt: time.Now().UTC(),
						}
						if replay, found, err := s.insertWorkspaceForCreation(&workspace); err != nil {
							return api.WorkspaceCreateResult{}, err
						} else if found {
							return replay, nil
						}
						s.invalidateMerge()
						return api.WorkspaceCreateResult{Workspace: workspace, Created: true}, nil
					}
					if name == "" {
						name = filepath.Base(resolved)
					}
					workspace := api.Workspace{
						ID: id, ProjectID: projectID, TaskID: taskID, Name: name, Path: resolved,
						Branch: branch, Kind: "worktree", CreationRequestID: requestID,
						CreationRequestHash: requestHash, CreatedAt: time.Now().UTC(),
					}
					if replay, found, err := s.insertWorkspaceForCreation(&workspace); err != nil {
						return api.WorkspaceCreateResult{}, err
					} else if found {
						return replay, nil
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
	branchCreated := false
	args := []string{"-C", project.Path, "worktree", "add", path, branch}
	if exec.Command("git", "-C", project.Path, "show-ref", "--verify", "--quiet", "refs/heads/"+branch).Run() != nil {
		branchCreated = true
		args = []string{"-C", project.Path, "worktree", "add", "-b", branch, path}
	}
	if output, err := exec.Command("git", args...).CombinedOutput(); err != nil {
		return api.WorkspaceCreateResult{}, fmt.Errorf("git worktree add: %s: %w", strings.TrimSpace(string(output)), err)
	}
	gitCreated = true
	if s.beforeWorkspaceInsert != nil {
		s.beforeWorkspaceInsert()
	}
	workspace := api.Workspace{
		ID: id, ProjectID: projectID, TaskID: taskID, Name: name, Path: path,
		Branch: branch, Kind: "worktree", ManagedWorktree: true,
		CreationRequestID: requestID, CreationRequestHash: requestHash, CreatedAt: time.Now().UTC(),
	}
	if replay, found, err := s.insertWorkspaceForCreation(&workspace); err != nil {
		return api.WorkspaceCreateResult{}, rollbackManagedWorktree(err, project.Path, path, branch, branchCreated)
	} else if found {
		return replay, nil
	}
	s.invalidateMerge()
	return api.WorkspaceCreateResult{Workspace: workspace, Created: true, GitWorktree: gitCreated}, nil
}

func rollbackManagedWorktree(cause error, projectPath, path, branch string, branchCreated bool) error {
	var cleanupErrors []error
	if output, err := exec.Command("git", "-C", projectPath, "worktree", "remove", "--force", path).CombinedOutput(); err != nil {
		cleanupErrors = append(cleanupErrors, fmt.Errorf("remove git worktree %q: %s: %w", path, strings.TrimSpace(string(output)), err))
	}
	if branchCreated {
		if output, err := exec.Command("git", "-C", projectPath, "branch", "-D", "--", branch).CombinedOutput(); err != nil {
			cleanupErrors = append(cleanupErrors, fmt.Errorf("delete created branch %q: %s: %w", branch, strings.TrimSpace(string(output)), err))
		}
	}
	if len(cleanupErrors) == 0 {
		return cause
	}
	return errors.Join(append([]error{cause}, cleanupErrors...)...)
}

func (s *Service) insertWorkspace(workspace *api.Workspace) error {
	_, _, err := s.insertWorkspaceForCreation(workspace)
	return err
}

func (s *Service) insertWorkspaceForCreation(workspace *api.Workspace) (api.WorkspaceCreateResult, bool, error) {
	var replay api.WorkspaceCreateResult
	var found bool
	err := s.Store.Update(func(state *api.State) error {
		var err error
		replay, found, err = workspaceCreationReplay(
			state, workspace.CreationRequestID, workspace.CreationRequestHash,
		)
		if err != nil || found {
			return err
		}
		if err := taskExists(state, workspace.TaskID); err != nil {
			return err
		}
		if err := branchAlreadyHasWorkspace(state, workspace.ProjectID, workspace.Branch); err != nil {
			return err
		}
		workspace.Order = nextWorkspaceOrder(state.Workspaces, workspace.ProjectID)
		state.Workspaces = append(state.Workspaces, *workspace)
		return nil
	})
	return replay, found, err
}

func taskExists(state *api.State, taskID string) error {
	if taskID == "" {
		return nil
	}
	if !slices.ContainsFunc(state.Tasks, func(task api.Task) bool { return task.ID == taskID }) {
		return fmt.Errorf("task not found: %s", taskID)
	}
	return nil
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

func (s *Service) logInfo(message string, keyValues ...any) {
	if s.Logger != nil {
		s.Logger.Info(message, keyValues...)
	}
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

// sessionEnvironment returns the per-session bindings together with the
// current runtime overrides. The overrides are sent with every new session so
// a detached Ghostline server can apply settings changed after it started;
// existing sessions keep the environment they were created with.
func (s *Service) sessionEnvironment(id, kind string) []string {
	env := agent.BindEnvironment(id, kind)
	keys := make([]string, 0, len(s.Settings.RuntimeEnv))
	for key, value := range s.Settings.RuntimeEnv {
		if key == "" || value == "" {
			continue
		}
		keys = append(keys, key)
	}
	slices.Sort(keys)
	for _, key := range keys {
		env = append(env, key+"="+s.Settings.RuntimeEnv[key])
	}
	return env
}

func (s *Service) createSession(ctx context.Context, workspaceID, groupID, command, kind, title, runtimeKind string) (api.Session, error) {
	startedAt := time.Now()
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
	if kind == "opencode" {
		if strings.TrimSpace(command) == "" {
			command = "opencode"
		}
		if err := agent.ValidateOpenCodeCommand(command); err != nil {
			return api.Session{}, err
		}
	}
	customTitle := strings.TrimSpace(title)
	defaultTitle := map[string]string{
		"shell": "Shell", "codex": "Codex", "claude": "Claude Code", "opencode": "OpenCode", "trae": "Trae",
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
	env := s.sessionEnvironment(id, kind)
	// Capture the Warren creation time before launching the provider. OpenCode
	// creates its SQLite session during process startup, so recording the time
	// afterwards can make a valid first session look older than Warren's
	// discovery lower bound.
	sessionCreatedAt := time.Now().UTC()
	runtimeStartedAt := time.Now()
	if err := adapter.Create(ctx, runtimeName, workingDirectory, command, env); err != nil {
		return api.Session{}, err
	}
	runtimeDuration := time.Since(runtimeStartedAt)
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
		CreatedAt:       sessionCreatedAt,
	}
	if groupID != "" {
		session.Scope = api.SessionScopeTerminalGroup
	}
	if injectedClaude {
		session.AgentSessionID = id
	}
	storeStartedAt := time.Now()
	if err := s.Store.Update(func(value *api.State) error { value.Sessions = append(value.Sessions, session); return nil }); err != nil {
		_ = adapter.Kill(ctx, runtimeName)
		return api.Session{}, err
	}
	storeDuration := time.Since(storeStartedAt)
	outputStartedAt := time.Now()
	if _, err := s.ensureOutput(ctx, session); err != nil {
		_ = adapter.Kill(ctx, runtimeName)
		_ = s.Store.Update(func(value *api.State) error {
			value.Sessions = filter(value.Sessions, func(item api.Session) bool { return item.ID != id })
			return nil
		})
		return api.Session{}, err
	}
	outputDuration := time.Since(outputStartedAt)
	agentStartedAt := time.Now()
	_, _ = s.ensureAgent(ctx, session)
	agentDuration := time.Since(agentStartedAt)
	s.logInfo(
		"session create complete",
		"session", session.ID,
		"runtimeKind", session.RuntimeKind,
		"runtimeCreate", runtimeDuration,
		"store", storeDuration,
		"output", outputDuration,
		"agent", agentDuration,
		"total", time.Since(startedAt),
	)
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
	if kind != settings.RuntimeGhostline {
		return fmt.Errorf("unsupported runtime %q (supported: ghostline)", kind)
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
	var releaseOpenCodeBinding func()
	if session.Kind == "opencode" {
		// Serialize deletion with provider-session discovery so a concurrent
		// reconcile cannot persist a binding or restart a tailer after this
		// Warren session has been removed.
		s.openCodeBindingMu.Lock()
		releaseOpenCodeBinding = s.openCodeBindingMu.Unlock
		defer releaseOpenCodeBinding()
	}
	// Only explicit Close Tab / Terminate Session reaches kill-session.
	adapter := s.runtimeFor(*session)
	if err := adapter.Kill(ctx, session.Runtime); err != nil {
		return err
	}
	s.stopOutput(id, true)
	if session.Kind == "opencode" {
		// OpenCode's projection cache is retained across a daemon restart, but
		// an explicitly deleted Warren session must not leave its conversation
		// snapshot behind indefinitely.
		_ = agent.RemoveOpenCodeCache(session.TranscriptPath)
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
			if session.Kind == "opencode" {
				s.openCodeBindingMu.Lock()
			}
			if adapter := s.runtimeFor(session); adapter != nil {
				_ = adapter.Kill(ctx, session.Runtime)
			}
			s.stopOutput(session.ID, true)
			if session.Kind == "opencode" {
				_ = agent.RemoveOpenCodeCache(session.TranscriptPath)
			}
			agent.RemoveBinding(session.ID)
			if session.Kind == "opencode" {
				s.openCodeBindingMu.Unlock()
			}
		}
	}
	return nil
}

func (s *Service) removeTerminalGroupRuntimes(ctx context.Context, state api.State, groupID string) {
	for _, session := range state.Sessions {
		if session.TerminalGroupID != groupID || session.Lifecycle != "running" {
			continue
		}
		if session.Kind == "opencode" {
			s.openCodeBindingMu.Lock()
		}
		if adapter := s.runtimeFor(session); adapter != nil {
			_ = adapter.Kill(ctx, session.Runtime)
		}
		s.stopOutput(session.ID, true)
		if session.Kind == "opencode" {
			_ = agent.RemoveOpenCodeCache(session.TranscriptPath)
		}
		agent.RemoveBinding(session.ID)
		if session.Kind == "opencode" {
			s.openCodeBindingMu.Unlock()
		}
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

// ensureOutput adopts a running Session. Ghostline v1 opens one caller-owned
// cursor reader. Repeating attach/adopt
// never stacks another watcher or reader.
func (s *Service) ensureOutput(ctx context.Context, session api.Session) (*outputSession, error) {
	s.lazyInit()
	s.outputMu.Lock()
	if existing := s.outputs[session.ID]; existing != nil {
		s.outputMu.Unlock()
		if s.cursorOutputRuntimeFor(session) != nil {
			if err := s.ensureCursorOutput(session, existing); err != nil {
				return nil, err
			}
		}
		return existing, nil
	}
	s.outputMu.Unlock()

	cursorRuntime := s.cursorOutputRuntimeFor(session)
	if cursorRuntime == nil {
		// Keep an in-memory ring for lightweight embedders and unit-test
		// runtimes that implement only the base Runtime contract. Production
		// sessions are always backed by Ghostline and take the cursor path.
		o := &outputSession{
			sessionID:         session.ID,
			runtimeName:       session.Runtime,
			runtimeKind:       s.runtimeKindFor(session),
			ring:              output.NewRing(session.Epoch, s.ringCapacity(), s.ringMaxBytes(), session.Sequence),
			responder:         s.newQueryResponder(),
			prepareLock:       newSessionLock(),
			persistedSequence: session.Sequence,
		}
		s.outputMu.Lock()
		if previous := s.outputs[session.ID]; previous != nil {
			s.outputMu.Unlock()
			return previous, nil
		}
		s.outputs[session.ID] = o
		s.outputMu.Unlock()
		return o, nil
	}
	outputSession := &outputSession{
		sessionID:         session.ID,
		runtimeName:       session.Runtime,
		runtimeKind:       s.runtimeKindFor(session),
		ring:              output.NewRing(session.Epoch, s.ringCapacity(), s.ringMaxBytes(), session.Sequence),
		responder:         s.newQueryResponder(),
		prepareLock:       newSessionLock(),
		persistedSequence: session.Sequence,
		// A Host restart has no retained browser ring. The next attach must
		// replay a fresh atomic checkpoint instead of pretending that an
		// opaque Ghostline cursor is a browser byte offset.
	}
	cursor, cursorErr := ghostline.ParseCursor(session.OutputCursor)
	if cursorErr != nil {
		s.logWarn("discard invalid ghostline output cursor", "session", session.ID, "error", cursorErr)
	}
	if session.OutputCursor == "" || cursorErr != nil {
		checkpointContext, cancelCheckpoint := context.WithTimeout(ctx, s.commandTimeout())
		checkpoint, err := cursorRuntime.Checkpoint(checkpointContext, session.Runtime)
		cancelCheckpoint()
		if err != nil {
			return nil, fmt.Errorf("checkpoint ghostline output: %w", err)
		}
		cursor = checkpoint.Cursor
	}
	outputSession.outputCursor = cursor
	outputSession.hasOutputCursor = true

	s.outputMu.Lock()
	if previous := s.outputs[session.ID]; previous != nil {
		s.outputMu.Unlock()
		if err := s.ensureCursorOutput(session, previous); err != nil {
			return nil, err
		}
		return previous, nil
	}
	s.outputs[session.ID] = outputSession
	s.outputMu.Unlock()

	if session.OutputCursor == "" || cursorErr != nil {
		outputSession.mu.Lock()
		if s.Store != nil {
			if err := s.persistCursorLocked(outputSession); err != nil {
				outputSession.mu.Unlock()
				s.logWarn("persist ghostline output cursor", "session", session.ID, "error", err)
			} else {
				outputSession.mu.Unlock()
			}
		} else {
			outputSession.mu.Unlock()
		}
	}
	if err := s.ensureCursorOutput(session, outputSession); err != nil {
		s.outputMu.Lock()
		if s.outputs[session.ID] == outputSession {
			delete(s.outputs, session.ID)
		}
		s.outputMu.Unlock()
		return nil, err
	}
	return outputSession, nil
}

// ensureCursorOutput resumes a v1 reader from the last fully recorded
// Ghostline cursor. The cursor is updated only after every byte returned by a
// reader has been appended to the browser ring, so a daemon crash can at most
// replay a bounded tail and cannot lose output.
func (s *Service) ensureCursorOutput(session api.Session, outputSession *outputSession) error {
	if s.cursorOutputRuntimeFor(session) == nil {
		return nil
	}
	outputSession.mu.Lock()
	running := outputSession.reader != nil
	hasCursor := outputSession.hasOutputCursor
	outputSession.mu.Unlock()
	if running {
		return nil
	}
	if !hasCursor {
		return errors.New("ghostline output reader has no cursor")
	}
	return s.startCursorOutput(session, outputSession)
}

func (s *Service) startCursorOutput(session api.Session, outputSession *outputSession) error {
	runtime := s.cursorOutputRuntimeFor(session)
	if runtime == nil {
		return nil
	}
	outputSession.mu.Lock()
	if outputSession.reader != nil {
		outputSession.mu.Unlock()
		return nil
	}
	cursor := outputSession.outputCursor
	outputSession.mu.Unlock()

	// The reader outlives the HTTP request that happened to create or attach
	// this session. Its explicit cancellation is retained in outputSession and
	// Close always unblocks a pending remote read.
	readerContext, cancel := context.WithCancel(context.Background())
	reader, err := runtime.OpenOutput(readerContext, session.Runtime, cursor)
	if err != nil {
		cancel()
		return fmt.Errorf("open ghostline output: %w", err)
	}
	done := make(chan struct{})
	outputSession.mu.Lock()
	if outputSession.reader != nil {
		outputSession.mu.Unlock()
		cancel()
		_ = reader.Close()
		return nil
	}
	outputSession.reader = reader
	outputSession.readerDone = done
	outputSession.readerCancel = cancel
	outputSession.mu.Unlock()

	go s.readCursorOutput(session, outputSession, reader, readerContext, done)
	return nil
}

func (s *Service) readCursorOutput(session api.Session, outputSession *outputSession, reader CursorOutputReader, readerContext context.Context, done chan struct{}) {
	defer func() {
		outputSession.mu.Lock()
		if outputSession.reader == reader {
			outputSession.reader = nil
			outputSession.readerDone = nil
			outputSession.readerCancel = nil
		}
		outputSession.mu.Unlock()
		close(done)
	}()

	buffer := make([]byte, 64*1024)
	for {
		count, readErr := reader.Read(buffer)
		if count > 0 {
			data := append([]byte(nil), buffer[:count]...)
			s.recordCursorOutput(session.ID, data, reader.Cursor())
		}
		if readErr != nil {
			if !errors.Is(readErr, io.EOF) && readerContext.Err() == nil {
				s.logWarn("read ghostline output", "session", session.ID, "error", readErr)
			}
			return
		}
		if count == 0 {
			s.logWarn("read ghostline output", "session", session.ID, "error", io.ErrNoProgress)
			return
		}
	}
}

// reservePeerCursorOutput removes and joins an older reader, then marks the
// subscription as direct before its snapshot is captured. Shared ring
// broadcasts skip reserved subscriptions, so resize redraws and other bytes
// produced before the snapshot cannot leak ahead of the replacement state.
func (s *Service) reservePeerCursorOutput(peer *wsPeer, sessionID string) {
	s.stopPeerCursorOutput(peer, sessionID, true)
	s.outputMu.Lock()
	streams := s.peerOutputs[peer]
	if streams == nil {
		streams = map[string]*peerOutputStream{}
		s.peerOutputs[peer] = streams
	}
	streams[sessionID] = nil
	s.outputMu.Unlock()
}

func (s *Service) startPeerCursorOutput(
	peer *wsPeer,
	session api.Session,
	cursor ghostline.Cursor,
	epoch, sequence uint64,
) error {
	runtime := s.cursorOutputRuntimeFor(session)
	if runtime == nil {
		return errors.New("ghostline cursor runtime is unavailable")
	}
	readerContext, cancel := context.WithCancel(context.Background())
	reader, err := runtime.OpenOutput(readerContext, session.Runtime, cursor)
	if err != nil {
		cancel()
		return fmt.Errorf("open peer ghostline output: %w", err)
	}
	stream := &peerOutputStream{
		reader: reader,
		cancel: cancel,
		done:   make(chan struct{}),
	}
	s.outputMu.Lock()
	streams := s.peerOutputs[peer]
	current, reserved := streams[session.ID]
	if !reserved || current != nil {
		s.outputMu.Unlock()
		cancel()
		_ = reader.Close()
		return errors.New("terminal output subscription changed during recovery")
	}
	streams[session.ID] = stream
	s.outputMu.Unlock()

	go s.readPeerCursorOutput(peer, session.ID, reader, readerContext, stream, epoch, sequence)
	return nil
}

func (s *Service) readPeerCursorOutput(
	peer *wsPeer,
	sessionID string,
	reader CursorOutputReader,
	readerContext context.Context,
	stream *peerOutputStream,
	epoch, sequence uint64,
) {
	defer close(stream.done)
	buffer := make([]byte, 64*1024)
	for {
		count, readErr := reader.Read(buffer)
		if count > 0 {
			payload := append([]byte(nil), buffer[:count]...)
			encoded, encodeErr := output.EncodeOutput(sessionID, epoch, sequence, payload)
			if encodeErr != nil || !peer.enqueueBinary(encoded) {
				return
			}
			sequence += uint64(count)
		}
		if readErr != nil {
			if !errors.Is(readErr, io.EOF) && readerContext.Err() == nil {
				s.logWarn("read peer ghostline output", "session", sessionID, "error", readErr)
				peer.close()
			}
			return
		}
		if count == 0 {
			s.logWarn("read peer ghostline output", "session", sessionID, "error", io.ErrNoProgress)
			peer.close()
			return
		}
	}
}

// stopPeerCursorOutput removes a direct subscription before stopping its
// reader. Teardown paths do not wait because they may be called synchronously
// from that reader's outbound-overflow path; replacement recovery waits so no
// stale frame can enqueue after the next snapshot.
func (s *Service) stopPeerCursorOutput(peer *wsPeer, sessionID string, wait bool) {
	s.outputMu.Lock()
	streams := s.peerOutputs[peer]
	stream, exists := streams[sessionID]
	if exists {
		delete(streams, sessionID)
		if len(streams) == 0 {
			delete(s.peerOutputs, peer)
		}
	}
	s.outputMu.Unlock()
	if !exists || stream == nil {
		return
	}
	stream.cancel()
	_ = stream.reader.Close()
	if wait {
		<-stream.done
	}
}

// stopCursorOutput closes and joins a caller-owned v1 reader. It intentionally
// runs before an attach obtains the broadcast lock: a reader can be waiting to
// publish output under that lock, and reversing the order would deadlock the
// checkpoint boundary.
func (s *Service) stopCursorOutput(outputSession *outputSession) {
	if outputSession == nil {
		return
	}
	outputSession.mu.Lock()
	reader := outputSession.reader
	done := outputSession.readerDone
	cancel := outputSession.readerCancel
	if cancel != nil {
		cancel()
	}
	if reader != nil {
		_ = reader.Close()
	}
	outputSession.mu.Unlock()
	if done != nil {
		<-done
	}
}

func (s *Service) resumeCursorOutput(session api.Session, outputSession *outputSession) {
	if err := s.ensureCursorOutput(session, outputSession); err != nil {
		s.logWarn("resume ghostline output", "session", session.ID, "error", err)
	}
}

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
	dedicated := session.Kind == "codex" || session.Kind == "claude" || session.Kind == "opencode"
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
			if session.AgentSessionID != "" {
				opencodeBinding, err = finder.FindBindingBySessionID(ctx, session.ID, workspacePath, session.AgentSessionID)
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
		if err != nil || binding == nil || (binding.Provider != "codex" && binding.Provider != "claude" && binding.Provider != "opencode") {
			s.clearShellAgentWithState(session, state)
			return nil, nil
		}
		agentState, stateErr := agent.ReadAgentStatus(agent.StatePath(session.ID))
		if stateErr == nil && agentState.Activity == api.AgentActivityExited {
			s.clearShellAgentWithState(session, state)
			return nil, nil
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
	s.agentsMu.Lock()
	existing := s.agents[sessionID]
	state, _ := agent.ReadAgentStatus(agent.StatePath(sessionID))
	if existing != nil && existing.watcher != nil && existing.watcher.Path() == transcriptPath &&
		(provider != "opencode" || existing.tailer != nil) {
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
	var closingTailer *agent.OpenCodeTailer
	if rebinding {
		closing = existing.watcher
		closingTailer = existing.tailer
		existing.watcher = nil
		existing.tailer = nil
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
	if closing != nil {
		closing.Close()
	}
	if closingTailer != nil {
		closingTailer.Close()
	}
	return current
}

// clearShellAgent tears down a shell overlay after its agent CLI exited and
// drops the persisted binding so clients stop treating the tab as an agent.
func (s *Service) clearShellAgent(session api.Session) {
	state := s.Store.Snapshot()
	s.clearShellAgentWithState(session, &state)
}

func (s *Service) clearShellAgentWithState(session api.Session, state *api.State) {
	if session.Kind == "codex" || session.Kind == "claude" || session.Kind == "opencode" {
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
	if err := s.Store.Update(func(value *api.State) error {
		for index := range value.Sessions {
			if value.Sessions[index].ID == session.ID {
				value.Sessions[index].AgentSessionID = ""
				value.Sessions[index].TranscriptPath = ""
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
			return
		}
	}
}

// transcriptTakenByOther prevents the cwd+mtime fallback from assigning one
// transcript to several Warren sessions. A transcript that another running
// session already projects must never be stolen.
func (s *Service) transcriptTakenByOther(transcriptPath, sessionID string) bool {
	return s.transcriptTakenByOtherInState(s.Store.Snapshot(), transcriptPath, sessionID)
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
	state := s.Store.Snapshot()
	s.persistAgentMetaWithState(&state, sessionID, agentSessionID, transcriptPath)
}

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

// agentTranscriptChunk returns raw JSONL only from the transcript already
// bound to this Warren session. The caller never supplies a filesystem path,
// which prevents the remote read API from becoming a general file reader.
func (s *Service) agentTranscriptChunk(
	ctx context.Context,
	sessionID string,
	offset int64,
	limit int,
) (api.AgentTranscriptChunk, error) {
	if offset < 0 {
		return api.AgentTranscriptChunk{}, errors.New("transcript offset cannot be negative")
	}
	if limit == 0 {
		limit = agentTranscriptChunkBytes
	}
	if limit < 0 || limit > agentTranscriptChunkBytes {
		return api.AgentTranscriptChunk{}, fmt.Errorf("transcript chunk limit must be between 1 and %d bytes", agentTranscriptChunkBytes)
	}

	session, ok := s.Session(sessionID)
	if !ok {
		return api.AgentTranscriptChunk{}, fmt.Errorf("session not found: %s", sessionID)
	}
	if session.Kind != "codex" && session.Kind != "claude" && session.Kind != "opencode" && session.AgentSessionID == "" {
		return api.AgentTranscriptChunk{}, fmt.Errorf("session is not bound to an agent: %s", sessionID)
	}
	if session.TranscriptPath == "" && session.Lifecycle == "running" {
		if _, err := s.ensureAgent(ctx, session); err != nil {
			return api.AgentTranscriptChunk{}, err
		}
		if refreshed, found := s.Session(sessionID); found {
			session = refreshed
		}
	}
	if session.TranscriptPath == "" {
		return api.AgentTranscriptChunk{}, fmt.Errorf("agent transcript is not ready: %s", sessionID)
	}
	data, next, eof, err := agent.ReadTranscriptChunk(session.TranscriptPath, offset, limit)
	if err != nil {
		return api.AgentTranscriptChunk{}, err
	}
	return api.AgentTranscriptChunk{Data: string(data), Next: next, EOF: eof}, nil
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
	kind := session.Kind
	if kind == "shell" || kind == "custom" {
		if binding, err := agent.ReadBinding(agent.BindPath(session.ID)); err == nil && binding != nil && binding.Provider != "" {
			kind = binding.Provider
		}
	}
	if kind != "codex" && kind != "claude" && kind != "opencode" {
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
		if current.Activity == api.AgentActivityExited || current.Activity == api.AgentActivityFailed {
			s.forceAgentStatus(session.ID, state)
		}
	case api.AgentActivityFailed:
		if current.Activity != state.Activity {
			s.recordAgentStatus(session.ID, state)
		}
	}
}

func (s *Service) stopAgent(sessionID string) {
	s.lazyInit()
	s.agentsMu.Lock()
	entry := s.agents[sessionID]
	delete(s.agents, sessionID)
	var watcher *agent.Watcher
	var tailer *agent.OpenCodeTailer
	if entry != nil {
		watcher = entry.watcher
		tailer = entry.tailer
	}
	s.agentsMu.Unlock()
	if watcher != nil {
		watcher.Close()
	}
	if tailer != nil {
		tailer.Close()
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

func (s *Service) commandTimeout() time.Duration {
	if s.CommandTimeout > 0 {
		return s.CommandTimeout
	}
	return defaultCommandTimeout
}

const branchAtomicReanchor = "atomic_reanchor"

// logRecoveryOutcome records which replay path served a peer and how many
// bytes it carried. This is pure observability for the warm-surface
// investigation: composer corruption reports need branch, byte volume, and
// the runtime width at capture time to be diagnosable after the fact.
func (s *Service) logRecoveryOutcome(
	sessionID string,
	method string,
	branch string,
	anchor *output.Anchor,
	bytes int,
	frames int,
	upper uint64,
) {
	s.outputMu.Lock()
	size, known := s.runtimeSizes[sessionID]
	s.outputMu.Unlock()
	sizeLabel := "unknown"
	if known {
		sizeLabel = fmt.Sprintf("%dx%d", size.Columns, size.Rows)
	}
	anchorLabel := "none"
	if anchor != nil {
		anchorLabel = fmt.Sprintf("epoch=%d sequence=%d", anchor.Epoch, anchor.Sequence)
	}
	s.logInfo("recovery outcome",
		"session", sessionID,
		"method", method,
		"branch", string(branch),
		"anchor", anchorLabel,
		"bytes", bytes,
		"frames", frames,
		"upper", upper,
		"runtimeSize", sizeLabel,
	)
}

func (s *Service) recordOutput(sessionID string, data []byte) {
	s.recordOutputWithCursor(sessionID, data, nil)
}

// recordCursorOutput records one complete v1 reader batch. Cursor is opaque:
// it becomes durable only after the complete batch has entered the browser
// ring, preserving the at-least-once recovery boundary across a Host crash.
func (s *Service) recordCursorOutput(sessionID string, data []byte, cursor ghostline.Cursor) {
	s.recordOutputWithCursor(sessionID, data, &cursor)
}

func (s *Service) recordOutputWithCursor(sessionID string, data []byte, cursor *ghostline.Cursor) {
	s.recordOutputWithCursorMode(sessionID, data, cursor, true)
}

// recordOutputWithCursorMode appends one complete reader batch before making
// it visible to peers. A recovery boundary can use broadcast=false while it
// catches the Warren ring up to the Ghostline checkpoint cursor: those bytes
// are already represented by the atomic state and must not be sent as a
// second live stream to existing peers.
func (s *Service) recordOutputWithCursorMode(
	sessionID string,
	data []byte,
	cursor *ghostline.Cursor,
	broadcast bool,
) {
	s.outputMu.Lock()
	outputSession := s.outputs[sessionID]
	attached := len(s.peers[sessionID]) > 0
	s.outputMu.Unlock()
	if outputSession == nil || len(data) == 0 {
		return
	}
	frames := make([]output.Frame, 0, len(data)/output.MaxPayload+1)
	var replies [][]byte
	for _, chunk := range output.SplitPayload(data) {
		outputSession.mu.Lock()
		frame, err := outputSession.ring.Append(sessionID, chunk)
		if !attached {
			replies = append(replies, outputSession.responder.Feed(chunk)...)
		}
		outputSession.mu.Unlock()
		if err != nil {
			continue
		}
		frames = append(frames, frame)
	}
	if len(frames) == 0 {
		return
	}

	outputSession.mu.Lock()
	if cursor != nil {
		outputSession.outputCursor = *cursor
		outputSession.hasOutputCursor = true
	}
	epoch := outputSession.ring.Epoch
	sequence := outputSession.ring.Upper()
	persist := sequence-outputSession.persistedSequence >= cursorPersistEvery
	if persist {
		outputSession.persistedSequence = sequence
	}
	outputSession.mu.Unlock()

	// Ring first, then clients: recovery is always authoritative even when a
	// peer cannot keep up and has to reconnect. A v1 cursor is not persisted
	// until all frames from this reader batch were appended above. Recovery-gap
	// bytes deliberately skip the broadcast because the atomic state already
	// covers them; every peer has its own direct reader at that boundary.
	if broadcast {
		for _, frame := range frames {
			s.broadcastFrame(frame)
		}
	}
	if persist {
		s.persistOutputCursor(outputSession, epoch, sequence)
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
	outputSession.mu.Unlock()
	s.persistOutputCursor(outputSession, epoch, sequence)
}

func (s *Service) persistOutputCursor(outputSession *outputSession, _, _ uint64) {
	if s.Store == nil {
		return
	}
	outputSession.mu.Lock()
	err := s.persistCursorLocked(outputSession)
	outputSession.mu.Unlock()
	if err != nil {
		s.logWarn("persist output cursor", "session", outputSession.sessionID, "error", err)
	}
}

func (s *Service) persistCursorLocked(outputSession *outputSession) error {
	epoch := outputSession.ring.Epoch
	sequence := outputSession.ring.Upper()
	return s.Store.Update(func(value *api.State) error {
		for index := range value.Sessions {
			if value.Sessions[index].ID == outputSession.sessionID && value.Sessions[index].Lifecycle == "running" {
				value.Sessions[index].Epoch = epoch
				value.Sessions[index].Sequence = sequence
				if outputSession.hasOutputCursor {
					value.Sessions[index].OutputCursor = outputSession.outputCursor.String()
				}
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
		if streams := s.peerOutputs[peer]; streams != nil {
			if _, direct := streams[frame.SessionID]; direct {
				continue
			}
		}
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
// the session broadcast lock. Reconnecting protocol-2 peers always receive a
// fresh atomic state, so no recovery mode needs to be carried in the ring.
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
	return s.attachOutputLocked(ctx, peer, session, anchor, "session.attach")
}

// prepareAttach serializes recovery and holds the shared broadcast boundary.
// The shared reader is stopped and joined before the runtime checkpoint.  This
// is a short pause, but it is the only way to prove that no reader has already
// consumed bytes whose cursor is ahead of Warren's ring boundary.  The reader
// is resumed after the caller releases the lock; the newly attached peer owns
// an independent reader from the paired checkpoint cursor.
func (s *Service) prepareAttach(ctx context.Context, session api.Session) (*sessionLock, func(), error) {
	// The desktop client has a shorter request timeout than the daemon's
	// command timeout. Bound the entire preparation phase independently so a
	// stalled adoption or lock cannot keep a WebSocket command
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
			s.resumeCursorOutput(session, outputSession)
			prepareLock.Unlock()
		})
	}
	// Join the shared reader before taking the broadcast lock.  A reader may be
	// blocked in a remote Read or in recordOutputWithCursor; Close unblocks it
	// and joining here establishes the exact checkpoint boundary below.
	s.stopCursorOutput(outputSession)
	lock := s.broadcastLock(session.ID)
	if err := lock.LockContext(prepareContext); err != nil {
		release()
		return nil, nil, fmt.Errorf("lock session output: %w", err)
	}
	return lock, release, nil
}

func (s *Service) attachOutputLocked(ctx context.Context, peer *wsPeer, session api.Session, anchor *output.Anchor, method string) error {
	s.lazyInit()
	s.outputMu.Lock()
	outputSession := s.outputs[session.ID]
	s.outputMu.Unlock()

	s.registerPeer(session.ID, peer)

	if peer.terminalStateFormat == "" {
		return errors.New("atomic terminal state format is not negotiated")
	}
	if s.cursorOutputRuntimeFor(session) == nil {
		return errors.New("ghostline atomic output runtime is unavailable")
	}
	return s.reanchorAtomicOutput(ctx, peer, session, outputSession, anchor, method)
}

// reanchorAtomicOutput sends one renderer-compatible terminal state and starts
// an independent Ghostline reader at its paired cursor. prepareAttach has
// already paused and joined the shared reader, so the state and cursor are
// paired with one exact broadcast boundary before existing output resumes.
func (s *Service) reanchorAtomicOutput(
	ctx context.Context,
	peer *wsPeer,
	session api.Session,
	outputSession *outputSession,
	anchor *output.Anchor,
	method string,
) error {
	stateContext, cancelState := context.WithTimeout(ctx, s.commandTimeout())
	var (
		format  string
		payload []byte
		cursor  ghostline.Cursor
		err     error
	)
	// Capture the Ghostline state while the shared reader is paused. The reader
	// normally keeps the Warren ring at the same cursor, but output can arrive
	// between the reader's final batch and this checkpoint. Catch that small
	// opaque-cursor gap up before calculating the protocol sequence so the
	// atomic state and the live stream share one exact boundary.
	switch peer.terminalStateFormat {
	case ghostline.AtomicStateFormat:
		runtime := s.atomicStateRuntimeFor(session)
		if runtime == nil {
			cancelState()
			return errors.New("ghostline native state runtime is unavailable")
		}
		var state ghostline.AtomicState
		state, err = runtime.AtomicState(stateContext, session.Runtime)
		format, payload, cursor = state.Format, state.Payload, state.Cursor
	case terminalStateFormatANSI:
		runtime := s.cursorOutputRuntimeFor(session)
		if runtime == nil {
			cancelState()
			return errors.New("ghostline checkpoint runtime is unavailable")
		}
		var checkpoint ghostline.Checkpoint
		checkpoint, err = runtime.Checkpoint(stateContext, session.Runtime)
		format, payload, cursor = terminalStateFormatANSI, checkpoint.Replay, checkpoint.Cursor
	default:
		cancelState()
		return fmt.Errorf("unsupported terminal state format %q", peer.terminalStateFormat)
	}
	cancelState()
	if err != nil {
		return fmt.Errorf("capture ghostline terminal state: %w", err)
	}
	if format == "" || cursor == (ghostline.Cursor{}) {
		return errors.New("ghostline returned an incomplete terminal state")
	}
	catchUpContext, cancelCatchUp := context.WithTimeout(ctx, s.commandTimeout())
	err = s.catchUpOutputCursor(catchUpContext, session, outputSession, cursor)
	cancelCatchUp()
	if err != nil {
		return fmt.Errorf("align ghostline recovery cursor: %w", err)
	}
	outputSession.mu.Lock()
	epoch := outputSession.ring.Epoch
	upper := outputSession.ring.Upper()
	outputSession.mu.Unlock()

	defer s.logRecoveryOutcome(
		session.ID,
		method,
		branchAtomicReanchor,
		anchor,
		len(payload),
		1,
		upper,
	)

	if err := peer.enqueueAttached(session.ID, epoch, upper, true); err != nil {
		return err
	}
	if err := peer.enqueueAtomicState(
		session.ID,
		epoch,
		upper,
		format,
		payload,
	); err != nil {
		return err
	}
	if err := s.startPeerCursorOutput(peer, session, cursor, epoch, upper); err != nil {
		return err
	}
	// Start the direct reader before releasing the presentation boundary.  Any
	// bytes produced after the checkpoint are therefore either queued before or
	// after this marker, but never lost because the reader had not been armed.
	if err := peer.enqueueSynced(session.ID, epoch, upper); err != nil {
		return err
	}

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

// catchUpOutputCursor records bytes that arrived after the shared reader was
// stopped but before Ghostline captured its atomic state. The target cursor is
// intentionally compared only for equality: Ghostline cursors are opaque to
// Warren, and reading one byte at a time is the safe fallback that cannot
// consume output produced after the checkpoint boundary. This path is limited
// to the short attach/reanchor window; the normal shared reader remains
// buffered at 64 KiB.
func (s *Service) catchUpOutputCursor(
	ctx context.Context,
	session api.Session,
	outputSession *outputSession,
	target ghostline.Cursor,
) error {
	outputSession.mu.Lock()
	from := outputSession.outputCursor
	outputSession.mu.Unlock()
	if from == target {
		return nil
	}
	runtime := s.cursorOutputRuntimeFor(session)
	if runtime == nil {
		return errors.New("ghostline cursor runtime is unavailable")
	}
	reader, err := runtime.OpenOutput(ctx, session.Runtime, from)
	if err != nil {
		return fmt.Errorf("open ghostline recovery gap: %w", err)
	}
	defer reader.Close()
	buffer := make([]byte, 1)
	for {
		if reader.Cursor() == target {
			return nil
		}
		if err := ctx.Err(); err != nil {
			return err
		}
		count, readErr := reader.Read(buffer)
		if count > 0 {
			cursor := reader.Cursor()
			s.recordOutputWithCursorMode(session.ID, buffer[:count], &cursor, false)
			if cursor == target {
				return nil
			}
		}
		if readErr != nil {
			if !errors.Is(readErr, io.EOF) {
				return fmt.Errorf("read ghostline recovery gap: %w", readErr)
			}
			if reader.Cursor() == target {
				return nil
			}
			return fmt.Errorf("ghostline recovery gap ended before checkpoint cursor")
		}
		if count == 0 {
			return io.ErrNoProgress
		}
	}
}

func (s *Service) PingOutput(sessionID string) {
	// Ghostline output readers block on the runtime stream and do not require
	// polling or an explicit wake-up.
}

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
// runtime size. A background endpoint receives a successful no-op so stale
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
	adapter := s.runtimeFor(session)
	if adapter == nil {
		return false, fmt.Errorf("runtime %q is unavailable", s.runtimeKindFor(session))
	}
	if err := adapter.Resize(ctx, session.Runtime, columns, rows); err != nil {
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
		return nil
	})
	if changed {
		s.stopOutput(sessionID, true)
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
