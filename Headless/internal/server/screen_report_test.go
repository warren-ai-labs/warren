package server

import (
	"net/http/httptest"
	"path/filepath"
	"testing"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/store"
)

func TestScreenReportReportsPositionToSessionCurrent(t *testing.T) {
	state, err := store.Open(filepath.Join(t.TempDir(), "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	group := api.TerminalGroup{ID: "group-1", Name: "Default"}
	if err := state.Update(func(value *api.State) error {
		value.TerminalGroups = []api.TerminalGroup{group}
		value.Sessions = []api.Session{
			{ID: "session-1", TerminalGroupID: group.ID, Scope: api.SessionScopeTerminalGroup, Lifecycle: "running"},
			{ID: "session-2", TerminalGroupID: group.ID, Scope: api.SessionScopeTerminalGroup, Lifecycle: "running", Title: "second"},
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	service := &Service{Store: state}
	httpServer := httptest.NewServer(NewHTTPServer(service, "secret", nil).Handler())
	defer httpServer.Close()
	connection := openAuthenticatedConnection(t, httpServer.URL, "/v1/ws")
	defer connection.Close()

	initial := requestResult[api.Session](t, connection, "session.current", map[string]any{"id": "session-1"})
	if initial.ScreenPosition != 0 || initial.ScreenPaneCount != 0 {
		t.Fatalf("expected no screen position before a report, got %d/%d", initial.ScreenPosition, initial.ScreenPaneCount)
	}

	reportResult := requestResult[map[string]any](t, connection, "screen.report", map[string]any{
		"sessions": []any{"session-1", "session-2"},
	})
	if reportResult["reported"] != true {
		t.Fatalf("expected reported true, got %#v", reportResult)
	}

	current := requestResult[api.Session](t, connection, "session.current", map[string]any{"id": "session-2"})
	if current.ScreenPosition != 2 || current.ScreenPaneCount != 2 {
		t.Fatalf("expected pane 2 of 2, got %d/%d", current.ScreenPosition, current.ScreenPaneCount)
	}

	// The Session record must not disclose the neighbours; that is what
	// screen.panes is for.
	panes := requestResult[api.ScreenPanesResult](t, connection, "screen.panes", map[string]any{"id": "session-2"})
	if len(panes.Screens) != 1 {
		t.Fatalf("expected one screen, got %#v", panes.Screens)
	}
	screen := panes.Screens[0]
	if screen.Position != 2 || screen.PaneCount != 2 || len(screen.Panes) != 2 {
		t.Fatalf("unexpected screen layout: %#v", screen)
	}
	if screen.Panes[0].SessionID != "session-1" || screen.Panes[0].Index != 1 || screen.Panes[0].Current {
		t.Fatalf("unexpected first pane: %#v", screen.Panes[0])
	}
	if screen.Panes[1].SessionID != "session-2" || !screen.Panes[1].Current || screen.Panes[1].Title != "second" {
		t.Fatalf("unexpected second pane: %#v", screen.Panes[1])
	}
	if errorText := requestError(t, connection, "screen.panes", map[string]any{"id": "missing"}); errorText == "" {
		t.Fatal("expected screen.panes to reject an unknown session")
	}
}

// A CLI invoked inside a Session dials its own connection and never reports a
// screen. It still has to learn where that Session sits, so the read crosses
// peers while the reported state stays owned by the client that reported it.
func TestScreenPanesAnswersAcrossPeers(t *testing.T) {
	state, err := store.Open(filepath.Join(t.TempDir(), "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	group := api.TerminalGroup{ID: "group-1", Name: "Default"}
	if err := state.Update(func(value *api.State) error {
		value.TerminalGroups = []api.TerminalGroup{group}
		value.Sessions = []api.Session{
			{ID: "session-1", TerminalGroupID: group.ID, Scope: api.SessionScopeTerminalGroup, Lifecycle: "running"},
			{ID: "session-2", TerminalGroupID: group.ID, Scope: api.SessionScopeTerminalGroup, Lifecycle: "running"},
			{ID: "session-3", TerminalGroupID: group.ID, Scope: api.SessionScopeTerminalGroup, Lifecycle: "running"},
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	service := &Service{Store: state}
	httpServer := httptest.NewServer(NewHTTPServer(service, "secret", nil).Handler())
	defer httpServer.Close()
	window := openAuthenticatedConnection(t, httpServer.URL, "/v1/ws")
	defer window.Close()
	cli := openAuthenticatedConnection(t, httpServer.URL, "/v1/ws")
	defer cli.Close()

	requestResult[map[string]any](t, window, "screen.report", map[string]any{
		"sessions": []any{"session-1", "session-3"},
	})

	current := requestResult[api.Session](t, cli, "session.current", map[string]any{"id": "session-3"})
	if current.ScreenPosition != 2 || current.ScreenPaneCount != 2 {
		t.Fatalf("expected pane 2 of 2 from another peer's screen, got %d/%d", current.ScreenPosition, current.ScreenPaneCount)
	}
	panes := requestResult[api.ScreenPanesResult](t, cli, "screen.panes", map[string]any{"id": "session-3"})
	if len(panes.Screens) != 1 || len(panes.Screens[0].Panes) != 2 {
		t.Fatalf("expected the window's two panes, got %#v", panes.Screens)
	}

	// A Session the CLI does not share a screen with reports nothing.
	unplaced := requestResult[api.Session](t, cli, "session.current", map[string]any{"id": "session-2"})
	if unplaced.ScreenPaneCount != 0 {
		t.Fatalf("expected session-2 to be off screen, got %d panes", unplaced.ScreenPaneCount)
	}
}

// Two windows may display one Session at the same time. Each keeps its own
// layout, and the most recent report is answered first.
func TestScreenPanesListsEveryWindowMostRecentFirst(t *testing.T) {
	state, err := store.Open(filepath.Join(t.TempDir(), "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	group := api.TerminalGroup{ID: "group-1", Name: "Default"}
	if err := state.Update(func(value *api.State) error {
		value.TerminalGroups = []api.TerminalGroup{group}
		value.Sessions = []api.Session{
			{ID: "session-1", TerminalGroupID: group.ID, Scope: api.SessionScopeTerminalGroup, Lifecycle: "running"},
			{ID: "session-2", TerminalGroupID: group.ID, Scope: api.SessionScopeTerminalGroup, Lifecycle: "running"},
			{ID: "session-3", TerminalGroupID: group.ID, Scope: api.SessionScopeTerminalGroup, Lifecycle: "running"},
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	service := &Service{Store: state}
	httpServer := httptest.NewServer(NewHTTPServer(service, "secret", nil).Handler())
	defer httpServer.Close()
	first := openAuthenticatedConnection(t, httpServer.URL, "/v1/ws")
	defer first.Close()
	second := openAuthenticatedConnection(t, httpServer.URL, "/v1/ws")
	defer second.Close()

	requestResult[map[string]any](t, first, "screen.report", map[string]any{
		"sessions": []any{"session-1", "session-3", "session-1"},
	})
	requestResult[map[string]any](t, second, "screen.report", map[string]any{
		"sessions": []any{"session-3", "session-2"},
	})

	panes := requestResult[api.ScreenPanesResult](t, first, "screen.panes", map[string]any{"id": "session-3"})
	if len(panes.Screens) != 2 {
		t.Fatalf("expected two screens, got %#v", panes.Screens)
	}
	if panes.Screens[0].Position != 1 || panes.Screens[0].Panes[1].SessionID != "session-2" {
		t.Fatalf("most recent screen should come first: %#v", panes.Screens[0])
	}
	if panes.Screens[1].Position != 2 || panes.Screens[1].Panes[0].SessionID != "session-1" {
		t.Fatalf("unexpected second screen: %#v", panes.Screens[1])
	}

	// A Session that ends drops out of every screen lazily, and reporting it
	// again is rejected.
	if err := state.Update(func(value *api.State) error {
		for index := range value.Sessions {
			if value.Sessions[index].ID == "session-1" {
				value.Sessions[index].Lifecycle = "ended"
			}
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	current := requestResult[api.Session](t, first, "session.current", map[string]any{"id": "session-3"})
	if current.ScreenPaneCount != 2 || current.ScreenPosition != 1 {
		t.Fatalf("expected the second window's layout to answer, got %d/%d", current.ScreenPosition, current.ScreenPaneCount)
	}
	panes = requestResult[api.ScreenPanesResult](t, first, "screen.panes", map[string]any{"id": "session-3"})
	if len(panes.Screens) != 2 || len(panes.Screens[1].Panes) != 1 || panes.Screens[1].Panes[0].SessionID != "session-3" {
		t.Fatalf("ended session remained on a screen: %#v", panes.Screens)
	}
	if errorText := requestError(t, first, "screen.report", map[string]any{"sessions": []any{"session-1"}}); errorText == "" {
		t.Fatal("expected ended session report to be rejected")
	}
	if errorText := requestError(t, first, "screen.report", map[string]any{"sessions": []any{"missing"}}); errorText == "" {
		t.Fatal("expected unknown session report to be rejected")
	}

	// Deleting a Session removes it from the window that still displays it
	// without disturbing the other window's list.
	if err := state.Update(func(value *api.State) error {
		filtered := value.Sessions[:0]
		for _, session := range value.Sessions {
			if session.ID != "session-2" {
				filtered = append(filtered, session)
			}
		}
		value.Sessions = filtered
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	panes = requestResult[api.ScreenPanesResult](t, second, "screen.panes", map[string]any{"id": "session-3"})
	if len(panes.Screens) != 2 {
		t.Fatalf("expected both windows to still display session-3: %#v", panes.Screens)
	}
	for _, screen := range panes.Screens {
		if screen.PaneCount != 1 || screen.Panes[0].SessionID != "session-3" {
			t.Fatalf("deleted or ended session remained on a screen: %#v", screen)
		}
	}
}
