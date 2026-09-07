package server

import (
	"context"
	"fmt"
	"io"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/abcdlsj/ghostline"
	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/output"
	"github.com/abcdlsj/warren/Headless/internal/store"
	"github.com/gorilla/websocket"
)

// testRuntime is a lightweight in-memory Runtime used by agent tests. It
// intentionally implements only the public Runtime contract; Warren's
// production output path is Ghostline-only.
type memoryOutputRuntime struct {
	mu       sync.Mutex
	sessions map[string]bool
	outputs  map[string][]byte
	resizes  []recordedResize
	onInput  func(string, []byte)
	readers  map[string]map[*memoryCursorReader]struct{}
}

func newMemoryOutputRuntime(t *testing.T) *memoryOutputRuntime {
	t.Helper()
	return &memoryOutputRuntime{sessions: map[string]bool{}, outputs: map[string][]byte{}}
}

func (r *memoryOutputRuntime) Create(_ context.Context, name, _, _ string, _ []string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.sessions[name] = true
	r.outputs[name] = nil
	if r.readers == nil {
		r.readers = map[string]map[*memoryCursorReader]struct{}{}
	}
	return nil
}
func (r *memoryOutputRuntime) Exists(_ context.Context, name string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.sessions[name]
}
func (r *memoryOutputRuntime) List(context.Context) (map[string]bool, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := map[string]bool{}
	for n := range r.sessions {
		out[n] = true
	}
	return out, nil
}
func (r *memoryOutputRuntime) Capture(_ context.Context, name string) ([]byte, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]byte(nil), r.outputs[name]...), nil
}
func (r *memoryOutputRuntime) Input(_ context.Context, name string, data []byte) error {
	r.mu.Lock()
	onInput := r.onInput
	r.outputs[name] = append(r.outputs[name], data...)
	readers := make([]*memoryCursorReader, 0, len(r.readers[name]))
	for reader := range r.readers[name] {
		readers = append(readers, reader)
	}
	r.mu.Unlock()
	if onInput != nil {
		onInput(name, append([]byte(nil), data...))
	}
	for _, reader := range readers {
		reader.notifyNewData()
	}
	return nil
}
func (r *memoryOutputRuntime) Resize(_ context.Context, _ string, columns, rows int) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.resizes = append(r.resizes, recordedResize{columns: columns, rows: rows})
	return nil
}
func (r *memoryOutputRuntime) Kill(_ context.Context, name string) error {
	r.mu.Lock()
	delete(r.sessions, name)
	delete(r.outputs, name)
	readers := make([]*memoryCursorReader, 0, len(r.readers[name]))
	for reader := range r.readers[name] {
		readers = append(readers, reader)
	}
	delete(r.readers, name)
	r.mu.Unlock()
	for _, reader := range readers {
		reader.closeFromRuntime()
	}
	return nil
}

// memoryCursorReader is a deterministic, cancellable reader used by the Go
// protocol tests. It mirrors the small CursorOutputReader contract without
// reaching into Ghostline's unexported reader constructor.
type memoryCursorReader struct {
	ctx       context.Context
	name      string
	readData  func(string) []byte
	remove    func(*memoryCursorReader)
	notify    chan struct{}
	closed    chan struct{}
	closeOnce sync.Once
	mu        sync.Mutex
	offset    int
}

func newMemoryCursorReader(
	ctx context.Context,
	name string,
	cursor ghostline.Cursor,
	readData func(string) []byte,
	remove func(*memoryCursorReader),
) (*memoryCursorReader, error) {
	offset, err := testCursorOffset(cursor)
	if err != nil {
		return nil, err
	}
	return &memoryCursorReader{
		ctx: ctx, name: name, readData: readData, remove: remove,
		notify: make(chan struct{}, 1), closed: make(chan struct{}), offset: offset,
	}, nil
}

func (r *memoryCursorReader) Read(p []byte) (int, error) {
	if len(p) == 0 {
		return 0, nil
	}
	for {
		r.mu.Lock()
		select {
		case <-r.closed:
			r.mu.Unlock()
			return 0, io.ErrClosedPipe
		default:
		}
		offset := r.offset
		r.mu.Unlock()

		data := r.readData(r.name)
		if offset < len(data) {
			n := copy(p, data[offset:])
			r.mu.Lock()
			if r.offset == offset {
				r.offset += n
			} else if r.offset < offset+n {
				r.offset = offset + n
			}
			r.mu.Unlock()
			return n, nil
		}
		select {
		case <-r.notify:
		case <-r.closed:
			return 0, io.ErrClosedPipe
		case <-r.ctx.Done():
			return 0, r.ctx.Err()
		}
	}
}

func (r *memoryCursorReader) Close() error {
	r.closeOnce.Do(func() {
		close(r.closed)
		if r.remove != nil {
			r.remove(r)
		}
	})
	return nil
}

func (r *memoryCursorReader) closeFromRuntime() { _ = r.Close() }

func (r *memoryCursorReader) notifyNewData() {
	select {
	case r.notify <- struct{}{}:
	default:
	}
}

func (r *memoryCursorReader) Cursor() ghostline.Cursor {
	r.mu.Lock()
	offset := r.offset
	r.mu.Unlock()
	cursor, _ := ghostline.ParseCursor(fmt.Sprintf("v1:1:%d", offset))
	return cursor
}

func testCursor(offset int) ghostline.Cursor {
	cursor, _ := ghostline.ParseCursor(fmt.Sprintf("v1:1:%d", offset))
	return cursor
}

