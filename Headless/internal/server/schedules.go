package server

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/agent"
	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/schedule"
	"github.com/abcdlsj/warren/Headless/internal/store"
)

const (
	// scheduleTickInterval bounds how long the loop sleeps between checks.
	// The loop compares wall-clock times on every wake rather than trusting
	// one long timer, because a monotonic timer does not advance while the
	// machine sleeps.
	scheduleTickInterval = 15 * time.Second
	// scheduleBusyPollInterval is how often a held prompt rechecks its Agent.
	scheduleBusyPollInterval = 2 * time.Second
	// scheduleAgentReadyTimeout bounds how long a run waits for an Agent that
	// has no execution yet, matching what `agent send` tolerates at startup.
	scheduleAgentReadyTimeout = 2 * time.Minute
	// scheduleRunRetention is how many finished runs each schedule keeps.
	scheduleRunRetention = 50
	scheduleFileVersion  = 1
)

// scheduleFile is the durable form of every Schedule and its run history. It
// lives beside state.json rather than in it: schedules are Host automation,
// not roster state, and keeping them out of the roster keeps every client's
// snapshot and delta protocol unchanged.
type scheduleFile struct {
	Version   int               `json:"version"`
	Schedules []api.Schedule    `json:"schedules"`
	Runs      []api.ScheduleRun `json:"runs"`
}

type scheduleBook struct {
	mu      sync.Mutex
	path    string
	data    scheduleFile
	loadErr error
	wake    chan struct{}
}

func (s *Service) scheduleBook() (*scheduleBook, error) {
	s.schedulesOnce.Do(func() {
		book := &scheduleBook{path: strings.TrimSpace(s.SchedulePath), wake: make(chan struct{}, 1)}
		book.data.Version = scheduleFileVersion
		if book.path == "" {
			book.loadErr = errors.New("schedules are unavailable on this Host")
		} else if data, err := os.ReadFile(book.path); err == nil {
			if err := json.Unmarshal(data, &book.data); err != nil {
				book.loadErr = fmt.Errorf("decode %s: %w", book.path, err)
			}
		} else if !errors.Is(err, os.ErrNotExist) {
			book.loadErr = fmt.Errorf("read %s: %w", book.path, err)
		}
		s.schedules = book
	})
	return s.schedules, s.schedules.loadErr
}

// saveLocked persists the book. Callers hold book.mu.
func (book *scheduleBook) saveLocked() error {
	if err := os.MkdirAll(filepath.Dir(book.path), 0o700); err != nil {
		return fmt.Errorf("create schedule directory: %w", err)
	}
	data, err := json.MarshalIndent(book.data, "", "  ")
	if err != nil {
		return err
	}
	temporary := book.path + ".tmp"
	if err := os.WriteFile(temporary, append(data, '\n'), 0o600); err != nil {
		return fmt.Errorf("write schedules: %w", err)
	}
	if err := os.Rename(temporary, book.path); err != nil {
		return fmt.Errorf("commit schedules: %w", err)
	}
	return nil
}

// errScheduleUnchanged lets an update callback report that it changed
// nothing, so the file is not rewritten.
var errScheduleUnchanged = errors.New("schedules unchanged")

// update applies fn to a copy and publishes it only after it is durable, so a
// failed write leaves the book as it was.
func (book *scheduleBook) update(fn func(*scheduleFile) error) error {
	book.mu.Lock()
	defer book.mu.Unlock()
	previous := cloneScheduleFile(book.data)
	if err := fn(&book.data); err != nil {
		book.data = previous
		if errors.Is(err, errScheduleUnchanged) {
			return nil
		}
		return err
	}
	if err := book.saveLocked(); err != nil {
		book.data = previous
		return err
	}
	return nil
}

func (book *scheduleBook) snapshot() scheduleFile {
	book.mu.Lock()
	defer book.mu.Unlock()
	return cloneScheduleFile(book.data)
}

func (book *scheduleBook) signal() {
	select {
	case book.wake <- struct{}{}:
	default:
	}
}

func cloneScheduleFile(value scheduleFile) scheduleFile {
	value.Schedules = slices.Clone(value.Schedules)
	value.Runs = slices.Clone(value.Runs)
	return value
}

func (s *Service) scheduleNow() time.Time {
	if s.scheduleClock != nil {
		return s.scheduleClock()
	}
	return time.Now()
}

func (s *Service) scheduleLocation() *time.Location {
	if s.scheduleTimeZone != nil {
		return s.scheduleTimeZone
	}
	return time.Local
}

func (s *Service) schedulePollInterval() time.Duration {
	if s.scheduleBusyPoll > 0 {
		return s.scheduleBusyPoll
	}
	return scheduleBusyPollInterval
}

// nextScheduleOccurrence returns the next due time strictly after `after`,
// or nil and the reason the schedule has none.
func nextScheduleOccurrence(value api.Schedule, after time.Time, location *time.Location) (*time.Time, string) {
	if value.At != nil {
		if value.RunCount > 0 {
			return nil, "ran once"
		}
		at := *value.At
		return &at, ""
	}
	if value.MaxRuns > 0 && value.RunCount >= value.MaxRuns {
		return nil, fmt.Sprintf("reached %d runs", value.MaxRuns)
	}
	cron, err := schedule.ParseCron(value.Cron)
	if err != nil {
		return nil, err.Error()
	}
	next := cron.Next(after.In(location))
	if next.IsZero() {
		return nil, "the cron expression has no further occurrence"
	}
	if value.Until != nil && next.After(*value.Until) {
		return nil, "reached " + value.Until.In(location).Format("2006-01-02 15:04")
	}
	next = next.UTC()
	return &next, ""
}

