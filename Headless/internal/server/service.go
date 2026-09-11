package server

import (
	"bytes"
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
	"strconv"
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
	sessiontitle "github.com/abcdlsj/warren/Headless/internal/title"
	"github.com/abcdlsj/warren/Headless/internal/usage"
)

const (
	defaultRingCapacity     = 256
	defaultRingMaxBytes     = 8 * 1024 * 1024
	defaultCommandTimeout   = 10 * time.Second
	metadataRefreshInterval = 750 * time.Millisecond
	metadataProbeTimeout    = 2 * time.Second
	slowRosterThreshold     = 50 * time.Millisecond
	cursorPersistEvery      = 256 * 1024
	orphanReapInterval      = 30 * time.Second
	// agentMessageMaxBytes bounds one pushed agent batch so a large
	// transcript never produces a single WebSocket message that exceeds
	// client limits (URLSession's default maximumMessageSize is 1 MiB).
	agentMessageMaxBytes     = 256 * 1024
	agentHistoryDefaultLimit = 200
	agentHistoryMaxLimit     = 500
	// A pending admission older than this at process startup cannot be safely
	// replayed: the provider may have completed after the client disconnected.
	canonicalCommandRecoveryAge = 15 * time.Minute
	// orphanReapGrace protects a session between runtime creation and its state
	// record becoming durable, so a concurrent reaper cannot kill a brand-new
	// runtime while CreateSession is still persisting it.
	// orphanReapGrace protects sessions across daemon upgrades: an install can
	// briefly overlap two daemons, and a legacy session must survive a slow
	// first reconcile instead of being reaped minutes after being marked
	// ended. Five minutes of grace is a safe trade-off for orphan cleanup.
	orphanReapGrace             = 5 * time.Minute
	runtimeProbeWarningInterval = time.Minute
	// operationAuditLimit keeps the durable safety log bounded. Only entries
	// with a compare-and-swap undo representation are retained.
	operationAuditLimit = 256
	setupScriptTimeout  = 5 * time.Minute
)

type Service struct {
	Store          *store.Store
	AgentStore     *store.AgentEventStore
	AgentStorePath string
	// HostName is the Warren Host/system name advertised to the owned Relay.
	// It is injected by the daemon from --name/WARREN_HOST_NAME.
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
	// settingsMu serializes settings updates with lifecycle supervisors and
	// status projections. The public Settings field is retained for backwards
	// compatibility with embedders; callers that run concurrently should use
	// the snapshot/update helpers below.
	settingsMu sync.RWMutex
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
	AgentHooks func() error
	// AgentProviders is the optional provider registry used by the lifecycle
	// supervisor. Nil retains the legacy built-in transcript path for
	// embedders that have not opted into provider handles yet.
	AgentProviders *AgentProviderRegistry
	// ProviderRegistry and AgentRegistry are compatibility aliases for
	// embedders that used the shorter names while this abstraction was being
	// introduced. When more than one is set, AgentProviders wins.
	ProviderRegistry *AgentProviderRegistry
	AgentRegistry    *AgentProviderRegistry
	// AgentController is an optional provider-native bridge for structured
	// Agent View actions. When absent, ordinary text keeps its legacy PTY path,
	// while interaction and interrupt requests fail explicitly.
	AgentController AgentViewController
	RingCapacity    int
	RingMaxBytes    int
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
	ClientsActive    func() bool
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
	// peerOutputs owns one Ghostline cursor reader per protocol-3 terminal
	// subscription. Independent readers let a cold peer start exactly at its
	// snapshot cursor; the shared reader is paused only for the short checkpoint
	// boundary so existing subscribers never receive a partial recovery.
	peerOutputs  map[*wsPeer]map[string]*peerOutputStream
	agentPeers   map[string]map[*wsPeer]struct{}
	focusedPeers map[string]*wsPeer
	// controlPeers is the authoritative per-session mutation lease. Terminal
	// focus normally owns the same lease, but Agent-only actions may claim it
	// before a terminal output subscription exists.
	controlPeers   map[string]*wsPeer
	runtimeSizes   map[string]ghostline.Size
	broadcastLocks map[string]*sessionLock
	agentsMu       sync.Mutex
	// OpenCode session discovery and metadata persistence must be one critical
	// section. A concurrent reconcile can otherwise observe the same provider
	// row before either Warren session has persisted its binding.
	openCodeBindingMu sync.Mutex
	agents            map[string]*agentSession
	agentEpoch        uint64
	// agentRosterRevision advances the observer-facing roster token when live
	// Agent handle state changes without a durable Store write. This lets
	// roster-delta clients receive capability/rebind updates immediately while
	// ChangesSince continues to track only durable mutations.
	agentRosterRevision atomic.Uint64
	// Agent View upload and idempotency state is device-local to this Host. It
	// contains no authentication material and is discarded on daemon restart.
	agentViewMu             sync.Mutex
	agentUploads            map[string]*agentUpload
	agentInteractionResults map[string]api.AgentInteractionResult
	agentMessageResults     map[string]api.AgentMessageSendResult
	agentInterruptResults   map[string]api.AgentTurnInterruptResult
	agentActionFingerprints map[string]string
	agentActionCalls        map[string]*agentActionCall
	agentSessionActionLocks map[string]*sync.Mutex
	// canonicalCommandResults is keyed by executionId/commandId. It is the
	// Host admission cache for the canonical API; a repeated command is
	// resolved before any provider bridge is invoked.
	canonicalCommandResults map[string]canonicalCommandResult
	liveActivityMu          sync.Mutex
	liveActivityWake        chan struct{}
	liveActivityPublisher   LiveActivityPublisher
	liveActivityDigest      []byte

	lifecycleOnce               sync.Once
	lifecycleCancel             context.CancelFunc
	canonicalCommandsReconciled bool
	usageAttributionInstalled   bool
	// usagePrices caches the unit price table behind cost figures. Shared so a
	// panel refresh does not refetch the catalog on every request.
	usagePrices     usage.PriceFetcher
	runtimeProbeMu  sync.Mutex
	runtimeProbeLog map[string]time.Time
}

type canonicalCommandResult struct {
	fingerprint string
	result      any
	err         error
}

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
}

type Runtime interface {
	Create(context.Context, string, string, string, []string) error
	Exists(context.Context, string) bool
	Capture(context.Context, string) ([]byte, error)
	Input(context.Context, string, []byte) error
	Resize(context.Context, string, int, int) error
	Kill(context.Context, string) error
}

// RuntimeProbeState describes what Warren actually learned from a runtime
// authority. Unknown is deliberately distinct from Dead: a timeout, transport
// outage, malformed response, or unavailable runtime must never end a durable
// Session or authorize an orphan reap.
type RuntimeProbeState uint8

const (
	RuntimeProbeUnknown RuntimeProbeState = iota
	RuntimeProbeAlive
	RuntimeProbeDead
)

// RuntimeProbeResult is the typed lifecycle result returned by adapters that
// can distinguish an authoritative negative answer from an unavailable
// authority. Err is diagnostic only; callers must branch on State.
type RuntimeProbeResult struct {
	State    RuntimeProbeState
	Evidence string
	Err      error
}

