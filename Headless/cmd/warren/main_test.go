package main

import (
	"encoding/json"
	"errors"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/agent"
	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/config"
)

func TestSessionRowsJoinsWorkspaceAndProject(t *testing.T) {
	now := time.Now().UTC()
	state := api.State{
		Projects: []api.Project{{
			ID:   "project-1",
			Name: "warren",
			Path: "/srv/warren",
		}},
		Workspaces: []api.Workspace{{
			ID:        "workspace-1",
			ProjectID: "project-1",
			Name:      "release/feature",
			Path:      "/srv/warren/.worktrees/feature",
			Branch:    "release/feature",
		}},
		Sessions: []api.Session{{
			ID:          "session-1",
			WorkspaceID: "workspace-1",
			Title:       "Codex",
			Kind:        "codex",
			Command:     "codex",
			Lifecycle:   "running",
			CreatedAt:   now,
		}},
	}

	rows := sessionRows(state, false, false)
	if len(rows) != 1 {
		t.Fatalf("rows = %d, want 1", len(rows))
	}
	row := rows[0]
	if row.ProjectID != "project-1" || row.ProjectName != "warren" {
		t.Errorf("project = %q/%q, want project-1/warren", row.ProjectID, row.ProjectName)
	}
	if row.WorkspaceName != "release/feature" {
		t.Errorf("workspace name = %q, want release/feature", row.WorkspaceName)
	}
	if row.Branch != "release/feature" || row.Path != "/srv/warren/.worktrees/feature" {
		t.Errorf("branch/path = %q/%q, want release/feature//srv/warren/.worktrees/feature", row.Branch, row.Path)
	}
	if row.Session.ID != "session-1" || row.Title != "Codex" {
		t.Errorf("embedded session lost: %+v", row.Session)
	}
}

func TestTerminalGroupAliasAndSessionCreateParams(t *testing.T) {
	if got := canonicalResource("group"); got != "terminal-group" {
		t.Fatalf("group alias = %q, want terminal-group", got)
	}
	if !knownResourceAction("terminal-group", "home") {
		t.Fatal("terminal-group home action is not registered")
	}
	if !knownResourceAction("session", "move") {
		t.Fatal("session move action is not registered")
	}
	params := normalizedParams(parseFlags([]string{"--group", "group-1", "--kind", "shell"}), "session", "create")
	if params["group"] != "group-1" {
		t.Fatalf("normalized group = %#v", params["group"])
	}
	if _, ok := params["workspace"]; ok {
		t.Fatalf("group session unexpectedly has workspace: %#v", params)
	}
	defaultParams := normalizedParams(parseFlags(nil), "session", "create")
	if _, ok := defaultParams["workspace"]; ok {
		t.Fatalf("default session unexpectedly has workspace: %#v", defaultParams)
	}
}

func TestProjectAddNormalizesAutomaticWorktreeImportFlag(t *testing.T) {
	params := normalizedParams(parseFlags([]string{
		"/srv/repository", "--auto-import-worktrees",
	}), "project", "add")
	if params["path"] != "/srv/repository" {
		t.Fatalf("project path = %#v", params["path"])
	}
	if !boolValue(params, "autoImportGitWorktrees") {
		t.Fatalf("automatic import flag = %#v, want true", params["autoImportGitWorktrees"])
	}
	if _, ok := params["auto-import-worktrees"]; ok {
		t.Fatalf("kebab-case flag leaked into request: %#v", params)
	}
}

func TestSessionRowsJoinsTerminalGroup(t *testing.T) {
	state := api.State{
		TerminalGroups: []api.TerminalGroup{{ID: "group-1", Name: "Inbox", Home: "/home/test"}},
		Sessions: []api.Session{{
			ID: "session-1", TerminalGroupID: "group-1", Scope: api.SessionScopeTerminalGroup,
			Title: "Shell", Kind: "shell", Lifecycle: "running",
		}},
	}
	rows := sessionRows(state, false, false)
	if len(rows) != 1 {
		t.Fatalf("rows = %d, want 1", len(rows))
	}
	if rows[0].TerminalGroupName != "Inbox" || rows[0].Path != "/home/test" {
		t.Fatalf("group context = %#v", rows[0])
	}
}