// CreateSchedule validates and stores a schedule.
func (s *Service) CreateSchedule(request api.ScheduleCreateRequest) (api.Schedule, error) {
	book, err := s.scheduleBook()
	if err != nil {
		return api.Schedule{}, err
	}
	now := s.scheduleNow()
	location := s.scheduleLocation()
	value := api.Schedule{
		ID:        store.NewID(),
		Name:      strings.TrimSpace(request.Name),
		Cron:      strings.TrimSpace(request.Cron),
		MaxRuns:   request.MaxRuns,
		TimeZone:  location.String(),
		State:     api.ScheduleStateActive,
		CreatedAt: now.UTC(),
		UpdatedAt: now.UTC(),
	}
	at := strings.TrimSpace(request.At)
	until := strings.TrimSpace(request.Until)
	switch {
	case value.Cron == "" && at == "":
		return api.Schedule{}, errors.New("a schedule needs --cron EXPRESSION or --at TIME")
	case value.Cron != "" && at != "":
		return api.Schedule{}, errors.New("--cron and --at are mutually exclusive")
	case value.Cron != "":
		if _, err := schedule.ParseCron(value.Cron); err != nil {
			return api.Schedule{}, err
		}
	default:
		instant, err := schedule.ParseInstant(at, location, false)
		if err != nil {
			return api.Schedule{}, fmt.Errorf("--at: %w", err)
		}
		if !instant.After(now) {
			return api.Schedule{}, fmt.Errorf("--at %s is in the past", at)
		}
		instant = instant.UTC()
		value.At = &instant
	}
	if value.MaxRuns < 0 {
		return api.Schedule{}, errors.New("--max-runs must not be negative")
	}
	if value.At != nil && (until != "" || value.MaxRuns > 0) {
		return api.Schedule{}, errors.New("--until and --max-runs apply only to --cron schedules")
	}
	if until != "" {
		instant, err := schedule.ParseInstant(until, location, true)
		if err != nil {
			return api.Schedule{}, fmt.Errorf("--until: %w", err)
		}
		if !instant.After(now) {
			return api.Schedule{}, fmt.Errorf("--until %s is in the past", until)
		}
		instant = instant.UTC()
		value.Until = &instant
	}
	action, err := s.scheduleAction(request)
	if err != nil {
		return api.Schedule{}, err
	}
	value.Action = action
	if value.Name == "" {
		value.Name = defaultScheduleName(action)
	}
	next, reason := nextScheduleOccurrence(value, now, location)
	if next == nil {
		return api.Schedule{}, fmt.Errorf("the schedule would never run: %s", reason)
	}
	value.NextRunAt = next
	if err := book.update(func(data *scheduleFile) error {
		data.Schedules = append(data.Schedules, value)
		return nil
	}); err != nil {
		return api.Schedule{}, err
	}
	book.signal()
	return value, nil
}

func (s *Service) scheduleAction(request api.ScheduleCreateRequest) (api.ScheduleAction, error) {
	agentID := strings.TrimSpace(request.Agent)
	workspaceID := strings.TrimSpace(request.Workspace)
	command := strings.TrimSpace(request.Command)
	provider := strings.ToLower(strings.TrimSpace(request.Provider))
	if request.Keep != 0 && provider == "" {
		return api.ScheduleAction{}, errors.New("--keep applies only to --provider actions")
	}
	switch {
	case agentID != "" && (workspaceID != "" || command != "" || provider != ""):
		return api.ScheduleAction{}, errors.New("--agent cannot be combined with --workspace, --command, or --provider")
	case agentID != "":
		session, ok := s.sessionInAnyLifecycle(agentID)
		if !ok {
			return api.ScheduleAction{}, fmt.Errorf("agent not found: %s", agentID)
		}
		if session.Lifecycle != "running" {
			return api.ScheduleAction{}, fmt.Errorf("agent has ended: %s", agentID)
		}
		if !scheduleSessionIsAgent(session) {
			return api.ScheduleAction{}, fmt.Errorf("session is not an Agent: %s", agentID)
		}
		return schedulePromptAction(api.ScheduleAction{Kind: api.ScheduleActionAgent, Agent: agentID}, request)
	case provider != "":
		if workspaceID == "" {
			return api.ScheduleAction{}, errors.New("a --provider action needs --workspace WORKSPACE_ID")
		}
		if !scheduleProviders[provider] {
			return api.ScheduleAction{}, fmt.Errorf("--provider must be codex, claude, opencode, pi, qoder, or antigravity, not %q", request.Provider)
		}
		if _, err := sessionWorkingDirectory(s.Store.Snapshot(), workspaceID); err != nil {
			return api.ScheduleAction{}, err
		}
		if request.Keep < 0 {
			return api.ScheduleAction{}, errors.New("--keep must not be negative")
		}
		if command == "" {
			command = provider
			if provider == "antigravity" {
				command = "agy"
			}
		}
		return schedulePromptAction(api.ScheduleAction{
			Kind: api.ScheduleActionNewAgent, Workspace: workspaceID, Provider: provider, Command: command, Keep: request.Keep,
		}, request)
	case workspaceID != "" || command != "":
		if workspaceID == "" || command == "" {
			return api.ScheduleAction{}, errors.New("a command action needs both --workspace WORKSPACE_ID and --command COMMAND")
		}
		if strings.TrimSpace(request.Prompt) != "" || strings.TrimSpace(request.PromptFile) != "" ||
			strings.TrimSpace(request.WhenBusy) != "" || strings.TrimSpace(request.BusyTimeout) != "" {
			return api.ScheduleAction{}, errors.New("prompt and busy options apply only to --agent and --provider actions")
		}
		if _, err := sessionWorkingDirectory(s.Store.Snapshot(), workspaceID); err != nil {
			return api.ScheduleAction{}, err
		}
		return api.ScheduleAction{Kind: api.ScheduleActionCommand, Workspace: workspaceID, Command: command}, nil
	default:
		return api.ScheduleAction{}, errors.New("a schedule needs --agent AGENT_ID, --workspace WORKSPACE_ID with --provider PROVIDER, or --workspace WORKSPACE_ID with --command COMMAND")
	}
}

