package api

import (
	"time"

	"github.com/abcdlsj/warren/Headless/internal/protocol"
)

// Version is the logical protocol version. Sourced from
// protocol/warren.schema.json via internal/protocol; do not edit here.
const Version = protocol.LogicalVersion

type Host struct {
	ID      string `json:"id"`
	Name    string `json:"name"`
	User    string `json:"user,omitempty"`
	OS      string `json:"os,omitempty"`
	Version string `json:"version"`
}

type Task struct {
	ID                  string    `json:"id"`
	Name                string    `json:"name"`
	Source              string    `json:"source,omitempty"`
	ExternalID          string    `json:"externalID,omitempty"`
	URL                 string    `json:"url,omitempty"`
	CreationRequestID   string    `json:"creationRequestId,omitempty"`
	CreationRequestHash string    `json:"creationRequestHash,omitempty"`
	Pinned              bool      `json:"pinned,omitempty"`
	Order               int       `json:"order,omitempty"`
	CreatedAt           time.Time `json:"createdAt"`
}

type Project struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	Path string `json:"path"`
	// SetupScript is an optional executable path, relative to Path unless
	// absolute. It runs in newly created managed worktrees only.
	SetupScript string `json:"setupScript,omitempty"`
	// AutoImportGitWorktrees controls whether this project imports every
	// existing Git worktree when the project is added or the setting is enabled.
	// It is deliberately project-scoped; one repository's worktree policy must
	// not silently change another repository's import behavior.
	AutoImportGitWorktrees bool      `json:"autoImportGitWorktrees"`
	Pinned                 bool      `json:"pinned,omitempty"`
	Order                  int       `json:"order,omitempty"`
	CreatedAt              time.Time `json:"createdAt"`
}

// WorktreeCandidate describes an existing Git worktree that can be imported
// into a Project. Imported candidates remain in the list so clients can show
// them as disabled instead of hiding the one-time import state.
type WorktreeCandidate struct {
	Path        string `json:"path"`
	Name        string `json:"name"`
	Branch      string `json:"branch,omitempty"`
	Locked      bool   `json:"locked,omitempty"`
	Imported    bool   `json:"imported"`
	WorkspaceID string `json:"workspace,omitempty"`
}

type Workspace struct {
	ID                  string `json:"id"`
	ProjectID           string `json:"project"`
	TaskID              string `json:"task,omitempty"`
	Name                string `json:"name"`
	Path                string `json:"path"`
	Branch              string `json:"branch,omitempty"`
	Kind                string `json:"kind"`
	CreationRequestID   string `json:"creationRequestId,omitempty"`
	CreationRequestHash string `json:"creationRequestHash,omitempty"`
	// ManagedWorktree is true only for Git worktrees created by Warren. An
	// imported checkout remains on disk when its Warren record is removed.
	ManagedWorktree bool `json:"managedWorktree,omitempty"`
	// WorktreeLocked mirrors Git's lock marker. Locked worktrees are never
	// removed automatically, even when a caller asks to remove the directory.
	WorktreeLocked bool      `json:"worktreeLocked,omitempty"`
	Pinned         bool      `json:"pinned,omitempty"`
	Order          int       `json:"order,omitempty"`
	CreatedAt      time.Time `json:"createdAt"`
	// MergeState is the live merge projection of the workspace branch against
	// the project's default branch. It is overlaid on roster snapshots only
	// and is never persisted with the workspace record.
	MergeState MergeState `json:"mergeState,omitempty"`
}

// MergeState describes whether a worktree branch still carries changes that
// are not present on the project's default branch. The zero value means "not
// applicable or not yet known"; clients only render the merged state.
type MergeState string

const (
	MergeStateMerged   MergeState = "merged"
	MergeStateUnmerged MergeState = "unmerged"
)

// WorkspaceCreateResult reports a created workspace together with side effects
// the caller needs to know: whether the Warren record was created and whether
// a Git worktree was actually created on disk.
type WorkspaceCreateResult struct {
	Workspace
	Created     bool `json:"created"`
	GitWorktree bool `json:"gitWorktree"`
}

type TerminalGroup struct {
	ID        string    `json:"id"`
	Name      string    `json:"name"`
	Home      string    `json:"home,omitempty"`
	Order     int       `json:"order,omitempty"`
	CreatedAt time.Time `json:"createdAt"`
}

const (
	SessionScopeWorkspace     = "workspace"
	SessionScopeTerminalGroup = "terminalGroup"
)

