package server

import (
	"errors"
	"fmt"
	"os/exec"
	"strings"
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