// scheduleProviders are the providers a new-agent action can start; it uses
// the TUI handler, whose initial prompt is a launch argument.
var scheduleProviders = map[string]bool{
	"codex": true, "claude": true, "opencode": true, "pi": true, "qoder": true, "antigravity": true,
}

// schedulePromptAction fills the prompt and busy policy shared by the agent
// and new-agent actions.
func schedulePromptAction(action api.ScheduleAction, request api.ScheduleCreateRequest) (api.ScheduleAction, error) {
	prompt := strings.TrimSpace(request.Prompt)
	promptFile := strings.TrimSpace(request.PromptFile)
	switch {
	case prompt != "" && promptFile != "":
		return api.ScheduleAction{}, errors.New("--prompt and --prompt-file are mutually exclusive")
	case prompt != "":
		action.Prompt = prompt
	case promptFile != "":
		path, err := expandHostPath(promptFile)
		if err != nil {
			return api.ScheduleAction{}, err
		}
		if _, err := readSchedulePrompt(path); err != nil {
			return api.ScheduleAction{}, err
		}
		action.PromptFile = path
	default:
		return api.ScheduleAction{}, errors.New("an agent action needs --prompt TEXT, --prompt-file PATH, or a prompt on stdin")
	}
	action.WhenBusy = strings.ToLower(strings.TrimSpace(request.WhenBusy))
	if action.WhenBusy == "" {
		action.WhenBusy = api.ScheduleWhenBusyWait
	}
	if action.WhenBusy != api.ScheduleWhenBusyWait && action.WhenBusy != api.ScheduleWhenBusySkip {
		return api.ScheduleAction{}, fmt.Errorf("--when-busy must be wait or skip, not %q", request.WhenBusy)
	}
	if timeout := strings.TrimSpace(request.BusyTimeout); timeout != "" {
		if action.WhenBusy != api.ScheduleWhenBusyWait {
			return api.ScheduleAction{}, errors.New("--busy-timeout applies only to --when-busy wait")
		}
		duration, err := time.ParseDuration(timeout)
		if err != nil || duration <= 0 {
			return api.ScheduleAction{}, fmt.Errorf("--busy-timeout must be a positive duration such as 30m or 2h, not %q", timeout)
		}
		action.BusyTimeout = duration.String()
	}
	return action, nil
}

// sessionInAnyLifecycle finds a Session whether or not it has ended, so a
// run can tell an ended Agent from one that never existed.
func (s *Service) sessionInAnyLifecycle(id string) (api.Session, bool) {
	for _, session := range s.Store.Snapshot().Sessions {
		if session.ID == id {
			return session, true
		}
	}
	return api.Session{}, false
}

// scheduleSessionIsAgent mirrors the CLI's Agent test: a dedicated provider
// Session, or a shell overlay whose provider binding has been recorded.
func scheduleSessionIsAgent(session api.Session) bool {
	switch strings.ToLower(strings.TrimSpace(session.Kind)) {
	case "codex", "claude", "opencode", "pi", "qoder", "antigravity":
		return true
	case "shell", "custom":
		return session.AgentSessionID != ""
	default:
		return false
	}
}

// expandHostPath resolves a leading ~ against the Host user's home, because
// the prompt file is read by the Host, which may not be the CLI's machine.
func expandHostPath(path string) (string, error) {
	if path == "~" || strings.HasPrefix(path, "~/") {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", fmt.Errorf("resolve ~: %w", err)
		}
		path = filepath.Join(home, strings.TrimPrefix(path, "~"))
	}
	if !filepath.IsAbs(path) {
		return "", fmt.Errorf("--prompt-file must be an absolute path or start with ~/: %s", path)
	}
	return filepath.Clean(path), nil
}

func readSchedulePrompt(path string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("read prompt file: %w", err)
	}
	text := strings.TrimSpace(string(data))
	if text == "" {
		return "", fmt.Errorf("prompt file is empty: %s", path)
	}
	return text, nil
}

func defaultScheduleName(action api.ScheduleAction) string {
	switch action.Kind {
	case api.ScheduleActionAgent:
		return "agent " + shortID(action.Agent)
	case api.ScheduleActionNewAgent:
		return "new " + action.Provider + " agent"
	}
	command := action.Command
	if len(command) > 40 {
		command = command[:40] + "…"
	}
	return command
}

func shortID(id string) string {
	if len(id) > 8 {
		return id[:8]
	}
	return id
}

// ListSchedules returns every schedule, oldest first, with its newest run.
func (s *Service) ListSchedules() ([]api.Schedule, error) {
	book, err := s.scheduleBook()
	if err != nil {
		return nil, err
	}
	data := book.snapshot()
	result := make([]api.Schedule, 0, len(data.Schedules))
	for _, value := range data.Schedules {
		result = append(result, withLastRun(value, data.Runs))
	}
	return result, nil
}

func (s *Service) GetSchedule(id string) (api.Schedule, error) {
	book, err := s.scheduleBook()
	if err != nil {
		return api.Schedule{}, err
	}
	data := book.snapshot()
	index := scheduleIndex(data.Schedules, id)
	if index < 0 {
		return api.Schedule{}, fmt.Errorf("schedule not found: %s", id)
	}
	return withLastRun(data.Schedules[index], data.Runs), nil
}

