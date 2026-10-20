package server

import (
	"context"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/git"
)

const (
	// mergeRefreshInterval bounds how stale the merge projection may become
	// between background refreshes. Steady-state ticks only read refs, so the
	// interval is cheap even with many projects.
	mergeRefreshInterval = 30 * time.Second
	// mergeCommandTimeout bounds every git command so a wedged repository can
	// never stall the background merge loop.
	mergeCommandTimeout = 2 * time.Second
	// mergeRefreshTimeout bounds one whole refresh pass so many workspaces or
	// slow disks cannot keep the projection stale for minutes. Workspaces
	// that did not get checked fall back to unknown on the next roster.
	mergeRefreshTimeout = 15 * time.Second
	// mergeWorkerCount bounds concurrent git processes across one refresh so
	// a large worktree fleet cannot saturate the machine.
	mergeWorkerCount = 4
)

// mergeCacheEntry stores one workspace's merge state together with the ref
// OIDs it was computed from. When the OIDs are unchanged on the next refresh,
// the expensive diff checks are skipped entirely.
type mergeCacheEntry struct {
	state      api.MergeState
	branchOID  string
	targetOIDs string
	base       string
}

// mergeStateCache holds the latest merge projection per workspace. It is
// written by the background merge loop and read by roster snapshots, so git
// work can never block a broadcast.
type mergeStateCache struct {
	mu     sync.RWMutex
	values map[string]mergeCacheEntry
}

func (c *mergeStateCache) get(workspaceID string) (api.MergeState, bool) {
	c.mu.RLock()
	defer c.mu.RUnlock()
	value, ok := c.values[workspaceID]
	return value.state, ok
}

func (c *mergeStateCache) entry(workspaceID string) (mergeCacheEntry, bool) {
	c.mu.RLock()
	defer c.mu.RUnlock()
	value, ok := c.values[workspaceID]
	return value, ok
}

// snapshot returns an immutable copy of the projection so one roster snapshot
// never mixes two generations of merge state.
func (c *mergeStateCache) snapshot() map[string]api.MergeState {
	c.mu.RLock()
	defer c.mu.RUnlock()
	next := make(map[string]api.MergeState, len(c.values))
	for workspaceID, entry := range c.values {
		next[workspaceID] = entry.state
	}
	return next
}

// replace swaps the whole projection atomically. Workspaces that are no
// longer present, not eligible, or whose repository could not be queried
// simply drop out of the map and render as "unknown".
func (c *mergeStateCache) replace(next map[string]mergeCacheEntry) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.values = next
}

// mergeBaseCache remembers the creation point resolved from a branch's
// reflog. The oldest entry of a branch reflog cannot change while the branch
// exists, so a resolution never expires; an unknown base is cached too, so a
// repository without reflogs does not pay for the lookup on every refresh.
type mergeBaseCache struct {
	mu     sync.RWMutex
	values map[string]string
}

func (c *mergeBaseCache) get(key string) (string, bool) {
	c.mu.RLock()
	defer c.mu.RUnlock()
	base, ok := c.values[key]
	return base, ok
}

func (c *mergeBaseCache) set(key, base string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.values == nil {
		c.values = make(map[string]string)
	}
	c.values[key] = base
}

// mergeLoop refreshes the merge projection on every tick and after wake
// signals. It never refreshes eagerly at startup: the first roster request
// from a client schedules the first pass, so an idle daemon stays light.
func (s *Service) mergeLoop(ctx context.Context) {
	ticker := time.NewTicker(mergeRefreshInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			s.maybeRefreshMerge(ctx)
		case <-s.mergeWake:
			// Coalesce bursts of wake signals into one refresh.
			drained := false
			for !drained {
				select {
				case <-s.mergeWake:
				default:
					drained = true
				}
			}
			s.maybeRefreshMerge(ctx)
		}
	}
}

// maybeRefreshMerge runs a refresh only when a client can observe the result.
// Without clients the dirty flag stays set and the first roster request
// schedules the work.
func (s *Service) maybeRefreshMerge(ctx context.Context) {
	if s.ClientsActive != nil && !s.ClientsActive() {
		return
	}
	s.refreshMergeStates(ctx)
}

