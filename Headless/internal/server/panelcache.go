package server

import (
	"container/list"
	"sync"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

const (
	panelCacheCapacity   = 16
	panelRevalidateAfter = 5 * time.Minute
	// The working tree changes under Agents and editors that never go through
	// Warren's Git commands, so the local part of a panel (status, log,
	// branches) is re-read after a few seconds. The remote part (fetch and the
	// pull request lookup, which goes over the network) keeps the longer
	// panelRevalidateAfter.
	panelLocalRevalidateAfter = 2 * time.Second
	panelRevalidateTimeout    = 30 * time.Second
	// A panel load may include a remote fetch plus several repository scans.
	// It must outlive the WebSocket request that started it so a reconnect does
	// not publish a canceled result to the next request.
	panelLoadTimeout = 90 * time.Second
)

type panelCacheEntry struct {
	key      string
	panel    api.GitPanel
	loadedAt time.Time
	// remoteLoadedAt is when the fetch and pull request lookup last ran;
	// a local-only refresh advances loadedAt but not this.
	remoteLoadedAt time.Time
	revalidating   bool
}

// panelRevalidation says how much of a cached panel to re-read.
type panelRevalidation int

const (
	panelRevalidateNone panelRevalidation = iota
	panelRevalidateLocal
	panelRevalidateFull
)

// panelCache is an LRU cache of git panel snapshots keyed by workspace ID.
// Entries never expire on their own; stale-while-revalidate keeps them fresh:
// a hit returns immediately while the cache re-queries the workspace in the
// background once it is older than panelRevalidateAfter. Only requested
// workspaces are ever cached.
type panelCache struct {
	mu          sync.Mutex
	cap         int
	list        *list.List
	index       map[string]*list.Element
	generations map[string]uint64
}

func newPanelCache(capacity int) *panelCache {
	return &panelCache{
		cap:         capacity,
		list:        list.New(),
		index:       make(map[string]*list.Element),
		generations: make(map[string]uint64),
	}
}

func (c *panelCache) Get(key string) (api.GitPanel, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	element, ok := c.index[key]
	if !ok {
		return api.GitPanel{}, false
	}
	entry := element.Value.(*panelCacheEntry)
	c.list.MoveToFront(element)
	return entry.panel, true
}

func (c *panelCache) Set(key string, panel api.GitPanel) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.setLocked(key, panel)
}

func (c *panelCache) SetIfVersion(key string, panel api.GitPanel, version uint64) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.generations[key] != version {
		return false
	}
	c.setLocked(key, panel)
	return true
}

// SetLocalIfVersion stores a panel re-read without its remote part. The
// pull request state and the remote clock carry over from the cached entry.
func (c *panelCache) SetLocalIfVersion(key string, panel api.GitPanel, version uint64) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.generations[key] != version {
		return false
	}
	element, ok := c.index[key]
	if !ok {
		return false
	}
	entry := element.Value.(*panelCacheEntry)
	panel.PullRequest = entry.panel.PullRequest
	panel.PullRequestError = entry.panel.PullRequestError
	entry.panel = panel
	entry.loadedAt = time.Now()
	c.list.MoveToFront(element)
	return true
}

func (c *panelCache) setLocked(key string, panel api.GitPanel) {
	now := time.Now()
	if element, ok := c.index[key]; ok {
		entry := element.Value.(*panelCacheEntry)
		entry.panel = panel
		entry.loadedAt = now
		entry.remoteLoadedAt = now
		c.list.MoveToFront(element)
		return
	}
	entry := &panelCacheEntry{key: key, panel: panel, loadedAt: now, remoteLoadedAt: now}
	element := c.list.PushFront(entry)
	c.index[key] = element
	if c.list.Len() > c.cap {
		c.remove(c.list.Back())
	}
}

func (c *panelCache) Version(key string) uint64 {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.generations[key]
}

// ShouldRevalidate reports whether key needs a background refresh and, if so,
// marks it as revalidating so concurrent hits do not start duplicate
// refreshes. The marker is cleared by FinishRevalidate.
func (c *panelCache) ShouldRevalidate(key string, after time.Duration) bool {
	return c.Revalidation(key, after, after) != panelRevalidateNone
}

// Revalidation reports how much of key needs a background refresh: all of it
// once the remote part is older than remoteAfter, the local part once the
// panel is older than localAfter. Like ShouldRevalidate it marks the entry so
// concurrent hits do not start duplicate refreshes.
func (c *panelCache) Revalidation(key string, remoteAfter, localAfter time.Duration) panelRevalidation {
	c.mu.Lock()
	defer c.mu.Unlock()
	element, ok := c.index[key]
	if !ok {
		return panelRevalidateNone
	}
	entry := element.Value.(*panelCacheEntry)
	if entry.revalidating {
		return panelRevalidateNone
	}
	kind := panelRevalidateNone
	switch {
	case time.Since(entry.remoteLoadedAt) >= remoteAfter:
		kind = panelRevalidateFull
	case time.Since(entry.loadedAt) >= localAfter:
		kind = panelRevalidateLocal
	default:
		return panelRevalidateNone
	}
	entry.revalidating = true
	return kind
}

func (c *panelCache) FinishRevalidate(key string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if element, ok := c.index[key]; ok {
		element.Value.(*panelCacheEntry).revalidating = false
	}
}

// Remove drops the entry and bumps its generation so in-flight loads and
// background refreshes started before the removal cannot write stale data
// back into the cache.
func (c *panelCache) Remove(key string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if element, ok := c.index[key]; ok {
		c.remove(element)
	}
	c.generations[key]++
}

func (c *panelCache) remove(element *list.Element) {
	delete(c.index, element.Value.(*panelCacheEntry).key)
	c.list.Remove(element)
}

// panelLoad deduplicates concurrent synchronous panel loads for the same
// workspace: only the first caller runs the query and the others wait for the
// same result.
type panelLoad struct {
	mu      sync.Mutex
	pending map[string]*panelLoadCall
}

type panelLoadCall struct {
	done  chan struct{}
	panel api.GitPanel
	err   error
}

func newPanelLoad() *panelLoad {
	return &panelLoad{pending: make(map[string]*panelLoadCall)}
}

func (l *panelLoad) Do(key string, load func() (api.GitPanel, error)) (api.GitPanel, error) {
	l.mu.Lock()
	if call, ok := l.pending[key]; ok {
		l.mu.Unlock()
		<-call.done
		return call.panel, call.err
	}
	call := &panelLoadCall{done: make(chan struct{})}
	l.pending[key] = call
	l.mu.Unlock()

	call.panel, call.err = load()
	close(call.done)

	l.mu.Lock()
	delete(l.pending, key)
	l.mu.Unlock()
	return call.panel, call.err
}
