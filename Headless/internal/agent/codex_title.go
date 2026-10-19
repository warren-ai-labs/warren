package agent

import (
	"context"
	"database/sql"
	"net/url"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	_ "github.com/ncruces/go-sqlite3/driver"
)

// readCodexThreadName returns the name Codex generated for one thread. Codex
// keeps that name outside the rollout, in the thread store beside its sessions
// tree, so the watched transcript alone cannot provide it. A store that has no
// name for the thread means Codex never named it, and the Host's own title
// request covers that conversation.
//
// Codex's session_index.jsonl is deliberately not consulted. On this machine
// every name it holds is already in the thread store, plus six stale rows whose
// names the store dropped and whose text is visibly truncated; the store is the
// authority and a stale copy must not resurrect a withdrawn name.
func readCodexThreadName(home, threadID string) string {
	threadID = strings.TrimSpace(threadID)
	if threadID == "" {
		return ""
	}
	home = firstNonEmpty(home, CodexHome())
	if home == "" {
		return ""
	}
	path := codexStateDBPath(home)
	if path == "" {
		return ""
	}
	// The store has a live writer, so the reader is opened read-only with a
	// bounded busy timeout, and query_only protects against a future accidental
	// mutation. An unknown schema fails the query on purpose: a conversation
	// nobody can read a name for is still named by the Host's own request.
	uri := url.URL{
		Scheme:   "file",
		Path:     filepath.ToSlash(path),
		RawQuery: "mode=ro&_pragma=busy_timeout(1000)",
	}
	db, err := sql.Open("sqlite3", uri.String())
	if err != nil {
		return ""
	}
	defer db.Close()
	db.SetMaxOpenConns(1)
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if _, err := db.ExecContext(ctx, "PRAGMA query_only = ON"); err != nil {
		return ""
	}
	var name sql.NullString
	// thread_source marks the subagent threads a Codex multi-agent run spawns.
	// Their name describes the delegated task, never the conversation a Warren
	// Session is showing.
	err = db.QueryRowContext(ctx,
		"SELECT name FROM threads WHERE id = ? AND (thread_source IS NULL OR thread_source != 'subagent')",
		threadID,
	).Scan(&name)
	if err != nil || !name.Valid {
		return ""
	}
	return strings.TrimSpace(name.String)
}

// codexStateDBPath returns the newest Codex thread store in one home. Codex
// versions the filename (state_5.sqlite), so the highest generation wins rather
// than a hardcoded one. Backup copies (state_5.sqlite.backup.N) are not
// database files and the suffix pattern excludes them.
func codexStateDBPath(home string) string {
	matches, err := filepath.Glob(filepath.Join(home, "state_*.sqlite"))
	if err != nil || len(matches) == 0 {
		return ""
	}
	sort.Slice(matches, func(i, j int) bool {
		return codexStateDBGeneration(matches[i]) < codexStateDBGeneration(matches[j])
	})
	if generation := codexStateDBGeneration(matches[len(matches)-1]); generation < 0 {
		return ""
	}
	return matches[len(matches)-1]
}

func codexStateDBGeneration(path string) int {
	stem := strings.TrimSuffix(filepath.Base(path), ".sqlite")
	value, err := strconv.Atoi(strings.TrimPrefix(stem, "state_"))
	if err != nil {
		return -1
	}
	return value
}