type Session struct {
	ID          string `json:"id"`
	WorkspaceID string `json:"workspace,omitempty"`
	// TerminalGroupID is set for standalone shell Sessions. WorkspaceID and
	// TerminalGroupID are mutually exclusive ownership fields.
	TerminalGroupID string `json:"terminalGroup,omitempty"`
	// Scope is explicit for new clients and derived from the ownership fields
	// for legacy records that predate Terminal Groups.
	Scope string `json:"scope,omitempty"`
	// Title is the generated default label (kind or command name) fixed at
	// session creation; it never changes after a user renames the session.
	Title string `json:"title"`
	// CustomTitle is the user-set display name. When non-empty it takes
	// precedence over Title in every client that renders a session name.
	CustomTitle string `json:"customTitle,omitempty"`
	Kind        string `json:"kind"`
	// AgentHandler selects the transport implementation inside an agent
	// family (for example tui or acp). It is optional so legacy Sessions keep
	// the provider's default handler.
	AgentHandler string `json:"agentHandler,omitempty"`
	Command      string `json:"command,omitempty"`
	// Process and Directory are live runtime metadata overlaid on roster
	// snapshots only; they are never persisted with the session record.
	Process     string `json:"process,omitempty"`
	Directory   string `json:"directory,omitempty"`
	Runtime     string `json:"runtime"`
	RuntimeKind string `json:"runtimeKind,omitempty"`
	Lifecycle   string `json:"lifecycle"`
	Epoch       uint64 `json:"epoch,omitempty"`
	Sequence    uint64 `json:"sequence,omitempty"`
	// OutputCursor is the opaque Ghostline v1 position immediately after the
	// output durably reflected by Epoch and Sequence. It is never exposed to
	// terminal clients and must not be synthesized from a byte offset.
	OutputCursor string `json:"outputCursor,omitempty"`
	Pinned       bool   `json:"pinned,omitempty"`
	// AgentSessionID is the provider's own conversation ID (Codex thread ID,
	// Claude session ID, or OpenCode SQLite session ID) bound to this Warren
	// session.
	AgentSessionID string `json:"agentSessionId,omitempty"`
	// TranscriptPath is the JSONL transcript projected by the agent watcher.
	TranscriptPath string `json:"transcriptPath,omitempty"`
	// AgentStatus is the live activity and human-attention projection of an
	// agent session. It is overlaid on roster snapshots only and is never
	// persisted with the session record.
	AgentStatus *AgentStatus `json:"agentStatus,omitempty"`
	// AgentTurn is the latest explicit lifecycle boundary for an agent. Like
	// AgentStatus, it is overlaid on roster snapshots only so clients can
	// distinguish a completed turn from an initially-ready agent.
	AgentTurn *AgentTurn `json:"agentTurn,omitempty"`
	// AgentCapabilities is the effective capability set for this Session,
	// after provider and transport negotiation. It is live projection data and
	// is never persisted in the durable Session record. An explicit empty array
	// means this agent is known but currently exposes no optional controls.
	AgentCapabilities []string   `json:"agentCapabilities"`
	CreatedAt         time.Time  `json:"createdAt"`
	EndedAt           *time.Time `json:"endedAt,omitempty"`
	// OperationID is returned by mutating session APIs for audit and safe
	// undo. It is intentionally not persisted in the session record.
	OperationID string `json:"operationId,omitempty"`
}

func (session Session) ScopeKind() string {
	if session.Scope != "" {
		return session.Scope
	}
	if session.TerminalGroupID != "" {
		return SessionScopeTerminalGroup
	}
	return SessionScopeWorkspace
}

// AgentActivity is the lifecycle state of an agent conversation. Human
// attention is represented separately by AgentStatus.Attention.
type AgentActivity string

const (
	AgentActivityReady   AgentActivity = "ready"
	AgentActivityWorking AgentActivity = "working"
	AgentActivityBlocked AgentActivity = "blocked"
	AgentActivityStalled AgentActivity = "stalled"
	AgentActivityFailed  AgentActivity = "failed"
	AgentActivityExited  AgentActivity = "exited"
)

// AgentAttentionKind identifies why a person should inspect an agent
// session. A warning is intentionally less certain than an input or approval
// request; it describes an abnormal condition such as a stalled turn.
type AgentAttentionKind string

