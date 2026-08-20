package git

import "testing"

func TestParseBranches(t *testing.T) {
	list := parseBranches("main\nfeature/x\n\n", "origin/HEAD\norigin/main\norigin/feature/x\n")
	if len(list.Local) != 2 || list.Local[0] != "main" || list.Local[1] != "feature/x" {
		t.Fatalf("local = %#v", list.Local)
	}
	if len(list.Remote) != 2 || list.Remote[0] != "origin/main" || list.Remote[1] != "origin/feature/x" {
		t.Fatalf("remote = %#v", list.Remote)
	}
}

func TestParseBranchesDropsOnlyHead(t *testing.T) {
	list := parseBranches("", "origin/HEAD\n")
	if len(list.Local) != 0 || len(list.Remote) != 0 {
		t.Fatalf("list = %#v, want empty", list)
	}
}

func TestParseBranchesEmpty(t *testing.T) {
	list := parseBranches("", "")
	if len(list.Local) != 0 || len(list.Remote) != 0 {
		t.Fatalf("list = %#v, want empty", list)
	}
}
