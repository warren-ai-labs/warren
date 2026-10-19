package agent

import (
	"context"
	"database/sql"
	"encoding/json"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	_ "github.com/ncruces/go-sqlite3/driver"
)

// TestRealCodexThreadNames checks the Codex title lookup against this machine's
// own rollout files and thread stores.
//
// Unit fixtures prove the query shape; only real rollouts prove that the Codex
// home is derived from the path the watcher is given (including a profile whose
// home is a subdirectory of CODEX_HOME), that the store really holds a generated
// name for a CLI-launched thread, and that the lookup reports exactly what Codex
// stored -- including the empty name of a thread nobody named. Run with:
//
//	go test ./Headless/internal/agent/ -run RealCodexThreadNames -v -tags=realdata
//
// Skipped by default so the suite stays hermetic.
func TestRealCodexThreadNames(t *testing.T) {
	if os.Getenv("WARREN_TITLE_REALDATA") == "" {
		t.Skip("set WARREN_TITLE_REALDATA=1 to check against local Codex state")
	}
	home, err := os.UserHomeDir()
	if err != nil {
		t.Skip("no home directory")
	}
	codexHome := filepath.Join(home, ".codex")
	root := filepath.Join(codexHome, "sessions")
	if _, err := os.Stat(root); err != nil {
		t.Skipf("no Codex sessions at %s", root)
	}
	checked, named, profiles := 0, 0, 0
	for _, walkRoot := range append([]string{root}, codexProfileSessionRoots(root)...) {
		if walkRoot != root {
			profiles++
		}
		_ = filepath.Walk(walkRoot, func(path string, info os.FileInfo, err error) error {
			if err != nil || info.IsDir() || !strings.HasSuffix(path, ".jsonl") {
				return nil
			}
			threadID := codexThreadIDFromTranscriptPath(path)
			if threadID == "" {
				return nil
			}
			derived := codexHomeFromTranscriptPath(path)
			stored, known := codexStoredName(t, derived, threadID)
			if !known {
				return nil
			}
			checked++
			if stored != "" {
				named++
			}
			if got := readCodexThreadName(derived, threadID); got != stored {
				t.Errorf("readCodexThreadName(%q) as home %q = %q, want %q", path, derived, got, stored)
			}
			return nil
		})
	}
	t.Logf("checked %d rollouts across %d profile roots, %d named by Codex", checked, profiles, named)
	if checked == 0 {
		t.Skip("no rollout thread has a row in the local thread store")
	}
}

// TestRealOpenCodeSessionTitles checks the OpenCode title lookup against this
// machine's own provider database. Only real data proves the subagent rule:
// OpenCode titles a child session after the delegated task, and those names must
// never become a Warren Session name. Run with:
//
//	go test ./Headless/internal/agent/ -run RealOpenCodeSessionTitles -v -tags=realdata
//
// Skipped by default so the suite stays hermetic.
func TestRealOpenCodeSessionTitles(t *testing.T) {
	if os.Getenv("WARREN_TITLE_REALDATA") == "" {
		t.Skip("set WARREN_TITLE_REALDATA=1 to check against the local OpenCode database")
	}
	reader := sqliteOpenCodeReader{databasePath: OpenCodeDatabasePath("")}
	top := openCodeSessions(t, "")
	child := openCodeSessions(t, "child")
	if len(top) == 0 && len(child) == 0 {
		t.Skip("no local OpenCode sessions")
	}
	ctx := context.Background()
	checked, named := 0, 0
	for _, row := range top {
		got, err := reader.ReadSessionTitle(ctx, row.id)
		if err != nil {
			t.Fatalf("ReadSessionTitle(%s): %v", row.id, err)
		}
		want := row.title
		if openCodePlaceholderTitle(want) {
			want = ""
		}
		checked++
		if got != want {
			t.Errorf("ReadSessionTitle(%q) = %q, want %q", row.id, got, want)
		}
		if got != "" {
			named++
		}
	}
	for _, row := range child {
		got, err := reader.ReadSessionTitle(ctx, row.id)
		if err != nil {
			t.Fatalf("ReadSessionTitle(%s): %v", row.id, err)
		}
		checked++
		if got != "" {
			t.Errorf("subagent session %q reported the title %q, want none", row.id, got)
		}
	}
	t.Logf("checked %d OpenCode sessions (%d top-level named, %d subagent)", checked, named, len(child))
}

type openCodeTitleRow struct{ id, title string }

// openCodeSessions lists sessions of one relationship from the local OpenCode
// database: "" for top-level rows, "child" for subagent rows.
func openCodeSessions(t *testing.T, relationship string) []openCodeTitleRow {
	t.Helper()
	path := OpenCodeDatabasePath("")
	if path == "" {
		return nil
	}
	db, err := openOpenCodeSQLite(path)
	if err != nil {
		t.Skipf("open %s: %v", path, err)
	}
	defer db.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if !sqliteTableExists(ctx, db, "session") {
		return nil
	}
	clause := "parent_id IS NULL OR parent_id = ''"
	if relationship == "child" {
		clause = "parent_id IS NOT NULL AND parent_id != ''"
	}
	rows, err := db.QueryContext(ctx, "SELECT id, coalesce(title, '') FROM session WHERE "+clause)
	if err != nil {
		t.Skipf("query %s: %v", path, err)
	}
	defer rows.Close()
	var result []openCodeTitleRow
	for rows.Next() {
		var row openCodeTitleRow
		if err := rows.Scan(&row.id, &row.title); err != nil {
			continue
		}
		result = append(result, row)
	}
	return result
}

