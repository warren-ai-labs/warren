package server

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/abcdlsj/ghostline"
	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/store"
	"github.com/gorilla/websocket"
)

type memoryRuntime struct {
	mu       sync.Mutex
	sessions map[string][]byte
	readers  map[string]map[*memoryCursorReader]struct{}
}

func newMemoryRuntime(t *testing.T) *memoryRuntime {
	t.Helper()
	return &memoryRuntime{sessions: map[string][]byte{}}
}

type listingRuntime struct {
	memoryRuntime
	lists  int
	exists int
}

type cancellationSensitiveRuntime struct {
	memoryRuntime
}

type recordedResize struct {
	columns int
	rows    int
}

type recordingRuntime struct {
	memoryRuntime
	events         []string
	resizes        []recordedResize
	captureSeen    chan struct{}
	captureOnce    sync.Once
	checkpointCall int
}

func (runtime *recordingRuntime) Resize(_ context.Context, _ string, columns, rows int) error {
	runtime.mu.Lock()
	runtime.events = append(runtime.events, "resize")
	runtime.resizes = append(runtime.resizes, recordedResize{columns: columns, rows: rows})
	runtime.mu.Unlock()
	return nil
}

func (runtime *recordingRuntime) Capture(ctx context.Context, name string) ([]byte, error) {
	runtime.mu.Lock()
	runtime.events = append(runtime.events, "capture")
	runtime.mu.Unlock()
	runtime.captureOnce.Do(func() { close(runtime.captureSeen) })
	return runtime.memoryRuntime.Capture(ctx, name)
}

func (runtime *recordingRuntime) Checkpoint(ctx context.Context, name string) (ghostline.Checkpoint, error) {
	checkpoint, err := runtime.memoryRuntime.Checkpoint(ctx, name)
	if err != nil {
		return ghostline.Checkpoint{}, err
	}
	runtime.mu.Lock()
	runtime.checkpointCall++
	// ensureOutput takes an internal cursor checkpoint before attach. The
	// user-visible recovery checkpoint is the second boundary; signal that
	// checkpoint regardless of whether the peer is focused (passive recovery
	// deliberately performs no resize).
	if runtime.checkpointCall == 2 {
		runtime.events = append(runtime.events, "capture")
		runtime.captureOnce.Do(func() { close(runtime.captureSeen) })
	}
	runtime.mu.Unlock()
	return checkpoint, nil
}

func (runtime *recordingRuntime) snapshotOrder() ([]string, []recordedResize) {
	runtime.mu.Lock()
	defer runtime.mu.Unlock()
	return append([]string(nil), runtime.events...), append([]recordedResize(nil), runtime.resizes...)
}

func (runtime *listingRuntime) List(context.Context) (map[string]bool, error) {
	runtime.mu.Lock()
	defer runtime.mu.Unlock()
	runtime.lists++
	result := make(map[string]bool, len(runtime.sessions))
	for name := range runtime.sessions {
		result[name] = true
	}
	return result, nil
}

func (runtime *listingRuntime) Exists(_ context.Context, name string) bool {
	runtime.mu.Lock()
	defer runtime.mu.Unlock()
	runtime.exists++
	_, ok := runtime.sessions[name]
	return ok
}

func (runtime *listingRuntime) probeCounts() (int, int) {
	runtime.mu.Lock()
	defer runtime.mu.Unlock()
	return runtime.lists, runtime.exists
}

func (runtime *cancellationSensitiveRuntime) List(ctx context.Context) (map[string]bool, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	result := make(map[string]bool, len(runtime.sessions))
	for name := range runtime.sessions {
		result[name] = true
	}
	return result, nil
}

func (runtime *cancellationSensitiveRuntime) Exists(ctx context.Context, name string) bool {
	if ctx.Err() != nil {
		return false
	}
	return runtime.memoryRuntime.Exists(ctx, name)
}

func (m *memoryRuntime) Create(_ context.Context, name, _, _ string, _ []string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.sessions[name] = []byte("ready\n")
	if m.readers == nil {
		m.readers = map[string]map[*memoryCursorReader]struct{}{}
	}
	return nil
}
func (m *memoryRuntime) Exists(_ context.Context, name string) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	_, ok := m.sessions[name]
	return ok
}
func (m *memoryRuntime) Capture(_ context.Context, name string) ([]byte, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return append([]byte(nil), m.sessions[name]...), nil
}
func (m *memoryRuntime) Input(_ context.Context, name string, data []byte) error {
	m.mu.Lock()
	m.sessions[name] = append(m.sessions[name], data...)
	readers := make([]*memoryCursorReader, 0, len(m.readers[name]))
	for reader := range m.readers[name] {
		readers = append(readers, reader)
	}
	m.mu.Unlock()
	for _, reader := range readers {
		reader.notifyNewData()
	}
	return nil
}
func (m *memoryRuntime) Resize(context.Context, string, int, int) error { return nil }
func (m *memoryRuntime) Kill(_ context.Context, name string) error {
	m.mu.Lock()
	delete(m.sessions, name)
	readers := make([]*memoryCursorReader, 0, len(m.readers[name]))
	for reader := range m.readers[name] {
		readers = append(readers, reader)
	}
	delete(m.readers, name)
	m.mu.Unlock()
	for _, reader := range readers {
		reader.closeFromRuntime()
	}
	return nil
}

type blockingKillRuntime struct {
	memoryRuntime
	killStarted chan struct{}
	releaseKill chan struct{}
	killOnce    sync.Once
}

func (runtime *blockingKillRuntime) Kill(ctx context.Context, name string) error {
	runtime.killOnce.Do(func() { close(runtime.killStarted) })
	select {
	case <-runtime.releaseKill:
		return runtime.memoryRuntime.Kill(ctx, name)
	case <-ctx.Done():
		return ctx.Err()
	}
}

type workspaceBlockingCreateRuntime struct {
	memoryRuntime
	blockedDirectory string
	createStarted    chan struct{}
	releaseCreate    chan struct{}
	startOnce        sync.Once
}

