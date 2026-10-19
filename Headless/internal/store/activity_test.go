package store

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

func activityTestState() api.State {
	return api.State{
		Projects: []api.Project{{ID: "p1"}, {ID: "p2"}},
		Workspaces: []api.Workspace{
			{ID: "w1", ProjectID: "p1"},
			{ID: "w2", ProjectID: "p1"},
			{ID: "w3", ProjectID: "p2"},
		},
	}
}

func TestStampActivityTracksSessionChangesPerWorkspace(t *testing.T) {
	first := time.Unix(100, 0).UTC()
	second := time.Unix(200, 0).UTC()
	before := activityTestState()
	after := activityTestState()
	after.Sessions = []api.Session{{ID: "s1", WorkspaceID: "w1", Lifecycle: "running"}}
	stampActivity(&before, &after, first)

	if got := after.Workspaces[0].LastActivityAt; got == nil || !got.Equal(first) {
		t.Fatalf("w1 last activity = %v, want %v", got, first)
	}
	if after.Workspaces[1].LastActivityAt != nil || after.Workspaces[2].LastActivityAt != nil {
		t.Fatal("untouched workspaces were stamped")
	}
	if got := after.Projects[0].ActiveSince; got == nil || !got.Equal(first) {
		t.Fatalf("p1 active since = %v, want %v", got, first)
	}
	if after.Projects[1].ActiveSince != nil {
		t.Fatal("p2 has no running session but was marked active")
	}

	// A second Session in another Workspace keeps the Project's stamp.
	before = after
	after = clone(before)
	after.Sessions = append(after.Sessions, api.Session{ID: "s2", WorkspaceID: "w2", Lifecycle: "running"})
	stampActivity(&before, &after, second)
	if got := after.Projects[0].ActiveSince; got == nil || !got.Equal(first) {
		t.Fatalf("p1 active since moved to %v while it stayed active", got)
	}
	if got := after.Workspaces[0].LastActivityAt; got == nil || !got.Equal(first) {
		t.Fatalf("w1 last activity moved to %v without a change of its own", got)
	}

	// Ending, then closing, every Session clears the Project and stamps both
	// Workspaces.
	before = after
	after = clone(before)
	after.Sessions[0].Lifecycle = "ended"
	after.Sessions = after.Sessions[:1]
	stampActivity(&before, &after, second)
	if after.Projects[0].ActiveSince != nil {
		t.Fatalf("p1 active since = %v after its last running session ended", after.Projects[0].ActiveSince)
	}
	for _, index := range []int{0, 1} {
		if got := after.Workspaces[index].LastActivityAt; got == nil || !got.Equal(second) {
			t.Fatalf("workspace %d last activity = %v, want %v", index, got, second)
		}
	}
}

func TestOpenBackfillsActivityFromSessions(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state.json")
	created := time.Unix(100, 0).UTC()
	ended := time.Unix(300, 0).UTC()
	state := activityTestState()
	state.Schema = currentSchema
	state.Sessions = []api.Session{
		{ID: "s1", WorkspaceID: "w1", Lifecycle: "running", CreatedAt: created},
		{ID: "s2", WorkspaceID: "w3", Lifecycle: "ended", CreatedAt: created, EndedAt: &ended},
	}
	data, err := json.Marshal(state)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	opened, err := Open(path, "test")
	if err != nil {
		t.Fatal(err)
	}
	snapshot := opened.Snapshot()
	if got := snapshot.Projects[0].ActiveSince; got == nil || !got.Equal(created) {
		t.Fatalf("p1 active since = %v, want %v", got, created)
	}
	if snapshot.Projects[1].ActiveSince != nil {
		t.Fatal("p2 has only an ended session but was marked active")
	}
	if got := snapshot.Workspaces[2].LastActivityAt; got == nil || !got.Equal(ended) {
		t.Fatalf("w3 last activity = %v, want %v", got, ended)
	}
	if snapshot.Workspaces[1].LastActivityAt != nil {
		t.Fatal("w2 never had a session but was given a last activity")
	}
}
