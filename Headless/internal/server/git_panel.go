package server

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/git"
)

func (s *Service) GitPanel(ctx context.Context, workspaceID string, fetch, force bool) (api.GitPanel, error) {
	workspace, err := findWorkspace(s.Store.Snapshot(), workspaceID)
	if err != nil {
		return api.GitPanel{}, err
	}
	cache := s.panelCacheFor()
	if !force {
		if panel, ok := cache.Get(workspaceID); ok {
			switch cache.Revalidation(workspaceID, panelRevalidateAfter, panelLocalRevalidateAfter) {
			case panelRevalidateFull:
				go s.revalidatePanel(workspace)
				panel.Refreshing = true
			case panelRevalidateLocal:
				go s.revalidatePanelLocally(workspace)
			}
			return panel, nil
		}
	}
	version := cache.Version(workspaceID)
	// panelLoad coalesces callers for one workspace. Detach the actual load
	// from one observer's WebSocket so a reconnect cannot cancel the shared
	// operation and poison every waiter with context.Canceled.
	loadContext, cancel := context.WithTimeout(context.WithoutCancel(ctx), panelLoadTimeout)
	defer cancel()
	panel, err := s.panelLoad.Do(workspaceID, func() (api.GitPanel, error) {
		return s.loadGitPanel(loadContext, workspace, fetch, true)
	})
	if err != nil {
		return api.GitPanel{}, err
	}
	cache.SetIfVersion(workspaceID, panel, version)
	return panel, nil
}

func (s *Service) panelCacheFor() *panelCache {
	s.panelCacheOnce.Do(func() {
		s.panelCache = newPanelCache(panelCacheCapacity)
		s.panelLoad = newPanelLoad()
	})
	return s.panelCache
}

func (s *Service) revalidatePanel(workspace api.Workspace) {
	ctx, cancel := context.WithTimeout(context.Background(), panelRevalidateTimeout)
	defer cancel()
	cache := s.panelCacheFor()
	version := cache.Version(workspace.ID)
	panel, err := s.loadGitPanel(ctx, workspace, true, true)
	if err == nil {
		cache.SetIfVersion(workspace.ID, panel, version)
	}
	cache.FinishRevalidate(workspace.ID)
}

// revalidatePanelLocally re-reads what changes without Warren's help (the
// working tree, commits, branches) and keeps the cached remote part.
func (s *Service) revalidatePanelLocally(workspace api.Workspace) {
	ctx, cancel := context.WithTimeout(context.Background(), panelRevalidateTimeout)
	defer cancel()
	cache := s.panelCacheFor()
	version := cache.Version(workspace.ID)
	panel, err := s.loadGitPanel(ctx, workspace, false, false)
	if err == nil {
		cache.SetLocalIfVersion(workspace.ID, panel, version)
	}
	cache.FinishRevalidate(workspace.ID)
}

func (s *Service) invalidatePanelCache(workspaceID string) {
	s.panelCacheFor().Remove(workspaceID)
}

