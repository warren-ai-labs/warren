package server

import (
	"context"
	"errors"
	"log/slog"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/store"
)

func TestCreateTaskWorkspaceAggregatesProjects(t *testing.T) {
	service := newTaskWorkspaceService(t)
	first := addTaskWorkspaceProject(t, service, filepath.Join(t.TempDir(), "first"))
	second := addTaskWorkspaceProject(t, service, filepath.Join(t.TempDir(), "second"))
	task, err := service.CreateTask("Cross-repository delivery", "", "", "")
	if err != nil {
		t.Fatal(err)
	}

	for _, project := range []api.Project{first, second} {
		workspace, err := service.CreateTaskWorkspace(project.ID, task.ID, "feature/aggregate", "", "")
		if err != nil {
			t.Fatal(err)
		}
		if workspace.TaskID != task.ID || workspace.ProjectID != project.ID {
			t.Fatalf("workspace = %#v, want project %q in task %q", workspace, project.ID, task.ID)
		}
	}
}

func TestCreateTaskWorkspaceRejectsMissingTaskBeforeFilesystemMutation(t *testing.T) {
	service := newTaskWorkspaceService(t)
	project := addTaskWorkspaceProject(t, service, filepath.Join(t.TempDir(), "repository"))
	parent := filepath.Join(t.TempDir(), "missing-parent")
	target := filepath.Join(parent, "workspace")

	_, err := service.CreateTaskWorkspace(project.ID, "missing-task", "feature/rejected", "", target)
	if err == nil || !strings.Contains(err.Error(), "task not found: missing-task") {
		t.Fatalf("error = %v, want missing task", err)
	}
	if _, err := os.Stat(parent); !os.IsNotExist(err) {
		t.Fatalf("workspace parent was mutated before task validation: %v", err)
	}
	if exec.Command("git", "-C", project.Path, "show-ref", "--verify", "--quiet", "refs/heads/feature/rejected").Run() == nil {
		t.Fatal("branch was created before task validation")
	}
}

func TestCreateWorkspaceWithoutTaskKeepsExistingBehavior(t *testing.T) {
	service := newTaskWorkspaceService(t)
	project := addTaskWorkspaceProject(t, service, filepath.Join(t.TempDir(), "repository"))

	workspace, err := service.CreateWorkspace(project.ID, "feature/standalone", "", "")
	if err != nil {
		t.Fatal(err)
	}
	if workspace.TaskID != "" {
		t.Fatalf("workspace task = %q, want empty", workspace.TaskID)
	}
	if workspace.CreationRequestID != "" || workspace.CreationRequestHash != "" {
		t.Fatalf("legacy workspace result has creation metadata: %#v", workspace)
	}
	for _, stored := range service.Store.Snapshot().Workspaces {
		if stored.CreationRequestID != "" || stored.CreationRequestHash != "" {
			t.Fatalf("legacy workspace has persisted creation metadata: %#v", stored)
		}
	}
}

