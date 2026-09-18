package main

import (
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"sync"
)

// maxLogFileBytes bounds the daemon log before it rotates to headless.log.1.
const maxLogFileBytes = 5 * 1024 * 1024

// newLogger writes structured logs to stderr and, when a path is configured,
// to a 0600 append-only file. Only high-signal events reach the file: daemon
// start/stop, Relay route changes, and errors. The file rotates to a single
// `.1` generation as soon as a write would push it past maxLogFileBytes, so a
// long-running daemon never grows its log without bound.
func newLogger(path string) *slog.Logger {
	writers := []io.Writer{os.Stderr}
	if path != "" {
		if file, err := newRotatingLogFile(path, maxLogFileBytes); err == nil {
			writers = append(writers, file)
		}
	}
	return slog.New(slog.NewTextHandler(io.MultiWriter(writers...), nil))
}

// rotatingLogFile appends to one path and rolls it to a single `<path>.1`
// generation once the next write would exceed max.
//
// Every goroutine that logs reaches Write through the slog handler, so the
// mutex serializes opening, rotating, and appending. Rotation never closes the
// live handle before its replacement exists: a failed rename or reopen leaves
// the current handle appendable so a logging hiccup cannot drop the line that
// triggered it.
type rotatingLogFile struct {
	path string
	max  int64

	mu    sync.Mutex
	file  *os.File
	bytes int64
}

func newRotatingLogFile(path string, max int64) (*rotatingLogFile, error) {
	file := &rotatingLogFile{path: path, max: max}
	file.mu.Lock()
	defer file.mu.Unlock()
	if err := file.openLocked(); err != nil {
		return nil, err
	}
	return file, nil
}

func (w *rotatingLogFile) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.bytes > 0 && w.bytes+int64(len(p)) > w.max {
		w.rotateLocked()
	}
	written, err := w.file.Write(p)
	w.bytes += int64(written)
	return written, err
}

// openLocked opens the path for appending and records its current size. A
// leftover log already at or past max is rotated away first, so a restart
// after a long run does not keep appending to an oversized file.
func (w *rotatingLogFile) openLocked() error {
	if info, err := os.Stat(w.path); err == nil && info.Size() >= w.max {
		_ = os.Rename(w.path, w.path+".1")
	}
	if err := os.MkdirAll(filepath.Dir(w.path), 0o700); err != nil {
		return err
	}
	file, err := os.OpenFile(w.path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	info, err := file.Stat()
	if err != nil {
		_ = file.Close()
		return err
	}
	w.file = file
	w.bytes = info.Size()
	return nil
}

// rotateLocked keeps exactly one previous generation and reopens an empty log.
// Any failure leaves the current handle untouched and writable, and the next
// write retries the rotation.
func (w *rotatingLogFile) rotateLocked() {
	previous := w.file
	_ = os.Remove(w.path + ".1")
	if err := os.Rename(w.path, w.path+".1"); err != nil {
		return
	}
	file, err := os.OpenFile(w.path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		_ = os.Rename(w.path+".1", w.path)
		return
	}
	_ = previous.Close()
	w.file = file
	w.bytes = 0
}