func (s *Service) loadGitPanel(ctx context.Context, workspace api.Workspace, fetch, remote bool) (api.GitPanel, error) {
	path := workspace.Path
	if fetch {
		unlock := s.lockGitMutation(workspace.ID)
		// Refresh the remote refs before comparing against origin/main. A
		// failed fetch (offline, no remote) must not block the panel; the
		// comparison then uses the last fetched refs. Release the mutation
		// lock as soon as fetch finishes so commits/pushes are not blocked
		// behind read-only panel queries or network PR lookups.
		_ = git.Fetch(ctx, path)
		unlock()
	}

	var (
		mainBranch string
		status     git.Status
		statusErr  error
		commits    []git.Commit
		commitsErr error
		branches   git.BranchList
		branchErr  error
		remoteURL  string
		operation  string
	)
	var wg sync.WaitGroup
	wg.Add(6)
	go func() { defer wg.Done(); mainBranch = git.MainBranch(ctx, path) }()
	go func() { defer wg.Done(); status, statusErr = git.StatusFor(ctx, path) }()
	go func() { defer wg.Done(); commits, commitsErr = git.Log(ctx, path, 20) }()
	go func() { defer wg.Done(); branches, branchErr = git.Branches(ctx, path) }()
	go func() { defer wg.Done(); remoteURL, _ = git.RemoteURL(ctx, path) }()
	go func() { defer wg.Done(); operation = git.OperationState(ctx, path) }()
	wg.Wait()

	if statusErr != nil {
		return api.GitPanel{}, statusErr
	}
	if commitsErr != nil {
		return api.GitPanel{}, commitsErr
	}
	if branchErr != nil {
		return api.GitPanel{}, branchErr
	}

	panel := api.GitPanel{
		WorkspaceID: workspace.ID,
		Branch:      status.Branch,
		Upstream:    status.Upstream,
		Ahead:       status.Ahead,
		Behind:      status.Behind,
		Remote:      remoteURL,
		MainBranch:  strings.TrimPrefix(mainBranch, "refs/remotes/"),
		Operation:   operation,
		Changes:     apiGitChanges(status.Changes),
		Commits:     apiGitCommits(commits),
		Branches:    apiGitBranches(branches),
	}

	var (
		pr              *git.PullRequest
		prErr           error
		merged          bool
		unmergedCommits []git.Commit
		aheadOfMain     int
		aheadOfMainOK   bool
	)
	var phase2 sync.WaitGroup
	if remote && panel.Remote != "" {
		phase2.Add(1)
		go func() {
			defer phase2.Done()
			pr, prErr = git.PullRequestForBranch(ctx, path)
		}()
	}
	if mainBranch != "" {
		// The default branch itself has nothing to merge into; keep showing it
		// as merged so the panel never labels its own history "not in main".
		if status.Branch == strings.TrimPrefix(mainBranch, "refs/remotes/origin/") {
			merged = true
		} else {
			phase2.Add(1)
			go func() {
				defer phase2.Done()
				// A recorded base belongs to the workspace's own branch; a worktree
				// switched elsewhere by hand must not reuse it.
				base := ""
				if workspace.Branch == status.Branch {
					base = workspace.BaseCommit
				}
				if base == "" {
					base, _ = git.BranchBase(ctx, path, status.Branch)
				}
				// The sidebar badge, `workspace list` and this panel must agree, so
				// the merge decision is shared with the Host's merge projection.
				if isMerged, known := git.MergedIntoTarget(ctx, path, mainBranch, status.Branch, base); known {
					merged = isMerged
				}
				if !merged {
					if unmerged, err := git.LogRangeFrom(ctx, path, mainBranch, base); err == nil {
						unmergedCommits = unmerged
					}
				}
			}()
		}
		phase2.Add(1)
		go func() {
			defer phase2.Done()
			if ahead, _, err := git.AheadBehind(ctx, path, mainBranch); err == nil {
				aheadOfMain = ahead
				aheadOfMainOK = true
			}
		}()
	}
	phase2.Wait()

	if remote && panel.Remote != "" {
		if prErr != nil && !errors.Is(prErr, git.ErrNoPullRequest) {
			panel.PullRequestError = prErr.Error()
		} else if pr != nil {
			panel.PullRequest = apiGitPullRequest(pr)
		}
	}
	if mainBranch != "" {
		panel.Merged = merged
		if len(unmergedCommits) > 0 {
			panel.UnmergedCommits = apiGitCommits(unmergedCommits)
		}
		if aheadOfMainOK {
			panel.AheadOfMain = aheadOfMain
		}
	}
	return panel, nil
}

// GitDiff returns the full content and unified diff of one path in a
// workspace, either in the working tree (staged selects the index) or for a
// specific commit.
func (s *Service) GitDiff(ctx context.Context, workspaceID, path string, staged bool, commit string) (api.GitDiff, error) {
	workspace, err := findWorkspace(s.Store.Snapshot(), workspaceID)
	if err != nil {
		return api.GitDiff{}, err
	}
	view, err := git.Show(ctx, workspace.Path, path, staged, commit)
	if err != nil {
		return api.GitDiff{}, err
	}
	return api.GitDiff{
		Diff: view.Diff, Content: view.Content,
		DiffTruncated: view.DiffTruncated, ContentTruncated: view.ContentTruncated,
	}, nil
}

func (s *Service) GitCheckout(ctx context.Context, workspaceID, branch string, create bool) (api.GitCommandResult, error) {
	unlock := s.lockGitMutation(workspaceID)
	defer unlock()
	workspace, err := findWorkspace(s.Store.Snapshot(), workspaceID)
	if err != nil {
		return api.GitCommandResult{}, err
	}
	if err := git.Checkout(ctx, workspace.Path, branch, create); err != nil {
		return api.GitCommandResult{}, err
	}
	current, err := git.CurrentBranch(ctx, workspace.Path)
	if err != nil {
		return api.GitCommandResult{}, err
	}
	if err := s.Store.Update(func(value *api.State) error {
		for i := range value.Workspaces {
			if value.Workspaces[i].ID == workspaceID {
				value.Workspaces[i].Branch = current
				// The recorded base describes the previous branch; the new
				// branch's creation point comes from its own reflog instead.
				value.Workspaces[i].BaseCommit = ""
				return nil
			}
		}
		return fmt.Errorf("workspace not found: %s", workspaceID)
	}); err != nil {
		return api.GitCommandResult{}, err
	}
	s.invalidatePanelCache(workspaceID)
	return api.GitCommandResult{Message: "Checked out " + current}, nil
}