// wakeMergeRefresh schedules an immediate background refresh without
// blocking the caller when one is already pending.
func (s *Service) wakeMergeRefresh() {
	s.initMergeState()
	select {
	case s.mergeWake <- struct{}{}:
	default:
	}
}

// invalidateMerge marks the projection dirty and schedules a refresh. The
// refresh itself is skipped until a client is connected; the dirty flag keeps
// the request pending.
func (s *Service) invalidateMerge() {
	s.initMergeState()
	s.mergeDirty.Store(true)
	s.wakeMergeRefresh()
}

// mergeProject is the per-project state gathered once per refresh and shared
// by every workspace check in that repository.
type mergeProject struct {
	repo        string
	defaultName string
	worktrees   map[string]string
	refs        map[string]string
}

// refreshMergeStates recomputes the merge projection for every eligible
// worktree workspace. Preparation (default branch, worktree HEADs, ref OIDs)
// is parallelized per project and workspace checks run in a bounded pool.
// Workspaces whose branch and target refs are unchanged reuse their cached
// state without running any diff.
func (s *Service) refreshMergeStates(ctx context.Context) {
	if s.Store == nil {
		return
	}
	s.initMergeState()
	refreshStartedAt := time.Now()
	refreshCtx, cancel := context.WithTimeout(ctx, mergeRefreshTimeout)
	defer cancel()

	state := s.Store.Snapshot()
	byProject := make(map[string][]api.Workspace)
	for _, workspace := range state.Workspaces {
		if workspace.Kind == "worktree" && workspace.Branch != "" {
			byProject[workspace.ProjectID] = append(byProject[workspace.ProjectID], workspace)
		}
	}
	type projectTask struct {
		project api.Project
	}
	var projectTasks []projectTask
	for _, project := range state.Projects {
		if len(byProject[project.ID]) > 0 {
			projectTasks = append(projectTasks, projectTask{project: project})
		}
	}

	prepared := make(map[string]*mergeProject, len(projectTasks))
	var preparedMu sync.Mutex
	var wg sync.WaitGroup
	sem := make(chan struct{}, mergeWorkerCount)
	for _, task := range projectTasks {
		wg.Add(1)
		go func(task projectTask) {
			defer wg.Done()
			select {
			case sem <- struct{}{}:
			case <-refreshCtx.Done():
				return
			}
			defer func() { <-sem }()
			prep := prepareMergeProject(refreshCtx, task.project.Path)
			if prep == nil {
				return
			}
			preparedMu.Lock()
			prepared[task.project.ID] = prep
			preparedMu.Unlock()
		}(task)
	}
	wg.Wait()

	type workspaceTask struct {
		project   api.Project
		workspace api.Workspace
		prep      *mergeProject
	}
	var workspaceTasks []workspaceTask
	for _, project := range state.Projects {
		prep := prepared[project.ID]
		if prep == nil {
			continue
		}
		for _, workspace := range byProject[project.ID] {
			workspaceTasks = append(workspaceTasks, workspaceTask{
				project: project, workspace: workspace, prep: prep,
			})
		}
	}

	next := make(map[string]mergeCacheEntry, len(workspaceTasks))
	var nextMu sync.Mutex
	for _, task := range workspaceTasks {
		wg.Add(1)
		go func(task workspaceTask) {
			defer wg.Done()
			select {
			case sem <- struct{}{}:
			case <-refreshCtx.Done():
				return
			}
			defer func() { <-sem }()
			entry, ok := s.checkWorkspaceMerge(refreshCtx, task.prep, task.workspace)
			if !ok {
				return
			}
			nextMu.Lock()
			next[task.workspace.ID] = entry
			nextMu.Unlock()
		}(task)
	}
	wg.Wait()

	s.mergeCache.replace(next)
	// Mark progress even when the deadline truncated the pass so roster
	// requests stop waking the loop; the next tick retries.
	s.mergeDirty.Store(false)
	s.mergeLastRefresh.Store(time.Now().UnixNano())
	if elapsed := time.Since(refreshStartedAt); elapsed >= time.Second {
		// A slow pass spawns git for many worktrees and can saturate the disk
		// that roster metadata reads share. Log it so a startup stall can be
		// attributed to the merge projection instead of a renderer bug.
		s.logInfo("slow merge refresh", "duration", elapsed, "workspaces", len(workspaceTasks))
	}
}