func TestSessionCreateRejectsWorkspaceAndGroupTogether(t *testing.T) {
	err := run([]string{"session", "create", "workspace-1", "--group", "group-1"})
	var usageErr *usageError
	if !errors.As(err, &usageErr) {
		t.Fatalf("error = %v, want *usageError", err)
	}
	if usageErr.message != "workspace and --group are mutually exclusive" {
		t.Fatalf("message = %q", usageErr.message)
	}
}

func TestSessionMoveValidatesTargetFlag(t *testing.T) {
	tests := []struct {
		name string
		args []string
		want string
	}{
		{
			name: "missing target",
			args: []string{"session", "move", "session-1"},
			want: "missing --workspace WORKSPACE_ID or --group GROUP_ID",
		},
		{
			name: "conflicting targets",
			args: []string{"session", "move", "session-1", "--workspace", "workspace-1", "--group", "group-1"},
			want: "--workspace and --group are mutually exclusive",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			err := run(test.args)
			var usageErr *usageError
			if !errors.As(err, &usageErr) {
				t.Fatalf("error = %v, want *usageError", err)
			}
			if usageErr.message != test.want {
				t.Fatalf("message = %q, want %q", usageErr.message, test.want)
			}
		})
	}
}

func TestSessionMoveNormalizesParams(t *testing.T) {
	params := normalizedParams(parseFlags([]string{
		"session-1", "--workspace", "workspace-1",
	}), "session", "move")
	if params["id"] != "session-1" || params["workspace"] != "workspace-1" {
		t.Fatalf("normalized params = %#v", params)
	}
	groupParams := normalizedParams(parseFlags([]string{
		"session-1", "--group", "group-1",
	}), "session", "move")
	if groupParams["id"] != "session-1" || groupParams["group"] != "group-1" {
		t.Fatalf("normalized group params = %#v", groupParams)
	}
}

func TestCurrentSessionIDUsesOnlyWarrenBinding(t *testing.T) {
	t.Setenv(agent.BindEnvSession, "session-current")
	if got, err := currentSessionID(); err != nil || got != "session-current" {
		t.Fatalf("currentSessionID = %q, %v; want session-current", got, err)
	}
	t.Setenv(agent.BindEnvSession, "")
	if _, err := currentSessionID(); err == nil || !strings.Contains(err.Error(), agent.BindEnvSession) {
		t.Fatalf("missing binding error = %v, want WARREN_SESSION_ID guidance", err)
	}
}

func TestSessionRowsMarkCurrentAndExposeDistinctAgentFields(t *testing.T) {
	state := api.State{Sessions: []api.Session{{
		ID: "warren-session", AgentSessionID: "codex-thread", TranscriptPath: "/tmp/transcript.jsonl",
		Title: "Codex", Kind: "codex", Lifecycle: "running",
	}}}
	rows := sessionRowsForCurrent(state, false, false, "warren-session")
	if len(rows) != 1 || !rows[0].Current || rows[0].WarrenSessionID != "warren-session" || rows[0].AgentThreadID != "codex-thread" {
		t.Fatalf("current row = %#v", rows)
	}
	data, err := json.Marshal(rows[0])
	if err != nil {
		t.Fatal(err)
	}
	for _, field := range []string{`"warrenSessionId":"warren-session"`, `"agentThreadId":"codex-thread"`, `"agentSessionId":"codex-thread"`, `"transcriptPath":"/tmp/transcript.jsonl"`, `"current":true`} {
		if !strings.Contains(string(data), field) {
			t.Fatalf("row JSON %s missing from %s", field, data)
		}
	}
}

func TestSessionMoveCurrentRequiresBindingBeforeEndpoint(t *testing.T) {
	t.Setenv(agent.BindEnvSession, "")
	err := run([]string{"session", "move", "--current", "--workspace", "workspace-1"})
	if err == nil || !strings.Contains(err.Error(), agent.BindEnvSession) {
		t.Fatalf("error = %v, want missing WARREN_SESSION_ID", err)
	}
}

func TestSessionMoveExpectedContextNormalizes(t *testing.T) {
	params := normalizedParams(parseFlags([]string{
		"session-1", "--workspace", "workspace-1", "--expected-workspace", "workspace-old", "--expected-agent-session", "thread-1",
	}), "session", "move")
	if params["expectedWorkspace"] != "workspace-old" || params["expectedAgentSession"] != "thread-1" {
		t.Fatalf("expected context = %#v", params)
	}
}