const (
	AgentAttentionInput    AgentAttentionKind = "input"
	AgentAttentionApproval AgentAttentionKind = "approval"
	AgentAttentionWarning  AgentAttentionKind = "warning"
)

// AgentAttention is bounded, provider-neutral metadata. It must never carry
// transcript content, prompt text, command arguments, or secrets.
type AgentAttention struct {
	Kind      AgentAttentionKind `json:"kind"`
	Reason    string             `json:"reason"`
	RequestID string             `json:"requestId,omitempty"`
	Since     time.Time          `json:"since"`
}

// AgentStatus is the complete live projection sent to clients. Attention is
// nil when the session has no outstanding human-facing condition.
type AgentStatus struct {
	Activity  AgentActivity   `json:"activity"`
	Attention *AgentAttention `json:"attention"`
}

// Equal compares the complete status value, including attention metadata.
// Attention is a pointer so callers can mutate their own copy without
// changing the tracker; pointer identity must therefore never participate in
// status-change detection.
func (s AgentStatus) Equal(other AgentStatus) bool {
	if s.Activity != other.Activity {
		return false
	}
	if s.Attention == nil || other.Attention == nil {
		return s.Attention == nil && other.Attention == nil
	}
	return s.Attention.Kind == other.Attention.Kind &&
		s.Attention.Reason == other.Attention.Reason &&
		s.Attention.RequestID == other.Attention.RequestID &&
		s.Attention.Since.Equal(other.Attention.Since)
}

// AgentEvent is one normalized message or tool transition from a Codex,
// Claude, or OpenCode transcript. It is a projection of the provider's own log;
// the terminal byte stream remains the source of truth for rendering.
type AgentEvent struct {
	Sequence uint64 `json:"seq"`
	Turn     uint64 `json:"turn,omitempty"`
	ID       string `json:"id,omitempty"`
	Provider string `json:"provider"`
	Type     string `json:"type"`
	Role     string `json:"role,omitempty"`
	Content  string `json:"content,omitempty"`
	// ContentDelta marks content as an append-only delta to the previous event
	// with the same provider, type, and ID. It is used by providers such as
	// OpenCode whose mutable parts are projected into the append-only event
	// stream.
	ContentDelta bool        `json:"contentDelta,omitempty"`
	Model        string      `json:"model,omitempty"`
	StopReason   string      `json:"stopReason,omitempty"`
	ToolName     string      `json:"toolName,omitempty"`
	ToolInput    any         `json:"toolInput,omitempty"`
	ToolStatus   string      `json:"toolStatus,omitempty"`
	CallID       string      `json:"callId,omitempty"`
	Output       string      `json:"output,omitempty"`
	Files        []string    `json:"files,omitempty"`
	Error        string      `json:"error,omitempty"`
	Usage        *AgentUsage `json:"usage,omitempty"`
	DurationMs   int64       `json:"durationMs,omitempty"`
	Sidechain    bool        `json:"sidechain,omitempty"`
	Timestamp    time.Time   `json:"timestamp,omitempty"`
	// Payload carries the optional structured object used by RFC 0010
	// interaction, plan, activity, plugin, subagent and attachment events.
	// A map keeps old clients source-compatible while unknown fields remain
	// safely ignored by decoders that do not render the event type.
	Payload map[string]any `json:"payload,omitempty"`
}

// AgentTurnStatus describes one explicit turn boundary in an agent transcript.
// Idle is only used by snapshots before the first observed turn.
type AgentTurnStatus string

const (
	AgentTurnIdle      AgentTurnStatus = "idle"
	AgentTurnStarted   AgentTurnStatus = "started"
	AgentTurnCompleted AgentTurnStatus = "completed"
	AgentTurnFailed    AgentTurnStatus = "failed"
	AgentTurnAborted   AgentTurnStatus = "aborted"
)

// AgentTurn is a monotonically numbered lifecycle transition within one
// agent epoch. The number resets when the transcript projection is replaced.
type AgentTurn struct {
	ID     uint64          `json:"id"`
	Status AgentTurnStatus `json:"status"`
}

// AgentUsage mirrors the token accounting both CLIs attach to their own
// transcript lines.
type AgentUsage struct {
	InputTokens              int64 `json:"inputTokens,omitempty"`
	CacheCreationInputTokens int64 `json:"cacheCreationInputTokens,omitempty"`
	CacheReadInputTokens     int64 `json:"cacheReadInputTokens,omitempty"`
	OutputTokens             int64 `json:"outputTokens,omitempty"`
	ReasoningOutputTokens    int64 `json:"reasoningOutputTokens,omitempty"`
	TotalTokens              int64 `json:"totalTokens,omitempty"`
}

