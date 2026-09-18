package main

import (
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

// line returns an 11-byte log line so a small max keeps the test readable.
func line(index int) string {
	return "line" + string(rune('0'+index%10)) + strings.Repeat("x", 6) + "\n"
}

func readFile(t *testing.T, path string) string {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	return string(data)
}

func TestRotatingLogFileRotatesWhileRunning(t *testing.T) {
	path := filepath.Join(t.TempDir(), "daemon.log")
	file, err := newRotatingLogFile(path, 100)
	if err != nil {
		t.Fatalf("newRotatingLogFile: %v", err)
	}
	var written strings.Builder
	for i := 0; i < 12; i++ {
		if _, err := file.Write([]byte(line(i))); err != nil {
			t.Fatalf("write %d: %v", i, err)
		}
		written.WriteString(line(i))
	}

	current, err := os.Stat(path)
	if err != nil {
		t.Fatalf("stat current log: %v", err)
	}
	if current.Size() > 100 {
		t.Fatalf("current log is %d bytes, want at most 100", current.Size())
	}
	combined := readFile(t, path+".1") + readFile(t, path)
	if combined != written.String() {
		t.Fatalf("combined generations lost lines:\ngot  %q\nwant %q", combined, written.String())
	}
}

func TestRotatingLogFileKeepsOneGeneration(t *testing.T) {
	path := filepath.Join(t.TempDir(), "daemon.log")
	file, err := newRotatingLogFile(path, 100)
	if err != nil {
		t.Fatalf("newRotatingLogFile: %v", err)
	}
	for i := 0; i < 200; i++ {
		if _, err := file.Write([]byte(line(i))); err != nil {
			t.Fatalf("write %d: %v", i, err)
		}
	}
	if _, err := os.Stat(path + ".1"); err != nil {
		t.Fatalf("stat previous generation: %v", err)
	}
	if _, err := os.Stat(path + ".1.1"); !os.IsNotExist(err) {
		t.Fatalf("second backup generation exists, want only one: %v", err)
	}
	combined := readFile(t, path+".1") + readFile(t, path)
	if !strings.HasSuffix(combined, line(199)) {
		t.Fatalf("combined generations do not end with the last line")
	}
}

func TestRotatingLogFileRotatesOversizedLeftoverOnOpen(t *testing.T) {
	path := filepath.Join(t.TempDir(), "daemon.log")
	oversized := strings.Repeat(line(0), 20)
	if err := os.WriteFile(path, []byte(oversized), 0o600); err != nil {
		t.Fatalf("seed oversized log: %v", err)
	}

	file, err := newRotatingLogFile(path, 100)
	if err != nil {
		t.Fatalf("newRotatingLogFile: %v", err)
	}
	if got := readFile(t, path+".1"); got != oversized {
		t.Fatalf("previous generation = %q, want the oversized log", got)
	}
	if _, err := file.Write([]byte(line(1))); err != nil {
		t.Fatalf("write after rotation: %v", err)
	}
	if got := readFile(t, path); got != line(1) {
		t.Fatalf("current log = %q, want only the new line", got)
	}
}

func TestRotatingLogFileConcurrentWrites(t *testing.T) {
	path := filepath.Join(t.TempDir(), "daemon.log")
	file, err := newRotatingLogFile(path, 256)
	if err != nil {
		t.Fatalf("newRotatingLogFile: %v", err)
	}
	var group sync.WaitGroup
	for worker := 0; worker < 8; worker++ {
		group.Add(1)
		go func() {
			defer group.Done()
			for i := 0; i < 50; i++ {
				if _, err := file.Write([]byte(line(i))); err != nil {
					t.Errorf("concurrent write: %v", err)
					return
				}
			}
		}()
	}
	group.Wait()

	for _, name := range []string{path, path + ".1"} {
		info, err := os.Stat(name)
		if err != nil {
			t.Fatalf("stat %s: %v", name, err)
		}
		if info.Size() > 256 {
			t.Fatalf("%s is %d bytes, want at most 256", name, info.Size())
		}
	}
}

func TestNewLoggerWritesToFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "daemon.log")
	newLogger(path).Info("daemon started", "port", 8789)

	written := readFile(t, path)
	if !strings.Contains(written, "daemon started") || !strings.Contains(written, "port=8789") {
		t.Fatalf("log file = %q, want the structured line", written)
	}
}
