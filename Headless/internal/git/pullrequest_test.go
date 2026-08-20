package git

import (
	"context"
	"errors"
	"strings"
	"testing"
)

func TestRemoteHostParsing(t *testing.T) {
	tests := []struct {
		remote string
		host   string
	}{
		{"git@github.com:abcdlsj/warren.git", "github.com"},
		{"https://github.com/abcdlsj/warren.git", "github.com"},
		{"ssh://git@github.com/abcdlsj/warren.git", "github.com"},
		{"git@gitlab.com:group/repo.git", "gitlab.com"},
		{"https://gitlab.bilibili.co/group/repo.git", "gitlab.bilibili.co"},
		{"git@git.bilibili.co:group/repo.git", "git.bilibili.co"},
		{"https://example.com/group/repo.git", "example.com"},
	}
	for _, test := range tests {
		if got := remoteHost(test.remote); got != test.host {
			t.Fatalf("remoteHost(%q) = %q, want %q", test.remote, got, test.host)
		}
	}
}

func TestPRHostSelectsCLIByRemote(t *testing.T) {
	dir := newRepository(t)
	if _, err := prHost(context.Background(), dir); err == nil {
		t.Fatal("prHost with no remote should fail")
	}
	gitForTest(t, dir, "remote", "add", "origin", "git@github.com:abcdlsj/warren.git")
	if host, err := prHost(context.Background(), dir); err != nil || host != "github" {
		t.Fatalf("prHost = %q, %v, want github", host, err)
	}
	gitForTest(t, dir, "remote", "set-url", "origin", "https://gitlab.bilibili.co/group/repo.git")
	if host, err := prHost(context.Background(), dir); err != nil || host != "gitlab" {
		t.Fatalf("prHost = %q, %v, want gitlab", host, err)
	}
	gitForTest(t, dir, "remote", "set-url", "origin", "git@git.bilibili.co:group/repo.git")
	if host, err := prHost(context.Background(), dir); err != nil || host != "gitlab" {
		t.Fatalf("prHost = %q, %v, want gitlab for git.bilibili.co", host, err)
	}
	gitForTest(t, dir, "remote", "set-url", "origin", "git@example.com:group/repo.git")
	if _, err := prHost(context.Background(), dir); err == nil || !strings.Contains(err.Error(), "unsupported git host") {
		t.Fatalf("prHost for unknown host = %v, want unsupported host error", err)
	}
}

func TestParseGitHubPullRequest(t *testing.T) {
	output := `{"number":42,"title":"Add PR panel","body":"Fixes things","state":"OPEN","isDraft":false,"url":"https://github.com/abcdlsj/warren/pull/42","author":{"login":"alice"},"baseRefName":"main","headRefName":"feature/x"}`
	pr, err := parseGitHubPullRequest(output)
	if err != nil {
		t.Fatal(err)
	}
	if pr.Number != 42 || pr.Title != "Add PR panel" || pr.Body != "Fixes things" {
		t.Fatalf("pr = %#v", pr)
	}
	if pr.State != "open" || pr.Author != "alice" || pr.Base != "main" || pr.Head != "feature/x" {
		t.Fatalf("pr = %#v", pr)
	}
}

func TestParseGitLabMergeRequest(t *testing.T) {
	output := `[{"iid":7,"title":"Add MR panel","description":"Fixes things","state":"opened","draft":true,"web_url":"https://gitlab.com/group/repo/-/merge_requests/7","author":{"username":"bob"},"source_branch":"feature/x","target_branch":"main"}]`
	pr, err := parseGitLabMergeRequest(output)
	if err != nil {
		t.Fatal(err)
	}
	if pr.Number != 7 || pr.Title != "Add MR panel" || !pr.Draft {
		t.Fatalf("pr = %#v", pr)
	}
	if pr.State != "open" || pr.Author != "bob" || pr.Base != "main" || pr.Head != "feature/x" {
		t.Fatalf("pr = %#v", pr)
	}
	if _, err := parseGitLabMergeRequest("[]"); !errors.Is(err, ErrNoPullRequest) {
		t.Fatalf("empty mr list = %v, want ErrNoPullRequest", err)
	}
}

func TestMainBranchShort(t *testing.T) {
	dir := newRepository(t)
	gitForTest(t, dir, "update-ref", "refs/remotes/origin/master", "HEAD")
	if got := MainBranchShort(context.Background(), dir); got != "master" {
		t.Fatalf("MainBranchShort = %q, want master", got)
	}
	gitForTest(t, dir, "update-ref", "refs/remotes/origin/main", "HEAD")
	if got := MainBranchShort(context.Background(), dir); got != "main" {
		t.Fatalf("MainBranchShort = %q, want main", got)
	}
}
