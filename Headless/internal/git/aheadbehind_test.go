package git

import (
	"context"
	"testing"
)

func TestAheadBehind(t *testing.T) {
	dir := newRepository(t)
	gitForTest(t, dir, "update-ref", "refs/remotes/origin/main", "HEAD")
	gitForTest(t, dir, "commit", "--allow-empty", "-m", "local commit one")
	gitForTest(t, dir, "commit", "--allow-empty", "-m", "local commit two")

	ahead, behind, err := AheadBehind(context.Background(), dir, "refs/remotes/origin/main")
	if err != nil {
		t.Fatal(err)
	}
	if ahead != 2 || behind != 0 {
		t.Fatalf("ahead/behind = %d/%d, want 2/0", ahead, behind)
	}
}

func TestAheadBehindCountsBehind(t *testing.T) {
	dir := newRepository(t)
	gitForTest(t, dir, "commit", "--allow-empty", "-m", "second")
	gitForTest(t, dir, "update-ref", "refs/remotes/origin/main", "HEAD")
	gitForTest(t, dir, "reset", "--hard", "HEAD~1")

	ahead, behind, err := AheadBehind(context.Background(), dir, "refs/remotes/origin/main")
	if err != nil {
		t.Fatal(err)
	}
	if ahead != 0 || behind != 1 {
		t.Fatalf("ahead/behind = %d/%d, want 0/1", ahead, behind)
	}
}
