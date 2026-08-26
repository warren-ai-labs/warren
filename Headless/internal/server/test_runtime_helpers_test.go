package server

import (
	"context"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/output"
	"github.com/abcdlsj/warren/Headless/internal/store"
	"github.com/gorilla/websocket"
)

// testRuntime is a lightweight in-memory Runtime used by agent tests. It
// intentionally implements only the public Runtime contract; Warren's
// production output path is Ghostline-only.
type spoolRuntime struct {
	mu       sync.Mutex
	sessions map[string]bool
	outputs  map[string][]byte
	resizes  []recordedResize
	onInput  func(string, []byte)
}

func newSpoolRuntime(t *testing.T) *spoolRuntime {
	t.Helper()
	return &spoolRuntime{sessions: map[string]bool{}, outputs: map[string][]byte{}}
}

func (r *spoolRuntime) Create(_ context.Context, name, _, _ string, _ []string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.sessions[name] = true
	r.outputs[name] = nil
	return nil
}
func (r *spoolRuntime) Exists(_ context.Context, name string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.sessions[name]
}
func (r *spoolRuntime) List(context.Context) (map[string]bool, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := map[string]bool{}
	for n := range r.sessions {
		out[n] = true
	}
	return out, nil
}
func (r *spoolRuntime) Capture(_ context.Context, name string) ([]byte, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]byte(nil), r.outputs[name]...), nil
}
func (r *spoolRuntime) Input(_ context.Context, name string, data []byte) error {
	r.mu.Lock()
	onInput := r.onInput
	r.mu.Unlock()
	if onInput != nil {
		onInput(name, append([]byte(nil), data...))
	}
	r.mu.Lock()
	r.outputs[name] = append(r.outputs[name], data...)
	r.mu.Unlock()
	return nil
}
func (r *spoolRuntime) Resize(_ context.Context, _ string, columns, rows int) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.resizes = append(r.resizes, recordedResize{columns: columns, rows: rows})
	return nil
}
func (r *spoolRuntime) Kill(_ context.Context, name string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	delete(r.sessions, name)
	delete(r.outputs, name)
	return nil
}
func newStateWithSession(t *testing.T, sessionID, runtimeName string) *store.Store {
	t.Helper()
	state, err := store.Open(filepath.Join(t.TempDir(), "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	projectID, workspaceID := store.NewID(), store.NewID()
	if err := state.Update(func(v *api.State) error {
		v.Projects = []api.Project{{ID: projectID, Name: "Project", Path: t.TempDir(), CreatedAt: time.Now().UTC()}}
		v.Workspaces = []api.Workspace{{ID: workspaceID, ProjectID: projectID, Name: "main", Path: "/tmp", Kind: "root", CreatedAt: time.Now().UTC()}}
		v.Sessions = []api.Session{{ID: sessionID, WorkspaceID: workspaceID, Title: "Shell", Kind: "shell", Runtime: runtimeName, Lifecycle: "running", CreatedAt: time.Now().UTC()}}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	return state
}

func waitForRingUpper(t *testing.T, service *Service, sessionID string, want uint64) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		service.outputMu.Lock()
		o := service.outputs[sessionID]
		service.outputMu.Unlock()
		if o != nil {
			o.mu.Lock()
			u := o.ring.Upper()
			o.mu.Unlock()
			if u >= want {
				return
			}
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("ring upper never reached %d", want)
}

func attachBrowser(t *testing.T, c *websocket.Conn, sessionID string, anchor *output.Anchor) {
	attachBrowserWithSize(t, c, sessionID, anchor, 0, 0)
}
func attachBrowserWithSize(t *testing.T, c *websocket.Conn, sessionID string, anchor *output.Anchor, columns, rows int) {
	t.Helper()
	params := map[string]any{"id": sessionID}
	if columns != 0 || rows != 0 {
		params["cols"] = columns
		params["rows"] = rows
	}
	if anchor != nil {
		params["epoch"] = anchor.Epoch
		params["sequence"] = anchor.Sequence
	}
	if err := c.WriteJSON(api.Envelope{Type: "request", ID: store.NewID(), Method: "session.attach", Params: params}); err != nil {
		t.Fatal(err)
	}
}
func readBinaryFrame(t *testing.T, c *websocket.Conn) output.DecodedFrame {
	t.Helper()
	_ = c.SetReadDeadline(time.Now().Add(2 * time.Second))
	defer c.SetReadDeadline(time.Time{})
	for {
		k, d, e := c.ReadMessage()
		if e != nil {
			t.Fatal(e)
		}
		if k != websocket.BinaryMessage {
			continue
		}
		f, e := output.DecodeOutput(d)
		if e != nil {
			t.Fatal(e)
		}
		return f
	}
}
func anchorFromMessage(t *testing.T, m map[string]any) output.Anchor {
	t.Helper()
	e, ok := m["epoch"].(float64)
	s, ok2 := m["sequence"].(float64)
	if !ok || !ok2 {
		t.Fatalf("message has no anchor: %#v", m)
	}
	return output.Anchor{Epoch: uint64(e), Sequence: uint64(s)}
}
func sendDetach(t *testing.T, c *websocket.Conn) {
	t.Helper()
	if err := c.WriteJSON(api.Envelope{Type: "request", ID: store.NewID(), Method: "session.detach"}); err != nil {
		t.Fatal(err)
	}
}
func writeRawInput(t *testing.T, c *websocket.Conn, d []byte) {
	t.Helper()
	if err := c.WriteMessage(websocket.BinaryMessage, d); err != nil {
		t.Fatal(err)
	}
}
