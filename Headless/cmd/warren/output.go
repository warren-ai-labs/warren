package main

import (
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/config"
)

type sshHostRow struct {
	Name          string `json:"name"`
	Host          string `json:"host"`
	User          string `json:"user"`
	Port          int    `json:"port"`
	IdentityFiles int    `json:"identityFiles"`
	Error         string `json:"error,omitempty"`
}

func printValue(value any) error {
	if outputQuiet {
		switch items := value.(type) {
		case []TaskRow:
			for _, item := range items {
				fmt.Println(item.ID)
			}
			return nil
		case []sshHostRow:
			for _, item := range items {
				fmt.Println(item.Name)
			}
			return nil
		case []ProjectRow:
			for _, item := range items {
				fmt.Println(item.ID)
			}
			return nil
		case []WorkspaceRow:
			for _, item := range items {
				fmt.Println(item.ID)
			}
			return nil
		case []api.TerminalGroup:
			for _, item := range items {
				fmt.Println(item.ID)
			}
			return nil
		case []api.PaneGroup:
			for _, item := range items {
				fmt.Println(item.ID)
			}
			return nil
		case []SessionRow:
			for _, item := range items {
				fmt.Println(item.ID)
			}
			return nil
		case []BrowserRow:
			for _, item := range items {
				fmt.Println(item.ID)
			}
			return nil
		case api.BrowserSession:
			fmt.Println(items.ID)
			return nil
		case *api.BrowserSession:
			fmt.Println(items.ID)
			return nil
		case []ScreenPaneRow:
			for _, item := range items {
				fmt.Println(item.SessionID)
			}
			return nil
		case api.WorkspaceCreateResult:
			fmt.Println(items.ID)
			return nil
		case *api.WorkspaceCreateResult:
			fmt.Println(items.ID)
			return nil
		case api.Workspace:
			fmt.Println(items.ID)
			return nil
		case *api.Workspace:
			fmt.Println(items.ID)
			return nil
		case api.Project:
			fmt.Println(items.ID)
			return nil
		case *api.Project:
			fmt.Println(items.ID)
			return nil
		case api.Task:
			fmt.Println(items.ID)
			return nil
		case *api.Task:
			fmt.Println(items.ID)
			return nil
		case api.TerminalGroup:
			fmt.Println(items.ID)
			return nil
		case *api.TerminalGroup:
			fmt.Println(items.ID)
			return nil
		case api.Session:
			fmt.Println(items.ID)
			return nil
		case *api.Session:
			fmt.Println(items.ID)
			return nil
		case agentCreateResult:
			fmt.Println(items.Session.ID)
			return nil
		case *agentCreateResult:
			fmt.Println(items.Session.ID)
			return nil
		case currentSessionValue:
			fmt.Println(items.Session.ID)
			return nil
		}
	}
	if outputJSON {
		data, err := json.MarshalIndent(value, "", "  ")
		if err != nil {
			return err
		}
		fmt.Println(string(data))
		return nil
	}
	switch items := value.(type) {
	case []TaskRow:
		rows := make([][]string, 0, len(items))
		for _, item := range items {
			rows = append(rows, taskRowCells(item))
		}
		printTable([]string{"ID", "NAME", "SOURCE", "EXTERNAL ID", "URL", "WORKSPACES", "PINNED", "CREATED"}, rows...)
	case []sshHostRow:
		rows := make([][]string, 0, len(items))
		for _, item := range items {
			rows = append(rows, []string{
				displayTruncated(item.Name, 25),
				displayTruncated(item.User, 20),
				displayTruncated(item.Host, 30),
				func() string {
					if item.Port == 0 {
						return "-"
					}
					return strconv.Itoa(item.Port)
				}(),
				func() string {
					if item.Error != "" {
						return displayTruncated(item.Error, 30)
					}
					return strconv.Itoa(item.IdentityFiles)
				}(),
			})
		}
		printTable([]string{"NAME", "USER", "HOST", "PORT", "IDENTITIES / STATUS"}, rows...)
	case []ProjectRow:
		rows := make([][]string, 0, len(items))
		for _, item := range items {
			rows = append(rows, projectRowCells(item))
		}
		printTable([]string{"ID", "NAME", "PATH", "WORKSPACES", "PINNED", "CREATED"}, rows...)
	case []WorkspaceRow:
		rows := make([][]string, 0, len(items))
		for _, item := range items {
			rows = append(rows, workspaceRowCells(item))
		}
		printTable([]string{"ID", "PROJECT", "TASK", "NAME", "BRANCH", "MERGED", "PATH", "KIND", "SESSIONS", "PINNED", "CREATED"}, rows...)
	case []api.TerminalGroup:
		rows := make([][]string, 0, len(items))
		for _, item := range items {
			rows = append(rows, terminalGroupRowCells(item))
		}
		printTable([]string{"ID", "NAME", "HOME", "ORDER", "CREATED"}, rows...)
	case []api.PaneGroup:
		rows := make([][]string, 0, len(items))
		for _, item := range items {
			rows = append(rows, paneGroupRowCells(item))
		}
		printTable([]string{"ID", "SCOPE", "OWNER", "NAME", "PANES", "ORDER", "REVISION", "SESSIONS"}, rows...)
	case []SessionRow:
		rows := make([][]string, 0, len(items))
		for _, item := range items {
			rows = append(rows, sessionRowCells(item))
		}
		printTable([]string{"WARREN SESSION ID", "PROJECT", "WORKSPACE", "GROUP", "BRANCH", "TITLE", "CURRENT", "KIND", "COMMAND", "RUN", "CWD", "AGENT/THREAD ID", "TRANSCRIPT PATH", "LIFECYCLE", "ACTIVITY", "ENDED AT", "PINNED", "CREATED"}, rows...)
	case []ScreenPaneRow:
		rows := make([][]string, 0, len(items))
		for _, item := range items {
			rows = append(rows, screenPaneRowCells(item))
		}
		printTable([]string{"GROUP", "NAME", "PANE", "PANE ID", "WARREN SESSION ID", "TITLE", "REVISION", "SCREEN", "CURRENT"}, rows...)
	case []BrowserRow:
		rows := make([][]string, 0, len(items))
		for _, item := range items {
			rows = append(rows, browserRowCells(item))
		}
		printTable([]string{"SESSION ID", "TITLE", "WORKSPACE / GROUP", "LIFECYCLE", "CREATED"}, rows...)
	case api.WorkspaceCreateResult:
		printKVTable(workspaceCreateResultPairs(items))
	case *api.WorkspaceCreateResult:
		printKVTable(workspaceCreateResultPairs(*items))
	case api.Workspace:
		printKVTable(workspaceCreateResultPairs(api.WorkspaceCreateResult{Workspace: items, Created: true}))
	case *api.Workspace:
		printKVTable(workspaceCreateResultPairs(api.WorkspaceCreateResult{Workspace: *items, Created: true}))
	case api.Project:
		printKVTable(projectPairs(items))
	case *api.Project:
		printKVTable(projectPairs(*items))
	case api.Task:
		printKVTable(taskPairs(items))
	case *api.Task:
		printKVTable(taskPairs(*items))
	case api.TerminalGroup:
		printKVTable(terminalGroupPairs(items))
	case *api.TerminalGroup:
		printKVTable(terminalGroupPairs(*items))
	case api.Session:
		printKVTable(sessionPairs(items))
	case *api.Session:
		printKVTable(sessionPairs(*items))
	case agentCreateResult:
		printKVTable(agentCreatePairs(items))
	case *agentCreateResult:
		printKVTable(agentCreatePairs(*items))
	case currentSessionValue:
		printKVTable(currentSessionPairs(items))
	case *currentSessionValue:
		printKVTable(currentSessionPairs(*items))
	case api.SessionMovePreflight:
		printKVTable(sessionMovePreflightPairs(items))
	case *api.SessionMovePreflight:
		printKVTable(sessionMovePreflightPairs(*items))
	case config.Endpoint:
		printKVTable([][2]string{
			{"NAME", items.Name},
			{"TYPE", endpointType(items.Type)},
			{"URL", items.URL},
			{"HOST ID", displayValue(items.HostID)},
			{"ROUTE ID", displayValue(items.RouteID)},
			{"SSH", displayValue(items.SSH)},
		})
	case *config.Endpoint:
		printKVTable([][2]string{
			{"NAME", items.Name},
			{"TYPE", endpointType(items.Type)},
			{"URL", items.URL},
			{"HOST ID", displayValue(items.HostID)},
			{"ROUTE ID", displayValue(items.RouteID)},
			{"SSH", displayValue(items.SSH)},
		})
	case map[string]bool:
		printKVTable(boolMapPairs(items))
	case *map[string]bool:
		printKVTable(boolMapPairs(*items))
	case map[string]any:
		printKVTable(anyMapPairs(items))
	case *map[string]any:
		printKVTable(anyMapPairs(*items))
	default:
		data, _ := json.MarshalIndent(value, "", "  ")
		fmt.Println(string(data))
	}
	return nil
}

