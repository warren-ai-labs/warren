package main

import (
	"errors"
	"fmt"
	"os"
	"strings"

	"github.com/abcdlsj/warren/Headless/internal/agent"
	"github.com/abcdlsj/warren/Headless/internal/api"
)

// SessionRow joins a session with its workspace and project so the CLI can
// display context the roster already carries. The embedded Session keeps the
// JSON payload backward compatible while adding the resolved names/paths.
type SessionRow struct {
	api.Session
	WarrenSessionID   string `json:"warrenSessionId"`
	AgentThreadID     string `json:"agentThreadId,omitempty"`
	ProjectID         string `json:"projectId,omitempty"`
	ProjectName       string `json:"projectName,omitempty"`
	WorkspaceName     string `json:"workspaceName,omitempty"`
	TerminalGroupName string `json:"terminalGroupName,omitempty"`
	Branch            string `json:"branch,omitempty"`
	Path              string `json:"path,omitempty"`
	Current           bool   `json:"current"`
}

func sessionActivity(session api.Session) string {
	if session.AgentStatus == nil {
		return ""
	}
	if session.AgentStatus.Activity == api.AgentActivityBlocked {
		return "attention"
	}
	return string(session.AgentStatus.Activity)
}

func sessionRows(state api.State, includeEnded, onlyEnded bool) []SessionRow {
	return sessionRowsForCurrent(state, includeEnded, onlyEnded, strings.TrimSpace(os.Getenv(agent.BindEnvSession)))
}

func sessionRowsForCurrent(state api.State, includeEnded, onlyEnded bool, currentID string) []SessionRow {
	workspaces := make(map[string]api.Workspace, len(state.Workspaces))
	for _, workspace := range state.Workspaces {
		workspaces[workspace.ID] = workspace
	}
	projects := make(map[string]api.Project, len(state.Projects))
	for _, project := range state.Projects {
		projects[project.ID] = project
	}
	rows := make([]SessionRow, 0, len(state.Sessions))
	for _, session := range state.Sessions {
		if onlyEnded && session.Lifecycle == "running" {
			continue
		}
		if !onlyEnded && !includeEnded && session.Lifecycle != "running" {
			continue
		}
		row := SessionRow{
			Session:         session,
			WarrenSessionID: session.ID,
			AgentThreadID:   session.AgentSessionID,
			Current:         currentID != "" && currentID == session.ID,
		}
		if workspace, ok := workspaces[session.WorkspaceID]; ok {
			row.WorkspaceName = workspace.Name
			row.Branch = workspace.Branch
			row.Path = workspace.Path
			if project, ok := projects[workspace.ProjectID]; ok {
				row.ProjectID = project.ID
				row.ProjectName = project.Name
			}
		}
		for _, group := range state.TerminalGroups {
			if group.ID == session.TerminalGroupID {
				row.TerminalGroupName = group.Name
				if row.Path == "" {
					row.Path = group.Home
				}
				break
			}
		}
		rows = append(rows, row)
	}
	return rows
}

// currentSessionID resolves only the Warren-owned binding environment. It
// deliberately does not inspect cwd, timestamps, names, or transcripts.
func currentSessionID() (string, error) {
	value := strings.TrimSpace(os.Getenv(agent.BindEnvSession))
	if value == "" {
		return "", errors.New("WARREN_SESSION_ID is not set; run this command from a Warren-managed session or pass an explicit SESSION_ID")
	}
	return value, nil
}

type currentSessionValue struct {
	api.Session
	WarrenSessionID string `json:"warrenSessionId"`
	AgentThreadID   string `json:"agentThreadId,omitempty"`
	Current         bool   `json:"current"`
}

type TaskRow struct {
	api.Task
	Workspaces int `json:"workspaces,omitempty"`
}

func taskRows(state api.State) []TaskRow {
	byTask := make(map[string]int)
	for _, workspace := range state.Workspaces {
		if workspace.TaskID != "" {
			byTask[workspace.TaskID]++
		}
	}
	rows := make([]TaskRow, 0, len(state.Tasks))
	for _, task := range state.Tasks {
		rows = append(rows, TaskRow{Task: task, Workspaces: byTask[task.ID]})
	}
	return rows
}

// effectiveSessionTitle is the single display-name rule used everywhere a
// session name is rendered: a user-set CustomTitle wins, otherwise the
// generated default Title is shown.
func effectiveSessionTitle(session api.Session) string {
	if title := strings.TrimSpace(session.CustomTitle); title != "" {
		return title
	}
	return session.Title
}

