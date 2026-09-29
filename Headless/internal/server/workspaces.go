package server

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/store"
)

func (s *Service) CreateWorkspace(projectID, branch, name, path string) (api.WorkspaceCreateResult, error) {
	result, err := s.createWorkspace(projectID, "", branch, name, path, "", false, nil)
	return withoutWorkspaceCreationMetadata(result), err
}

func (s *Service) CreateTaskWorkspace(projectID, taskID, branch, name, path string) (api.WorkspaceCreateResult, error) {
	result, err := s.createWorkspace(projectID, taskID, branch, name, path, "", false, nil)
	return withoutWorkspaceCreationMetadata(result), err
}

func (s *Service) CreateTaskWorkspaceWithRequestID(projectID, taskID, branch, name, path, requestID string) (api.WorkspaceCreateResult, error) {
	result, err := s.createWorkspace(projectID, taskID, branch, name, path, requestID, false, nil)
	return withoutWorkspaceCreationMetadata(result), err
}

func (s *Service) CreateTaskWorkspaceWithSetup(
	projectID, taskID, branch, name, path, requestID string,
	runSetupScript bool, setupArgs []string,
) (api.WorkspaceCreateResult, error) {
	result, err := s.createWorkspace(
		projectID, taskID, branch, name, path, requestID, runSetupScript, setupArgs,
	)
	return withoutWorkspaceCreationMetadata(result), err
}

func (s *Service) createWorkspace(
	projectID, taskID, branch, name, path, requestID string,
	runSetupScript bool, setupArgs []string,
) (api.WorkspaceCreateResult, error) {
	var err error
	requestID, err = normalizeCreationRequestID(requestID)
	if err != nil {
		return api.WorkspaceCreateResult{}, err
	}
	branch = strings.TrimSpace(branch)
	if branch == "" {
		return api.WorkspaceCreateResult{}, errors.New("branch is required")
	}
	if name == "" {
		name = branch
	}
	requestPath := path
	if requestPath != "" {
		requestPath, _ = filepath.Abs(expandHome(requestPath))
	}
	requestHash := ""
	if requestID != "" {
		setupArgsJSON, _ := json.Marshal(setupArgs)
		requestHash = creationRequestHash(
			"workspace.create", projectID, taskID, branch, name, requestPath,
			strconv.FormatBool(runSetupScript), string(setupArgsJSON),
		)
	}

	projectLock := s.projectLifecycleLock(projectID)
	projectLock.Lock()
	defer projectLock.Unlock()

	state := s.Store.Snapshot()
	if replay, found, err := workspaceCreationReplay(&state, requestID, requestHash); err != nil {
		return api.WorkspaceCreateResult{}, err
	} else if found {
		return replay, nil
	}
	var project *api.Project
	for i := range state.Projects {
		if state.Projects[i].ID == projectID {
			project = &state.Projects[i]
			break
		}
	}
	if project == nil {
		return api.WorkspaceCreateResult{}, fmt.Errorf("project not found: %s", projectID)
	}
	if err := taskExists(&state, taskID); err != nil {
		return api.WorkspaceCreateResult{}, err
	}
	if err := branchAlreadyHasWorkspace(&state, projectID, branch); err != nil {
		return api.WorkspaceCreateResult{}, err
	}
	id := store.NewID()
	gitCreated := false
	if path != "" {
		if resolved, err := filepath.Abs(expandHome(path)); err == nil {
			if info, statErr := os.Stat(resolved); statErr == nil && info.IsDir() {
				if output, gitErr := exec.Command("git", "-C", resolved, "rev-parse", "--show-toplevel").Output(); gitErr == nil {
					root := strings.TrimSpace(string(output))
					if samePath(root, project.Path) {
						if branch == "" {
							branch = gitOutput(resolved, "branch", "--show-current")
						}
						if name == "" {
							name = defaultValue(branch, "main")
						}
						workspace := api.Workspace{
							ID: id, ProjectID: projectID, TaskID: taskID, Name: name, Path: resolved,
							Branch: branch, Kind: "root", CreationRequestID: requestID,
							CreationRequestHash: requestHash, CreatedAt: time.Now().UTC(),
						}
						if replay, found, err := s.insertWorkspaceForCreation(&workspace); err != nil {
							return api.WorkspaceCreateResult{}, err
						} else if found {
							return replay, nil
						}
						s.invalidateMerge()
						return api.WorkspaceCreateResult{Workspace: workspace, Created: true}, nil
					}
					if name == "" {
						name = filepath.Base(resolved)
					}
					workspace := api.Workspace{
						ID: id, ProjectID: projectID, TaskID: taskID, Name: name, Path: resolved,
						Branch: branch, Kind: "worktree", CreationRequestID: requestID,
						CreationRequestHash: requestHash, CreatedAt: time.Now().UTC(),
					}
					if replay, found, err := s.insertWorkspaceForCreation(&workspace); err != nil {
						return api.WorkspaceCreateResult{}, err
					} else if found {
						return replay, nil
					}
					s.invalidateMerge()
					return api.WorkspaceCreateResult{Workspace: workspace, Created: true}, nil
				}
			}
		}
	}
	if path == "" {
		path = filepath.Join(expandHome(s.WorktreeRoot), project.ID[:8], id[:8]+"-"+safeName(branch))
	}
	path, _ = filepath.Abs(expandHome(path))
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return api.WorkspaceCreateResult{}, err
	}
	branchCreated := false
	args := []string{"-C", project.Path, "worktree", "add", path, branch}
	if exec.Command("git", "-C", project.Path, "show-ref", "--verify", "--quiet", "refs/heads/"+branch).Run() != nil {
		branchCreated = true
		args = []string{"-C", project.Path, "worktree", "add", "-b", branch, path}
	}
	if output, err := exec.Command("git", args...).CombinedOutput(); err != nil {
		return api.WorkspaceCreateResult{}, fmt.Errorf("git worktree add: %s: %w", strings.TrimSpace(string(output)), err)
	}
	gitCreated = true
	if runSetupScript {
		if err := s.runSetupScript(*project, api.Workspace{
			ID: id, ProjectID: projectID, TaskID: taskID, Name: name, Path: path,
			Branch: branch, Kind: "worktree",
		}, setupArgs); err != nil {
			return api.WorkspaceCreateResult{}, rollbackManagedWorktree(err, project.Path, path, branch, branchCreated)
		}
	}
	if s.beforeWorkspaceInsert != nil {
		s.beforeWorkspaceInsert()
	}
	workspace := api.Workspace{
		ID: id, ProjectID: projectID, TaskID: taskID, Name: name, Path: path,
		Branch: branch, Kind: "worktree", ManagedWorktree: true,
		CreationRequestID: requestID, CreationRequestHash: requestHash, CreatedAt: time.Now().UTC(),
	}
	if replay, found, err := s.insertWorkspaceForCreation(&workspace); err != nil {
		return api.WorkspaceCreateResult{}, rollbackManagedWorktree(err, project.Path, path, branch, branchCreated)
	} else if found {
		return replay, nil
	}
	s.invalidateMerge()
	return api.WorkspaceCreateResult{Workspace: workspace, Created: true, GitWorktree: gitCreated}, nil
}