func taskRowCells(item TaskRow) []string {
	return []string{
		item.ID,
		displayTruncated(item.Name, 30),
		displayValue(item.Source),
		displayTruncated(item.ExternalID, 20),
		displayTruncated(item.URL, 35),
		strconv.Itoa(item.Workspaces),
		displayBool(item.Pinned),
		formatTime(item.CreatedAt),
	}
}

func projectRowCells(item ProjectRow) []string {
	return []string{
		item.ID,
		displayTruncated(item.Name, 25),
		displayTruncatedPath(item.Path, 40),
		strconv.Itoa(item.Workspaces),
		displayBool(item.Pinned),
		formatTime(item.CreatedAt),
	}
}

func workspaceRowCells(item WorkspaceRow) []string {
	return []string{
		item.ID,
		displayTruncated(item.ProjectName, 20),
		displayTruncated(item.TaskName, 20),
		displayTruncated(item.Name, 20),
		displayTruncated(item.Branch, 20),
		displayMergeState(item.MergeState),
		displayTruncatedPath(item.Path, 35),
		item.Kind,
		strconv.Itoa(item.Sessions),
		displayBool(item.Pinned),
		formatTime(item.CreatedAt),
	}
}

func taskPairs(value api.Task) [][2]string {
	return [][2]string{
		{"ID", value.ID},
		{"NAME", value.Name},
		{"SOURCE", displayValue(value.Source)},
		{"EXTERNAL ID", displayValue(value.ExternalID)},
		{"URL", displayValue(value.URL)},
		{"PINNED", displayBool(value.Pinned)},
		{"CREATED AT", formatTime(value.CreatedAt)},
	}
}