func TestSessionMoveExplicitIDRequiresIntent(t *testing.T) {
	err := run([]string{"session", "move", "session-1", "--workspace", "workspace-1"})
	var usageErr *usageError
	if !errors.As(err, &usageErr) || !strings.Contains(usageErr.message, "requires --confirm") {
		t.Fatalf("error = %v, want explicit intent usage error", err)
	}
	// --dry-run is an explicit preflight intent and should get as far as
	// endpoint resolution rather than failing the local safety check.
	err = run([]string{"session", "move", "session-1", "--workspace", "workspace-1", "--dry-run"})
	if errors.As(err, &usageErr) {
		t.Fatalf("dry-run unexpectedly returned usage error: %v", err)
	}
}

func TestEffectiveSessionTitlePrefersCustomTitle(t *testing.T) {
	session := api.Session{Title: "Shell", CustomTitle: "My Shell"}
	if got := effectiveSessionTitle(session); got != "My Shell" {
		t.Fatalf("effective title with custom = %q, want My Shell", got)
	}
	session.CustomTitle = "   "
	if got := effectiveSessionTitle(session); got != "Shell" {
		t.Fatalf("effective title with blank custom = %q, want Shell", got)
	}

	rows := sessionRows(api.State{Sessions: []api.Session{{
		ID: "session-1", Title: "Shell", CustomTitle: "My Shell",
		Kind: "shell", Lifecycle: "running",
	}}}, false, false)
	if got := sessionRowCells(rows[0])[5]; got != "My Shell" {
		t.Fatalf("session list title cell = %q, want My Shell", got)
	}
}

func TestParseFlagsBareBooleanDoesNotConsumePositional(t *testing.T) {
	params := parseFlags([]string{"session-1", "--raw", "hello world"})
	if !boolValue(params, "raw") {
		t.Fatalf("raw = false, want true")
	}
	positions := positionals(params)
	if len(positions) != 2 || positions[0] != "session-1" || positions[1] != "hello world" {
		t.Fatalf("positionals = %q, want [session-1 hello world]", positions)
	}
}

func TestParseFlagsBooleanWithExplicitValueStillConsumes(t *testing.T) {
	params := parseFlags([]string{"session-1", "--pinned", "true"})
	if stringValue(params, "pinned") != "true" {
		t.Fatalf("pinned = %q, want true", stringValue(params, "pinned"))
	}
	positions := positionals(params)
	if len(positions) != 1 || positions[0] != "session-1" {
		t.Fatalf("positionals = %q, want [session-1]", positions)
	}
}

func TestParseFlagsBooleanEqualsStillWorks(t *testing.T) {
	params := parseFlags([]string{"session-1", "--raw=true", "hello world"})
	if !boolValue(params, "raw") {
		t.Fatalf("raw = false, want true")
	}
	positions := positionals(params)
	if len(positions) != 2 || positions[1] != "hello world" {
		t.Fatalf("positionals = %q, want [session-1 hello world]", positions)
	}
}

func TestCollectAgentTypeFlagsPreservesRepeatedValues(t *testing.T) {
	values := collectAgentTypeFlags([]string{
		"codex",
		"--include", "user,assistant",
		"--include=tool_call",
		"--filter", "usage",
	}, "include")
	if got, want := strings.Join(values, ","), "user,assistant,tool_call"; got != want {
		t.Fatalf("include values = %q, want %q", got, want)
	}
	filters := collectAgentTypeFlags([]string{"--filter", "usage", "--exclude=attachment"}, "filter", "exclude")
	if got, want := strings.Join(filters, ","), "usage,attachment"; got != want {
		t.Fatalf("filter values = %q, want %q", got, want)
	}
}

func TestValidateAgentReadArgs(t *testing.T) {
	tests := []struct {
		name string
		args []string
		want string
	}{
		{name: "all and recent", args: []string{"codex", "--all", "--recent", "10"}, want: "--all cannot"},
		{name: "full and chars", args: []string{"codex", "--full", "--chars", "10"}, want: "--full cannot"},
		{name: "unknown flag", args: []string{"codex", "--recnet", "10"}, want: "unknown flag"},
		{name: "missing value", args: []string{"codex", "--workspace"}, want: "requires a value"},
		{name: "missing include value", args: []string{"codex", "--include", "--all"}, want: "requires a value"},
		{name: "short flag", args: []string{"codex", "-v"}, want: "unknown flag"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if _, err := validateAgentReadArgs(test.args); err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("validate(%q) = %v, want error containing %q", test.args, err, test.want)
			}
		})
	}
	if help, err := validateAgentReadArgs([]string{"-h"}); err != nil || !help {
		t.Fatalf("validate -h = help %v, err %v; want help", help, err)
	}
}