func testCursorOffset(cursor ghostline.Cursor) (int, error) {
	value := cursor.String()
	if value == "" {
		return 0, nil
	}
	parts := strings.Split(value, ":")
	if len(parts) != 3 || parts[0] != "v1" {
		return 0, fmt.Errorf("invalid test cursor %q", value)
	}
	offset, err := strconv.Atoi(parts[2])
	if err != nil || offset < 0 {
		return 0, fmt.Errorf("invalid test cursor %q", value)
	}
	return offset, nil
}

func (r *memoryOutputRuntime) cursorForLocked(name string) ghostline.Cursor {
	return testCursor(len(r.outputs[name]))
}

func (r *memoryOutputRuntime) Checkpoint(_ context.Context, name string) (ghostline.Checkpoint, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	return ghostline.Checkpoint{
		Replay: append([]byte(nil), r.outputs[name]...),
		Cursor: r.cursorForLocked(name),
	}, nil
}

func (r *memoryOutputRuntime) AtomicState(ctx context.Context, name string) (ghostline.AtomicState, error) {
	checkpoint, err := r.Checkpoint(ctx, name)
	if err != nil {
		return ghostline.AtomicState{}, err
	}
	return ghostline.AtomicState{Format: ghostline.AtomicStateFormat, Payload: checkpoint.Replay, Cursor: checkpoint.Cursor}, nil
}

func (r *memoryOutputRuntime) OpenOutput(ctx context.Context, name string, cursor ghostline.Cursor) (CursorOutputReader, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if !r.sessions[name] {
		return nil, fmt.Errorf("session %q not found", name)
	}
	reader, err := newMemoryCursorReader(ctx, name, cursor,
		func(name string) []byte {
			r.mu.Lock()
			defer r.mu.Unlock()
			return append([]byte(nil), r.outputs[name]...)
		},
		func(reader *memoryCursorReader) {
			r.mu.Lock()
			defer r.mu.Unlock()
			delete(r.readers[name], reader)
		},
	)
	if err != nil {
		return nil, err
	}
	if r.readers == nil {
		r.readers = map[string]map[*memoryCursorReader]struct{}{}
	}
	if r.readers[name] == nil {
		r.readers[name] = map[*memoryCursorReader]struct{}{}
	}
	r.readers[name][reader] = struct{}{}
	return reader, nil
}

func (r *memoryRuntime) Checkpoint(_ context.Context, name string) (ghostline.Checkpoint, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	return ghostline.Checkpoint{
		Replay: append([]byte(nil), r.sessions[name]...),
		Cursor: testCursor(len(r.sessions[name])),
	}, nil
}

func (r *memoryRuntime) AtomicState(ctx context.Context, name string) (ghostline.AtomicState, error) {
	checkpoint, err := r.Checkpoint(ctx, name)
	if err != nil {
		return ghostline.AtomicState{}, err
	}
	return ghostline.AtomicState{Format: ghostline.AtomicStateFormat, Payload: checkpoint.Replay, Cursor: checkpoint.Cursor}, nil
}

func (r *memoryRuntime) OpenOutput(ctx context.Context, name string, cursor ghostline.Cursor) (CursorOutputReader, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if _, ok := r.sessions[name]; !ok {
		return nil, fmt.Errorf("session %q not found", name)
	}
	reader, err := newMemoryCursorReader(ctx, name, cursor,
		func(name string) []byte {
			r.mu.Lock()
			defer r.mu.Unlock()
			return append([]byte(nil), r.sessions[name]...)
		},
		func(reader *memoryCursorReader) {
			r.mu.Lock()
			defer r.mu.Unlock()
			delete(r.readers[name], reader)
		},
	)
	if err != nil {
		return nil, err
	}
	if r.readers == nil {
		r.readers = map[string]map[*memoryCursorReader]struct{}{}
	}
	if r.readers[name] == nil {
		r.readers[name] = map[*memoryCursorReader]struct{}{}
	}
	r.readers[name][reader] = struct{}{}
	return reader, nil
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

type terminalSubscriptionResult struct {
	Subscribed   bool   `json:"subscribed"`
	AttachmentID string `json:"attachmentId"`
}

func subscribeBrowser(t *testing.T, c *websocket.Conn, sessionID string, anchor *output.Anchor) {
	subscribeBrowserWithSize(t, c, sessionID, anchor, 0, 0)
}

func subscribeBrowserWithSize(t *testing.T, c *websocket.Conn, sessionID string, anchor *output.Anchor, columns, rows int) {
	t.Helper()
	params := map[string]any{"id": sessionID}
	// A visible browser surface owns the control lease while it is subscribed.
	params["claim"] = true
	if columns != 0 || rows != 0 {
		params["cols"] = columns
		params["rows"] = rows
	}
	if anchor != nil {
		params["epoch"] = anchor.Epoch
		params["sequence"] = anchor.Sequence
	}
	if err := c.WriteJSON(api.Envelope{Type: "request", ID: store.NewID(), Method: "session.subscribe", Params: params}); err != nil {
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
		if e == nil {
			return f
		}
		state, stateErr := output.DecodeAtomicState(d)
		if stateErr != nil {
			t.Fatalf("decode terminal frame: output=%v atomic=%v", e, stateErr)
		}
		return output.DecodedFrame{
			SessionID: state.SessionID,
			Epoch:     state.Epoch,
			Sequence:  state.Sequence,
			Payload:   state.Payload,
		}
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
func writeInputFrame(t *testing.T, c *websocket.Conn, sessionID, attachmentID string, sequence uint64, d []byte) {
	t.Helper()
	frame, err := output.EncodeInput(output.InputMetadata{
		Version:      api.Version,
		SessionID:    sessionID,
		AttachmentID: attachmentID,
		Sequence:     sequence,
	}, d)
	if err != nil {
		t.Fatal(err)
	}
	if err := c.WriteMessage(websocket.BinaryMessage, frame); err != nil {
		t.Fatal(err)
	}
}
