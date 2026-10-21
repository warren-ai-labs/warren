package git

import (
	"context"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// Fetch downloads the latest refs from origin so panel comparisons against
// origin/main reflect what is actually on the remote. It never touches the
// working tree, so it is safe during rebases and merges.
func Fetch(ctx context.Context, dir string) error {
	_, err := run(ctx, dir, "fetch", "origin")
	return err
}

// MainBranch returns the remote ref of the repository's main line
// (origin/main, falling back to origin/master), or "" when the remote has
// neither.
func MainBranch(ctx context.Context, dir string) string {
	for _, ref := range []string{"refs/remotes/origin/main", "refs/remotes/origin/master"} {
		if _, err := run(ctx, dir, "rev-parse", "--verify", "--quiet", ref); err == nil {
			return ref
		}
	}
	return ""
}

// IsMerged reports whether HEAD is an ancestor of ref, i.e. every commit on
// the current branch is already reachable from the main line.
func IsMerged(ctx context.Context, dir, ref string) (bool, error) {
	output, err := run(ctx, dir, "rev-list", "--count", ref+"..HEAD")
	if err != nil {
		return false, err
	}
	count, err := strconv.Atoi(strings.TrimSpace(output))
	if err != nil {
		return false, err
	}
	return count == 0, nil
}

// OperationState reports an in-progress git operation by inspecting the
// per-worktree git directory, or "" when the workspace is idle.
func OperationState(ctx context.Context, dir string) string {
	output, err := run(ctx, dir, "rev-parse", "--absolute-git-dir")
	if err != nil {
		return ""
	}
	gitDir := strings.TrimSpace(output)
	for _, marker := range []struct {
		path string
		name string
	}{
		{"rebase-merge", "rebase"},
		{"rebase-apply", "rebase"},
		{"MERGE_HEAD", "merge"},
		{"CHERRY_PICK_HEAD", "cherry-pick"},
		{"REVERT_HEAD", "revert"},
	} {
		if _, err := os.Stat(filepath.Join(gitDir, marker.path)); err == nil {
			return marker.name
		}
	}
	return ""
}
