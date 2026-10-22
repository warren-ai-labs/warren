package server

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/settings"
	"github.com/abcdlsj/warren/Headless/internal/store"
)

// probeRuntimeStub answers exactly what a test wants a runtime probe to see, so
// the end reason each evidence produces can be asserted without a Ghostline
// server.
type probeRuntimeStub struct {
	memoryRuntime
	probe RuntimeProbeResult
	kill  func()
}

func (runtime *probeRuntimeStub) Probe(context.Context, string) RuntimeProbeResult {
	return runtime.probe
}

func (runtime *probeRuntimeStub) List(context.Context) (map[string]bool, error) {
	if runtime.probe.State == RuntimeProbeDead {
		return map[string]bool{}, nil
	}
	return map[string]bool{"warren_session": true}, nil
}

func (runtime *probeRuntimeStub) Kill(ctx context.Context, name string) error {
	if runtime.kill != nil {
		runtime.kill()
	}
	return runtime.memoryRuntime.Kill(ctx, name)
}

func sessionMemoryFixture(t *testing.T, sessions ...api.Session) (*Service, *store.Store) {
	t.Helper()
	state, err := store.Open(filepath.Join(t.TempDir(), "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	if len(sessions) > 0 {
		if err := state.Update(func(value *api.State) error {
			value.Sessions = sessions
			return nil
		}); err != nil {
			t.Fatal(err)
		}
	}
	return &Service{Store: state}, state
}

func TestMarkEndedRecordsEveryReason(t *testing.T) {
	reasons := []string{
		api.EndReasonUserClosed,
		api.EndReasonProcessExited,
		api.EndReasonRuntimeMissing,
	}
	for _, reason := range reasons {
		service, state := sessionMemoryFixture(t, api.Session{
			ID: "session", Runtime: "warren_session", Lifecycle: "running", CreatedAt: time.Now().UTC(),
		})
		service.markEnded("session", reason)
		session := state.Snapshot().Sessions[0]
		if session.Lifecycle != "ended" || session.EndedAt == nil {
			t.Fatalf("%s: session not ended: %#v", reason, session)
		}
		if session.EndReason != reason {
			t.Fatalf("end reason = %q, want %q", session.EndReason, reason)
		}
	}
}

// An ended Session written by a Host that had no end reasons must read as
// unknown rather than as one of the reasons this build records.
func TestLegacyEndedSessionReadsAsUnknown(t *testing.T) {
	service, _ := sessionMemoryFixture(t, api.Session{
		ID: "legacy", Runtime: "warren_legacy", Lifecycle: "ended",
	})
	session, ok := service.durableSession("legacy")
	if !ok {
		t.Fatal("legacy session not found")
	}
	if api.SessionEndReason(session.EndReason) != api.EndReasonUnknown {
		t.Fatalf("end reason = %q, want unknown", api.SessionEndReason(session.EndReason))
	}
	if api.SessionKeptAfterEnd(session) {
		t.Fatal("an ended Session with no reason stays out of the stopped-Tab roster")
	}
}

func TestReconcileAttributesMissingRuntimeAndExitedProgram(t *testing.T) {
	cases := []struct {
		name  string
		probe RuntimeProbeResult
		want  string
	}{
		{
			name:  "server pid gone",
			probe: RuntimeProbeResult{State: RuntimeProbeDead, Evidence: "server_pid_gone"},
			want:  api.EndReasonRuntimeMissing,
		},
		{
			name:  "runtime lost the session",
			probe: RuntimeProbeResult{State: RuntimeProbeDead, Evidence: "session_not_found"},
			want:  api.EndReasonRuntimeMissing,
		},
		{
			name:  "runtime reported the program gone",
			probe: RuntimeProbeResult{State: RuntimeProbeDead, Evidence: "status_not_alive"},
			want:  api.EndReasonProcessExited,
		},
	}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			state, err := store.Open(filepath.Join(t.TempDir(), "state.json"), "test")
			if err != nil {
				t.Fatal(err)
			}
			runtime := &probeRuntimeStub{
				memoryRuntime: memoryRuntime{sessions: map[string][]byte{}},
				probe:         testCase.probe,
			}
			if err := state.Update(func(value *api.State) error {
				value.Sessions = []api.Session{{
					ID: "session", Runtime: "warren_session", RuntimeKind: settings.RuntimeGhostline,
					Lifecycle: "running", CreatedAt: time.Now().UTC(),
				}}
				return nil
			}); err != nil {
				t.Fatal(err)
			}
			service := &Service{Store: state, Runtime: runtime, Runtimes: map[string]Runtime{settings.RuntimeGhostline: runtime}}
			service.reconcile(context.Background())

			session := state.Snapshot().Sessions[0]
			if session.Lifecycle != "ended" || session.EndReason != testCase.want {
				t.Fatalf("session = %#v, want ended/%s", session, testCase.want)
			}
		})
	}
}

