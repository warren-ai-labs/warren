package server

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/abcdlsj/ghostline"
	"github.com/abcdlsj/warren/Headless/internal/runtime"
)

// GhostlineRuntime adapts ghostline's session-handle API to the name-based
// Runtime surface used by Service. Handles are cached by name and re-adopted
// from the server on demand, so a daemon restart keeps managing sessions
// owned by a detached ghostline serve process.
type GhostlineRuntime struct {
	client   *ghostline.Client
	mu       sync.Mutex
	sessions map[string]*ghostline.Session
}

func NewGhostlineRuntime(client *ghostline.Client) *GhostlineRuntime {
	return &GhostlineRuntime{client: client, sessions: map[string]*ghostline.Session{}}
}

func (r *GhostlineRuntime) Check(ctx context.Context) error {
	return r.client.Check(ctx)
}

func (r *GhostlineRuntime) Create(ctx context.Context, name, directory, command string, env []string) error {
	// The PTY always starts an interactive login shell and the requested
	// command is typed into it, so quitting an agent TUI leaves a usable
	// terminal behind. The daemon removes ambient NO_COLOR before starting the
	// ghostline server; do not pass NO_COLOR= here because presence of an empty
	// variable still disables colors for Codex.
	sessionEnv := append([]string(nil), env...)
	session, err := r.client.Start(ctx, ghostline.SessionOptions{
		Name: name,
		Process: ghostline.ProcessSpec{
			Directory:   directory,
			Environment: sessionEnv,
		},
	})
	if err != nil {
		return err
	}
	if strings.TrimSpace(command) != "" {
		// Give the login shell a beat to start, then type the command.
		time.Sleep(400 * time.Millisecond)
		if err := session.WriteInput(ctx, []byte(command+"\r")); err != nil {
			return fmt.Errorf("type session command: %w", err)
		}
	}
	r.mu.Lock()
	r.sessions[name] = session
	r.mu.Unlock()
	return nil
}

func (r *GhostlineRuntime) session(ctx context.Context, name string) (*ghostline.Session, error) {
	r.mu.Lock()
	session := r.sessions[name]
	r.mu.Unlock()
	if session != nil {
		return session, nil
	}
	adopted, err := r.client.Get(ctx, name)
	if err != nil {
		return nil, err
	}
	r.mu.Lock()
	if existing := r.sessions[name]; existing != nil {
		r.mu.Unlock()
		return existing, nil
	}
	r.sessions[name] = adopted
	r.mu.Unlock()
	return adopted, nil
}

func (r *GhostlineRuntime) Exists(ctx context.Context, name string) bool {
	session, err := r.session(ctx, name)
	if err != nil {
		return false
	}
	status, err := session.Status(ctx)
	return err == nil && status.Alive
}

func (r *GhostlineRuntime) Capture(ctx context.Context, name string) ([]byte, error) {
	session, err := r.session(ctx, name)
	if err != nil {
		return nil, fmt.Errorf("ghostline session %s: %w", name, err)
	}
	return session.Replay(ctx)
}

func (r *GhostlineRuntime) Input(ctx context.Context, name string, data []byte) error {
	session, err := r.session(ctx, name)
	if err != nil {
		return fmt.Errorf("ghostline session %s: %w", name, err)
	}
	return session.WriteInput(ctx, data)
}

func (r *GhostlineRuntime) Resize(ctx context.Context, name string, columns, rows int) error {
	session, err := r.session(ctx, name)
	if err != nil {
		return fmt.Errorf("ghostline session %s: %w", name, err)
	}
	return session.Resize(ctx, ghostline.Size{Columns: columns, Rows: rows})
}

func (r *GhostlineRuntime) Kill(ctx context.Context, name string) error {
	session, err := r.session(ctx, name)
	if errors.Is(err, ghostline.ErrSessionNotFound) {
		return nil
	}
	if err != nil {
		return err
	}
	err = session.Delete(ctx)
	if errors.Is(err, ghostline.ErrSessionNotFound) {
		return nil
	}
	if err == nil {
		r.mu.Lock()
		delete(r.sessions, name)
		r.mu.Unlock()
	}
	return err
}

func (r *GhostlineRuntime) List(ctx context.Context) (map[string]bool, error) {
	listed, err := r.client.List(ctx)
	if err != nil {
		return nil, err
	}
	sessions := make(map[string]bool, len(listed))
	r.mu.Lock()
	defer r.mu.Unlock()
	for _, session := range listed {
		sessions[session.Name()] = true
		r.sessions[session.Name()] = session
	}
	return sessions, nil
}

func (r *GhostlineRuntime) ListCreated(ctx context.Context) (map[string]time.Time, error) {
	sessions, err := r.client.List(ctx)
	if err != nil {
		return nil, err
	}
	result := make(map[string]time.Time, len(sessions))
	r.mu.Lock()
	defer r.mu.Unlock()
	for _, session := range sessions {
		result[session.Name()] = session.CreatedAt()
		r.sessions[session.Name()] = session
	}
	return result, nil
}

// Metadata reports the foreground process snapshot from ghostline when the
// server was started with ProbeForeground enabled. Older servers without the
// capability return empty metadata without failing the roster.
func (r *GhostlineRuntime) Metadata(ctx context.Context, name string) (runtime.RuntimeMetadata, error) {
	session, err := r.session(ctx, name)
	if err != nil {
		return runtime.RuntimeMetadata{}, fmt.Errorf("ghostline session %s: %w", name, err)
	}
	metadata, err := session.Metadata(ctx)
	if err != nil {
		return runtime.RuntimeMetadata{}, err
	}
	return runtime.RuntimeMetadata{Process: metadata.Process, Directory: metadata.Directory}, nil
}

// Checkpoint captures a v1 replay together with an opaque output cursor. The
// Service owns the reader lifecycle so it never exposes or interprets v1
// output storage paths.
func (r *GhostlineRuntime) Checkpoint(ctx context.Context, name string) (ghostline.Checkpoint, error) {
	session, err := r.session(ctx, name)
	if err != nil {
		return ghostline.Checkpoint{}, fmt.Errorf("ghostline session %s: %w", name, err)
	}
	return session.Checkpoint(ctx)
}

// AtomicState captures Ghostty's native terminal state together with the
// first output cursor not represented by it. Warren treats the payload as an
// opaque runtime artifact and forwards its advertised format unchanged.
func (r *GhostlineRuntime) AtomicState(ctx context.Context, name string) (ghostline.AtomicState, error) {
	session, err := r.session(ctx, name)
	if err != nil {
		return ghostline.AtomicState{}, fmt.Errorf("ghostline session %s: %w", name, err)
	}
	return session.AtomicState(ctx)
}

// OpenOutput creates one caller-owned v1 reader from an opaque cursor.
func (r *GhostlineRuntime) OpenOutput(ctx context.Context, name string, cursor ghostline.Cursor) (CursorOutputReader, error) {
	session, err := r.session(ctx, name)
	if err != nil {
		return nil, fmt.Errorf("ghostline session %s: %w", name, err)
	}
	return session.Output(ctx, cursor)
}
