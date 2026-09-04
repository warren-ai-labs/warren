package server

import (
	"path/filepath"
	"testing"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/store"
)

func TestLiveActivitySnapshotProjectsRunningSessionsAndAttention(t *testing.T) {
	state, err := store.Open(filepath.Join(t.TempDir(), "state.json"), "Host")
	if err != nil {
		t.Fatal(err)
	}
	createdAt := time.Date(2026, 9, 3, 12, 0, 0, 0, time.UTC)
	if err := state.Update(func(value *api.State) error {
		value.Sessions = []api.Session{
			{ID: "running", Title: "Build", Kind: "codex", Runtime: "warren_running", Lifecycle: "running", CreatedAt: createdAt},
			{ID: "ended", Title: "Old", Kind: "shell", Runtime: "warren_ended", Lifecycle: "ended", CreatedAt: createdAt.Add(time.Minute)},
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	service := &Service{Store: state}
	service.lazyInit()
	service.recordAgentStatus("running", api.AgentStatus{
		Activity: api.AgentActivityWorking,
		Attention: &api.AgentAttention{
			Kind:   api.AgentAttentionInput,
			Reason: "needs input",
		},
	})
	snapshot := service.liveActivitySnapshot()
	if snapshot.Connection != "connected" || snapshot.ActiveSessionCount != 1 || snapshot.WorkingSessionCount != 1 || snapshot.AttentionSessionCount != 1 {
		t.Fatalf("snapshot counts = %+v", snapshot)
	}
	// After filtering out ended sessions, only the running session should appear.
	if len(snapshot.Sessions) != 1 {
		t.Fatalf("snapshot sessions = %+v", snapshot.Sessions)
	}
	if snapshot.Sessions[0].ID != "running" || snapshot.Sessions[0].Connection != "connected" || snapshot.Sessions[0].Title != "Build" || !snapshot.Sessions[0].Attention {
		t.Fatalf("running projection = %+v", snapshot.Sessions[0])
	}
}
