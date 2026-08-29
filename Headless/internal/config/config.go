package config

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
)

type Endpoint struct {
	Name    string `json:"name"`
	URL     string `json:"url"`
	Token   string `json:"token"`
	SSH     string `json:"ssh,omitempty"`
	Type    string `json:"type,omitempty"`
	HostID  string `json:"host_id,omitempty"`
	RouteID string `json:"route_id,omitempty"`
}
type Config struct {
	Current   string              `json:"current"`
	Endpoints map[string]Endpoint `json:"endpoints"`
}

func DefaultPath() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".warren", "config.json")
}
func Load(path string) (Config, error) {
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
	return value, nil
}
func Save(path string, value Config) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	data, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	temporary := path + ".tmp"
	if err := os.WriteFile(temporary, append(data, '\n'), 0o600); err != nil {
		return err
	}
	return os.Rename(temporary, path)
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
