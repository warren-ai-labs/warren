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
	mu       sync.RWMutex
	path     string
	state    api.State
	revision uint64
	changed  chan struct{}
}

const currentSchema = 2

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
		case 1:
			s.state.Schema = currentSchema
			migrated = true
		case currentSchema:
		default:
			return nil, fmt.Errorf("unsupported state schema %d", s.state.Schema)
		}
		if len(s.state.TerminalGroups) == 0 {
			if err := ensureTerminalGroups(&s.state); err != nil {
				return nil, err
			}
			migrated = true
		}
		if migrated {
			if err := s.saveLocked(); err != nil {
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
	if err := s.saveLocked(); err != nil {
		return nil, err
	}
	return s, nil
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
	s.mu.Lock()
	defer s.mu.Unlock()
	next := clone(s.state)
	if err := fn(&next); err != nil {
		return err
	}
	old := s.state
	s.state = next
	if err := s.saveLocked(); err != nil {
		s.state = old
		return err
	}
	s.revision++
	close(s.changed)
	s.changed = make(chan struct{})
	return nil
}

func (s *Store) saveLocked() error {
	if err := os.MkdirAll(filepath.Dir(s.path), 0o700); err != nil {
		return fmt.Errorf("create state directory: %w", err)
	}
	data, err := json.MarshalIndent(s.state, "", "  ")
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
		result.GhostlineMigration = &migration
	}
	result.Operations = append([]api.OperationAudit(nil), value.Operations...)
	for index := range result.Sessions {
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