// checkWorkspaceMerge resolves one workspace's merge state. The stored branch
// must still match the worktree's actual HEAD, and unchanged ref OIDs reuse
// the cached state without running any diff.
func (s *Service) checkWorkspaceMerge(ctx context.Context, prep *mergeProject, workspace api.Workspace) (mergeCacheEntry, bool) {
	if workspace.Branch == prep.defaultName {
		return mergeCacheEntry{}, false
	}
	if actual, found := prep.worktrees[worktreePathKey(workspace.Path)]; !found || actual != workspace.Branch {
		// The stored branch no longer matches the worktree HEAD (or the
		// worktree is gone/detached); do not trust stale state.
		return mergeCacheEntry{}, false
	}
	branchRef := "refs/heads/" + workspace.Branch
	branchOID := prep.refs[branchRef]
	if branchOID == "" {
		return mergeCacheEntry{}, false
	}
	localTarget := prep.refs["refs/heads/"+prep.defaultName]
	originTarget := prep.refs["refs/remotes/origin/"+prep.defaultName]
	targetOIDs := localTarget + "|" + originTarget
	base := workspace.BaseCommit
	if base == "" {
		base = s.mergeBaseFor(ctx, prep.repo, workspace.Branch)
	}
	if entry, ok := s.mergeCache.entry(workspace.ID); ok &&
		entry.branchOID == branchOID && entry.targetOIDs == targetOIDs && entry.base == base {
		return entry, true
	}
	gitCtx, cancel := context.WithTimeout(ctx, mergeCommandTimeout)
	defer cancel()
	state, known := mergeStateForTargets(gitCtx, prep, branchRef, base)
	if !known {
		return mergeCacheEntry{}, false
	}
	return mergeCacheEntry{
		state:      state,
		branchOID:  branchOID,
		targetOIDs: targetOIDs,
		base:       base,
	}, true
}

// mergeBaseFor resolves a workspace branch's creation point from its reflog
// when Warren did not record one, and caches the result for later refreshes.
func (s *Service) mergeBaseFor(ctx context.Context, repo, branch string) string {
	key := repo + "\x00" + branch
	if base, ok := s.mergeBases.get(key); ok {
		return base
	}
	gitCtx, cancel := context.WithTimeout(ctx, mergeCommandTimeout)
	defer cancel()
	base, _ := git.BranchBase(gitCtx, repo, branch)
	s.mergeBases.set(key, base)
	return base
}

// prepareMergeProject gathers everything one refresh needs for a repository:
// the default branch, the branch currently checked out in each worktree, and
// the OIDs of every local and remote-tracking ref.
func prepareMergeProject(ctx context.Context, repo string) *mergeProject {
	gitCtx, cancel := context.WithTimeout(ctx, mergeCommandTimeout)
	defer cancel()
	defaultName, ok := resolveDefaultBranch(gitCtx, repo)
	if !ok {
		return nil
	}
	worktrees, ok := worktreeBranchMap(gitCtx, repo)
	if !ok {
		return nil
	}
	refs := make(map[string]string)
	output, err := exec.CommandContext(gitCtx, "git", "-C", repo, "for-each-ref",
		"--format=%(refname)%00%(objectname)", "refs/heads", "refs/remotes/origin").Output()
	if err != nil {
		return nil
	}
	for _, line := range strings.Split(string(output), "\n") {
		parts := strings.SplitN(line, "\x00", 2)
		if len(parts) == 2 && parts[0] != "" {
			refs[parts[0]] = parts[1]
		}
	}
	return &mergeProject{
		repo:        repo,
		defaultName: defaultName,
		worktrees:   worktrees,
		refs:        refs,
	}
}

