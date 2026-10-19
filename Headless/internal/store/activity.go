package store

import (
	"sort"
	"strings"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

// Activity stamps are derived from the Session list on every write, so every
// path that creates, ends, deletes, or moves a Session records them without
// each caller having to remember to.

// stampActivity records Workspace and Project activity for the Session changes
// between before and after.
//
// A Workspace's LastActivityAt moves whenever the set of its Sessions or one
// of their lifecycles changes. A Project's ActiveSince is set when it goes
// from no running Session to one and cleared when its last one goes away; a
// Project that stays active keeps its stamp, so its place among the active
// Projects does not change while it works.
func stampActivity(before, after *api.State, now time.Time) {
	beforeSignatures := workspaceSessionSignatures(before.Sessions)
	afterSignatures := workspaceSessionSignatures(after.Sessions)
	for index := range after.Workspaces {
		id := after.Workspaces[index].ID
		if beforeSignatures[id] != afterSignatures[id] {
			stamp := now
			after.Workspaces[index].LastActivityAt = &stamp
		}
	}

	beforeRunning := runningProjects(before)
	afterRunning := runningProjects(after)
	for index := range after.Projects {
		project := &after.Projects[index]
		switch {
		case !afterRunning[project.ID]:
			project.ActiveSince = nil
		case !beforeRunning[project.ID] || project.ActiveSince == nil:
			stamp := now
			project.ActiveSince = &stamp
		}
	}
}

// backfillActivity gives a state written before activity stamps existed the
// best values its Sessions can still prove. It reports whether it changed
// anything.
func backfillActivity(state *api.State) bool {
	changed := false
	latestByWorkspace := make(map[string]time.Time)
	earliestRunningByWorkspace := make(map[string]time.Time)
	for _, session := range state.Sessions {
		if session.WorkspaceID == "" {
			continue
		}
		moment := session.CreatedAt
		if session.EndedAt != nil {
			moment = *session.EndedAt
		}
		if current, ok := latestByWorkspace[session.WorkspaceID]; !ok || moment.After(current) {
			latestByWorkspace[session.WorkspaceID] = moment
		}
		if session.Lifecycle == "running" {
			if current, ok := earliestRunningByWorkspace[session.WorkspaceID]; !ok || session.CreatedAt.Before(current) {
				earliestRunningByWorkspace[session.WorkspaceID] = session.CreatedAt
			}
		}
	}
	earliestRunningByProject := make(map[string]time.Time)
	for index := range state.Workspaces {
		workspace := &state.Workspaces[index]
		if latest, ok := latestByWorkspace[workspace.ID]; ok && workspace.LastActivityAt == nil {
			stamp := latest
			workspace.LastActivityAt = &stamp
			changed = true
		}
		if earliest, ok := earliestRunningByWorkspace[workspace.ID]; ok {
			if current, seen := earliestRunningByProject[workspace.ProjectID]; !seen || earliest.Before(current) {
				earliestRunningByProject[workspace.ProjectID] = earliest
			}
		}
	}
	for index := range state.Projects {
		project := &state.Projects[index]
		earliest, running := earliestRunningByProject[project.ID]
		switch {
		case !running && project.ActiveSince != nil:
			project.ActiveSince = nil
			changed = true
		case running && project.ActiveSince == nil:
			stamp := earliest
			project.ActiveSince = &stamp
			changed = true
		}
	}
	return changed
}

// workspaceSessionSignatures names, per Workspace, which Sessions it holds and
// in which lifecycle.
func workspaceSessionSignatures(sessions []api.Session) map[string]string {
	entries := make(map[string][]string)
	for _, session := range sessions {
		if session.WorkspaceID == "" {
			continue
		}
		entries[session.WorkspaceID] = append(entries[session.WorkspaceID], session.ID+"="+session.Lifecycle)
	}
	signatures := make(map[string]string, len(entries))
	for id, values := range entries {
		sort.Strings(values)
		signatures[id] = strings.Join(values, ",")
	}
	return signatures
}

// runningProjects is the set of Projects with at least one running Session.
func runningProjects(state *api.State) map[string]bool {
	projectByWorkspace := make(map[string]string, len(state.Workspaces))
	for _, workspace := range state.Workspaces {
		projectByWorkspace[workspace.ID] = workspace.ProjectID
	}
	running := make(map[string]bool)
	for _, session := range state.Sessions {
		if session.Lifecycle != "running" || session.WorkspaceID == "" {
			continue
		}
		if projectID, ok := projectByWorkspace[session.WorkspaceID]; ok {
			running[projectID] = true
		}
	}
	return running
}
