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
	Type      string `json:"type,omitempty"`
	HostID    string `json:"host_id,omitempty"`
	RouteID   string `json:"route_id,omitempty"`
	ClientID  string `json:"client_id,omitempty"`
	// RefreshToken and the route fields are persisted by native clients. Keep
	// them in the shared Go model so CLI display writes cannot discard metadata
	// it does not otherwise interpret.
	RefreshToken    string `json:"refresh_token,omitempty"`
	DirectURL       string `json:"direct_url,omitempty"`
	RelayURL        string `json:"relay_url,omitempty"`
	RoutePreference string `json:"route_preference,omitempty"`
}

// DisplayConfig is the client-local, ordered set of endpoint aliases shown
// together by the Desktop. It intentionally stores aliases only;
// endpoint credentials and route metadata remain in Config.Endpoints.
type DisplayConfig struct {
	Version   int      `json:"version"`
	Endpoints []string `json:"endpoints"`
}

type Config struct {
	Current   string              `json:"current"`
	Endpoints map[string]Endpoint `json:"endpoints"`
	Display   *DisplayConfig      `json:"display,omitempty"`
}

// UnmarshalJSON accepts the preview sidebar field as a read-only migration
// path. Writes use Config.Display and therefore emit only the public display
// field.
func (c *Config) UnmarshalJSON(data []byte) error {
	type configWire struct {
		Current       string              `json:"current"`
		Endpoints     map[string]Endpoint `json:"endpoints"`
		Display       *DisplayConfig      `json:"display"`
		LegacySidebar *DisplayConfig      `json:"sidebar"`
	}
	var wire configWire
	if err := json.Unmarshal(data, &wire); err != nil {
		return err
	}
	c.Current = wire.Current
	c.Endpoints = wire.Endpoints
	c.Display = wire.Display
	if c.Display == nil {
		c.Display = wire.LegacySidebar
	}
	return nil
}

const DisplayConfigVersion = 1

// EffectiveDisplay returns the ordered aliases that should be visible to a
// client. A missing display section preserves the pre-display single-current
// behavior. The synthetic local alias is always valid, even when it has no
// explicit row in Endpoints.
func (c Config) EffectiveDisplay() ([]string, error) {
	if c.Display == nil {
		current := strings.TrimSpace(c.Current)
		if current == "" {
			current = "local"
		}
		return []string{current}, nil
	}
	if c.Display.Version != 0 && c.Display.Version != DisplayConfigVersion {
		return nil, fmt.Errorf("unsupported display config version: %d", c.Display.Version)
	}
	aliases, err := normalizeDisplayAliases(c.Display.Endpoints)
	if err != nil {
		return nil, err
	}
	if len(aliases) == 0 {
		return nil, errors.New("display endpoint set cannot be empty")
	}
	for _, alias := range aliases {
		if alias != "local" {
			if _, ok := c.Endpoints[alias]; !ok {
				return nil, fmt.Errorf("display endpoint not found: %s", alias)
			}
		}
	}
	return aliases, nil
}

// NormalizeDisplay validates and canonicalizes an explicitly configured
// display set. Current remains an independent foreground-connection choice;
// switching it must never add an alias to Display.
func (c *Config) NormalizeDisplay() error {
	if c.Endpoints == nil {
		c.Endpoints = map[string]Endpoint{}
	}
	if c.Display == nil {
		if strings.TrimSpace(c.Current) == "" {
			c.Current = "local"
		}
		return nil
	}
	if c.Display.Version == 0 {
		c.Display.Version = DisplayConfigVersion
	}
	if c.Display.Version != DisplayConfigVersion {
		return fmt.Errorf("unsupported display config version: %d", c.Display.Version)
	}
	aliases, err := normalizeDisplayAliases(c.Display.Endpoints)
	if err != nil {
		return err
	}
	if len(aliases) == 0 {
		return errors.New("display endpoint set cannot be empty")
	}
	for _, alias := range aliases {
		if alias != "local" {
			if _, ok := c.Endpoints[alias]; !ok {
				return fmt.Errorf("display endpoint not found: %s", alias)
			}
		}
	}
	c.Display.Endpoints = aliases
	current := strings.TrimSpace(c.Current)
	if current == "" {
		current = "local"
	}
	if current != "local" {
		if _, ok := c.Endpoints[current]; !ok {
			return fmt.Errorf("endpoint not found: %s", current)
		}
	}
	// Keep the persisted marker canonical even when an older caller passed
	// surrounding whitespace. Display aliases are validated independently, so
	// a valid current endpoint does not need to appear in that list.
	c.Current = current
	return nil
}

func normalizeDisplayAliases(values []string) ([]string, error) {
	result := make([]string, 0, len(values))
	seen := make(map[string]struct{}, len(values))
	for _, raw := range values {
		alias := strings.TrimSpace(raw)
		if alias == "" {
			return nil, errors.New("display endpoint name cannot be empty")
		}
		if alias != raw {
			return nil, fmt.Errorf("display endpoint name must not have surrounding whitespace: %q", raw)
		}
		if strings.ContainsAny(alias, "\r\n\x00") {
			return nil, fmt.Errorf("invalid display endpoint name: %q", alias)
		}
		if _, exists := seen[alias]; exists {
			continue
		}
		seen[alias] = struct{}{}
		result = append(result, alias)
	}
	return result, nil
}

func containsDisplayAlias(values []string, target string) bool {
	for _, value := range values {
		if value == target {
			return true
		}
	}
	return false
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
	return loadUnlocked(path)
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
	if value.Display != nil {
		if err := value.NormalizeDisplay(); err != nil {
			return err
		}
	}
	if len(value.Endpoints) > 0 {
		endpoints := make(map[string]Endpoint, len(value.Endpoints))
		for name, endpoint := range value.Endpoints {
			if strings.TrimSpace(endpoint.SSH) != "" {
				// SSH endpoints own only durable route metadata. Never allow a
				// runtime URL or token to be written alongside that route.
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
	value := Config{Endpoints: map[string]Endpoint{}}
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return value, nil
	}
	if err != nil {
		return value, err
	}
	if err := json.Unmarshal(data, &value); err != nil {
		return value, fmt.Errorf("decode config: %w", err)
	}
	if value.Endpoints == nil {
		value.Endpoints = map[string]Endpoint{}
	}
	for name, endpoint := range value.Endpoints {
		if strings.TrimSpace(endpoint.SSH) == "" || (endpoint.URL == "" && endpoint.Token == "") {
			continue
		}
		return Config{Endpoints: map[string]Endpoint{}}, fmt.Errorf(
			"state_reset_required: endpoint %q contains removed SSH runtime fields; recreate the Warren config",
			name,
		)
	}
	return value, nil
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
