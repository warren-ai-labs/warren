package server

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/store"
)

func (s *Service) AddProject(path, name string) (api.Project, error) {
	return s.AddProjectWithOptions(path, name, false)
}

// AddProjectWithOptions adds a project and optionally imports every existing
// Git worktree for that project. The option is persisted on the Project, not
// in host-wide settings, so repositories can opt in independently.
func (s *Service) AddProjectWithOptions(path, name string, autoImportGitWorktrees bool) (api.Project, error) {
	selected, err := filepath.Abs(expandHome(strings.TrimSpace(path)))
	if err != nil {
		return api.Project{}, err
	}
	info, err := os.Stat(selected)
	if err != nil || !info.IsDir() {
		return api.Project{}, fmt.Errorf("project path is not a directory: %s", selected)
	}
	worktrees, err := listGitWorktrees(selected)
	if err != nil {
		return api.Project{}, fmt.Errorf("project is not a Git repository: %s: %w", selected, err)
	}
	createdAt := time.Now().UTC()
	project := api.Project{
		ID:                     store.NewID(),
		Path:                   filepath.Clean(worktrees[0].Path),
		AutoImportGitWorktrees: autoImportGitWorktrees,
		CreatedAt:              createdAt,
	}
	if name == "" {
		name = filepath.Base(project.Path)
	}
	project.Name = name
	workspaces, err := workspacesForGitWorktrees(
		project.ID,
		createdAt,
		worktrees,
		os.Stat,
		project.AutoImportGitWorktrees,
	)
	if err != nil {
		return api.Project{}, err
	}
	err = s.Store.Update(func(state *api.State) error {
		for _, value := range state.Projects {
			if samePath(value.Path, project.Path) {
				return fmt.Errorf("project already exists: %s", project.Path)
			}
		}
		project.Order = len(state.Projects)
		state.Projects = append(state.Projects, project)
		state.Workspaces = append(state.Workspaces, workspaces...)
		return nil
	})
	if err == nil {
		s.invalidateMerge()
	}
	return project, err
}

// ListProjectWorktrees returns existing external Git worktrees for a project.
// Already registered worktrees stay in the result so clients can render them
// disabled and explain that import is a one-time operation.
func (s *Service) ListProjectWorktrees(projectID string) ([]api.WorktreeCandidate, error) {
	state := s.Store.Snapshot()
	var project api.Project
	found := false
	for _, value := range state.Projects {
		if value.ID == projectID {
			project = value
			found = true
			break
		}
	}
	if !found {
		return nil, fmt.Errorf("project not found: %s", projectID)
	}
	return projectWorktreeCandidates(project, state.Workspaces)
}