// AgentMessage carries a live batch of normalized agent events for one
// session. Batches are bounded so a single WebSocket message stays well
// below client message-size limits; full history is fetched separately via
// the agent.history request.
type AgentMessage struct {
	Type    string `json:"t"`
	Session string `json:"session"`
	// Epoch identifies one Host process's agent projection. Clients reset
	// their event history when the epoch changes after a daemon restart.
	Epoch  uint64       `json:"epoch,omitempty"`
	Events []AgentEvent `json:"events"`
}

// AgentStatusMessage is the lightweight live status update for one session.
// It is deliberately a small standalone message so clients that only render
// the status light never have to receive full event batches.
type AgentStatusMessage struct {
	Type    string      `json:"t"`
	Session string      `json:"session"`
	Epoch   uint64      `json:"epoch,omitempty"`
	Status  AgentStatus `json:"status"`
}

// AgentTurnMessage carries explicit turn boundaries for blocking clients.
// Activity remains presentation state; callers must use this message instead
// of treating the ambiguous ready state as proof that a new turn completed.
type AgentTurnMessage struct {
	Type    string          `json:"t"`
	Session string          `json:"session"`
	Epoch   uint64          `json:"epoch,omitempty"`
	Turn    uint64          `json:"turn"`
	Status  AgentTurnStatus `json:"status"`
}

// AgentSnapshotResult is the subscription baseline used before a caller sends
// input or starts waiting. Event sequence is included for diagnostics.
type AgentSnapshotResult struct {
	Epoch    uint64    `json:"epoch"`
	Turn     AgentTurn `json:"turn"`
	Sequence uint64    `json:"sequence"`
}

// AgentSubscriptionResult binds a read-only subscriber to a session and
// returns the turn baseline established before live boundaries can interleave.
type AgentSubscriptionResult struct {
	Session   Session             `json:"session"`
	Snapshot  AgentSnapshotResult `json:"snapshot"`
	GapEvents []AgentEvent        `json:"gapEvents,omitempty"`
}

// AgentWaitResult is printed by the blocking CLI once a turn reaches a
// terminal state.
type AgentWaitResult struct {
	Session string          `json:"session"`
	Epoch   uint64          `json:"epoch"`
	Turn    uint64          `json:"turn"`
	Status  AgentTurnStatus `json:"status"`
	Events  []AgentEvent    `json:"events"`
}

// AgentHistoryResult is one page of the agent event history. Cursor is the
// sequence of the first event in the page and can be passed back as `before`
// to load the previous page; HasMore reports whether older events exist.
type AgentHistoryResult struct {
	Epoch   uint64       `json:"epoch,omitempty"`
	Events  []AgentEvent `json:"events"`
	Cursor  uint64       `json:"cursor,omitempty"`
	HasMore bool         `json:"hasMore"`
}

// AgentTranscriptChunk is one bounded raw JSONL segment from the transcript
// bound to a Warren Agent session. Paths are intentionally not exposed: the
// Host resolves the binding from the session ID before every read.
type AgentTranscriptChunk struct {
	Data string `json:"data"`
	Next int64  `json:"next"`
	EOF  bool   `json:"eof"`
}

type State struct {
	Schema int `json:"schema"`
	// Revision is a transient, non-zero roster token used by streaming clients
	// to validate deltas. It is populated only in observer snapshots and is
	// never written into the durable state file.
	Revision       uint64          `json:"revision,omitempty"`
	Host           Host            `json:"host"`
	Tasks          []Task          `json:"tasks"`
	Projects       []Project       `json:"projects"`
	Workspaces     []Workspace     `json:"workspaces"`
	TerminalGroups []TerminalGroup `json:"terminalGroups"`
	Sessions       []Session       `json:"sessions"`
	// GhostlineMigration is the one in-flight (or most recently completed)
	// ownership journal. It is separate from terminal Sessions because
	// Ghostline transfers the complete PTY batch atomically while Warren owns
	// only the route and process lifecycle around that transfer.
	GhostlineMigration *GhostlineMigration `json:"ghostlineMigration,omitempty"`
	// Operations is the bounded mutation audit trail. Entries are only added
	// for operations that have a safe, compare-and-swap undo representation.
	Operations []OperationAudit `json:"operations,omitempty"`
	// WorktreeOwnershipMigrated records that legacy workspace ownership has
	// been reconciled against the configured Warren worktree root.
	WorktreeOwnershipMigrated bool   `json:"worktreeOwnershipMigrated,omitempty"`
	WarrenVersion             string `json:"warrenVersion,omitempty"`
}