func withLastRun(value api.Schedule, runs []api.ScheduleRun) api.Schedule {
	for index := len(runs) - 1; index >= 0; index-- {
		if runs[index].ScheduleID == value.ID {
			run := runs[index]
			value.LastRun = &run
			break
		}
	}
	return value
}

func scheduleIndex(schedules []api.Schedule, id string) int {
	id = strings.TrimSpace(id)
	return slices.IndexFunc(schedules, func(value api.Schedule) bool { return value.ID == id })
}

// RemoveSchedule deletes a schedule and its history. A prompt it was holding
// for a busy Agent is dropped with it.
func (s *Service) RemoveSchedule(id string) error {
	book, err := s.scheduleBook()
	if err != nil {
		return err
	}
	return book.update(func(data *scheduleFile) error {
		index := scheduleIndex(data.Schedules, id)
		if index < 0 {
			return fmt.Errorf("schedule not found: %s", id)
		}
		removed := data.Schedules[index].ID
		data.Schedules = slices.Delete(data.Schedules, index, index+1)
		data.Runs = slices.DeleteFunc(data.Runs, func(run api.ScheduleRun) bool { return run.ScheduleID == removed })
		return nil
	})
}

// SetSchedulePaused pauses or resumes a schedule. Resuming does not replay
// occurrences that fell inside the pause.
func (s *Service) SetSchedulePaused(id string, paused bool) (api.Schedule, error) {
	book, err := s.scheduleBook()
	if err != nil {
		return api.Schedule{}, err
	}
	now := s.scheduleNow()
	var result api.Schedule
	err = book.update(func(data *scheduleFile) error {
		index := scheduleIndex(data.Schedules, id)
		if index < 0 {
			return fmt.Errorf("schedule not found: %s", id)
		}
		value := &data.Schedules[index]
		if value.State == api.ScheduleStateCompleted {
			return fmt.Errorf("schedule %s is completed (%s)", value.ID, value.EndReason)
		}
		if paused {
			value.State = api.ScheduleStatePaused
			value.NextRunAt = nil
		} else if value.State == api.ScheduleStatePaused {
			value.State = api.ScheduleStateActive
			after := now
			if value.At != nil {
				// A one-shot whose instant passed while paused runs now.
				after = value.At.Add(-time.Minute)
			}
			next, reason := nextScheduleOccurrence(*value, after, s.scheduleLocation())
			value.NextRunAt = next
			if next == nil {
				value.State = api.ScheduleStateCompleted
				value.EndReason = reason
			}
		}
		value.UpdatedAt = now.UTC()
		result = withLastRun(*value, data.Runs)
		return nil
	})
	if err == nil && !paused {
		book.signal()
	}
	return result, err
}

// RunScheduleNow starts one manual run regardless of the schedule's state.
// It does not count toward --max-runs or move the next occurrence.
func (s *Service) RunScheduleNow(ctx context.Context, id string) (api.ScheduleRun, error) {
	book, err := s.scheduleBook()
	if err != nil {
		return api.ScheduleRun{}, err
	}
	now := s.scheduleNow().UTC()
	var run api.ScheduleRun
	var action api.ScheduleAction
	err = book.update(func(data *scheduleFile) error {
		index := scheduleIndex(data.Schedules, id)
		if index < 0 {
			return fmt.Errorf("schedule not found: %s", id)
		}
		action = data.Schedules[index].Action
		run = startScheduleRun(data, data.Schedules[index], api.ScheduleTriggerManual, now, now)
		return nil
	})
	if err != nil {
		return api.ScheduleRun{}, err
	}
	s.launchScheduleRun(s.scheduleContext(ctx), run, action, book.snapshot().Schedules)
	return run, nil
}

// ScheduleRuns returns a schedule's runs, newest first.
func (s *Service) ScheduleRuns(id string, limit int) ([]api.ScheduleRun, error) {
	book, err := s.scheduleBook()
	if err != nil {
		return nil, err
	}
	data := book.snapshot()
	if scheduleIndex(data.Schedules, id) < 0 {
		return nil, fmt.Errorf("schedule not found: %s", id)
	}
	result := make([]api.ScheduleRun, 0)
	for index := len(data.Runs) - 1; index >= 0; index-- {
		if data.Runs[index].ScheduleID != strings.TrimSpace(id) {
			continue
		}
		result = append(result, data.Runs[index])
		if limit > 0 && len(result) == limit {
			break
		}
	}
	return result, nil
}

// startScheduleRun appends a run in its initial state. A held prompt of the
// same schedule is superseded so one schedule never queues more than one.
func startScheduleRun(data *scheduleFile, value api.Schedule, trigger string, scheduledAt, now time.Time) api.ScheduleRun {
	run := api.ScheduleRun{
		ID:          store.NewID(),
		ScheduleID:  value.ID,
		Trigger:     trigger,
		ScheduledAt: scheduledAt.UTC(),
		StartedAt:   now.UTC(),
		Status:      api.ScheduleRunRunning,
	}
	if value.Action.Kind == api.ScheduleActionAgent {
		run.Session = value.Action.Agent
	}
	for index := range data.Runs {
		previous := &data.Runs[index]
		if previous.ScheduleID == value.ID && previous.Status == api.ScheduleRunWaiting {
			finished := now.UTC()
			previous.Status = api.ScheduleRunSkipped
			previous.Error = "superseded by run " + run.ID + " before the Agent's turn ended"
			previous.FinishedAt = &finished
		}
	}
	data.Runs = append(data.Runs, run)
	trimScheduleRuns(data, value.ID)
	return run
}

// trimScheduleRuns drops the oldest finished runs beyond the retention.
func trimScheduleRuns(data *scheduleFile, scheduleID string) {
	finished := 0
	for _, run := range data.Runs {
		if run.ScheduleID == scheduleID && run.FinishedAt != nil {
			finished++
		}
	}
	excess := finished - scheduleRunRetention
	if excess <= 0 {
		return
	}
	data.Runs = slices.DeleteFunc(data.Runs, func(run api.ScheduleRun) bool {
		if excess > 0 && run.ScheduleID == scheduleID && run.FinishedAt != nil {
			excess--
			return true
		}
		return false
	})
}