// A runtime that closes its Session's output has lost the program it ran. The
// probe decides, so an answered dead status ends the Session and an unavailable
// runtime is left to the reconciliation loop.
func TestRuntimeExitEndsSessionWithObservedReason(t *testing.T) {
	state, err := store.Open(filepath.Join(t.TempDir(), "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	runtime := &probeRuntimeStub{
		memoryRuntime: memoryRuntime{sessions: map[string][]byte{}},
		probe:         RuntimeProbeResult{State: RuntimeProbeDead, Evidence: "status_not_alive"},
	}
	if err := state.Update(func(value *api.State) error {
		value.Sessions = []api.Session{{
			ID: "session", Runtime: "warren_session", Lifecycle: "running", CreatedAt: time.Now().UTC(),
		}}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	service := &Service{Store: state, Runtime: runtime}
	service.endAfterRuntimeExit("session")

	session := state.Snapshot().Sessions[0]
	if session.Lifecycle != "ended" || session.EndReason != api.EndReasonProcessExited {
		t.Fatalf("session = %#v, want ended/processExited", session)
	}
}

func TestRuntimeExitKeepsSessionWhenProbeCannotAnswer(t *testing.T) {
	state, err := store.Open(filepath.Join(t.TempDir(), "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	runtime := &probeRuntimeStub{
		memoryRuntime: memoryRuntime{sessions: map[string][]byte{}},
		probe:         RuntimeProbeResult{State: RuntimeProbeUnknown, Evidence: "session_get_failed"},
	}
	if err := state.Update(func(value *api.State) error {
		value.Sessions = []api.Session{{
			ID: "session", Runtime: "warren_session", Lifecycle: "running", CreatedAt: time.Now().UTC(),
		}}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	service := &Service{Store: state, Runtime: runtime}
	service.endAfterRuntimeExit("session")

	if session := state.Snapshot().Sessions[0]; session.Lifecycle != "running" {
		t.Fatalf("an unanswered probe ended the Session: %#v", session)
	}
}

func TestRosterKeepsOnlyTheEndedSessionsWorthShowing(t *testing.T) {
	endedAt := time.Now().UTC()
	cases := []struct {
		name    string
		session api.Session
		kept    bool
	}{
		{
			name:    "lost runtime",
			session: api.Session{ID: "a", Kind: "shell", Lifecycle: "ended", EndReason: api.EndReasonRuntimeMissing, EndedAt: &endedAt},
			kept:    true,
		},
		{
			name:    "exited program",
			session: api.Session{ID: "b", Kind: "codex", Lifecycle: "ended", EndReason: api.EndReasonProcessExited, EndedAt: &endedAt},
			kept:    true,
		},
		{
			name:    "user closed",
			session: api.Session{ID: "c", Kind: "shell", Lifecycle: "ended", EndReason: api.EndReasonUserClosed, EndedAt: &endedAt},
			kept:    false,
		},
		{
			name:    "legacy without reason",
			session: api.Session{ID: "d", Kind: "shell", Lifecycle: "ended", EndedAt: &endedAt},
			kept:    false,
		},
		{
			name:    "browser has no terminal to show",
			session: api.Session{ID: "e", Kind: sessionKindBrowser, Lifecycle: "ended", EndReason: api.EndReasonRuntimeMissing, EndedAt: &endedAt},
			kept:    false,
		},
		{
			name:    "chat has no terminal to show",
			session: api.Session{ID: "f", Kind: "codex", RuntimeKind: "acp", Lifecycle: "ended", EndReason: api.EndReasonRuntimeMissing, EndedAt: &endedAt},
			kept:    false,
		},
	}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			service, _ := sessionMemoryFixture(t, testCase.session)
			roster := service.Roster(context.Background())
			if kept := len(roster.Sessions) == 1; kept != testCase.kept {
				t.Fatalf("kept = %v, want %v (%#v)", kept, testCase.kept, roster.Sessions)
			}
		})
	}
}

func TestSessionHistoryReadsTheLastSegmentFromItsFirstByte(t *testing.T) {
	outputDir := t.TempDir()
	directory := filepath.Join(outputDir, "warren_session-1234")
	if err := os.MkdirAll(directory, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(directory, "1.out"), []byte("first\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(directory, "2.out"), []byte("second\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	endedAt := time.Now().UTC()
	service, _ := sessionMemoryFixture(t, api.Session{
		ID: "session", Runtime: "warren_session", Kind: "shell", Lifecycle: "ended",
		EndReason: api.EndReasonRuntimeMissing, EndedAt: &endedAt,
	})
	service.OutputDir = outputDir

	result, err := service.SessionHistory(context.Background(), "session")
	if err != nil {
		t.Fatal(err)
	}
	if string(result.Payload) != "second\n" {
		t.Fatalf("payload = %q, want the newest segment", result.Payload)
	}
	if !result.BestEffort || result.Truncated {
		t.Fatalf("history flags = bestEffort %v truncated %v", result.BestEffort, result.Truncated)
	}
	if result.EndReason != api.EndReasonRuntimeMissing || result.Lifecycle != "ended" {
		t.Fatalf("history metadata = %#v", result)
	}
}

func TestSessionHistoryBoundsTheSegmentAndIgnoresSymlinks(t *testing.T) {
	outputDir := t.TempDir()
	directory := filepath.Join(outputDir, "warren_session-1234")
	if err := os.MkdirAll(directory, 0o700); err != nil {
		t.Fatal(err)
	}
	payload := strings.Repeat("x", sessionHistoryMaxBytes+128)
	if err := os.WriteFile(filepath.Join(directory, "1.out"), []byte(payload), 0o600); err != nil {
		t.Fatal(err)
	}
	service, _ := sessionMemoryFixture(t, api.Session{
		ID: "session", Runtime: "warren_session", Kind: "shell", Lifecycle: "ended",
		EndReason: api.EndReasonRuntimeMissing,
	})
	service.OutputDir = outputDir

	result, err := service.SessionHistory(context.Background(), "session")
	if err != nil {
		t.Fatal(err)
	}
	if len(result.Payload) != sessionHistoryMaxBytes || !result.Truncated {
		t.Fatalf("payload = %d bytes, truncated %v", len(result.Payload), result.Truncated)
	}

	// A symlinked directory named like the runtime must not be followed.
	symlinkRoot := t.TempDir()
	elsewhere := filepath.Join(symlinkRoot, "elsewhere")
	if err := os.MkdirAll(elsewhere, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(elsewhere, "1.out"), []byte("secret"), 0o600); err != nil {
		t.Fatal(err)
	}
	linkRoot := t.TempDir()
	if err := os.Symlink(elsewhere, filepath.Join(linkRoot, "warren_session-9999")); err != nil {
		t.Fatal(err)
	}
	service.OutputDir = linkRoot
	linked, err := service.SessionHistory(context.Background(), "session")
	if err != nil {
		t.Fatal(err)
	}
	if len(linked.Payload) != 0 {
		t.Fatalf("history followed a symlinked segment: %q", linked.Payload)
	}
}

func TestSessionHistoryAnswersWithoutOutput(t *testing.T) {
	service, _ := sessionMemoryFixture(t, api.Session{
		ID: "session", Runtime: "warren_session", Kind: "shell", Lifecycle: "ended",
		EndReason: api.EndReasonRuntimeMissing,
	})
	service.OutputDir = t.TempDir()

	result, err := service.SessionHistory(context.Background(), "session")
	if err != nil {
		t.Fatal(err)
	}
	if len(result.Payload) != 0 || result.Bytes != 0 {
		t.Fatalf("history = %#v, want an empty payload", result)
	}
}

// Resuming continues a conversation in a new Session; the ended record keeps its
// own identity, output, and reason.
func TestResumeSessionStartsANewSessionOnTheSameConversation(t *testing.T) {
	workspaceID := "workspace-1"
	state, err := store.Open(filepath.Join(t.TempDir(), "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	runtime := &probeRuntimeStub{memoryRuntime: memoryRuntime{sessions: map[string][]byte{}}}
	if err := state.Update(func(value *api.State) error {
		value.Workspaces = []api.Workspace{{ID: workspaceID, Name: "ws", Path: t.TempDir()}}
		value.Sessions = []api.Session{{
			ID: "ended", WorkspaceID: workspaceID, Runtime: "warren_ended", Kind: "codex",
			Command: "codex --dangerously-bypass-hook-trust", AgentSessionID: "thread-1",
			Lifecycle: "ended", EndReason: api.EndReasonRuntimeMissing, Title: "Codex",
			Pinned: true, CreatedAt: time.Now().UTC(),
		}}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	service := &Service{Store: state, Runtime: runtime, DefaultRuntime: settings.RuntimeGhostline}

	created, err := service.ResumeSession(context.Background(), "ended")
	if err != nil {
		t.Fatal(err)
	}
	if created.ID == "ended" || created.Lifecycle != "running" {
		t.Fatalf("resume did not create a running Session: %#v", created)
	}
	if created.AgentSessionID != "thread-1" || created.ResumedFromSessionID != "ended" {
		t.Fatalf("resume did not keep the conversation lineage: %#v", created)
	}
	if !created.Pinned {
		t.Fatal("resume dropped the ended Session's pin")
	}
	// The preserved executable wins over the provider default, and the old
	// launch command is not replayed.
	if created.Command != "codex resume thread-1" {
		t.Fatalf("resume command = %q", created.Command)
	}
	ended, ok := service.durableSession("ended")
	if !ok || ended.Lifecycle != "ended" || ended.EndReason != api.EndReasonRuntimeMissing {
		t.Fatalf("resume rewrote the ended record: %#v", ended)
	}
}

func TestResumeSessionRejectsASecondRunningOwner(t *testing.T) {
	workspaceID := "workspace-1"
	state, err := store.Open(filepath.Join(t.TempDir(), "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	runtime := &probeRuntimeStub{memoryRuntime: memoryRuntime{sessions: map[string][]byte{}}}
	if err := state.Update(func(value *api.State) error {
		value.Workspaces = []api.Workspace{{ID: workspaceID, Name: "ws", Path: t.TempDir()}}
		value.Sessions = []api.Session{
			{ID: "ended", WorkspaceID: workspaceID, Runtime: "warren_ended", Kind: "pi", AgentSessionID: "abc", Lifecycle: "ended", EndReason: api.EndReasonRuntimeMissing, CreatedAt: time.Now().UTC()},
			{ID: "running", WorkspaceID: workspaceID, Runtime: "warren_running", Kind: "pi", AgentSessionID: "abc", Lifecycle: "running", CreatedAt: time.Now().UTC()},
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	service := &Service{Store: state, Runtime: runtime, DefaultRuntime: settings.RuntimeGhostline}

	if _, err := service.ResumeSession(context.Background(), "ended"); err == nil {
		t.Fatal("resume started a second writer for one conversation")
	}
}

// The pre-check in ResumeSession reads a snapshot, so two resumes that pass it at
// the same moment would both create. The same check runs again inside the state
// transaction; this exercises that path directly by calling the create path the
// pre-check would have refused.
func TestCreateSessionWithRefusesASecondWriterInsideTheTransaction(t *testing.T) {
	workspaceID := "workspace-1"
	state, err := store.Open(filepath.Join(t.TempDir(), "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	runtime := &probeRuntimeStub{memoryRuntime: memoryRuntime{sessions: map[string][]byte{}}}
	if err := state.Update(func(value *api.State) error {
		value.Workspaces = []api.Workspace{{ID: workspaceID, Name: "ws", Path: t.TempDir()}}
		value.Sessions = []api.Session{
			{ID: "running", WorkspaceID: workspaceID, Runtime: "warren_running", Kind: "pi", AgentSessionID: "abc", Lifecycle: "running", CreatedAt: time.Now().UTC()},
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	service := &Service{Store: state, Runtime: runtime, DefaultRuntime: settings.RuntimeGhostline}

	_, err = service.createSessionWith(context.Background(), sessionCreateRequest{
		workspaceID:          workspaceID,
		command:              "pi --session abc",
		kind:                 "pi",
		resumeAgentSessionID: "abc",
		resumedFromSessionID: "ended",
	})
	if err == nil {
		t.Fatal("the state transaction accepted a second writer for one conversation")
	}
	for _, session := range state.Snapshot().Sessions {
		if session.ID != "running" {
			t.Fatalf("a refused resume still wrote a Session: %#v", session)
		}
	}
}

func TestResumeSessionRefusesASessionWithNothingToContinue(t *testing.T) {
	service, _ := sessionMemoryFixture(t, api.Session{
		ID: "shell", Kind: "shell", Lifecycle: "ended", EndReason: api.EndReasonRuntimeMissing,
	})
	if _, err := service.ResumeSession(context.Background(), "shell"); err == nil {
		t.Fatal("resume accepted a Session with no Agent conversation")
	}
}

func TestResumeCommandPerProvider(t *testing.T) {
	cases := []struct {
		kind    string
		command string
		want    string
	}{
		{kind: "codex", command: "codex --dangerously-bypass-hook-trust", want: "codex resume thread-1"},
		{kind: "codex", command: "codex-opgo", want: "codex-opgo resume thread-1"},
		{kind: "claude", command: "claude", want: "claude --resume thread-1"},
		{kind: "pi", command: "pi", want: "pi --session thread-1"},
		{kind: "opencode", command: "opencode", want: "opencode --session thread-1"},
	}
	for _, testCase := range cases {
		command, provider, err := resumeCommand(api.Session{Kind: testCase.kind, Command: testCase.command}, "thread-1")
		if err != nil {
			t.Fatalf("%s: %v", testCase.kind, err)
		}
		if command != testCase.want || provider != testCase.kind {
			t.Fatalf("%s: command %q provider %q, want %q", testCase.kind, command, provider, testCase.want)
		}
	}
}

// A shell that a provider bound after launch resumes through the binding's
// provider rather than through the shell it was launched as.
func TestResumeCommandUsesTheBoundProvider(t *testing.T) {
	command, provider, err := resumeCommand(api.Session{Kind: "shell", AgentProvider: "claude"}, "thread-2")
	if err != nil {
		t.Fatal(err)
	}
	if command != "claude --resume thread-2" || provider != "claude" {
		t.Fatalf("command = %q provider = %q", command, provider)
	}
}

// Closing a running Session records who ended it before the runtime dies, so a
// concurrent observer cannot call the same death a missing runtime.
func TestDeleteSessionRecordsUserClosedBeforeKilling(t *testing.T) {
	var observed api.Session
	var once sync.Once
	state, err := store.Open(filepath.Join(t.TempDir(), "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	runtime := &probeRuntimeStub{memoryRuntime: memoryRuntime{sessions: map[string][]byte{}}}
	service := &Service{Store: state, Runtime: runtime, DefaultRuntime: settings.RuntimeGhostline}
	runtime.kill = func() {
		once.Do(func() {
			for _, session := range state.Snapshot().Sessions {
				if session.ID == "session" {
					observed = session
				}
			}
		})
	}
	if err := runtime.memoryRuntime.Create(context.Background(), "warren_session", t.TempDir(), "", nil); err != nil {
		t.Fatal(err)
	}
	if err := state.Update(func(value *api.State) error {
		value.Sessions = []api.Session{{
			ID: "session", Runtime: "warren_session", Kind: "shell", Lifecycle: "running", CreatedAt: time.Now().UTC(),
		}}
		return nil
	}); err != nil {
		t.Fatal(err)
	}

	if err := service.DeleteSession(context.Background(), "session"); err != nil {
		t.Fatal(err)
	}
	if observed.Lifecycle != "ended" || observed.EndReason != api.EndReasonUserClosed {
		t.Fatalf("state during the kill = %#v, want ended/userClosed", observed)
	}
	if len(state.Snapshot().Sessions) != 0 {
		t.Fatalf("deleted Session stayed in state: %#v", state.Snapshot().Sessions)
	}
}

// Closing a stopped Tab is the removal itself: there is no runtime left to kill
// and the failure to find one must not keep the record alive.
func TestDeleteSessionRemovesAStoppedSession(t *testing.T) {
	service, state := sessionMemoryFixture(t, api.Session{
		ID: "stopped", Runtime: "warren_stopped", Kind: "shell", Lifecycle: "ended",
		EndReason: api.EndReasonRuntimeMissing,
	})
	if err := service.DeleteSession(context.Background(), "stopped"); err != nil {
		t.Fatal(err)
	}
	if len(state.Snapshot().Sessions) != 0 {
		t.Fatalf("stopped Session was not removed: %#v", state.Snapshot().Sessions)
	}
}

// A state file written before end reasons existed must still open, and its
// ended Sessions must stay out of the roster until a reason is recorded.
func TestOldStateWithoutEndReasonLoads(t *testing.T) {
	directory := t.TempDir()
	path := filepath.Join(directory, "state.json")
	legacy := `{"schema":4,"host":{"id":"host","name":"test"},"tasks":[],"projects":[],"workspaces":[],` +
		`"sessions":[{"id":"old","runtime":"warren_old","kind":"shell","lifecycle":"ended",` +
		`"endedAt":"2026-01-02T03:04:05Z","createdAt":"2026-01-01T00:00:00Z"}],"paneGroups":[]}`
	if err := os.WriteFile(path, []byte(legacy), 0o600); err != nil {
		t.Fatal(err)
	}
	state, err := store.Open(path, "test")
	if err != nil {
		t.Fatalf("old state did not load: %v", err)
	}
	sessions := state.Snapshot().Sessions
	if len(sessions) != 1 || sessions[0].EndReason != "" {
		t.Fatalf("legacy sessions = %#v", sessions)
	}
	service := &Service{Store: state}
	if roster := service.Roster(context.Background()); len(roster.Sessions) != 0 {
		t.Fatalf("legacy ended Session entered the roster: %#v", roster.Sessions)
	}
}