const (
	GhostlineMigrationPreparing = "preparing"
	GhostlineMigrationPrepared  = "prepared"
	GhostlineMigrationCommitted = "committed"
	GhostlineMigrationRouted    = "routed"
	GhostlineMigrationRetired   = "retired"
)

// GhostlineMigration records one rolling handoff. SessionID identifies this
// migration transaction, not a terminal session. Socket paths are local-only
// control-plane data; clients always attach through Warren's current route.
type GhostlineMigration struct {
	SessionID       string            `json:"sessionId"`
	SourceSocket    string            `json:"sourceSocket"`
	TargetSocket    string            `json:"targetSocket"`
	SourceProtocol  string            `json:"sourceProtocol"`
	HandoffVersion  string            `json:"handoffVersion,omitempty"`
	Phase           string            `json:"phase"`
	SkippedSessions []string          `json:"skippedSessions,omitempty"`
	SkipReasons     map[string]string `json:"skipReasons,omitempty"`
	CreatedAt       time.Time         `json:"createdAt"`
	UpdatedAt       time.Time         `json:"updatedAt"`
}

// OperationAudit records a reversible session move (or its reversal). The
// before/after ownership fields are compared during undo so an unrelated
// change can never be silently overwritten.
type OperationAudit struct {
	ID                    string     `json:"id"`
	Kind                  string     `json:"kind"`
	Resource              string     `json:"resource"`
	ResourceID            string     `json:"resourceId"`
	BeforeWorkspaceID     string     `json:"beforeWorkspace,omitempty"`
	BeforeTerminalGroupID string     `json:"beforeTerminalGroup,omitempty"`
	AfterWorkspaceID      string     `json:"afterWorkspace,omitempty"`
	AfterTerminalGroupID  string     `json:"afterTerminalGroup,omitempty"`
	AgentSessionID        string     `json:"agentSessionId,omitempty"`
	RevertsOperationID    string     `json:"revertsOperationId,omitempty"`
	CreatedAt             time.Time  `json:"createdAt"`
	RevertedAt            *time.Time `json:"revertedAt,omitempty"`
}

// SessionMovePreflight describes the exact source and destination checked by
// the Host before a move. It contains IDs and context only, never transcript
// contents.
type SessionMovePreflight struct {
	Allowed                    bool    `json:"allowed"`
	Session                    Session `json:"session"`
	SourceWorkspaceID          string  `json:"sourceWorkspace,omitempty"`
	SourceTerminalGroupID      string  `json:"sourceTerminalGroup,omitempty"`
	DestinationWorkspaceID     string  `json:"destinationWorkspace,omitempty"`
	DestinationTerminalGroupID string  `json:"destinationTerminalGroup,omitempty"`
	ExpectedWorkspaceID        string  `json:"expectedWorkspace,omitempty"`
	ExpectedAgentSessionID     string  `json:"expectedAgentSessionId,omitempty"`
}

type Envelope struct {
	Type         string   `json:"t"`
	ID           string   `json:"id,omitempty"`
	Token        string   `json:"token,omitempty"`
	Version      string   `json:"version,omitempty"`
	Capabilities []string `json:"capabilities,omitempty"`
	// TerminalStateFormats lists opaque terminal-state encodings the client
	// can install atomically. Protocol 2 requires at least one format shared
	// with the Host; protocol 1 clients are rejected during authentication.
	TerminalStateFormats []string       `json:"terminalStateFormats,omitempty"`
	Method               string         `json:"method,omitempty"`
	Params               map[string]any `json:"params,omitempty"`
	Session              string         `json:"session,omitempty"`
	Workspace            string         `json:"workspace,omitempty"`
	Project              string         `json:"project,omitempty"`
	Command              string         `json:"command,omitempty"`
	Kind                 string         `json:"kind,omitempty"`
	Title                string         `json:"title,omitempty"`
	Data                 string         `json:"data,omitempty"`
	Cols                 int            `json:"cols,omitempty"`
	Rows                 int            `json:"rows,omitempty"`
	Epoch                uint64         `json:"epoch,omitempty"`
	Sequence             uint64         `json:"sequence,omitempty"`
}