// ProjectRow adds roster-derived context (workspace count) to a project while
// keeping the original JSON fields intact.
type ProjectRow struct {
	api.Project
	Workspaces int `json:"workspaces,omitempty"`
}

func projectRows(state api.State) []ProjectRow {
	byProject := make(map[string]int)
	for _, workspace := range state.Workspaces {
		byProject[workspace.ProjectID]++
	}
	rows := make([]ProjectRow, 0, len(state.Projects))
	for _, project := range state.Projects {
		rows = append(rows, ProjectRow{Project: project, Workspaces: byProject[project.ID]})
	}
	return rows
}

// WorkspaceRow joins a workspace with its project and adds a running session
// count while keeping the original JSON fields intact.
type WorkspaceRow struct {
	api.Workspace
	ProjectName string `json:"projectName,omitempty"`
	TaskName    string `json:"taskName,omitempty"`
	Sessions    int    `json:"sessions,omitempty"`
}

func workspaceRows(state api.State) []WorkspaceRow {
	projects := make(map[string]api.Project, len(state.Projects))
	for _, project := range state.Projects {
		projects[project.ID] = project
	}
	tasks := make(map[string]api.Task, len(state.Tasks))
	for _, task := range state.Tasks {
		tasks[task.ID] = task
	}
	runningByWorkspace := make(map[string]int)
	for _, session := range state.Sessions {
		if session.Lifecycle == "running" {
			runningByWorkspace[session.WorkspaceID]++
		}
	}
	rows := make([]WorkspaceRow, 0, len(state.Workspaces))
	for _, workspace := range state.Workspaces {
		row := WorkspaceRow{Workspace: workspace, Sessions: runningByWorkspace[workspace.ID]}
		if project, ok := projects[workspace.ProjectID]; ok {
			row.ProjectName = project.Name
		}
		if task, ok := tasks[workspace.TaskID]; ok {
			row.TaskName = task.Name
		}
		rows = append(rows, row)
	}
	return rows
}

func taskWorkspaceRows(state api.State, taskID string, available bool) ([]WorkspaceRow, error) {
	taskFound := false
	for _, task := range state.Tasks {
		if task.ID == taskID {
			taskFound = true
			break
		}
	}
	if !taskFound {
		return nil, fmt.Errorf("task not found: %s", taskID)
	}
	rows := workspaceRows(state)
	result := make([]WorkspaceRow, 0, len(rows))
	for _, row := range rows {
		if available && row.TaskID == "" {
			result = append(result, row)
		}
		if !available && row.TaskID == taskID {
			result = append(result, row)
		}
	}
	return result, nil
}

func parseOptionalBool(params map[string]any, key string) (bool, bool) {
	val, ok := params[key]
	if !ok {
		return false, false
	}
	switch v := val.(type) {
	case bool:
		return v, true
	case string:
		lower := strings.ToLower(strings.TrimSpace(v))
		if lower == "true" || lower == "1" || lower == "yes" {
			return true, true
		}
		if lower == "false" || lower == "0" || lower == "no" {
			return false, true
		}
	}
	return false, false
}