func (s *Service) runSetupScript(project api.Project, workspace api.Workspace, setupArgs []string) error {
	scriptPath, err := setupScriptPath(project)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), setupScriptTimeout)
	defer cancel()
	args := append([]string{project.Path, workspace.Path}, setupArgs...)
	command := exec.CommandContext(ctx, scriptPath, args...)
	command.Dir = workspace.Path
	command.Env = setupScriptEnvironment(os.Environ(), project, workspace, scriptPath)
	if err := command.Run(); err != nil {
		if errors.Is(ctx.Err(), context.DeadlineExceeded) {
			return fmt.Errorf("setup script timed out after %s", setupScriptTimeout)
		}
		return fmt.Errorf("setup script failed: %w", err)
	}
	return nil
}

func setupScriptPath(project api.Project) (string, error) {
	configured := strings.TrimSpace(project.SetupScript)
	if configured == "" {
		return "", errors.New("setup script is not configured")
	}
	path := expandHome(configured)
	if !filepath.IsAbs(path) {
		path = filepath.Join(project.Path, path)
	}
	path, err := filepath.Abs(path)
	if err != nil {
		return "", fmt.Errorf("resolve setup script: %w", err)
	}
	info, err := os.Stat(path)
	if err != nil {
		return "", fmt.Errorf("setup script is not readable: %s: %w", path, err)
	}
	if !info.Mode().IsRegular() {
		return "", fmt.Errorf("setup script is not a regular file: %s", path)
	}
	if info.Mode().Perm()&0o111 == 0 {
		return "", fmt.Errorf("setup script is not executable: %s", path)
	}
	return path, nil
}