type Response struct {
	Type   string `json:"t"`
	ID     string `json:"id,omitempty"`
	OK     bool   `json:"ok"`
	Result any    `json:"result,omitempty"`
	Error  string `json:"error,omitempty"`
}

// GitPanel is the aggregated Git projection for one workspace.
type GitPanel struct {
	WorkspaceID      string          `json:"workspace"`
	Branch           string          `json:"branch"`
	Upstream         string          `json:"upstream,omitempty"`
	Ahead            int             `json:"ahead,omitempty"`
	Behind           int             `json:"behind,omitempty"`
	AheadOfMain      int             `json:"aheadOfMain,omitempty"`
	Remote           string          `json:"remote,omitempty"`
	MainBranch       string          `json:"mainBranch,omitempty"`
	Merged           bool            `json:"merged,omitempty"`
	Operation        string          `json:"operation,omitempty"`
	Changes          []GitChange     `json:"changes"`
	Commits          []GitCommit     `json:"commits"`
	UnmergedCommits  []GitCommit     `json:"unmergedCommits,omitempty"`
	Branches         []GitBranch     `json:"branches"`
	PullRequest      *GitPullRequest `json:"pullRequest,omitempty"`
	PullRequestError string          `json:"pullRequestError,omitempty"`
	Refreshing       bool            `json:"refreshing,omitempty"`
}

type GitChange struct {
	Path       string `json:"path"`
	Status     string `json:"status"`
	Staged     bool   `json:"staged,omitempty"`
	RenameFrom string `json:"renameFrom,omitempty"`
	Added      int    `json:"added,omitempty"`
	Deleted    int    `json:"deleted,omitempty"`
}

type GitCommit struct {
	Hash    string      `json:"hash"`
	Short   string      `json:"short"`
	Subject string      `json:"subject"`
	Author  string      `json:"author"`
	Email   string      `json:"email,omitempty"`
	Time    time.Time   `json:"time"`
	Files   []GitChange `json:"files"`
}

type GitBranch struct {
	Name   string `json:"name"`
	Remote bool   `json:"remote"`
}

// GitPullRequest is a hosted pull request (GitHub PR or GitLab MR) for the
// workspace's current branch.
type GitPullRequest struct {
	Number int    `json:"number,omitempty"`
	Title  string `json:"title"`
	Body   string `json:"body,omitempty"`
	State  string `json:"state,omitempty"`
	Draft  bool   `json:"draft,omitempty"`
	URL    string `json:"url,omitempty"`
	Author string `json:"author,omitempty"`
	Base   string `json:"base,omitempty"`
	Head   string `json:"head,omitempty"`
}

type GitCommandResult struct {
	Message string `json:"message"`
}

type GitDiff struct {
	Diff             string `json:"diff"`
	Content          string `json:"content"`
	DiffTruncated    bool   `json:"diffTruncated,omitempty"`
	ContentTruncated bool   `json:"contentTruncated,omitempty"`
}

// PublicAccessStatus is the credential-free projection of the Relay-owned
// public route. The Host Secret and any Relay access capability are never
// included in this type.
type PublicAccessStatus struct {
	RelayURL       string `json:"relayUrl,omitempty"`
	HostID         string `json:"hostId,omitempty"`
	RouteID        string `json:"routeId,omitempty"`
	PublicHostname string `json:"publicHostname,omitempty"`
	PathPrefix     string `json:"pathPrefix,omitempty"`
	AuthMode       string `json:"authMode,omitempty"`
	Enabled        bool   `json:"enabled"`
	Authenticated  bool   `json:"authenticated"`
	Running        bool   `json:"running"`
	PublicEndpoint string `json:"publicEndpoint,omitempty"`
	Error          string `json:"error,omitempty"`
}

// PublicAccessEnableRequest configures the Relay-owned public route. Relay
// allocates a safe hostname and path when both values are omitted.
type PublicAccessEnableRequest struct {
	PublicHostname *string `json:"publicHostname,omitempty"`
	PathPrefix     *string `json:"pathPrefix,omitempty"`
}

// PublicAccessTestRequest validates Relay connectivity and route metadata
// without enabling the public route.
type PublicAccessTestRequest struct {
	PublicHostname *string `json:"publicHostname,omitempty"`
	PathPrefix     *string `json:"pathPrefix,omitempty"`
}