func TestValidateAgentWaitArgs(t *testing.T) {
	if help, err := validateAgentWaitArgs([]string{"--help"}); err != nil || !help {
		t.Fatalf("validate help = %v, %v; want true, nil", help, err)
	}
	if _, err := validateAgentWaitArgs([]string{"session-1", "--timeout"}); err == nil || !strings.Contains(err.Error(), "requires a value") {
		t.Fatalf("missing timeout error = %v", err)
	}
	if _, err := validateAgentWaitArgs([]string{"session-1", "--callback", "echo nope"}); err == nil || !strings.Contains(err.Error(), "unknown flag") {
		t.Fatalf("callback error = %v", err)
	}
}

func TestAgentWaitTimeout(t *testing.T) {
	if got, err := agentWaitTimeout(parseFlags(nil)); err != nil || got != defaultAgentWaitTimeout {
		t.Fatalf("default timeout = %s, %v", got, err)
	}
	if got, err := agentWaitTimeout(parseFlags([]string{"--timeout", "45s"})); err != nil || got != 45*time.Second {
		t.Fatalf("explicit timeout = %s, %v", got, err)
	}
	if _, err := agentWaitTimeout(parseFlags([]string{"--timeout", "never"})); err == nil {
		t.Fatal("invalid timeout succeeded")
	}
	if _, err := agentWaitTimeout(parseFlags([]string{"--timeout"})); err == nil || !strings.Contains(err.Error(), "requires a value") {
		t.Fatalf("missing timeout error = %v", err)
	}
}

func TestValidateAgentSendWaitRejectsRunningTurn(t *testing.T) {
	if err := validateAgentSendWait(api.AgentSnapshotResult{
		Turn: api.AgentTurn{ID: 2, Status: api.AgentTurnStarted},
	}); err == nil || !strings.Contains(err.Error(), "already has a running turn") {
		t.Fatalf("running turn error = %v", err)
	}
	if err := validateAgentSendWait(api.AgentSnapshotResult{
		Turn: api.AgentTurn{ID: 2, Status: api.AgentTurnCompleted},
	}); err != nil {
		t.Fatalf("completed baseline rejected: %v", err)
	}
}

func TestAgentWaitCursorJoinsRunningOrJustCompletedTurn(t *testing.T) {
	after, current := agentWaitCursor(api.AgentSnapshotResult{
		Turn: api.AgentTurn{ID: 4, Status: api.AgentTurnStarted},
	})
	if after != 4 || current != 4 {
		t.Fatalf("running cursor = after %d current %d, want 4 and 4", after, current)
	}
	after, current = agentWaitCursor(api.AgentSnapshotResult{
		Turn: api.AgentTurn{ID: 4, Status: api.AgentTurnCompleted},
	})
	if after != 3 || current != 0 {
		t.Fatalf("completed cursor = after %d current %d, want 3 and 0", after, current)
	}
	after, current = agentWaitCursor(api.AgentSnapshotResult{
		Turn: api.AgentTurn{Status: api.AgentTurnIdle},
	})
	if after != 0 || current != 0 {
		t.Fatalf("idle cursor = after %d current %d, want zeroes", after, current)
	}
}

func TestSessionRowsKeepsOrphanSessionUsable(t *testing.T) {
	state := api.State{
		Sessions: []api.Session{{
			ID:          "session-1",
			WorkspaceID: "missing-workspace",
			Title:       "Shell",
			Kind:        "shell",
			Lifecycle:   "running",
		}},
	}

	rows := sessionRows(state, false, false)
	if len(rows) != 1 {
		t.Fatalf("rows = %d, want 1", len(rows))
	}
	row := rows[0]
	if row.ProjectName != "" || row.WorkspaceName != "" || row.Branch != "" {
		t.Errorf("orphan row should stay empty, got %+v", row)
	}
	if row.Session.ID != "session-1" {
		t.Errorf("session id = %q, want session-1", row.Session.ID)
	}
}