func (runtime *workspaceBlockingCreateRuntime) Create(ctx context.Context, name, directory, command string, env []string) error {
	if directory == runtime.blockedDirectory {
		runtime.startOnce.Do(func() { close(runtime.createStarted) })
		select {
		case <-runtime.releaseCreate:
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	return runtime.memoryRuntime.Create(ctx, name, directory, command, env)
}

func TestWebSocketAuthenticationAndResourceLifecycle(t *testing.T) {
	t.Parallel()
	directory := t.TempDir()
	repository := filepath.Join(directory, "repository")
	if err := os.MkdirAll(repository, 0o755); err != nil {
		t.Fatal(err)
	}
	if output, err := exec.Command("git", "-C", repository, "init", "--quiet").CombinedOutput(); err != nil {
		t.Fatalf("git init: %s: %v", output, err)
	}
	state, err := store.Open(filepath.Join(directory, "state.json"), "test-vps")
	if err != nil {
		t.Fatal(err)
	}
	runtime := &memoryRuntime{sessions: map[string][]byte{}}
	service := &Service{Store: state, Runtime: runtime, WorktreeRoot: filepath.Join(directory, "worktrees")}
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
	if welcome["t"] != "welcome" {
		t.Fatalf("unexpected welcome: %#v", welcome)
	}

	project := requestResult[api.Project](t, connection, "project.add", map[string]any{"path": repository})
	if project.Name != "repository" {
		t.Fatalf("unexpected project: %#v", project)
	}
	roster := requestResult[api.State](t, connection, "roster", nil)
	if len(roster.Workspaces) != 1 {
		t.Fatalf("expected root workspace, got %#v", roster.Workspaces)
	}
	session := requestResult[api.Session](t, connection, "session.create", map[string]any{"workspace": roster.Workspaces[0].ID, "kind": "shell"})
	if !runtime.Exists(context.Background(), session.Runtime) {
		t.Fatal("runtime was not created")
	}
	subscription := requestResultBeforeBinary[terminalSubscriptionResult](t, connection, "session.subscribe", map[string]any{
		"id": session.ID, "claim": true,
	})
	if !subscription.Subscribed || subscription.AttachmentID == "" {
		t.Fatalf("invalid terminal subscription: %#v", subscription)
	}
	writeInputFrame(t, connection, session.ID, subscription.AttachmentID, 0, []byte("binary-input"))
	deadline := time.Now().Add(time.Second)
	for {
		runtime.mu.Lock()
		received := strings.Contains(string(runtime.sessions[session.Runtime]), "binary-input")
		runtime.mu.Unlock()
		if received {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("binary terminal input was not delivered")
		}
		time.Sleep(time.Millisecond)
	}
	_ = requestResult[map[string]bool](t, connection, "session.delete", map[string]any{"id": session.ID})
	if runtime.Exists(context.Background(), session.Runtime) {
		t.Fatal("runtime was not deleted")
	}
}

func TestRemoveWorkspaceCanKeepLocalWorktree(t *testing.T) {
	t.Parallel()
	directory := t.TempDir()
	repository := filepath.Join(directory, "repository")
	if err := os.MkdirAll(repository, 0o755); err != nil {
		t.Fatal(err)
	}
	runGit := func(arguments ...string) {
		t.Helper()
		command := exec.Command("git", append([]string{"-C", repository}, arguments...)...)
		if output, err := command.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %s: %v", arguments, output, err)
		}
	}
	runGit("init", "--quiet")
	runGit("config", "user.email", "test@example.com")
	runGit("config", "user.name", "Test")
	if err := os.WriteFile(filepath.Join(repository, "README.md"), []byte("warren\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	runGit("add", "README.md")
	runGit("commit", "--quiet", "-m", "init")

	state, err := store.Open(filepath.Join(directory, "state.json"), "test-host")
	if err != nil {
		t.Fatal(err)
	}
	service := &Service{
		Store:        state,
		Runtime:      &memoryRuntime{sessions: map[string][]byte{}},
		WorktreeRoot: filepath.Join(directory, "worktrees"),
	}
	project, err := service.AddProject(repository, "")
	if err != nil {
		t.Fatal(err)
	}
	workspace, err := service.CreateWorkspace(project.ID, "feature/keep-worktree", "", "")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(workspace.Path); err != nil {
		t.Fatalf("created worktree missing: %v", err)
	}

	if err := service.RemoveWorkspace(context.Background(), workspace.ID, RemoveWorkspaceOptions{
		Force:          true,
		RemoveWorktree: false,
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(workspace.Path); err != nil {
		t.Fatalf("worktree should remain on disk: %v", err)
	}
	for _, value := range service.Store.Snapshot().Workspaces {
		if value.ID == workspace.ID {
			t.Fatalf("workspace %s should be removed", workspace.ID)
		}
	}
}

func TestWorkspaceRemovalPublishesStateBeforeRuntimeCleanup(t *testing.T) {
	state := newStateWithSession(t, "session-remove-order", "runtime-remove-order")
	runtime := &blockingKillRuntime{
		memoryRuntime: memoryRuntime{sessions: map[string][]byte{"runtime-remove-order": []byte("ready\n")}},
		killStarted:   make(chan struct{}),
		releaseKill:   make(chan struct{}),
	}
	service := &Service{Store: state, Runtime: runtime}
	workspaceID := state.Snapshot().Workspaces[0].ID

	removeDone := make(chan error, 1)
	go func() {
		removeDone <- service.RemoveWorkspace(context.Background(), workspaceID, RemoveWorkspaceOptions{Force: true})
	}()

	select {
	case <-runtime.killStarted:
	case <-time.After(time.Second):
		t.Fatal("workspace runtime cleanup did not start")
	}
	for _, workspace := range state.Snapshot().Workspaces {
		if workspace.ID == workspaceID {
			t.Fatal("workspace state was not published before runtime cleanup")
		}
	}

	createContext, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if _, err := service.CreateSession(createContext, workspaceID, "", "shell", "", ""); err == nil || !strings.Contains(err.Error(), "workspace not found") {
		t.Fatalf("CreateSession during cleanup error = %v, want workspace not found", err)
	}

	close(runtime.releaseKill)
	select {
	case err := <-removeDone:
		if err != nil {
			t.Fatalf("RemoveWorkspace: %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("workspace runtime cleanup did not finish")
	}
}

func TestSlowWorkspaceRemovalDoesNotBlockSessionCreate(t *testing.T) {
	state := newStateWithSession(t, "session-websocket-remove-order", "runtime-websocket-remove-order")
	runtime := &blockingKillRuntime{
		memoryRuntime: memoryRuntime{sessions: map[string][]byte{"runtime-websocket-remove-order": []byte("ready\n")}},
		killStarted:   make(chan struct{}),
		releaseKill:   make(chan struct{}),
	}
	service := &Service{Store: state, Runtime: runtime}
	httpServer := httptest.NewServer(NewHTTPServer(service, "secret", nil).Handler())
	defer httpServer.Close()
	connection := openAuthenticatedConnection(t, httpServer.URL, "/v1/ws")
	defer connection.Close()

	workspaceID := state.Snapshot().Workspaces[0].ID
	removeID := store.NewID()
	if err := connection.WriteJSON(api.Envelope{
		Type: "request", ID: removeID, Method: "workspace.remove",
		Params: map[string]any{"id": workspaceID, "force": true},
	}); err != nil {
		t.Fatal(err)
	}
	select {
	case <-runtime.killStarted:
	case <-time.After(time.Second):
		t.Fatal("workspace runtime cleanup did not start")
	}

	createID := store.NewID()
	if err := connection.WriteJSON(api.Envelope{
		Type: "request", ID: createID, Method: "session.create",
		Params: map[string]any{"workspace": workspaceID, "kind": "shell"},
	}); err != nil {
		t.Fatal(err)
	}
	_ = connection.SetReadDeadline(time.Now().Add(time.Second))
	var createResponse api.Response
	for {
		_, data, err := connection.ReadMessage()
		if err != nil {
			t.Fatalf("session.create remained blocked by workspace removal: %v", err)
		}
		if json.Unmarshal(data, &createResponse) == nil && createResponse.Type == "response" && createResponse.ID == createID {
			break
		}
	}
	_ = connection.SetReadDeadline(time.Time{})
	if createResponse.OK || !strings.Contains(createResponse.Error, "workspace not found") {
		t.Fatalf("session.create response = %#v, want workspace-not-found error", createResponse)
	}

	close(runtime.releaseKill)
	_ = connection.SetReadDeadline(time.Now().Add(time.Second))
	var removeResponse api.Response
	for {
		_, data, err := connection.ReadMessage()
		if err != nil {
			t.Fatalf("workspace.remove did not finish: %v", err)
		}
		if json.Unmarshal(data, &removeResponse) == nil && removeResponse.Type == "response" && removeResponse.ID == removeID {
			break
		}
	}
	_ = connection.SetReadDeadline(time.Time{})
	if !removeResponse.OK {
		t.Fatalf("workspace.remove response = %#v", removeResponse)
	}
}

func TestSessionLifecycleMutationsDoNotBlockWebSocketReader(t *testing.T) {
	t.Run("create", func(t *testing.T) {
		state, err := store.Open(filepath.Join(t.TempDir(), "state.json"), "test")
		if err != nil {
			t.Fatal(err)
		}
		runtime := &blockingCreateRuntime{
			memoryRuntime: newMemoryRuntime(t),
			entered:       make(chan struct{}),
			release:       make(chan struct{}),
		}
		projectID := store.NewID()
		workspaceID := store.NewID()
		if err := state.Update(func(value *api.State) error {
			value.Projects = []api.Project{{
				ID: projectID, Name: "Project", Path: t.TempDir(), CreatedAt: time.Now().UTC(),
			}}
			value.Workspaces = []api.Workspace{{
				ID: workspaceID, ProjectID: projectID, Name: "main", Path: t.TempDir(),
				Kind: "root", CreatedAt: time.Now().UTC(),
			}}
			return nil
		}); err != nil {
			t.Fatal(err)
		}
		service := &Service{Store: state, Runtime: runtime}
		httpServer := httptest.NewServer(NewHTTPServer(service, "secret", nil).Handler())
		defer httpServer.Close()
		connection := openAuthenticatedConnection(t, httpServer.URL, "/v1/ws")
		defer connection.Close()

		createID := store.NewID()
		if err := connection.WriteJSON(api.Envelope{
			Type: "request", ID: createID, Method: "session.create",
			Params: map[string]any{"workspace": workspaceID, "kind": "shell"},
		}); err != nil {
			t.Fatal(err)
		}
		select {
		case <-runtime.entered:
		case <-time.After(time.Second):
			t.Fatal("session.create did not reach the runtime")
		}

		rosterID := store.NewID()
		if err := connection.WriteJSON(api.Envelope{Type: "request", ID: rosterID, Method: "roster"}); err != nil {
			t.Fatal(err)
		}
		readResponseByID(t, connection, rosterID, time.Second)

		close(runtime.release)
		readResponseByID(t, connection, createID, time.Second)
	})

	t.Run("delete", func(t *testing.T) {
		state, session := testSession(t)
		runtime := &blockingKillRuntime{
			memoryRuntime: memoryRuntime{sessions: map[string][]byte{session.Runtime: []byte("ready\n")}},
			killStarted:   make(chan struct{}),
			releaseKill:   make(chan struct{}),
		}
		service := &Service{Store: state, Runtime: runtime}
		httpServer := httptest.NewServer(NewHTTPServer(service, "secret", nil).Handler())
		defer httpServer.Close()
		connection := openAuthenticatedConnection(t, httpServer.URL, "/v1/ws")
		defer connection.Close()

		deleteID := store.NewID()
		if err := connection.WriteJSON(api.Envelope{
			Type: "request", ID: deleteID, Method: "session.delete",
			Params: map[string]any{"id": session.ID},
		}); err != nil {
			t.Fatal(err)
		}
		select {
		case <-runtime.killStarted:
		case <-time.After(time.Second):
			t.Fatal("session.delete did not reach the runtime")
		}

		rosterID := store.NewID()
		if err := connection.WriteJSON(api.Envelope{Type: "request", ID: rosterID, Method: "roster"}); err != nil {
			t.Fatal(err)
		}
		readResponseByID(t, connection, rosterID, time.Second)

		close(runtime.releaseKill)
		readResponseByID(t, connection, deleteID, time.Second)
	})
}

func TestWorkspaceSessionCreationDoesNotSerializeOtherWorkspaces(t *testing.T) {
	state, err := store.Open(filepath.Join(t.TempDir(), "state.json"), "test-host")
	if err != nil {
		t.Fatal(err)
	}
	projectID := store.NewID()
	workspaceAID := store.NewID()
	workspaceBID := store.NewID()
	workspaceAPath := t.TempDir()
	workspaceBPath := t.TempDir()
	if err := state.Update(func(value *api.State) error {
		value.Projects = []api.Project{{
			ID: projectID, Name: "Project", Path: t.TempDir(), CreatedAt: time.Now().UTC(),
		}}
		value.Workspaces = []api.Workspace{
			{ID: workspaceAID, ProjectID: projectID, Name: "A", Path: workspaceAPath, Kind: "root", CreatedAt: time.Now().UTC()},
			{ID: workspaceBID, ProjectID: projectID, Name: "B", Path: workspaceBPath, Kind: "worktree", CreatedAt: time.Now().UTC()},
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	runtime := &workspaceBlockingCreateRuntime{
		memoryRuntime:    memoryRuntime{sessions: map[string][]byte{}},
		blockedDirectory: workspaceAPath,
		createStarted:    make(chan struct{}),
		releaseCreate:    make(chan struct{}),
	}
	service := &Service{Store: state, Runtime: runtime}

	createA := make(chan error, 1)
	go func() {
		_, createErr := service.CreateSession(context.Background(), workspaceAID, "", "shell", "", "")
		createA <- createErr
	}()
	select {
	case <-runtime.createStarted:
	case <-time.After(time.Second):
		t.Fatal("workspace A session creation did not reach the runtime")
	}

	createB := make(chan error, 1)
	go func() {
		_, createErr := service.CreateSession(context.Background(), workspaceBID, "", "shell", "", "")
		createB <- createErr
	}()
	select {
	case createErr := <-createB:
		if createErr != nil {
			t.Fatalf("workspace B session creation: %v", createErr)
		}
	case <-time.After(time.Second):
		close(runtime.releaseCreate)
		t.Fatal("workspace B session creation was serialized behind workspace A")
	}

	close(runtime.releaseCreate)
	if createErr := <-createA; createErr != nil {
		t.Fatalf("workspace A session creation: %v", createErr)
	}
}

func TestRemoveWorkspaceToleratesAlreadyRemovedWorktree(t *testing.T) {
	t.Parallel()
	directory := t.TempDir()
	repository := filepath.Join(directory, "repository")
	if err := os.MkdirAll(repository, 0o755); err != nil {
		t.Fatal(err)
	}
	runGit := func(arguments ...string) {
		t.Helper()
		command := exec.Command("git", append([]string{"-C", repository}, arguments...)...)
		if output, err := command.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %s: %v", arguments, output, err)
		}
	}
	runGit("init", "--quiet")
	runGit("config", "user.email", "test@example.com")
	runGit("config", "user.name", "Test")
	if err := os.WriteFile(filepath.Join(repository, "README.md"), []byte("warren\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	runGit("add", "README.md")
	runGit("commit", "--quiet", "-m", "init")

	state, err := store.Open(filepath.Join(directory, "state.json"), "test-host")
	if err != nil {
		t.Fatal(err)
	}
	service := &Service{
		Store:        state,
		Runtime:      &memoryRuntime{sessions: map[string][]byte{}},
		WorktreeRoot: filepath.Join(directory, "worktrees"),
	}
	project, err := service.AddProject(repository, "")
	if err != nil {
		t.Fatal(err)
	}
	workspace, err := service.CreateWorkspace(project.ID, "feature/already-removed", "", "")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.RemoveAll(workspace.Path); err != nil {
		t.Fatal(err)
	}

	if err := service.RemoveWorkspace(context.Background(), workspace.ID, RemoveWorkspaceOptions{
		Force:          true,
		RemoveWorktree: true,
	}); err != nil {
		t.Fatalf("remove workspace with missing worktree: %v", err)
	}
	for _, value := range service.Store.Snapshot().Workspaces {
		if value.ID == workspace.ID {
			t.Fatalf("workspace %s should be removed from state", workspace.ID)
		}
	}
}

func TestMaintenanceBroadcastReachesAllPeers(t *testing.T) {
	state, err := store.Open(filepath.Join(t.TempDir(), "state.json"), "test-host")
	if err != nil {
		t.Fatal(err)
	}
	service := &Service{Store: state, Runtime: &memoryRuntime{sessions: map[string][]byte{}}}
	httpServer := httptest.NewServer(NewHTTPServer(service, "secret", nil).Handler())
	defer httpServer.Close()

	first := openAuthenticatedConnection(t, httpServer.URL, "/v1/ws")
	defer first.Close()
	second := openAuthenticatedConnection(t, httpServer.URL, "/v1/ws")
	defer second.Close()

	unauthorized, err := http.NewRequest(
		http.MethodPost,
		httpServer.URL+"/v1/maintenance",
		strings.NewReader(`{"message":"updating"}`),
	)
	if err != nil {
		t.Fatal(err)
	}
	response, err := httpServer.Client().Do(unauthorized)
	if err != nil {
		t.Fatal(err)
	}
	_ = response.Body.Close()
	if response.StatusCode != http.StatusUnauthorized {
		t.Fatalf("unauthorized maintenance status = %d, want 401", response.StatusCode)
	}

	request, err := http.NewRequest(
		http.MethodPost,
		httpServer.URL+"/v1/maintenance",
		strings.NewReader(`{"message":"Installing a new Warren build"}`),
	)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Authorization", "Bearer secret")
	request.Header.Set("Content-Type", "application/json")
	response, err = httpServer.Client().Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("maintenance status = %d, want 200", response.StatusCode)
	}

	for index, connection := range []*websocket.Conn{first, second} {
		message := readBrowserMessage(t, connection, "maintenance")
		if message["state"] != "starting" {
			t.Fatalf("peer %d maintenance state = %#v, want starting", index, message["state"])
		}
		if message["message"] != "Installing a new Warren build" {
			t.Fatalf("peer %d maintenance message = %#v", index, message["message"])
		}
	}
}

func TestRosterBroadcastsCreatedWorktreeAndSession(t *testing.T) {
	t.Parallel()
	directory := t.TempDir()
	repository := filepath.Join(directory, "repository")
	if err := os.MkdirAll(repository, 0o755); err != nil {
		t.Fatal(err)
	}
	if output, err := exec.Command("git", "-C", repository, "init", "--quiet").CombinedOutput(); err != nil {
		t.Fatalf("git init: %s: %v", output, err)
	}
	if err := os.WriteFile(filepath.Join(repository, "README.md"), []byte("fixture\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	for _, args := range [][]string{
		{"-C", repository, "add", "README.md"},
		{"-C", repository, "-c", "user.name=Warren Test", "-c", "user.email=warren@example.invalid", "commit", "-m", "fixture"},
	} {
		if output, err := exec.Command("git", args...).CombinedOutput(); err != nil {
			t.Fatalf("git setup: %s: %v", output, err)
		}
	}
	state, err := store.Open(filepath.Join(directory, "state.json"), "test-vps")
	if err != nil {
		t.Fatal(err)
	}
	runtime := &memoryRuntime{sessions: map[string][]byte{}}
	service := &Service{Store: state, Runtime: runtime, WorktreeRoot: filepath.Join(directory, "worktrees")}
	httpServer := httptest.NewServer(NewHTTPServer(service, "secret", slog.Default()).Handler())
	defer httpServer.Close()

	mutator := openAuthenticatedConnection(t, httpServer.URL, "/v1/ws")
	defer mutator.Close()
	observer := openAuthenticatedConnection(t, httpServer.URL, "/v1/ws")
	defer observer.Close()
	waitForRoster(t, observer, func(api.State) bool { return true })

	project := requestResult[api.Project](t, mutator, "project.add", map[string]any{"path": repository})
	workspace := requestResult[api.WorkspaceCreateResult](t, mutator, "workspace.create", map[string]any{
		"project": project.ID,
		"branch":  "feature/live",
	})
	if workspace.Kind != "worktree" {
		t.Fatalf("expected worktree workspace, got %#v", workspace)
	}
	if !workspace.Created {
		t.Fatal("workspace.create result should report created=true")
	}
	if !workspace.GitWorktree {
		t.Fatal("workspace.create result should report gitWorktree=true")
	}
	relative, err := filepath.Rel(filepath.Clean(service.WorktreeRoot), filepath.Clean(workspace.Path))
	if err != nil || relative == ".." || strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
		t.Fatalf("worktree path %q is outside root %q", workspace.Path, service.WorktreeRoot)
	}
	waitForRoster(t, observer, func(state api.State) bool {
		for _, value := range state.Workspaces {
			if value.ID == workspace.ID {
				return true
			}
		}
		return false
	})

	session := requestResult[api.Session](t, mutator, "session.create", map[string]any{
		"workspace": workspace.ID,
		"kind":      "shell",
	})
	waitForRoster(t, observer, func(state api.State) bool {
		for _, value := range state.Sessions {
			if value.ID == session.ID {
				return true
			}
		}
		return false
	})
}

func TestCreateWorkspaceRejectsDuplicateBranch(t *testing.T) {
	t.Parallel()
	directory := t.TempDir()
	repository := filepath.Join(directory, "repository")
	if err := os.MkdirAll(repository, 0o755); err != nil {
		t.Fatal(err)
	}
	runGit := func(arguments ...string) {
		t.Helper()
		command := exec.Command("git", append([]string{"-C", repository}, arguments...)...)
		if output, err := command.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %s: %v", arguments, output, err)
		}
	}
	runGit("init", "--quiet")
	runGit("config", "user.email", "test@example.com")
	runGit("config", "user.name", "Test")
	if err := os.WriteFile(filepath.Join(repository, "README.md"), []byte("warren\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	runGit("add", "README.md")
	runGit("commit", "--quiet", "-m", "init")

	state, err := store.Open(filepath.Join(directory, "state.json"), "test-host")
	if err != nil {
		t.Fatal(err)
	}
	service := &Service{
		Store:        state,
		Runtime:      &memoryRuntime{sessions: map[string][]byte{}},
		WorktreeRoot: filepath.Join(directory, "worktrees"),
	}
	project, err := service.AddProject(repository, "")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := service.CreateWorkspace(project.ID, "feature/duplicate", "", ""); err != nil {
		t.Fatal(err)
	}
	if _, err := service.CreateWorkspace(project.ID, "feature/duplicate", "", ""); err == nil {
		t.Fatal("duplicate branch workspace was accepted")
	} else if !strings.Contains(err.Error(), "already exists") {
		t.Fatalf("duplicate branch error = %v, want already exists", err)
	}
	if _, err := service.CreateWorkspace(project.ID, "feature/other", "", ""); err != nil {
		t.Fatalf("different branch should be allowed: %v", err)
	}
}

func TestRejectsInvalidToken(t *testing.T) {
	t.Parallel()
	directory := t.TempDir()
	state, _ := store.Open(filepath.Join(directory, "state.json"), "test")
	httpServer := httptest.NewServer(NewHTTPServer(&Service{Store: state, Runtime: &memoryRuntime{sessions: map[string][]byte{}}}, "secret", slog.Default()).Handler())
	defer httpServer.Close()
	endpoint := "ws" + strings.TrimPrefix(httpServer.URL, "http") + "/v1/ws"
	connection, _, err := websocket.DefaultDialer.Dial(endpoint, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer connection.Close()
	_ = connection.WriteJSON(api.Envelope{Type: "auth", Token: "wrong"})
	var response api.Response
	if err := connection.ReadJSON(&response); err != nil {
		t.Fatal(err)
	}
	if response.Error != "unauthorized" {
		t.Fatalf("unexpected response: %#v", response)
	}
}

func TestRejectsProtocolOneAndClientsWithoutAtomicTerminalState(t *testing.T) {
	t.Parallel()
	state, _ := store.Open(filepath.Join(t.TempDir(), "state.json"), "test")
	httpServer := httptest.NewServer(NewHTTPServer(
		&Service{Store: state, Runtime: &memoryRuntime{sessions: map[string][]byte{}}},
		"secret",
		slog.Default(),
	).Handler())
	defer httpServer.Close()
	endpoint := "ws" + strings.TrimPrefix(httpServer.URL, "http") + "/v1/ws"

	for name, auth := range map[string]api.Envelope{
		"protocol one": {
			Type:                 "auth",
			Token:                "secret",
			Version:              "1.0",
			TerminalStateFormats: []string{terminalStateFormatANSI},
		},
		"missing state format": {
			Type:    "auth",
			Token:   "secret",
			Version: api.Version,
		},
	} {
		t.Run(name, func(t *testing.T) {
			connection, _, err := websocket.DefaultDialer.Dial(endpoint, nil)
			if err != nil {
				t.Fatal(err)
			}
			defer connection.Close()
			if err := connection.WriteJSON(auth); err != nil {
				t.Fatal(err)
			}
			var response api.Response
			if err := connection.ReadJSON(&response); err != nil {
				t.Fatal(err)
			}
			if response.Type != "error" || response.OK {
				t.Fatalf("response = %#v, want protocol rejection", response)
			}
			if !strings.Contains(response.Error, "incompatible protocol") &&
				!strings.Contains(response.Error, "upgrade required") {
				t.Fatalf("error = %q, want explicit upgrade rejection", response.Error)
			}
		})
	}
}

func TestRenameAndPinResources(t *testing.T) {
	t.Parallel()
	state, session := testSession(t)
	httpServer := httptest.NewServer(NewHTTPServer(
		&Service{Store: state, Runtime: &memoryRuntime{sessions: map[string][]byte{}}},
		"secret",
		slog.Default(),
	).Handler())
	defer httpServer.Close()

	connection := openAuthenticatedConnection(t, httpServer.URL, "/v1/ws")
	defer connection.Close()

	initial := requestResult[api.State](t, connection, "roster", nil)
	projectID := initial.Projects[0].ID
	workspaceID := initial.Workspaces[0].ID

	requestResult[map[string]bool](t, connection, "project.rename", map[string]any{
		"id": projectID, "name": "Renamed Project",
	})
	requestResult[map[string]bool](t, connection, "workspace.rename", map[string]any{
		"id": workspaceID, "name": "Renamed Workspace",
	})
	requestResult[map[string]bool](t, connection, "session.rename", map[string]any{
		"id": session.ID, "title": "My Custom Session",
	})
	requestResult[map[string]bool](t, connection, "project.pin", map[string]any{
		"id": projectID, "pinned": true,
	})
	requestResult[map[string]bool](t, connection, "workspace.pin", map[string]any{
		"id": workspaceID, "pinned": true,
	})
	requestResult[map[string]bool](t, connection, "session.pin", map[string]any{
		"id": session.ID, "pinned": true,
	})

	updated := requestResult[api.State](t, connection, "roster", nil)
	if updated.Projects[0].Name != "Renamed Project" || !updated.Projects[0].Pinned {
		t.Fatalf("project rename/pin not reflected: %#v", updated.Projects[0])
	}
	if updated.Workspaces[0].Name != "Renamed Workspace" || !updated.Workspaces[0].Pinned {
		t.Fatalf("workspace rename/pin not reflected: %#v", updated.Workspaces[0])
	}
	if updated.Sessions[0].CustomTitle != "My Custom Session" || !updated.Sessions[0].Pinned {
		t.Fatalf("session rename/pin not reflected: %#v", updated.Sessions[0])
	}
}

func TestAttachSizeFromParamsRequiresCompletePositiveViewport(t *testing.T) {
	tests := []struct {
		name      string
		params    map[string]any
		columns   int
		rows      int
		specified bool
		wantError bool
	}{
		{name: "omitted for compatibility", params: nil},
		{name: "numbers", params: map[string]any{"cols": float64(101), "rows": float64(33)}, columns: 101, rows: 33, specified: true},
		{name: "desktop strings", params: map[string]any{"cols": "88", "rows": "27"}, columns: 88, rows: 27, specified: true},
		{name: "missing rows", params: map[string]any{"cols": 88}, wantError: true},
		{name: "zero columns", params: map[string]any{"cols": 0, "rows": 27}, wantError: true},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			columns, rows, specified, err := attachSizeFromParams(test.params)
			if test.wantError {
				if err == nil {
					t.Fatal("expected invalid terminal size")
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if columns != test.columns || rows != test.rows || specified != test.specified {
				t.Fatalf("size = (%d, %d, %t), want (%d, %d, %t)", columns, rows, specified, test.columns, test.rows, test.specified)
			}
		})
	}
}

func TestBrowserAttachResizesBeforeFirstSnapshot(t *testing.T) {
	state, session := testSession(t)
	runtime := &recordingRuntime{
		memoryRuntime: memoryRuntime{sessions: map[string][]byte{session.Runtime: []byte("prompt")}},
		captureSeen:   make(chan struct{}),
	}
	httpServer := httptest.NewServer(NewHTTPServer(&Service{Store: state, Runtime: runtime}, "secret", slog.Default()).Handler())
	defer httpServer.Close()
	connection := openAuthenticatedConnection(t, httpServer.URL, "/v1/ws")
	defer connection.Close()

	subscribeBrowserWithSize(t, connection, session.ID, nil, 101, 33)
	readBrowserMessage(t, connection, "attached")
	waitForCapture(t, runtime.captureSeen)
	assertResizePrecedesCapture(t, runtime, 101, 33)
}

func TestAnchorFromParamsAcceptsDesktopStrings(t *testing.T) {
	anchor := anchorFromParams(map[string]any{
		"epoch": "7", "sequence": "99",
	})
	if anchor == nil || anchor.Epoch != 7 || anchor.Sequence != 99 {
		t.Fatalf("anchorFromParams(strings) = %#v, want epoch=7 sequence=99", anchor)
	}
	if anchor := anchorFromParams(map[string]any{
		"epoch": "not-a-number", "sequence": 1,
	}); anchor != nil {
		t.Fatalf("invalid anchor unexpectedly parsed: %#v", anchor)
	}
}

func TestDesktopAttachResizesBeforeFirstSnapshot(t *testing.T) {
	state, session := testSession(t)
	runtime := &recordingRuntime{
		memoryRuntime: memoryRuntime{sessions: map[string][]byte{session.Runtime: []byte("prompt")}},
		captureSeen:   make(chan struct{}),
	}
	httpServer := httptest.NewServer(NewHTTPServer(&Service{Store: state, Runtime: runtime}, "secret", slog.Default()).Handler())
	defer httpServer.Close()
	connection := openAuthenticatedConnection(t, httpServer.URL, "/v1/ws")
	defer connection.Close()

	_ = requestResultBeforeBinary[terminalSubscriptionResult](t, connection, "session.subscribe", map[string]any{
		"id": session.ID, "claim": true, "cols": "88", "rows": "27",
	})
	waitForCapture(t, runtime.captureSeen)
	assertResizePrecedesCapture(t, runtime, 88, 27)
}

func TestPassiveAttachSeedsSnapshotWithoutResizingSharedRuntime(t *testing.T) {
	state, session := testSession(t)
	runtime := &recordingRuntime{
		memoryRuntime: memoryRuntime{sessions: map[string][]byte{session.Runtime: []byte("prompt")}},
		captureSeen:   make(chan struct{}),
	}
	httpServer := httptest.NewServer(NewHTTPServer(&Service{Store: state, Runtime: runtime}, "secret", slog.Default()).Handler())
	defer httpServer.Close()
	connection := openAuthenticatedConnection(t, httpServer.URL, "/v1/ws")
	defer connection.Close()

	// A passive attach carries the viewer's viewport but must never mutate
	// the shared runtime: a pre-snapshot resize would SIGWINCH the child and
	// its redraw bytes would race (and be skipped by) the snapshot capture,
	// leaving full-screen TUIs repainting regions no client ever received.
	_ = requestResultBeforeBinary[terminalSubscriptionResult](t, connection, "session.subscribe", map[string]any{
		"id": session.ID, "claim": false, "cols": "88", "rows": "27",
	})
	waitForCapture(t, runtime.captureSeen)
	if _, resizes := runtime.snapshotOrder(); len(resizes) != 0 {
		t.Fatalf("passive attach resized the shared runtime: %#v", resizes)
	}
}

func TestOnlyFocusedPeerCanResizeSharedRuntime(t *testing.T) {
	state, session := testSession(t)
	runtime := &recordingRuntime{
		memoryRuntime: memoryRuntime{sessions: map[string][]byte{session.Runtime: []byte("prompt")}},
		captureSeen:   make(chan struct{}),
	}
	httpServer := httptest.NewServer(NewHTTPServer(&Service{Store: state, Runtime: runtime}, "secret", slog.Default()).Handler())
	defer httpServer.Close()

	first := openAuthenticatedConnection(t, httpServer.URL, "/v1/ws")
	defer first.Close()
	second := openAuthenticatedConnection(t, httpServer.URL, "/v1/ws")
	defer second.Close()

	_ = requestResultBeforeBinary[terminalSubscriptionResult](t, first, "session.subscribe", map[string]any{
		"id": session.ID, "claim": true, "cols": 101, "rows": 33,
	})
	readBrowserMessage(t, first, "attached")
	readBinaryFrame(t, first)
	readBrowserMessage(t, first, "synced")

	_ = requestResultBeforeBinary[terminalSubscriptionResult](t, second, "session.subscribe", map[string]any{
		"id": session.ID, "claim": false, "cols": 77, "rows": 27,
	})
	readBrowserMessage(t, second, "attached")
	readBinaryFrame(t, second)
	readBrowserMessage(t, second, "synced")

	_, resizes := runtime.snapshotOrder()
	if len(resizes) != 1 || resizes[0] != (recordedResize{columns: 101, rows: 33}) {
		t.Fatalf("passive attach changed runtime size: %#v", resizes)
	}

	requestError(t, second, "session.resize", map[string]any{
		"cols": 77, "rows": 27,
	})

	focused := requestResult[map[string]bool](t, second, "session.focus", map[string]any{
		"id": session.ID, "focused": true, "cols": 77, "rows": 27,
	})
	if !focused["focused"] || !focused["resized"] {
		t.Fatalf("focus handoff result = %#v", focused)
	}

	oldOwner := requestResult[map[string]bool](t, first, "session.resize", map[string]any{
		"cols": 101, "rows": 33,
	})
	if oldOwner["resized"] {
		t.Fatal("previous focus owner resized after handoff")
	}
	newOwner := requestResult[map[string]bool](t, second, "session.resize", map[string]any{
		"cols": 78, "rows": 28,
	})
	if !newOwner["resized"] {
		t.Fatal("current focus owner resize was ignored")
	}
	sameSize := requestResult[map[string]bool](t, second, "session.focus", map[string]any{
		"focused": true, "cols": 78, "rows": 28,
	})
	if sameSize["resized"] {
		t.Fatal("same-size focus unexpectedly resized the runtime")
	}
	sameSizeResize := requestResult[map[string]bool](t, second, "session.resize", map[string]any{
		"cols": 78, "rows": 28,
	})
	if sameSizeResize["resized"] {
		t.Fatal("same-size resize unexpectedly resized the runtime")
	}

	_, resizes = runtime.snapshotOrder()
	want := []recordedResize{{columns: 101, rows: 33}, {columns: 77, rows: 27}, {columns: 78, rows: 28}}
	if len(resizes) != len(want) {
		t.Fatalf("runtime resize calls = %#v, want %#v", resizes, want)
	}
	for index := range want {
		if resizes[index] != want[index] {
			t.Fatalf("runtime resize calls = %#v, want %#v", resizes, want)
		}
	}
}

func testSession(t *testing.T) (*store.Store, api.Session) {
	t.Helper()
	state, err := store.Open(filepath.Join(t.TempDir(), "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	projectID := store.NewID()
	workspaceID := store.NewID()
	session := api.Session{
		ID: sessionIDForTest(), WorkspaceID: workspaceID, Title: "Shell", Kind: "shell",
		Runtime: "runtime-test", Lifecycle: "running", CreatedAt: time.Now().UTC(),
	}
	if err := state.Update(func(value *api.State) error {
		value.Projects = []api.Project{{ID: projectID, Name: "Project", Path: t.TempDir(), CreatedAt: time.Now().UTC()}}
		value.Workspaces = []api.Workspace{{ID: workspaceID, ProjectID: projectID, Name: "main", Path: "/tmp", Kind: "root", CreatedAt: time.Now().UTC()}}
		value.Sessions = []api.Session{session}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	return state, session
}

func sessionIDForTest() string { return store.NewID() }

func openAuthenticatedConnection(t *testing.T, serverURL, path string) *websocket.Conn {
	return openAuthenticatedConnectionWithCapabilities(t, serverURL, path, nil)
}

func openAuthenticatedConnectionWithCapabilities(
	t *testing.T,
	serverURL, path string,
	capabilities []string,
) *websocket.Conn {
	return openAuthenticatedConnectionWithStateFormat(
		t,
		serverURL,
		path,
		capabilities,
		terminalStateFormatANSI,
	)
}

func openAuthenticatedConnectionWithStateFormat(
	t *testing.T,
	serverURL, path string,
	capabilities []string,
	stateFormat string,
) *websocket.Conn {
	t.Helper()
	endpoint := "ws" + strings.TrimPrefix(serverURL, "http") + path
	connection, _, err := websocket.DefaultDialer.Dial(endpoint, nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := connection.WriteJSON(api.Envelope{
		Type:                 "auth",
		Token:                "secret",
		Version:              api.Version,
		Capabilities:         capabilities,
		TerminalStateFormats: []string{stateFormat},
	}); err != nil {
		connection.Close()
		t.Fatal(err)
	}
	var welcome map[string]any
	if err := connection.ReadJSON(&welcome); err != nil {
		connection.Close()
		t.Fatal(err)
	}
	if welcome["t"] != "welcome" {
		connection.Close()
		t.Fatalf("unexpected welcome: %#v", welcome)
	}
	return connection
}

func waitForRoster(t *testing.T, connection *websocket.Conn, matches func(api.State) bool) api.State {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	_ = connection.SetReadDeadline(deadline)
	defer connection.SetReadDeadline(time.Time{})
	for {
		kind, data, err := connection.ReadMessage()
		if err != nil {
			t.Fatal(err)
		}
		if kind != websocket.TextMessage {
			continue
		}
		var message struct {
			Type  string    `json:"t"`
			State api.State `json:"state"`
		}
		if json.Unmarshal(data, &message) != nil || message.Type != "roster" {
			continue
		}
		if matches(message.State) {
			return message.State
		}
	}
}

func readBrowserMessage(t *testing.T, connection *websocket.Conn, messageType string) map[string]any {
	t.Helper()
	deadline := time.Now().Add(time.Second)
	_ = connection.SetReadDeadline(deadline)
	defer connection.SetReadDeadline(time.Time{})
	for {
		kind, data, err := connection.ReadMessage()
		if err != nil {
			t.Fatal(err)
		}
		if kind != websocket.TextMessage {
			continue
		}
		var value map[string]any
		if json.Unmarshal(data, &value) == nil && value["t"] == messageType {
			return value
		}
	}
}

func waitForCapture(t *testing.T, captureSeen <-chan struct{}) {
	t.Helper()
	select {
	case <-captureSeen:
	case <-time.After(time.Second):
		t.Fatal("first terminal snapshot was not captured")
	}
}

func assertResizePrecedesCapture(t *testing.T, runtime *recordingRuntime, columns, rows int) {
	t.Helper()
	events, resizes := runtime.snapshotOrder()
	if len(events) < 2 || events[0] != "resize" || events[1] != "capture" {
		t.Fatalf("runtime events = %v, want [resize capture]", events)
	}
	if len(resizes) != 1 || resizes[0] != (recordedResize{columns: columns, rows: rows}) {
		t.Fatalf("resize calls = %#v", resizes)
	}
}

func requestResult[T any](t *testing.T, connection *websocket.Conn, method string, params map[string]any) T {
	t.Helper()
	id := store.NewID()
	if err := connection.WriteJSON(api.Envelope{Type: "request", ID: id, Method: method, Params: params}); err != nil {
		t.Fatal(err)
	}
	for {
		_, data, err := connection.ReadMessage()
		if err != nil {
			t.Fatal(err)
		}
		var response api.Response
		if json.Unmarshal(data, &response) != nil || response.Type != "response" || response.ID != id {
			continue
		}
		if !response.OK {
			t.Fatal(response.Error)
		}
		raw, _ := json.Marshal(response.Result)
		var result T
		if err := json.Unmarshal(raw, &result); err != nil {
			t.Fatal(err)
		}
		return result
	}
}

func readResponseByID(t *testing.T, connection *websocket.Conn, id string, timeout time.Duration) api.Response {
	t.Helper()
	_ = connection.SetReadDeadline(time.Now().Add(timeout))
	defer connection.SetReadDeadline(time.Time{})
	for {
		_, data, err := connection.ReadMessage()
		if err != nil {
			t.Fatal(err)
		}
		var response api.Response
		if json.Unmarshal(data, &response) == nil && response.Type == "response" && response.ID == id {
			if !response.OK {
				t.Fatalf("request %s failed: %s", id, response.Error)
			}
			return response
		}
	}
}

func requestError(t *testing.T, connection *websocket.Conn, method string, params map[string]any) string {
	t.Helper()
	id := store.NewID()
	if err := connection.WriteJSON(api.Envelope{Type: "request", ID: id, Method: method, Params: params}); err != nil {
		t.Fatal(err)
	}
	for {
		_, data, err := connection.ReadMessage()
		if err != nil {
			t.Fatal(err)
		}
		var response api.Response
		if json.Unmarshal(data, &response) != nil || response.Type != "response" || response.ID != id {
			continue
		}
		if response.OK {
			t.Fatalf("request %s unexpectedly succeeded: %#v", method, response.Result)
		}
		return response.Error
	}
}

func requestResultBeforeBinary[T any](t *testing.T, connection *websocket.Conn, method string, params map[string]any) T {
	t.Helper()
	id := store.NewID()
	if err := connection.WriteJSON(api.Envelope{Type: "request", ID: id, Method: method, Params: params}); err != nil {
		t.Fatal(err)
	}
	for {
		messageType, data, err := connection.ReadMessage()
		if err != nil {
			t.Fatal(err)
		}
		if messageType == websocket.BinaryMessage {
			t.Fatal("terminal output arrived before the attach response")
		}
		var response api.Response
		if json.Unmarshal(data, &response) != nil || response.Type != "response" || response.ID != id {
			continue
		}
		if !response.OK {
			t.Fatal(response.Error)
		}
		raw, _ := json.Marshal(response.Result)
		var result T
		if err := json.Unmarshal(raw, &result); err != nil {
			t.Fatal(err)
		}
		return result
	}
}

func TestHealthEndpoint(t *testing.T) {
	t.Parallel()
	request := httptest.NewRequest("GET", "http://localhost/healthz", nil)
	response := httptest.NewRecorder()
	directory := t.TempDir()
	state, _ := store.Open(filepath.Join(directory, "state.json"), "test")
	handler := NewHTTPServer(&Service{Store: state, Runtime: &memoryRuntime{sessions: map[string][]byte{}}}, "secret", slog.Default())
	handler.BuildVersion = "abc1234"
	handler.BuildRevision = "abc1234def5678"
	handler.BuildDirty = true
	handler.GhostlineRPCVersion = "0.6.0"
	handler.GhostlineTagVersion = "v0.6.1"
	handler.Handler().ServeHTTP(response, request)
	if response.Code != 200 {
		t.Fatalf("health returned %d", response.Code)
	}
	var body struct {
		OK                  bool   `json:"ok"`
		Ready               bool   `json:"ready"`
		Version             string `json:"version"`
		Build               string `json:"build"`
		Revision            string `json:"revision"`
		Dirty               bool   `json:"dirty"`
		GhostlineRPCVersion string `json:"ghostlineRPCVersion"`
		GhostlineTagVersion string `json:"ghostlineTagVersion"`
		Status              struct {
			Store string          `json:"store"`
			Relay api.RelayHealth `json:"relay"`
		} `json:"status"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode health body: %v", err)
	}
	if !body.OK {
		t.Fatalf("expected ok=true, got %+v", body)
	}
	if !body.Ready {
		t.Fatalf("expected ready=true with healthy subsystems, got %+v", body)
	}
	if body.Version != api.Version || body.Build != "abc1234" || body.Revision != "abc1234def5678" || !body.Dirty || body.GhostlineRPCVersion != "0.6.0" || body.GhostlineTagVersion != "v0.6.1" {
		t.Fatalf("health body = %+v", body)
	}
	if body.Status.Store != api.HealthReady {
		t.Fatalf("expected status.store=ready, got %q", body.Status.Store)
	}
	if body.Status.Relay.State != api.HealthUnconfigured {
		t.Fatalf("expected status.relay.state=unconfigured, got %+v", body.Status.Relay)
	}
}

func TestHealthEndpointRelayDegraded(t *testing.T) {
	t.Parallel()
	request := httptest.NewRequest("GET", "http://localhost/healthz", nil)
	response := httptest.NewRecorder()
	directory := t.TempDir()
	state, _ := store.Open(filepath.Join(directory, "state.json"), "test")
	handler := NewHTTPServer(&Service{Store: state, Runtime: &memoryRuntime{sessions: map[string][]byte{}}}, "secret", slog.Default())
	handler.RelayState = func() api.RelayHealth {
		return api.RelayHealth{Configured: true, Connected: false, State: api.HealthError, LastError: "dial timeout"}
	}
	handler.Handler().ServeHTTP(response, request)
	if response.Code != 200 {
		t.Fatalf("health returned %d", response.Code)
	}
	var body struct {
		Ready  bool `json:"ready"`
		Status struct {
			Relay api.RelayHealth `json:"relay"`
		} `json:"status"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode health body: %v", err)
	}
	if body.Ready {
		t.Fatalf("expected ready=false when relay is in error state, got true")
	}
	if body.Status.Relay.State != api.HealthError || body.Status.Relay.LastError != "dial timeout" || !body.Status.Relay.Configured {
		t.Fatalf("relay status not surfaced: %+v", body.Status.Relay)
	}
}

func TestCACertDownload(t *testing.T) {
	t.Parallel()
	caPath := filepath.Join(t.TempDir(), "ca.crt")
	if err := os.WriteFile(caPath, []byte("-----BEGIN CERTIFICATE-----\nZmFrZQ==\n-----END CERTIFICATE-----\n"), 0o600); err != nil {
		t.Fatalf("write CA certificate: %v", err)
	}
	handler := NewHTTPServer(&Service{}, "secret", slog.Default())
	handler.CACertPath = caPath
	request := httptest.NewRequest("GET", "http://localhost/tls/ca.pem", nil)
	response := httptest.NewRecorder()
	handler.Handler().ServeHTTP(response, request)
	if response.Code != 200 {
		t.Fatalf("CA download returned %d", response.Code)
	}
	if contentType := response.Header().Get("Content-Type"); contentType != "application/x-x509-ca-cert" {
		t.Fatalf("Content-Type = %q", contentType)
	}
	if body := response.Body.String(); !strings.Contains(body, "BEGIN CERTIFICATE") {
		t.Fatalf("CA body = %q", body)
	}
}

func TestSameOriginAllowsLANAndForwardedHTTPS(t *testing.T) {
	t.Parallel()
	server := NewHTTPServer(&Service{}, "secret", slog.Default())
	cases := []struct {
		name   string
		host   string
		origin string
		proto  string
		want   bool
	}{
		{name: "LAN direct", host: "192.168.1.117:8789", origin: "http://192.168.1.117:8789", want: true},
		{name: "LAN hostname", host: "mac-mini.local:8789", origin: "http://mac-mini.local:8789", want: true},
		{name: "loopback", host: "127.0.0.1:8789", origin: "http://127.0.0.1:8789", want: true},
		{name: "localhost", host: "localhost:8789", origin: "http://localhost:8789", want: true},
		{name: "Relay route", host: "warren.example.com", origin: "https://warren.example.com", proto: "https", want: true},
		{name: "cross-site origin", host: "192.168.1.117:8789", origin: "http://evil.example", want: false},
		{name: "wrong scheme", host: "192.168.1.117:8789", origin: "https://192.168.1.117:8789", want: false},
		{name: "different LAN host", host: "192.168.1.117:8789", origin: "http://192.168.1.118:8789", want: false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			request := httptest.NewRequest("GET", "http://"+tc.host+"/v1/ws", nil)
			request.Header.Set("Origin", tc.origin)
			if tc.proto != "" {
				request.Header.Set("X-Forwarded-Proto", tc.proto)
			}
			if got := server.upgrader.CheckOrigin(request); got != tc.want {
				t.Fatalf("CheckOrigin(host=%q origin=%q proto=%q) = %v, want %v", tc.host, tc.origin, tc.proto, got, tc.want)
			}
		})
	}
}

func TestRosterProjectionDoesNotProbeOrMutateRuntimeLifecycle(t *testing.T) {
	state, _ := store.Open(filepath.Join(t.TempDir(), "state.json"), "test")
	runtime := &listingRuntime{memoryRuntime: memoryRuntime{sessions: map[string][]byte{"running": {}}}}
	service := &Service{Store: state, Runtime: runtime}
	if err := state.Update(func(value *api.State) error {
		value.Sessions = []api.Session{{ID: "one", Runtime: "running", Lifecycle: "running"}, {ID: "two", Runtime: "missing", Lifecycle: "running"}}
		return nil
	}); err != nil {
		t.Fatal(err)
	}

	for range 5 {
		roster := service.Roster(context.Background())
		if roster.Sessions[0].Lifecycle != "running" || roster.Sessions[1].Lifecycle != "running" {
			t.Fatalf("roster projection changed durable lifecycle: %#v", roster.Sessions)
		}
	}
	if lists, exists := runtime.probeCounts(); lists != 0 || exists != 0 {
		t.Fatalf("roster runtime probes: lists=%d exists=%d", lists, exists)
	}

	service.reconcile(context.Background())
	roster := service.Roster(context.Background())
	if lists, exists := runtime.probeCounts(); lists != 1 || exists != 0 {
		t.Fatalf("lifecycle runtime probes: lists=%d exists=%d", lists, exists)
	}
	// After filtering out ended sessions, only the running session should remain.
	if len(roster.Sessions) != 1 || roster.Sessions[0].Lifecycle != "running" {
		t.Fatalf("ended sessions filtered from roster: %#v", roster.Sessions)
	}
}

func TestRosterProjectionIgnoresObserverCancellation(t *testing.T) {
	state, err := store.Open(filepath.Join(t.TempDir(), "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	runtime := &cancellationSensitiveRuntime{
		memoryRuntime: memoryRuntime{sessions: map[string][]byte{"runtime-live": {}}},
	}
	if err := state.Update(func(value *api.State) error {
		value.Sessions = []api.Session{{
			ID: "session", Runtime: "runtime-live", Lifecycle: "running", CreatedAt: time.Now().UTC(),
		}}
		return nil
	}); err != nil {
		t.Fatal(err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	roster := (&Service{Store: state, Runtime: runtime}).Roster(ctx)
	if roster.Sessions[0].Lifecycle != "running" {
		t.Fatalf("canceled observer context ended a live session: %#v", roster.Sessions[0])
	}
}

func TestRosterProjectionDoesNotProbeEndedSessions(t *testing.T) {
	state, err := store.Open(filepath.Join(t.TempDir(), "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	ghostlineRuntime := &listingRuntime{memoryRuntime: memoryRuntime{sessions: map[string][]byte{}}}
	service := &Service{
		Store:          state,
		Runtime:        ghostlineRuntime,
		Runtimes:       map[string]Runtime{"ghostline": ghostlineRuntime},
		DefaultRuntime: "ghostline",
	}
	endedAt := time.Now().UTC()
	if err := state.Update(func(value *api.State) error {
		value.Sessions = []api.Session{{
			ID: "legacy-ended", Runtime: "warren_legacy", Lifecycle: "ended", EndedAt: &endedAt,
		}}
		return nil
	}); err != nil {
		t.Fatal(err)
	}

	for range 10 {
		roster := service.Roster(context.Background())
		// After filtering out ended sessions, the roster should be empty.
		if len(roster.Sessions) != 0 {
			t.Fatalf("ended sessions filtered from roster: %#v", roster.Sessions)
		}
	}
	if lists, exists := ghostlineRuntime.probeCounts(); lists != 0 || exists != 0 {
		t.Fatalf("probes for ended session: lists=%d exists=%d", lists, exists)
	}
}
