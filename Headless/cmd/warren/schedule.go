package main

import (
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

var scheduleActionValueFlags = map[string]map[string]bool{
	"create": {
		"name": true, "cron": true, "at": true, "until": true, "max-runs": true,
		"agent": true, "prompt": true, "prompt-file": true, "when-busy": true, "busy-timeout": true,
		"workspace": true, "command": true, "provider": true, "keep": true,
	},
	"list": {"search": true, "state": true, "agent": true, "workspace": true, "limit": true},
	"runs": {"limit": true},
}

var scheduleActionBooleanFlags = map[string]map[string]bool{
	"list": {"all": true},
	"runs": {"all": true},
}

func scheduleCommand(args []string) error {
	if len(args) == 0 {
		return newUsageError("schedule command is required", scheduleUsageText())
	}
	if isHelpArgument(args[0]) {
		fmt.Print(scheduleUsageText())
		return nil
	}
	action := args[0]
	switch action {
	case "get":
		action = "view"
	case "delete":
		action = "remove"
	case "run-now":
		action = "run"
	}
	switch action {
	case "create", "list", "view", "remove", "pause", "resume", "run", "runs":
	default:
		return newUsageError(fmt.Sprintf("unsupported command: schedule %s", args[0]), scheduleUsageText())
	}
	booleanFlags := map[string]bool{"help": true}
	for name := range scheduleActionBooleanFlags[action] {
		booleanFlags[name] = true
	}
	help, _, err := validateStrictFlags(args[1:], scheduleActionValueFlags[action], booleanFlags)
	if err != nil {
		return newUsageError(err.Error(), scheduleActionUsageText(action))
	}
	if help {
		fmt.Print(scheduleActionUsageText(action))
		return nil
	}
	params := parseFlags(args[1:], scheduleActionValueFlags[action])
	positions := positionals(params)
	switch action {
	case "create", "list":
		if len(positions) > 0 {
			return newUsageError(fmt.Sprintf("schedule %s does not accept positional arguments", action), scheduleActionUsageText(action))
		}
	default:
		if len(positions) != 1 {
			return newUsageError("schedule "+action+" requires exactly one SCHEDULE_ID", scheduleActionUsageText(action))
		}
	}
	switch action {
	case "create":
		return scheduleCreate(params)
	case "list":
		return scheduleList(params)
	case "runs":
		return scheduleRuns(positions[0], params)
	}
	method := map[string]string{
		"view": "schedule.get", "remove": "schedule.remove", "pause": "schedule.pause",
		"resume": "schedule.resume", "run": "schedule.run",
	}[action]
	ctx, c, err := connect()
	if err != nil {
		return err
	}
	defer c.Close()
	request := map[string]any{"id": positions[0]}
	switch action {
	case "remove":
		var result map[string]bool
		if err := c.Request(ctx, method, request, &result); err != nil {
			return err
		}
		return printValue(result)
	case "run":
		var result api.ScheduleRun
		if err := c.Request(ctx, method, request, &result); err != nil {
			return err
		}
		return printValue(result)
	default:
		var result api.Schedule
		if err := c.Request(ctx, method, request, &result); err != nil {
			return err
		}
		return printValue(result)
	}
}

func scheduleCreate(params map[string]any) error {
	request := api.ScheduleCreateRequest{
		Name:        stringValue(params, "name"),
		Cron:        stringValue(params, "cron"),
		At:          stringValue(params, "at"),
		Until:       stringValue(params, "until"),
		Agent:       stringValue(params, "agent"),
		Prompt:      stringValue(params, "prompt"),
		PromptFile:  stringValue(params, "prompt-file"),
		WhenBusy:    stringValue(params, "when-busy"),
		BusyTimeout: stringValue(params, "busy-timeout"),
		Workspace:   stringValue(params, "workspace"),
		Command:     stringValue(params, "command"),
		Provider:    strings.ToLower(strings.TrimSpace(stringValue(params, "provider"))),
	}
	if value := stringValue(params, "keep"); value != "" {
		parsed, err := strconv.Atoi(value)
		if err != nil || parsed <= 0 {
			return newUsageError("--keep must be a positive integer", scheduleActionUsageText("create"))
		}
		request.Keep = parsed
	}
	if request.Provider != "" && request.Command != "" {
		// The executable runs exactly as `agent create --command` would, so
		// it is held to the same rules before the Host stores it.
		if err := validateAgentCommand(request.Command, request.Provider); err != nil {
			return newUsageError(err.Error(), scheduleActionUsageText("create"))
		}
	}
	if value := stringValue(params, "max-runs"); value != "" {
		parsed, err := strconv.Atoi(value)
		if err != nil || parsed <= 0 {
			return newUsageError("--max-runs must be a positive integer", scheduleActionUsageText("create"))
		}
		request.MaxRuns = parsed
	}
	if request.Cron == "" && request.At == "" {
		return newUsageError("missing --cron EXPRESSION or --at TIME", scheduleActionUsageText("create"))
	}
	if request.Agent == "" && request.Workspace == "" && request.Command == "" && request.Provider == "" {
		return newUsageError("missing --agent AGENT_ID, --workspace WORKSPACE_ID with --provider PROVIDER, or --workspace WORKSPACE_ID with --command COMMAND", scheduleActionUsageText("create"))
	}
	// Like `agent send`, an action that prompts an Agent without --prompt or
	// --prompt-file reads the prompt from stdin, once, when it is created.
	if (request.Agent != "" || request.Provider != "") && request.Prompt == "" && request.PromptFile == "" {
		data, err := io.ReadAll(os.Stdin)
		if err != nil {
			return err
		}
		request.Prompt = strings.TrimSpace(string(data))
		if request.Prompt == "" {
			return newUsageError("missing --prompt TEXT, --prompt-file PATH, or stdin input", scheduleActionUsageText("create"))
		}
	}
	ctx, c, err := connect()
	if err != nil {
		return err
	}
	defer c.Close()
	var result api.Schedule
	if err := c.Request(ctx, "schedule.create", request, &result); err != nil {
		return err
	}
	return printValue(result)
}

// ScheduleRow is a Schedule as `schedule list` shows it.
type ScheduleRow struct {
	api.Schedule
}

func scheduleList(params map[string]any) error {
	limit, err := listLimit(params)
	if err != nil {
		return newUsageError(err.Error(), scheduleActionUsageText("list"))
	}
	state := strings.ToLower(strings.TrimSpace(stringValue(params, "state")))
	switch state {
	case "", api.ScheduleStateActive, api.ScheduleStatePaused, api.ScheduleStateCompleted:
	default:
		return newUsageError("--state must be active, paused, or completed", scheduleActionUsageText("list"))
	}
	ctx, c, err := connect()
	if err != nil {
		return err
	}
	defer c.Close()
	var schedules []api.Schedule
	if err := c.Request(ctx, "schedule.list", map[string]any{}, &schedules); err != nil {
		return err
	}
	rows := filterScheduleRows(schedules, state, stringValue(params, "agent"), stringValue(params, "workspace"), stringValue(params, "search"))
	return printValue(limitListRows(rows, limit))
}

func filterScheduleRows(schedules []api.Schedule, state, agentID, workspaceID, search string) []ScheduleRow {
	search = strings.ToLower(strings.TrimSpace(search))
	rows := make([]ScheduleRow, 0, len(schedules))
	for _, value := range schedules {
		if state != "" && value.State != state {
			continue
		}
		if agentID != "" && value.Action.Agent != agentID {
			continue
		}
		if workspaceID != "" && value.Action.Workspace != workspaceID {
			continue
		}
		if search != "" {
			haystack := strings.ToLower(strings.Join([]string{
				value.ID, value.Name, value.Cron, value.Action.Agent, value.Action.Workspace,
				value.Action.Command, value.Action.Prompt, value.Action.PromptFile,
			}, "\n"))
			if !strings.Contains(haystack, search) {
				continue
			}
		}
		rows = append(rows, ScheduleRow{Schedule: value})
	}
	return rows
}

func scheduleRuns(id string, params map[string]any) error {
	limit, err := listLimit(params)
	if err != nil {
		return newUsageError(err.Error(), scheduleActionUsageText("runs"))
	}
	ctx, c, err := connect()
	if err != nil {
		return err
	}
	defer c.Close()
	var runs []api.ScheduleRun
	if err := c.Request(ctx, "schedule.runs", map[string]any{"id": id, "limit": limit}, &runs); err != nil {
		return err
	}
	return printValue(runs)
}

func scheduleWhen(value api.Schedule) string {
	if value.At != nil {
		return "at " + formatTime(*value.At)
	}
	return value.Cron
}

func scheduleActionSummary(action api.ScheduleAction) string {
	switch action.Kind {
	case api.ScheduleActionAgent:
		return "agent " + action.Agent
	case api.ScheduleActionNewAgent:
		return "new " + action.Provider + " agent in " + action.Workspace
	}
	return "command in " + action.Workspace
}

func scheduleLastResult(value api.Schedule) string {
	if value.LastRun == nil {
		return "-"
	}
	return value.LastRun.Status + " " + formatTime(value.LastRun.StartedAt)
}

func scheduleRowCells(item ScheduleRow) []string {
	return []string{
		item.ID,
		displayTruncated(item.Name, 25),
		item.State,
		displayTruncated(scheduleWhen(item.Schedule), 20),
		formatOptionalTime(item.NextRunAt),
		formatOptionalTime(item.Until),
		strconv.Itoa(item.RunCount),
		displayTruncated(scheduleLastResult(item.Schedule), 28),
		displayTruncated(scheduleActionSummary(item.Action), 46),
	}
}

func schedulePairs(value api.Schedule) [][2]string {
	maxRuns := "-"
	if value.MaxRuns > 0 {
		maxRuns = strconv.Itoa(value.MaxRuns)
	}
	pairs := [][2]string{
		{"ID", value.ID},
		{"NAME", value.Name},
		{"STATE", value.State},
		{"END REASON", displayValue(value.EndReason)},
		{"WHEN", scheduleWhen(value)},
		{"TIME ZONE", displayValue(value.TimeZone)},
		{"UNTIL", formatOptionalTime(value.Until)},
		{"MAX RUNS", maxRuns},
		{"RUNS", strconv.Itoa(value.RunCount)},
		{"NEXT RUN", formatOptionalTime(value.NextRunAt)},
		{"ACTION", value.Action.Kind},
	}
	if value.Action.Kind == api.ScheduleActionAgent || value.Action.Kind == api.ScheduleActionNewAgent {
		if value.Action.Kind == api.ScheduleActionAgent {
			pairs = append(pairs, [2]string{"AGENT", value.Action.Agent})
		} else {
			keep := "all"
			if value.Action.Keep > 0 {
				keep = "newest " + strconv.Itoa(value.Action.Keep)
			}
			pairs = append(pairs,
				[2]string{"WORKSPACE", value.Action.Workspace},
				[2]string{"PROVIDER", value.Action.Provider},
				[2]string{"COMMAND", value.Action.Command},
				[2]string{"KEEP AGENTS", keep},
			)
		}
		pairs = append(pairs,
			[2]string{"PROMPT", displayTruncated(value.Action.Prompt, 80)},
			[2]string{"PROMPT FILE", displayValue(value.Action.PromptFile)},
			[2]string{"WHEN BUSY", value.Action.WhenBusy},
			[2]string{"BUSY TIMEOUT", displayValue(value.Action.BusyTimeout)},
		)
	} else {
		pairs = append(pairs,
			[2]string{"WORKSPACE", value.Action.Workspace},
			[2]string{"COMMAND", value.Action.Command},
		)
	}
	pairs = append(pairs, [2]string{"LAST RUN", scheduleLastResult(value)})
	if value.LastRun != nil && value.LastRun.Error != "" {
		pairs = append(pairs, [2]string{"LAST ERROR", value.LastRun.Error})
	}
	return append(pairs, [2]string{"CREATED AT", formatTime(value.CreatedAt)})
}

func scheduleRunCells(run api.ScheduleRun) []string {
	exit := "-"
	if run.ExitCode != nil {
		exit = strconv.Itoa(*run.ExitCode)
	}
	return []string{
		run.ID,
		run.Trigger,
		formatTime(run.ScheduledAt),
		formatTime(run.StartedAt),
		formatOptionalTime(run.FinishedAt),
		run.Status,
		displayTruncated(run.Session, 36),
		exit,
		displayTruncated(run.Error, 60),
	}
}

func scheduleRunPairs(run api.ScheduleRun) [][2]string {
	return [][2]string{
		{"ID", run.ID},
		{"SCHEDULE", run.ScheduleID},
		{"TRIGGER", run.Trigger},
		{"STATUS", run.Status},
		{"SESSION", displayValue(run.Session)},
		{"STARTED AT", formatTime(run.StartedAt)},
	}
}

func scheduleUsageText() string {
	return `Usage:
  warren schedule create|list|view|remove|pause|resume|run|runs

Host-owned timers. The Warren daemon keeps them in schedules.json beside its
state, fires them in the Host's local time zone, and keeps firing after a
restart; no CLI process has to stay running.

Commands:
  create   add a schedule (see 'warren schedule create --help')
  list     list schedules (10 rows by default)
  view     show one schedule and its last run (alias: get)
  remove   delete a schedule and its run history (alias: delete)
  pause    stop firing until resumed
  resume   fire again from the next occurrence; skipped occurrences are not replayed
  run      run once now; does not count toward --max-runs (alias: run-now)
  runs     show recent runs, newest first

Examples:
  warren schedule create --name gray-check --cron "47 10 * * *" --until 2026-10-30 \
    --agent AGENT_ID --prompt-file '~/.warren/schedules/gray-check.prompt'
  warren schedule create --name nightly-review --cron "0 2 * * *" --keep 7 \
    --workspace WORKSPACE_ID --provider claude --prompt "Review yesterday's commits"
`
}

func scheduleActionUsageText(action string) string {
	switch action {
	case "create":
		return `Usage:
  warren schedule create (--cron EXPRESSION | --at TIME) [--until TIME] [--max-runs N] [--name NAME]
      --agent AGENT_ID [--prompt TEXT | --prompt-file PATH] [--when-busy wait|skip] [--busy-timeout DURATION]
  warren schedule create (--cron EXPRESSION | --at TIME) [--until TIME] [--max-runs N] [--name NAME]
      --workspace WORKSPACE_ID --provider PROVIDER [--command EXECUTABLE]
      [--prompt TEXT | --prompt-file PATH] [--when-busy wait|skip] [--busy-timeout DURATION] [--keep N]
  warren schedule create (--cron EXPRESSION | --at TIME) [--until TIME] [--max-runs N] [--name NAME]
      --workspace WORKSPACE_ID --command COMMAND

Timing (Host local time zone):
  --cron         five fields: minute hour day-of-month month day-of-week,
                 or @hourly, @daily, @weekly, @monthly, @yearly
  --at           run once, e.g. "2026-10-24 10:47"
  --until        stop after this time; a bare date such as 2026-10-30 includes that whole day
  --max-runs     stop after N scheduled runs
  A run missed while the Host was down or asleep runs once when it is back.

Agent action (one Agent turn, like 'warren agent send'):
  --prompt       literal prompt text; with neither --prompt nor --prompt-file, stdin is read once now
  --prompt-file  a file on the Host, read at each run; ~ is the Host user's home
  --when-busy    wait (default): hold the prompt until the Agent's current turn ends;
                 a newer occurrence replaces a prompt still held
                 skip: record the run as skipped
  --busy-timeout fail a held prompt after this long, e.g. 2h (default: no limit)
  A missing or ended Agent fails the run; the failure is kept in 'schedule runs'.

New-agent action (a new Agent per run, like 'warren agent create --prompt'):
  --provider     codex, claude, opencode, pi, qoder, or antigravity
  --command      the provider executable and options, as in 'agent create' (default: the provider)
  The prompt is the Agent's first turn and is read at each run. The run stays
  running until that turn ends, then records succeeded or failed. The Agent is
  titled "NAME MM-DD HH:MM" and stays open for follow-up turns.
  --when-busy    wait (default): start only after the previous run's first turn ends
                 skip: record the run as skipped while the previous run is open
  --busy-timeout fail a run that waited this long for the previous one
  --keep         after each run, remove the Agents of older runs beyond the newest N;
                 pinned and working Agents are kept (default: keep every Agent)

Command action:
  --command      run through /bin/sh as a new shell Session in the Workspace; the run
                 records the Session ID and exit status
`
	case "list":
		return `Usage:
  warren schedule list [--state active|paused|completed] [--agent AGENT_ID] [--workspace WORKSPACE_ID]
      [--search TEXT] [--limit N | --all]

Shows up to 10 schedules by default. -q prints IDs; --json prints the full objects.
`
	case "runs":
		return `Usage:
  warren schedule runs SCHEDULE_ID [--limit N | --all]

Shows the newest 10 runs by default: when each was due and started, its status
(waiting, running, succeeded, failed, skipped), the Session it targeted, and any error.
The Host keeps the last 50 finished runs per schedule.
`
	case "view":
		return "Usage:\n  warren schedule view SCHEDULE_ID\n"
	case "remove":
		return "Usage:\n  warren schedule remove SCHEDULE_ID\n\nA prompt the schedule is holding for a busy Agent is dropped.\n"
	case "pause":
		return "Usage:\n  warren schedule pause SCHEDULE_ID\n"
	case "resume":
		return "Usage:\n  warren schedule resume SCHEDULE_ID\n"
	case "run":
		return "Usage:\n  warren schedule run SCHEDULE_ID\n\nStarts one run now and prints it; follow it with 'warren schedule runs'.\n"
	}
	return scheduleUsageText()
}