func TestProjectRowsCountWorkspaces(t *testing.T) {
	state := api.State{
		Projects: []api.Project{
			{ID: "project-1", Name: "warren", Path: "/srv/warren"},
			{ID: "project-2", Name: "empty", Path: "/srv/empty"},
		},
		Workspaces: []api.Workspace{
			{ID: "workspace-1", ProjectID: "project-1"},
			{ID: "workspace-2", ProjectID: "project-1"},
		},
	}

	rows := projectRows(state)
	if len(rows) != 2 {
		t.Fatalf("rows = %d, want 2", len(rows))
	}
	if rows[0].ID != "project-1" || rows[0].Workspaces != 2 {
		t.Errorf("project-1 rows = %d, want 2 (id %q)", rows[0].Workspaces, rows[0].ID)
	}
	if rows[1].ID != "project-2" || rows[1].Workspaces != 0 {
		t.Errorf("project-2 rows = %d, want 0 (id %q)", rows[1].Workspaces, rows[1].ID)
	}
}

func TestWorkspaceRowsJoinProjectAndCountRunningSessions(t *testing.T) {
	now := time.Now().UTC()
	state := api.State{
		Projects: []api.Project{{
			ID:   "project-1",
			Name: "warren",
			Path: "/srv/warren",
		}},
		Workspaces: []api.Workspace{{
			ID:         "workspace-1",
			ProjectID:  "project-1",
			Name:       "release/feature",
			Path:       "/srv/warren/.worktrees/feature",
			Branch:     "release/feature",
			Kind:       "worktree",
			CreatedAt:  now,
			MergeState: api.MergeStateMerged,
		}},
		Sessions: []api.Session{
			{ID: "session-1", WorkspaceID: "workspace-1", Lifecycle: "running", CreatedAt: now},
			{ID: "session-2", WorkspaceID: "workspace-1", Lifecycle: "exited", CreatedAt: now},
			{ID: "session-3", WorkspaceID: "missing", Lifecycle: "running", CreatedAt: now},
		},
	}

	rows := workspaceRows(state)
	if len(rows) != 1 {
		t.Fatalf("rows = %d, want 1", len(rows))
	}
	row := rows[0]
	if row.ProjectName != "warren" {
		t.Errorf("project name = %q, want warren", row.ProjectName)
	}
	if row.Sessions != 1 {
		t.Errorf("running sessions = %d, want 1", row.Sessions)
	}
	if row.Workspace.ID != "workspace-1" || row.Kind != "worktree" {
		t.Errorf("embedded workspace lost: %+v", row.Workspace)
	}
	if row.MergeState != api.MergeStateMerged {
		t.Errorf("merge state = %q, want merged", row.MergeState)
	}
}

func TestDisplayMergeState(t *testing.T) {
	if got := displayMergeState(api.MergeStateMerged); got != "merged" {
		t.Errorf("displayMergeState(merged) = %q, want merged", got)
	}
	if got := displayMergeState(api.MergeStateUnmerged); got != "" {
		t.Errorf("displayMergeState(unmerged) = %q, want empty", got)
	}
	if got := displayMergeState(""); got != "" {
		t.Errorf("displayMergeState(unknown) = %q, want empty", got)
	}
}

func TestSessionRowsHideEndedByDefault(t *testing.T) {
	now := time.Now().UTC()
	endedAt := now.Add(-time.Hour)
	state := api.State{
		Sessions: []api.Session{
			{ID: "session-running", WorkspaceID: "workspace-1", Lifecycle: "running", CreatedAt: now},
			{ID: "session-ended", WorkspaceID: "workspace-1", Lifecycle: "ended", EndedAt: &endedAt, CreatedAt: now},
		},
	}

	rows := sessionRows(state, false, false)
	if len(rows) != 1 {
		t.Fatalf("rows = %d, want 1 (default hides ended)", len(rows))
	}
	if rows[0].ID != "session-running" {
		t.Errorf("row id = %q, want session-running", rows[0].ID)
	}
}

func TestSessionRowsAllIncludesEnded(t *testing.T) {
	now := time.Now().UTC()
	endedAt := now.Add(-time.Hour)
	state := api.State{
		Sessions: []api.Session{
			{ID: "session-running", WorkspaceID: "workspace-1", Lifecycle: "running", CreatedAt: now},
			{ID: "session-ended", WorkspaceID: "workspace-1", Lifecycle: "ended", EndedAt: &endedAt, CreatedAt: now},
		},
	}

	rows := sessionRows(state, true, false)
	if len(rows) != 2 {
		t.Fatalf("rows = %d, want 2 (--all includes ended)", len(rows))
	}
}

