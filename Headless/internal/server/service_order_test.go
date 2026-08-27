package server

import (
	"context"
	"log/slog"
	"net/http/httptest"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/store"
	"github.com/gorilla/websocket"
)

func testOrderService(t *testing.T) (*Service, *store.Store, string) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "state.json")
	state, err := store.Open(path, "test")
	if err != nil {
		t.Fatal(err)
	}
	return &Service{Store: state, Runtime: &memoryRuntime{sessions: map[string][]byte{}}}, state, path
}

func seedOrderedState(t *testing.T, state *store.Store) {
	t.Helper()
	now := time.Now().UTC()
	if err := state.Update(func(value *api.State) error {
		value.Projects = []api.Project{
			{ID: "project-a", Name: "alpha", Order: 2, CreatedAt: now.Add(1 * time.Minute)},
			{ID: "project-b", Name: "bravo", Order: 0, CreatedAt: now},
			{ID: "project-c", Name: "charlie", Order: 1, CreatedAt: now.Add(2 * time.Minute)},
		}
		value.Workspaces = []api.Workspace{
			{ID: "workspace-1", ProjectID: "project-a", Name: "one", Order: 1, CreatedAt: now},
			{ID: "workspace-2", ProjectID: "project-a", Name: "two", Order: 0, CreatedAt: now.Add(1 * time.Minute)},
			{ID: "workspace-3", ProjectID: "project-b", Name: "three", Order: 2, CreatedAt: now},
			{ID: "workspace-4", ProjectID: "project-b", Name: "four", Order: 1, CreatedAt: now},
			{ID: "workspace-5", ProjectID: "project-b", Name: "five", Order: 0, CreatedAt: now},
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
}

func TestRosterUsesStoredSidebarOrder(t *testing.T) {
	service, state, _ := testOrderService(t)
	seedOrderedState(t, state)

	roster := service.Roster(context.Background())
	projectIDs := make([]string, 0, len(roster.Projects))
	for _, project := range roster.Projects {
		projectIDs = append(projectIDs, project.ID)
	}
	if got, want := joinStrings(projectIDs), "project-b project-c project-a"; got != want {
		t.Fatalf("project order: got %s want %s", got, want)
	}

	workspaceIDs := make([]string, 0, len(roster.Workspaces))
	for _, workspace := range roster.Workspaces {
		workspaceIDs = append(workspaceIDs, workspace.ID)
	}
	// project-a (id < project-b): workspace-2 then workspace-1; project-b: five, four, three.
	if got, want := joinStrings(workspaceIDs), "workspace-2 workspace-1 workspace-5 workspace-4 workspace-3"; got != want {
		t.Fatalf("workspace order: got %s want %s", got, want)
	}
}

func TestMoveProjectBeforePersistsAcrossRestart(t *testing.T) {
	service, state, path := testOrderService(t)
	seedOrderedState(t, state)

	if err := service.MoveProject("project-a", "project-b"); err != nil {
		t.Fatal(err)
	}
	roster := service.Roster(context.Background())
	if got, want := roster.Projects[0].ID, "project-a"; got != want {
		t.Fatalf("first project after move: got %s want %s", got, want)
	}

	reopened, err := store.Open(path, "test")
	if err != nil {
		t.Fatal(err)
	}
	snapshot := reopened.Snapshot()
	orders := map[string]int{}
	for _, project := range snapshot.Projects {
		orders[project.ID] = project.Order
	}
	if orders["project-a"] != 0 || orders["project-b"] != 1 || orders["project-c"] != 2 {
		t.Fatalf("persisted orders after restart: %#v", orders)
	}
}

func TestMoveProjectToEnd(t *testing.T) {
	service, state, _ := testOrderService(t)
	seedOrderedState(t, state)

	if err := service.MoveProject("project-b", ""); err != nil {
		t.Fatal(err)
	}
	roster := service.Roster(context.Background())
	if got, want := roster.Projects[len(roster.Projects)-1].ID, "project-b"; got != want {
		t.Fatalf("last project after move: got %s want %s", got, want)
	}
}

func TestMoveProjectUnknownTargets(t *testing.T) {
	service, state, _ := testOrderService(t)
	seedOrderedState(t, state)

	if err := service.MoveProject("missing", ""); err == nil {
		t.Fatal("expected missing source error")
	}
	if err := service.MoveProject("project-a", "missing"); err == nil {
		t.Fatal("expected missing before error")
	}
}

func TestMoveWorkspaceStaysInsideProject(t *testing.T) {
	service, state, _ := testOrderService(t)
	seedOrderedState(t, state)

	if err := service.MoveWorkspace("workspace-1", "workspace-2"); err != nil {
		t.Fatal(err)
	}
	roster := service.Roster(context.Background())
	workspaceIDs := make([]string, 0, len(roster.Workspaces))
	for _, workspace := range roster.Workspaces {
		workspaceIDs = append(workspaceIDs, workspace.ID)
	}
	// workspace-1 moved before workspace-2 inside project-a; project-b untouched.
	if got, want := joinStrings(workspaceIDs), "workspace-1 workspace-2 workspace-5 workspace-4 workspace-3"; got != want {
		t.Fatalf("workspace order after move: got %s want %s", got, want)
	}
}

func TestMoveWorkspaceToEnd(t *testing.T) {
	service, state, _ := testOrderService(t)
	seedOrderedState(t, state)

	if err := service.MoveWorkspace("workspace-5", ""); err != nil {
		t.Fatal(err)
	}
	roster := service.Roster(context.Background())
	var projectB []string
	for _, workspace := range roster.Workspaces {
		if workspace.ProjectID == "project-b" {
			projectB = append(projectB, workspace.ID)
		}
	}
	if got, want := joinStrings(projectB), "workspace-4 workspace-3 workspace-5"; got != want {
		t.Fatalf("workspace order in project-b: got %s want %s", got, want)
	}
}

func TestMoveWorkspaceUnknownTargets(t *testing.T) {
	service, state, _ := testOrderService(t)
	seedOrderedState(t, state)

	if err := service.MoveWorkspace("missing", ""); err == nil {
		t.Fatal("expected missing source error")
	}
	if err := service.MoveWorkspace("workspace-1", "missing"); err == nil {
		t.Fatal("expected missing before error")
	}
}

func TestAddProjectAssignsNextOrder(t *testing.T) {
	service, state, _ := testOrderService(t)
	seedOrderedState(t, state)

	directory := t.TempDir()
	if output, err := exec.Command("git", "-C", directory, "init", "--quiet").CombinedOutput(); err != nil {
		t.Fatalf("git init: %s: %v", output, err)
	}
	if _, err := service.AddProject(directory, "delta"); err != nil {
		t.Fatal(err)
	}
	roster := service.Roster(context.Background())
	if got, want := roster.Projects[len(roster.Projects)-1].Order, 3; got != want {
		t.Fatalf("new project order: got %d want %d", got, want)
	}
}

func TestMoveMethodsOverWebSocket(t *testing.T) {
	service, state, _ := testOrderService(t)
	seedOrderedState(t, state)

	server := httptest.NewServer(NewHTTPServer(service, "secret", slog.Default()).Handler())
	defer server.Close()
	endpoint := "ws" + strings.TrimPrefix(server.URL, "http") + "/v1/ws"
	connection, _, err := websocket.DefaultDialer.Dial(endpoint, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer connection.Close()
	if err := connection.WriteJSON(api.Envelope{
		Type:                 "auth",
		Token:                "secret",
		Version:              api.Version,
		TerminalStateFormats: []string{terminalStateFormatANSI},
	}); err != nil {
		t.Fatal(err)
	}
	var welcome map[string]any
	if err := connection.ReadJSON(&welcome); err != nil {
		t.Fatal(err)
	}

	requestResult[map[string]any](t, connection, "project.move", map[string]any{"id": "project-a", "before": "project-b"})
	requestResult[map[string]any](t, connection, "workspace.move", map[string]any{"id": "workspace-1", "before": "workspace-2"})

	roster := requestResult[api.State](t, connection, "roster", nil)
	projectIDs := make([]string, 0, len(roster.Projects))
	for _, project := range roster.Projects {
		projectIDs = append(projectIDs, project.ID)
	}
	if got, want := joinStrings(projectIDs), "project-a project-b project-c"; got != want {
		t.Fatalf("project order over websocket: got %s want %s", got, want)
	}
	workspaceIDs := make([]string, 0, len(roster.Workspaces))
	for _, workspace := range roster.Workspaces {
		workspaceIDs = append(workspaceIDs, workspace.ID)
	}
	if got, want := joinStrings(workspaceIDs), "workspace-1 workspace-2 workspace-5 workspace-4 workspace-3"; got != want {
		t.Fatalf("workspace order over websocket: got %s want %s", got, want)
	}
}

func joinStrings(values []string) string {
	result := ""
	for index, value := range values {
		if index > 0 {
			result += " "
		}
		result += value
	}
	return result
}