// RuntimeProber is an additive capability so existing embedders that only
// implement Runtime keep compiling while production adapters can expose safe
// lifecycle semantics. New lifecycle decisions always prefer this interface.
type RuntimeProber interface {
	Probe(context.Context, string) RuntimeProbeResult
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
	s.settingsMu.RLock()
	defaultRuntime := s.DefaultRuntime
	s.settingsMu.RUnlock()
	if defaultRuntime != "" {
		return defaultRuntime
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
	if s.controlPeers == nil {
		s.controlPeers = map[string]*wsPeer{}
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
	if s.AgentStore == nil && strings.TrimSpace(s.AgentStorePath) != "" {
		path := resolvePath(expandHome(s.AgentStorePath))
		if agentStore, err := store.OpenAgentEventStore(path); err == nil {
			s.AgentStore = agentStore
		}
	}
	if s.AgentStore != nil && !s.usageAttributionInstalled {
		// The journal owns no host state, so it cannot map a stream to a
		// project on its own. Injecting the lookup keeps spend attributable
		// while leaving stores built by tests and embedders inert.
		s.AgentStore.SetUsageAttributionResolver(s.usageAttributionForStream)
		s.usageAttributionInstalled = true
	}
	if s.AgentStore != nil && !s.canonicalCommandsReconciled {
		if _, err := s.AgentStore.ReconcilePendingCanonicalCommands(
			context.Background(), time.Now().UTC(), canonicalCommandRecoveryAge,
		); err != nil {
			s.logWarn("reconcile pending canonical commands", "error", err)
		} else {
			s.canonicalCommandsReconciled = true
		}
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
		go s.liveActivityLoop(ctx)
		go s.mergeLoop(ctx)
		if s.ProbeForeground {
			go s.metadataLoop(ctx)
		}
	})
}

func (s *Service) Shutdown() {
	if s.lifecycleCancel != nil {
		s.lifecycleCancel()
	}
	s.cleanupAgentAttachments()
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
	// Protocol-3 subscriptions own independent Ghostline readers. They are
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
	agentHandles := make([]AgentHandle, 0, len(s.agents))
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
		agentSession.mu.Lock()
		if agentSession.handle != nil {
			agentHandles = append(agentHandles, agentSession.handle)
			// Detach before invoking Close so a repeated Shutdown (or a
			// callback racing shutdown) cannot close or mutate the same handle
			// twice.
			agentSession.handle = nil
			agentSession.bindingKey = ""
			agentSession.providerKind = ""
			agentSession.handlerKind = ""
			agentSession.capabilities = nil
		}
		agentSession.mu.Unlock()
	}
	s.agentsMu.Unlock()
	for _, watcher := range agentWatchers {
		watcher.Close()
	}
	for _, tailer := range agentTailers {
		tailer.Close()
	}
	for _, handle := range agentHandles {
		_ = handle.Close()
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
			s.reapAgentAttachments(time.Now())
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
	seenSessions := make(map[string]struct{}, len(state.Sessions))
	for _, session := range state.Sessions {
		if session.Lifecycle != "running" {
			s.stopOutput(session.ID, false)
			s.stopAgent(session.ID)
			continue
		}
		seenSessions[session.ID] = struct{}{}
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
		s.applyAgentState(session)
		_, _ = s.ensureAgentWithState(probeContext, session, &state)
	}
	s.stopMissingAgents(seenSessions)
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
		if s.ProbeForeground && s.metadataCache != nil {
			if metadata, ok := s.metadataCache.get(session.ID); ok {
				session.Process = metadata.Process
				session.Directory = metadata.Directory
			}
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

// SetProjectSetupScript changes the executable used for newly created managed
// worktrees. An empty value disables setup execution for this project.
func (s *Service) SetProjectSetupScript(projectID, script string) (api.Project, error) {
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
	project.SetupScript = strings.TrimSpace(script)
	if project.SetupScript != "" {
		if _, err := setupScriptPath(project); err != nil {
			return api.Project{}, err
		}
	}
	if err := s.Store.Update(func(value *api.State) error {
		for index := range value.Projects {
			if value.Projects[index].ID == projectID {
				value.Projects[index].SetupScript = project.SetupScript
				return nil
			}
		}
		return fmt.Errorf("project not found: %s", projectID)
	}); err != nil {
		return api.Project{}, err
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
	result, err := s.createWorkspace(projectID, "", branch, name, path, "", false, nil)
	return withoutWorkspaceCreationMetadata(result), err
}

func (s *Service) CreateTaskWorkspace(projectID, taskID, branch, name, path string) (api.WorkspaceCreateResult, error) {
	result, err := s.createWorkspace(projectID, taskID, branch, name, path, "", false, nil)
	return withoutWorkspaceCreationMetadata(result), err
}

func (s *Service) CreateTaskWorkspaceWithRequestID(projectID, taskID, branch, name, path, requestID string) (api.WorkspaceCreateResult, error) {
	result, err := s.createWorkspace(projectID, taskID, branch, name, path, requestID, false, nil)
	return withoutWorkspaceCreationMetadata(result), err
}

func (s *Service) CreateTaskWorkspaceWithSetup(
	projectID, taskID, branch, name, path, requestID string,
	runSetupScript bool, setupArgs []string,
) (api.WorkspaceCreateResult, error) {
	result, err := s.createWorkspace(
		projectID, taskID, branch, name, path, requestID, runSetupScript, setupArgs,
	)
	return withoutWorkspaceCreationMetadata(result), err
}

func (s *Service) createWorkspace(
	projectID, taskID, branch, name, path, requestID string,
	runSetupScript bool, setupArgs []string,
) (api.WorkspaceCreateResult, error) {
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
		setupArgsJSON, _ := json.Marshal(setupArgs)
		requestHash = creationRequestHash(
			"workspace.create", projectID, taskID, branch, name, requestPath,
			strconv.FormatBool(runSetupScript), string(setupArgsJSON),
		)
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
	if runSetupScript {
		if err := s.runSetupScript(*project, api.Workspace{
			ID: id, ProjectID: projectID, TaskID: taskID, Name: name, Path: path,
			Branch: branch, Kind: "worktree",
		}, setupArgs); err != nil {
			return api.WorkspaceCreateResult{}, rollbackManagedWorktree(err, project.Path, path, branch, branchCreated)
		}
	}
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

func (s *Service) runSetupScript(project api.Project, workspace api.Workspace, setupArgs []string) error {
	scriptPath, err := setupScriptPath(project)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), setupScriptTimeout)
	defer cancel()
	args := append([]string{project.Path, workspace.Path}, setupArgs...)
	command := exec.CommandContext(ctx, scriptPath, args...)
	command.Dir = workspace.Path
	command.Env = setupScriptEnvironment(os.Environ(), project, workspace, scriptPath)
	if err := command.Run(); err != nil {
		if errors.Is(ctx.Err(), context.DeadlineExceeded) {
			return fmt.Errorf("setup script timed out after %s", setupScriptTimeout)
		}
		return fmt.Errorf("setup script failed: %w", err)
	}
	return nil
}

func setupScriptPath(project api.Project) (string, error) {
	configured := strings.TrimSpace(project.SetupScript)
	if configured == "" {
		return "", errors.New("setup script is not configured")
	}
	path := expandHome(configured)
	if !filepath.IsAbs(path) {
		path = filepath.Join(project.Path, path)
	}
	path, err := filepath.Abs(path)
	if err != nil {
		return "", fmt.Errorf("resolve setup script: %w", err)
	}
	info, err := os.Stat(path)
	if err != nil {
		return "", fmt.Errorf("setup script is not readable: %s: %w", path, err)
	}
	if !info.Mode().IsRegular() {
		return "", fmt.Errorf("setup script is not a regular file: %s", path)
	}
	if info.Mode().Perm()&0o111 == 0 {
		return "", fmt.Errorf("setup script is not executable: %s", path)
	}
	return path, nil
}

func setupScriptEnvironment(environment []string, project api.Project, workspace api.Workspace, scriptPath string) []string {
	values := map[string]string{
		"WARREN_PROJECT_ID":       project.ID,
		"WARREN_PROJECT_NAME":     project.Name,
		"WARREN_PROJECT_PATH":     project.Path,
		"WARREN_MAIN_REPO_PATH":   project.Path,
		"WARREN_WORKSPACE_ID":     workspace.ID,
		"WARREN_WORKSPACE_NAME":   workspace.Name,
		"WARREN_WORKSPACE_PATH":   workspace.Path,
		"WARREN_WORKTREE_PATH":    workspace.Path,
		"WARREN_WORKSPACE_BRANCH": workspace.Branch,
		"WARREN_TASK_ID":          workspace.TaskID,
		"WARREN_SETUP_SCRIPT":     scriptPath,
	}
	result := make([]string, 0, len(environment)+len(values))
	for _, entry := range environment {
		key, _, ok := strings.Cut(entry, "=")
		if !ok {
			continue
		}
		if _, overridden := values[key]; !overridden {
			result = append(result, entry)
		}
	}
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	slices.Sort(keys)
	for _, key := range keys {
		result = append(result, key+"="+values[key])
	}
	return result
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
	return s.CreateSessionWithHandler(ctx, workspaceID, command, kind, title, runtimeKind, "")
}

// CreateSessionWithHandler is the handler-aware form used by protocol
// clients that explicitly select a transport such as codex/acp. The original
// CreateSession signature remains source-compatible for shell and TUI users.
func (s *Service) CreateSessionWithHandler(ctx context.Context, workspaceID, command, kind, title, runtimeKind, agentHandler string) (api.Session, error) {
	if workspaceID != "" {
		if projectLock := s.lockWorkspaceForSession(workspaceID); projectLock != nil {
			defer projectLock.RUnlock()
		}
	}
	return s.createSession(ctx, workspaceID, "", command, kind, title, runtimeKind, agentHandler)
}

func (s *Service) CreateGroupSession(ctx context.Context, groupID, command, kind, title, runtimeKind string) (api.Session, error) {
	return s.CreateGroupSessionWithHandler(ctx, groupID, command, kind, title, runtimeKind, "")
}

func (s *Service) CreateGroupSessionWithHandler(ctx context.Context, groupID, command, kind, title, runtimeKind, agentHandler string) (api.Session, error) {
	s.terminalGroupLifecycleMu.Lock()
	defer s.terminalGroupLifecycleMu.Unlock()
	return s.createSession(ctx, "", groupID, command, kind, title, runtimeKind, agentHandler)
}

// CreateDefaultGroupSession creates a standalone shell in the first ordered
// Group, recreating Inbox when a Host has no Groups left.
func (s *Service) CreateDefaultGroupSession(ctx context.Context, command, kind, title, runtimeKind string) (api.Session, error) {
	return s.CreateDefaultGroupSessionWithHandler(ctx, command, kind, title, runtimeKind, "")
}

func (s *Service) CreateDefaultGroupSessionWithHandler(ctx context.Context, command, kind, title, runtimeKind, agentHandler string) (api.Session, error) {
	s.terminalGroupLifecycleMu.Lock()
	defer s.terminalGroupLifecycleMu.Unlock()

	group, err := s.ensureTerminalGroup()
	if err != nil {
		return api.Session{}, err
	}
	return s.createSession(ctx, "", group.ID, command, kind, title, runtimeKind, agentHandler)
}

// sessionEnvironment returns the per-session bindings together with the
// current runtime overrides. The overrides are sent with every new session so
// a detached Ghostline server can apply settings changed after it started;
// existing sessions keep the environment they were created with. Empty values
// are retained as explicit unset requests and are handled by the login-shell
// bootstrap in GhostlineRuntime.
func (s *Service) sessionEnvironment(id, kind string) ([]string, error) {
	env := agent.BindEnvironment(id, kind)
	runtimeEnv := s.SettingsSnapshot().RuntimeEnv
	if err := settings.ValidateRuntimeEnv(runtimeEnv); err != nil {
		return nil, err
	}
	keys := make([]string, 0, len(runtimeEnv))
	for key := range runtimeEnv {
		keys = append(keys, key)
	}
	slices.Sort(keys)
	for _, key := range keys {
		env = append(env, key+"="+runtimeEnv[key])
	}
	return env, nil
}

func (s *Service) createSession(ctx context.Context, workspaceID, groupID, command, kind, title, runtimeKind string, agentHandler ...string) (api.Session, error) {
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
	kind = normalizeProviderKind(kind)
	if kind == "" {
		kind = "shell"
	}
	kind, embeddedAgentHandler := splitAgentKey(kind)
	selectedAgentHandler := ""
	if embeddedAgentHandler != "" {
		selectedAgentHandler = embeddedAgentHandler
	}
	if len(agentHandler) > 0 {
		explicitHandler := normalizeProviderKind(agentHandler[0])
		if family, embeddedHandler := splitAgentKey(explicitHandler); family == kind && embeddedHandler != "" {
			selectedAgentHandler = embeddedHandler
		} else if explicitHandler != "" {
			selectedAgentHandler = explicitHandler
		}
	}
	if kind == "opencode" {
		if strings.TrimSpace(command) == "" {
			command = "opencode"
		}
		if err := agent.ValidateOpenCodeCommand(command); err != nil {
			return api.Session{}, err
		}
	}
	if kind == "pi" {
		if strings.TrimSpace(command) == "" {
			command = "pi"
		}
		if err := agent.ValidatePiCommand(command); err != nil {
			return api.Session{}, err
		}
	}
	if kind == "qoder" {
		if strings.TrimSpace(command) == "" {
			command = "qoder"
		}
		if err := agent.ValidateQoderCommand(command); err != nil {
			return api.Session{}, err
		}
	}
	if kind == "antigravity" {
		if strings.TrimSpace(command) == "" {
			command = "agy"
		}
		if err := agent.ValidateAntigravityCommand(command); err != nil {
			return api.Session{}, err
		}
	}
	customTitle := strings.TrimSpace(title)
	defaultTitle := map[string]string{
		"shell": "Shell", "codex": "Codex", "claude": "Claude Code", "opencode": "OpenCode", "trae": "Trae", "pi": "Pi", "qoder": "Qoder", "antigravity": "Antigravity",
	}[kind]
	if defaultTitle == "" {
		fields := strings.Fields(command)
		if len(fields) > 0 {
			defaultTitle = fields[0]
		} else {
			defaultTitle = "Shell"
		}
	}
	// A title that merely repeats the kind-derived default is not a user-set
	// name: preset bars used to echo their display label ("Pi", "Codex") as
	// the create title, which occupied the custom-title slot and suppressed
	// automatic AI title generation. Keep CustomTitle empty in that case so
	// the roster falls back to Title until a real rename or generated title
	// arrives.
	if customTitle == defaultTitle {
		customTitle = ""
	}
	sessionKind := runtimeKind
	if sessionKind == "" {
		sessionKind = s.runtimeKindFor(api.Session{})
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
	injectedQoder := false
	if kind == "qoder" {
		injected := agent.InjectQoderSessionID(command, id)
		if injected != command {
			command = injected
			injectedQoder = true
		}
	}
	// Every session gets the binding environment so a CLI started manually
	// inside a plain shell is bound to the same Warren session by its own
	// lifecycle hooks.
	env, err := s.sessionEnvironment(id, kind)
	if err != nil {
		return api.Session{}, fmt.Errorf("build session environment: %w", err)
	}
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
		AgentProvider:   agentProviderForKind(kind),
		AgentHandler:    selectedAgentHandler,
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
	if injectedQoder {
		session.AgentSessionID = id
	}
	storeStartedAt := time.Now()
	if err := s.Store.Update(func(value *api.State) error { value.Sessions = append(value.Sessions, session); return nil }); err != nil {
		_ = adapter.Kill(ctx, runtimeName)
		return api.Session{}, err
	}
	s.wakeLiveActivity()
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
	value := s.SettingsSnapshot()
	return s.UpdateSettings(kind, value.RuntimeEnv)
}

// SettingsSnapshot returns a detached copy suitable for concurrent readers.
// Maps are copied so a caller cannot mutate the service's live configuration.
func (s *Service) SettingsSnapshot() settings.Settings {
	s.settingsMu.RLock()
	defer s.settingsMu.RUnlock()
	value := s.Settings
	if value.DefaultRuntime == "" {
		value.DefaultRuntime = s.DefaultRuntime
	}
	value.RuntimeEnv = cloneStringMap(value.RuntimeEnv)
	value.PairedClients = clonePairedClients(value.PairedClients)
	return value
}

func cloneStringMap(value map[string]string) map[string]string {
	if value == nil {
		return nil
	}
	copy := make(map[string]string, len(value))
	for key, item := range value {
		copy[key] = item
	}
	return copy
}

// PairedClientsSnapshot returns detached pairing metadata. Token hashes are
// kept inside the Host service and are never projected to remote clients.
func (s *Service) PairedClientsSnapshot() []settings.PairedClient {
	s.settingsMu.RLock()
	defer s.settingsMu.RUnlock()
	return clonePairedClients(s.Settings.PairedClients)
}

// UpdatePairedClients persists the current set of explicitly paired clients.
func (s *Service) UpdatePairedClients(values []settings.PairedClient) error {
	s.settingsMu.Lock()
	defer s.settingsMu.Unlock()
	s.Settings.PairedClients = clonePairedClients(values)
	if s.SettingsPath != "" {
		return settings.Save(s.SettingsPath, s.Settings)
	}
	return nil
}

func clonePairedClients(values []settings.PairedClient) []settings.PairedClient {
	if values == nil {
		return nil
	}
	return append([]settings.PairedClient(nil), values...)
}

// RelaySettingsSnapshot and PublicTunnelSettingsSnapshot are the lifecycle
// supervisor's narrow read surface; neither returns any Host Secret.
func (s *Service) RelaySettingsSnapshot() settings.RelaySettings {
	s.settingsMu.RLock()
	defer s.settingsMu.RUnlock()
	return s.Settings.Relay
}

func (s *Service) PublicTunnelSettingsSnapshot() settings.PublicTunnelSettings {
	s.settingsMu.RLock()
	defer s.settingsMu.RUnlock()
	return s.Settings.PublicTunnel
}

func (s *Service) UpdateRelaySettings(value settings.RelaySettings) error {
	s.settingsMu.Lock()
	defer s.settingsMu.Unlock()
	s.Settings.Relay = value
	if s.SettingsPath != "" {
		return settings.Save(s.SettingsPath, s.Settings)
	}
	return nil
}

func (s *Service) UpdatePublicTunnelSettings(value settings.PublicTunnelSettings) error {
	s.settingsMu.Lock()
	defer s.settingsMu.Unlock()
	s.Settings.PublicTunnel = value
	if s.SettingsPath != "" {
		return settings.Save(s.SettingsPath, s.Settings)
	}
	return nil
}

// UpdateSettings changes the engine used for newly created sessions and the
// runtime environment overrides, persisting them when a settings file is
// configured. Existing sessions keep their own runtimeKind.
func (s *Service) UpdateSettings(kind string, runtimeEnv map[string]string) error {
	if err := settings.ValidateRuntimeEnv(runtimeEnv); err != nil {
		return err
	}
	s.settingsMu.Lock()
	defer s.settingsMu.Unlock()
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
	s.Settings.RuntimeEnv = cloneStringMap(runtimeEnv)
	if s.SettingsPath != "" {
		return settings.Save(s.SettingsPath, s.Settings)
	}
	return nil
}

// PublicAccessEnabled reports the persisted public Relay route intent. This
// distinction lets recovery retry after a daemon restart without claiming
// that the route is already live.
func (s *Service) PublicAccessEnabled() bool {
	s.settingsMu.RLock()
	defer s.settingsMu.RUnlock()
	return s.Settings.PublicTunnel.Enabled
}

// SetAutoOpenShell records whether opening an empty workspace creates a Shell
// session by default. Explicit session actions are unaffected.
func (s *Service) SetAutoOpenShell(enabled bool) error {
	s.settingsMu.Lock()
	defer s.settingsMu.Unlock()
	s.Settings.AutoOpenShell = enabled
	if s.SettingsPath != "" {
		return settings.Save(s.SettingsPath, s.Settings)
	}
	return nil
}

// SetAutoStartAI records whether entering an empty workspace starts the first
// AI preset. Explicit session actions are unaffected.
func (s *Service) SetAutoStartAI(enabled bool) error {
	s.settingsMu.Lock()
	defer s.settingsMu.Unlock()
	s.Settings.AutoStartAI = enabled
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
	err := s.Store.Update(func(value *api.State) error {
		value.Sessions = filter(value.Sessions, func(item api.Session) bool { return item.ID != id })
		return nil
	})
	if err == nil {
		s.wakeLiveActivity()
	}
	return err
}

func (s *Service) Session(id string) (api.Session, bool) {
	for _, session := range s.Store.Snapshot().Sessions {
		if session.ID == id && session.Lifecycle == "running" {
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
			// Runtime teardown can close a reader before Service.stopOutput gets
			// to detach the peer (session.delete and workspace cleanup both kill
			// the runtime first). io.ErrClosedPipe is therefore a normal reader
			// lifecycle result, just like EOF; treating it as a transport failure
			// closes the WebSocket before the mutation response can be delivered.
			// Other errors still close the peer so a genuinely broken output
			// stream cannot leave the client connected to a silent subscription.
			if !errors.Is(readErr, io.EOF) && !errors.Is(readErr, io.ErrClosedPipe) && readerContext.Err() == nil {
				s.logWarn("read peer ghostline output", "session", sessionID, "error", readErr)
				peer.closeWithReason("runtime_output_error")
			}
			return
		}
		if count == 0 {
			s.logWarn("read peer ghostline output", "session", sessionID, "error", io.ErrNoProgress)
			peer.closeWithReason("runtime_output_no_progress")
			return
		}
	}
}

// stopPeerCursorOutput removes a direct subscription before stopping its
// reader. Teardown paths do not wait because they may be called synchronously
// from that reader's outbound-overflow path; replacement recovery waits so no
// stale frame can enqueue after the next snapshot. The wait is bounded so a
// stale peer reader that does not observe Close promptly cannot stall a
// rapid tab switch (see stopCursorOutputWithin).
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
		select {
		case <-stream.done:
		case <-time.After(2 * time.Second):
			s.logWarn("stopPeerCursorOutput join timed out", "session", sessionID, "timeoutMs", int64(2000))
		}
	}
}

// stopCursorOutput closes and joins a caller-owned v1 reader. It intentionally
// runs before an attach obtains the broadcast lock: a reader can be waiting to
// publish output under that lock, and reversing the order would deadlock the
// checkpoint boundary.
//
// The join is bounded: a ghostline reader can be blocked inside a remote Read
// that does not observe Close promptly (for example when the ghostline server
// stops answering output-read RPCs). Without a bound, a rapid workspace/tab
// switch would hang the new subscribe behind the stale reader forever, leaving
// the target pane black. On timeout we record a warning and proceed; the stale
// reader is closed and will be replaced by ensureCursorOutput on resume.
func (s *Service) stopCursorOutput(outputSession *outputSession) {
	s.stopCursorOutputWithin(outputSession, 2*time.Second, "subscribe/attach")
}

func (s *Service) stopCursorOutputWithin(outputSession *outputSession, timeout time.Duration, caller string) {
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
	if done == nil {
		return
	}
	select {
	case <-done:
	case <-time.After(timeout):
		s.logWarn("stopCursorOutput join timed out", "caller", caller, "timeoutMs", timeout.Milliseconds())
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

// clearShellAgent tears down a shell overlay after its agent CLI exited and
// drops the persisted binding so clients stop treating the tab as an agent.
func (s *Service) clearShellAgent(session api.Session) {
	state := s.Store.Snapshot()
	s.clearShellAgentWithState(session, &state)
}

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
	if s.AgentStore == nil || strings.TrimSpace(executionID) == "" {
		return api.AgentStatus{}, api.AgentTurn{Status: api.AgentTurnIdle}, false
	}
	status := api.AgentStatus{}
	turn := api.AgentTurn{Status: api.AgentTurnIdle}
	var after uint64
	if checkpoint, ok, err := s.AgentStore.CanonicalCheckpoint(context.Background(), executionID); err == nil && ok {
		status, turn = canonicalProjectionFromState(checkpoint.State)
		after = checkpoint.Sequence
	}
	result, err := s.AgentStore.QueryCanonicalEvents(context.Background(), executionID, after, 0, agentHistoryMaxLimit)
	if err != nil {
		// A checkpoint at or before the retention boundary can be rebuilt from
		// the retained tail. Do not make a cold start fail merely because the
		// cache was pruned between the two reads.
		if _, boundary := err.(*store.CanonicalHistoryBoundary); boundary {
			result, err = s.AgentStore.QueryCanonicalEvents(context.Background(), executionID, 0, 0, agentHistoryMaxLimit)
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

// appendCanonicalEventsLocked commits one immutable batch and returns the
// exact Host-assigned rows. The caller owns entry.mu. The memory path mirrors
// the SQLite journal for tests and embedders that do not configure AgentStore.
func (s *Service) appendCanonicalEventsLocked(sessionID string, entry *agentSession, events []api.CanonicalAgentEvent) ([]api.CanonicalAgentEvent, error) {
	return s.appendCanonicalEventsLockedWithCheckpoint(sessionID, entry, events, nil)
}

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
	if s.AgentStore != nil {
		assigned, err := s.AgentStore.AppendCanonicalEventsWithCheckpoint(context.Background(), streamID, streamID, events, checkpoint)
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
			if !canonicalEventsEquivalent(*existing, event) {
				return nil, fmt.Errorf("canonical agent event conflict at %s", event.EventID)
			}
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
	var broadcastLock *sessionLock
	if expected != nil {
		broadcastLock = s.broadcastLock(sessionID)
		broadcastLock.Lock()
		defer broadcastLock.Unlock()
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
	var broadcastLock *sessionLock
	if expected != nil {
		broadcastLock = s.broadcastLock(sessionID)
		broadcastLock.Lock()
		defer broadcastLock.Unlock()
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

// tryStartSessionTitle atomically claims the one automatic title request for a
// session once its first user and assistant texts are complete. The request is
// intentionally asynchronous: an unavailable model must never delay terminal
// or agent event delivery.
func (s *Service) tryStartSessionTitle(sessionID string) {
	if !s.titleGenerationConfigured() || s.Store == nil {
		return
	}
	state := s.Store.Snapshot()
	found := false
	for _, session := range state.Sessions {
		if session.ID != sessionID {
			continue
		}
		found = true
		// Do not spend a request for a session that already has a manual or
		// previously generated title, or whose runtime has already ended.
		if strings.TrimSpace(session.CustomTitle) != "" || session.Lifecycle != "running" {
			return
		}
		break
	}
	if !found {
		return
	}
	var input sessiontitle.Input
	s.agentsMu.Lock()
	entry := s.agents[sessionID]
	if entry == nil {
		s.agentsMu.Unlock()
		return
	}
	entry.mu.Lock()
	if entry.titleGenerationStarted || !entry.titleAssistantComplete ||
		strings.TrimSpace(entry.titleUser) == "" || strings.TrimSpace(entry.titleAssistant) == "" {
		entry.mu.Unlock()
		s.agentsMu.Unlock()
		return
	}
	entry.titleGenerationStarted = true
	input = sessiontitle.Input{
		User:      entry.titleUser,
		Assistant: entry.titleAssistant,
	}
	entry.mu.Unlock()
	s.agentsMu.Unlock()

	config := sessiontitle.Config{
		BaseURL: s.Settings.OpenAIBaseURL,
		Model:   s.Settings.OpenAIModel,
		APIKey:  s.Settings.OpenAIKey,
	}
	go s.generateSessionTitle(sessionID, config, input)
}

func (s *Service) titleGenerationConfigured() bool {
	return s.Settings.OpenAITitleEnabled &&
		strings.TrimSpace(s.Settings.OpenAIBaseURL) != "" &&
		strings.TrimSpace(s.Settings.OpenAIKey) != ""
}

// TestOpenAITitle makes one best-effort title request without changing
// settings or session state. An empty key uses the key already held by the
// Host so clients can test a saved credential without downloading it.
func (s *Service) TestOpenAITitle(ctx context.Context, baseURL, model, apiKey string) error {
	if strings.TrimSpace(apiKey) == "" {
		apiKey = s.Settings.OpenAIKey
	}
	requestContext, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	_, err := (sessiontitle.Generator{Config: sessiontitle.Config{
		BaseURL: baseURL,
		Model:   model,
		APIKey:  apiKey,
	}}).Generate(requestContext, sessiontitle.Input{
		User:      "Verify that this coding session title endpoint is reachable.",
		Assistant: "The endpoint is responding.",
	})
	return err
}

// isTitleSystemContext filters provider-injected scaffolding that can arrive
// as a user-role event. It must not become the subject of an automatic title.
func isTitleSystemContext(content string) bool {
	content = strings.TrimSpace(content)
	return strings.HasPrefix(strings.ToLower(content), "# agents.md") ||
		strings.HasPrefix(content, "<environment_context>") ||
		strings.HasPrefix(content, "<collaboration_mode>") ||
		strings.Contains(content, "<permissions instructions>")
}

// appendTitleMessage keeps the first real text message and only appends
// deltas that belong to that same provider message. Provider message IDs are
// present for OpenCode; the empty-ID fallback keeps normalized test and legacy
// events usable without allowing a later complete message to replace it.
func appendTitleMessage(value, provider, messageID *string, event api.AgentEvent) bool {
	content := strings.TrimSpace(event.Content)
	if content == "" {
		return false
	}
	if *value == "" {
		*value = content
		*provider = event.Provider
		*messageID = event.ID
		return true
	}
	if !event.ContentDelta || event.Provider != *provider {
		return false
	}
	if *messageID != "" {
		if event.ID != *messageID {
			return false
		}
	} else if event.ID != "" {
		return false
	}
	*value = strings.TrimSpace(*value + event.Content)
	return true
}

func (s *Service) generateSessionTitle(sessionID string, config sessiontitle.Config, input sessiontitle.Input) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	titleValue, err := (sessiontitle.Generator{Config: config}).Generate(ctx, input)
	if err != nil {
		s.logWarn("generate session title", "session", sessionID, "error", err)
		return
	}
	err = s.Store.Update(func(state *api.State) error {
		for index := range state.Sessions {
			session := &state.Sessions[index]
			if session.ID != sessionID {
				continue
			}
			// CustomTitle is also the durable automatic display override. A
			// manual rename that wins the race must never be overwritten.
			if strings.TrimSpace(session.CustomTitle) != "" || session.Lifecycle != "running" {
				return nil
			}
			session.CustomTitle = titleValue
			return nil
		}
		return fmt.Errorf("session not found: %s", sessionID)
	})
	if err != nil {
		s.logWarn("persist session title", "session", sessionID, "error", err)
	} else {
		s.wakeLiveActivity()
	}
}

// forceAgentStatus records a state transition that must override an exited
// marker, such as a new SessionStart resetting the shell overlay to ready.
func (s *Service) forceAgentStatus(sessionID string, status api.AgentStatus) {
	s.setAgentStatus(sessionID, status, true)
}

func (s *Service) setAgentStatus(sessionID string, status api.AgentStatus, force bool) {
	s.setAgentStatusForHandle(sessionID, nil, status, force)
}

func (s *Service) setAgentStatusForHandle(sessionID string, expected AgentHandle, status api.AgentStatus, force bool) {
	var broadcastLock *sessionLock
	if expected != nil {
		broadcastLock = s.broadcastLock(sessionID)
		broadcastLock.Lock()
		defer broadcastLock.Unlock()
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
	if s.AgentStore != nil {
		result, err := s.AgentStore.QueryCanonicalEvents(ctx, streamID, after, before, limit)
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
	if status.Activity == "" && s.AgentStore != nil {
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
	case api.AgentActivityBlocked, api.AgentActivityStalled:
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
	if s.AgentStore != nil {
		if checkpoint, ok, err := s.AgentStore.CanonicalCheckpoint(context.Background(), s.canonicalExecutionID(sessionID)); err == nil && ok &&
			(checkpoint.Sequence == sequence || sequence == 0) {
			return checkpoint
		}
	}
	status := s.agentStatus(sessionID)
	turn := s.agentTurn(sessionID)
	return api.AgentProjectionCheckpoint{Sequence: sequence, State: canonicalProjectionState(status, turn)}
}

type canonicalInteractionProjection struct {
	kind      string
	version   uint64
	state     string
	optionIDs map[string]struct{}
}

func canonicalEntryHasResolvedInteraction(entry *agentSession, interactionID string) bool {
	return canonicalEntryHasTerminalInteraction(entry, interactionID)
}

func canonicalEntryHasTerminalInteraction(entry *agentSession, interactionID string) bool {
	if entry == nil || strings.TrimSpace(interactionID) == "" {
		return false
	}
	for _, event := range entry.canonicalEvents {
		if event.Type != "interaction.resolved" && event.Type != "interaction.expired" {
			continue
		}
		if canonicalInteractionEventMatchesID(event, interactionID) {
			return true
		}
	}
	return false
}

func canonicalInteractionEventID(event api.AgentEvent) string {
	if event.Payload != nil {
		for _, key := range []string{"interactionId", "requestId"} {
			if value, ok := event.Payload[key].(string); ok && strings.TrimSpace(value) != "" {
				return strings.TrimSpace(value)
			}
		}
	}
	return strings.TrimSpace(event.ID)
}

func canonicalInteractionCanonicalID(event api.CanonicalAgentEvent) string {
	if event.Payload != nil {
		for _, key := range []string{"interactionId", "requestId"} {
			if value, ok := event.Payload[key].(string); ok && strings.TrimSpace(value) != "" {
				return strings.TrimSpace(value)
			}
		}
	}
	return strings.TrimSpace(event.EventID)
}

func canonicalInteractionIdentityValues(event api.CanonicalAgentEvent) []string {
	values := make([]string, 0, 2)
	if event.Payload != nil {
		for _, key := range []string{"interactionId", "requestId"} {
			value, ok := event.Payload[key].(string)
			value = strings.TrimSpace(value)
			if !ok || value == "" {
				continue
			}
			seen := false
			for _, prior := range values {
				if prior == value {
					seen = true
					break
				}
			}
			if !seen {
				values = append(values, value)
			}
		}
	}
	if len(values) == 0 {
		if eventID := strings.TrimSpace(event.EventID); eventID != "" {
			values = append(values, eventID)
		}
	}
	return values
}

func canonicalInteractionEventMatchesID(event api.CanonicalAgentEvent, interactionID string) bool {
	interactionID = strings.TrimSpace(interactionID)
	if interactionID == "" {
		return false
	}
	for _, value := range canonicalInteractionIdentityValues(event) {
		if value == interactionID {
			return true
		}
	}
	return false
}

func canonicalInteractionEventsMatch(left, right api.CanonicalAgentEvent) bool {
	leftValues := canonicalInteractionIdentityValues(left)
	rightValues := canonicalInteractionIdentityValues(right)
	for _, leftValue := range leftValues {
		for _, rightValue := range rightValues {
			if leftValue == rightValue {
				return true
			}
		}
	}
	return false
}

// mergeCanonicalInteractionContext keeps the request schema attached to a
// terminal lifecycle row. Providers commonly emit only requestId/state in the
// tool result; dropping the original questions/options makes an Answered card
// impossible to inspect after replay.
func mergeCanonicalInteractionContext(history []api.CanonicalAgentEvent, event *api.CanonicalAgentEvent) {
	if event == nil || event.Payload == nil || event.Type == "interaction.requested" {
		return
	}
	if canonicalInteractionCanonicalID(*event) == "" {
		return
	}
	for index := len(history) - 1; index >= 0; index-- {
		candidate := history[index]
		if candidate.Type != "interaction.requested" || !canonicalInteractionEventsMatch(candidate, *event) {
			continue
		}
		if candidate.Payload == nil {
			return
		}
		for _, key := range []string{"interactionId", "requestId", "kind", "title", "description", "schema", "options", "questions", "version", "turnId"} {
			if _, exists := event.Payload[key]; exists {
				continue
			}
			if value, exists := candidate.Payload[key]; exists {
				event.Payload[key] = value
			}
		}
		return
	}
}

// canonicalInteraction resolves the provider-neutral interaction projection
// from immutable events. The wire command carries only interactionId and
// version; accepting a guessed kind or an old version would let a client
// answer a different interaction than the one shown by the Host.
func (s *Service) canonicalInteraction(sessionID, interactionID string) (canonicalInteractionProjection, bool) {
	interactionID = strings.TrimSpace(interactionID)
	if interactionID == "" {
		return canonicalInteractionProjection{}, false
	}
	execution, ok := s.canonicalExecutionForSession(sessionID)
	if !ok || execution.StreamID == "" {
		return canonicalInteractionProjection{}, false
	}
	result, err := s.canonicalHistoryPage(context.Background(), execution.StreamID, 0, 0, agentHistoryMaxLimit)
	if err != nil {
		return canonicalInteractionProjection{}, false
	}
	var projection canonicalInteractionProjection
	for _, event := range result.Events {
		if event.Type != "interaction.requested" && event.Type != "interaction.resolved" && event.Type != "interaction.expired" {
			continue
		}
		if !canonicalInteractionEventMatchesID(event, interactionID) {
			continue
		}
		if kind, _ := event.Payload["kind"].(string); kind != "" {
			kind = strings.ToLower(strings.TrimSpace(kind))
			if kind == "question" || kind == "permission" || kind == "confirmation" {
				projection.kind = kind
			}
		}
		if event.Type == "interaction.requested" {
			if projection.optionIDs == nil {
				projection.optionIDs = make(map[string]struct{})
			}
			collectCanonicalInteractionOptionIDs(event.Payload["options"], projection.optionIDs, 0)
			collectCanonicalInteractionOptionIDs(event.Payload["schema"], projection.optionIDs, 0)
			collectCanonicalQuestionOptionIDs(event.Payload["questions"], projection.optionIDs, 0)
		}
		if version := canonicalInteractionVersion(event.Payload["version"]); version > 0 {
			projection.version = version
		} else if projection.version == 0 {
			projection.version = 1
		}
		state, _ := event.Payload["state"].(string)
		state = strings.ToLower(strings.TrimSpace(strings.ReplaceAll(state, "-", "_")))
		switch event.Type {
		case "interaction.requested":
			if state == "" {
				state = "pending"
			}
		case "interaction.resolved":
			// The lifecycle type is authoritative even when a provider uses
			// answered/accepted/completed in its payload.
			state = "resolved"
		case "interaction.expired":
			state = "expired"
		}
		if state != "" {
			projection.state = state
		}
	}
	return projection, projection.kind != ""
}

const (
	canonicalInteractionMaxFields = 32
	canonicalInteractionMaxDepth  = 4
	canonicalInteractionMaxText   = 16 * 1024
)

// collectCanonicalInteractionOptionIDs extracts only bounded option-like
// values from a provider schema. It is deliberately not a general JSON Schema
// evaluator: the Host validates the response shape and option identity while
// leaving provider-specific presentation fields opaque.
func collectCanonicalInteractionOptionIDs(value any, ids map[string]struct{}, depth int) {
	if depth > canonicalInteractionMaxDepth || len(ids) >= 128 {
		return
	}
	switch value := value.(type) {
	case []any:
		for _, item := range value {
			collectCanonicalInteractionOptionIDs(item, ids, depth+1)
			if len(ids) >= 128 {
				return
			}
		}
	case map[string]any:
		for key, item := range value {
			switch strings.ToLower(strings.TrimSpace(key)) {
			case "id", "value":
				if text, ok := item.(string); ok {
					text = strings.TrimSpace(text)
					if text != "" && len(text) <= 1024 {
						ids[text] = struct{}{}
					}
				}
			case "options", "enum", "items", "properties":
				collectCanonicalInteractionOptionIDs(item, ids, depth+1)
			}
			if len(ids) >= 128 {
				return
			}
		}
	}
}

// Question payloads keep their selectable values one level below a
// `questions` array. Do not feed the whole object into the generic collector:
// a question's own `id` is not an answer option and must not become accepted
// merely because it happens to use the same field name.
func collectCanonicalQuestionOptionIDs(value any, ids map[string]struct{}, depth int) {
	if depth > canonicalInteractionMaxDepth || len(ids) >= 128 {
		return
	}
	switch value := value.(type) {
	case []any:
		for _, item := range value {
			collectCanonicalQuestionOptionIDs(item, ids, depth+1)
			if len(ids) >= 128 {
				return
			}
		}
	case map[string]any:
		for key, item := range value {
			switch strings.ToLower(strings.TrimSpace(key)) {
			case "options", "enum":
				collectCanonicalInteractionOptionIDs(item, ids, depth+1)
			case "questions", "schema", "items":
				collectCanonicalQuestionOptionIDs(item, ids, depth+1)
			}
			if len(ids) >= 128 {
				return
			}
		}
	}
}

func validateCanonicalInteractionResolution(projection canonicalInteractionProjection, resolution map[string]any) error {
	if len(resolution) == 0 {
		return errors.New("interaction resolution must not be empty")
	}
	if len(resolution) > canonicalInteractionMaxFields {
		return fmt.Errorf("interaction resolution has too many fields (max %d)", canonicalInteractionMaxFields)
	}
	if cancelled, present := resolution["cancelled"]; present {
		value, ok := cancelled.(bool)
		if !ok {
			return errors.New("interaction resolution cancelled must be a boolean")
		}
		if value {
			return nil
		}
	}
	for _, key := range []string{"decision", "value", "text"} {
		if raw, present := resolution[key]; present {
			text, ok := raw.(string)
			if !ok || strings.TrimSpace(text) == "" {
				return fmt.Errorf("interaction resolution %s must be a non-empty string", key)
			}
			if len(text) > canonicalInteractionMaxText {
				return fmt.Errorf("interaction resolution %s is too large", key)
			}
		}
	}
	if projection.kind == "permission" || projection.kind == "confirmation" {
		choice := strings.TrimSpace(agentStringValue(resolution["decision"]))
		if choice == "" {
			choice = strings.TrimSpace(agentStringValue(resolution["value"]))
		}
		if choice == "" {
			return fmt.Errorf("%s resolution requires decision or value", projection.kind)
		}
		if len(projection.optionIDs) > 0 {
			if _, ok := projection.optionIDs[choice]; !ok {
				return fmt.Errorf("%s resolution selects an unknown option", projection.kind)
			}
		}
		return nil
	}
	if projection.kind != "question" {
		return fmt.Errorf("unsupported interaction kind %q", projection.kind)
	}
	for _, key := range []string{"answers", "customAnswers"} {
		if raw, present := resolution[key]; present {
			values, ok := raw.(map[string]any)
			if !ok || len(values) == 0 || len(values) > canonicalInteractionMaxFields {
				return fmt.Errorf("interaction resolution %s must be a bounded object", key)
			}
			for _, value := range values {
				if err := validateCanonicalInteractionAnswer(value, key == "answers", projection.optionIDs, 0); err != nil {
					return err
				}
			}
		}
	}
	if text := strings.TrimSpace(agentStringValue(resolution["text"])); text != "" {
		return nil
	}
	if _, answers := resolution["answers"]; !answers {
		if _, custom := resolution["customAnswers"]; !custom {
			return errors.New("question resolution requires answers, customAnswers, text, or cancelled")
		}
	}
	return nil
}

func validateCanonicalInteractionAnswer(value any, optionValue bool, optionIDs map[string]struct{}, depth int) error {
	if depth > 3 {
		return errors.New("interaction answer is too deeply nested")
	}
	switch value := value.(type) {
	case string:
		text := strings.TrimSpace(value)
		if text == "" || len(text) > canonicalInteractionMaxText {
			return errors.New("interaction answer must be a bounded non-empty string")
		}
		if optionValue && len(optionIDs) > 0 {
			if _, ok := optionIDs[text]; !ok {
				return errors.New("interaction answer selects an unknown option")
			}
		}
		return nil
	case []any:
		if len(value) == 0 || len(value) > canonicalInteractionMaxFields {
			return errors.New("interaction answer list must be bounded and non-empty")
		}
		for _, item := range value {
			if err := validateCanonicalInteractionAnswer(item, optionValue, optionIDs, depth+1); err != nil {
				return err
			}
		}
		return nil
	case map[string]any:
		if len(value) == 0 || len(value) > canonicalInteractionMaxFields {
			return errors.New("interaction answer object must be bounded and non-empty")
		}
		for _, item := range value {
			if err := validateCanonicalInteractionAnswer(item, false, nil, depth+1); err != nil {
				return err
			}
		}
		return nil
	default:
		return errors.New("interaction answer contains an unsupported value")
	}
}

func canonicalInteractionVersion(value any) uint64 {
	switch value := value.(type) {
	case uint64:
		return value
	case uint32:
		return uint64(value)
	case uint:
		return uint64(value)
	case int:
		if value > 0 {
			return uint64(value)
		}
	case int64:
		if value > 0 {
			return uint64(value)
		}
	case float64:
		if value > 0 && value == float64(uint64(value)) {
			return uint64(value)
		}
	case json.Number:
		if parsed, err := strconv.ParseUint(string(value), 10, 64); err == nil {
			return parsed
		}
	case string:
		if parsed, err := strconv.ParseUint(strings.TrimSpace(value), 10, 64); err == nil {
			return parsed
		}
	}
	return 0
}

func (s *Service) canonicalInteractionKind(sessionID, interactionID string) (string, bool) {
	projection, found := s.canonicalInteraction(sessionID, interactionID)
	return projection.kind, found
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
	case api.AgentActivityWorking, api.AgentActivityBlocked, api.AgentActivityStalled:
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
	case api.AgentActivityBlocked, api.AgentActivityStalled:
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
	lock := s.broadcastLock(sessionID)
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
// and event subscribers under the session broadcast lock.
func (s *Service) broadcastAgent(send func(*wsPeer) error, sessionID string) {
	lock := s.broadcastLock(sessionID)
	lock.Lock()
	defer lock.Unlock()
	s.broadcastAgentLocked(send, sessionID)
}

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
	// Resolve the recipients before touching the session broadcast lock. Every
	// subscriber that negotiated a direct Ghostline reader is served from its
	// own paired stream and is excluded below, so this set is empty for a
	// session whose only subscribers are current desktop clients. Locking for
	// an empty set is what turned ordinary contention into a peer reset: the
	// timeout path closed every subscription on the session even though this
	// frame was never going to be written to any of them.
	if len(s.sharedBroadcastPeers(frame.SessionID)) == 0 {
		return
	}
	encoded, err := output.EncodeOutput(frame.SessionID, frame.Epoch, frame.Sequence, frame.Payload)
	if err != nil {
		return
	}
	lock := s.broadcastLock(frame.SessionID)
	if !lock.TryLock() {
		// The same lock is held by attach recovery while it captures a
		// checkpoint, by focus/resize while the runtime applies a PTY size, and
		// by the Agent subsystem while it reads a canonical history page.
		// Waiting preserves frame ordering (the ring already owns these bytes)
		// and is always preferable to a reset, so the deadline has to cover the
		// slowest legitimate holder rather than a shorter guess.
		ctx, cancel := context.WithTimeout(context.Background(), s.broadcastLockWait())
		err := lock.LockContext(ctx)
		cancel()
		if err != nil {
			// Only the peers that were about to receive this frame can have a
			// gap. Peers reading their own direct stream are unaffected and must
			// keep their connection: one contended session must never drop the
			// other sessions multiplexed onto the same WebSocket.
			s.forcePeerReanchor(frame.SessionID, s.sharedBroadcastPeers(frame.SessionID))
			return
		}
	}
	defer lock.Unlock()
	// Re-resolve under the lock. An attach we waited on promotes its peer to a
	// direct reader, and that peer must not also receive this frame.
	for _, peer := range s.sharedBroadcastPeers(frame.SessionID) {
		if !peer.enqueueBinary(encoded) {
			s.detachPeer(peer, frame.SessionID)
		}
	}
}

// sharedBroadcastPeers lists the subscribers of a session that are still served
// from the shared ring. A peer holding a direct Ghostline reader — reserved
// during recovery or already running — receives that stream instead and is
// excluded.
func (s *Service) sharedBroadcastPeers(sessionID string) []*wsPeer {
	s.outputMu.Lock()
	defer s.outputMu.Unlock()
	peers := make([]*wsPeer, 0, len(s.peers[sessionID]))
	for peer := range s.peers[sessionID] {
		if streams := s.peerOutputs[peer]; streams != nil {
			if _, direct := streams[sessionID]; direct {
				continue
			}
		}
		peers = append(peers, peer)
	}
	return peers
}

// broadcastLockWait bounds how long a shared-ring frame waits for the session
// broadcast lock. Every legitimate holder is itself bounded by the command
// timeout, so reaching this deadline means the lock leaked rather than that the
// receiving peer is slow.
func (s *Service) broadcastLockWait() time.Duration {
	return s.commandTimeout()
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

// forcePeerReanchor resets the given subscribers after a shared-ring frame
// could not be delivered, so a gap is never papered over silently. Closing the
// connection is the only in-protocol resync signal: a reconnecting peer always
// receives a fresh atomic state, so no recovery mode is carried in the ring.
// The caller decides which peers are affected — this must not extend to peers
// that were never a recipient of the undelivered frame.
func (s *Service) forcePeerReanchor(sessionID string, peers []*wsPeer) {
	if len(peers) == 0 {
		return
	}
	s.logWarn("force peer reanchor", "session", sessionID, "peers", len(peers))
	for _, peer := range peers {
		peer.closeWithReason("force_reanchor")
	}
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
	peer.ensureAttachment(session.ID)

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
	if s.controlPeers[sessionID] == peer {
		delete(s.controlPeers, sessionID)
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
	if peers := s.agentPeers[sessionID]; peers != nil {
		delete(peers, peer)
		if len(peers) == 0 {
			delete(s.agentPeers, sessionID)
		}
	}
	// Agent subscriptions are passive, but an Agent-only action may have
	// promoted this peer to the per-session mutation lease. A disconnect (or a
	// rapid stream switch) must release that lease or every later client will
	// observe a permanently occupied owner. Preserve the lease when this same
	// peer still owns terminal focus; in that case the terminal subscription is
	// the live owner and should continue to gate input/resize.
	if s.controlPeers[sessionID] == peer && s.focusedPeers[sessionID] != peer {
		delete(s.controlPeers, sessionID)
	}
	s.outputMu.Unlock()
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
			if s.controlPeers[session.ID] == peer {
				delete(s.controlPeers, session.ID)
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
	s.controlPeers[session.ID] = peer
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

// claimControlPeer transfers the mutation lease without requiring a terminal
// output subscription. This is used by Agent-only Stop/interaction actions;
// terminal focus still remains separately gated by the output roster.
func (s *Service) claimControlPeer(peer *wsPeer, sessionID string) bool {
	s.lazyInit()
	s.outputMu.Lock()
	s.controlPeers[sessionID] = peer
	s.outputMu.Unlock()
	return true
}

// claimAgentControlPeer acknowledges an Agent-only focus request.
// Agent View operations operate through structured, idempotent RPCs and do not
// contend with or require the single-tenant Terminal PTY control lease.
func (s *Service) claimAgentControlPeer(peer *wsPeer, sessionID string) bool {
	return true
}

func (s *Service) releaseControlPeer(peer *wsPeer, sessionID string) {
	s.lazyInit()
	s.outputMu.Lock()
	if s.controlPeers[sessionID] == peer {
		delete(s.controlPeers, sessionID)
	}
	s.outputMu.Unlock()
}

func (s *Service) hasControlPeer(peer *wsPeer, sessionID string) bool {
	s.outputMu.Lock()
	defer s.outputMu.Unlock()
	return s.controlPeers[sessionID] == peer
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
	delete(s.controlPeers, sessionID)
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
		s.wakeLiveActivity()
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

// regularFileExists reports whether path names an existing regular file. It
// mirrors the transcript guards in the agent package so binding fallbacks only
// adopt files the provider is actually writing.
func regularFileExists(path string) bool {
	if strings.TrimSpace(path) == "" {
		return false
	}
	info, err := os.Stat(path)
	return err == nil && !info.IsDir()
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
