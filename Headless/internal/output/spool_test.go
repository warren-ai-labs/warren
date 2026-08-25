package output

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestSpoolWatcherPingsAndAppliesShorterInterval(t *testing.T) {
	path := filepath.Join(t.TempDir(), "output.spool")
	if err := os.WriteFile(path, nil, 0o600); err != nil {
		t.Fatal(err)
	}

	seen := make(chan string, 2)
	watcher, err := NewSpoolWatcher(path, 0, func(data []byte) {
		seen <- string(data)
	}, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	watcher.SetInterval(time.Hour)
	watcher.Start()
	defer watcher.Close()

	appendSpool(t, path, "ping")
	watcher.Ping()
	if got := waitForSpoolData(t, seen); got != "ping" {
		t.Fatalf("ping data = %q, want %q", got, "ping")
	}

	appendSpool(t, path, "poll")
	watcher.SetInterval(5 * time.Millisecond)
	if got := waitForSpoolData(t, seen); got != "poll" {
		t.Fatalf("poll data = %q, want %q", got, "poll")
	}
}

func TestSpoolWatcherPauseAndSkipTo(t *testing.T) {
	path := filepath.Join(t.TempDir(), "output.spool")
	if err := os.WriteFile(path, []byte("before"), 0o600); err != nil {
		t.Fatal(err)
	}

	seen := make(chan string, 1)
	watcher, err := NewSpoolWatcher(path, 0, func(data []byte) {
		seen <- string(data)
	}, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	watcher.Pause()
	if err := watcher.SkipTo(int64(len("before"))); err != nil {
		t.Fatal(err)
	}
	watcher.Start()
	defer watcher.Close()
	appendSpool(t, path, "after")
	watcher.Resume()
	if got := waitForSpoolData(t, seen); got != "after" {
		t.Fatalf("skipped spool data = %q, want %q", got, "after")
	}
}

func appendSpool(t *testing.T, path, value string) {
	t.Helper()
	file, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	if _, err := file.WriteString(value); err != nil {
		t.Fatal(err)
	}
}

func waitForSpoolData(t *testing.T, seen <-chan string) string {
	t.Helper()
	select {
	case value := <-seen:
		return value
	case <-time.After(500 * time.Millisecond):
		t.Fatal("spool watcher did not deliver data")
		return ""
	}
}
