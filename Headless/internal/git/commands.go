package git

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// CurrentBranch returns the checked-out branch name, or "HEAD" when detached.
// symbolic-ref works even on an unborn HEAD (a repository without commits).
func CurrentBranch(ctx context.Context, dir string) (string, error) {
	if output, err := run(ctx, dir, "symbolic-ref", "--quiet", "--short", "HEAD"); err == nil {
		return strings.TrimSpace(output), nil
	}
	output, err := run(ctx, dir, "rev-parse", "--abbrev-ref", "HEAD")
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(output), nil
}

// Checkout switches the workspace to branch, creating it first when create
// is true. Remote-only names (origin/...) create a local tracking branch.
func Checkout(ctx context.Context, dir, branch string, create bool) error {
	args := []string{"switch"}
	if create {
		args = append(args, "-c", branch)
	} else if localBranchExists(ctx, dir, branch) {
		// "--" keeps a branch named like a flag (e.g. "-f") from being
		// parsed as a git option, which could silently discard local changes.
		args = append(args, "--", branch)
	} else if index := strings.Index(branch, "/"); index > 0 && remoteBranchExists(ctx, dir, branch) {
		// Remote-tracking name (origin/feature/x): create a local branch that
		// tracks it, unless the local short name already exists.
		short := branch[index+1:]
		if localBranchExists(ctx, dir, short) {
			args = append(args, "--", short)
		} else {
			args = append(args, "-c", short, "--track", branch)
		}
	} else {
		// Unknown short name: rely on git switch DWIM for remote-only names.
		args = append(args, "--", branch)
	}
	_, err := run(ctx, dir, args...)
	return err
}

func localBranchExists(ctx context.Context, dir, branch string) bool {
	_, err := run(ctx, dir, "rev-parse", "--verify", "--quiet", "refs/heads/"+branch)
	return err == nil
}

func remoteBranchExists(ctx context.Context, dir, branch string) bool {
	_, err := run(ctx, dir, "rev-parse", "--verify", "--quiet", "refs/remotes/"+branch)
	return err == nil
}

// Pull updates the workspace with a conservative fast-forward-only merge.
func Pull(ctx context.Context, dir string) (string, error) {
	return run(ctx, dir, "pull", "--ff-only")
}

// Commit stages every change (tracked, staged, and untracked) and creates a
// commit with message, so a subsequent push always has something to upload.
func CommitAll(ctx context.Context, dir, message string) (string, error) {
	snapshot, err := captureIndex(ctx, dir)
	if err != nil {
		return "", err
	}
	if _, err := run(ctx, dir, "add", "-A"); err != nil {
		return "", err
	}
	output, err := run(ctx, dir, "commit", "-m", message)
	if err == nil {
		return output, nil
	}
	if restoreErr := snapshot.restore(); restoreErr != nil {
		return "", fmt.Errorf("commit failed: %w; restore index: %v", err, restoreErr)
	}
	return "", err
}

type indexSnapshot struct {
	path   string
	data   []byte
	mode   os.FileMode
	exists bool
}

func captureIndex(ctx context.Context, dir string) (indexSnapshot, error) {
	output, err := run(ctx, dir, "rev-parse", "--path-format=absolute", "--git-path", "index")
	if err != nil {
		return indexSnapshot{}, err
	}
	path := strings.TrimSpace(output)
	if !filepath.IsAbs(path) {
		path = filepath.Join(dir, path)
	}
	info, err := os.Stat(path)
	if os.IsNotExist(err) {
		return indexSnapshot{path: path}, nil
	}
	if err != nil {
		return indexSnapshot{}, err
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return indexSnapshot{}, err
	}
	return indexSnapshot{path: path, data: data, mode: info.Mode(), exists: true}, nil
}

func (s indexSnapshot) restore() error {
	if !s.exists {
		if err := os.Remove(s.path); err != nil && !os.IsNotExist(err) {
			return err
		}
		return nil
	}
	temporary, err := os.CreateTemp(filepath.Dir(s.path), ".warren-index-*")
	if err != nil {
		return err
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)
	if err := temporary.Chmod(s.mode.Perm()); err != nil {
		temporary.Close()
		return err
	}
	if _, err := temporary.Write(s.data); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Sync(); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	return os.Rename(temporaryPath, s.path)
}

// Push uploads the current branch, setting the upstream when the branch has
// none yet.
func Push(ctx context.Context, dir string) (string, error) {
	status, err := StatusFor(ctx, dir)
	if err != nil {
		return "", err
	}
	if status.Upstream == "" {
		return run(ctx, dir, "push", "-u", "origin", "HEAD")
	}
	return run(ctx, dir, "push")
}
