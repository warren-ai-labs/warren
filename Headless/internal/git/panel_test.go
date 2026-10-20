package git

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestMainBranchFallsBackToMaster(t *testing.T) {
	dir := newRepository(t)
	if got := MainBranch(context.Background(), dir); got != "" {
		t.Fatalf("MainBranch with no remote refs = %q, want empty", got)
	}
	gitForTest(t, dir, "update-ref", "refs/remotes/origin/master", "HEAD")
	if got := MainBranch(context.Background(), dir); got != "refs/remotes/origin/master" {
		t.Fatalf("MainBranch = %q, want origin/master", got)
	}
	gitForTest(t, dir, "update-ref", "refs/remotes/origin/main", "HEAD")
	if got := MainBranch(context.Background(), dir); got != "refs/remotes/origin/main" {
		t.Fatalf("MainBranch = %q, want origin/main", got)
	}
}

func TestMergedIntoTargetAndLogRange(t *testing.T) {
	dir := newRepository(t)
	base := strings.TrimSpace(gitForTest(t, dir, "rev-parse", "main"))
	gitForTest(t, dir, "checkout", "-b", "dev")
	if err := os.WriteFile(filepath.Join(dir, "b.txt"), []byte("b\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	gitForTest(t, dir, "add", "-A")
	gitForTest(t, dir, "commit", "-m", "dev change")
	gitForTest(t, dir, "update-ref", "refs/remotes/origin/main", "main")

	mainRef := "refs/remotes/origin/main"
	if merged, known := MergedIntoTarget(context.Background(), dir, mainRef, "dev", base); !known || merged {
		t.Fatalf("MergedIntoTarget = %v, %v, want known unmerged", merged, known)
	}
	unmerged, err := LogRange(context.Background(), dir, mainRef)
	if err != nil {
		t.Fatal(err)
	}
	if len(unmerged) != 1 || unmerged[0].Subject != "dev change" {
		t.Fatalf("unmerged = %#v, want only the dev commit", unmerged)
	}

	gitForTest(t, dir, "checkout", "main")
	gitForTest(t, dir, "merge", "--ff-only", "dev")
	gitForTest(t, dir, "checkout", "dev")
	gitForTest(t, dir, "update-ref", "refs/remotes/origin/main", "main")
	if merged, known := MergedIntoTarget(context.Background(), dir, mainRef, "dev", base); !known || !merged {
		t.Fatalf("MergedIntoTarget after merge = %v, %v, want known merged", merged, known)
	}
	// Without a recorded base the branch matches the target tip exactly, and
	// an unknown base is never trusted as merged.
	if merged, known := MergedIntoTarget(context.Background(), dir, mainRef, "dev", ""); !known || merged {
		t.Fatalf("MergedIntoTarget without base = %v, %v, want known unmerged", merged, known)
	}
	unmerged, err = LogRange(context.Background(), dir, mainRef)
	if err != nil {
		t.Fatal(err)
	}
	if len(unmerged) != 0 {
		t.Fatalf("unmerged after merge = %#v, want none", unmerged)
	}
	// A known base keeps the branch's own commit listed even after the merge,
	// because the base defines the branch's work rather than the merge state.
	own, err := LogRangeFrom(context.Background(), dir, mainRef, base)
	if err != nil {
		t.Fatal(err)
	}
	if len(own) != 1 || own[0].Subject != "dev change" {
		t.Fatalf("base range = %#v, want only the dev commit", own)
	}
}

func TestMergedIntoTargetRequiresOwnCommits(t *testing.T) {
	dir := newRepository(t)
	gitForTest(t, dir, "commit", "--allow-empty", "-m", "second")
	current := strings.TrimSpace(gitForTest(t, dir, "rev-parse", "main"))
	previous := strings.TrimSpace(gitForTest(t, dir, "rev-parse", "main~1"))

	// A fresh branch sits on the default tip: no commits of its own.
	gitForTest(t, dir, "branch", "fresh", "main")
	if merged, known := MergedIntoTarget(context.Background(), dir, "main", "fresh", current); !known || merged {
		t.Fatalf("fresh branch = %v, %v, want known unmerged", merged, known)
	}
	// Without a recorded base the exact tip match must still be unmerged.
	if merged, known := MergedIntoTarget(context.Background(), dir, "main", "fresh", ""); !known || merged {
		t.Fatalf("fresh branch without base = %v, %v, want known unmerged", merged, known)
	}

	// A branch created from an older default commit also has no own work.
	gitForTest(t, dir, "branch", "older", previous)
	if merged, known := MergedIntoTarget(context.Background(), dir, "main", "older", previous); !known || merged {
		t.Fatalf("older branch = %v, %v, want known unmerged", merged, known)
	}
}

func TestMergedIntoTargetRecognizesMergeShapes(t *testing.T) {
	dir := newRepository(t)
	write := func(name string) {
		t.Helper()
		if err := os.WriteFile(filepath.Join(dir, name), []byte(name+"\n"), 0o644); err != nil {
			t.Fatal(err)
		}
		gitForTest(t, dir, "add", "-A")
	}
	commitOn := func(branch, name string) string {
		t.Helper()
		base := strings.TrimSpace(gitForTest(t, dir, "rev-parse", "main"))
		gitForTest(t, dir, "checkout", "-b", branch, base)
		write(name)
		gitForTest(t, dir, "commit", "-m", branch+" change")
		gitForTest(t, dir, "checkout", "main")
		return base
	}

	ffBase := commitOn("feature/ff", "ff.txt")
	gitForTest(t, dir, "merge", "--ff-only", "feature/ff")

	mergeCommitBase := commitOn("feature/merge-commit", "merge-commit.txt")
	gitForTest(t, dir, "merge", "--no-ff", "feature/merge-commit", "-m", "merge feature/merge-commit")

	squashBase := commitOn("feature/squash", "squash.txt")
	gitForTest(t, dir, "merge", "--squash", "feature/squash")
	gitForTest(t, dir, "commit", "-m", "squash merge feature/squash")

	aheadBase := commitOn("feature/ahead", "ahead.txt")

	cases := []struct {
		branch string
		base   string
		merged bool
	}{
		{"feature/ff", ffBase, true},
		{"feature/merge-commit", mergeCommitBase, true},
		{"feature/squash", squashBase, true},
		{"feature/ahead", aheadBase, false},
	}
	for _, value := range cases {
		merged, known := MergedIntoTarget(context.Background(), dir, "main", value.branch, value.base)
		if !known || merged != value.merged {
			t.Errorf("%s = %v, %v, want known %v", value.branch, merged, known, value.merged)
		}
	}
}

func TestBranchBaseReadsCreationReflog(t *testing.T) {
	dir := newRepository(t)
	previous := strings.TrimSpace(gitForTest(t, dir, "rev-parse", "main"))
	gitForTest(t, dir, "commit", "--allow-empty", "-m", "second")

	gitForTest(t, dir, "branch", "imported", previous)
	base, known := BranchBase(context.Background(), dir, "imported")
	if !known || base != previous {
		t.Fatalf("BranchBase = %q, %v, want %q", base, known, previous)
	}

	// A branch created without a reflog has no recorded creation point.
	gitForTest(t, dir, "config", "core.logAllRefUpdates", "false")
	gitForTest(t, dir, "update-ref", "refs/heads/unrecorded", previous)
	if base, known := BranchBase(context.Background(), dir, "unrecorded"); known {
		t.Fatalf("BranchBase without reflog = %q, want unknown", base)
	}
}

func TestOperationStateDetectsInProgressOperations(t *testing.T) {
	dir := newRepository(t)
	if got := OperationState(context.Background(), dir); got != "" {
		t.Fatalf("OperationState idle = %q, want empty", got)
	}
	gitDir := strings.TrimSpace(gitForTest(t, dir, "rev-parse", "--absolute-git-dir"))
	rebaseDir := filepath.Join(gitDir, "rebase-merge")
	if err := os.MkdirAll(filepath.Join(rebaseDir, "interactive"), 0o755); err != nil {
		t.Fatal(err)
	}
	if got := OperationState(context.Background(), dir); got != "rebase" {
		t.Fatalf("OperationState = %q, want rebase", got)
	}
}

func TestLogRangeIsBounded(t *testing.T) {
	dir := newRepository(t)
	gitForTest(t, dir, "update-ref", "refs/remotes/origin/main", "HEAD")
	for range unmergedLogLimit + 5 {
		gitForTest(t, dir, "commit", "--allow-empty", "-m", "unmerged")
	}
	commits, err := LogRange(context.Background(), dir, "refs/remotes/origin/main")
	if err != nil {
		t.Fatal(err)
	}
	if len(commits) != unmergedLogLimit {
		t.Fatalf("LogRange returned %d commits, want cap %d", len(commits), unmergedLogLimit)
	}
}
