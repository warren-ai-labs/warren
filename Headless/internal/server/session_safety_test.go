package server

import (
	"context"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/store"
)

func TestSessionMoveCASPreflightAndUndo(t *testing.T) {
	state, err := store.Open(filepath.Join(t.TempDir(), "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	workspace := api.Workspace{ID: "workspace-target", ProjectID: "project-1", Name: "target", Path: t.TempDir(), Kind: "root"}
	if err := state.Update(func(value *api.State) error {
		value.Workspaces = append(value.Workspaces, workspace)
		value.Sessions = append(value.Sessions, api.Session{
			ID: "session-1", TerminalGroupID: value.TerminalGroups[0].ID,
			Scope: api.SessionScopeTerminalGroup, AgentSessionID: "thread-1", Lifecycle: "running",
		})
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	service := &Service{Store: state}

	expectedWorkspace := ""
	expectedAgent := "thread-1"
	preflight, err := service.PreflightSessionMove("session-1", workspace.ID, "", SessionMoveExpectations{
		WorkspaceID: &expectedWorkspace, AgentSessionID: &expectedAgent,
	})
	if err != nil {
		t.Fatal(err)
	}
	if !preflight.Allowed || preflight.SourceTerminalGroupID == "" || preflight.DestinationWorkspaceID != workspace.ID {
		t.Fatalf("preflight = %#v", preflight)
	}
	if got := len(state.Snapshot().Operations); got != 0 {
		t.Fatalf("preflight changed operation log: %d", got)
	}

	moved, err := service.MoveSessionWithExpectations(context.Background(), "session-1", workspace.ID, "", SessionMoveExpectations{
		WorkspaceID: &expectedWorkspace, AgentSessionID: &expectedAgent,
	})
	if err != nil {
		t.Fatal(err)
	}
	if moved.WorkspaceID != workspace.ID || moved.OperationID == "" {
		t.Fatalf("moved = %#v, want operation ID", moved)
	}
	operationID := moved.OperationID

	staleWorkspace := "stale-workspace"
	if _, err := service.MoveSessionWithExpectations(context.Background(), "session-1", "", state.Snapshot().TerminalGroups[0].ID, SessionMoveExpectations{WorkspaceID: &staleWorkspace}); err == nil || !strings.Contains(err.Error(), "stale session context") {
		t.Fatalf("stale move error = %v, want actionable CAS error", err)
	}
	current, ok := service.Session("session-1")
	if !ok || current.WorkspaceID != workspace.ID {
		t.Fatalf("stale move changed session: %#v", current)
	}

	reverted, err := service.UndoSessionMove(operationID)
	if err != nil {
		t.Fatal(err)
	}
	if reverted.TerminalGroupID == "" || reverted.WorkspaceID != "" || reverted.OperationID == "" {
		t.Fatalf("reverted = %#v", reverted)
	}
	if _, err := service.UndoSessionMove(operationID); err == nil || !strings.Contains(err.Error(), "already reverted") {
		t.Fatalf("second undo error = %v, want already reverted", err)
	}
	if got := len(state.Snapshot().Operations); got != 2 {
		t.Fatalf("operation log length = %d, want original and reversal", got)
	}
}

func TestSessionUndoFailsClosedAfterInterveningMove(t *testing.T) {
	state, err := store.Open(filepath.Join(t.TempDir(), "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	firstWorkspace := api.Workspace{ID: "workspace-first", ProjectID: "project-1", Name: "first", Path: t.TempDir(), Kind: "root"}
	secondWorkspace := api.Workspace{ID: "workspace-second", ProjectID: "project-1", Name: "second", Path: t.TempDir(), Kind: "root"}
	if err := state.Update(func(value *api.State) error {
		value.Workspaces = append(value.Workspaces, firstWorkspace, secondWorkspace)
		value.Sessions = append(value.Sessions, api.Session{ID: "session-2", WorkspaceID: firstWorkspace.ID, Scope: api.SessionScopeWorkspace, Lifecycle: "running"})
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	service := &Service{Store: state}
	moved, err := service.MoveSession(context.Background(), "session-2", secondWorkspace.ID, "")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := service.MoveSession(context.Background(), "session-2", firstWorkspace.ID, ""); err != nil {
		t.Fatal(err)
	}
	if _, err := service.UndoSessionMove(moved.OperationID); err == nil || !strings.Contains(err.Error(), "context changed") {
		t.Fatalf("undo error = %v, want fail-closed context error", err)
	}
	current, _ := service.Session("session-2")
	if current.WorkspaceID != firstWorkspace.ID {
		t.Fatalf("failed undo changed session: %#v", current)
	}
}

func TestSessionSafetyMethodsOverWebSocket(t *testing.T) {
	state, err := store.Open(filepath.Join(t.TempDir(), "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	workspace := api.Workspace{ID: "workspace-api", ProjectID: "project-1", Name: "api", Path: t.TempDir(), Kind: "root"}
	group := state.Snapshot().TerminalGroups[0]
	if err := state.Update(func(value *api.State) error {
		value.Workspaces = append(value.Workspaces, workspace)
		value.Sessions = append(value.Sessions, api.Session{ID: "session-api", TerminalGroupID: group.ID, Scope: api.SessionScopeTerminalGroup, AgentSessionID: "thread-api", Lifecycle: "running"})
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	service := &Service{Store: state}
	httpServer := httptest.NewServer(NewHTTPServer(service, "secret", nil).Handler())
	defer httpServer.Close()
	connection := openAuthenticatedConnection(t, httpServer.URL, "/v1/ws")
	defer connection.Close()

	current := requestResult[api.Session](t, connection, "session.current", map[string]any{"id": "session-api"})
	if current.ID != "session-api" || current.AgentSessionID != "thread-api" {
		t.Fatalf("current session = %#v", current)
	}
	preflight := requestResult[api.SessionMovePreflight](t, connection, "session.move.preflight", map[string]any{
		"id": "session-api", "workspace": workspace.ID, "expectedWorkspace": "", "expectedAgentSession": "thread-api",
	})
	if !preflight.Allowed || preflight.SourceTerminalGroupID != group.ID {
		t.Fatalf("preflight = %#v", preflight)
	}
	moved := requestResult[api.Session](t, connection, "session.move", map[string]any{
		"id": "session-api", "workspace": workspace.ID, "expectedWorkspace": "", "expectedAgentSession": "thread-api",
	})
	if moved.OperationID == "" {
		t.Fatalf("move result missing operation ID: %#v", moved)
	}
	reverted := requestResult[api.Session](t, connection, "session.undo", map[string]any{"operation": moved.OperationID})
	if reverted.TerminalGroupID != group.ID || reverted.WorkspaceID != "" {
		t.Fatalf("undo result = %#v", reverted)
	}
}
