package git

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestShowWorkingTree(t *testing.T) {
	dir := newRepository(t)
	if err := os.WriteFile(filepath.Join(dir, "a.txt"), []byte("b\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	view, err := Show(context.Background(), dir, "a.txt", false, "")
	if err != nil {
		t.Fatal(err)
	}
	if view.Content != "b\n" {
		t.Fatalf("content = %q, want working tree content", view.Content)
	}
	if !strings.Contains(view.Diff, "-a\n") || !strings.Contains(view.Diff, "+b\n") {
		t.Fatalf("diff = %q, want a -> b change", view.Diff)
	}
}

func TestShowStaged(t *testing.T) {
	dir := newRepository(t)
	if err := os.WriteFile(filepath.Join(dir, "a.txt"), []byte("b\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	gitForTest(t, dir, "add", "a.txt")
	view, err := Show(context.Background(), dir, "a.txt", true, "")
	if err != nil {
		t.Fatal(err)
	}
	if view.Content != "b\n" {
		t.Fatalf("content = %q, want index content", view.Content)
	}
	if !strings.Contains(view.Diff, "-a\n") || !strings.Contains(view.Diff, "+b\n") {
		t.Fatalf("staged diff = %q, want a -> b change", view.Diff)
	}
}

func TestShowStagedFileHasNoUnstagedDiff(t *testing.T) {
	dir := newRepository(t)
	if err := os.WriteFile(filepath.Join(dir, "a.txt"), []byte("b\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	gitForTest(t, dir, "add", "a.txt")
	view, err := Show(context.Background(), dir, "a.txt", false, "")
	if err != nil {
		t.Fatal(err)
	}
	if view.Diff != "" {
		t.Fatalf("unstaged diff = %q, want empty for fully staged file", view.Diff)
	}
}

func TestShowUntracked(t *testing.T) {
	dir := newRepository(t)
	if err := os.WriteFile(filepath.Join(dir, "new.txt"), []byte("n\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	view, err := Show(context.Background(), dir, "new.txt", false, "")
	if err != nil {
		t.Fatal(err)
	}
	if view.Content != "n\n" {
		t.Fatalf("content = %q, want untracked file content", view.Content)
	}
	if !strings.Contains(view.Diff, "new file mode") || !strings.Contains(view.Diff, "+n") {
		t.Fatalf("untracked diff = %q, want new-file diff", view.Diff)
	}
}

func TestShowCommit(t *testing.T) {
	dir := newRepository(t)
	if err := os.WriteFile(filepath.Join(dir, "a.txt"), []byte("b\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	gitForTest(t, dir, "add", "a.txt")
	gitForTest(t, dir, "commit", "-m", "change a")
	view, err := Show(context.Background(), dir, "a.txt", false, "HEAD")
	if err != nil {
		t.Fatal(err)
	}
	if view.Content != "b\n" {
		t.Fatalf("content = %q, want commit content", view.Content)
	}
	if !strings.Contains(view.Diff, "-a\n") || !strings.Contains(view.Diff, "+b\n") {
		t.Fatalf("commit diff = %q, want a -> b change", view.Diff)
	}
}

func TestShowDeletedFile(t *testing.T) {
	dir := newRepository(t)
	if err := os.Remove(filepath.Join(dir, "a.txt")); err != nil {
		t.Fatal(err)
	}
	view, err := Show(context.Background(), dir, "a.txt", false, "")
	if err != nil {
		t.Fatal(err)
	}
	if view.Content != "" {
		t.Fatalf("content = %q, want empty for deleted file", view.Content)
	}
	if !strings.Contains(view.Diff, "-a\n") {
		t.Fatalf("diff = %q, want deletion", view.Diff)
	}
}

func TestShowRejectsEscapingPath(t *testing.T) {
	dir := newRepository(t)
	for _, path := range []string{"../../etc/passwd", "../outside.txt"} {
		if _, err := Show(context.Background(), dir, path, false, ""); err == nil {
			t.Fatalf("Show(%q) = nil error, want rejection", path)
		}
	}
}
