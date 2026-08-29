package server

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/store"
)

func seedTaskWorkspaces(t *testing.T, service *Service) {
	t.Helper()
	if err := service.Store.Update(func(state *api.State) error {
		state.Projects = []api.Project{
			{ID: "project-a", Name: "A"},
			{ID: "project-b", Name: "B"},
		}
		state.Workspaces = []api.Workspace{
			{ID: "workspace-a", ProjectID: "project-a", Name: "feature-a"},
			{ID: "workspace-b", ProjectID: "project-b", Name: "feature-b"},
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
}

func TestTaskAggregatesWorkspacesAcrossProjects(t *testing.T) {
	service, _, _ := testOrderService(t)
	seedTaskWorkspaces(t, service)

	task, err := service.CreateTask("Cross-repository delivery", "TAPD", "12345", "https://tapd.example.com/story/12345")
	if err != nil {
		t.Fatal(err)
	}
	if task.Source != "tapd" || task.ExternalID != "12345" {
		t.Fatalf("task = %#v", task)
	}
	for _, workspaceID := range []string{"workspace-a", "workspace-b"} {
		if err := service.AttachWorkspaceToTask(task.ID, workspaceID); err != nil {
			t.Fatal(err)
		}
	}

	roster := service.Roster(context.Background())
	if len(roster.Tasks) != 1 {
		t.Fatalf("tasks = %#v", roster.Tasks)
	}
	for _, workspace := range roster.Workspaces {
		if workspace.TaskID != task.ID {
			t.Fatalf("workspace %s task = %q, want %q", workspace.ID, workspace.TaskID, task.ID)
		}
	}
}

func TestTaskExternalIdentityAndURLValidation(t *testing.T) {
	service, _, _ := testOrderService(t)
	if _, err := service.CreateTask("Missing external ID", "tapd", "", ""); err == nil {
		t.Fatal("expected paired external identity validation")
	}
	if _, err := service.CreateTask("Bad URL", "", "", "javascript:alert(1)"); err == nil {
		t.Fatal("expected URL validation")
	}
	if _, err := service.CreateTask("First", "tapd", "123", ""); err != nil {
		t.Fatal(err)
	}
	if _, err := service.CreateTask("Duplicate", "TAPD", "123", ""); err == nil || !strings.Contains(err.Error(), "already exists") {
		t.Fatalf("duplicate error = %v", err)
	}
}

func TestCreateTaskWithRequestIDIsIdempotentAndNormalizesURLScheme(t *testing.T) {
	service, _, statePath := testOrderService(t)
	requestID := "11111111-1111-4111-8111-111111111111"

	first, err := service.CreateTaskWithRequestID(
		"Delivery", "TAPD", "123", "HTTPS://tracker.example/tasks/123", requestID,
	)
	if err != nil {
		t.Fatal(err)
	}
	reopened, err := store.Open(statePath, "test")
	if err != nil {
		t.Fatal(err)
	}
	restarted := &Service{Store: reopened, Runtime: &memoryRuntime{sessions: map[string][]byte{}}}
	second, err := restarted.CreateTaskWithRequestID(
		"Delivery", "TAPD", "123", "HTTPS://tracker.example/tasks/123", requestID,
	)
	if err != nil {
		t.Fatal(err)
	}
	if first != second || first.URL != "https://tracker.example/tasks/123" {
		t.Fatalf("idempotent tasks = %#v and %#v", first, second)
	}
	if first.CreationRequestID != "" || first.CreationRequestHash != "" ||
		second.CreationRequestID != "" || second.CreationRequestHash != "" {
		t.Fatalf("creation metadata leaked in task results: %#v and %#v", first, second)
	}
	if tasks := restarted.Store.Snapshot().Tasks; len(tasks) != 1 {
		t.Fatalf("tasks = %#v, want one resource", tasks)
	} else if tasks[0].CreationRequestID != requestID || tasks[0].CreationRequestHash == "" {
		t.Fatalf("persisted task creation metadata = %#v", tasks[0])
	}
	rosterTask := restarted.Roster(context.Background()).Tasks[0]
	if rosterTask.CreationRequestID != "" || rosterTask.CreationRequestHash != "" {
		t.Fatalf("creation metadata leaked in roster task: %#v", rosterTask)
	}

	if _, err := restarted.CreateTaskWithRequestID(
		"Different", "", "", "", requestID,
	); err == nil || !strings.Contains(err.Error(), "conflicting parameters") {
		t.Fatalf("conflict error = %v", err)
	}
	if _, err := restarted.CreateTaskWithRequestID(
		"Invalid request", "", "", "", "not-a-uuid",
	); err == nil || !strings.Contains(err.Error(), "request ID must be a UUID") {
		t.Fatalf("invalid request ID error = %v", err)
	}
}

func TestCreateTaskWithoutRequestIDKeepsLegacyNonIdempotentBehavior(t *testing.T) {
	service, _, _ := testOrderService(t)

	first, err := service.CreateTask("Same name", "", "", "")
	if err != nil {
		t.Fatal(err)
	}
	second, err := service.CreateTask("Same name", "", "", "")
	if err != nil {
		t.Fatal(err)
	}
	if first.ID == second.ID || len(service.Store.Snapshot().Tasks) != 2 {
		t.Fatalf("legacy creates = %#v and %#v", first, second)
	}
	for _, task := range []api.Task{first, second} {
		if task.CreationRequestID != "" || task.CreationRequestHash != "" {
			t.Fatalf("legacy task result has creation metadata: %#v", task)
		}
	}
	for _, task := range service.Store.Snapshot().Tasks {
		if task.CreationRequestID != "" || task.CreationRequestHash != "" {
			t.Fatalf("legacy task has creation metadata: %#v", task)
		}
	}
}

func TestTaskAttachRejectsConflictingMembership(t *testing.T) {
	service, _, _ := testOrderService(t)
	seedTaskWorkspaces(t, service)
	first, err := service.CreateTask("First", "", "", "")
	if err != nil {
		t.Fatal(err)
	}
	second, err := service.CreateTask("Second", "", "", "")
	if err != nil {
		t.Fatal(err)
	}
	if err := service.AttachWorkspaceToTask(first.ID, "workspace-a"); err != nil {
		t.Fatal(err)
	}
	if err := service.AttachWorkspaceToTask(second.ID, "workspace-a"); err == nil || !strings.Contains(err.Error(), "detach it first") {
		t.Fatalf("conflict error = %v", err)
	}
	if err := service.DetachWorkspaceFromTask(second.ID, "workspace-a"); err == nil {
		t.Fatal("expected guarded detach error")
	}
	if err := service.DetachWorkspaceFromTask(first.ID, "workspace-a"); err != nil {
		t.Fatal(err)
	}
	if err := service.AttachWorkspaceToTask(second.ID, "workspace-a"); err != nil {
		t.Fatal(err)
	}
}

func TestRemoveTaskOnlyDetachesWorkspaces(t *testing.T) {
	service, _, _ := testOrderService(t)
	seedTaskWorkspaces(t, service)
	task, err := service.CreateTask("Delivery", "", "", "")
	if err != nil {
		t.Fatal(err)
	}
	if err := service.AttachWorkspaceToTask(task.ID, "workspace-a"); err != nil {
		t.Fatal(err)
	}
	if err := service.Store.Update(func(state *api.State) error {
		state.Sessions = append(state.Sessions, api.Session{
			ID: "session-a", WorkspaceID: "workspace-a", Scope: "workspace", Lifecycle: "running", CreatedAt: time.Now().UTC(),
		})
		return nil
	}); err != nil {
		t.Fatal(err)
	}

	if err := service.RemoveTask(task.ID); err != nil {
		t.Fatal(err)
	}
	snapshot := service.Store.Snapshot()
	if len(snapshot.Tasks) != 0 || len(snapshot.Workspaces) != 2 || len(snapshot.Sessions) != 1 {
		t.Fatalf("state after task removal = %#v", snapshot)
	}
	if snapshot.Workspaces[0].TaskID != "" {
		t.Fatalf("workspace remained attached: %#v", snapshot.Workspaces[0])
	}
}

func TestMoveTaskPersistsOrder(t *testing.T) {
	service, _, _ := testOrderService(t)
	first, err := service.CreateTask("First", "", "", "")
	if err != nil {
		t.Fatal(err)
	}
	second, err := service.CreateTask("Second", "", "", "")
	if err != nil {
		t.Fatal(err)
	}
	third, err := service.CreateTask("Third", "", "", "")
	if err != nil {
		t.Fatal(err)
	}
	if err := service.MoveTask(third.ID, first.ID); err != nil {
		t.Fatal(err)
	}
	tasks := service.Roster(context.Background()).Tasks
	if len(tasks) != 3 || tasks[0].ID != third.ID || tasks[1].ID != first.ID || tasks[2].ID != second.ID {
		t.Fatalf("tasks after move = %#v", tasks)
	}
}