func TestCreateWorkspaceWithRequestIDSurvivesRestartWithoutRepeatingCreation(t *testing.T) {
	directory := t.TempDir()
	statePath := filepath.Join(directory, "state.json")
	state, err := store.Open(statePath, "test-host")
	if err != nil {
		t.Fatal(err)
	}
	service := &Service{
		Store:        state,
		Runtime:      &memoryRuntime{sessions: map[string][]byte{}},
		WorktreeRoot: filepath.Join(directory, "worktrees"),
	}
	project := addTaskWorkspaceProject(t, service, filepath.Join(directory, "repository"))
	requestID := "22222222-2222-4222-8222-222222222222"

	first, err := service.CreateTaskWorkspaceWithRequestID(
		project.ID, "", "feature/idempotent", "Idempotent", "", requestID,
	)
	if err != nil {
		t.Fatal(err)
	}
	firstWorkspaceCount := len(service.Store.Snapshot().Workspaces)
	firstWorktrees := taskWorkspaceWorktreePaths(t, project.Path)
	reopened, err := store.Open(statePath, "test-host")
	if err != nil {
		t.Fatal(err)
	}
	restarted := &Service{
		Store:        reopened,
		Runtime:      &memoryRuntime{sessions: map[string][]byte{}},
		WorktreeRoot: filepath.Join(directory, "worktrees"),
	}
	second, err := restarted.CreateTaskWorkspaceWithRequestID(
		project.ID, "", "feature/idempotent", "Idempotent", "", requestID,
	)
	if err != nil {
		t.Fatal(err)
	}
	if first != second {
		t.Fatalf("idempotent workspace results = %#v and %#v", first, second)
	}
	if first.CreationRequestID != "" || first.CreationRequestHash != "" ||
		second.CreationRequestID != "" || second.CreationRequestHash != "" {
		t.Fatalf("creation metadata leaked in workspace results: %#v and %#v", first, second)
	}
	secondWorktrees := taskWorkspaceWorktreePaths(t, project.Path)
	if strings.Join(firstWorktrees, "\n") != strings.Join(secondWorktrees, "\n") {
		t.Fatalf("worktrees changed during replay: before=%q after=%q", firstWorktrees, secondWorktrees)
	}
	storedWorkspaces := restarted.Store.Snapshot().Workspaces
	matching := 0
	for _, workspace := range storedWorkspaces {
		if workspace.CreationRequestID == requestID {
			if workspace.CreationRequestHash == "" {
				t.Fatalf("persisted workspace creation hash is empty: %#v", workspace)
			}
			matching++
		}
	}
	if matching != 1 {
		t.Fatalf("matching workspaces = %d, want one resource", matching)
	}
	if len(storedWorkspaces) != firstWorkspaceCount {
		t.Fatalf("workspace count after replay = %d, want %d", len(storedWorkspaces), firstWorkspaceCount)
	}
	for _, rosterWorkspace := range restarted.Roster(context.Background()).Workspaces {
		if rosterWorkspace.CreationRequestID != "" || rosterWorkspace.CreationRequestHash != "" {
			t.Fatalf("creation metadata leaked in roster workspace: %#v", rosterWorkspace)
		}
	}

	if _, err := restarted.CreateTaskWorkspaceWithRequestID(
		project.ID, "", "feature/different", "Different", "", requestID,
	); err == nil || !strings.Contains(err.Error(), "conflicting parameters") {
		t.Fatalf("conflict error = %v", err)
	}
	if _, err := restarted.CreateTaskWorkspaceWithRequestID(
		project.ID, "", "feature/invalid-request", "Invalid request", "", "not-a-uuid",
	); err == nil || !strings.Contains(err.Error(), "request ID must be a UUID") {
		t.Fatalf("invalid request ID error = %v", err)
	}
}

func TestCreationRequestIDCannotCrossResourceTypes(t *testing.T) {
	service := newTaskWorkspaceService(t)
	project := addTaskWorkspaceProject(t, service, filepath.Join(t.TempDir(), "repository"))
	requestID := "33333333-3333-4333-8333-333333333333"
	if _, err := service.CreateTaskWithRequestID("Delivery", "", "", "", requestID); err != nil {
		t.Fatal(err)
	}

	_, err := service.CreateTaskWorkspaceWithRequestID(
		project.ID, "", "feature/cross-type", "Cross type", "", requestID,
	)
	if err == nil || !strings.Contains(err.Error(), "already used by task.create") {
		t.Fatalf("cross-type error = %v", err)
	}

	workspaceRequestID := "66666666-6666-4666-8666-666666666666"
	if _, err := service.CreateTaskWorkspaceWithRequestID(
		project.ID, "", "feature/cross-type-reverse", "Cross type reverse", "", workspaceRequestID,
	); err != nil {
		t.Fatal(err)
	}
	if _, err := service.CreateTaskWithRequestID("Reverse delivery", "", "", "", workspaceRequestID); err == nil ||
		!strings.Contains(err.Error(), "already used by workspace.create") {
		t.Fatalf("reverse cross-type error = %v", err)
	}
}

func TestInsertWorkspaceRevalidatesTaskMembership(t *testing.T) {
	service := newTaskWorkspaceService(t)
	workspace := api.Workspace{ID: "workspace-1", ProjectID: "project-1", TaskID: "removed-task", Branch: "feature/race"}

	err := service.insertWorkspace(&workspace)
	if err == nil || !strings.Contains(err.Error(), "task not found: removed-task") {
		t.Fatalf("error = %v, want final task validation", err)
	}
	if len(service.Store.Snapshot().Workspaces) != 0 {
		t.Fatal("workspace was inserted without its task")
	}
}

