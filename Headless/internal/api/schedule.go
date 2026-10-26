package api

import "time"

// Schedule kinds of action.
const (
	// ScheduleActionAgent starts one Agent turn, like `warren agent send`.
	ScheduleActionAgent = "agent"
	// ScheduleActionNewAgent creates a new Agent in a Workspace with the
	// prompt as its first turn, like `warren agent create --prompt`.
	ScheduleActionNewAgent = "new-agent"
	// ScheduleActionCommand runs one shell command as a new Session in a
	// Workspace, like `warren session create` whose process is the command.
	ScheduleActionCommand = "command"
)

// What an agent action does when its Agent is mid-turn, and what a
// new-agent action does while the Agent of its previous run is.
const (
	// ScheduleWhenBusyWait holds the prompt and delivers it once the current
	// turn ends.
	ScheduleWhenBusyWait = "wait"
	// ScheduleWhenBusySkip records the run as skipped.
	ScheduleWhenBusySkip = "skip"
)

// Schedule states.
const (
	ScheduleStateActive = "active"
	ScheduleStatePaused = "paused"
	// ScheduleStateCompleted means no further run is due: a one-shot ran, the
	// run limit was reached, or the next occurrence falls after Until.
	ScheduleStateCompleted = "completed"
)

// Schedule run statuses.
const (
	// ScheduleRunWaiting means the Agent was mid-turn and the prompt is held.
	ScheduleRunWaiting = "waiting"
	// ScheduleRunRunning means the command Session is still executing, or a
	// new Agent's first turn has not ended.
	ScheduleRunRunning   = "running"
	ScheduleRunSucceeded = "succeeded"
	ScheduleRunFailed    = "failed"
	ScheduleRunSkipped   = "skipped"
)

// Schedule run triggers.
const (
	ScheduleTriggerSchedule = "schedule"
	ScheduleTriggerManual   = "manual"
)

// Schedule is a Host-owned timer that performs one action on a cron
// expression or at one instant. Times are evaluated in the Host's local time
// zone.
type Schedule struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	// Cron is a five-field expression; empty for a one-shot.
	Cron string `json:"cron,omitempty"`
	// At is the instant of a one-shot; nil for a repeating schedule.
	At *time.Time `json:"at,omitempty"`
	// Until bounds a repeating schedule: no occurrence after it runs.
	Until *time.Time `json:"until,omitempty"`
	// MaxRuns bounds the scheduled runs; zero is unbounded. Manual runs do
	// not count.
	MaxRuns  int            `json:"maxRuns,omitempty"`
	TimeZone string         `json:"timeZone"`
	Action   ScheduleAction `json:"action"`
	State    string         `json:"state"`
	// EndReason says why a completed schedule stopped.
	EndReason string       `json:"endReason,omitempty"`
	NextRunAt *time.Time   `json:"nextRunAt,omitempty"`
	RunCount  int          `json:"runCount"`
	LastRun   *ScheduleRun `json:"lastRun,omitempty"`
	CreatedAt time.Time    `json:"createdAt"`
	UpdatedAt time.Time    `json:"updatedAt"`
}

// ScheduleAction is the work one run performs.
type ScheduleAction struct {
	Kind string `json:"kind"`
	// Agent is the Warren Session ID of the target Agent.
	Agent string `json:"agent,omitempty"`
	// Prompt is literal prompt text. PromptFile is a Host path read at each
	// run, so editing the file changes later runs. Exactly one is set for an
	// agent action.
	Prompt     string `json:"prompt,omitempty"`
	PromptFile string `json:"promptFile,omitempty"`
	WhenBusy   string `json:"whenBusy,omitempty"`
	// BusyTimeout bounds how long a waiting prompt is held, as a Go duration.
	// Empty holds it until the turn ends, the Agent ends, or the next
	// occurrence supersedes it.
	BusyTimeout string `json:"busyTimeout,omitempty"`
	// Workspace is where a command runs or a new Agent is created.
	Workspace string `json:"workspace,omitempty"`
	// Command is the shell command of a command action, or the provider
	// executable and options of a new-agent action.
	Command string `json:"command,omitempty"`
	// Provider is the Agent provider of a new-agent action.
	Provider string `json:"provider,omitempty"`
	// Keep, for a new-agent action, removes the Agents of older runs beyond
	// the newest Keep once a run's first turn ends. Zero keeps every Agent.
	Keep int `json:"keep,omitempty"`
}

// ScheduleRun records one execution of a Schedule's action.
type ScheduleRun struct {
	ID         string `json:"id"`
	ScheduleID string `json:"scheduleId"`
	Trigger    string `json:"trigger"`
	// ScheduledAt is the occurrence this run serves; a run that started late,
	// after the Host was down or asleep, keeps the occurrence it was due.
	ScheduledAt time.Time  `json:"scheduledAt"`
	StartedAt   time.Time  `json:"startedAt"`
	DeliveredAt *time.Time `json:"deliveredAt,omitempty"`
	FinishedAt  *time.Time `json:"finishedAt,omitempty"`
	Status      string     `json:"status"`
	Error       string     `json:"error,omitempty"`
	// Session is the Agent that received the prompt, the Agent a new-agent
	// run created, or the Session a command ran in.
	Session  string `json:"session,omitempty"`
	ExitCode *int   `json:"exitCode,omitempty"`
}

// ScheduleCreateRequest is the schedule.create parameter object. Times are
// strings so the Host, whose time zone governs the schedule, parses them.
type ScheduleCreateRequest struct {
	Name        string `json:"name"`
	Cron        string `json:"cron,omitempty"`
	At          string `json:"at,omitempty"`
	Until       string `json:"until,omitempty"`
	MaxRuns     int    `json:"maxRuns,omitempty"`
	Agent       string `json:"agent,omitempty"`
	Prompt      string `json:"prompt,omitempty"`
	PromptFile  string `json:"promptFile,omitempty"`
	WhenBusy    string `json:"whenBusy,omitempty"`
	BusyTimeout string `json:"busyTimeout,omitempty"`
	Workspace   string `json:"workspace,omitempty"`
	Command     string `json:"command,omitempty"`
	Provider    string `json:"provider,omitempty"`
	Keep        int    `json:"keep,omitempty"`
}
