package git

import (
	"testing"
	"time"
)

const logFixture = "COMMIT\x00f0ed40cd607e2198521a680f37c9808ea8f4d908\x00f0ed40c\x00third\x00t\x00t@t\x002026-08-19T16:30:31+08:00\x00\n\n" +
	"A\ta b.txt\n" +
	"M\tb.txt\n" +
	"R100\tsub/c.txt\tsub/d.txt\n" +
	"COMMIT\x0065e778d309c453193d6a6a35b5e49e00ce202b0f\x0065e778d\x00init\x00t\x00t@t\x002026-08-19T16:30:13+08:00\x00\n\n" +
	"A\ta.txt\n" +
	"A\tsub/c.txt\n"

func TestParseLog(t *testing.T) {
	commits := parseLog(logFixture)
	if len(commits) != 2 {
		t.Fatalf("commits = %d, want 2", len(commits))
	}
	first := commits[0]
	if first.Hash != "f0ed40cd607e2198521a680f37c9808ea8f4d908" || first.Short != "f0ed40c" {
		t.Fatalf("hash/short = %q/%q", first.Hash, first.Short)
	}
	if first.Subject != "third" || first.Author != "t" || first.Email != "t@t" {
		t.Fatalf("subject/author/email = %q/%q/%q", first.Subject, first.Author, first.Email)
	}
	wantTime, _ := time.Parse(time.RFC3339, "2026-08-19T16:30:31+08:00")
	if !first.Time.Equal(wantTime) {
		t.Fatalf("time = %v, want %v", first.Time, wantTime)
	}
	wantFiles := []FileChange{
		{Path: "a b.txt", Status: "A"},
		{Path: "b.txt", Status: "M"},
		{Path: "sub/d.txt", Status: "R", RenameFrom: "sub/c.txt"},
	}
	if len(first.Files) != len(wantFiles) {
		t.Fatalf("files = %#v, want %#v", first.Files, wantFiles)
	}
	for i := range wantFiles {
		if first.Files[i] != wantFiles[i] {
			t.Fatalf("files[%d] = %#v, want %#v", i, first.Files[i], wantFiles[i])
		}
	}
	if commits[1].Subject != "init" || len(commits[1].Files) != 2 {
		t.Fatalf("second commit = %#v", commits[1])
	}
}

func TestParseLogNumstat(t *testing.T) {
	output := "COMMIT\x00abc123\x00\x00\n3\t0\ta.txt\x002\t1\tb.txt\x00" +
		"COMMIT\x00def456\x00\x00\n1\t0\tnew.txt\x00"
	got := parseLogNumstat(output)
	if len(got) != 2 {
		t.Fatalf("len = %d, want 2", len(got))
	}
	if got["abc123"]["a.txt"] != (LineCount{Added: 3}) {
		t.Errorf("abc123 a.txt = %+v, want {3 0}", got["abc123"]["a.txt"])
	}
	if got["abc123"]["b.txt"] != (LineCount{Added: 2, Deleted: 1}) {
		t.Errorf("abc123 b.txt = %+v, want {2 1}", got["abc123"]["b.txt"])
	}
	if got["def456"]["new.txt"] != (LineCount{Added: 1}) {
		t.Errorf("def456 new.txt = %+v, want {1 0}", got["def456"]["new.txt"])
	}
}

func TestMergeLogCounts(t *testing.T) {
	commits := []Commit{
		{Hash: "abc123", Files: []FileChange{
			{Path: "a.txt", Status: "M"},
			{Path: "new.txt", Status: "A", RenameFrom: "old.txt"},
		}},
	}
	counts := map[string]map[string]LineCount{
		"abc123": {
			"a.txt":   {Added: 3},
			"new.txt": {Added: 5},
			"old.txt": {Deleted: 2},
		},
	}
	mergeLogCounts(commits, counts)
	files := commits[0].Files
	if files[0].Added != 3 || files[0].Deleted != 0 {
		t.Errorf("a.txt = %+v, want {3 0}", files[0])
	}
	if files[1].Added != 5 || files[1].Deleted != 2 {
		t.Errorf("new.txt = %+v, want {5 2} (old deletions merged)", files[1])
	}
}
