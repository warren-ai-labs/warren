package server

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/store"
)

func gitForServiceTest(t *testing.T, dir string, args ...string) {
	t.Helper()
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git binary not available")
	}
	command := exec.Command("git", append([]string{"-C", dir}, args...)...)
	if output, err := command.CombinedOutput(); err != nil {
		t.Fatalf("git %v: %s: %v", args, output, err)
	}
}

func newRepositoryForServiceTest(t *testing.T) string {
	t.Helper()
	dir := filepath.Join(t.TempDir(), "repository")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	gitForServiceTest(t, dir, "init", "--quiet", "-b", "main")
	gitForServiceTest(t, dir, "config", "user.email", "test@example.com")
	gitForServiceTest(t, dir, "config", "user.name", "Test")
	if err := os.WriteFile(filepath.Join(dir, "a.txt"), []byte("a\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	gitForServiceTest(t, dir, "add", "-A")
	gitForServiceTest(t, dir, "commit", "-m", "init")
	return dir
}

func gitPanelService(t *testing.T, repository string) (*Service, string) {
	t.Helper()
	state, err := store.Open(filepath.Join(t.TempDir(), "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	projectID := store.NewID()
	workspaceID := store.NewID()
	if err := state.Update(func(value *api.State) error {
		value.Projects = []api.Project{{ID: projectID, Name: "Project", Path: repository, CreatedAt: time.Now().UTC()}}
		value.Workspaces = []api.Workspace{{ID: workspaceID, ProjectID: projectID, Name: "main", Path: repository, Kind: "root", CreatedAt: time.Now().UTC()}}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	return &Service{Store: state}, workspaceID
}

func TestGitPanelAggregatesWorkspace(t *testing.T) {
	repository := newRepositoryForServiceTest(t)
	service, workspaceID := gitPanelService(t, repository)

	panel, err := service.GitPanel(context.Background(), workspaceID, false, false)
	if err != nil {
		t.Fatal(err)
	}
	if panel.Branch != "main" {
		t.Fatalf("branch = %q, want main", panel.Branch)
	}
	if len(panel.Commits) != 1 || panel.Commits[0].Subject != "init" {
		t.Fatalf("commits = %#v", panel.Commits)
	}
	if len(panel.Changes) != 0 {
		t.Fatalf("changes = %#v, want none", panel.Changes)
	}
	if panel.PullRequest != nil || panel.PullRequestError != "" {
		t.Fatalf("pull request = %#v, %q, want none without a remote", panel.PullRequest, panel.PullRequestError)
	}
	foundMain := false
	for _, branch := range panel.Branches {
		if branch.Name == "main" && !branch.Remote {
			foundMain = true
		}
	}
	if !foundMain {
		t.Fatalf("branches = %#v, want local main", panel.Branches)
	}
}

func TestGitPanelRejectsUnknownWorkspace(t *testing.T) {
	service, _ := gitPanelService(t, newRepositoryForServiceTest(t))
	if _, err := service.GitPanel(context.Background(), "missing", false, false); err == nil {
		t.Fatal("expected error for unknown workspace")
	}
}

func TestGitCheckoutUpdatesStoredBranch(t *testing.T) {
	repository := newRepositoryForServiceTest(t)
	service, workspaceID := gitPanelService(t, repository)
	gitForServiceTest(t, repository, "branch", "dev")

	if _, err := service.GitCheckout(context.Background(), workspaceID, "dev", false); err != nil {
		t.Fatal(err)
	}
	panel, err := service.GitPanel(context.Background(), workspaceID, false, false)
	if err != nil {
		t.Fatal(err)
	}
	if panel.Branch != "dev" {
		t.Fatalf("branch = %q, want dev", panel.Branch)
	}
	state := service.Store.Snapshot()
	if state.Workspaces[0].Branch != "dev" {
		t.Fatalf("stored branch = %q, want dev", state.Workspaces[0].Branch)
	}
}

func TestGitCheckoutCreateBranch(t *testing.T) {
	repository := newRepositoryForServiceTest(t)
	service, workspaceID := gitPanelService(t, repository)

	if _, err := service.GitCheckout(context.Background(), workspaceID, "feature/x", true); err != nil {
		t.Fatal(err)
	}
	state := service.Store.Snapshot()
	if state.Workspaces[0].Branch != "feature/x" {
		t.Fatalf("stored branch = %q, want feature/x", state.Workspaces[0].Branch)
	}
}

func TestGitCheckoutLocalSlashBranchKeepsFullName(t *testing.T) {
	repository := newRepositoryForServiceTest(t)
	service, workspaceID := gitPanelService(t, repository)
	gitForServiceTest(t, repository, "branch", "feature/x")

	if _, err := service.GitCheckout(context.Background(), workspaceID, "feature/x", false); err != nil {
		t.Fatal(err)
	}
	state := service.Store.Snapshot()
	if state.Workspaces[0].Branch != "feature/x" {
		t.Fatalf("stored branch = %q, want feature/x", state.Workspaces[0].Branch)
	}
}

func TestGitCheckoutRemoteBranchStoresLocalName(t *testing.T) {
	upstream := newRepositoryForServiceTest(t)
	gitForServiceTest(t, upstream, "checkout", "-q", "-b", "dev")
	if err := os.WriteFile(filepath.Join(upstream, "dev.txt"), []byte("d\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	gitForServiceTest(t, upstream, "add", "-A")
	gitForServiceTest(t, upstream, "commit", "-m", "dev")
	gitForServiceTest(t, upstream, "checkout", "-q", "main")

	clone := filepath.Join(t.TempDir(), "clone")
	gitForServiceTest(t, filepath.Dir(upstream), "clone", "-q", upstream, clone)
	service, workspaceID := gitPanelService(t, clone)

	if _, err := service.GitCheckout(context.Background(), workspaceID, "origin/dev", false); err != nil {
		t.Fatal(err)
	}
	state := service.Store.Snapshot()
	if state.Workspaces[0].Branch != "dev" {
		t.Fatalf("stored branch = %q, want dev", state.Workspaces[0].Branch)
	}
}

func TestGitCheckoutCreateOnEmptyRepo(t *testing.T) {
	directory := t.TempDir()
	repository := filepath.Join(directory, "repository")
	if err := os.MkdirAll(repository, 0o755); err != nil {
		t.Fatal(err)
	}
	gitForServiceTest(t, repository, "init", "--quiet", "-b", "main")
	gitForServiceTest(t, repository, "config", "user.email", "test@example.com")
	gitForServiceTest(t, repository, "config", "user.name", "Test")
	service, workspaceID := gitPanelService(t, repository)

	if _, err := service.GitCheckout(context.Background(), workspaceID, "feature/x", true); err != nil {
		t.Fatal(err)
	}
	state := service.Store.Snapshot()
	if state.Workspaces[0].Branch != "feature/x" {
		t.Fatalf("stored branch = %q, want feature/x", state.Workspaces[0].Branch)
	}
}

func TestGitDiffReturnsWorkingTreeDiff(t *testing.T) {
	repository := newRepositoryForServiceTest(t)
	service, workspaceID := gitPanelService(t, repository)
	if err := os.WriteFile(filepath.Join(repository, "a.txt"), []byte("b\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	diff, err := service.GitDiff(context.Background(), workspaceID, "a.txt", false, "")
	if err != nil {
		t.Fatal(err)
	}
	if diff.Content != "b\n" {
		t.Fatalf("content = %q, want working tree content", diff.Content)
	}
	if !strings.Contains(diff.Diff, "-a\n") || !strings.Contains(diff.Diff, "+b\n") {
		t.Fatalf("diff = %q, want a -> b change", diff.Diff)
	}
}

func TestGitPanelDeduplicatesConcurrentColdLoads(t *testing.T) {
	repository := newRepositoryForServiceTest(t)
	service, workspaceID := gitPanelService(t, repository)

	type result struct {
		panel api.GitPanel
		err   error
	}
	start := make(chan struct{})
	results := make(chan result, 2)
	for i := 0; i < 2; i++ {
		go func() {
			<-start
			panel, err := service.GitPanel(context.Background(), workspaceID, false, false)
			results <- result{panel: panel, err: err}
		}()
	}
	close(start)

	panels := make([]api.GitPanel, 0, 2)
	for i := 0; i < 2; i++ {
		select {
		case got := <-results:
			if got.err != nil {
				t.Fatal(got.err)
			}
			panels = append(panels, got.panel)
		case <-time.After(10 * time.Second):
			t.Fatal("timed out waiting for a git panel call")
		}
	}
	if panels[0].Branch != panels[1].Branch {
		t.Fatalf("concurrent cold loads returned different panels: %q vs %q", panels[0].Branch, panels[1].Branch)
	}
	if loads := service.panelLoads.Load(); loads != 1 {
		t.Fatalf("git panel loads = %d, want 1", loads)
	}
}

func TestGitPanelColdLoadFollowerCancellationReturnsBeforeElectedLoad(t *testing.T) {
	repository := newRepositoryForServiceTest(t)
	service, workspaceID := gitPanelService(t, repository)
	admit := &queueingAdmit{}
	service.gitCoordinator = newWorkspaceGitCoordinator(admit.submit, gitCoordinatorPendingLimit, gitCoordinatorWorkspacePendingLimit, 4)

	headDone := make(chan error, 1)
	go func() {
		_, err := service.GitPanel(context.Background(), workspaceID, false, false)
		headDone <- err
	}()
	headJob := admit.waitForJob(t)

	followerCtx, followerCancel := context.WithCancel(context.Background())
	followerDone := make(chan error, 1)
	go func() {
		_, err := service.GitPanel(followerCtx, workspaceID, false, false)
		followerDone <- err
	}()
	waitForCoordinatorQueued(t, service.gitCoordinator, workspaceID, 1)
	followerCancel()
	select {
	case err := <-followerDone:
		if err == nil {
			t.Fatal("cancelled cold-load follower returned success")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("cancelled cold-load follower did not return before the elected load")
	}

	admit.start(headJob)
	select {
	case err := <-headDone:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("elected cold load did not complete")
	}
	if loads := service.panelLoads.Load(); loads != 1 {
		t.Fatalf("git panel loads = %d, want 1", loads)
	}
}

func TestGitPanelSWRRejectedAdmissionResetsRevalidating(t *testing.T) {
	repository := newRepositoryForServiceTest(t)
	service, workspaceID := gitPanelService(t, repository)
	ctx := context.Background()
	if _, err := service.GitPanel(ctx, workspaceID, false, false); err != nil {
		t.Fatal(err)
	}
	cache := service.panelCacheFor()
	cache.mu.Lock()
	element := cache.index[workspaceID]
	element.Value.(*panelCacheEntry).loadedAt = time.Now().Add(-panelRevalidateAfter - time.Minute)
	cache.mu.Unlock()

	service.revalidateLane = newStaleRevalidateLane(nil, 0, 0)
	panel, err := service.GitPanel(ctx, workspaceID, false, false)
	if err != nil {
		t.Fatal(err)
	}
	if panel.Refreshing {
		t.Fatal("expected rejected revalidation submission to keep Refreshing=false")
	}
	if !cache.ShouldRevalidate(workspaceID, 0) {
		t.Fatal("expected rejected revalidation submission to reset the revalidating marker")
	}
}

func TestGitPanelSWRRevalidationFinishesExactlyOnce(t *testing.T) {
	repository := newRepositoryForServiceTest(t)
	service, workspaceID := gitPanelService(t, repository)
	ctx := context.Background()
	if _, err := service.GitPanel(ctx, workspaceID, false, false); err != nil {
		t.Fatal(err)
	}
	cache := service.panelCacheFor()
	cache.mu.Lock()
	element := cache.index[workspaceID]
	element.Value.(*panelCacheEntry).loadedAt = time.Now().Add(-panelRevalidateAfter - time.Minute)
	cache.mu.Unlock()

	if !cache.ShouldRevalidate(workspaceID, panelRevalidateAfter) {
		t.Fatal("expected stale entry to start revalidating")
	}
	workspace, err := findWorkspace(service.Store.Snapshot(), workspaceID)
	if err != nil {
		t.Fatal(err)
	}
	service.revalidatePanel(workspaceID, workspace.Path)
	if !cache.ShouldRevalidate(workspaceID, 0) {
		t.Fatal("expected revalidation to finish and clear the revalidating marker exactly once")
	}
}

func TestGitPanelLoadSurvivesCallerCancellation(t *testing.T) {
	repository := newRepositoryForServiceTest(t)
	service, workspaceID := gitPanelService(t, repository)
	unlock := service.lockGitMutation(workspaceID)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		_, err := service.GitPanel(ctx, workspaceID, true, true)
		done <- err
	}()

	// Keep the shared load blocked while its original observer disappears.
	time.Sleep(20 * time.Millisecond)
	cancel()
	unlock()

	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("git panel load inherited caller cancellation: %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("git panel load did not finish after the mutation lock was released")
	}
}
