package agent

import (
	"context"
	"database/sql"
	"net/url"
	"path/filepath"
	"strings"
	"time"
)

// SetTitleSource tells the parser which conversation's name to read. The
// transcript path carries both: agy keeps one summaries database beside brain/,
// and the conversation ID is the directory above its generated logs.
func (p *antigravityParser) SetTitleSource(home, conversationID string) {
	p.titleHome = strings.TrimSpace(home)
	p.titleConversation = strings.TrimSpace(conversationID)
}

// TakeTitle returns the name agy wrote for this conversation, once. agy names
// its own conversation in conversation_summaries.title; until that row exists
// the parser reports nothing and Warren's own title request remains the
// fallback.
func (p *antigravityParser) TakeTitle() string {
	if p.titleCaptured {
		return ""
	}
	if p.titleValue == "" {
		p.titleValue = readAntigravityConversationTitle(p.titleHome, p.titleConversation)
		if p.titleValue == "" {
			return ""
		}
	}
	p.titleCaptured = true
	return p.titleValue
}

// antigravityTitleSourceFromTranscriptPath returns the product home and
// conversation ID a transcript path belongs to. A path that is not agy's
// generated transcript shape yields empty values instead of guessing.
func antigravityTitleSourceFromTranscriptPath(path string) (home, conversationID string) {
	logs := filepath.Dir(filepath.Clean(path))
	generated := filepath.Dir(logs)
	conversationDir := filepath.Dir(generated)
	brain := filepath.Dir(conversationDir)
	if filepath.Base(logs) != "logs" ||
		filepath.Base(generated) != ".system_generated" ||
		filepath.Base(brain) != "brain" {
		return "", ""
	}
	return filepath.Dir(brain), filepath.Base(conversationDir)
}

// readAntigravityConversationTitle reads the name agy stored for one
// conversation. The database has a live writer, so it is opened read-only with
// a bounded busy timeout; an unreadable row or schema means agy has not named
// the conversation yet, and the caller keeps its own fallback.
func readAntigravityConversationTitle(home, conversationID string) string {
	if home == "" || conversationID == "" {
		return ""
	}
	path := filepath.Join(home, "conversation_summaries.db")
	if !regularFileExists(path) {
		return ""
	}
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
	var title sql.NullString
	if err := db.QueryRowContext(ctx,
		"SELECT title FROM conversation_summaries WHERE conversation_id = ?",
		conversationID,
	).Scan(&title); err != nil || !title.Valid {
		return ""
	}
	return strings.TrimSpace(title.String)
}
