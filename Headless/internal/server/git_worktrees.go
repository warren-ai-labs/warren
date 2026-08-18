package server

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/store"
)

type gitWorktree struct {
	Path     string
	Branch   string
	Detached bool
	Locked   bool
	Prunable bool
	Bare     bool
}

func listGitWorktrees(repository string) ([]gitWorktree, error) {
	output, err := exec.Command(
		"git", "-C", repository, "worktree", "list", "--porcelain", "-z",
	).Output()
	if err != nil {
		return nil, fmt.Errorf("git worktree list: %w", err)
	}
	return parseGitWorktreesPorcelain(output)
}

func parseGitWorktreesPorcelain(output []byte) ([]gitWorktree, error) {
	worktrees := make([]gitWorktree, 0)
	var current *gitWorktree
	flush := func() {
		if current == nil {
			return
		}
		worktrees = append(worktrees, *current)
		current = nil
	}

	for _, token := range strings.Split(string(output), "\x00") {
		if token == "" {
			continue
		}
		key, value, hasValue := strings.Cut(token, " ")
		if key == "worktree" {
			flush()
			if !hasValue || value == "" {
				return nil, errors.New("git worktree record is missing its path")
			}
			current = &gitWorktree{Path: value}
			continue
		}
		if current == nil {
			return nil, fmt.Errorf("git worktree attribute %q appears before a worktree path", token)
		}
		switch key {
		case "branch":
			current.Branch = strings.TrimPrefix(value, "refs/heads/")
		case "detached":
			current.Detached = true
		case "locked":
			current.Locked = true
		case "prunable":
			current.Prunable = true
		case "bare":
			current.Bare = true
		}
	}
	flush()
	if len(worktrees) == 0 {
		return nil, errors.New("git worktree record is missing its path")
	}
	return worktrees, nil
}

func workspacesForGitWorktrees(
	projectID string,
	createdAt time.Time,
	worktrees []gitWorktree,
	stat func(string) (os.FileInfo, error),
) ([]api.Workspace, error) {
	if len(worktrees) == 0 {
		return nil, errors.New("Git repository has no worktrees")
	}
	if worktrees[0].Bare {
		return nil, errors.New("bare Git repositories are not supported")
	}

	result := make([]api.Workspace, 0, len(worktrees))
	paths := make([]string, 0, len(worktrees))
	for index, worktree := range worktrees {
		if worktree.Bare {
			continue
		}
		if worktree.Prunable {
			if index == 0 {
				return nil, errors.New("main Git worktree is prunable")
			}
			continue
		}

		path := filepath.Clean(worktree.Path)
		info, err := stat(path)
		if err != nil {
			if index > 0 && os.IsNotExist(err) {
				continue
			}
			return nil, fmt.Errorf("inspect Git worktree %s: %w", path, err)
		}
		if !info.IsDir() {
			if index == 0 {
				return nil, fmt.Errorf("main Git worktree is not a directory: %s", path)
			}
			continue
		}

		duplicate := false
		for _, existing := range paths {
			if samePath(existing, path) {
				duplicate = true
				break
			}
		}
		if duplicate {
			continue
		}
		paths = append(paths, path)

		name := worktree.Branch
		if name == "" {
			name = filepath.Base(path)
		}
		kind := "worktree"
		if index == 0 {
			kind = "root"
		}
		result = append(result, api.Workspace{
			ID:        store.NewID(),
			ProjectID: projectID,
			Name:      name,
			Path:      path,
			Branch:    worktree.Branch,
			Kind:      kind,
			Order:     len(result),
			CreatedAt: createdAt,
		})
	}
	if len(result) == 0 || result[0].Kind != "root" {
		return nil, errors.New("Git repository has no valid main worktree")
	}
	return result, nil
}