// scheduleContext is the context runs execute under: the Service lifecycle
// when it is running, so a run outlives the request that started it.
func (s *Service) scheduleContext(fallback context.Context) context.Context {
	s.scheduleCtxMu.Lock()
	defer s.scheduleCtxMu.Unlock()
	if s.scheduleCtx != nil {
		return s.scheduleCtx
	}
	return context.WithoutCancel(fallback)
}

// scheduleLoop fires due schedules until ctx ends.
func (s *Service) scheduleLoop(ctx context.Context) {
	book, err := s.scheduleBook()
	if err != nil {
		s.logWarn("schedules disabled", "error", err)
		return
	}
	s.scheduleCtxMu.Lock()
	s.scheduleCtx = ctx
	s.scheduleCtxMu.Unlock()
	s.resumeScheduleRuns(ctx)
	for {
		s.fireDueSchedules(ctx)
		wait := scheduleTickInterval
		if next, ok := s.nextScheduleDue(); ok {
			if until := next.Sub(s.scheduleNow()); until < wait {
				wait = max(until, 0)
			}
		}
		timer := time.NewTimer(wait)
		select {
		case <-ctx.Done():
			timer.Stop()
			return
		case <-book.wake:
			timer.Stop()
		case <-timer.C:
		}
	}
}

func (s *Service) nextScheduleDue() (time.Time, bool) {
	book, err := s.scheduleBook()
	if err != nil {
		return time.Time{}, false
	}
	var next time.Time
	for _, value := range book.snapshot().Schedules {
		if value.State != api.ScheduleStateActive || value.NextRunAt == nil {
			continue
		}
		if next.IsZero() || value.NextRunAt.Before(next) {
			next = *value.NextRunAt
		}
	}
	return next, !next.IsZero()
}

// fireDueSchedules starts one run for every active schedule that is due.
// Occurrences missed while the Host was down or asleep collapse into that one
// run instead of replaying each of them.
func (s *Service) fireDueSchedules(ctx context.Context) {
	book, err := s.scheduleBook()
	if err != nil {
		return
	}
	now := s.scheduleNow()
	location := s.scheduleLocation()
	type started struct {
		run    api.ScheduleRun
		action api.ScheduleAction
	}
	var runs []started
	err = book.update(func(data *scheduleFile) error {
		for index := range data.Schedules {
			value := &data.Schedules[index]
			if value.State != api.ScheduleStateActive || value.NextRunAt == nil || value.NextRunAt.After(now) {
				continue
			}
			due := *value.NextRunAt
			run := startScheduleRun(data, *value, api.ScheduleTriggerSchedule, due, now)
			runs = append(runs, started{run: run, action: value.Action})
			value.RunCount++
			value.UpdatedAt = now.UTC()
			next, reason := nextScheduleOccurrence(*value, now, location)
			value.NextRunAt = next
			if next == nil {
				value.State = api.ScheduleStateCompleted
				value.EndReason = reason
			}
		}
		if len(runs) == 0 {
			return errScheduleUnchanged
		}
		return nil
	})
	if err != nil {
		s.logWarn("fire schedules", "error", err)
		return
	}
	schedules := book.snapshot().Schedules
	for _, item := range runs {
		s.launchScheduleRun(ctx, item.run, item.action, schedules)
	}
}

// resumeScheduleRuns continues runs the previous Host process left open: a
// held prompt keeps waiting and a command keeps being watched, since its
// Session survives in Ghostline across a daemon restart.
func (s *Service) resumeScheduleRuns(ctx context.Context) {
	book, err := s.scheduleBook()
	if err != nil {
		return
	}
	data := book.snapshot()
	for _, run := range data.Runs {
		if run.FinishedAt != nil {
			continue
		}
		index := scheduleIndex(data.Schedules, run.ScheduleID)
		if index < 0 {
			continue
		}
		s.launchScheduleRun(ctx, run, data.Schedules[index].Action, data.Schedules)
	}
}

func (s *Service) launchScheduleRun(ctx context.Context, run api.ScheduleRun, action api.ScheduleAction, schedules []api.Schedule) {
	name := ""
	if index := scheduleIndex(schedules, run.ScheduleID); index >= 0 {
		name = schedules[index].Name
	}
	go func() {
		switch action.Kind {
		case api.ScheduleActionAgent:
			s.deliverScheduledPrompt(ctx, run, action)
		case api.ScheduleActionNewAgent:
			s.runScheduledNewAgent(ctx, run, action, name)
		case api.ScheduleActionCommand:
			s.runScheduledCommand(ctx, run, action, name)
		default:
			s.finishScheduleRun(run.ID, api.ScheduleRunFailed, fmt.Sprintf("unknown action %q", action.Kind), nil)
		}
	}()
}

// updateScheduleRun edits an open run. It reports false when the run is gone
// or already finished, which is how an executor learns it was superseded or
// its schedule removed.
func (s *Service) updateScheduleRun(id string, fn func(*api.ScheduleRun)) bool {
	book, err := s.scheduleBook()
	if err != nil {
		return false
	}
	open := false
	err = book.update(func(data *scheduleFile) error {
		for index := range data.Runs {
			if data.Runs[index].ID == id && data.Runs[index].FinishedAt == nil {
				before := data.Runs[index]
				fn(&data.Runs[index])
				open = true
				if scheduleRunEqual(before, data.Runs[index]) {
					return errScheduleUnchanged
				}
				return nil
			}
		}
		return errScheduleUnchanged
	})
	if err != nil {
		s.logWarn("update schedule run", "run", id, "error", err)
		return false
	}
	return open
}