func displayMergeState(value api.MergeState) string {
	if value == api.MergeStateMerged {
		return "merged"
	}
	return ""
}

func terminalGroupRowCells(item api.TerminalGroup) []string {
	return []string{
		item.ID,
		displayTruncated(item.Name, 25),
		displayTruncatedPath(item.Home, 35),
		strconv.Itoa(item.Order),
		formatTime(item.CreatedAt),
	}
}

func sessionRowCells(item SessionRow) []string {
	return []string{
		item.ID,
		displayTruncated(item.ProjectName, 20),
		displayTruncated(item.WorkspaceName, 20),
		displayTruncated(item.TerminalGroupName, 20),
		displayTruncated(item.Branch, 20),
		displayTruncated(effectiveSessionTitle(item.Session), 30),
		displayBool(item.Current),
		item.Kind,
		displayTruncated(item.Command, 30),
		displayTruncated(sessionForegroundCommand(item.Session), 40),
		displayTruncated(item.Directory, 40),
		displayTruncated(item.AgentSessionID, 20),
		displayTruncatedPath(item.TranscriptPath, 30),
		item.Lifecycle,
		displayValue(sessionActivity(item.Session)),
		formatOptionalTime(item.EndedAt),
		displayBool(item.Pinned),
		formatTime(item.CreatedAt),
	}
}

// sessionForegroundCommand is the command line currently running in a Session,
// which is more useful than the fixed launch command once a shell has started
// something. It falls back to the foreground process name.
func sessionForegroundCommand(session api.Session) string {
	if value := strings.TrimSpace(session.CommandLine); value != "" {
		return value
	}
	return strings.TrimSpace(session.Process)
}

