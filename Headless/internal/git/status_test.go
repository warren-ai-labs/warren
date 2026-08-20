package git

import "testing"

const statusFixture = "# branch.oid 65e778d309c453193d6a6a35b5e49e00ce202b0f\x00" +
	"# branch.head main\x00" +
	"# branch.upstream origin/main\x00" +
	"# branch.ab +2 -1\x00" +
	"# stash 1\x00" +
	"1 M. N... 100644 100644 100644 61780798228d17af2d34fce4cfbdf35556832472 b89df23defe5ae95cfb2ff7408d90afd689b8c43 b.txt\x00" +
	"1 .M N... 100644 100644 100644 61780798228d17af2d34fce4cfbdf35556832472 b89df23defe5ae95cfb2ff7408d90afd689b8c43 unstaged.txt\x00" +
	"2 R. N... 100644 100644 100644 f2ad6c76f0115a6ba5b00456a849810e7ec0af20 f2ad6c76f0115a6ba5b00456a849810e7ec0af20 R100 sub/d.txt\x00sub/c.txt\x00" +
	"? a b.txt\x00" +
	"? new.txt\x00"

func TestParseStatus(t *testing.T) {
	status := parseStatus(statusFixture)
	if status.Branch != "main" {
		t.Fatalf("branch = %q, want main", status.Branch)
	}
	if status.Upstream != "origin/main" {
		t.Fatalf("upstream = %q, want origin/main", status.Upstream)
	}
	if status.Ahead != 2 || status.Behind != 1 {
		t.Fatalf("ahead/behind = %d/%d, want 2/1", status.Ahead, status.Behind)
	}
	if status.Stash != 1 {
		t.Fatalf("stash = %d, want 1", status.Stash)
	}
	want := []Change{
		{Path: "b.txt", Status: "M", Staged: true},
		{Path: "unstaged.txt", Status: "M", Staged: false},
		{Path: "sub/d.txt", Status: "R", Staged: true, RenameFrom: "sub/c.txt"},
		{Path: "a b.txt", Status: "?"},
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

func TestParseStatusDetachedAndClean(t *testing.T) {
	status := parseStatus("# branch.oid abc\x00# branch.head (detached)\x00")
	if status.Branch != "" {
		t.Fatalf("branch = %q, want empty for detached HEAD", status.Branch)
	}
	if len(status.Changes) != 0 {
		t.Fatalf("changes = %#v, want none", status.Changes)
	}
}

func TestParseStatusUnmerged(t *testing.T) {
	status := parseStatus("u UU N... 100644 100644 100644 100644 100644 <h> <h> conflicted.txt\x00")
	want := []Change{{Path: "conflicted.txt", Status: "UU"}}
	if len(status.Changes) != len(want) {
		t.Fatalf("changes = %#v, want %#v", status.Changes, want)
	}
	for i := range want {
		if status.Changes[i] != want[i] {
			t.Fatalf("changes[%d] = %#v, want %#v", i, status.Changes[i], want[i])
		}
	}
}

func TestParseStatusStagedAndUnstagedSamePath(t *testing.T) {
	status := parseStatus("1 MM N... 100644 100644 100644 61780798228d17af2d34fce4cfbdf35556832472 b89df23defe5ae95cfb2ff7408d90afd689b8c43 same.txt\x00")
	want := []Change{
		{Path: "same.txt", Status: "M", Staged: true},
		{Path: "same.txt", Status: "M", Staged: false},
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

func TestParseStatusZeroAheadBehind(t *testing.T) {
	status := parseStatus("# branch.oid abc\x00# branch.head main\x00# branch.ab +0 -0\x00")
	if status.Ahead != 0 || status.Behind != 0 {
		t.Fatalf("ahead/behind = %d/%d, want 0/0", status.Ahead, status.Behind)
	}
}

func TestParseStatusNoUpstream(t *testing.T) {
	status := parseStatus("# branch.oid abc\x00# branch.head main\x00# branch.ab +1 -1\x00")
	if status.Upstream != "" {
		t.Fatalf("upstream = %q, want empty", status.Upstream)
	}
}