// ImportProjectWorktrees registers selected existing Git worktrees as
// workspaces. It never creates, moves, or removes a checkout on disk.
func (s *Service) ImportProjectWorktrees(projectID string, paths []string) ([]api.Workspace, error) {
	state := s.Store.Snapshot()
	var project api.Project
	found := false
	for _, value := range state.Projects {
		if value.ID == projectID {
			project = value
			found = true
			break
		}
	}
	if !found {
		return nil, fmt.Errorf("project not found: %s", projectID)
	}
	candidates, err := projectWorktreeCandidates(project, state.Workspaces)
	if err != nil {
		return nil, err
	}
	requested := make(map[string]struct{}, len(paths))
	for _, path := range paths {
		path = filepath.Clean(strings.TrimSpace(path))
		if path != "." && path != "" {
			requested[normalizedPathKey(path)] = struct{}{}
		}
	}
	if len(requested) == 0 {
		return nil, errors.New("at least one worktree path is required")
	}

	selected := make([]api.WorktreeCandidate, 0, len(requested))
	for _, candidate := range candidates {
		if _, ok := requested[normalizedPathKey(candidate.Path)]; !ok {
			continue
		}
		if candidate.Imported {
			continue
		}
		selected = append(selected, candidate)
		delete(requested, normalizedPathKey(candidate.Path))
	}
	if len(requested) > 0 {
		return nil, fmt.Errorf("worktree is not an importable checkout: %s", firstMapKey(requested))
	}
	created := make([]api.Workspace, 0, len(selected))
	err = s.Store.Update(func(value *api.State) error {
		for _, candidate := range selected {
			duplicate := false
			for _, workspace := range value.Workspaces {
				if workspace.ProjectID == projectID && samePath(workspace.Path, candidate.Path) {
					duplicate = true
					break
				}
			}
			if duplicate {
				continue
			}
			workspace := api.Workspace{
				ID:             store.NewID(),
				ProjectID:      projectID,
				Name:           candidate.Name,
				Path:           filepath.Clean(candidate.Path),
				Branch:         candidate.Branch,
				Kind:           "worktree",
				WorktreeLocked: candidate.Locked,
				Order:          nextWorkspaceOrder(value.Workspaces, projectID),
				CreatedAt:      time.Now().UTC(),
			}
			if err := branchAlreadyHasWorkspace(value, projectID, workspace.Branch); err != nil {
				return err
			}
			value.Workspaces = append(value.Workspaces, workspace)
			created = append(created, workspace)
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	if len(created) > 0 {
		s.invalidateMerge()
	}
	return created, nil
}

// SetProjectAutoImportGitWorktrees changes one project's automatic import
// policy. Enabling it also imports currently visible external worktrees once;
// this is deliberately non-interactive and leaves imported checkouts on disk.
func (s *Service) SetProjectAutoImportGitWorktrees(projectID string, enabled bool) (api.Project, error) {
	state := s.Store.Snapshot()
	var project api.Project
	found := false
	for _, value := range state.Projects {
		if value.ID == projectID {
			project = value
			found = true
			break
		}
	}
	if !found {
		return api.Project{}, fmt.Errorf("project not found: %s", projectID)
	}
	project.AutoImportGitWorktrees = enabled
	if err := s.Store.Update(func(value *api.State) error {
		for index := range value.Projects {
			if value.Projects[index].ID == projectID {
				value.Projects[index].AutoImportGitWorktrees = enabled
				return nil
			}
		}
		return fmt.Errorf("project not found: %s", projectID)
	}); err != nil {
		return api.Project{}, err
	}
	if enabled {
		candidates, err := projectWorktreeCandidates(project, state.Workspaces)
		if err != nil {
			return api.Project{}, err
		}
		paths := make([]string, 0, len(candidates))
		for _, candidate := range candidates {
			if !candidate.Imported {
				paths = append(paths, candidate.Path)
			}
		}
		if len(paths) > 0 {
			if _, err := s.ImportProjectWorktrees(projectID, paths); err != nil {
				return api.Project{}, err
			}
		}
	}
	return project, nil
}

// SetProjectSetupScript changes the executable used for newly created managed
// worktrees. An empty value disables setup execution for this project.
func (s *Service) SetProjectSetupScript(projectID, script string) (api.Project, error) {
	state := s.Store.Snapshot()
	var project api.Project
	found := false
	for _, value := range state.Projects {
		if value.ID == projectID {
			project = value
			found = true
			break
		}
	}
	if !found {
		return api.Project{}, fmt.Errorf("project not found: %s", projectID)
	}
	project.SetupScript = strings.TrimSpace(script)
	if project.SetupScript != "" {
		if _, err := setupScriptPath(project); err != nil {
			return api.Project{}, err
		}
	}
	if err := s.Store.Update(func(value *api.State) error {
		for index := range value.Projects {
			if value.Projects[index].ID == projectID {
				value.Projects[index].SetupScript = project.SetupScript
				return nil
			}
		}
		return fmt.Errorf("project not found: %s", projectID)
	}); err != nil {
		return api.Project{}, err
	}
	return project, nil
}

func projectWorktreeCandidates(project api.Project, workspaces []api.Workspace) ([]api.WorktreeCandidate, error) {
	worktrees, err := listGitWorktrees(project.Path)
	if err != nil {
		return nil, err
	}
	importedByPath := make(map[string]api.Workspace)
	for _, workspace := range workspaces {
		if workspace.ProjectID == project.ID {
			importedByPath[normalizedPathKey(workspace.Path)] = workspace
		}
	}
	candidates := make([]api.WorktreeCandidate, 0, len(worktrees))
	for _, worktree := range worktrees {
		path := filepath.Clean(worktree.Path)
		if worktree.Bare || samePath(path, project.Path) || worktree.Prunable {
			continue
		}
		info, err := os.Stat(path)
		if err != nil {
			if os.IsNotExist(err) {
				continue
			}
			return nil, fmt.Errorf("inspect Git worktree %s: %w", path, err)
		}
		if !info.IsDir() {
			continue
		}
		name := worktree.Branch
		if name == "" {
			name = filepath.Base(path)
		}
		candidate := api.WorktreeCandidate{
			Path:   path,
			Name:   name,
			Branch: worktree.Branch,
			Locked: worktree.Locked,
		}
		if workspace, ok := importedByPath[normalizedPathKey(path)]; ok {
			candidate.Imported = true
			candidate.WorkspaceID = workspace.ID
		}
		candidates = append(candidates, candidate)
	}
	return candidates, nil
}

func normalizedPathKey(path string) string {
	path = strings.TrimSpace(expandHome(path))
	if absolute, err := filepath.Abs(path); err == nil {
		path = absolute
	}
	if resolved, err := filepath.EvalSymlinks(path); err == nil {
		path = resolved
	}
	return filepath.Clean(path)
}

func firstMapKey(values map[string]struct{}) string {
	for value := range values {
		return value
	}
	return ""
}

// MoveProject moves one project before another project (or to the end when
// before is empty) and renumbers the stored sidebar order.
func (s *Service) MoveProject(id, before string) error {
	return s.Store.Update(func(state *api.State) error {
		sortProjects(state.Projects)
		index := -1
		for i := range state.Projects {
			if state.Projects[i].ID == id {
				index = i
				break
			}
		}
		if index < 0 {
			return fmt.Errorf("project not found: %s", id)
		}
		target := len(state.Projects)
		if before != "" {
			found := false
			for i := range state.Projects {
				if state.Projects[i].ID == before {
					target = i
					found = true
					break
				}
			}
			if !found {
				return fmt.Errorf("before project not found: %s", before)
			}
		}
		project := state.Projects[index]
		state.Projects = append(state.Projects[:index], state.Projects[index+1:]...)
		if index < target {
			target--
		}
		state.Projects = slices.Insert(state.Projects, target, project)
		for i := range state.Projects {
			state.Projects[i].Order = i
		}
		return nil
	})
}

// MoveWorkspace moves one workspace before another workspace inside the same
// project (or to the end when before is empty) and renumbers the stored
// per-project sidebar order.
func (s *Service) MoveWorkspace(id, before string) error {
	return s.Store.Update(func(state *api.State) error {
		sortWorkspaces(state.Workspaces)
		index := -1
		projectID := ""
		for i := range state.Workspaces {
			if state.Workspaces[i].ID == id {
				index = i
				projectID = state.Workspaces[i].ProjectID
				break
			}
		}
		if index < 0 {
			return fmt.Errorf("workspace not found: %s", id)
		}
		var ids []string
		for _, workspace := range state.Workspaces {
			if workspace.ProjectID == projectID {
				ids = append(ids, workspace.ID)
			}
		}
		target := len(ids)
		if before != "" {
			found := false
			for i, workspaceID := range ids {
				if workspaceID == before {
					target = i
					found = true
					break
				}
			}
			if !found {
				return fmt.Errorf("before workspace not found: %s", before)
			}
		}
		source := -1
		for i, workspaceID := range ids {
			if workspaceID == id {
				source = i
				break
			}
		}
		ids = append(ids[:source], ids[source+1:]...)
		if source < target {
			target--
		}
		ids = slices.Insert(ids, target, id)
		orders := make(map[string]int, len(ids))
		for i, workspaceID := range ids {
			orders[workspaceID] = i
		}
		for i := range state.Workspaces {
			if state.Workspaces[i].ProjectID == projectID {
				state.Workspaces[i].Order = orders[state.Workspaces[i].ID]
			}
		}
		return nil
	})
}

func (s *Service) RemoveProject(id string, force bool) error {
	projectLock := s.projectLifecycleLock(id)
	projectLock.Lock()
	state := s.Store.Snapshot()
	found := false
	workspaceIDs := make([]string, 0)
	for _, workspace := range state.Workspaces {
		if workspace.ProjectID != id {
			continue
		}
		workspaceIDs = append(workspaceIDs, workspace.ID)
		for _, session := range state.Sessions {
			if session.WorkspaceID == workspace.ID && session.Lifecycle == "running" && !force {
				projectLock.Unlock()
				return errors.New("project has running sessions; use --force")
			}
		}
	}
	for _, project := range state.Projects {
		if project.ID == id {
			found = true
			break
		}
	}
	if !found {
		projectLock.Unlock()
		return fmt.Errorf("project not found: %s", id)
	}
	err := s.Store.Update(func(value *api.State) error {
		workspaceIDs := map[string]bool{}
		value.Projects = filter(value.Projects, func(p api.Project) bool { return p.ID != id })
		value.Workspaces = filter(value.Workspaces, func(w api.Workspace) bool {
			if w.ProjectID == id {
				workspaceIDs[w.ID] = true
				return false
			}
			return true
		})
		value.Sessions = filter(value.Sessions, func(session api.Session) bool { return !workspaceIDs[session.WorkspaceID] })
		for i := range value.Projects {
			value.Projects[i].Order = i
		}
		return nil
	})
	projectLock.Unlock()
	if err != nil {
		return err
	}
	s.invalidateMerge()
	if force {
		for _, workspaceID := range workspaceIDs {
			_ = s.removeWorkspaceRuntime(context.Background(), state, workspaceID)
		}
	}
	return nil
}

func (s *Service) RenameProject(id, name string) error {
	name = strings.TrimSpace(name)
	if name == "" {
		return errors.New("project name cannot be empty")
	}
	return s.Store.Update(func(state *api.State) error {
		for index := range state.Projects {
			if state.Projects[index].ID == id {
				state.Projects[index].Name = name
				return nil
			}
		}
		return fmt.Errorf("project not found: %s", id)
	})
}

func (s *Service) RenameWorkspace(id, name string) error {
	name = strings.TrimSpace(name)
	if name == "" {
		return errors.New("workspace name cannot be empty")
	}
	return s.Store.Update(func(state *api.State) error {
		for index := range state.Workspaces {
			if state.Workspaces[index].ID == id {
				state.Workspaces[index].Name = name
				return nil
			}
		}
		return fmt.Errorf("workspace not found: %s", id)
	})
}

func (s *Service) SetProjectPinned(id string, pinned bool) error {
	return s.Store.Update(func(state *api.State) error {
		for index := range state.Projects {
			if state.Projects[index].ID == id {
				state.Projects[index].Pinned = pinned
				return nil
			}
		}
		return fmt.Errorf("project not found: %s", id)
	})
}

func (s *Service) SetWorkspacePinned(id string, pinned bool) error {
	return s.Store.Update(func(state *api.State) error {
		for index := range state.Workspaces {
			if state.Workspaces[index].ID == id {
				state.Workspaces[index].Pinned = pinned
				return nil
			}
		}
		return fmt.Errorf("workspace not found: %s", id)
	})
}