func workspaceCreateResultPairs(value api.WorkspaceCreateResult) [][2]string {
	pairs := [][2]string{
		{"ID", value.ID},
		{"PROJECT", value.ProjectID},
	}
	if value.TaskID != "" {
		pairs = append(pairs, [2]string{"TASK", value.TaskID})
	}
	return append(pairs, [][2]string{
		{"NAME", value.Name},
		{"BRANCH", displayValue(value.Branch)},
		{"PATH", value.Path},
		{"KIND", value.Kind},
		{"PINNED", displayBool(value.Pinned)},
		{"CREATED AT", formatTime(value.CreatedAt)},
		{"CREATED", displayBool(value.Created)},
		{"GIT WORKTREE", displayBool(value.GitWorktree)},
	}...)
}

func projectPairs(value api.Project) [][2]string {
	return [][2]string{
		{"ID", value.ID},
		{"NAME", value.Name},
		{"PATH", value.Path},
		{"PINNED", displayBool(value.Pinned)},
		{"CREATED AT", formatTime(value.CreatedAt)},
	}
}

func terminalGroupPairs(value api.TerminalGroup) [][2]string {
	return [][2]string{
		{"ID", value.ID},
		{"NAME", value.Name},
		{"HOME", displayValue(value.Home)},
		{"ORDER", strconv.Itoa(value.Order)},
		{"CREATED AT", formatTime(value.CreatedAt)},
	}
}

func sessionPairs(value api.Session) [][2]string {
	return [][2]string{
		{"ID", value.ID},
		{"SCOPE", value.ScopeKind()},
		{"WORKSPACE", value.WorkspaceID},
		{"TERMINAL GROUP", value.TerminalGroupID},
		{"TITLE", effectiveSessionTitle(value)},
		{"KIND", value.Kind},
		{"COMMAND", displayValue(value.Command)},
		{"RUNTIME", value.Runtime},
		{"RUNTIME KIND", displayValue(value.RuntimeKind)},
		{"LIFECYCLE", value.Lifecycle},
		{"ACTIVITY", displayValue(sessionActivity(value))},
		{"AGENT SESSION", displayValue(value.AgentSessionID)},
		{"OPERATION ID", displayValue(value.OperationID)},
		{"TRANSCRIPT", displayValue(value.TranscriptPath)},
		{"PINNED", displayBool(value.Pinned)},
		{"CREATED AT", formatTime(value.CreatedAt)},
		{"ENDED AT", formatOptionalTime(value.EndedAt)},
	}
}

func agentCreatePairs(value agentCreateResult) [][2]string {
	pairs := [][2]string{
		{"AGENT ID", value.Session.ID},
		{"PROVIDER", value.Session.Kind},
		{"COMMAND", displayValue(value.Session.Command)},
		{"TITLE", effectiveSessionTitle(value.Session)},
		{"PROMPT SENT", displayBool(value.PromptSent)},
		{"LIFECYCLE", value.Session.Lifecycle},
	}
	if value.Wait != nil {
		pairs = append(pairs,
			[2]string{"TURN", strconv.FormatUint(value.Wait.Turn, 10)},
			[2]string{"TURN STATUS", string(value.Wait.Status)},
		)
	}
	return pairs
}

func currentSessionPairs(value currentSessionValue) [][2]string {
	pairs := sessionPairs(value.Session)
	pairs = append([][2]string{{"CURRENT", displayBool(value.Current)}, {"WARREN SESSION ID", value.WarrenSessionID}, {"AGENT/THREAD ID", displayValue(value.AgentThreadID)}}, pairs...)
	// Where this Session sits on the screen that displays it, without naming the
	// panes around it. `warren session panes` is the query for those.
	if count := value.Session.ScreenPaneCount; count > 1 {
		pairs = append(pairs, [2]string{
			"SCREEN POSITION",
			fmt.Sprintf("pane %d of %d", value.Session.ScreenPosition, count),
		})
	}
	return pairs
}

