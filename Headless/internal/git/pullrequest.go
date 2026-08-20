package git

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os/exec"
	"strings"
)

// ErrNoPullRequest reports that the current branch has no hosted pull
// request (GitHub PR or GitLab MR) yet.
var ErrNoPullRequest = errors.New("no pull request found for branch")

// PullRequest is a hosted pull request for one branch, backed by either the
// GitHub CLI or the GitLab CLI depending on the origin remote.
type PullRequest struct {
	Number int
	Title  string
	Body   string
	State  string
	Draft  bool
	URL    string
	Author string
	Base   string
	Head   string
}

// PullRequestForBranch returns the pull request whose head is the current
// branch, or (nil, ErrNoPullRequest) when none exists yet.
func PullRequestForBranch(ctx context.Context, dir string) (*PullRequest, error) {
	host, err := prHost(ctx, dir)
	if err != nil {
		return nil, err
	}
	branch, err := CurrentBranch(ctx, dir)
	if err != nil || branch == "" || branch == "HEAD" {
		return nil, fmt.Errorf("a named branch is required to look up a pull request")
	}
	switch host {
	case "github":
		return gitHubPullRequest(ctx, dir, branch)
	case "gitlab":
		return gitLabMergeRequest(ctx, dir, branch)
	}
	return nil, fmt.Errorf("unsupported pull request host %q", host)
}

// CreatePullRequest pushes the current branch when needed and opens a pull
// request against the repository's main branch, returning the created
// request.
func CreatePullRequest(ctx context.Context, dir, title, body string) (*PullRequest, error) {
	host, err := prHost(ctx, dir)
	if err != nil {
		return nil, err
	}
	if strings.TrimSpace(title) == "" {
		return nil, fmt.Errorf("pull request title is required")
	}
	branch, err := CurrentBranch(ctx, dir)
	if err != nil || branch == "" || branch == "HEAD" {
		return nil, fmt.Errorf("a named branch is required to create a pull request")
	}
	base := MainBranchShort(ctx, dir)
	if base == "" {
		return nil, fmt.Errorf("no main branch found on origin")
	}
	// The hosting API only sees pushed branches; reuse the panel's push
	// semantics so a fresh branch needs no manual push first.
	if _, err := Push(ctx, dir); err != nil {
		return nil, fmt.Errorf("push %s: %w", branch, err)
	}
	switch host {
	case "github":
		_, err = runHost(ctx, dir, "gh", "pr", "create", "--title", title, "--body", body, "--base", base)
	case "gitlab":
		_, err = runHost(ctx, dir, "glab", "mr", "create", "--title", title, "--description", body, "--source-branch", branch, "--target-branch", base, "--yes")
	}
	if err != nil {
		return nil, err
	}
	return PullRequestForBranch(ctx, dir)
}

// MainBranchShort returns the short branch name of the repository's main
// line ("main" or "master"), or "" when the remote has neither.
func MainBranchShort(ctx context.Context, dir string) string {
	short := strings.TrimPrefix(MainBranch(ctx, dir), "refs/remotes/")
	if index := strings.IndexByte(short, '/'); index > 0 {
		short = short[index+1:]
	}
	return short
}

// prHost maps the origin remote to the CLI that manages pull requests for
// it: "github" for GitHub remotes and "gitlab" for GitLab remotes.
func prHost(ctx context.Context, dir string) (string, error) {
	remote, err := RemoteURL(ctx, dir)
	if err != nil {
		return "", err
	}
	host := remoteHost(remote)
	switch {
	case strings.Contains(host, "github.com"):
		return "github", nil
	case strings.Contains(host, "gitlab"), host == "git.bilibili.co":
		return "gitlab", nil
	}
	return "", fmt.Errorf("unsupported git host %q for pull requests (GitHub and GitLab are supported)", host)
}

// remoteHost extracts the host name from any common git remote URL form:
// ssh, https, or scp-like git@host:path.
func remoteHost(remote string) string {
	value := strings.TrimSpace(remote)
	for _, prefix := range []string{"ssh://", "git://", "http://", "https://"} {
		value = strings.TrimPrefix(value, prefix)
	}
	if at := strings.IndexByte(value, '@'); at >= 0 {
		value = value[at+1:]
	}
	if colon := strings.IndexByte(value, ':'); colon >= 0 {
		return value[:colon]
	}
	if slash := strings.IndexByte(value, '/'); slash >= 0 {
		return value[:slash]
	}
	return value
}

