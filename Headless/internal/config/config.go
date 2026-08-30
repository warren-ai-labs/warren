package config

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"syscall"
)

var processLock sync.Mutex

type Endpoint struct {
	Name      string `json:"name"`
	URL       string `json:"url"`
	Token     string `json:"token"`
	SSH       string `json:"ssh,omitempty"`
	SSHRemote string `json:"sshRemote,omitempty"`
}
type Config struct {
	Current   string              `json:"current"`
	Endpoints map[string]Endpoint `json:"endpoints"`
}

func DefaultPath() string {
	if configured := strings.TrimSpace(os.Getenv("WARREN_CONFIG")); configured != "" {
		return configured
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".warren", "config.json")
}
func Load(path string) (Config, error) {
	unlock, err := lock(path)
	if err != nil {
		return Config{Endpoints: map[string]Endpoint{}}, err
	}
	defer unlock()
	value, migrated, err := loadUnlockedWithMigration(path)
	if err != nil {
		return value, err
	}
	if migrated {
		if err := saveUnlocked(path, value); err != nil {
			return value, fmt.Errorf("migrate config: %w", err)
		}
	}
	return value, nil
}
func Save(path string, value Config) error {
	unlock, err := lock(path)
	if err != nil {
		return err
	}
	defer unlock()
	return saveUnlocked(path, value)
}

// Update performs a read/modify/write transaction while holding the same
// sidecar lock used by Save.  Endpoint selection is shared by the Desktop and
// CLI, so loading and saving in separate critical sections can otherwise drop
// a concurrent update.
func Update(path string, update func(*Config) error) error {
	unlock, err := lock(path)
	if err != nil {
		return err
	}
	defer unlock()
	value, err := loadUnlocked(path)
	if err != nil {
		return err
	}
	if err := update(&value); err != nil {
		return err
	}
	return saveUnlocked(path, value)
}

func saveUnlocked(path string, value Config) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	if value.Endpoints == nil {
		value.Endpoints = map[string]Endpoint{}
	}
	if len(value.Endpoints) > 0 {
		endpoints := make(map[string]Endpoint, len(value.Endpoints))
		for name, endpoint := range value.Endpoints {
			if strings.TrimSpace(endpoint.SSH) != "" {
				// SSH endpoints own only durable route metadata. Never allow a
				// stale runtime URL/token supplied by a legacy caller to be
				// written back.
				endpoint.URL = ""
				endpoint.Token = ""
			}
			endpoints[name] = endpoint
		}
		value.Endpoints = endpoints
	}
	data, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	directory := filepath.Dir(path)
	temporaryFile, err := os.CreateTemp(directory, filepath.Base(path)+".tmp-*")
	if err != nil {
		return err
	}
	temporary := temporaryFile.Name()
	defer os.Remove(temporary)
	if err := temporaryFile.Chmod(0o600); err != nil {
		_ = temporaryFile.Close()
		return err
	}
	if _, err := temporaryFile.Write(append(data, '\n')); err != nil {
		_ = temporaryFile.Close()
		return err
	}
	if err := temporaryFile.Sync(); err != nil {
		_ = temporaryFile.Close()
		return err
	}
	if err := temporaryFile.Close(); err != nil {
		return err
	}
	return os.Rename(temporary, path)
}

func loadUnlocked(path string) (Config, error) {
	value, _, err := loadUnlockedWithMigration(path)
	return value, err
}

func loadUnlockedWithMigration(path string) (Config, bool, error) {
	value := Config{Endpoints: map[string]Endpoint{}}
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return value, false, nil
	}
	if err != nil {
		return value, false, err
	}
	if err := json.Unmarshal(data, &value); err != nil {
		return value, false, fmt.Errorf("decode config: %w", err)
	}
	if value.Endpoints == nil {
		value.Endpoints = map[string]Endpoint{}
	}
	// Older versions persisted the helper's loopback URL and bearer token
	// alongside SSH metadata. Treat SSH as the durable source of truth and
	// scrub those runtime values on every read so list/current output and the
	// next write cannot re-expose stale credentials.
	migrated := false
	for name, endpoint := range value.Endpoints {
		if strings.TrimSpace(endpoint.SSH) == "" || (endpoint.URL == "" && endpoint.Token == "") {
			continue
		}
		endpoint.URL = ""
		endpoint.Token = ""
		value.Endpoints[name] = endpoint
		migrated = true
	}
	return value, migrated, nil
}

func lock(path string) (func(), error) {
	// POSIX fcntl locks are process-associated: two descriptors opened by
	// goroutines in this CLI do not reliably exclude one another. Serialize
	// in-process callers before taking the cross-process sidecar lock.
	processLock.Lock()
	releaseProcessLock := true
	defer func() {
		if releaseProcessLock {
			processLock.Unlock()
		}
	}()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, err
	}
	file, err := os.OpenFile(path+".lock", os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, err
	}
	if err := file.Chmod(0o600); err != nil {
		_ = file.Close()
		return nil, err
	}
	lock := &syscall.Flock_t{Type: syscall.F_WRLCK, Whence: 0}
	if err := syscall.FcntlFlock(file.Fd(), syscall.F_SETLKW, lock); err != nil {
		_ = file.Close()
		return nil, fmt.Errorf("lock config: %w", err)
	}
	releaseProcessLock = false
	var once sync.Once
	return func() {
		once.Do(func() {
			unlock := &syscall.Flock_t{Type: syscall.F_UNLCK, Whence: 0}
			_ = syscall.FcntlFlock(file.Fd(), syscall.F_SETLK, unlock)
			_ = file.Close()
			processLock.Unlock()
		})
	}, nil
}
func (c Config) Resolve(name string) (Endpoint, error) {
	if name == "" {
		name = c.Current
	}
	value, ok := c.Endpoints[name]
	if !ok {
		return Endpoint{}, fmt.Errorf("endpoint not found: %s", name)
	}
	return value, nil
}
func (c Config) Names() []string {
	values := make([]string, 0, len(c.Endpoints))
	for name := range c.Endpoints {
		values = append(values, name)
	}
	sort.Strings(values)
	return values
}