func sessionMovePreflightPairs(value api.SessionMovePreflight) [][2]string {
	return [][2]string{
		{"ALLOWED", displayBool(value.Allowed)},
		{"WARREN SESSION ID", value.Session.ID},
		{"SOURCE WORKSPACE", displayValue(value.SourceWorkspaceID)},
		{"SOURCE GROUP", displayValue(value.SourceTerminalGroupID)},
		{"DESTINATION WORKSPACE", displayValue(value.DestinationWorkspaceID)},
		{"DESTINATION GROUP", displayValue(value.DestinationTerminalGroupID)},
		{"AGENT/THREAD ID", displayValue(value.Session.AgentSessionID)},
		{"TRANSCRIPT PATH", displayValue(value.Session.TranscriptPath)},
	}
}

func boolMapPairs(value map[string]bool) [][2]string {
	keys := make([]string, 0, len(value))
	for key := range value {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	pairs := make([][2]string, 0, len(keys))
	for _, key := range keys {
		pairs = append(pairs, [2]string{strings.ToUpper(key), displayBool(value[key])})
	}
	return pairs
}

func anyMapPairs(value map[string]any) [][2]string {
	keys := make([]string, 0, len(value))
	for key := range value {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	pairs := make([][2]string, 0, len(keys))
	for _, key := range keys {
		pairs = append(pairs, [2]string{strings.ToUpper(key), displayAny(value[key])})
	}
	return pairs
}

func displayAny(value any) string {
	switch item := value.(type) {
	case bool:
		return displayBool(item)
	case string:
		return displayValue(item)
	case float64:
		return strconv.FormatFloat(item, 'f', -1, 64)
	default:
		data, _ := json.Marshal(item)
		return string(data)
	}
}

func cleanTableCell(val string) string {
	val = strings.ReplaceAll(val, "\r\n", " ")
	val = strings.ReplaceAll(val, "\n", " ")
	val = strings.ReplaceAll(val, "\r", " ")
	val = strings.ReplaceAll(val, "\t", " ")
	return strings.TrimSpace(val)
}

func printTable(headers []string, rows ...[]string) {
	widths := make([]int, len(headers))
	for index, header := range headers {
		widths[index] = len(header)
	}
	for _, row := range rows {
		for index, cell := range row {
			cell = cleanTableCell(cell)
			if index < len(widths) && len(cell) > widths[index] {
				widths[index] = len(cell)
			}
		}
	}
	printTableRow(headers, widths)
	for _, row := range rows {
		cleanRow := make([]string, len(row))
		for i, cell := range row {
			cleanRow[i] = cleanTableCell(cell)
		}
		printTableRow(cleanRow, widths)
	}
}

func printTableRow(cells []string, widths []int) {
	var line strings.Builder
	for index, cell := range cells {
		if index > 0 {
			line.WriteString("  ")
		}
		if index < len(widths) {
			fmt.Fprintf(&line, "%-*s", widths[index], cell)
		} else {
			line.WriteString(cell)
		}
	}
	fmt.Println(strings.TrimRight(line.String(), " "))
}

func printKVTable(pairs [][2]string) {
	width := 0
	for _, pair := range pairs {
		if len(pair[0]) > width {
			width = len(pair[0])
		}
	}
	for _, pair := range pairs {
		fmt.Printf("%-*s  %s\n", width, pair[0], pair[1])
	}
}

func displayValue(value string) string {
	if value == "" {
		return "-"
	}
	return value
}

func displayTruncated(value string, maxLen int) string {
	value = strings.TrimSpace(value)
	if value == "" {
		return "-"
	}
	if maxLen <= 3 || len(value) <= maxLen {
		return value
	}
	return value[:maxLen-3] + "..."
}

func displayTruncatedPath(value string, maxLen int) string {
	value = strings.TrimSpace(value)
	if value == "" {
		return "-"
	}
	if maxLen <= 3 || len(value) <= maxLen {
		return value
	}
	return "..." + value[len(value)-(maxLen-3):]
}

func endpointType(value string) string {
	value = strings.TrimSpace(strings.ToLower(value))
	if value == "" {
		return "daemon"
	}
	return value
}

func displayBool(value bool) string {
	if value {
		return "yes"
	}
	return "no"
}

func formatTime(value time.Time) string {
	if value.IsZero() {
		return "-"
	}
	return value.Local().Format("2006-01-02 15:04")
}

func formatOptionalTime(value *time.Time) string {
	if value == nil {
		return "-"
	}
	return formatTime(*value)
}

func env(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}

func usage() { fmt.Print(usageText()) }