// TestRealOpenCodeRootBindings checks the child-session rule against this
// machine's own OpenCode database: every real delegated session must resolve to
// the root conversation that owns it, and discovery must never offer one.
//
// Skipped by default so the suite stays hermetic.
func TestRealOpenCodeRootBindings(t *testing.T) {
	if os.Getenv("WARREN_TITLE_REALDATA") == "" {
		t.Skip("set WARREN_TITLE_REALDATA=1 to check against the local OpenCode database")
	}
	children := openCodeSessions(t, "child")
	if len(children) == 0 {
		t.Skip("no local OpenCode child sessions")
	}
	finder := DefaultFinder{}
	ctx := context.Background()
	for _, row := range children {
		want := realOpenCodeRoot(t, row.id)
		binding, err := finder.FindBindingBySessionID(ctx, "warren-probe", "", row.id)
		if err != nil {
			t.Fatalf("FindBindingBySessionID(%s): %v", row.id, err)
		}
		if binding == nil {
			t.Errorf("FindBindingBySessionID(%s) returned no binding, want root %s", row.id, want)
			continue
		}
		if binding.SessionID != want {
			t.Errorf("FindBindingBySessionID(%s) = %s, want the root %s", row.id, binding.SessionID, want)
		}
	}
	t.Logf("resolved %d real child sessions to their root conversations", len(children))
}

// realOpenCodeRoot follows parent_id to the conversation that owns a session.
func realOpenCodeRoot(t *testing.T, sessionID string) string {
	t.Helper()
	path := OpenCodeDatabasePath("")
	db, err := openOpenCodeSQLite(path)
	if err != nil {
		t.Skipf("open %s: %v", path, err)
	}
	defer db.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	current := sessionID
	for depth := 0; depth < 64; depth++ {
		var parent sql.NullString
		if err := db.QueryRowContext(ctx, "SELECT parent_id FROM session WHERE id = ?", current).Scan(&parent); err != nil {
			break
		}
		parentID := strings.TrimSpace(parent.String)
		if parentID == "" {
			break
		}
		current = parentID
	}
	return current
}

// codexStoredName returns the name one Codex home holds for a thread, and
// whether the store knows the thread at all.
func codexStoredName(t *testing.T, home, threadID string) (string, bool) {
	t.Helper()
	path := codexStateDBPath(home)
	if path == "" {
		return "", false
	}
	uri := url.URL{Scheme: "file", Path: filepath.ToSlash(path), RawQuery: "mode=ro"}
	db, err := sql.Open("sqlite3", uri.String())
	if err != nil {
		t.Skipf("open %s: %v", path, err)
	}
	defer db.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	var name sql.NullString
	err = db.QueryRowContext(ctx, "SELECT name FROM threads WHERE id = ?", threadID).Scan(&name)
	if err != nil {
		return "", false
	}
	return strings.TrimSpace(name.String), true
}

// TestRealClaudeSessionTitles checks the Claude title record against this
// machine's own transcripts, including the subagent rule: Claude writes a
// conversation name only for the session it owns, never for a delegated child,
// and a child transcript must therefore report no title.
//
// Skipped by default so the suite stays hermetic.
func TestRealClaudeSessionTitles(t *testing.T) {
	if os.Getenv("WARREN_TITLE_REALDATA") == "" {
		t.Skip("set WARREN_TITLE_REALDATA=1 to check against local Claude transcripts")
	}
	home, err := os.UserHomeDir()
	if err != nil {
		t.Skip("no home directory")
	}
	root := filepath.Join(home, ".claude", "projects")
	if _, err := os.Stat(root); err != nil {
		t.Skipf("no Claude transcripts at %s", root)
	}
	main, subagent, withTitle := 0, 0, 0
	_ = filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
		if err != nil || info.IsDir() || !strings.HasSuffix(path, ".jsonl") {
			return nil
		}
		// The expected name is the last ai-title record in the file, which is
		// what a replay of the same lines must reproduce.
		raw, readErr := os.ReadFile(path)
		if readErr != nil {
			return nil
		}
		want := lastClaudeTitle(string(raw))
		parser := newClaudeParser(64 * 1024)
		for _, line := range strings.Split(string(raw), "\n") {
			if strings.TrimSpace(line) == "" {
				continue
			}
			parser.Parse([]byte(line))
		}
		got := parser.TakeTitle()
		isSubagent := strings.Contains(path, string(filepath.Separator)+"subagents"+string(filepath.Separator))
		if isSubagent {
			subagent++
			if got != "" {
				t.Errorf("subagent transcript %q reported the title %q, want none", path, got)
			}
			return nil
		}
		main++
		if want != "" {
			withTitle++
		}
		if got != want {
			t.Errorf("claude transcript %q reported the title %q, want %q", path, got, want)
		}
		return nil
	})
	t.Logf("checked %d Claude session transcripts (%d named) and %d subagent transcripts", main, withTitle, subagent)
}

// lastClaudeTitle returns the newest ai-title name in a transcript.
func lastClaudeTitle(raw string) string {
	title := ""
	for _, line := range strings.Split(raw, "\n") {
		var record struct {
			Type    string `json:"type"`
			AITitle string `json:"aiTitle"`
		}
		if json.Unmarshal([]byte(line), &record) != nil || record.Type != "ai-title" {
			continue
		}
		if trimmed := strings.TrimSpace(record.AITitle); trimmed != "" {
			title = trimmed
		}
	}
	return title
}
