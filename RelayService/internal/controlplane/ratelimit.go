package controlplane

import (
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
)

const maxRateLimiterEntries = 4096

type rateLimitEntry struct {
	started time.Time
	count   int
}

// rateLimiter is a bounded fixed-window limiter. A call may provide multiple
// keys (for example, the caller IP and Host ID); all counters are checked
// before any are incremented so a rejected request does not consume partial
// quota.
type rateLimiter struct {
	mu      sync.Mutex
	entries map[string]rateLimitEntry
	limit   int
	window  time.Duration
	now     func() time.Time
}

func newRateLimiter(limit int, window time.Duration) *rateLimiter {
	return &rateLimiter{
		entries: make(map[string]rateLimitEntry),
		limit:   limit,
		window:  window,
		now:     time.Now,
	}
}

func (limiter *rateLimiter) allow(keys ...string) bool {
	if limiter == nil || limiter.limit <= 0 {
		return true
	}
	now := limiter.now()
	unique := make([]string, 0, len(keys))
	seen := make(map[string]struct{}, len(keys))
	for _, key := range keys {
		if key == "" {
			continue
		}
		if _, ok := seen[key]; ok {
			continue
		}
		seen[key] = struct{}{}
		unique = append(unique, key)
	}
	if len(unique) == 0 {
		return true
	}

	limiter.mu.Lock()
	defer limiter.mu.Unlock()
	for _, key := range unique {
		entry, ok := limiter.entries[key]
		if !ok || !now.Before(entry.started.Add(limiter.window)) {
			continue
		}
		if entry.count >= limiter.limit {
			return false
		}
	}
	for _, key := range unique {
		entry := limiter.entries[key]
		if entry.started.IsZero() || !now.Before(entry.started.Add(limiter.window)) {
			entry = rateLimitEntry{started: now}
		}
		entry.count++
		limiter.entries[key] = entry
	}
	limiter.prune(now)
	return true
}

func (limiter *rateLimiter) prune(now time.Time) {
	if len(limiter.entries) <= maxRateLimiterEntries {
		return
	}
	for key, entry := range limiter.entries {
		if !now.Before(entry.started.Add(limiter.window)) {
			delete(limiter.entries, key)
		}
	}
	for key := range limiter.entries {
		if len(limiter.entries) <= maxRateLimiterEntries {
			break
		}
		delete(limiter.entries, key)
	}
}

func requestClientIP(request *http.Request) string {
	if request == nil {
		return "unknown"
	}
	remote := strings.TrimSpace(request.RemoteAddr)
	if host, _, err := net.SplitHostPort(remote); err == nil && host != "" {
		return host
	}
	if remote != "" && !strings.Contains(remote, ":") {
		return remote
	}
	return "unknown"
}

func writeRateLimit(response http.ResponseWriter, window time.Duration) {
	seconds := int64(window / time.Second)
	if window%time.Second != 0 {
		seconds++
	}
	if seconds < 1 {
		seconds = 1
	}
	response.Header().Set("Retry-After", strconv.FormatInt(seconds, 10))
	http.Error(response, "rate limit exceeded", http.StatusTooManyRequests)
}
