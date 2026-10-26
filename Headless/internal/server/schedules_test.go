package server

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/store"
)

type scheduleTestClock struct{ now atomic.Int64 }

func (c *scheduleTestClock) Now() time.Time           { return time.Unix(0, c.now.Load()) }
func (c *scheduleTestClock) Set(value time.Time)      { c.now.Store(value.UnixNano()) }
func (c *scheduleTestClock) Advance(by time.Duration) { c.now.Add(int64(by)) }

const scheduleTestAgent = "agent-session"

type scheduleFixture struct {
	service  *Service
	runtime  *memoryRuntime
	clock    *scheduleTestClock
	location *time.Location
	dir      string
}

// newScheduleFixture builds a Host with one idle Codex Agent and one
// Workspace, a fake clock at 2026-10-23 09:00 Shanghai time, and a schedule
// file in a temporary directory.
func newScheduleFixture(t *testing.T) *scheduleFixture {
	t.Helper()
	location, err := time.LoadLocation("Asia/Shanghai")
	if err != nil {
		t.Skipf("time zone unavailable: %v", err)
	}
	dir := t.TempDir()
	state, err := store.Open(filepath.Join(dir, "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	if err := state.Update(func(value *api.State) error {
		value.Projects = []api.Project{{ID: "project", Name: "project", Path: dir}}
		value.Workspaces = []api.Workspace{{ID: "workspace", ProjectID: "project", Name: "main", Path: dir}}
		value.Sessions = []api.Session{{
			ID: scheduleTestAgent, WorkspaceID: "workspace", Kind: "codex", Runtime: "runtime",
			Lifecycle: "running", Title: "Codex", AgentExecutionID: "execution-1", CreatedAt: time.Now().UTC(),
		}}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	runtime := &processTestRuntime{memoryRuntime: newMemoryRuntime(t), processes: map[string]*testProcess{}}
	if err := runtime.Create(context.Background(), "runtime", "", "", nil); err != nil {
		t.Fatal(err)
	}
	clock := &scheduleTestClock{}
	clock.Set(time.Date(2026, 10, 23, 9, 0, 0, 0, location))
	service := &Service{
		Store:            state,
		Runtime:          runtime,
		ACPShell:         func() (string, []string) { return "", nil },
		SchedulePath:     filepath.Join(dir, "schedules.json"),
		scheduleClock:    clock.Now,
		scheduleTimeZone: location,
		scheduleBusyPoll: 5 * time.Millisecond,
	}
	service.lazyInit()
	service.agents[scheduleTestAgent] = &agentSession{}
	return &scheduleFixture{service: service, runtime: runtime.memoryRuntime, clock: clock, location: location, dir: dir}
}

func (f *scheduleFixture) setActivity(activity api.AgentActivity) {
	entry := f.service.agents[scheduleTestAgent]
	entry.mu.Lock()
	entry.status = api.AgentStatus{Activity: activity}
	entry.mu.Unlock()
}

func (f *scheduleFixture) captured(t *testing.T) string {
	t.Helper()
	data, _ := f.runtime.Capture(context.Background(), "runtime")
	return string(data)
}

func (f *scheduleFixture) at(value string) time.Time {
	parsed, err := time.ParseInLocation("2006-01-02 15:04", value, f.location)
	if err != nil {
		panic(err)
	}
	return parsed
}

// waitRun polls until the newest run of the schedule satisfies done.
func waitRun(t *testing.T, service *Service, scheduleID string, done func(api.ScheduleRun) bool) api.ScheduleRun {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for {
		runs, err := service.ScheduleRuns(scheduleID, 1)
		if err != nil {
			t.Fatal(err)
		}
		if len(runs) == 1 && done(runs[0]) {
			return runs[0]
		}
		if time.Now().After(deadline) {
			t.Fatalf("run did not reach the expected state: %#v", runs)
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func finished(run api.ScheduleRun) bool { return run.FinishedAt != nil }

func TestScheduleDailyPromptWaitsForBusyAgentTurn(t *testing.T) {
	f := newScheduleFixture(t)
	promptPath := filepath.Join(f.dir, "gray-check.prompt")
	if err := os.WriteFile(promptPath, []byte("Run the gray check\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	created, err := f.service.CreateSchedule(api.ScheduleCreateRequest{
		Cron: "47 10 * * *", Until: "2026-10-30", Agent: scheduleTestAgent, PromptFile: promptPath,
	})
	if err != nil {
		t.Fatal(err)
	}
	if created.Action.WhenBusy != api.ScheduleWhenBusyWait {
		t.Fatalf("default busy policy = %q", created.Action.WhenBusy)
	}
	if !created.NextRunAt.Equal(f.at("2026-10-23 10:47")) {
		t.Fatalf("next run = %s", created.NextRunAt.In(f.location))
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	f.setActivity(api.AgentActivityWorking)
	f.clock.Set(f.at("2026-10-23 10:47"))
	f.service.fireDueSchedules(ctx)
	waiting := waitRun(t, f.service, created.ID, func(run api.ScheduleRun) bool { return run.Status == api.ScheduleRunWaiting })
	if strings.Contains(f.captured(t), "gray check") {
		t.Fatal("the prompt was delivered while the Agent was working")
	}
	if !waiting.ScheduledAt.Equal(f.at("2026-10-23 10:47")) {
		t.Fatalf("scheduled at = %s", waiting.ScheduledAt)
	}

	// The prompt file is read at delivery, so an edit made meanwhile counts.
	if err := os.WriteFile(promptPath+".tmp", []byte("Run the gray check v2"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(promptPath+".tmp", promptPath); err != nil {
		t.Fatal(err)
	}
	f.setActivity(api.AgentActivityReady)
	run := waitRun(t, f.service, created.ID, finished)
	if run.Status != api.ScheduleRunSucceeded || run.DeliveredAt == nil || run.Error != "" {
		t.Fatalf("run = %#v", run)
	}
	if !strings.Contains(f.captured(t), "Run the gray check v2") {
		t.Fatalf("captured %q", f.captured(t))
	}

	value, err := f.service.GetSchedule(created.ID)
	if err != nil {
		t.Fatal(err)
	}
	if value.RunCount != 1 || !value.NextRunAt.Equal(f.at("2026-10-24 10:47")) || value.LastRun == nil || value.LastRun.ID != run.ID {
		t.Fatalf("schedule after run = %#v", value)
	}
}

func TestScheduleStopsAfterUntil(t *testing.T) {
	f := newScheduleFixture(t)
	created, err := f.service.CreateSchedule(api.ScheduleCreateRequest{
		Cron: "47 10 * * *", Until: "2026-10-24", Agent: scheduleTestAgent, Prompt: "check",
	})
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	for _, day := range []string{"2026-10-23 10:47", "2026-10-24 10:47"} {
		f.clock.Set(f.at(day))
		f.service.fireDueSchedules(ctx)
		waitRun(t, f.service, created.ID, finished)
	}
	value, _ := f.service.GetSchedule(created.ID)
	if value.State != api.ScheduleStateCompleted || value.NextRunAt != nil || value.RunCount != 2 {
		t.Fatalf("schedule = %#v", value)
	}
	if !strings.Contains(value.EndReason, "2026-10-24") {
		t.Fatalf("end reason = %q", value.EndReason)
	}
	f.clock.Set(f.at("2026-10-25 10:47"))
	f.service.fireDueSchedules(ctx)
	if runs, _ := f.service.ScheduleRuns(created.ID, 0); len(runs) != 2 {
		t.Fatalf("runs after until = %d", len(runs))
	}
}

func TestScheduleSkipsBusyAgentWhenAsked(t *testing.T) {
	f := newScheduleFixture(t)
	created, err := f.service.CreateSchedule(api.ScheduleCreateRequest{
		Cron: "*/5 * * * *", Agent: scheduleTestAgent, Prompt: "ping", WhenBusy: "skip",
	})
	if err != nil {
		t.Fatal(err)
	}
	f.setActivity(api.AgentActivityWorking)
	f.clock.Advance(5 * time.Minute)
	f.service.fireDueSchedules(context.Background())
	run := waitRun(t, f.service, created.ID, finished)
	if run.Status != api.ScheduleRunSkipped || !strings.Contains(run.Error, "working") {
		t.Fatalf("run = %#v", run)
	}
}

func TestScheduleBusyTimeoutFailsTheRun(t *testing.T) {
	f := newScheduleFixture(t)
	created, err := f.service.CreateSchedule(api.ScheduleCreateRequest{
		Cron: "*/5 * * * *", Agent: scheduleTestAgent, Prompt: "ping", BusyTimeout: "10m",
	})
	if err != nil {
		t.Fatal(err)
	}
	f.setActivity(api.AgentActivityWorking)
	f.clock.Advance(5 * time.Minute)
	f.service.fireDueSchedules(context.Background())
	waitRun(t, f.service, created.ID, func(run api.ScheduleRun) bool { return run.Status == api.ScheduleRunWaiting })
	f.clock.Advance(11 * time.Minute)
	run := waitRun(t, f.service, created.ID, finished)
	if run.Status != api.ScheduleRunFailed || !strings.Contains(run.Error, "--busy-timeout 10m0s") {
		t.Fatalf("run = %#v", run)
	}
}

func TestScheduleNextOccurrenceSupersedesHeldPrompt(t *testing.T) {
	f := newScheduleFixture(t)
	created, err := f.service.CreateSchedule(api.ScheduleCreateRequest{
		Cron: "*/5 * * * *", Agent: scheduleTestAgent, Prompt: "ping",
	})
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	f.setActivity(api.AgentActivityWorking)
	f.clock.Advance(5 * time.Minute)
	f.service.fireDueSchedules(ctx)
	first := waitRun(t, f.service, created.ID, func(run api.ScheduleRun) bool { return run.Status == api.ScheduleRunWaiting })
	f.clock.Advance(5 * time.Minute)
	f.service.fireDueSchedules(ctx)
	second := waitRun(t, f.service, created.ID, func(run api.ScheduleRun) bool {
		return run.ID != first.ID && run.Status == api.ScheduleRunWaiting
	})
	runs, _ := f.service.ScheduleRuns(created.ID, 0)
	if len(runs) != 2 || runs[1].ID != first.ID || runs[1].Status != api.ScheduleRunSkipped || !strings.Contains(runs[1].Error, second.ID) {
		t.Fatalf("runs = %#v", runs)
	}
	f.setActivity(api.AgentActivityReady)
	waitRun(t, f.service, created.ID, finished)
	if count := strings.Count(f.captured(t), "ping"); count != 1 {
		t.Fatalf("prompt delivered %d times", count)
	}
}

func TestScheduleRecordsEndedAgent(t *testing.T) {
	f := newScheduleFixture(t)
	created, err := f.service.CreateSchedule(api.ScheduleCreateRequest{
		Cron: "*/5 * * * *", Agent: scheduleTestAgent, Prompt: "ping",
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := f.service.Store.Update(func(value *api.State) error {
		value.Sessions[0].Lifecycle = "ended"
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	f.clock.Advance(5 * time.Minute)
	f.service.fireDueSchedules(context.Background())
	run := waitRun(t, f.service, created.ID, finished)
	if run.Status != api.ScheduleRunFailed || run.Error != "agent has ended: "+scheduleTestAgent {
		t.Fatalf("run = %#v", run)
	}

	if err := f.service.Store.Update(func(value *api.State) error {
		value.Sessions = nil
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := f.service.RunScheduleNow(context.Background(), created.ID); err != nil {
		t.Fatal(err)
	}
	run = waitRun(t, f.service, created.ID, func(run api.ScheduleRun) bool { return run.Trigger == api.ScheduleTriggerManual && finished(run) })
	if run.Status != api.ScheduleRunFailed || run.Error != "agent not found: "+scheduleTestAgent {
		t.Fatalf("run = %#v", run)
	}
}

func TestScheduleOneShotManualRunAndPause(t *testing.T) {
	f := newScheduleFixture(t)
	created, err := f.service.CreateSchedule(api.ScheduleCreateRequest{
		Name: "once", At: "2026-10-23 12:00", Agent: scheduleTestAgent, Prompt: "once",
	})
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	if _, err := f.service.RunScheduleNow(ctx, created.ID); err != nil {
		t.Fatal(err)
	}
	waitRun(t, f.service, created.ID, finished)
	value, _ := f.service.GetSchedule(created.ID)
	if value.RunCount != 0 || value.State != api.ScheduleStateActive {
		t.Fatalf("a manual run changed the schedule: %#v", value)
	}

	if _, err := f.service.SetSchedulePaused(created.ID, true); err != nil {
		t.Fatal(err)
	}
	f.clock.Set(f.at("2026-10-23 12:30"))
	f.service.fireDueSchedules(ctx)
	if runs, _ := f.service.ScheduleRuns(created.ID, 0); len(runs) != 1 {
		t.Fatalf("a paused schedule fired: %#v", runs)
	}
	// A one-shot whose instant passed while paused runs once resumed.
	resumed, err := f.service.SetSchedulePaused(created.ID, false)
	if err != nil {
		t.Fatal(err)
	}
	if resumed.State != api.ScheduleStateActive || resumed.NextRunAt == nil {
		t.Fatalf("resumed = %#v", resumed)
	}
	f.service.fireDueSchedules(ctx)
	waitRun(t, f.service, created.ID, func(run api.ScheduleRun) bool { return run.Trigger == api.ScheduleTriggerSchedule && finished(run) })
	value, _ = f.service.GetSchedule(created.ID)
	if value.State != api.ScheduleStateCompleted || value.EndReason != "ran once" {
		t.Fatalf("schedule = %#v", value)
	}
	if _, err := f.service.SetSchedulePaused(created.ID, false); err == nil {
		t.Fatal("a completed schedule resumed")
	}
}

func TestScheduleMaxRunsAndPersistence(t *testing.T) {
	f := newScheduleFixture(t)
	created, err := f.service.CreateSchedule(api.ScheduleCreateRequest{
		Cron: "0 * * * *", MaxRuns: 2, Agent: scheduleTestAgent, Prompt: "hourly",
	})
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	f.clock.Set(f.at("2026-10-23 10:00"))
	f.service.fireDueSchedules(ctx)
	waitRun(t, f.service, created.ID, finished)

	// A new Host process reads the same file and keeps the schedule.
	reopened := &Service{Store: f.service.Store, SchedulePath: f.service.SchedulePath, scheduleClock: f.clock.Now, scheduleTimeZone: f.location}
	value, err := reopened.GetSchedule(created.ID)
	if err != nil {
		t.Fatal(err)
	}
	if value.RunCount != 1 || !value.NextRunAt.Equal(f.at("2026-10-23 11:00")) || value.LastRun == nil {
		t.Fatalf("reopened = %#v", value)
	}

	f.clock.Set(f.at("2026-10-23 13:30")) // three missed hours collapse into one run
	f.service.fireDueSchedules(ctx)
	run := waitRun(t, f.service, created.ID, finished)
	if !run.ScheduledAt.Equal(f.at("2026-10-23 11:00")) {
		t.Fatalf("late run scheduled at %s", run.ScheduledAt.In(f.location))
	}
	value, _ = f.service.GetSchedule(created.ID)
	if value.State != api.ScheduleStateCompleted || value.RunCount != 2 || value.EndReason != "reached 2 runs" {
		t.Fatalf("schedule = %#v", value)
	}
}

func TestScheduleCommandRunsAsWorkspaceSession(t *testing.T) {
	f := newScheduleFixture(t)
	created, err := f.service.CreateSchedule(api.ScheduleCreateRequest{
		Name: "probe", Cron: "@hourly", Workspace: "workspace", Command: "test -d . && exit 3",
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.service.RunScheduleNow(context.Background(), created.ID); err != nil {
		t.Fatal(err)
	}
	run := waitRun(t, f.service, created.ID, finished)
	if run.Status != api.ScheduleRunFailed || run.ExitCode == nil || *run.ExitCode != 3 || run.Session == "" {
		t.Fatalf("run = %#v", run)
	}
	session, ok := f.service.sessionInAnyLifecycle(run.Session)
	if !ok || session.WorkspaceID != "workspace" || session.Lifecycle == "running" || session.CustomTitle != "probe" {
		t.Fatalf("session = %#v", session)
	}
}

func TestScheduleCreateValidation(t *testing.T) {
	f := newScheduleFixture(t)
	cases := []struct {
		request api.ScheduleCreateRequest
		want    string
	}{
		{api.ScheduleCreateRequest{Agent: scheduleTestAgent, Prompt: "x"}, "--cron EXPRESSION or --at TIME"},
		{api.ScheduleCreateRequest{Cron: "* * *", Agent: scheduleTestAgent, Prompt: "x"}, "5 fields"},
		{api.ScheduleCreateRequest{At: "2026-10-22 10:00", Agent: scheduleTestAgent, Prompt: "x"}, "in the past"},
		{api.ScheduleCreateRequest{At: "2026-10-24 10:00", Until: "2026-10-25", Agent: scheduleTestAgent, Prompt: "x"}, "apply only to --cron"},
		{api.ScheduleCreateRequest{Cron: "@daily", Until: "2026-10-01", Agent: scheduleTestAgent, Prompt: "x"}, "in the past"},
		{api.ScheduleCreateRequest{Cron: "@daily", Agent: "missing", Prompt: "x"}, "agent not found"},
		{api.ScheduleCreateRequest{Cron: "@daily", Agent: scheduleTestAgent}, "needs --prompt"},
		{api.ScheduleCreateRequest{Cron: "@daily", Agent: scheduleTestAgent, PromptFile: "relative.prompt"}, "absolute path"},
		{api.ScheduleCreateRequest{Cron: "@daily", Agent: scheduleTestAgent, PromptFile: "/nonexistent/x.prompt"}, "read prompt file"},
		{api.ScheduleCreateRequest{Cron: "@daily", Agent: scheduleTestAgent, Prompt: "x", WhenBusy: "queue"}, "wait or skip"},
		{api.ScheduleCreateRequest{Cron: "@daily", Agent: scheduleTestAgent, Prompt: "x", WhenBusy: "skip", BusyTimeout: "1h"}, "only to --when-busy wait"},
		{api.ScheduleCreateRequest{Cron: "@daily", Workspace: "workspace"}, "both --workspace"},
		{api.ScheduleCreateRequest{Cron: "@daily", Workspace: "nope", Command: "true"}, "workspace not found"},
		{api.ScheduleCreateRequest{Cron: "@daily", Agent: scheduleTestAgent, Workspace: "workspace", Command: "true"}, "cannot be combined"},
		{api.ScheduleCreateRequest{Cron: "0 0 30 2 *", Agent: scheduleTestAgent, Prompt: "x"}, "would never run"},
	}
	for _, test := range cases {
		_, err := f.service.CreateSchedule(test.request)
		if err == nil || !strings.Contains(err.Error(), test.want) {
			t.Errorf("%+v: error %v, want %q", test.request, err, test.want)
		}
	}
	if list, _ := f.service.ListSchedules(); len(list) != 0 {
		t.Fatalf("invalid requests stored schedules: %#v", list)
	}
}

func TestScheduleRemoveDropsHistory(t *testing.T) {
	f := newScheduleFixture(t)
	created, err := f.service.CreateSchedule(api.ScheduleCreateRequest{Cron: "@daily", Agent: scheduleTestAgent, Prompt: "x"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.service.RunScheduleNow(context.Background(), created.ID); err != nil {
		t.Fatal(err)
	}
	waitRun(t, f.service, created.ID, finished)
	if err := f.service.RemoveSchedule(created.ID); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(f.service.SchedulePath)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(data, []byte(created.ID)) {
		t.Fatalf("schedule file still mentions the removed schedule: %s", data)
	}
	if err := f.service.RemoveSchedule(created.ID); err == nil {
		t.Fatal("removed a missing schedule")
	}
}

func TestScheduleIdleTickDoesNotRewriteTheFile(t *testing.T) {
	f := newScheduleFixture(t)
	if _, err := f.service.CreateSchedule(api.ScheduleCreateRequest{Cron: "@daily", Agent: scheduleTestAgent, Prompt: "x"}); err != nil {
		t.Fatal(err)
	}
	before, err := os.Stat(f.service.SchedulePath)
	if err != nil {
		t.Fatal(err)
	}
	time.Sleep(20 * time.Millisecond)
	f.service.fireDueSchedules(context.Background())
	after, err := os.Stat(f.service.SchedulePath)
	if err != nil {
		t.Fatal(err)
	}
	if !after.ModTime().Equal(before.ModTime()) {
		t.Fatal("a tick with nothing due rewrote schedules.json")
	}
}

// setScheduledAgentTurn records the turn the Host observed for an Agent, as
// the provider watcher would.
func setScheduledAgentTurn(service *Service, sessionID string, turn api.AgentTurn, activity api.AgentActivity) {
	service.agentsMu.Lock()
	entry := service.agents[sessionID]
	if entry == nil {
		entry = &agentSession{}
		service.agents[sessionID] = entry
	}
	service.agentsMu.Unlock()
	entry.mu.Lock()
	entry.turn = turn
	entry.status = api.AgentStatus{Activity: activity}
	entry.mu.Unlock()
}

func TestScheduleNewAgentRunsPromptAsFirstTurn(t *testing.T) {
	f := newScheduleFixture(t)
	created, err := f.service.CreateSchedule(api.ScheduleCreateRequest{
		Name: "gray-check", Cron: "47 10 * * *", Workspace: "workspace", Provider: "claude", Prompt: "it's the gray check",
	})
	if err != nil {
		t.Fatal(err)
	}
	if created.Action.Kind != api.ScheduleActionNewAgent || created.Action.Command != "claude" || created.Action.WhenBusy != api.ScheduleWhenBusyWait {
		t.Fatalf("action = %#v", created.Action)
	}
	f.clock.Set(f.at("2026-10-23 10:47"))
	f.service.fireDueSchedules(context.Background())
	run := waitRun(t, f.service, created.ID, func(run api.ScheduleRun) bool { return run.Session != "" })
	if run.Status != api.ScheduleRunRunning || run.DeliveredAt == nil {
		t.Fatalf("run = %#v", run)
	}
	session, ok := f.service.Session(run.Session)
	if !ok || session.Kind != "claude" || session.WorkspaceID != "workspace" || session.CustomTitle != "gray-check 10-23 10:47" {
		t.Fatalf("session = %#v", session)
	}
	if !strings.Contains(session.Command, `'it'"'"'s the gray check'`) {
		t.Fatalf("command %q does not carry the quoted launch prompt", session.Command)
	}
	setScheduledAgentTurn(f.service, run.Session, api.AgentTurn{ID: 1, Status: api.AgentTurnStarted}, api.AgentActivityWorking)
	time.Sleep(30 * time.Millisecond)
	if runs, _ := f.service.ScheduleRuns(created.ID, 1); runs[0].FinishedAt != nil {
		t.Fatalf("the run finished while the first turn was working: %#v", runs[0])
	}
	setScheduledAgentTurn(f.service, run.Session, api.AgentTurn{ID: 1, Status: api.AgentTurnCompleted}, api.AgentActivityReady)
	run = waitRun(t, f.service, created.ID, finished)
	if run.Status != api.ScheduleRunSucceeded {
		t.Fatalf("run = %#v", run)
	}
}

func TestScheduleNewAgentWaitsForThePreviousRunAndPrunes(t *testing.T) {
	f := newScheduleFixture(t)
	created, err := f.service.CreateSchedule(api.ScheduleCreateRequest{
		Cron: "*/5 * * * *", Workspace: "workspace", Provider: "codex", Prompt: "ping", Keep: 1,
	})
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	f.clock.Advance(5 * time.Minute)
	f.service.fireDueSchedules(ctx)
	first := waitRun(t, f.service, created.ID, func(run api.ScheduleRun) bool { return run.Session != "" })

	f.clock.Advance(5 * time.Minute)
	f.service.fireDueSchedules(ctx)
	second := waitRun(t, f.service, created.ID, func(run api.ScheduleRun) bool {
		return run.ID != first.ID && run.Status == api.ScheduleRunWaiting
	})
	if second.Session != "" || !strings.Contains(second.Error, first.ID) {
		t.Fatalf("second = %#v", second)
	}

	setScheduledAgentTurn(f.service, first.Session, api.AgentTurn{ID: 1, Status: api.AgentTurnFailed}, api.AgentActivityReady)
	second = waitRun(t, f.service, created.ID, func(run api.ScheduleRun) bool { return run.ID == second.ID && run.Session != "" })
	runs, _ := f.service.ScheduleRuns(created.ID, 0)
	if runs[1].Status != api.ScheduleRunFailed || runs[1].Error != "the first turn ended as failed" {
		t.Fatalf("first run = %#v", runs[1])
	}
	if second.Session == first.Session {
		t.Fatal("the second run reused the first Agent")
	}

	setScheduledAgentTurn(f.service, second.Session, api.AgentTurn{ID: 1, Status: api.AgentTurnCompleted}, api.AgentActivityReady)
	waitRun(t, f.service, created.ID, finished)
	deadline := time.Now().Add(5 * time.Second)
	for {
		_, firstExists := f.service.sessionInAnyLifecycle(first.Session)
		_, secondExists := f.service.sessionInAnyLifecycle(second.Session)
		if !firstExists && secondExists {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("--keep 1 left first=%v second=%v", firstExists, secondExists)
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func TestScheduleNewAgentSkipsWhileThePreviousRunIsOpen(t *testing.T) {
	f := newScheduleFixture(t)
	created, err := f.service.CreateSchedule(api.ScheduleCreateRequest{
		Cron: "*/5 * * * *", Workspace: "workspace", Provider: "codex", Prompt: "ping", WhenBusy: "skip",
	})
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	f.clock.Advance(5 * time.Minute)
	f.service.fireDueSchedules(ctx)
	first := waitRun(t, f.service, created.ID, func(run api.ScheduleRun) bool { return run.Session != "" })
	f.clock.Advance(5 * time.Minute)
	f.service.fireDueSchedules(ctx)
	second := waitRun(t, f.service, created.ID, func(run api.ScheduleRun) bool { return run.ID != first.ID && finished(run) })
	if second.Status != api.ScheduleRunSkipped || second.Session != "" {
		t.Fatalf("second = %#v", second)
	}
}

func TestScheduleNewAgentRecordsAnAgentThatEndsEarly(t *testing.T) {
	f := newScheduleFixture(t)
	created, err := f.service.CreateSchedule(api.ScheduleCreateRequest{
		Cron: "@daily", Workspace: "workspace", Provider: "pi", Prompt: "ping",
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.service.RunScheduleNow(context.Background(), created.ID); err != nil {
		t.Fatal(err)
	}
	run := waitRun(t, f.service, created.ID, func(run api.ScheduleRun) bool { return run.Session != "" })
	f.service.markEnded(run.Session, api.EndReasonProcessExited)
	run = waitRun(t, f.service, created.ID, finished)
	if run.Status != api.ScheduleRunFailed || !strings.Contains(run.Error, "ended before its first turn ended") {
		t.Fatalf("run = %#v", run)
	}
}

func TestScheduleNewAgentValidation(t *testing.T) {
	f := newScheduleFixture(t)
	cases := []struct {
		request api.ScheduleCreateRequest
		want    string
	}{
		{api.ScheduleCreateRequest{Cron: "@daily", Provider: "claude", Prompt: "x"}, "needs --workspace"},
		{api.ScheduleCreateRequest{Cron: "@daily", Workspace: "workspace", Provider: "trae", Prompt: "x"}, "--provider must be"},
		{api.ScheduleCreateRequest{Cron: "@daily", Workspace: "nope", Provider: "claude", Prompt: "x"}, "workspace not found"},
		{api.ScheduleCreateRequest{Cron: "@daily", Workspace: "workspace", Provider: "claude"}, "needs --prompt"},
		{api.ScheduleCreateRequest{Cron: "@daily", Workspace: "workspace", Provider: "claude", Prompt: "x", Keep: -1}, "must not be negative"},
		{api.ScheduleCreateRequest{Cron: "@daily", Agent: scheduleTestAgent, Prompt: "x", Keep: 2}, "--keep applies only"},
		{api.ScheduleCreateRequest{Cron: "@daily", Agent: scheduleTestAgent, Provider: "claude", Prompt: "x"}, "cannot be combined"},
	}
	for _, test := range cases {
		_, err := f.service.CreateSchedule(test.request)
		if err == nil || !strings.Contains(err.Error(), test.want) {
			t.Errorf("%+v: error %v, want %q", test.request, err, test.want)
		}
	}
}
