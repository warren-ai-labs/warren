package server

import (
	"reflect"
	"testing"
)

func TestParseGitWorktreesPorcelain(t *testing.T) {
	input := []byte("worktree /repo\x00HEAD abc\x00branch refs/heads/main\x00unknown future\x00\x00" +
		"worktree /repo-feature\x00HEAD def\x00branch refs/heads/feature/demo\x00locked reason\x00\x00" +
		"worktree /repo-detached\x00HEAD fed\x00detached\x00\x00" +
		"worktree /repo-stale\x00HEAD bad\x00prunable missing gitdir\x00\x00")

	got, err := parseGitWorktreesPorcelain(input)
	if err != nil {
		t.Fatal(err)
	}
	want := []gitWorktree{
		{Path: "/repo", Branch: "main"},
		{Path: "/repo-feature", Branch: "feature/demo", Locked: true},
		{Path: "/repo-detached", Detached: true},
		{Path: "/repo-stale", Prunable: true},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("parsed worktrees: got %#v want %#v", got, want)
	}
}

func TestParseGitWorktreesPorcelainRejectsAttributesBeforeWorktree(t *testing.T) {
	_, err := parseGitWorktreesPorcelain([]byte("HEAD abc\x00branch refs/heads/main\x00"))
	if err == nil {
		t.Fatal("expected malformed worktree error")
	}
}

func TestParseGitWorktreesPorcelainRejectsEmptyPath(t *testing.T) {
	_, err := parseGitWorktreesPorcelain([]byte("worktree \x00HEAD abc\x00"))
	if err == nil {
		t.Fatal("expected empty worktree path error")
	}
}
