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

func TestShowRejectsCommitOptionInjection(t *testing.T) {
	dir := newRepository(t)
	target := filepath.Join(t.TempDir(), "must-not-change")
	if err := os.WriteFile(target, []byte("sentinel"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := Show(context.Background(), dir, "a.txt", false, "--output="+target); err == nil {
		t.Fatal("Show accepted a git option as a commit")
	}
	content, err := os.ReadFile(target)
	if err != nil {
		t.Fatal(err)
	}
	if string(content) != "sentinel" {
		t.Fatalf("target content = %q, want sentinel", content)
	}
}

func TestShowTruncatesOversizedWorkingTreeFile(t *testing.T) {
	dir := newRepository(t)
	path := filepath.Join(dir, "large.bin")
	file, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := file.Truncate(maxFileViewBytes + 1); err != nil {
		file.Close()
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}
	view, err := Show(context.Background(), dir, "large.bin", false, "")
	if err != nil {
		t.Fatal(err)
	}
	if !view.ContentTruncated {
		t.Fatal("oversized content was not marked as truncated")
	}
	if len(view.Content) != maxFileViewBytes {
		t.Fatalf("content length = %d, want %d", len(view.Content), maxFileViewBytes)
	}
}

func TestRunTruncatedReturnsBoundedPrefix(t *testing.T) {
	dir := newRepository(t)
	content := strings.Repeat("0123456789", 8)
	if err := os.WriteFile(filepath.Join(dir, "large.txt"), []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	gitForTest(t, dir, "add", "large.txt")
	gitForTest(t, dir, "commit", "-m", "add large file")
	output, truncated, err := runTruncated(context.Background(), dir, 16, "show", "HEAD:large.txt")
	if err != nil {
		t.Fatal(err)
	}
	if !truncated {
		t.Fatal("output was not marked as truncated")
	}
	if output != content[:16] {
		t.Fatalf("output = %q, want %q", output, content[:16])
	}
}

func TestShowDoesNotFollowWorkingTreeSymlink(t *testing.T) {
	dir := newRepository(t)
	outside := filepath.Join(t.TempDir(), "secret")
	if err := os.WriteFile(outside, []byte("private content"), 0o600); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(dir, "link")
	if err := os.Symlink(outside, link); err != nil {
		t.Skipf("symlink unavailable: %v", err)
	}
	view, err := Show(context.Background(), dir, "link", false, "")
	if err != nil {
		t.Fatal(err)
	}
	if view.Content != outside {
		t.Fatalf("symlink content = %q, want link target path", view.Content)
	}
	if strings.Contains(view.Content, "private content") {
		t.Fatal("Show followed a symlink outside the workspace")
	}
}

func TestShowDoesNotFollowParentSymlinkOutsideWorkspace(t *testing.T) {
	dir := newRepository(t)
	outside := t.TempDir()
	if err := os.WriteFile(filepath.Join(outside, "secret"), []byte("private content"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(dir, "escape")); err != nil {
		t.Skipf("symlink unavailable: %v", err)
	}
	view, err := Show(context.Background(), dir, "escape/secret", false, "")
	if err == nil {
		t.Fatalf("Show followed a parent symlink outside the workspace: %#v", view)
	}
	if strings.Contains(view.Content, "private content") {
		t.Fatal("Show returned content from outside the workspace")
	}
}