func setupScriptEnvironment(environment []string, project api.Project, workspace api.Workspace, scriptPath string) []string {
	values := map[string]string{
		"WARREN_PROJECT_ID":       project.ID,
		"WARREN_PROJECT_NAME":     project.Name,
		"WARREN_PROJECT_PATH":     project.Path,
		"WARREN_MAIN_REPO_PATH":   project.Path,
		"WARREN_WORKSPACE_ID":     workspace.ID,
		"WARREN_WORKSPACE_NAME":   workspace.Name,
		"WARREN_WORKSPACE_PATH":   workspace.Path,
		"WARREN_WORKTREE_PATH":    workspace.Path,
		"WARREN_WORKSPACE_BRANCH": workspace.Branch,
		"WARREN_TASK_ID":          workspace.TaskID,
		"WARREN_SETUP_SCRIPT":     scriptPath,
	}
	result := make([]string, 0, len(environment)+len(values))
	for _, entry := range environment {
		key, _, ok := strings.Cut(entry, "=")
		if !ok {
			continue
		}
		if _, overridden := values[key]; !overridden {
			result = append(result, entry)
		}
	}
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	slices.Sort(keys)
	for _, key := range keys {
		result = append(result, key+"="+values[key])
	}
	return result
}

func rollbackManagedWorktree(cause error, projectPath, path, branch string, branchCreated bool) error {
	var cleanupErrors []error
	if output, err := exec.Command("git", "-C", projectPath, "worktree", "remove", "--force", path).CombinedOutput(); err != nil {
		cleanupErrors = append(cleanupErrors, fmt.Errorf("remove git worktree %q: %s: %w", path, strings.TrimSpace(string(output)), err))
	}
	if branchCreated {
		if output, err := exec.Command("git", "-C", projectPath, "branch", "-D", "--", branch).CombinedOutput(); err != nil {
			cleanupErrors = append(cleanupErrors, fmt.Errorf("delete created branch %q: %s: %w", branch, strings.TrimSpace(string(output)), err))
		}
	}
	if len(cleanupErrors) == 0 {
		return cause
	}
	return errors.Join(append([]error{cause}, cleanupErrors...)...)
}

func (s *Service) insertWorkspace(workspace *api.Workspace) error {
	_, _, err := s.insertWorkspaceForCreation(workspace)
	return err
}

func (s *Service) insertWorkspaceForCreation(workspace *api.Workspace) (api.WorkspaceCreateResult, bool, error) {
	var replay api.WorkspaceCreateResult
	var found bool
	err := s.Store.Update(func(state *api.State) error {
		var err error
		replay, found, err = workspaceCreationReplay(
			state, workspace.CreationRequestID, workspace.CreationRequestHash,
		)
		if err != nil || found {
			return err
		}
		if err := taskExists(state, workspace.TaskID); err != nil {
			return err
		}
		if err := branchAlreadyHasWorkspace(state, workspace.ProjectID, workspace.Branch); err != nil {
			return err
		}
		workspace.Order = nextWorkspaceOrder(state.Workspaces, workspace.ProjectID)
		state.Workspaces = append(state.Workspaces, *workspace)
		return nil
	})
	return replay, found, err
}

func taskExists(state *api.State, taskID string) error {
	if taskID == "" {
		return nil
	}
	if !slices.ContainsFunc(state.Tasks, func(task api.Task) bool { return task.ID == taskID }) {
		return fmt.Errorf("task not found: %s", taskID)
	}
	return nil
}

// branchAlreadyHasWorkspace enforces the invariant that a project has at most
// one workspace per Git branch, regardless of whether the workspace is a root
// checkout or a git worktree.
func branchAlreadyHasWorkspace(state *api.State, projectID, branch string) error {
	// Detached Git worktrees do not have a branch name. Multiple detached
	// checkouts are valid and must not collide on the empty string.
	if strings.TrimSpace(branch) == "" {
		return nil
	}
	for i := range state.Workspaces {
		workspace := state.Workspaces[i]
		if workspace.ProjectID == projectID && workspace.Branch == branch {
			return fmt.Errorf("workspace already exists for branch %q (workspace %s)", branch, workspace.ID)
		}
	}
	return nil
}

type RemoveWorkspaceOptions struct {
	Force bool
	// RemoveWorktree controls whether a Git worktree directory is removed
	// together with its Warren workspace. It only applies to worktree-backed
	// workspaces; main checkouts are never deleted from disk.
	RemoveWorktree bool
}