func TestSessionRowsEndedOnly(t *testing.T) {
	now := time.Now().UTC()
	endedAt := now.Add(-time.Hour)
	state := api.State{
		Sessions: []api.Session{
			{ID: "session-running", WorkspaceID: "workspace-1", Lifecycle: "running", CreatedAt: now},
			{ID: "session-ended", WorkspaceID: "workspace-1", Lifecycle: "ended", EndedAt: &endedAt, CreatedAt: now},
		},
	}

	rows := sessionRows(state, false, true)
	if len(rows) != 1 {
		t.Fatalf("rows = %d, want 1 (--ended lists only ended)", len(rows))
	}
	if rows[0].ID != "session-ended" {
		t.Errorf("row id = %q, want session-ended", rows[0].ID)
	}
}

func TestHoistGlobalFlagsMovesFlagsFromAnyPosition(t *testing.T) {
	tests := []struct {
		name string
		args []string
		want []string
	}{
		{
			name: "json after subcommand",
			args: []string{"session", "list", "--json"},
			want: []string{"--json", "session", "list"},
		},
		{
			name: "json before subcommand",
			args: []string{"--json", "session", "list"},
			want: []string{"--json", "session", "list"},
		},
		{
			name: "value flag mixed with json",
			args: []string{"session", "list", "--endpoint", "vps", "--json"},
			want: []string{"--endpoint", "vps", "--json", "session", "list"},
		},
		{
			name: "equals form is preserved",
			args: []string{"session", "list", "--config=/tmp/cfg.json", "--json=false"},
			want: []string{"--config=/tmp/cfg.json", "--json=false", "session", "list"},
		},
		{
			name: "headless flags are untouched",
			args: []string{"headless", "--name", "host-a"},
			want: []string{"headless", "--name", "host-a"},
		},
		{
			name: "missing value stays for flag parser",
			args: []string{"session", "list", "--token"},
			want: []string{"session", "list", "--token"},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := hoistGlobalFlags(test.args); !reflect.DeepEqual(got, test.want) {
				t.Errorf("hoistGlobalFlags(%v) = %v, want %v", test.args, got, test.want)
			}
		})
	}
}

func TestHoistGlobalFlagsLeavesTokenForEndpointAdd(t *testing.T) {
	tests := []struct {
		name string
		args []string
		want []string
	}{
		{
			name: "endpoint add token stays local",
			args: []string{"endpoint", "add", "spike", "--url", "http://127.0.0.1:8789", "--token", "secret"},
			want: []string{"endpoint", "add", "spike", "--url", "http://127.0.0.1:8789", "--token", "secret"},
		},
		{
			name: "server alias also keeps token",
			args: []string{"server", "add", "spike", "--token=secret", "--url", "http://127.0.0.1:8789"},
			want: []string{"server", "add", "spike", "--token=secret", "--url", "http://127.0.0.1:8789"},
		},
		{
			name: "json still hoists for endpoint add",
			args: []string{"endpoint", "add", "spike", "--url", "http://127.0.0.1:8789", "--token", "secret", "--json"},
			want: []string{"--json", "endpoint", "add", "spike", "--url", "http://127.0.0.1:8789", "--token", "secret"},
		},
		{
			name: "config still hoists for endpoint add",
			args: []string{"--config", "/tmp/cfg.json", "endpoint", "add", "spike", "--token", "secret"},
			want: []string{"--config", "/tmp/cfg.json", "endpoint", "add", "spike", "--token", "secret"},
		},
		{
			name: "other commands still hoist token",
			args: []string{"session", "list", "--token", "secret"},
			want: []string{"--token", "secret", "session", "list"},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := hoistGlobalFlags(test.args); !reflect.DeepEqual(got, test.want) {
				t.Errorf("hoistGlobalFlags(%v) = %v, want %v", test.args, got, test.want)
			}
		})
	}
}

func TestEndpointAddKeepsTokenFlag(t *testing.T) {
	configPath = filepath.Join(t.TempDir(), "config.json")
	t.Cleanup(func() { configPath = config.DefaultPath() })

	if err := run([]string{
		"--config", configPath,
		"endpoint", "add", "spike",
		"--url", "http://127.0.0.1:8789",
		"--token", "secret",
	}); err != nil {
		t.Fatal(err)
	}
	settings, err := config.Load(configPath)
	if err != nil {
		t.Fatal(err)
	}
	endpoint, ok := settings.Endpoints["spike"]
	if !ok {
		t.Fatalf("endpoint spike not saved: %#v", settings.Endpoints)
	}
	if endpoint.Token != "secret" {
		t.Errorf("token = %q, want secret", endpoint.Token)
	}
}