// scheduleRunEqual compares the fields an executor edits, so a held run that
// polls without news does not rewrite the file every poll.
func scheduleRunEqual(a, b api.ScheduleRun) bool {
	return a.Status == b.Status && a.Error == b.Error && a.Session == b.Session &&
		a.FinishedAt == nil && b.FinishedAt == nil && a.DeliveredAt == nil && b.DeliveredAt == nil
}

func (s *Service) scheduleRunOpen(id string) bool {
	book, err := s.scheduleBook()
	if err != nil {
		return false
	}
	book.mu.Lock()
	defer book.mu.Unlock()
	for _, run := range book.data.Runs {
		if run.ID == id {
			return run.FinishedAt == nil
		}
	}
	return false
}

func (s *Service) finishScheduleRun(id, status, message string, edit func(*api.ScheduleRun)) {
	finished := s.scheduleNow().UTC()
	s.updateScheduleRun(id, func(run *api.ScheduleRun) {
		run.Status = status
		run.Error = message
		run.FinishedAt = &finished
		if edit != nil {
			edit(run)
		}
	})
	if status == api.ScheduleRunFailed {
		s.logWarn("schedule run failed", "run", id, "error", message)
	}
}

type promptAttempt int

const (
	promptDelivered promptAttempt = iota
	promptBusy
	promptNotReady
	promptFailed
)

// deliverScheduledPrompt sends the prompt as one Agent turn, holding it while
// the Agent is mid-turn when the action asks to wait.
func (s *Service) deliverScheduledPrompt(ctx context.Context, run api.ScheduleRun, action api.ScheduleAction) {
	var busyDeadline time.Time
	if action.BusyTimeout != "" {
		if duration, err := time.ParseDuration(action.BusyTimeout); err == nil {
			busyDeadline = run.StartedAt.Add(duration)
		}
	}
	readyDeadline := s.scheduleNow().Add(scheduleAgentReadyTimeout)
	for {
		if !s.scheduleRunOpen(run.ID) {
			return
		}
		attempt, message := s.attemptScheduledPrompt(ctx, action)
		if ctx.Err() != nil {
			// Shutdown leaves the run open; the next Host process resumes it.
			return
		}
		now := s.scheduleNow()
		switch attempt {
		case promptDelivered:
			delivered := now.UTC()
			s.finishScheduleRun(run.ID, api.ScheduleRunSucceeded, "", func(run *api.ScheduleRun) { run.DeliveredAt = &delivered })
			return
		case promptFailed:
			s.finishScheduleRun(run.ID, api.ScheduleRunFailed, message, nil)
			return
		case promptBusy:
			if action.WhenBusy == api.ScheduleWhenBusySkip {
				s.finishScheduleRun(run.ID, api.ScheduleRunSkipped, message, nil)
				return
			}
			if !busyDeadline.IsZero() && !now.Before(busyDeadline) {
				s.finishScheduleRun(run.ID, api.ScheduleRunFailed, message+" for longer than --busy-timeout "+action.BusyTimeout, nil)
				return
			}
			s.updateScheduleRun(run.ID, func(run *api.ScheduleRun) {
				run.Status = api.ScheduleRunWaiting
				run.Error = message
			})
		case promptNotReady:
			if !now.Before(readyDeadline) {
				s.finishScheduleRun(run.ID, api.ScheduleRunFailed, message, nil)
				return
			}
		}
		timer := time.NewTimer(s.schedulePollInterval())
		select {
		case <-ctx.Done():
			timer.Stop()
			return
		case <-timer.C:
		}
	}
}

// attemptScheduledPrompt makes one delivery attempt through the same Host
// path `agent.turn.start` uses.
func (s *Service) attemptScheduledPrompt(ctx context.Context, action api.ScheduleAction) (promptAttempt, string) {
	session, ok := s.sessionInAnyLifecycle(action.Agent)
	if !ok {
		return promptFailed, "agent not found: " + action.Agent
	}
	if session.Lifecycle != "running" {
		return promptFailed, "agent has ended: " + action.Agent
	}
	executionID := strings.TrimSpace(session.AgentExecutionID)
	if executionID == "" {
		return promptNotReady, "agent is still starting: " + action.Agent
	}
	if execution, ok := s.canonicalExecutionForSession(session.ID); ok {
		switch execution.State {
		case api.AgentExecutionWorking:
			return promptBusy, api.ErrAgentBusy.Error()
		case api.AgentExecutionBlocked:
			if execution.Status.Attention == nil || execution.Status.Attention.Kind != api.AgentAttentionInput {
				return promptBusy, api.ErrAgentBlocked.Error()
			}
		}
	}
	// Read only once the Agent can take the turn, so a held run delivers the
	// file as it is when the turn ends.
	text := action.Prompt
	if action.PromptFile != "" {
		var err error
		if text, err = readSchedulePrompt(action.PromptFile); err != nil {
			return promptFailed, err.Error()
		}
	}
	request := api.AgentTurnStartCommand{
		AgentCommand: api.AgentCommand{CommandID: store.NewID(), ExecutionID: executionID},
		Text:         text,
	}
	_, err := s.runCanonicalCommand(ctx, request.ExecutionID, request.CommandID, request, func() (any, error) {
		result, err := s.sendAgentMessage(ctx, api.AgentMessageSendRequest{
			Session: session.ID, ClientMessageID: request.CommandID, Text: request.Text,
		})
		if err != nil {
			return nil, err
		}
		return api.AgentCommandReceipt{CommandID: request.CommandID, Accepted: result.Accepted}, nil
	})
	switch {
	case err == nil:
		return promptDelivered, ""
	case errors.Is(err, api.ErrAgentBusy) || errors.Is(err, api.ErrAgentBlocked):
		return promptBusy, err.Error()
	default:
		return promptFailed, err.Error()
	}
}