func TestCreateTaskWorkspaceRollsBackManagedGitArtifactsAfterTaskRemoval(t *testing.T) {
	tests := []struct {
		name              string
		branch            string
		preexistingBranch bool
		wantBranchLeft    bool
	}{
		{name: "created branch", branch: "feature/created", wantBranchLeft: false},
		{name: "existing branch", branch: "feature/existing", preexistingBranch: true, wantBranchLeft: true},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			service := newTaskWorkspaceService(t)
			project := addTaskWorkspaceProject(t, service, filepath.Join(t.TempDir(), "repository"))
			if test.preexistingBranch {
				runTaskWorkspaceGit(t, project.Path, "branch", test.branch)
			}
			task, err := service.CreateTask("Delivery", "", "", "")
			if err != nil {
				t.Fatal(err)
			}
			workspaceCount := len(service.Store.Snapshot().Workspaces)
			target := filepath.Join(t.TempDir(), "workspace")
			service.beforeWorkspaceInsert = func() {
				if _, err := os.Stat(target); err != nil {
					t.Fatalf("worktree was not created before insert: %v", err)
				}
				if !taskWorkspaceBranchExists(project.Path, test.branch) {
					t.Fatal("branch was not created before insert")
				}
				if err := service.RemoveTask(task.ID); err != nil {
					t.Fatal(err)
				}
			}

			_, err = service.CreateTaskWorkspace(project.ID, task.ID, test.branch, "", target)
			if err == nil || !strings.Contains(err.Error(), "task not found: "+task.ID) {
				t.Fatalf("error = %v, want original task validation failure", err)
			}
			if len(service.Store.Snapshot().Workspaces) != workspaceCount {
				t.Fatal("workspace state remained after insert failure")
			}
			if _, err := os.Stat(target); !os.IsNotExist(err) {
				t.Fatalf("worktree path remained after insert failure: %v", err)
			}
			if got := taskWorkspaceBranchExists(project.Path, test.branch); got != test.wantBranchLeft {
				t.Fatalf("branch exists = %t, want %t", got, test.wantBranchLeft)
			}
		})
	}
}

func TestRollbackManagedWorktreeJoinsCleanupFailures(t *testing.T) {
	original := errors.New("store update failed")
	err := rollbackManagedWorktree(original, t.TempDir(), filepath.Join(t.TempDir(), "missing-worktree"), "feature/missing", true)
	if !errors.Is(err, original) {
		t.Fatalf("rollback error = %v, want original failure", err)
	}
	for _, message := range []string{"remove git worktree", "delete created branch"} {
		if !strings.Contains(err.Error(), message) {
			t.Fatalf("cleanup error = %v, want %q", err, message)
		}
	}
}

func TestWebSocketCreatesTaskWorkspacesAndPreservesOptionalTask(t *testing.T) {
	service := newTaskWorkspaceService(t)
	server := httptest.NewServer(NewHTTPServer(service, "secret", slog.Default()).Handler())
	defer server.Close()
	mutator := openAuthenticatedConnection(t, server.URL, "/v1/ws")
	defer mutator.Close()

	first := addTaskWorkspaceProject(t, service, filepath.Join(t.TempDir(), "first"))
	second := addTaskWorkspaceProject(t, service, filepath.Join(t.TempDir(), "second"))
	observer := openAuthenticatedConnection(t, server.URL, "/v1/ws")
	defer observer.Close()
	waitForRoster(t, observer, func(api.State) bool { return true })

	task := requestResult[api.Task](t, mutator, "task.create", map[string]any{"name": "Delivery"})
	branches := []string{"feature/ws-first", "feature/ws-second"}
	for index, project := range []api.Project{first, second} {
		workspace := requestResult[api.WorkspaceCreateResult](t, mutator, "workspace.create", map[string]any{
			"project": project.ID,
			"task":    task.ID,
			"branch":  branches[index],
		})
		if workspace.TaskID != task.ID {
			t.Fatalf("workspace task = %q, want %q", workspace.TaskID, task.ID)
		}
		waitForRoster(t, observer, func(state api.State) bool {
			for _, observed := range state.Workspaces {
				if observed.ID == workspace.ID && observed.ProjectID == project.ID && observed.TaskID == task.ID {
					return true
				}
			}
			return false
		})
	}

	missingParent := filepath.Join(t.TempDir(), "missing-parent")
	errorText := requestError(t, mutator, "workspace.create", map[string]any{
		"project": first.ID,
		"task":    "missing-task",
		"branch":  "feature/rejected-over-ws",
		"path":    filepath.Join(missingParent, "workspace"),
	})
	if !strings.Contains(errorText, "task not found: missing-task") {
		t.Fatalf("error = %q, want missing task", errorText)
	}
	if _, err := os.Stat(missingParent); !os.IsNotExist(err) {
		t.Fatalf("workspace parent was mutated before task validation: %v", err)
	}

	standalone := requestResult[api.WorkspaceCreateResult](t, mutator, "workspace.create", map[string]any{
		"project": first.ID,
		"branch":  "feature/standalone-over-ws",
	})
	if standalone.TaskID != "" {
		t.Fatalf("standalone workspace task = %q, want empty", standalone.TaskID)
	}
}

