package git

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func gitForTest(t *testing.T, dir string, args ...string) string {
	t.Helper()
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git binary not available")
	}
	command := exec.Command("git", append([]string{"-C", dir}, args...)...)
	output, err := command.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v: %s: %v", args, output, err)
	}
	return string(output)
}

func newRepository(t *testing.T) string {
	t.Helper()
	dir := filepath.Join(t.TempDir(), "repository")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	gitForTest(t, dir, "init", "--quiet", "-b", "main")
	gitForTest(t, dir, "config", "user.email", "test@example.com")
	gitForTest(t, dir, "config", "user.name", "Test")
	if err := os.WriteFile(filepath.Join(dir, "a.txt"), []byte("a\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	gitForTest(t, dir, "add", "-A")
	gitForTest(t, dir, "commit", "-m", "init")
	return dir
}

func TestStatusForReportsCleanTree(t *testing.T) {
	dir := newRepository(t)
	status, err := StatusFor(context.Background(), dir)
	if err != nil {
		t.Fatal(err)
	}
	if status.Branch != "main" {
		t.Fatalf("branch = %q, want main", status.Branch)
	}
	if len(status.Changes) != 0 {
		t.Fatalf("changes = %#v, want none", status.Changes)
	}
}

func TestStatusForReportsUntrackedAndModified(t *testing.T) {
	dir := newRepository(t)
	if err := os.WriteFile(filepath.Join(dir, "a.txt"), []byte("b\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "new.txt"), []byte("n\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	status, err := StatusFor(context.Background(), dir)
	if err != nil {
		t.Fatal(err)
	}
	want := []Change{
		{Path: "a.txt", Status: "M", Added: 1, Deleted: 1},
		{Path: "new.txt", Status: "?"},
	}
	if len(status.Changes) != len(want) {
		t.Fatalf("changes = %#v, want %#v", status.Changes, want)
	}
	for i := range want {
		if status.Changes[i] != want[i] {
			t.Fatalf("changes[%d] = %#v, want %#v", i, status.Changes[i], want[i])
		}
	}
}

func TestLogAndBranchesAndCheckout(t *testing.T) {
	dir := newRepository(t)
	gitForTest(t, dir, "branch", "dev")
	gitForTest(t, dir, "checkout", "-q", "dev")
	if err := os.WriteFile(filepath.Join(dir, "dev.txt"), []byte("d\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	gitForTest(t, dir, "add", "-A")
	gitForTest(t, dir, "commit", "-m", "dev commit")

	commits, err := Log(context.Background(), dir, 10)
	if err != nil {
		t.Fatal(err)
	}
	// The init commit is reachable from main, so history is scoped to
	// commits unique to the current branch.
	if len(commits) != 1 {
		t.Fatalf("commits = %d, want 1", len(commits))
	}
	if commits[0].Subject != "dev commit" || len(commits[0].Files) != 1 ||
		commits[0].Files[0] != (FileChange{Path: "dev.txt", Status: "A", Added: 1}) {
		t.Fatalf("latest commit = %#v", commits[0])
	}

	branches, err := Branches(context.Background(), dir)
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, name := range branches.Local {
		if name == "dev" {
			found = true
		}
	}
	if !found {
		t.Fatalf("local branches = %#v, want dev", branches.Local)
	}

	if err := Checkout(context.Background(), dir, "main", false); err != nil {
		t.Fatal(err)
	}
	status, err := StatusFor(context.Background(), dir)
	if err != nil {
		t.Fatal(err)
	}
	if status.Branch != "main" {
		t.Fatalf("branch after checkout = %q, want main", status.Branch)
	}

	if err := Checkout(context.Background(), dir, "feature/new", true); err != nil {
		t.Fatal(err)
	}
	status, err = StatusFor(context.Background(), dir)
	if err != nil {
		t.Fatal(err)
	}
	if status.Branch != "feature/new" {
		t.Fatalf("branch after create = %q, want feature/new", status.Branch)
	}
}

func TestLogScopesToCurrentBranch(t *testing.T) {
	dir := newRepository(t)
	gitForTest(t, dir, "checkout", "-q", "-b", "feature/x")
	if err := os.WriteFile(filepath.Join(dir, "x.txt"), []byte("x\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	gitForTest(t, dir, "add", "-A")
	gitForTest(t, dir, "commit", "-m", "feature commit")

	commits, err := Log(context.Background(), dir, 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(commits) != 1 || commits[0].Subject != "feature commit" {
		t.Fatalf("commits = %#v, want only the feature commit", commits)
	}

	if err := Checkout(context.Background(), dir, "main", false); err != nil {
		t.Fatal(err)
	}
	commits, err = Log(context.Background(), dir, 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(commits) != 0 {
		t.Fatalf("main commits = %#v, want none reachable from other branches", commits)
	}
}

func TestPullFailsFastWhenDiverged(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git binary not available")
	}
	// Build a local clone pair so pull has a real remote to talk to.
	upstream := newRepository(t)
	clone := filepath.Join(t.TempDir(), "clone")
	gitForTest(t, filepath.Dir(upstream), "clone", "-q", upstream, clone)
	gitForTest(t, clone, "config", "user.email", "test@example.com")
	gitForTest(t, clone, "config", "user.name", "Test")

	// Upstream advances; local clone diverges.
	gitForTest(t, upstream, "checkout", "-q", "main")
	if err := os.WriteFile(filepath.Join(upstream, "u.txt"), []byte("u\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	gitForTest(t, upstream, "add", "-A")
	gitForTest(t, upstream, "commit", "-m", "upstream commit")
	if err := os.WriteFile(filepath.Join(clone, "c.txt"), []byte("c\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	gitForTest(t, clone, "add", "-A")
	gitForTest(t, clone, "commit", "-m", "local commit")

	_, err := Pull(context.Background(), clone)
	if err == nil {
		t.Fatal("pull --ff-only should fail on diverged history")
	}
	if !strings.Contains(err.Error(), "Not possible to fast-forward") {
		t.Fatalf("pull error = %q, want fast-forward hint", err.Error())
	}
}

func TestCheckoutRemoteShortNameUsesDWIM(t *testing.T) {
	upstream := newRepository(t)
	gitForTest(t, upstream, "checkout", "-q", "-b", "feature/y")
	if err := os.WriteFile(filepath.Join(upstream, "y.txt"), []byte("y\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	gitForTest(t, upstream, "add", "-A")
	gitForTest(t, upstream, "commit", "-m", "y")
	gitForTest(t, upstream, "checkout", "-q", "main")

	clone := filepath.Join(t.TempDir(), "clone")
	gitForTest(t, filepath.Dir(upstream), "clone", "-q", upstream, clone)

	if err := Checkout(context.Background(), clone, "feature/y", false); err != nil {
		t.Fatal(err)
	}
	branch, err := CurrentBranch(context.Background(), clone)
	if err != nil {
		t.Fatal(err)
	}
	if branch != "feature/y" {
		t.Fatalf("branch = %q, want feature/y", branch)
	}
}

func TestStatusForReportsLineCounts(t *testing.T) {
	dir := newRepository(t)
	// staged: modify a.txt (2 lines added), stage a new file
	if err := os.WriteFile(filepath.Join(dir, "a.txt"), []byte("a\nb\nc\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "staged.txt"), []byte("1\n2\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	gitForTest(t, dir, "add", "-A")
	// unstaged: tweak a.txt further and add an untracked file
	if err := os.WriteFile(filepath.Join(dir, "a.txt"), []byte("a\nb\nc\nd\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "untracked.txt"), []byte("x\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	status, err := StatusFor(context.Background(), dir)
	if err != nil {
		t.Fatal(err)
	}
	var stagedA, unstagedA, staged, untracked Change
	for _, change := range status.Changes {
		switch change.Path {
		case "a.txt":
			if change.Staged {
				stagedA = change
			} else {
				unstagedA = change
			}
		case "staged.txt":
			staged = change
		case "untracked.txt":
			untracked = change
		}
	}
	if !stagedA.Staged || stagedA.Status != "M" || stagedA.Added != 2 || stagedA.Deleted != 0 {
		t.Errorf("staged a.txt = %#v, want staged M +2 -0", stagedA)
	}
	if unstagedA.Staged || unstagedA.Status != "M" || unstagedA.Added != 1 || unstagedA.Deleted != 0 {
		t.Errorf("unstaged a.txt = %#v, want unstaged M +1 -0", unstagedA)
	}
	if staged.Status != "A" || staged.Added != 2 {
		t.Errorf("staged.txt = %#v, want A +2", staged)
	}
	if untracked.Status != "?" || untracked.Added != 0 || untracked.Deleted != 0 {
		t.Errorf("untracked.txt = %#v, want ? no counts", untracked)
	}
}

func TestStatusForMergesRenameCounts(t *testing.T) {
	dir := newRepository(t)
	// Rename detected by git (high similarity), so porcelain v2 reports one
	// R record and numstat merges the old deletions into the new path.
	if err := os.WriteFile(filepath.Join(dir, "old.txt"), []byte("a\nb\nc\nd\ne\nf\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	gitForTest(t, dir, "add", "-A")
	gitForTest(t, dir, "commit", "-q", "-m", "seed")
	if err := os.WriteFile(filepath.Join(dir, "new.txt"), []byte("a\nb\nc\nd\ne\nf\nG\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(filepath.Join(dir, "old.txt")); err != nil {
		t.Fatal(err)
	}
	gitForTest(t, dir, "add", "-A")
	status, err := StatusFor(context.Background(), dir)
	if err != nil {
		t.Fatal(err)
	}
	for _, change := range status.Changes {
		if change.RenameFrom != "" {
			if change.Added != 1 || change.Deleted != 0 {
				t.Errorf("rename change = %#v, want +1 -0", change)
			}
			return
		}
	}
	t.Errorf("no rename change in %#v", status.Changes)
}

func TestCommitStagesAllChanges(t *testing.T) {
	dir := newRepository(t)
	if err := os.WriteFile(filepath.Join(dir, "a.txt"), []byte("b\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "new.txt"), []byte("n\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "staged.txt"), []byte("s\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	gitForTest(t, dir, "add", "staged.txt")

	if _, err := CommitAll(context.Background(), dir, "commit everything"); err != nil {
		t.Fatal(err)
	}
	status, err := StatusFor(context.Background(), dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(status.Changes) != 0 {
		t.Fatalf("changes after commit = %#v, want clean tree", status.Changes)
	}
	output := gitForTest(t, dir, "log", "-1", "--pretty=%s")
	if strings.TrimSpace(output) != "commit everything" {
		t.Fatalf("last commit subject = %q", strings.TrimSpace(output))
	}
}

func TestCommitFailsOnCleanTree(t *testing.T) {
	dir := newRepository(t)
	if _, err := CommitAll(context.Background(), dir, "nothing to commit"); err == nil {
		t.Fatal("CommitAll on a clean tree should fail")
	}
}