// runScheduledCommand runs the command as the process of a new shell Session
// in the Workspace, so its output is a Session like any other, and records
// how it exited.
func (s *Service) runScheduledCommand(ctx context.Context, run api.ScheduleRun, action api.ScheduleAction, name string) {
	processRuntime := s.processRuntime()
	if processRuntime == nil {
		s.finishScheduleRun(run.ID, api.ScheduleRunFailed, "this Host cannot run commands without a shell", nil)
		return
	}
	var session api.Session
	if run.Session != "" {
		// Resumed after a Host restart: watch the Session already running.
		existing, ok := s.Session(run.Session)
		if !ok {
			s.finishScheduleRun(run.ID, api.ScheduleRunFailed, "the command's Session is gone: "+run.Session, nil)
			return
		}
		session = existing
	} else {
		if strings.TrimSpace(name) == "" {
			name = action.Command
		}
		shell, _, _ := s.acpShell()
		createContext, cancel := context.WithTimeout(ctx, acpTerminalCreateTimeout)
		created, err := s.createScheduledCommandSession(createContext, action, name, shell)
		cancel()
		if err != nil {
			s.finishScheduleRun(run.ID, api.ScheduleRunFailed, err.Error(), nil)
			return
		}
		session = created
		if !s.updateScheduleRun(run.ID, func(run *api.ScheduleRun) { run.Session = created.ID }) {
			return
		}
	}
	exit, err := processRuntime.WaitProcess(ctx, session.Runtime)
	if ctx.Err() != nil {
		return
	}
	s.markEnded(session.ID, api.EndReasonProcessExited)
	if err != nil {
		s.finishScheduleRun(run.ID, api.ScheduleRunFailed, "wait for the command: "+err.Error(), nil)
		return
	}
	code := exit.Code
	status, message := api.ScheduleRunSucceeded, ""
	switch {
	case exit.Signal != "":
		status, message = api.ScheduleRunFailed, "the command was ended by "+exit.Signal
	case code != 0:
		status, message = api.ScheduleRunFailed, fmt.Sprintf("the command exited with status %d", code)
	}
	s.finishScheduleRun(run.ID, status, message, func(run *api.ScheduleRun) { run.ExitCode = &code })
}

func (s *Service) createScheduledCommandSession(ctx context.Context, action api.ScheduleAction, name, shell string) (api.Session, error) {
	if lock := s.lockWorkspaceForSession(action.Workspace); lock != nil {
		defer lock.RUnlock()
	}
	return s.createSessionWith(ctx, sessionCreateRequest{
		workspaceID: action.Workspace,
		command:     action.Command,
		kind:        "shell",
		title:       clipACPText(name, acpTerminalTitleLimit),
		processArgv: acpTerminalArgv(shell, action.Command, nil),
	})
}

// dispatchSchedule serves the schedule.* control methods.
func (s *Service) dispatchSchedule(ctx context.Context, method string, params map[string]any) (any, error) {
	id := stringParam(params, "id")
	switch method {
	case "schedule.create":
		request, err := decodeAgentParams[api.ScheduleCreateRequest](params)
		if err != nil {
			return nil, err
		}
		return s.CreateSchedule(request)
	case "schedule.list":
		return s.ListSchedules()
	case "schedule.get":
		return s.GetSchedule(id)
	case "schedule.remove":
		if err := s.RemoveSchedule(id); err != nil {
			return nil, err
		}
		return map[string]bool{"removed": true}, nil
	case "schedule.pause":
		return s.SetSchedulePaused(id, true)
	case "schedule.resume":
		return s.SetSchedulePaused(id, false)
	case "schedule.run":
		return s.RunScheduleNow(ctx, id)
	case "schedule.runs":
		return s.ScheduleRuns(id, intParam(params, "limit"))
	}
	return nil, fmt.Errorf("unsupported method: %s", method)
}

// runScheduledNewAgent creates a new Agent with the prompt as its launch-time
// first turn, the way `agent create --prompt` does, then keeps the run open
// until that turn ends so the run reports how it went.
func (s *Service) runScheduledNewAgent(ctx context.Context, run api.ScheduleRun, action api.ScheduleAction, name string) {
	sessionID := run.Session
	if sessionID == "" {
		if !s.waitForEarlierScheduledAgent(ctx, run, action) {
			return
		}
		text := action.Prompt
		if action.PromptFile != "" {
			var err error
			if text, err = readSchedulePrompt(action.PromptFile); err != nil {
				s.finishScheduleRun(run.ID, api.ScheduleRunFailed, err.Error(), nil)
				return
			}
		}
		if strings.TrimSpace(name) == "" {
			name = action.Provider
		}
		title := name + " " + run.ScheduledAt.In(s.scheduleLocation()).Format("01-02 15:04")
		createContext, cancel := context.WithTimeout(ctx, acpTerminalCreateTimeout)
		created, err := s.CreateSessionWithHandler(createContext, action.Workspace,
			agent.AppendInitialPrompt(action.Command, action.Provider, text), action.Provider, title, "", "")
		cancel()
		if err != nil {
			s.finishScheduleRun(run.ID, api.ScheduleRunFailed, "create the Agent: "+err.Error(), nil)
			return
		}
		sessionID = created.ID
		delivered := s.scheduleNow().UTC()
		if !s.updateScheduleRun(run.ID, func(run *api.ScheduleRun) {
			run.Session = created.ID
			run.Status = api.ScheduleRunRunning
			run.Error = ""
			run.DeliveredAt = &delivered
		}) {
			return
		}
	}
	if !s.watchScheduledAgentTurn(ctx, run.ID, sessionID) {
		return
	}
	if action.Keep > 0 {
		s.pruneScheduledAgents(ctx, run.ScheduleID, action.Keep)
	}
}