func TestWebSocketCreateRequestIDsReturnTheFirstPersistedResults(t *testing.T) {
	service := newTaskWorkspaceService(t)
	server := httptest.NewServer(NewHTTPServer(service, "secret", slog.Default()).Handler())
	defer server.Close()
	connection := openAuthenticatedConnection(t, server.URL, "/v1/ws")
	defer connection.Close()
	retryConnection := openAuthenticatedConnection(t, server.URL, "/v1/ws")
	defer retryConnection.Close()
	project := addTaskWorkspaceProject(t, service, filepath.Join(t.TempDir(), "repository"))

	taskParams := map[string]any{
		"name": "Delivery", "requestId": "44444444-4444-4444-8444-444444444444",
	}
	firstTask := requestResult[api.Task](t, connection, "task.create", taskParams)
	secondTask := requestResult[api.Task](t, retryConnection, "task.create", taskParams)
	if firstTask != secondTask || len(service.Store.Snapshot().Tasks) != 1 {
		t.Fatalf("task results = %#v and %#v", firstTask, secondTask)
	}

	workspaceParams := map[string]any{
		"project":   project.ID,
		"task":      firstTask.ID,
		"branch":    "feature/wire-idempotent",
		"requestId": "55555555-5555-4555-8555-555555555555",
	}
	firstWorkspace := requestResult[api.WorkspaceCreateResult](t, connection, "workspace.create", workspaceParams)
	secondWorkspace := requestResult[api.WorkspaceCreateResult](t, retryConnection, "workspace.create", workspaceParams)
	matching := 0
	for _, workspace := range service.Store.Snapshot().Workspaces {
		if workspace.CreationRequestID == "55555555-5555-4555-8555-555555555555" {
			matching++
		}
	}
	if firstWorkspace != secondWorkspace || matching != 1 {
		t.Fatalf("workspace results = %#v and %#v", firstWorkspace, secondWorkspace)
	}
}

func newTaskWorkspaceService(t *testing.T) *Service {
	t.Helper()
	directory := t.TempDir()
	state, err := store.Open(filepath.Join(directory, "state.json"), "test-host")
	if err != nil {
		t.Fatal(err)
	}
	return &Service{
		Store:        state,
		Runtime:      &memoryRuntime{sessions: map[string][]byte{}},
		WorktreeRoot: filepath.Join(directory, "worktrees"),
	}
}

func addTaskWorkspaceProject(t *testing.T, service *Service, repository string) api.Project {
	t.Helper()
	if err := os.MkdirAll(repository, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, arguments := range [][]string{
		{"init", "--quiet", "--initial-branch=main"},
		{"-c", "user.name=Warren Tests", "-c", "user.email=warren@example.invalid", "commit", "--quiet", "--allow-empty", "-m", "initial"},
	} {
		if output, err := exec.Command("git", append([]string{"-C", repository}, arguments...)...).CombinedOutput(); err != nil {
			t.Fatalf("git %v: %s: %v", arguments, output, err)
		}
	}
	project, err := service.AddProject(repository, "")
	if err != nil {
		t.Fatal(err)
	}
	return project
}

func runTaskWorkspaceGit(t *testing.T, repository string, arguments ...string) {
	t.Helper()
	if output, err := exec.Command("git", append([]string{"-C", repository}, arguments...)...).CombinedOutput(); err != nil {
		t.Fatalf("git %v: %s: %v", arguments, output, err)
	}
}

func taskWorkspaceBranchExists(repository, branch string) bool {
	return exec.Command("git", "-C", repository, "show-ref", "--verify", "--quiet", "refs/heads/"+branch).Run() == nil
}

func taskWorkspaceWorktreePaths(t *testing.T, repository string) []string {
	t.Helper()
	output, err := exec.Command("git", "-C", repository, "worktree", "list", "--porcelain").CombinedOutput()
	if err != nil {
		t.Fatalf("list worktrees: %s: %v", output, err)
	}
	var paths []string
	for _, line := range strings.Split(string(output), "\n") {
		if path, found := strings.CutPrefix(line, "worktree "); found {
			paths = append(paths, path)
		}
	}
	return paths
}
