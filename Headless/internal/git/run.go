package git

import (
	"context"
	"errors"
	"fmt"
	"os/exec"
	"strings"
	"time"
)

const commandTimeout = 60 * time.Second

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
	return runGit(ctx, dir, args, false)
}

// runAllowExit is like run but treats exit code 1 as success, which
// git diff --no-index uses to report that the compared paths differ.
func runAllowExit(ctx context.Context, dir string, args ...string) (string, error) {
	return runGit(ctx, dir, args, true)
}

func runGit(ctx context.Context, dir string, args []string, allowExitOne bool) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, commandTimeout)
	defer cancel()
	command := exec.CommandContext(ctx, "git", append([]string{"-C", dir}, args...)...)
	output, err := command.CombinedOutput()
	if err != nil {
		if ctx.Err() != nil {
			if errors.Is(ctx.Err(), context.DeadlineExceeded) {
				return "", fmt.Errorf("git %s timed out: %w", strings.Join(args, " "), ctx.Err())
			}
			return "", fmt.Errorf("git %s canceled: %w", strings.Join(args, " "), ctx.Err())
		}
		if allowExitOne {
			var exitErr *exec.ExitError
			if errors.As(err, &exitErr) && exitErr.ExitCode() == 1 {
				return string(output), nil
			}
		}
		return "", &Error{Output: string(output), Err: err}
	}
	return string(output), nil
}
