package main

import (
	"errors"
	"strings"
	"testing"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

func TestScheduleCommandRejectsBadArguments(t *testing.T) {
	cases := []struct {
		args []string
		want string
	}{
		{[]string{"schedule"}, "schedule command is required"},
		{[]string{"schedule", "edit"}, "unsupported command: schedule edit"},
		{[]string{"schedule", "create", "--agent", "A", "--prompt", "x"}, "missing --cron EXPRESSION or --at TIME"},
		{[]string{"schedule", "create", "--cron", "@daily"}, "missing --agent AGENT_ID"},
		{[]string{"schedule", "create", "--cron", "@daily", "--agent", "A", "--prompt", "x", "--max-runs", "0"}, "--max-runs must be a positive integer"},
		{[]string{"schedule", "create", "--cron", "@daily", "--agent", "A", "--bogus", "x"}, `unknown flag "--bogus"`},
		{[]string{"schedule", "create", "extra", "--cron", "@daily"}, "does not accept positional arguments"},
		{[]string{"schedule", "view"}, "requires exactly one SCHEDULE_ID"},
		{[]string{"schedule", "runs", "A", "B"}, "requires exactly one SCHEDULE_ID"},
		{[]string{"schedule", "runs", "A", "--all", "--limit", "3"}, "--all cannot be combined with --limit"},
		{[]string{"schedule", "list", "--state", "done"}, "--state must be active, paused, or completed"},
		{[]string{"schedule", "create", "--cron", "@daily", "--workspace", "W", "--provider", "claude", "--prompt", "x", "--keep", "0"}, "--keep must be a positive integer"},
		{[]string{"schedule", "create", "--cron", "@daily", "--workspace", "W", "--provider", "claude", "--command", "claude; rm -rf /", "--prompt", "x"}, "shell operators"},
		{[]string{"schedule", "create", "--cron", "@daily", "--workspace", "W", "--provider", "codex", "--command", "codex exec", "--prompt", "x"}, "codex"},
	}
	for _, test := range cases {
		err := run(test.args)
		var usageErr *usageError
		if !errors.As(err, &usageErr) || !strings.Contains(usageErr.message, test.want) {
			t.Errorf("%v: error = %v, want usage error containing %q", test.args, err, test.want)
		}
	}
}

func TestScheduleHelpNamesEveryAction(t *testing.T) {
	text := scheduleUsageText()
	for _, action := range []string{"create", "list", "view", "remove", "pause", "resume", "run", "runs"} {
		if !strings.Contains(text, "  "+action+" ") {
			t.Errorf("schedule help does not describe %s", action)
		}
	}
	if !strings.Contains(usageText(), "schedule create|list|view|remove|pause|resume|run|runs") {
		t.Error("top-level help does not list schedule")
	}
	create := scheduleActionUsageText("create")
	for _, flag := range []string{"--cron", "--at", "--until", "--max-runs", "--prompt-file", "--when-busy", "--busy-timeout", "--workspace", "--command", "--provider", "--keep"} {
		if !strings.Contains(create, flag) {
			t.Errorf("create help does not describe %s", flag)
		}
	}
}

func TestFilterScheduleRows(t *testing.T) {
	schedules := []api.Schedule{
		{ID: "s1", Name: "gray-check", State: api.ScheduleStateActive, Action: api.ScheduleAction{Kind: api.ScheduleActionAgent, Agent: "agent-1", PromptFile: "/p/gray.prompt"}},
		{ID: "s2", Name: "nightly", State: api.ScheduleStatePaused, Action: api.ScheduleAction{Kind: api.ScheduleActionCommand, Workspace: "ws-1", Command: "make test"}},
		{ID: "s3", Name: "done", State: api.ScheduleStateCompleted, Action: api.ScheduleAction{Kind: api.ScheduleActionAgent, Agent: "agent-2", Prompt: "hi"}},
	}
	ids := func(rows []ScheduleRow) string {
		values := make([]string, 0, len(rows))
		for _, row := range rows {
			values = append(values, row.ID)
		}
		return strings.Join(values, ",")
	}
	if got := ids(filterScheduleRows(schedules, "", "", "", "")); got != "s1,s2,s3" {
		t.Fatalf("all = %s", got)
	}
	if got := ids(filterScheduleRows(schedules, api.ScheduleStatePaused, "", "", "")); got != "s2" {
		t.Fatalf("paused = %s", got)
	}
	if got := ids(filterScheduleRows(schedules, "", "agent-2", "", "")); got != "s3" {
		t.Fatalf("agent = %s", got)
	}
	if got := ids(filterScheduleRows(schedules, "", "", "ws-1", "")); got != "s2" {
		t.Fatalf("workspace = %s", got)
	}
	if got := ids(filterScheduleRows(schedules, "", "", "", "GRAY")); got != "s1" {
		t.Fatalf("search = %s", got)
	}
	if got := ids(limitListRows(filterScheduleRows(schedules, "", "", "", ""), 2)); got != "s1,s2" {
		t.Fatalf("limit = %s", got)
	}
}
