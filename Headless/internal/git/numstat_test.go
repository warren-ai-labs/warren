package git

import "testing"

func TestParseNumstat(t *testing.T) {
	block := "3\t0\ta.txt\x00" +
		"3\t0\tb.txt\x00" +
		"-\t-\tbin.dat\x00" +
		"0\t7\told.txt\x00" +
		"2\t0\tnew.txt\x00"
	got := parseNumstat(block)
	if len(got) != 5 {
		t.Fatalf("len = %d, want 5", len(got))
	}
	if got["a.txt"] != (LineCount{Added: 3}) {
		t.Errorf("a.txt = %+v, want {3 0}", got["a.txt"])
	}
	if got["b.txt"] != (LineCount{Added: 3}) {
		t.Errorf("b.txt = %+v, want {3 0}", got["b.txt"])
	}
	if got["bin.dat"] != (LineCount{}) {
		t.Errorf("bin.dat = %+v, want {0 0}", got["bin.dat"])
	}
	if got["old.txt"] != (LineCount{Deleted: 7}) {
		t.Errorf("old.txt = %+v, want {0 7}", got["old.txt"])
	}
	if got["new.txt"] != (LineCount{Added: 2}) {
		t.Errorf("new.txt = %+v, want {2 0}", got["new.txt"])
	}
}

func TestParseNumstatRenameForms(t *testing.T) {
	// -z form: "add\tdelete\t" then old and new path tokens.
	got := parseNumstat("5\t9\t\x00original.txt\x00renamed.txt\x00")
	if len(got) != 1 {
		t.Fatalf("len = %d, want 1", len(got))
	}
	if got["renamed.txt"] != (LineCount{Added: 5, Deleted: 9}) {
		t.Errorf("renamed.txt = %+v, want {5 9}", got["renamed.txt"])
	}
	// Plain form: "add\tdelete\told => new".
	got = parseNumstat("5\t9\toriginal.txt => renamed.txt\n")
	if got["renamed.txt"] != (LineCount{Added: 5, Deleted: 9}) {
		t.Errorf("renamed.txt = %+v, want {5 9}", got["renamed.txt"])
	}
}

func TestParseNumstatEmpty(t *testing.T) {
	if got := parseNumstat(""); len(got) != 0 {
		t.Fatalf("len = %d, want 0", len(got))
	}
}
