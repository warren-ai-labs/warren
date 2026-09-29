package server

import (
	"context"
	"sync/atomic"
	"testing"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

func TestPanelCacheServesFreshEntries(t *testing.T) {
	cache := newPanelCache(2)
	cache.Set("a", api.GitPanel{WorkspaceID: "a"})
	if _, ok := cache.Get("a"); !ok {
		t.Fatal("expected cache hit for fresh entry")
	}
	if _, ok := cache.Get("b"); ok {
		t.Fatal("expected cache miss for unknown entry")
	}
}

func TestPanelCacheEvictsLeastRecentlyUsed(t *testing.T) {
	cache := newPanelCache(2)
	cache.Set("a", api.GitPanel{WorkspaceID: "a"})
	cache.Set("b", api.GitPanel{WorkspaceID: "b"})
	if _, ok := cache.Get("a"); !ok {
		t.Fatal("expected a to be cached")
	}
	cache.Set("c", api.GitPanel{WorkspaceID: "c"})
	if _, ok := cache.Get("b"); ok {
		t.Fatal("expected b to be evicted as least recently used")
	}
	if _, ok := cache.Get("a"); !ok {
		t.Fatal("expected a to survive after being touched")
	}
}

func TestPanelCacheSetIfVersionRejectsStaleWrites(t *testing.T) {
	cache := newPanelCache(2)
	cache.Set("a", api.GitPanel{WorkspaceID: "a"})
	version := cache.Version("a")
	cache.Remove("a")
	if cache.SetIfVersion("a", api.GitPanel{WorkspaceID: "a", Branch: "stale"}, version) {
		t.Fatal("expected stale write to be rejected after removal")
	}
	if _, ok := cache.Get("a"); ok {
		t.Fatal("expected removed entry to stay absent")
	}
}

func TestPanelCacheShouldRevalidateCoalesces(t *testing.T) {
	cache := newPanelCache(2)
	cache.Set("a", api.GitPanel{WorkspaceID: "a"})
	if !cache.ShouldRevalidate("a", 0) {
		t.Fatal("expected first check to trigger revalidation")
	}
	if cache.ShouldRevalidate("a", 0) {
		t.Fatal("expected concurrent check to be coalesced while revalidating")
	}
	cache.FinishRevalidate("a")
	if !cache.ShouldRevalidate("a", 0) {
		t.Fatal("expected revalidation to be allowed again after finishing")
	}
}

func TestPanelLoadMergesConcurrentLoads(t *testing.T) {
	loads := newPanelLoad()
	var calls atomic.Int32
	start := make(chan struct{})
	const workers = 8
	results := make(chan string, workers)
	for i := 0; i < workers; i++ {
		go func() {
			<-start
			panel, err := loads.Do("a", func() (api.GitPanel, error) {
				calls.Add(1)
				time.Sleep(50 * time.Millisecond)
				return api.GitPanel{WorkspaceID: "a", Branch: "main"}, nil
			})
			if err != nil {
				results <- "error"
				return
			}
			results <- panel.Branch
		}()
	}
	close(start)
	for i := 0; i < workers; i++ {
		if branch := <-results; branch != "main" {
			t.Fatalf("worker got branch %q, want main", branch)
		}
	}
	if calls.Load() != 1 {
		t.Fatalf("load executed %d times, want 1", calls.Load())
	}
}

func TestGitPanelServesCachedSnapshot(t *testing.T) {
	repository := newRepositoryForServiceTest(t)
	service, workspaceID := gitPanelService(t, repository)
	ctx := context.Background()

	first, err := service.GitPanel(ctx, workspaceID, false, false)
	if err != nil {
		t.Fatal(err)
	}
	gitForServiceTest(t, repository, "commit", "--allow-empty", "-m", "second")

	second, err := service.GitPanel(ctx, workspaceID, false, false)
	if err != nil {
		t.Fatal(err)
	}
	if len(second.Commits) != len(first.Commits) {
		t.Fatalf("second call returned %d commits, want cached %d", len(second.Commits), len(first.Commits))
	}

	service.invalidatePanelCache(workspaceID)
	third, err := service.GitPanel(ctx, workspaceID, false, false)
	if err != nil {
		t.Fatal(err)
	}
	if len(third.Commits) != len(first.Commits)+1 {
		t.Fatalf("after invalidation got %d commits, want %d", len(third.Commits), len(first.Commits)+1)
	}
}

func TestGitPanelCacheIsLazyPerWorkspace(t *testing.T) {
	repository := newRepositoryForServiceTest(t)
	service, workspaceID := gitPanelService(t, repository)
	otherWorkspaceID := workspaceID + "-other"

	if _, ok := service.panelCacheFor().Get(otherWorkspaceID); ok {
		t.Fatal("expected unrequested workspace to be absent from the cache")
	}
	if _, err := service.GitPanel(context.Background(), workspaceID, false, false); err != nil {
		t.Fatal(err)
	}
	if _, ok := service.panelCacheFor().Get(otherWorkspaceID); ok {
		t.Fatal("expected unrequested workspace to stay uncached after another request")
	}
}

func TestGitPanelForceRefreshBypassesCache(t *testing.T) {
	repository := newRepositoryForServiceTest(t)
	service, workspaceID := gitPanelService(t, repository)
	ctx := context.Background()

	if _, err := service.GitPanel(ctx, workspaceID, false, false); err != nil {
		t.Fatal(err)
	}
	gitForServiceTest(t, repository, "commit", "--allow-empty", "-m", "second")

	cached, err := service.GitPanel(ctx, workspaceID, false, false)
	if err != nil {
		t.Fatal(err)
	}
	if len(cached.Commits) != 1 {
		t.Fatalf("cached call returned %d commits, want 1 from cache", len(cached.Commits))
	}

	forced, err := service.GitPanel(ctx, workspaceID, false, true)
	if err != nil {
		t.Fatal(err)
	}
	if len(forced.Commits) != 2 {
		t.Fatalf("forced call returned %d commits, want 2", len(forced.Commits))
	}

	after, err := service.GitPanel(ctx, workspaceID, false, false)
	if err != nil {
		t.Fatal(err)
	}
	if len(after.Commits) != 2 {
		t.Fatalf("cache was not refreshed by the forced call, got %d commits", len(after.Commits))
	}
}

func TestGitPanelReportsBackgroundRefresh(t *testing.T) {
	repository := newRepositoryForServiceTest(t)
	service, workspaceID := gitPanelService(t, repository)
	ctx := context.Background()

	if _, err := service.GitPanel(ctx, workspaceID, false, false); err != nil {
		t.Fatal(err)
	}
	cache := service.panelCacheFor()
	cache.mu.Lock()
	element := cache.index[workspaceID]
	stale := time.Now().Add(-panelRevalidateAfter - time.Minute)
	element.Value.(*panelCacheEntry).loadedAt = stale
	element.Value.(*panelCacheEntry).remoteLoadedAt = stale
	cache.mu.Unlock()

	panel, err := service.GitPanel(ctx, workspaceID, false, false)
	if err != nil {
		t.Fatal(err)
	}
	if !panel.Refreshing {
		t.Fatal("expected panel to report a background refresh after the revalidate window")
	}

	panel, err = service.GitPanel(ctx, workspaceID, false, false)
	if err != nil {
		t.Fatal(err)
	}
	if panel.Refreshing {
		t.Fatal("expected no refresh flag while revalidation is already running")
	}
}

func TestGitPanelAheadBehindAgainstMain(t *testing.T) {
	repository := newRepositoryForServiceTest(t)
	gitForServiceTest(t, repository, "commit", "--allow-empty", "-m", "one")
	gitForServiceTest(t, repository, "commit", "--allow-empty", "-m", "two")
	gitForServiceTest(t, repository, "update-ref", "refs/remotes/origin/main", "HEAD")
	gitForServiceTest(t, repository, "reset", "--hard", "HEAD~2")

	service, workspaceID := gitPanelService(t, repository)
	panel, err := service.GitPanel(context.Background(), workspaceID, false, false)
	if err != nil {
		t.Fatal(err)
	}
	if panel.AheadOfMain != 0 {
		t.Fatalf("ahead of main = %d, want 0 when HEAD is behind origin/main", panel.AheadOfMain)
	}
	if panel.Ahead != 0 || panel.Behind != 0 {
		t.Fatalf("upstream ahead/behind = %d/%d, want 0/0 without a tracking branch", panel.Ahead, panel.Behind)
	}
}

func TestGitPanelAheadOfMain(t *testing.T) {
	repository := newRepositoryForServiceTest(t)
	gitForServiceTest(t, repository, "update-ref", "refs/remotes/origin/main", "HEAD")
	gitForServiceTest(t, repository, "commit", "--allow-empty", "-m", "one")
	gitForServiceTest(t, repository, "commit", "--allow-empty", "-m", "two")

	service, workspaceID := gitPanelService(t, repository)
	panel, err := service.GitPanel(context.Background(), workspaceID, false, false)
	if err != nil {
		t.Fatal(err)
	}
	if panel.AheadOfMain != 2 {
		t.Fatalf("ahead of main = %d, want 2", panel.AheadOfMain)
	}
}

func TestPanelCacheRevalidatesLocalStateSoonAndRemoteStateLater(t *testing.T) {
	cache := newPanelCache(4)
	pr := &api.GitPullRequest{Number: 7, Title: "Open"}
	cache.Set("a", api.GitPanel{WorkspaceID: "a", PullRequest: pr})
	if got := cache.Revalidation("a", time.Hour, time.Hour); got != panelRevalidateNone {
		t.Fatalf("fresh entry = %v, want none", got)
	}
	// Edits made outside Warren only need the local part re-read.
	if got := cache.Revalidation("a", time.Hour, 0); got != panelRevalidateLocal {
		t.Fatalf("stale local state = %v, want local", got)
	}
	cache.FinishRevalidate("a")
	version := cache.Version("a")
	if !cache.SetLocalIfVersion("a", api.GitPanel{WorkspaceID: "a", Changes: []api.GitChange{{Path: "README.md", Status: "M"}}}, version) {
		t.Fatal("local refresh was rejected")
	}
	panel, _ := cache.Get("a")
	if len(panel.Changes) != 1 || panel.PullRequest == nil || panel.PullRequest.Number != 7 {
		t.Fatalf("local refresh must add the change and keep the pull request: %+v", panel)
	}
	if got := cache.Revalidation("a", 0, time.Hour); got != panelRevalidateFull {
		t.Fatalf("stale remote state = %v, want full", got)
	}
}
