package git

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os/exec"
	"strings"
	"sync"
	"time"
)

const (
	commandTimeout            = 60 * time.Second
	defaultCommandOutputLimit = 16 * 1024 * 1024
)

type limitedOutput struct {
	mu       sync.Mutex
	buffer   bytes.Buffer
	limit    int
	exceeded bool
	cancel   context.CancelFunc
}

func (w *limitedOutput) Write(value []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	remaining := w.limit - w.buffer.Len()
	if remaining > 0 {
		write := len(value)
		if write > remaining {
			write = remaining
		}
		_, _ = w.buffer.Write(value[:write])
	}
	if len(value) > remaining {
		w.exceeded = true
		w.cancel()
	}
	// Report the complete write while canceling the command. This prevents the
	// child from spending unbounded CPU and I/O producing output we will drop.
	return len(value), nil
}

func (w *limitedOutput) String() string {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.buffer.String()
}

func (w *limitedOutput) Exceeded() bool {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.exceeded
}

// Error carries the trimmed command output so the UI can show why an
// operation failed instead of a bare exit status.
type Error struct {
	Output string
	Err    error
}

func (e *Error) Error() string {
	if message := strings.TrimSpace(e.Output); message != "" {
		return message
	}
	return e.Err.Error()
}

func (e *Error) Unwrap() error { return e.Err }

func run(ctx context.Context, dir string, args ...string) (string, error) {
	output, exceeded, err := runGit(ctx, dir, args, false, defaultCommandOutputLimit)
	return requireCompleteOutput(output, exceeded, err, args, defaultCommandOutputLimit)
}

func runLimited(ctx context.Context, dir string, limit int, args ...string) (string, error) {
	output, exceeded, err := runGit(ctx, dir, args, false, limit)
	return requireCompleteOutput(output, exceeded, err, args, limit)
}

func runTruncated(ctx context.Context, dir string, limit int, args ...string) (string, bool, error) {
	return runGit(ctx, dir, args, false, limit)
}

// runAllowExit is like run but treats exit code 1 as success, which
// git diff --no-index uses to report that the compared paths differ.
func runAllowExit(ctx context.Context, dir string, args ...string) (string, error) {
	output, exceeded, err := runGit(ctx, dir, args, true, defaultCommandOutputLimit)
	return requireCompleteOutput(output, exceeded, err, args, defaultCommandOutputLimit)
}

func runAllowExitLimited(ctx context.Context, dir string, limit int, args ...string) (string, error) {
	output, exceeded, err := runGit(ctx, dir, args, true, limit)
	return requireCompleteOutput(output, exceeded, err, args, limit)
}

func runAllowExitTruncated(ctx context.Context, dir string, limit int, args ...string) (string, bool, error) {
	return runGit(ctx, dir, args, true, limit)
}

func requireCompleteOutput(output string, exceeded bool, err error, args []string, limit int) (string, error) {
	if exceeded {
		return "", fmt.Errorf("git %s output exceeds %d bytes", strings.Join(args, " "), limit)
	}
	return output, err
}

func runGit(ctx context.Context, dir string, args []string, allowExitOne bool, outputLimit int) (string, bool, error) {
	commandCtx, cancel := context.WithTimeout(ctx, commandTimeout)
	defer cancel()
	command := exec.CommandContext(commandCtx, "git", append([]string{"-C", dir}, args...)...)
	output := &limitedOutput{limit: outputLimit, cancel: cancel}
	command.Stdout = output
	command.Stderr = output
	err := command.Run()
	text := output.String()
	if output.Exceeded() {
		return text, true, nil
	}
	if err != nil {
		if commandCtx.Err() != nil {
			if errors.Is(commandCtx.Err(), context.DeadlineExceeded) {
				return "", false, fmt.Errorf("git %s timed out: %w", strings.Join(args, " "), commandCtx.Err())
			}
			return "", false, fmt.Errorf("git %s canceled: %w", strings.Join(args, " "), commandCtx.Err())
		}
		if allowExitOne {
			var exitErr *exec.ExitError
			if errors.As(err, &exitErr) && exitErr.ExitCode() == 1 {
				return text, false, nil
			}
		}
		return "", false, &Error{Output: text, Err: err}
	}
	return text, false, nil
}
