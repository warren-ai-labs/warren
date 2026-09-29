package server

import (
	"context"
	"io"
	"log/slog"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/abcdlsj/ghostline"
	"github.com/abcdlsj/warren/Headless/internal/agent"
	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/browser"
	"github.com/abcdlsj/warren/Headless/internal/settings"
	"github.com/abcdlsj/warren/Headless/internal/store"
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
	// agentJournalPruneInterval is how often the background sweep looks for
	// retired Agent streams. It is far slower than reconcile because the sweep
	// deletes rows and has no reason to touch the journal often.
	agentJournalPruneInterval = 10 * time.Minute
	// agentJournalRetentionGrace is how long a stream survives its last write
	// before the sweep may remove it. Sessions still running are protected
	// explicitly; the grace covers a Session that just ended and any replica
	// that is still catching up.
	agentJournalRetentionGrace = 24 * time.Hour
	// agentJournalPruneRowBudget bounds one prune transaction. One stream can
	// hold tens of thousands of rows, and a single large delete would hold the
	// store write lock long enough to stall live appends and history reads.
	agentJournalPruneRowBudget = 2000
	// agentJournalPrunePause is yielded between prune transactions so live
	// appends interleave with a long sweep.
	agentJournalPrunePause = 50 * time.Millisecond
	// agentJournalReclaimPages bounds one incremental vacuum. An unbounded one
	// frees the whole freelist in a single transaction and holds the store
	// write lock for seconds.
	agentJournalReclaimPages = 2000
	// operationAuditLimit keeps the durable safety log bounded. Only entries
	// with a compare-and-swap undo representation are retained.
	operationAuditLimit = 256
	setupScriptTimeout  = 5 * time.Minute
)