// mergeStateForTargets reports whether the branch carries no changes that are
// missing from the default branch, and whether that could be determined. A
// branch with no commits of its own is never merged, even though it has no
// diff against the default branch. Squash and rebase merges are recognized
// even though the original commits are not ancestors of main: instead of
// comparing history, every path the branch changed since its base is compared
// against the default branch, so the branch only counts as merged when the
// default branch already contains identical content for those paths. Both the
// local and remote-tracking default refs are checked: a local merge that was
// not pushed yet and a remote merge that was not fetched yet are both
// recognized.
func mergeStateForTargets(ctx context.Context, prep *mergeProject, branchRef, base string) (api.MergeState, bool) {
	checked := false
	for _, target := range []string{
		"refs/heads/" + prep.defaultName,
		"refs/remotes/origin/" + prep.defaultName,
	} {
		if prep.refs[target] == "" {
			continue
		}
		merged, known := git.MergedIntoTarget(ctx, prep.repo, target, branchRef, base)
		if known && merged {
			return api.MergeStateMerged, true
		}
		if known {
			checked = true
		}
		// Any other failure (missing branch, corrupt object, timeout) is
		// inconclusive for this target; another lineage may still answer.
	}
	if checked {
		return api.MergeStateUnmerged, true
	}
	return "", false
}

// resolveDefaultBranch returns the project's default branch name. It prefers
// the remote HEAD symref (what the hosting platform declares as default),
// then falls back to local main and master. The returned name is the short
// branch name, e.g. "main".
func resolveDefaultBranch(ctx context.Context, repo string) (string, bool) {
	gitCtx, cancel := context.WithTimeout(ctx, mergeCommandTimeout)
	defer cancel()
	if output, err := exec.CommandContext(gitCtx, "git", "-C", repo,
		"symbolic-ref", "--quiet", "refs/remotes/origin/HEAD").Output(); err == nil {
		ref := strings.TrimSpace(string(output))
		if name := strings.TrimPrefix(ref, "refs/remotes/origin/"); name != ref && name != "" && name != "HEAD" {
			if exec.CommandContext(gitCtx, "git", "-C", repo, "show-ref",
				"--verify", "--quiet", "refs/remotes/origin/"+name).Run() == nil {
				return name, true
			}
		}
	}
	for _, name := range []string{"main", "master"} {
		if exec.CommandContext(gitCtx, "git", "-C", repo, "show-ref",
			"--verify", "--quiet", "refs/heads/"+name).Run() == nil {
			return name, true
		}
	}
	return "", false
}

// worktreeBranchMap maps every registered worktree path to the short branch
// name it currently has checked out. Detached worktrees and entries without a
// branch are omitted, so callers treat them as unknown.
func worktreeBranchMap(ctx context.Context, repo string) (map[string]string, bool) {
	output, err := exec.CommandContext(ctx, "git", "-C", repo,
		"worktree", "list", "--porcelain").Output()
	if err != nil {
		return nil, false
	}
	result := make(map[string]string)
	var path string
	for _, line := range strings.Split(string(output), "\n") {
		switch {
		case strings.HasPrefix(line, "worktree "):
			path = strings.TrimSpace(strings.TrimPrefix(line, "worktree "))
		case strings.HasPrefix(line, "branch "):
			ref := strings.TrimSpace(strings.TrimPrefix(line, "branch "))
			if name := strings.TrimPrefix(ref, "refs/heads/"); name != ref && path != "" {
				result[worktreePathKey(path)] = name
			}
		}
	}
	return result, true
}

// worktreePathKey normalizes a worktree path so paths reached through a
// symlink (for example /var vs /private/var on macOS) compare equal to the
// canonical path git reports.
func worktreePathKey(path string) string {
	if resolved, err := filepath.EvalSymlinks(path); err == nil {
		return resolved
	}
	absolute, err := filepath.Abs(path)
	if err != nil {
		return filepath.Clean(path)
	}
	return filepath.Clean(absolute)
}