func TestRunHelpExitsSuccessfully(t *testing.T) {
	for _, arguments := range [][]string{
		{"help"},
		{"-h"},
		{"--help"},
		{"workspace", "--help"},
		{"workspace", "-h"},
		{"worktree", "--help"},
		{"worktree", "-h"},
		{"project", "--help"},
		{"session", "--help"},
	} {
		if err := run(arguments); err != nil {
			t.Errorf("run(%v) = %v, want nil", arguments, err)
		}
	}
}

func TestRunResourceHelpDoesNotConnect(t *testing.T) {
	// These commands must not reach connect(); validation and help happen
	// before any server dial, so they succeed even without an endpoint.
	for _, arguments := range [][]string{
		{"workspace", "create", "--help"},
		{"worktree", "create", "--help"},
		{"session", "attach", "--help"},
	} {
		if err := run(arguments); err != nil {
			t.Errorf("run(%v) = %v, want nil", arguments, err)
		}
	}
}

func TestRunMissingArgumentsReturnUsageError(t *testing.T) {
	tests := []struct {
		arguments []string
		message   string
		usage     string
	}{
		{[]string{"workspace", "create"}, "missing PROJECT_ID", "warren workspace create PROJECT_ID"},
		{[]string{"worktree", "create"}, "missing PROJECT_ID", "warren worktree create PROJECT_ID"},
		{[]string{"worktree", "create", "PROJECT_ID"}, "missing --branch BRANCH", "warren worktree create PROJECT_ID"},
		{[]string{"workspace"}, "workspace command is required", "warren workspace list"},
		{[]string{"session", "send"}, "missing SESSION_ID", "warren session send SESSION_ID"},
		{[]string{"endpoint", "add"}, "missing ENDPOINT_NAME", "warren endpoint add NAME"},
		{[]string{"ssh"}, "missing SSH_TARGET", "warren ssh USER@HOST"},
	}
	for _, test := range tests {
		err := run(test.arguments)
		var usageErr *usageError
		if !errors.As(err, &usageErr) {
			t.Errorf("run(%v) error = %v, want *usageError", test.arguments, err)
			continue
		}
		if usageErr.message != test.message {
			t.Errorf("run(%v) message = %q, want %q", test.arguments, usageErr.message, test.message)
		}
		if !contains(usageErr.text, test.usage) {
			t.Errorf("run(%v) usage = %q, want it to contain %q", test.arguments, usageErr.text, test.usage)
		}
	}
}

func TestRunUnsupportedActionUsesAliasInError(t *testing.T) {
	err := run([]string{"worktree", "bogus"})
	var usageErr *usageError
	if !errors.As(err, &usageErr) {
		t.Fatalf("error = %v, want *usageError", err)
	}
	if usageErr.message != "unsupported command: worktree bogus" {
		t.Errorf("message = %q, want %q", usageErr.message, "unsupported command: worktree bogus")
	}
	if !contains(usageErr.text, "warren worktree list") {
		t.Errorf("usage should use the typed alias, got %q", usageErr.text)
	}
}

func TestRunSessionListAllEndedMutuallyExclusive(t *testing.T) {
	err := run([]string{"session", "list", "--all", "--ended"})
	var usageErr *usageError
	if !errors.As(err, &usageErr) {
		t.Fatalf("error = %v, want *usageError", err)
	}
	if usageErr.message != "--all and --ended are mutually exclusive" {
		t.Errorf("message = %q", usageErr.message)
	}
	if !contains(usageErr.text, "warren session list [--all | --ended]") {
		t.Errorf("usage should mention --all/--ended, got %q", usageErr.text)
	}
}

func TestRunUnknownCommandReturnsUsageError(t *testing.T) {
	err := run([]string{"nope"})
	var usageErr *usageError
	if !errors.As(err, &usageErr) {
		t.Fatalf("error = %v, want *usageError", err)
	}
	if usageErr.message != "unknown command \"nope\"; run 'warren help'" {
		t.Errorf("message = %q", usageErr.message)
	}
}

func contains(text, substring string) bool {
	return strings.Contains(text, substring)
}