func filterSessionRows(rows []SessionRow, params map[string]any, currentID string) ([]SessionRow, error) {
	status := strings.ToLower(strings.TrimSpace(stringValue(params, "status")))
	if status != "" && status != "running" && status != "ended" {
		return nil, errors.New("--status must be running or ended")
	}
	if status == "running" && boolValue(params, "ended") {
		return nil, errors.New("--status running and --ended are mutually exclusive")
	}
	if status == "ended" && boolValue(params, "all") {
		return nil, errors.New("--status ended and --all are mutually exclusive")
	}
	onlyEnded := boolValue(params, "ended") || status == "ended"
	includeEnded := boolValue(params, "all") || onlyEnded
	if status == "running" {
		includeEnded = false
		onlyEnded = false
	}

	workspaceFilter := strings.TrimSpace(stringValue(params, "workspace"))
	if workspaceFilter == "" {
		workspaceFilter = strings.TrimSpace(stringValue(params, "workspace-id"))
	}
	projectFilter := strings.TrimSpace(stringValue(params, "project"))
	if projectFilter == "" {
		projectFilter = strings.TrimSpace(stringValue(params, "project-id"))
	}
	groupFilter := strings.TrimSpace(stringValue(params, "group"))
	if groupFilter == "" {
		groupFilter = strings.TrimSpace(stringValue(params, "group-id"))
	}
	kindFilter := strings.ToLower(strings.TrimSpace(stringValue(params, "kind")))
	if kindFilter == "" {
		kindFilter = strings.ToLower(strings.TrimSpace(stringValue(params, "provider")))
	}
	activityFilter := strings.ToLower(strings.TrimSpace(stringValue(params, "activity")))
	searchFilter := strings.ToLower(strings.TrimSpace(stringValue(params, "search")))
	if searchFilter == "" {
		searchFilter = strings.ToLower(strings.TrimSpace(stringValue(params, "query")))
	}
	pinned, hasPinned := parseOptionalBool(params, "pinned")

	filterByCurrent := boolValue(params, "current")
	var currentSession *SessionRow
	if filterByCurrent {
		if currentID == "" {
			return nil, errors.New("WARREN_SESSION_ID is not set; run this command from a Warren-managed session or pass an explicit context")
		}
		for index := range rows {
			if rows[index].ID == currentID {
				currentSession = &rows[index]
				break
			}
		}
		if currentSession == nil {
			return nil, fmt.Errorf("current session not found: %s", currentID)
		}
	}

	result := make([]SessionRow, 0, len(rows))
	for _, row := range rows {
		if onlyEnded && row.Lifecycle == "running" {
			continue
		}
		if !onlyEnded && !includeEnded && row.Lifecycle != "running" {
			continue
		}
		if workspaceFilter != "" {
			if !strings.EqualFold(row.WorkspaceID, workspaceFilter) && !strings.EqualFold(row.WorkspaceName, workspaceFilter) {
				continue
			}
		}
		if projectFilter != "" {
			if !strings.EqualFold(row.ProjectID, projectFilter) && !strings.EqualFold(row.ProjectName, projectFilter) {
				continue
			}
		}
		if groupFilter != "" {
			if !strings.EqualFold(row.TerminalGroupID, groupFilter) && !strings.EqualFold(row.TerminalGroupName, groupFilter) {
				continue
			}
		}
		if kindFilter != "" {
			if !strings.EqualFold(row.Kind, kindFilter) {
				continue
			}
		}
		if activityFilter != "" {
			act := strings.ToLower(sessionActivity(row.Session))
			var rawAct string
			if row.Session.AgentStatus != nil {
				rawAct = strings.ToLower(string(row.Session.AgentStatus.Activity))
			}
			if act != activityFilter && rawAct != activityFilter {
				continue
			}
		}
		if hasPinned && row.Pinned != pinned {
			continue
		}
		if filterByCurrent {
			if currentSession.WorkspaceID != "" {
				if row.WorkspaceID != currentSession.WorkspaceID {
					continue
				}
			} else if currentSession.TerminalGroupID != "" {
				if row.TerminalGroupID != currentSession.TerminalGroupID {
					continue
				}
			} else if row.ID != currentSession.ID {
				continue
			}
		}
		if searchFilter != "" {
			title := strings.ToLower(effectiveSessionTitle(row.Session))
			cmd := strings.ToLower(row.Command)
			id := strings.ToLower(row.ID)
			ws := strings.ToLower(row.WorkspaceName)
			proj := strings.ToLower(row.ProjectName)
			branch := strings.ToLower(row.Branch)
			agentSession := strings.ToLower(row.AgentSessionID)
			if !strings.Contains(title, searchFilter) &&
				!strings.Contains(cmd, searchFilter) &&
				!strings.Contains(id, searchFilter) &&
				!strings.Contains(ws, searchFilter) &&
				!strings.Contains(proj, searchFilter) &&
				!strings.Contains(branch, searchFilter) &&
				!strings.Contains(agentSession, searchFilter) {
				continue
			}
		}
		result = append(result, row)
	}
	return result, nil
}