// waitForEarlierScheduledAgent applies the busy policy while an earlier run
// of the same schedule is still open, so runs never stack Agents that work
// at once. It reports whether the run should go on.
func (s *Service) waitForEarlierScheduledAgent(ctx context.Context, run api.ScheduleRun, action api.ScheduleAction) bool {
	var deadline time.Time
	if action.BusyTimeout != "" {
		if duration, err := time.ParseDuration(action.BusyTimeout); err == nil {
			deadline = run.StartedAt.Add(duration)
		}
	}
	for {
		if !s.scheduleRunOpen(run.ID) {
			return false
		}
		earlier := s.earlierOpenScheduleRun(run)
		if earlier == "" {
			return true
		}
		message := "run " + earlier + " is still open"
		if action.WhenBusy == api.ScheduleWhenBusySkip {
			s.finishScheduleRun(run.ID, api.ScheduleRunSkipped, message, nil)
			return false
		}
		if !deadline.IsZero() && !s.scheduleNow().Before(deadline) {
			s.finishScheduleRun(run.ID, api.ScheduleRunFailed, message+" for longer than --busy-timeout "+action.BusyTimeout, nil)
			return false
		}
		s.updateScheduleRun(run.ID, func(run *api.ScheduleRun) {
			run.Status = api.ScheduleRunWaiting
			run.Error = message
		})
		timer := time.NewTimer(s.schedulePollInterval())
		select {
		case <-ctx.Done():
			timer.Stop()
			return false
		case <-timer.C:
		}
	}
}

// earlierOpenScheduleRun returns an open run of the same schedule that was
// started before run. Runs are appended in start order.
func (s *Service) earlierOpenScheduleRun(run api.ScheduleRun) string {
	book, err := s.scheduleBook()
	if err != nil {
		return ""
	}
	book.mu.Lock()
	defer book.mu.Unlock()
	for _, other := range book.data.Runs {
		if other.ID == run.ID {
			return ""
		}
		if other.ScheduleID == run.ScheduleID && other.FinishedAt == nil {
			return other.ID
		}
	}
	return ""
}

// watchScheduledAgentTurn finishes the run once the new Agent's first turn
// ends. A provider that reports no turn identity is done when it stops
// working after having worked. It reports whether the run was finished here.
func (s *Service) watchScheduledAgentTurn(ctx context.Context, runID, sessionID string) bool {
	sawWorking := false
	for {
		if !s.scheduleRunOpen(runID) {
			return false
		}
		session, ok := s.sessionInAnyLifecycle(sessionID)
		switch {
		case !ok:
			s.finishScheduleRun(runID, api.ScheduleRunFailed, "the Agent was removed before its first turn ended: "+sessionID, nil)
			return true
		case session.Lifecycle != "running":
			s.finishScheduleRun(runID, api.ScheduleRunFailed, "the Agent ended before its first turn ended: "+sessionID, nil)
			return true
		}
		// Reading the execution restores a turn projection the previous Host
		// process persisted, so a watch resumed after a restart sees it.
		execution, _ := s.canonicalExecutionForSession(sessionID)
		turn := s.agentTurn(sessionID)
		if execution.State == api.AgentExecutionWorking {
			sawWorking = true
		}
		switch {
		case turn.ID > 0 && turn.Status == api.AgentTurnCompleted:
			s.finishScheduleRun(runID, api.ScheduleRunSucceeded, "", nil)
			return true
		case turn.ID > 0 && turn.Status != api.AgentTurnStarted && turn.Status != api.AgentTurnIdle:
			s.finishScheduleRun(runID, api.ScheduleRunFailed, "the first turn ended as "+string(turn.Status), nil)
			return true
		case turn.ID == 0 && sawWorking && execution.State == api.AgentExecutionReady:
			s.finishScheduleRun(runID, api.ScheduleRunSucceeded, "", nil)
			return true
		}
		timer := time.NewTimer(s.schedulePollInterval())
		select {
		case <-ctx.Done():
			timer.Stop()
			return false
		case <-timer.C:
		}
	}
}

// pruneScheduledAgents removes the Agents of a schedule's older runs beyond
// the newest keep. An Agent that is pinned, working, or still followed by an
// open run is left alone.
func (s *Service) pruneScheduledAgents(ctx context.Context, scheduleID string, keep int) {
	book, err := s.scheduleBook()
	if err != nil {
		return
	}
	data := book.snapshot()
	open := map[string]bool{}
	var ordered []string
	seen := map[string]bool{}
	for index := len(data.Runs) - 1; index >= 0; index-- {
		run := data.Runs[index]
		if run.ScheduleID != scheduleID || run.Session == "" {
			continue
		}
		if run.FinishedAt == nil {
			open[run.Session] = true
		}
		if !seen[run.Session] {
			seen[run.Session] = true
			ordered = append(ordered, run.Session)
		}
	}
	if len(ordered) <= keep {
		return
	}
	for _, sessionID := range ordered[keep:] {
		session, ok := s.sessionInAnyLifecycle(sessionID)
		if !ok || session.Pinned || open[sessionID] {
			continue
		}
		if execution, ok := s.canonicalExecutionForSession(sessionID); ok && execution.State == api.AgentExecutionWorking {
			continue
		}
		removeContext, cancel := context.WithTimeout(ctx, s.commandTimeout())
		if err := s.DeleteSession(removeContext, sessionID); err != nil {
			s.logWarn("remove a scheduled Agent", "schedule", scheduleID, "session", sessionID, "error", err)
		}
		cancel()
	}
}
