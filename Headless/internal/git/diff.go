package git

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// FileView is one file's full content and its unified diff, both keyed to
// the same version: the working tree, the index, or a specific commit.
type FileView struct {
	Content string
	Diff    string
}

// Show returns the full content of path at the selected version together
// with its unified diff. When commit is non-empty both are keyed to that
// commit; staged selects the index; otherwise the working tree is shown.
// Untracked files have no reference version, so the whole file is shown as
// new content. Deleted files report an empty content with their diff.
func Show(ctx context.Context, dir, path string, staged bool, commit string) (FileView, error) {
	if commit != "" {
		diff, err := run(ctx, dir, "show", "--format=", "--no-ext-diff", commit, "--", path)
		if err != nil {
			return FileView{}, err
		}
		return FileView{Content: showContent(ctx, dir, commit+":"+path), Diff: diff}, nil
	}
	if staged {
		diff, err := run(ctx, dir, "diff", "--cached", "--no-ext-diff", "--", path)
		if err != nil {
			return FileView{}, err
		}
		return FileView{Content: showContent(ctx, dir, ":"+path), Diff: diff}, nil
	}
	diff, err := unstagedDiff(ctx, dir, path)
	if err != nil {
		return FileView{}, err
	}
	return FileView{Content: worktreeContent(dir, path), Diff: diff}, nil
}

// showContent returns the file content at rev (e.g. "HEAD:path" or ":path"),
// or "" when the path does not exist there.
func showContent(ctx context.Context, dir, rev string) string {
	output, err := run(ctx, dir, "show", rev)
	if err != nil {
		return ""
	}
	return output
}

// unstagedDiff returns the working-tree diff of path, or a new-file diff for
// untracked files.
func unstagedDiff(ctx context.Context, dir, path string) (string, error) {
	output, err := run(ctx, dir, "diff", "--no-ext-diff", "--", path)
	if err != nil {
		return "", err
	}
	if strings.TrimSpace(output) != "" || tracked(ctx, dir, path) {
		return output, nil
	}
	return runAllowExit(ctx, dir, "diff", "--no-index", "--no-ext-diff", "--", "/dev/null", path)
}

// tracked reports whether git tracks path in the index.
func tracked(ctx context.Context, dir, path string) bool {
	_, err := run(ctx, dir, "ls-files", "--error-unmatch", "--", path)
	return err == nil
}

// worktreeContent reads path from the working tree, or "" when it is gone.
func worktreeContent(dir, path string) string {
	full, err := safePath(dir, path)
	if err != nil {
		return ""
	}
	content, err := os.ReadFile(full)
	if err != nil {
		return ""
	}
	return string(content)
}

// safePath joins path onto dir, rejecting paths that escape it.
func safePath(dir, path string) (string, error) {
	full := filepath.Join(dir, filepath.FromSlash(path))
	rel, err := filepath.Rel(dir, full)
	if err != nil {
		return "", err
	}
	if rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return "", fmt.Errorf("path escapes workspace: %s", path)
	}
	return full, nil
}