func (s *Service) RemoveWorkspace(ctx context.Context, id string, options RemoveWorkspaceOptions) error {
	projectLock := s.lockWorkspaceLifecycle(id)
	if projectLock == nil {
		return fmt.Errorf("workspace not found: %s", id)
	}
	state := s.Store.Snapshot()
	var workspace *api.Workspace
	for i := range state.Workspaces {
		if state.Workspaces[i].ID == id {
			workspace = &state.Workspaces[i]
			break
		}
	}
	if workspace == nil {
		projectLock.Unlock()
		return fmt.Errorf("workspace not found: %s", id)
	}
	for _, session := range state.Sessions {
		if session.WorkspaceID == id && session.Lifecycle == "running" && !options.Force {
			projectLock.Unlock()
			return errors.New("workspace has running sessions; use --force")
		}
	}
	workspaceValue := *workspace
	err := s.Store.Update(func(value *api.State) error {
		projectID := workspaceValue.ProjectID
		value.Workspaces = filter(value.Workspaces, func(w api.Workspace) bool { return w.ID != id })
		value.Sessions = filter(value.Sessions, func(session api.Session) bool { return session.WorkspaceID != id })
		order := 0
		for i := range value.Workspaces {
			if value.Workspaces[i].ProjectID == projectID {
				value.Workspaces[i].Order = order
				order++
			}
		}
		// The owner is gone from this snapshot, so its arrangements go with it.
		reconcilePaneGroups(value)
		return nil
	})
	projectLock.Unlock()
	if err != nil {
		return err
	}
	s.invalidateMerge()

	// Publish the removal before doing best-effort runtime and filesystem
	// cleanup. This keeps the roster responsive and prevents a new session from
	// racing with a workspace that is already gone from durable state.
	if options.Force {
		_ = s.removeWorkspaceRuntime(ctx, state, id)
	}
	// Imported and locked worktrees are never removed from disk. The caller may
	// still delete Warren's workspace record, but filesystem ownership must be
	// explicit and a Git lock must be respected.
	if workspaceValue.Kind == "worktree" && options.RemoveWorktree && workspaceValue.ManagedWorktree && !workspaceValue.WorktreeLocked {
		s.removeWorktreeDirectory(workspaceValue, state.Projects)
	}
	return nil
}

// removeWorktreeDirectory is best-effort physical cleanup of a worktree-backed
// workspace. Removing the Warren workspace record must never depend on git
// succeeding: a stale registration, an already-removed directory, or a busy
// file must not leave the workspace stuck in state. Every failure is logged and
// the operation proceeds; a leftover directory (and possibly its git
// registration) is left on disk and would only be re-imported by an explicit
// `project add`.
func (s *Service) removeWorktreeDirectory(workspace api.Workspace, projects []api.Project) {
	var project api.Project
	for _, value := range projects {
		if value.ID == workspace.ProjectID {
			project = value
			break
		}
	}
	// External shells (Codex, Claude, ...) keep their cwd inside the worktree.
	// Terminate them before the git remove so deleting the directory cannot
	// strand their exec sessions on a removed cwd.
	if _, err := terminateProcessesUnder(workspace.Path); err != nil {
		s.logWarn("terminate worktree processes during workspace removal", "workspace", workspace.ID, "error", err)
	}
	if _, err := os.Stat(workspace.Path); err != nil {
		if !errors.Is(err, os.ErrNotExist) {
			s.logWarn("stat worktree path during workspace removal", "workspace", workspace.ID, "error", err)
		}
		// The worktree was already removed outside Warren. Converge on state
		// cleanup instead of failing on git's "not a worktree".
		return
	}
	if project.Path == "" {
		// The owning project was itself removed, so its git metadata is gone
		// with it. Leave the directory and let state cleanup proceed.
		return
	}
	if output, err := exec.Command("git", "-C", project.Path, "worktree", "remove", "--force", workspace.Path).CombinedOutput(); err != nil {
		// "not a working tree", a stale registration, or a busy file: leave the
		// directory on disk rather than failing the deletion the user asked for.
		s.logWarn("git worktree remove during workspace removal", "workspace", workspace.ID, "output", strings.TrimSpace(string(output)), "error", err)
	}
}

func findWorkspace(state api.State, id string) (api.Workspace, error) {
	for _, workspace := range state.Workspaces {
		if workspace.ID == id {
			return workspace, nil
		}
	}
	return api.Workspace{}, fmt.Errorf("workspace not found: %s", id)
}