func (s *Service) GitPull(ctx context.Context, workspaceID string) (api.GitCommandResult, error) {
	unlock := s.lockGitMutation(workspaceID)
	defer unlock()
	workspace, err := findWorkspace(s.Store.Snapshot(), workspaceID)
	if err != nil {
		return api.GitCommandResult{}, err
	}
	output, err := git.Pull(ctx, workspace.Path)
	if err != nil {
		return api.GitCommandResult{}, err
	}
	s.invalidatePanelCache(workspaceID)
	return api.GitCommandResult{Message: strings.TrimSpace(output)}, nil
}

func (s *Service) GitPush(ctx context.Context, workspaceID string) (api.GitCommandResult, error) {
	unlock := s.lockGitMutation(workspaceID)
	defer unlock()
	workspace, err := findWorkspace(s.Store.Snapshot(), workspaceID)
	if err != nil {
		return api.GitCommandResult{}, err
	}
	output, err := git.Push(ctx, workspace.Path)
	if err != nil {
		return api.GitCommandResult{}, err
	}
	s.invalidatePanelCache(workspaceID)
	return api.GitCommandResult{Message: strings.TrimSpace(output)}, nil
}

func (s *Service) GitCommit(ctx context.Context, workspaceID, message string) (api.GitCommandResult, error) {
	unlock := s.lockGitMutation(workspaceID)
	defer unlock()
	workspace, err := findWorkspace(s.Store.Snapshot(), workspaceID)
	if err != nil {
		return api.GitCommandResult{}, err
	}
	output, err := git.CommitAll(ctx, workspace.Path, message)
	if err != nil {
		return api.GitCommandResult{}, err
	}
	s.invalidatePanelCache(workspaceID)
	return api.GitCommandResult{Message: strings.TrimSpace(output)}, nil
}

// GitCreatePullRequest pushes the workspace branch if needed and opens a
// pull request against the repository's main branch.
func (s *Service) GitCreatePullRequest(ctx context.Context, workspaceID, title, body string) (api.GitPullRequest, error) {
	unlock := s.lockGitMutation(workspaceID)
	defer unlock()
	workspace, err := findWorkspace(s.Store.Snapshot(), workspaceID)
	if err != nil {
		return api.GitPullRequest{}, err
	}
	pr, err := git.CreatePullRequest(ctx, workspace.Path, title, body)
	if err != nil {
		return api.GitPullRequest{}, err
	}
	s.invalidatePanelCache(workspaceID)
	return *apiGitPullRequest(pr), nil
}

func apiGitChanges(changes []git.Change) []api.GitChange {
	result := make([]api.GitChange, 0, len(changes))
	for _, change := range changes {
		result = append(result, api.GitChange{
			Path:       change.Path,
			Status:     change.Status,
			Staged:     change.Staged,
			RenameFrom: change.RenameFrom,
			Added:      change.Added,
			Deleted:    change.Deleted,
		})
	}
	return result
}

func apiGitCommits(commits []git.Commit) []api.GitCommit {
	result := make([]api.GitCommit, 0, len(commits))
	for _, commit := range commits {
		files := make([]api.GitChange, 0, len(commit.Files))
		for _, file := range commit.Files {
			files = append(files, api.GitChange{
				Path:       file.Path,
				Status:     file.Status,
				RenameFrom: file.RenameFrom,
				Added:      file.Added,
				Deleted:    file.Deleted,
			})
		}
		result = append(result, api.GitCommit{
			Hash:    commit.Hash,
			Short:   commit.Short,
			Subject: commit.Subject,
			Author:  commit.Author,
			Email:   commit.Email,
			Time:    commit.Time,
			Files:   files,
		})
	}
	return result
}

func apiGitBranches(list git.BranchList) []api.GitBranch {
	result := make([]api.GitBranch, 0, len(list.Local)+len(list.Remote))
	for _, name := range list.Local {
		result = append(result, api.GitBranch{Name: name})
	}
	for _, name := range list.Remote {
		result = append(result, api.GitBranch{Name: name, Remote: true})
	}
	return result
}

func apiGitPullRequest(pr *git.PullRequest) *api.GitPullRequest {
	return &api.GitPullRequest{
		Number: pr.Number,
		Title:  pr.Title,
		Body:   pr.Body,
		State:  pr.State,
		Draft:  pr.Draft,
		URL:    pr.URL,
		Author: pr.Author,
		Base:   pr.Base,
		Head:   pr.Head,
	}
}