type Service struct {
	// acpHandoffs holds the chat Sessions currently moving to a terminal
	// (RFC 0023 §6.12); no agent process may start for them meanwhile.
	acpHandoffs sync.Map

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
	// ACPShell overrides the login shell used to launch ACP agents. Tests use
	// it to run a fake agent directly; nil uses the user's login shell.
	ACPShell func() (string, []string)
	// ACPHoldCommand runs an ACP agent's holder as its own process, so the
	// agent survives a Host restart. Nil runs holders inside the Host, which
	// then outlive only a Service, not the process.
	ACPHoldCommand []string
	// ACPHoldDir holds the holder sockets; empty uses a temporary directory.
	ACPHoldDir   string
	RingCapacity int
	RingMaxBytes int
	// CommandTimeout bounds runtime operations during attach and adoption. A
	// stuck runtime must fail the attach and release the session broadcast
	// lock instead of wedging the session until the
	// daemon restarts.
	CommandTimeout time.Duration
	// ProbeForeground enables the runtime's OS-level foreground process probe
	// (process name and command line). The metadata loop runs regardless so the
	// shell's OSC 7 working directory always reaches the roster; this flag only
	// controls the extra probe cost.
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
	// browserMu guards the lazily-created Chromium manager. A browser Session
	// has no PTY runtime, so it cannot join Runtimes; creating the manager on
	// first use also means a Host that never opens a browser never needs a
	// writable profile directory.
	browserMu sync.Mutex
	browsers  *browser.Manager
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
	// resizePeers is the authoritative per-session viewport owner. It is
	// deliberately separate from focusedPeers/controlPeers: a split window
	// shows several sessions at once, and a passive pane must be able to size
	// its own PTY without taking keyboard input away from whichever client is
	// actively using that session. The focused peer owns the size; when no
	// peer owns it, any output subscriber may adopt it.
	resizePeers map[string]*wsPeer
	// controlPeers is the authoritative per-session mutation lease. Terminal
	// focus normally owns the same lease, but Agent-only actions may claim it
	// before a terminal output subscription exists.
	controlPeers   map[string]*wsPeer
	runtimeSizes   map[string]ghostline.Size
	broadcastLocks map[string]*sessionLock
	// agentLocks order canonical Agent history reads against live Agent
	// increments for one session. They are separate from broadcastLocks so a
	// slow journal query never stalls terminal output, attach, or resize.
	agentLocks map[string]*sessionLock
	// resizeMu guards the per-session viewport queue below. Runtime.Resize can
	// block for seconds on a remote host, so it must never run on the
	// WebSocket reader. The queue serializes per session with latest-wins
	// semantics: a slow resize cannot delay attach/recovery on the same
	// connection, and two resizes for one session cannot apply out of order.
	resizeMu      sync.Mutex
	resizePending map[string]ghostline.Size
	resizeActive  map[string]bool
	resizeWorkers sync.WaitGroup
	agentsMu      sync.Mutex
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

	lifecycleOnce   sync.Once
	lifecycleCancel context.CancelFunc
	// agentStoreMu guards the one-time open of AgentStorePath. Opening the
	// agent journal is expensive, so it must never run inside outputMu:
	// roster snapshots and terminal attaches call lazyInit on their hot path
	// and would otherwise stall for the whole open.
	agentStoreMu                sync.Mutex
	canonicalCommandsReconciled bool
	usageAttributionInstalled   bool
	// agentJournalPruning keeps at most one background sweep in flight. The
	// sweep runs in its own goroutine because it can take minutes.
	agentJournalPruning atomic.Bool
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

type Runtime interface {
	Create(context.Context, string, string, string, []string) error
	Exists(context.Context, string) bool
	Capture(context.Context, string) ([]byte, error)
	Input(context.Context, string, []byte) error
	Resize(context.Context, string, int, int) error
	Kill(context.Context, string) error
}

// ProcessRuntime runs one command as a PTY's process instead of an
// interactive shell. It backs the terminals an ACP agent creates
// (RFC 0023 §6.6): their output must be the command's own and their exit
// status the command's.
type ProcessRuntime interface {
	CreateProcess(ctx context.Context, name, directory string, argv, env []string) error
	// ProcessOutput streams raw output from the first retained byte and ends
	// once the process has ended and its output is drained.
	ProcessOutput(ctx context.Context, name string) (io.ReadCloser, error)
	WaitProcess(ctx context.Context, name string) (RuntimeExit, error)
	TerminateProcess(ctx context.Context, name string) error
}

// RuntimeExit is how a process ended. Code is -1 when it was signaled or its
// status is unknown.
type RuntimeExit struct {
	Code   int
	Signal string
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

// RuntimeSizeProvider reports the current PTY grid size for a runtime. The
// lifecycle loop seeds the shared-size cache from it after a restart so a
// client focus whose size is unchanged can skip a resize round trip -- which
// otherwise holds the session broadcast lock while the freshly handed-off
// Ghostline server is still adopting sessions.
type RuntimeSizeProvider interface {
	Size(context.Context, string) (ghostline.Size, error)
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
	startedAt := time.Now()
	s.outputMu.Lock()
	waited := time.Since(startedAt)
	s.lazyInitLocked()
	s.outputMu.Unlock()
	if waited >= 100*time.Millisecond {
		// lazyInit is on the roster and terminal-attach hot paths; a long wait
		// here means another goroutine is holding outputMu across slow work.
		s.logInfo("slow lazy init lock wait", "duration", waited)
	}
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
	if s.resizePeers == nil {
		s.resizePeers = map[string]*wsPeer{}
	}
	if s.resizePending == nil {
		s.resizePending = map[string]ghostline.Size{}
	}
	if s.resizeActive == nil {
		s.resizeActive = map[string]bool{}
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
	if s.agentLocks == nil {
		s.agentLocks = map[string]*sessionLock{}
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

// agentStore returns the durable agent journal, opening it once on first use.
//
// It is deliberately separate from lazyInit/outputMu. Opening the journal can
// take seconds on a large database, and lazyInit runs on the roster and
// terminal-attach hot paths, so doing it there stalled them for the whole
// open. Callers that actually need the journal come through here; callers that
// do not never pay for it.
func (s *Service) agentStore() *store.AgentEventStore {
	s.agentStoreMu.Lock()
	defer s.agentStoreMu.Unlock()
	initStartedAt := time.Now()
	if s.AgentStore == nil && strings.TrimSpace(s.AgentStorePath) != "" {
		path := resolvePath(expandHome(s.AgentStorePath))
		if agentStore, err := store.OpenAgentEventStore(path); err == nil {
			s.AgentStore = agentStore
		}
	}
	if s.AgentStore == nil {
		return nil
	}
	if !s.usageAttributionInstalled {
		// The journal owns no host state, so it cannot map a stream to a
		// project on its own. Injecting the lookup keeps spend attributable
		// while leaving stores built by tests and embedders inert.
		s.AgentStore.SetUsageAttributionResolver(s.usageAttributionForStream)
		s.usageAttributionInstalled = true
	}
	if !s.canonicalCommandsReconciled {
		if _, err := s.AgentStore.ReconcilePendingCanonicalCommands(
			context.Background(), time.Now().UTC(), canonicalCommandRecoveryAge,
		); err != nil {
			s.logWarn("reconcile pending canonical commands", "error", err)
		} else {
			s.canonicalCommandsReconciled = true
		}
	}
	if elapsed := time.Since(initStartedAt); elapsed >= 500*time.Millisecond {
		s.logInfo("slow agent store init", "duration", elapsed)
	}
	return s.AgentStore
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
		// Open the agent journal off the request path: roster snapshots and
		// terminal attaches must never wait for this. Agent traffic that
		// arrives before it is ready blocks on agentStore's own mutex.
		go s.agentStore()
		go s.lifecycleLoop(ctx)
		go s.liveActivityLoop(ctx)
		go s.mergeLoop(ctx)
		// Run the metadata loop regardless of ProbeForeground: the OSC 7
		// working directory is cheap and must reach the roster, while the OS
		// foreground probe only adds data when the runtime was started with it.
		go s.metadataLoop(ctx)
	})
}

func (s *Service) Shutdown() {
	if s.lifecycleCancel != nil {
		s.lifecycleCancel()
	}
	// Every managed Chromium is a child process. Leaving one running past
	// shutdown would strand a browser no Host can drive.
	if manager := s.browserManagerIfPresent(); manager != nil {
		manager.Close()
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
		// A handle that can detach leaves its agent running for the next
		// Host; closing it would end the agent with the daemon.
		if detacher, ok := handle.(interface{ Detach() error }); ok {
			_ = detacher.Detach()
			continue
		}
		_ = handle.Close()
	}
}

func (s *Service) lifecycleLoop(ctx context.Context) {
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	reaper := time.NewTicker(orphanReapInterval)
	defer reaper.Stop()
	pruner := time.NewTicker(agentJournalPruneInterval)
	defer pruner.Stop()
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
		case <-pruner.C:
			s.startAgentJournalPrune(ctx)
		}
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