func gitHubPullRequest(ctx context.Context, dir, branch string) (*PullRequest, error) {
	if err := requireHostCLI("gh"); err != nil {
		return nil, err
	}
	output, err := runHost(ctx, dir, "gh", "pr", "view", "--json", "number,title,body,state,isDraft,url,author,baseRefName,headRefName")
	if err != nil {
		if strings.Contains(err.Error(), "no pull requests found") {
			return nil, ErrNoPullRequest
		}
		return nil, err
	}
	return parseGitHubPullRequest(output)
}

func gitLabMergeRequest(ctx context.Context, dir, branch string) (*PullRequest, error) {
	if err := requireHostCLI("glab"); err != nil {
		return nil, err
	}
	output, err := runHost(ctx, dir, "glab", "mr", "list", "--source-branch", branch, "-F", "json")
	if err != nil {
		return nil, err
	}
	return parseGitLabMergeRequest(output)
}

func requireHostCLI(name string) error {
	if _, err := exec.LookPath(name); err != nil {
		return fmt.Errorf("%s CLI not found on PATH; install it to manage pull requests", name)
	}
	return nil
}

// runHost runs a hosting CLI (gh or glab) with the repository as the
// working directory; unlike git these CLIs infer the repository from cwd.
func runHost(ctx context.Context, dir, name string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, commandTimeout)
	defer cancel()
	command := exec.CommandContext(ctx, name, args...)
	command.Dir = dir
	output, err := command.CombinedOutput()
	if err != nil {
		if ctx.Err() != nil {
			if errors.Is(ctx.Err(), context.DeadlineExceeded) {
				return "", fmt.Errorf("%s %s timed out: %w", name, strings.Join(args, " "), ctx.Err())
			}
			return "", fmt.Errorf("%s %s canceled: %w", name, strings.Join(args, " "), ctx.Err())
		}
		return "", &Error{Output: string(output), Err: err}
	}
	return string(output), nil
}

type gitHubPullRequestJSON struct {
	Number  int    `json:"number"`
	Title   string `json:"title"`
	Body    string `json:"body"`
	State   string `json:"state"`
	IsDraft bool   `json:"isDraft"`
	URL     string `json:"url"`
	Author  struct {
		Login string `json:"login"`
	} `json:"author"`
	BaseRefName string `json:"baseRefName"`
	HeadRefName string `json:"headRefName"`
}

func parseGitHubPullRequest(output string) (*PullRequest, error) {
	var raw gitHubPullRequestJSON
	if err := json.Unmarshal([]byte(output), &raw); err != nil {
		return nil, fmt.Errorf("parse gh pr view output: %w", err)
	}
	if raw.Number == 0 {
		return nil, fmt.Errorf("gh pr view returned no pull request")
	}
	return &PullRequest{
		Number: raw.Number,
		Title:  raw.Title,
		Body:   raw.Body,
		State:  normalizeState(raw.State),
		Draft:  raw.IsDraft,
		URL:    raw.URL,
		Author: raw.Author.Login,
		Base:   raw.BaseRefName,
		Head:   raw.HeadRefName,
	}, nil
}

type gitLabMergeRequestJSON struct {
	IID         int    `json:"iid"`
	Title       string `json:"title"`
	Description string `json:"description"`
	State       string `json:"state"`
	Draft       bool   `json:"draft"`
	WebURL      string `json:"web_url"`
	Author      struct {
		Username string `json:"username"`
	} `json:"author"`
	SourceBranch string `json:"source_branch"`
	TargetBranch string `json:"target_branch"`
}

func parseGitLabMergeRequest(output string) (*PullRequest, error) {
	trimmed := strings.TrimSpace(output)
	if trimmed == "" {
		return nil, ErrNoPullRequest
	}
	var list []gitLabMergeRequestJSON
	if err := json.Unmarshal([]byte(trimmed), &list); err != nil {
		return nil, fmt.Errorf("parse glab mr list output: %w", err)
	}
	if len(list) == 0 {
		return nil, ErrNoPullRequest
	}
	mr := list[0]
	return &PullRequest{
		Number: mr.IID,
		Title:  mr.Title,
		Body:   mr.Description,
		State:  normalizeState(mr.State),
		Draft:  mr.Draft,
		URL:    mr.WebURL,
		Author: mr.Author.Username,
		Base:   mr.TargetBranch,
		Head:   mr.SourceBranch,
	}, nil
}

func normalizeState(state string) string {
	state = strings.ToLower(strings.TrimSpace(state))
	if state == "opened" {
		return "open"
	}
	return state
}
