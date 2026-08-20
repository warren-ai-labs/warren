package git

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

const maxFileViewBytes = 16 * 1024 * 1024

// FileView is one file's full content and its unified diff, both keyed to
// the same version: the working tree, the index, or a specific commit.
type FileView struct {
	Content          string
	Diff             string
	ContentTruncated bool
	DiffTruncated    bool
}

// Show returns the full content of path at the selected version together
// with its unified diff. When commit is non-empty both are keyed to that
// commit; staged selects the index; otherwise the working tree is shown.
// Untracked files have no reference version, so the whole file is shown as
// new content. Deleted files report an empty content with their diff.
func Show(ctx context.Context, dir, path string, staged bool, commit string) (FileView, error) {
	if commit != "" {
		resolved, err := resolveCommit(ctx, dir, commit)
		if err != nil {
			return FileView{}, err
		}
		content, contentTruncated, err := showContent(ctx, dir, resolved+":"+path)
		if err != nil {
			return FileView{}, err
		}
		diff, diffTruncated, err := runTruncated(ctx, dir, maxFileViewBytes, "show", "--format=", "--no-ext-diff", "--end-of-options", resolved, "--", path)
		if err != nil {
			return FileView{}, err
		}
		return FileView{
			Content: content, Diff: completeTextPrefix(diff, diffTruncated),
			ContentTruncated: contentTruncated, DiffTruncated: diffTruncated,
		}, nil
	}
	if staged {
		content, contentTruncated, err := showContent(ctx, dir, ":"+path)
		if err != nil {
			return FileView{}, err
		}
		diff, diffTruncated, err := runTruncated(ctx, dir, maxFileViewBytes, "diff", "--cached", "--no-ext-diff", "--", path)
		if err != nil {
			return FileView{}, err
		}
		return FileView{
			Content: content, Diff: completeTextPrefix(diff, diffTruncated),
			ContentTruncated: contentTruncated, DiffTruncated: diffTruncated,
		}, nil
	}
	content, contentTruncated, err := worktreeContent(dir, path)
	if err != nil {
		return FileView{}, err
	}
	diff, diffTruncated, err := unstagedDiff(ctx, dir, path)
	if err != nil {
		return FileView{}, err
	}
	return FileView{
		Content: content, Diff: completeTextPrefix(diff, diffTruncated),
		ContentTruncated: contentTruncated, DiffTruncated: diffTruncated,
	}, nil
}

func resolveCommit(ctx context.Context, dir, commit string) (string, error) {
	output, err := runLimited(ctx, dir, 256, "rev-parse", "--verify", "--quiet", "--end-of-options", commit+"^{commit}")
	if err != nil {
		return "", fmt.Errorf("invalid commit %q: %w", commit, err)
	}
	return strings.TrimSpace(output), nil
}

// showContent returns the bounded file content at rev (e.g. "HEAD:path" or
// ":path"), or "" when the path does not exist there.
func showContent(ctx context.Context, dir, rev string) (string, bool, error) {
	sizeText, err := runLimited(ctx, dir, 64, "cat-file", "-s", "--end-of-options", rev)
	if err != nil {
		return "", false, nil
	}
	size, err := strconv.ParseInt(strings.TrimSpace(sizeText), 10, 64)
	if err != nil {
		return "", false, fmt.Errorf("read git object size: %w", err)
	}
	content, truncated, err := runTruncated(ctx, dir, maxFileViewBytes, "show", "--no-ext-diff", "--end-of-options", rev)
	if err != nil {
		return "", false, err
	}
	return strings.ToValidUTF8(content, ""), truncated || size > maxFileViewBytes, nil
}

// unstagedDiff returns the working-tree diff of path, or a new-file diff for
// untracked files.
func unstagedDiff(ctx context.Context, dir, path string) (string, bool, error) {
	output, truncated, err := runTruncated(ctx, dir, maxFileViewBytes, "diff", "--no-ext-diff", "--", path)
	if err != nil {
		return "", false, err
	}
	if truncated || strings.TrimSpace(output) != "" || tracked(ctx, dir, path) {
		return output, truncated, nil
	}
	return runAllowExitTruncated(ctx, dir, maxFileViewBytes, "diff", "--no-index", "--no-ext-diff", "--", "/dev/null", path)
}

// tracked reports whether git tracks path in the index.
func tracked(ctx context.Context, dir, path string) bool {
	_, err := run(ctx, dir, "ls-files", "--error-unmatch", "--", path)
	return err == nil
}

// worktreeContent reads path from the working tree, or "" when it is gone.
func worktreeContent(dir, path string) (string, bool, error) {
	root, err := os.OpenRoot(dir)
	if err != nil {
		return "", false, err
	}
	defer root.Close()
	name := filepath.FromSlash(path)
	info, err := root.Lstat(name)
	if err != nil {
		if os.IsNotExist(err) {
			return "", false, nil
		}
		return "", false, err
	}
	if info.Mode()&os.ModeSymlink != 0 {
		target, err := root.Readlink(name)
		if err != nil {
			return "", false, err
		}
		return target, false, nil
	}
	file, err := root.Open(name)
	if err != nil {
		return "", false, err
	}
	defer file.Close()
	content, err := io.ReadAll(io.LimitReader(file, maxFileViewBytes+1))
	if err != nil {
		return "", false, err
	}
	truncated := len(content) > maxFileViewBytes || info.Size() > maxFileViewBytes
	if len(content) > maxFileViewBytes {
		content = content[:maxFileViewBytes]
	}
	return strings.ToValidUTF8(string(content), ""), truncated, nil
}

func completeTextPrefix(value string, truncated bool) string {
	value = strings.ToValidUTF8(value, "")
	if !truncated {
		return value
	}
	if index := strings.LastIndexByte(value, '\n'); index >= 0 {
		return value[:index+1]
	}
	return ""
}