func filterWorkspaceRows(rows []WorkspaceRow, params map[string]any) ([]WorkspaceRow, error) {
	project := strings.TrimSpace(stringValue(params, "project"))
	if project == "" {
		project = strings.TrimSpace(stringValue(params, "project-id"))
	}
	task := strings.TrimSpace(stringValue(params, "task"))
	if task == "" {
		task = strings.TrimSpace(stringValue(params, "task-id"))
	}
	branch := strings.TrimSpace(stringValue(params, "branch"))
	search := strings.ToLower(strings.TrimSpace(stringValue(params, "search")))
	if search == "" {
		search = strings.ToLower(strings.TrimSpace(stringValue(params, "query")))
	}
	onlyMerged := boolValue(params, "merged")
	onlyUnmerged := boolValue(params, "unmerged")
	if onlyMerged && onlyUnmerged {
		return nil, errors.New("--merged and --unmerged are mutually exclusive")
	}
	unattached := boolValue(params, "unattached") || boolValue(params, "no-task")
	hasSessions := boolValue(params, "has-sessions") || boolValue(params, "active")
	pinned, hasPinned := parseOptionalBool(params, "pinned")

	result := make([]WorkspaceRow, 0, len(rows))
	for _, row := range rows {
		if project != "" && !strings.EqualFold(row.ProjectID, project) && !strings.EqualFold(row.ProjectName, project) {
			continue
		}
		if task != "" && !strings.EqualFold(row.TaskID, task) && !strings.EqualFold(row.TaskName, task) {
			continue
		}
		if unattached && row.TaskID != "" {
			continue
		}
		if onlyMerged && row.MergeState != api.MergeStateMerged {
			continue
		}
		if onlyUnmerged && row.MergeState == api.MergeStateMerged {
			continue
		}
		if branch != "" && !strings.EqualFold(row.Branch, branch) && !strings.Contains(strings.ToLower(row.Branch), strings.ToLower(branch)) {
			continue
		}
		if hasSessions && row.Sessions == 0 {
			continue
		}
		if hasPinned && row.Pinned != pinned {
			continue
		}
		if search != "" {
			if !strings.Contains(strings.ToLower(row.ID), search) &&
				!strings.Contains(strings.ToLower(row.Name), search) &&
				!strings.Contains(strings.ToLower(row.Branch), search) &&
				!strings.Contains(strings.ToLower(row.Path), search) &&
				!strings.Contains(strings.ToLower(row.ProjectName), search) &&
				!strings.Contains(strings.ToLower(row.TaskName), search) {
				continue
			}
		}
		result = append(result, row)
	}
	return result, nil
}

func filterTaskRows(rows []TaskRow, params map[string]any) ([]TaskRow, error) {
	source := strings.TrimSpace(stringValue(params, "source"))
	search := strings.ToLower(strings.TrimSpace(stringValue(params, "search")))
	if search == "" {
		search = strings.ToLower(strings.TrimSpace(stringValue(params, "query")))
	}
	hasWorkspaces := boolValue(params, "has-workspaces")
	unattached := boolValue(params, "unattached") || boolValue(params, "no-workspaces")
	if hasWorkspaces && unattached {
		return nil, errors.New("--has-workspaces and --unattached are mutually exclusive")
	}
	pinned, hasPinned := parseOptionalBool(params, "pinned")

	result := make([]TaskRow, 0, len(rows))
	for _, row := range rows {
		if source != "" && !strings.EqualFold(row.Source, source) {
			continue
		}
		if hasWorkspaces && row.Workspaces == 0 {
			continue
		}
		if unattached && row.Workspaces > 0 {
			continue
		}
		if hasPinned && row.Pinned != pinned {
			continue
		}
		if search != "" {
			if !strings.Contains(strings.ToLower(row.ID), search) &&
				!strings.Contains(strings.ToLower(row.Name), search) &&
				!strings.Contains(strings.ToLower(row.ExternalID), search) &&
				!strings.Contains(strings.ToLower(row.URL), search) {
				continue
			}
		}
		result = append(result, row)
	}
	return result, nil
}

func filterProjectRows(rows []ProjectRow, params map[string]any) ([]ProjectRow, error) {
	search := strings.ToLower(strings.TrimSpace(stringValue(params, "search")))
	if search == "" {
		search = strings.ToLower(strings.TrimSpace(stringValue(params, "query")))
	}
	hasWorkspaces := boolValue(params, "has-workspaces")
	pinned, hasPinned := parseOptionalBool(params, "pinned")

	result := make([]ProjectRow, 0, len(rows))
	for _, row := range rows {
		if hasWorkspaces && row.Workspaces == 0 {
			continue
		}
		if hasPinned && row.Pinned != pinned {
			continue
		}
		if search != "" {
			if !strings.Contains(strings.ToLower(row.ID), search) &&
				!strings.Contains(strings.ToLower(row.Name), search) &&
				!strings.Contains(strings.ToLower(row.Path), search) {
				continue
			}
		}
		result = append(result, row)
	}
	return result, nil
}

func filterTerminalGroupRows(groups []api.TerminalGroup, params map[string]any) ([]api.TerminalGroup, error) {
	search := strings.ToLower(strings.TrimSpace(stringValue(params, "search")))
	if search == "" {
		search = strings.ToLower(strings.TrimSpace(stringValue(params, "query")))
	}
	if search == "" {
		return groups, nil
	}
	result := make([]api.TerminalGroup, 0, len(groups))
	for _, group := range groups {
		if strings.Contains(strings.ToLower(group.ID), search) ||
			strings.Contains(strings.ToLower(group.Name), search) ||
			strings.Contains(strings.ToLower(group.Home), search) {
			result = append(result, group)
		}
	}
	return result, nil
}
