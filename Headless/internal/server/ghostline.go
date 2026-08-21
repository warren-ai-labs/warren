package server

import (
	"context"
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
	sessions map[string]ghostline.Session
}

func NewGhostlineRuntime(client *ghostline.Client) *GhostlineRuntime {
	return &GhostlineRuntime{client: client, sessions: map[string]ghostline.Session{}}
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
		Name:        name,
		Directory:   directory,
		Command:     "",
		Environment: sessionEnv,
	})
	if err != nil {
		return err
	}
	if strings.TrimSpace(command) != "" {
		// Give the login shell a beat to start, then type the command.
		time.Sleep(400 * time.Millisecond)
		if err := session.Input(ctx, []byte(command+"\r")); err != nil {
			return fmt.Errorf("type session command: %w", err)
		}
	}
	r.mu.Lock()
	r.sessions[name] = session
	r.mu.Unlock()
	return nil
}

func (r *GhostlineRuntime) session(ctx context.Context, name string) ghostline.Session {
	r.mu.Lock()
	session := r.sessions[name]
	r.mu.Unlock()
	if session != nil {
		return session
	}
	adopted, ok := r.client.Session(name)
	if !ok {
		return nil
	}
	r.mu.Lock()
	r.sessions[name] = adopted
	r.mu.Unlock()
	return adopted
}

func (r *GhostlineRuntime) Exists(ctx context.Context, name string) bool {
	session := r.session(ctx, name)
	return session != nil && session.Alive()
}

func (r *GhostlineRuntime) Capture(ctx context.Context, name string) ([]byte, error) {
	session := r.session(ctx, name)
	if session == nil {
		return nil, fmt.Errorf("ghostline session not found: %s", name)
	}
	return session.Snapshot(ctx)
}

func (r *GhostlineRuntime) Input(ctx context.Context, name string, data []byte) error {
	session := r.session(ctx, name)
	if session == nil {
		return fmt.Errorf("ghostline session not found: %s", name)
	}
	return session.Input(ctx, data)
}

func (r *GhostlineRuntime) Resize(ctx context.Context, name string, columns, rows int) error {
	session := r.session(ctx, name)
	if session == nil {
		return fmt.Errorf("ghostline session not found: %s", name)
	}
	return session.Resize(ctx, ghostline.Size{Columns: columns, Rows: rows})
}

func (r *GhostlineRuntime) Kill(ctx context.Context, name string) error {
	session := r.session(ctx, name)
	if session == nil {
		return nil
	}
	return session.Remove()
}

// EnsurePipe is a no-op: ghostline writes its own spool, there is no pipe to
// install on adoption.
func (r *GhostlineRuntime) EnsurePipe(context.Context, string) error { return nil }

func (r *GhostlineRuntime) SpoolPath(name string) string {
	session := r.session(context.Background(), name)
	if session == nil {
		return ""
	}
	return session.SpoolPath()
}

func (r *GhostlineRuntime) SpoolSize(ctx context.Context, name string) (int64, error) {
	session := r.session(ctx, name)
	if session == nil {
		return 0, fmt.Errorf("ghostline session not found: %s", name)
	}
	return session.SpoolSize(ctx)
}

func (r *GhostlineRuntime) TruncateSpool(ctx context.Context, name string) error {
	session := r.session(ctx, name)
	if session == nil {
		return fmt.Errorf("ghostline session not found: %s", name)
	}
	return session.TruncateSpool(ctx)
}

func (r *GhostlineRuntime) ArchiveSpool(ctx context.Context, name string) error {
	session := r.session(ctx, name)
	if session == nil {
		return fmt.Errorf("ghostline session not found: %s", name)
	}
	return session.ArchiveSpool(ctx)
}

func (r *GhostlineRuntime) RemoveSpool(name string) {
	if session := r.session(context.Background(), name); session != nil {
		session.RemoveSpool()
	}
}

func (r *GhostlineRuntime) List(ctx context.Context) (map[string]bool, error) {
	names, err := r.client.List(ctx)
	if err != nil {
		return nil, err
	}
	sessions := make(map[string]bool, len(names))
	for _, name := range names {
		sessions[name] = true
	}
	return sessions, nil
}

func (r *GhostlineRuntime) Recover(ctx context.Context, name string, offset, end int64) ([]byte, error) {
	session := r.session(ctx, name)
	if session == nil {
		return nil, fmt.Errorf("ghostline session not found: %s", name)
	}
	return session.Recover(ctx, offset, end)
}

func (r *GhostlineRuntime) ListCreated(ctx context.Context) (map[string]time.Time, error) {
	sessions := r.client.Sessions()
	result := make(map[string]time.Time, len(sessions))
	for _, session := range sessions {
		result[session.Name()] = session.CreatedAt()
	}
	return result, nil
}

// Metadata reports the foreground process snapshot from ghostline when the
// server was started with ProbeForeground enabled. Older servers without the
// capability return empty metadata without failing the roster.
func (r *GhostlineRuntime) Metadata(ctx context.Context, name string) (runtime.RuntimeMetadata, error) {
	session := r.session(ctx, name)
	if session == nil {
		return runtime.RuntimeMetadata{}, fmt.Errorf("ghostline session not found: %s", name)
	}
	provider, ok := session.(ghostline.MetadataProvider)
	if !ok {
		return runtime.RuntimeMetadata{}, nil
	}
	metadata, err := provider.Metadata(ctx)
	if err != nil {
		return runtime.RuntimeMetadata{}, err
	}
	return runtime.RuntimeMetadata{Process: metadata.Process, Directory: metadata.Directory}, nil
}
