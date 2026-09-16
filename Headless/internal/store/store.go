package store

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/user"
	"path/filepath"
	"runtime"
	"sync"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

type Store struct {
	// mu guards the published state, revision, and change channel. It is held
	// only for the clone of the current state and for the pointer swap that
	// publishes an update, never across disk I/O. Roster snapshots and session
	// lookups read through mu, so holding it during the full state.json rewrite
	// used to starve terminal attaches for seconds after a daemon restart.
	mu sync.RWMutex
	// writeMu serializes writers and their persistence so a slow disk write can
	// neither block readers of mu nor let two writers interleave.
	writeMu  sync.Mutex
	path     string
	state    api.State
	revision uint64
	changed  chan struct{}
}

const currentSchema = 4

var alreadyChanged = func() <-chan struct{} {
	value := make(chan struct{})
	close(value)
	return value
}()

func Open(path, hostName string) (*Store, error) {
	s := &Store{path: path, changed: make(chan struct{})}
	data, err := os.ReadFile(path)
	if err == nil {
		if err := json.Unmarshal(data, &s.state); err != nil {
			return nil, fmt.Errorf("decode state: %w", err)
		}
		migrated := false
		switch s.state.Schema {
		case 1, 2, 3:
			// The state shape remains compatible across these releases. Bump the
			// marker and preserve every known field instead of forcing a reset.
			// Schema 4 adds Host-owned Pane Groups; a Host that has never served a
			// split simply carries none.
			s.state.Schema = currentSchema
			migrated = true
		case currentSchema:
		default:
			return nil, &StateResetError{Path: path, FoundSchema: s.state.Schema, RequiredSchema: currentSchema}
		}
		if len(s.state.TerminalGroups) == 0 {
			if err := ensureTerminalGroups(&s.state); err != nil {
				return nil, err
			}
			migrated = true
		}
		if migrated {
			if err := s.save(s.state); err != nil {
				return nil, err
			}
		}
		return s, nil
	}
	if !errors.Is(err, os.ErrNotExist) {
		return nil, fmt.Errorf("read state: %w", err)
	}
	if hostName == "" {
		hostName, _ = os.Hostname()
	}
	current, _ := user.Current()
	s.state = api.State{
		Schema: currentSchema,
		Host:   api.Host{ID: NewID(), Name: hostName, User: userName(current), OS: runtime.GOOS + "/" + runtime.GOARCH, Version: api.Version},
	}
	if err := ensureTerminalGroups(&s.state); err != nil {
		return nil, err
	}
	if err := s.save(s.state); err != nil {
		return nil, err
	}
	return s, nil
}

// StateResetError is returned for unknown or future state files. Known older
// schemas are upgraded in place because their fields remain compatible.
type StateResetError struct {
	Path           string
	FoundSchema    int
	RequiredSchema int
}

func (e *StateResetError) Error() string {
	if e == nil {
		return "state_reset_required"
	}
	return fmt.Sprintf("state_reset_required: %s has schema %d; create a fresh state file with schema %d", e.Path, e.FoundSchema, e.RequiredSchema)
}

func userName(value *user.User) string {
	if value == nil {
		return ""
	}
	return value.Username
}

func (s *Store) Snapshot() api.State {
	state, _ := s.SnapshotVersion()
	return state
}

func (s *Store) SnapshotVersion() (api.State, uint64) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return clone(s.state), s.revision
}

func (s *Store) ChangesSince(revision uint64) <-chan struct{} {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if revision != s.revision {
		return alreadyChanged
	}
	return s.changed
}

func (s *Store) Update(fn func(*api.State) error) error {
	// Writers are serialized by writeMu while mu is only taken for the clone
	// and the publish below. Snapshot, SnapshotVersion, and ChangesSince
	// therefore never wait for the state.json rewrite or for another writer.
	s.writeMu.Lock()
	defer s.writeMu.Unlock()

	s.mu.RLock()
	next := clone(s.state)
	s.mu.RUnlock()

	if err := fn(&next); err != nil {
		return err
	}
	// Persist before publishing so a failed write leaves the in-memory state
	// untouched, matching the previous rollback contract.
	if err := s.save(next); err != nil {
		return err
	}

	s.mu.Lock()
	s.state = next
	s.revision++
	close(s.changed)
	s.changed = make(chan struct{})
	s.mu.Unlock()
	return nil
}

// save persists value to disk. Callers must hold writeMu, or be Open before
// the Store is shared, so writes stay ordered and the published state only
// advances after it is durable.
func (s *Store) save(value api.State) error {
	if err := os.MkdirAll(filepath.Dir(s.path), 0o700); err != nil {
		return fmt.Errorf("create state directory: %w", err)
	}
	data, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	temporary := s.path + ".tmp"
	if err := os.WriteFile(temporary, append(data, '\n'), 0o600); err != nil {
		return fmt.Errorf("write state: %w", err)
	}
	if err := os.Rename(temporary, s.path); err != nil {
		return fmt.Errorf("commit state: %w", err)
	}
	return nil
}

func NewID() string {
	var raw [16]byte
	if _, err := rand.Read(raw[:]); err != nil {
		panic(err)
	}
	raw[6] = (raw[6] & 0x0f) | 0x40
	raw[8] = (raw[8] & 0x3f) | 0x80
	value := hex.EncodeToString(raw[:])
	return value[0:8] + "-" + value[8:12] + "-" + value[12:16] + "-" + value[16:20] + "-" + value[20:32]
}

func clone(value api.State) api.State {
	result := value
	result.Tasks = append([]api.Task(nil), value.Tasks...)
	result.Projects = append([]api.Project(nil), value.Projects...)
	result.Workspaces = append([]api.Workspace(nil), value.Workspaces...)
	result.TerminalGroups = append([]api.TerminalGroup(nil), value.TerminalGroups...)
	result.Sessions = append([]api.Session(nil), value.Sessions...)
	if value.GhostlineMigration != nil {
		migration := *value.GhostlineMigration
		migration.SkippedSessions = append([]string(nil), value.GhostlineMigration.SkippedSessions...)
		if value.GhostlineMigration.SkipReasons != nil {
			migration.SkipReasons = make(map[string]string, len(value.GhostlineMigration.SkipReasons))
			for key, reason := range value.GhostlineMigration.SkipReasons {
				migration.SkipReasons[key] = reason
			}
		}
		result.GhostlineMigration = &migration
	}
	result.Operations = append([]api.OperationAudit(nil), value.Operations...)
	for index := range result.Sessions {
		if value.Sessions[index].AgentCapabilities != nil {
			result.Sessions[index].AgentCapabilities = append([]string(nil), value.Sessions[index].AgentCapabilities...)
		}
		if value.Sessions[index].EndedAt == nil {
			continue
		}
		endedAt := *value.Sessions[index].EndedAt
		result.Sessions[index].EndedAt = &endedAt
	}
	for index := range result.Operations {
		if value.Operations[index].RevertedAt == nil {
			continue
		}
		revertedAt := *value.Operations[index].RevertedAt
		result.Operations[index].RevertedAt = &revertedAt
	}
	return result
}

func ensureTerminalGroups(state *api.State) error {
	if len(state.TerminalGroups) > 0 {
		return nil
	}
	state.TerminalGroups = []api.TerminalGroup{{
		ID:        NewID(),
		Name:      "Inbox",
		CreatedAt: time.Now().UTC(),
	}}
	return nil
}
