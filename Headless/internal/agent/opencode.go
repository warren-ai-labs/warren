package agent

// OpenCode integration is deliberately kept behind a small reader/tailer
// boundary. The current provider store is SQLite. Warren never writes that
// store; it projects read-only snapshots into a private JSONL cache that the
// normal transcript watcher can consume.

import (
	"bufio"
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
	_ "github.com/ncruces/go-sqlite3/driver"
)

const (
	openCodeProvider     = "opencode"
	openCodeSQLite       = "sqlite"
	openCodeCacheDirName = "opencode-cache"
	// Mutable OpenCode rows are mirrored as complete snapshots. Compacting at
	// a bounded line/byte count keeps long replies from turning the cache into
	// an O(n²) append-only history while retaining the latest state for restart
	// recovery.
	openCodeCacheCompactionLines = 256
	openCodeCacheCompactionBytes = 8 * 1024 * 1024
)

var openCodeSessionReuseFlags = map[string]bool{
	"--continue": true,
	"-c":         true,
	"--session":  true,
	"-s":         true,
	"--fork":     true,
}

// ValidateOpenCodeCommand keeps every session.create caller from selecting a
// provider conversation that Warren did not create. The CLI performs the
// same validation for agent create, but Desktop and Web launch presets call
// session.create directly and must receive the invariant at the Host boundary.
func ValidateOpenCodeCommand(command string) error {
	if err := validateOpenCodeShellSyntax(command); err != nil {
		return err
	}
	tokens, err := splitOpenCodeCommandWords(command)
	if err != nil {
		return fmt.Errorf("invalid OpenCode command: %w", err)
	}
	if len(tokens) == 0 {
		return errors.New("OpenCode command must not be empty")
	}
	for index := 1; index < len(tokens); index++ {
		flag := tokens[index]
		if equal := strings.IndexByte(flag, '='); equal >= 0 {
			flag = flag[:equal]
		}
		if openCodeSessionReuseFlags[flag] {
			return errors.New("OpenCode command must start a new session; session resume flags are not supported")
		}
	}
	return nil
}

func validateOpenCodeShellSyntax(command string) error {
	inSingle, inDouble, escaped := false, false, false
	for _, char := range command {
		if escaped {
			escaped = false
			continue
		}
		if inSingle {
			if char == '\'' {
				inSingle = false
			}
			continue
		}
		if inDouble {
			switch char {
			case '\\':
				escaped = true
			case '"':
				inDouble = false
			case '`', '$':
				return errors.New("OpenCode command must not contain shell operators or substitutions")
			}
			continue
		}
		switch char {
		case '\\':
			escaped = true
		case '\'':
			inSingle = true
		case '"':
			inDouble = true
		case ';', '&', '|', '>', '<', '`', '(', ')', '\n', '$':
			return errors.New("OpenCode command must be an executable with options; shell operators and substitutions are not supported")
		}
	}
	if escaped {
		return errors.New("OpenCode command has a trailing escape")
	}
	if inSingle || inDouble {
		return errors.New("OpenCode command has an unterminated quote")
	}
	return nil
}

func splitOpenCodeCommandWords(command string) ([]string, error) {
	var words []string
	var current strings.Builder
	inSingle, inDouble, escaped, started := false, false, false, false
	flush := func() {
		if started {
			words = append(words, current.String())
			current.Reset()
			started = false
		}
	}
	for _, char := range command {
		switch {
		case escaped:
			current.WriteRune(char)
			escaped = false
			started = true
		case inSingle:
			if char == '\'' {
				inSingle = false
			} else {
				current.WriteRune(char)
			}
			started = true
		case inDouble:
			switch char {
			case '"':
				inDouble = false
			case '\\':
				escaped = true
			default:
				current.WriteRune(char)
			}
			started = true
		default:
			switch {
			case char == '\\':
				escaped = true
				started = true
			case char == '\'':
				inSingle = true
				started = true
			case char == '"':
				inDouble = true
				started = true
			case char == ' ' || char == '\t' || char == '\r' || char == '\n':
				flush()
			default:
				current.WriteRune(char)
				started = true
			}
		}
	}
	if escaped {
		return nil, errors.New("trailing escape")
	}
	if inSingle || inDouble {
		return nil, errors.New("unterminated quote")
	}
	flush()
	return words, nil
}

// OpenCodeBinding is the immutable identity used by one Warren session. A
// binding points at one OpenCode conversation, not at whichever conversation
// happens to be newest in the same checkout on the next poll.
type OpenCodeBinding struct {
	Provider      string `json:"provider"`
	SessionID     string `json:"sessionId"`
	Backend       string `json:"backend"`
	DataRoot      string `json:"dataRoot,omitempty"`
	DatabasePath  string `json:"databasePath,omitempty"`
	CachePath     string `json:"cachePath"`
	WorkspacePath string `json:"workspacePath,omitempty"`
}

func (b OpenCodeBinding) Valid() bool {
	if b.Provider != openCodeProvider || b.SessionID == "" {
		return false
	}
	return b.Backend == openCodeSQLite && b.DatabasePath != ""
}

// BindingFinder is an additive interface. Finder remains source-compatible
// with the Codex/Claude file finder, while OpenCode callers can obtain the
// complete backend/session binding needed for a stable tailer.
type BindingFinder interface {
	FindBinding(ctx context.Context, warrenSessionID, kind, workspacePath string, after time.Time) (*OpenCodeBinding, error)
	FindBindingBySessionID(ctx context.Context, warrenSessionID, workspacePath, opencodeSessionID string) (*OpenCodeBinding, error)
}

// BindingCandidatesFinder is an optional extension used when more than one
// OpenCode session is created in the same workspace at nearly the same time.
// A caller can skip candidates already bound to another Warren session instead
// of repeatedly selecting the same earliest row.
type BindingCandidatesFinder interface {
	FindBindings(ctx context.Context, warrenSessionID, kind, workspacePath string, after time.Time) ([]*OpenCodeBinding, error)
}

// OpenCodeDataRoot returns OpenCode's application data directory. The explicit
// override is intended for tests and embedders. Warren's own override is
// deliberately namespaced so it cannot be mistaken for an OpenCode setting
// (the provider currently follows XDG_DATA_HOME and platform defaults).
func OpenCodeDataRoot(override string) string {
	if strings.TrimSpace(override) != "" {
		return filepath.Clean(override)
	}
	if value := strings.TrimSpace(os.Getenv("WARREN_OPENCODE_DATA_DIR")); value != "" {
		return filepath.Clean(value)
	}
	if value := strings.TrimSpace(os.Getenv("XDG_DATA_HOME")); value != "" {
		return filepath.Join(value, "opencode")
	}
	home, _ := os.UserHomeDir()
	if home == "" {
		return ""
	}
	switch runtime.GOOS {
	case "windows":
		local := strings.TrimSpace(os.Getenv("LOCALAPPDATA"))
		if local == "" {
			local = filepath.Join(home, "AppData", "Local")
		}
		return filepath.Join(local, "opencode")
	default:
		return filepath.Join(home, ".local", "share", "opencode")
	}
}

// OpenCodeDatabasePath returns the current SQLite database path.
func OpenCodeDatabasePath(dataRoot string) string {
	if dataRoot == "" {
		dataRoot = OpenCodeDataRoot("")
	}
	if dataRoot == "" {
		return ""
	}
	return filepath.Join(dataRoot, "opencode.db")
}

// OpenCodeCachePath is deterministic across daemon restarts and includes both
// Warren and OpenCode IDs, preventing a /clear or a reused Warren tab from
// consuming another conversation's projection.
func OpenCodeCachePath(warrenSessionID, opencodeSessionID string) string {
	root := filepath.Join(configDir(), openCodeCacheDirName)
	return filepath.Join(root, safeOpenCodeID(warrenSessionID)+"-"+safeOpenCodeID(opencodeSessionID)+".jsonl")
}

func safeOpenCodeID(value string) string {
	original := strings.TrimSpace(value)
	value = original
	if value != "" {
		var builder strings.Builder
		for _, char := range value {
			if (char >= 'a' && char <= 'z') || (char >= 'A' && char <= 'Z') ||
				(char >= '0' && char <= '9') || char == '-' || char == '_' || char == '.' {
				builder.WriteRune(char)
			} else {
				builder.WriteByte('_')
			}
		}
		if result := strings.Trim(builder.String(), "._"); result != "" {
			if result == original {
				return result
			}
			hash := sha256.Sum256([]byte(original))
			return result + "-" + hex.EncodeToString(hash[:4])
		}
	}
	hash := sha256.Sum256([]byte(original))
	return hex.EncodeToString(hash[:8])
}

type openCodeSession struct {
	ID        string `json:"id"`
	ProjectID string `json:"projectID"`
	Directory string `json:"directory"`
	Cwd       string `json:"cwd"`
	Path      struct {
		Cwd  string `json:"cwd"`
		Root string `json:"root"`
	} `json:"path"`
	Time struct {
		Created  int64 `json:"created"`
		Updated  int64 `json:"updated"`
		Archived int64 `json:"archived"`
	} `json:"time"`
}

type openCodeTime struct {
	Created   int64 `json:"created"`
	Completed int64 `json:"completed"`
}

type openCodeMessage struct {
	ID         string          `json:"id"`
	SessionID  string          `json:"sessionID"`
	Role       string          `json:"role"`
	Time       openCodeTime    `json:"time"`
	ModelID    string          `json:"modelID"`
	ProviderID string          `json:"providerID"`
	Finish     string          `json:"finish"`
	Error      json.RawMessage `json:"error"`
	Summary    json.RawMessage `json:"summary"`
}

type openCodeToolState struct {
	Status string          `json:"status"`
	Input  json.RawMessage `json:"input"`
	Output json.RawMessage `json:"output"`
	Error  json.RawMessage `json:"error"`
}

type openCodePart struct {
	ID        string            `json:"id"`
	MessageID string            `json:"messageID,omitempty"`
	Type      string            `json:"type"`
	Text      string            `json:"text,omitempty"`
	CallID    string            `json:"callID,omitempty"`
	Tool      string            `json:"tool,omitempty"`
	State     openCodeToolState `json:"state,omitempty"`
}

// openCodeEnvelope is Warren's private cache record. It intentionally keeps
// the source IDs so updates can be reduced to deltas and safely replayed.
type openCodeEnvelope struct {
	MessageID   string          `json:"messageId"`
	Role        string          `json:"role"`
	Finish      string          `json:"finish,omitempty"`
	ModelID     string          `json:"modelId,omitempty"`
	ProviderID  string          `json:"providerId,omitempty"`
	Time        openCodeTime    `json:"time"`
	Summary     json.RawMessage `json:"summary,omitempty"`
	Error       json.RawMessage `json:"error,omitempty"`
	Parts       []openCodePart  `json:"parts,omitempty"`
	Fingerprint string          `json:"fingerprint,omitempty"`
}

type openCodeSourceMessage struct {
	Message openCodeMessage
	Parts   []openCodePart
	Updated int64
}

type openCodeReader interface {
	ReadMessages(ctx context.Context, sessionID string, updatedSince int64) ([]openCodeSourceMessage, error)
}

type openCodeReaderCloser interface {
	Close() error
}

// DefaultFinder implements the stock Codex/Claude finder and OpenCode's
// current SQLite binding finder. The old Find method remains available for the
// other providers and returns the cache path for OpenCode.
func (f DefaultFinder) FindBinding(ctx context.Context, warrenSessionID, kind, workspacePath string, after time.Time) (*OpenCodeBinding, error) {
	bindings, err := f.FindBindings(ctx, warrenSessionID, kind, workspacePath, after)
	if err != nil || len(bindings) == 0 {
		return nil, err
	}
	return bindings[0], nil
}

func (f DefaultFinder) FindBindings(ctx context.Context, warrenSessionID, kind, workspacePath string, after time.Time) ([]*OpenCodeBinding, error) {
	if strings.ToLower(strings.TrimSpace(kind)) != openCodeProvider {
		return nil, nil
	}
	dataRoot := resolveOpenCodeDataRoot(f.OpenCodeRoot)
	if dataRoot == "" {
		return nil, nil
	}
	if databasePath := OpenCodeDatabasePath(dataRoot); databasePath != "" {
		sessions, err := findSQLiteOpenCodeSessions(ctx, databasePath, workspacePath, after, "")
		if err != nil {
			return nil, err
		}
		bindings := make([]*OpenCodeBinding, 0, len(sessions))
		for _, session := range sessions {
			bindings = append(bindings, newOpenCodeBinding(warrenSessionID, workspacePath, dataRoot, session.ID))
		}
		return bindings, nil
	}
	return nil, nil
}

func (f DefaultFinder) FindBindingBySessionID(ctx context.Context, warrenSessionID, workspacePath, opencodeSessionID string) (*OpenCodeBinding, error) {
	if strings.TrimSpace(opencodeSessionID) == "" {
		return nil, nil
	}
	dataRoot := resolveOpenCodeDataRoot(f.OpenCodeRoot)
	if databasePath := OpenCodeDatabasePath(dataRoot); databasePath != "" {
		if session, err := findSQLiteOpenCodeSession(ctx, databasePath, workspacePath, time.Time{}, opencodeSessionID); err != nil {
			return nil, err
		} else if session != nil {
			return newOpenCodeBinding(warrenSessionID, workspacePath, dataRoot, session.ID), nil
		}
	}
	return nil, nil
}

func newOpenCodeBinding(warrenSessionID, workspacePath, dataRoot, sessionID string) *OpenCodeBinding {
	return &OpenCodeBinding{
		Provider:      openCodeProvider,
		SessionID:     sessionID,
		Backend:       openCodeSQLite,
		DataRoot:      dataRoot,
		DatabasePath:  OpenCodeDatabasePath(dataRoot),
		CachePath:     OpenCodeCachePath(warrenSessionID, sessionID),
		WorkspacePath: workspacePath,
	}
}

func resolveOpenCodeDataRoot(override string) string {
	override = strings.TrimSpace(override)
	if override == "" {
		return OpenCodeDataRoot("")
	}
	override = filepath.Clean(override)
	if filepath.Base(override) == "opencode.db" {
		return filepath.Dir(override)
	}
	return override
}

func findSQLiteOpenCodeSession(ctx context.Context, databasePath, workspacePath string, after time.Time, wantedID string) (*openCodeSession, error) {
	candidates, err := findSQLiteOpenCodeSessions(ctx, databasePath, workspacePath, after, wantedID)
	if err != nil || len(candidates) == 0 {
		return nil, err
	}
	return &candidates[0], nil
}

func findSQLiteOpenCodeSessions(ctx context.Context, databasePath, workspacePath string, after time.Time, wantedID string) ([]openCodeSession, error) {
	if databasePath == "" {
		return nil, nil
	}
	info, err := os.Stat(databasePath)
	if err != nil || info.IsDir() {
		return nil, nil
	}
	db, err := openOpenCodeSQLite(databasePath)
	if err != nil {
		return nil, nil
	}
	defer db.Close()
	if !sqliteTableExists(ctx, db, "session") {
		return nil, nil
	}
	projectWorktree := sqliteProjectWorktree(ctx, db)
	// OpenCode's current schema is intentionally explicit here. Supporting a
	// second schema silently would make a corrupt or old database look valid and
	// could bind a Warren session to the wrong conversation.
	query := `SELECT id, project_id, directory, time_created, time_updated FROM session`
	args := []any{}
	if wantedID != "" {
		query += " WHERE id = ?"
		args = append(args, wantedID)
	}
	rows, err := db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, nil
	}
	defer rows.Close()
	var candidates []openCodeSession
	for rows.Next() {
		var session openCodeSession
		var projectID, directory sql.NullString
		var created, updated sql.NullInt64
		if err := rows.Scan(&session.ID, &projectID, &directory, &created, &updated); err != nil {
			continue
		}
		session.ProjectID = projectID.String
		session.Directory = directory.String
		session.Time.Created = created.Int64
		session.Time.Updated = updated.Int64
		if session.ID == "" {
			continue
		}
		if wantedID == "" {
			if !openCodeSessionMatches(session, workspacePath, projectWorktree) ||
				!openCodeSessionCreatedAfter(session.Time.Created, after) {
				continue
			}
		}
		candidates = append(candidates, session)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	sort.SliceStable(candidates, func(i, j int) bool {
		// The lower bound is captured immediately before Warren launches
		// OpenCode. Select the first session created after that point so two
		// nearly simultaneous Warren launches do not both claim the newest row.
		if !after.IsZero() {
			if candidates[i].Time.Created != candidates[j].Time.Created {
				return candidates[i].Time.Created < candidates[j].Time.Created
			}
			return candidates[i].ID < candidates[j].ID
		}
		left := candidates[i].Time.Updated
		if left == 0 {
			left = candidates[i].Time.Created
		}
		right := candidates[j].Time.Updated
		if right == 0 {
			right = candidates[j].Time.Created
		}
		if left == right {
			return candidates[i].ID < candidates[j].ID
		}
		return left > right
	})
	return candidates, nil
}

func sqliteProjectWorktree(ctx context.Context, db *sql.DB) func(string) string {
	if !sqliteTableExists(ctx, db, "project") {
		return nil
	}
	rows, err := db.QueryContext(ctx, "SELECT id, worktree FROM project")
	if err != nil {
		return nil
	}
	defer rows.Close()
	worktrees := make(map[string]string)
	for rows.Next() {
		var id, worktree sql.NullString
		if err := rows.Scan(&id, &worktree); err != nil || !id.Valid || !worktree.Valid {
			continue
		}
		worktrees[id.String] = worktree.String
	}
	if len(worktrees) == 0 {
		return nil
	}
	return func(projectID string) string { return worktrees[projectID] }
}

func openCodeSessionMatches(session openCodeSession, workspacePath string, projectWorktree func(string) string) bool {
	if workspacePath == "" {
		return true
	}
	for _, candidate := range []string{session.Directory, session.Cwd, session.Path.Cwd, session.Path.Root} {
		if candidate != "" && samePath(candidate, workspacePath) {
			return true
		}
	}
	if projectWorktree != nil && session.ProjectID != "" {
		if candidate := projectWorktree(session.ProjectID); candidate != "" && samePath(candidate, workspacePath) {
			return true
		}
	}
	return false
}

func openCodeMillisTime(value int64) time.Time {
	if value <= 0 {
		return time.Time{}
	}
	return time.UnixMilli(value)
}

func openCodeSessionCreatedAfter(value int64, after time.Time) bool {
	if after.IsZero() {
		return true
	}
	created := openCodeMillisTime(value)
	if created.IsZero() {
		return false
	}
	// OpenCode persists millisecond timestamps while Warren's launch marker
	// carries nanosecond precision. Truncate the lower bound to the provider's
	// precision; otherwise a session created in the same millisecond can be
	// rejected merely because its stored value lost the sub-millisecond tail.
	return !created.Before(after.Truncate(time.Millisecond))
}

func openOpenCodeSQLite(path string) (*sql.DB, error) {
	// OpenCode keeps a live writer open. SQLite URI mode=ro plus a bounded busy
	// timeout ensures a poll can never create or mutate the provider database,
	// and query_only protects Warren if a future reader accidentally executes a
	// mutating statement.
	uri := url.URL{Scheme: "file", Path: filepath.ToSlash(path), RawQuery: "mode=ro&_pragma=busy_timeout(2000)"}
	dsn := uri.String()
	db, err := sql.Open("sqlite3", dsn)
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if err := db.PingContext(ctx); err != nil {
		db.Close()
		return nil, err
	}
	if _, err := db.ExecContext(ctx, "PRAGMA query_only = ON"); err != nil {
		db.Close()
		return nil, err
	}
	return db, nil
}

func sqliteTableExists(ctx context.Context, db *sql.DB, table string) bool {
	var name string
	return db.QueryRowContext(ctx, "SELECT name FROM sqlite_master WHERE type='table' AND name=?", table).Scan(&name) == nil
}

type sqliteOpenCodeReader struct {
	databasePath string
	state        *sqliteReaderState
}

// sqliteReaderState keeps one read-only connection alive between polls. This
// lets PRAGMA data_version cheaply skip a full conversation scan when the
// provider database has not changed; a nil state is used by small fixtures
// that intentionally open a fresh connection for each read.
type sqliteReaderState struct {
	mu              sync.Mutex
	db              *sql.DB
	dataVersion     int64
	versionObserved bool
}

func (r sqliteOpenCodeReader) database(ctx context.Context) (*sql.DB, error) {
	if r.state == nil {
		return openOpenCodeSQLite(r.databasePath)
	}
	r.state.mu.Lock()
	defer r.state.mu.Unlock()
	if r.state.db != nil {
		return r.state.db, nil
	}
	db, err := openOpenCodeSQLite(r.databasePath)
	if err != nil {
		return nil, err
	}
	if err := db.PingContext(ctx); err != nil {
		_ = db.Close()
		return nil, err
	}
	r.state.db = db
	return db, nil
}

func (r sqliteOpenCodeReader) Close() error {
	if r.state == nil {
		return nil
	}
	r.state.mu.Lock()
	db := r.state.db
	r.state.db = nil
	r.state.versionObserved = false
	r.state.mu.Unlock()
	if db == nil {
		return nil
	}
	return db.Close()
}

func (r sqliteOpenCodeReader) databaseChanged(ctx context.Context, db *sql.DB) bool {
	if r.state == nil {
		return true
	}
	var version int64
	if err := db.QueryRowContext(ctx, "PRAGMA data_version").Scan(&version); err != nil {
		r.invalidateVersion()
		return true
	}
	r.state.mu.Lock()
	defer r.state.mu.Unlock()
	changed := !r.state.versionObserved || r.state.dataVersion != version
	r.state.dataVersion = version
	r.state.versionObserved = true
	return changed
}

// invalidateVersion forces the next poll to query the provider again. A
// transient lock, migration, or malformed row must not be hidden forever by
// the data_version fast path after the first failed read.
func (r sqliteOpenCodeReader) invalidateVersion() {
	if r.state == nil {
		return
	}
	r.state.mu.Lock()
	r.state.versionObserved = false
	r.state.mu.Unlock()
}

func (r sqliteOpenCodeReader) ReadMessages(ctx context.Context, sessionID string, updatedSince int64) ([]openCodeSourceMessage, error) {
	db, err := r.database(ctx)
	if err != nil {
		return nil, err
	}
	if r.state == nil {
		defer db.Close()
	}
	if !r.databaseChanged(ctx, db) {
		return nil, nil
	}
	if !sqliteTableExists(ctx, db, "message") || !sqliteTableExists(ctx, db, "part") {
		err := errors.New("OpenCode database is missing message/part tables")
		r.invalidateVersion()
		return nil, err
	}
	// Do not join and GROUP BY m.data here. OpenCode stores the complete user
	// prompt in message.data and a single row can be tens of megabytes. SQLite
	// has to copy every GROUP BY value into a temporary B-tree, which can exhaust
	// the process when several sessions are restored at once. The indexed
	// correlated aggregate preserves the part timestamp without materialising
	// the message payload as a grouping key.
	query := `SELECT m.id, m.session_id, m.time_created, m.time_updated, m.data,
		COALESCE((SELECT MAX(p.time_updated) FROM part AS p WHERE p.message_id = m.id), 0) AS part_time_updated
		FROM message AS m
		WHERE m.session_id = ?`
	args := []any{sessionID}
	if updatedSince > 0 {
		query += ` AND (
			EXISTS (SELECT 1 FROM part AS changed WHERE changed.message_id = m.id AND changed.time_updated >= ?)
			OR m.time_created >= ? OR m.time_updated >= ?
		)`
		args = append(args, updatedSince, updatedSince, updatedSince)
	}
	query += " ORDER BY m.time_created ASC, m.id ASC"
	rows, err := db.QueryContext(ctx, query, args...)
	if err != nil {
		r.invalidateVersion()
		return nil, err
	}
	defer rows.Close()
	type messageRow struct {
		message          openCodeMessage
		created, updated int64
	}
	var rowsData []messageRow
	for rows.Next() {
		var message openCodeMessage
		columnID := ""
		var sessionIDValue string
		var created, updated, partUpdated sql.NullInt64
		var raw []byte
		if err := rows.Scan(&columnID, &sessionIDValue, &created, &updated, &raw, &partUpdated); err != nil {
			r.invalidateVersion()
			return nil, err
		}
		if columnID == "" {
			continue
		}
		if err := json.Unmarshal(raw, &message); err != nil {
			r.invalidateVersion()
			return nil, fmt.Errorf("decode OpenCode message %q: %w", columnID, err)
		}
		// OpenCode may keep large diff snapshots under message.summary. Warren's
		// projection only consumes a user-facing title/body, so retain that small
		// subset and discard provider bookkeeping before it reaches the cache.
		message.Summary = compactOpenCodeSummary(message.Summary)
		message.ID = columnID
		message.SessionID = sessionIDValue
		if message.Time.Created == 0 && created.Valid {
			message.Time.Created = created.Int64
		}
		if message.Time.Completed == 0 && updated.Valid && updated.Int64 > 0 && message.Role == "assistant" && message.Finish != "" {
			message.Time.Completed = updated.Int64
		}
		rowUpdated := int64(0)
		if updated.Valid {
			rowUpdated = updated.Int64
		}
		if rowUpdated == 0 && created.Valid {
			rowUpdated = created.Int64
		}
		if partUpdated.Valid && partUpdated.Int64 > rowUpdated {
			rowUpdated = partUpdated.Int64
		}
		rowsData = append(rowsData, messageRow{message: message, created: message.Time.Created, updated: rowUpdated})
	}
	if err := rows.Err(); err != nil {
		r.invalidateVersion()
		return nil, err
	}
	// Close the message cursor before querying parts. The reader intentionally
	// uses one SQLite connection; issuing a nested query while that cursor is
	// open would wait forever for the same connection.
	if err := rows.Close(); err != nil {
		r.invalidateVersion()
		return nil, err
	}
	partsByMessage, err := readSQLiteOpenCodeParts(ctx, db, sessionID, updatedSince)
	if err != nil {
		r.invalidateVersion()
		return nil, err
	}
	result := make([]openCodeSourceMessage, 0, len(rowsData))
	for _, row := range rowsData {
		result = append(result, openCodeSourceMessage{
			Message: row.message,
			Parts:   partsByMessage[row.message.ID],
			Updated: row.updated,
		})
	}
	return result, nil
}

func readSQLiteOpenCodeParts(ctx context.Context, db *sql.DB, sessionID string, updatedSince int64) (map[string][]openCodePart, error) {
	// Fetch all parts for the bound session in one indexed query. The previous
	// per-message lookup turned every database update into an N+1 round trip for
	// long conversations, even though the message query had already selected
	// the complete session snapshot. On incremental polls, the subquery keeps
	// the part scan limited to messages that caused the update while still
	// returning every part needed to rebuild each mutable envelope.
	query := "SELECT p.id, p.message_id, p.data FROM part AS p WHERE p.session_id = ?"
	args := []any{sessionID}
	if updatedSince > 0 {
		query += ` AND p.message_id IN (
			SELECT m.id FROM message AS m
			LEFT JOIN part AS changed ON changed.message_id = m.id
			WHERE m.session_id = ?
			  AND (changed.time_updated >= ? OR m.time_created >= ? OR m.time_updated >= ?)
		)`
		args = append(args, sessionID, updatedSince, updatedSince, updatedSince)
	}
	query += " ORDER BY p.time_created ASC, p.id ASC"
	rows, err := db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := make(map[string][]openCodePart)
	for rows.Next() {
		var part openCodePart
		columnID, columnMessageID := part.ID, part.MessageID
		var raw []byte
		if err := rows.Scan(&columnID, &columnMessageID, &raw); err != nil {
			return nil, err
		}
		if columnID == "" || columnMessageID == "" {
			continue
		}
		if err := json.Unmarshal(raw, &part); err != nil {
			return nil, fmt.Errorf("decode OpenCode part %q: %w", columnID, err)
		}
		// IDs and ownership come from relational columns, not provider JSON.
		// Reasserting them avoids a malformed payload crossing session/message
		// boundaries or producing a cache record that cannot be reconciled.
		part.ID = columnID
		part.MessageID = columnMessageID
		result[part.MessageID] = append(result[part.MessageID], part)
	}
	return result, rows.Err()
}

// OpenCodeTailer polls one bound session and appends complete snapshots to its
// private cache. Failed writes and incomplete message/part races never mark a
// message as seen, so the next poll can recover the missing content.
type OpenCodeTailer struct {
	binding      OpenCodeBinding
	cachePath    string
	interval     time.Duration
	reader       openCodeReader
	seen         map[string]string
	snapshots    map[string]openCodeEnvelope
	cacheLines   int
	cacheBytes   int64
	updatedSince int64
	pollMu       sync.Mutex
	mu           sync.Mutex
	stop         chan struct{}
	done         chan struct{}
	started      bool
	once         sync.Once
}

func NewOpenCodeTailer(binding OpenCodeBinding) (*OpenCodeTailer, error) {
	if !binding.Valid() {
		return nil, errors.New("invalid OpenCode binding")
	}
	cachePath := binding.CachePath
	if cachePath == "" {
		cachePath = OpenCodeCachePath("warren", binding.SessionID)
	}
	var reader openCodeReader
	switch binding.Backend {
	case openCodeSQLite:
		reader = &sqliteOpenCodeReader{databasePath: binding.DatabasePath, state: &sqliteReaderState{}}
	default:
		return nil, fmt.Errorf("unsupported OpenCode backend %q", binding.Backend)
	}
	tailer := &OpenCodeTailer{
		binding: binding, cachePath: cachePath, interval: watchInterval,
		reader: reader, seen: map[string]string{}, snapshots: map[string]openCodeEnvelope{}, stop: make(chan struct{}), done: make(chan struct{}),
	}
	tailer.loadCacheState()
	return tailer, nil
}

// StartOpenCodeSessionTailer starts the stable, bound tailer used by Service.
func StartOpenCodeSessionTailer(binding OpenCodeBinding) (*OpenCodeTailer, error) {
	tailer, err := NewOpenCodeTailer(binding)
	if err != nil {
		return nil, err
	}
	tailer.started = true
	go tailer.loop()
	return tailer, nil
}

// StartOpenCodeTailer is retained as a small compatibility helper for callers
// that only have a workspace. New code should resolve and pass a binding.
func StartOpenCodeTailer(cachePath, workspace string, after time.Time) *OpenCodeTailer {
	binding, _ := (DefaultFinder{}).FindBinding(context.Background(), "compat", openCodeProvider, workspace, after)
	if binding == nil {
		return &OpenCodeTailer{cachePath: cachePath, interval: watchInterval, seen: map[string]string{}, stop: make(chan struct{})}
	}
	if cachePath != "" {
		binding.CachePath = cachePath
	}
	tailer, err := NewOpenCodeTailer(*binding)
	if err != nil {
		return &OpenCodeTailer{cachePath: cachePath, interval: watchInterval, seen: map[string]string{}, stop: make(chan struct{})}
	}
	tailer.started = true
	go tailer.loop()
	return tailer
}

// Path returns the Warren-owned JSONL cache consumed by the transcript
// watcher.
func (t *OpenCodeTailer) Path() string { return t.cachePath }

func (t *OpenCodeTailer) Close() {
	t.once.Do(func() {
		close(t.stop)
		if t.started && t.done != nil {
			<-t.done
		}
		if closer, ok := t.reader.(openCodeReaderCloser); ok {
			_ = closer.Close()
		}
	})
}

func (t *OpenCodeTailer) loop() {
	defer close(t.done)
	_ = t.Poll(context.Background())
	ticker := time.NewTicker(t.interval)
	defer ticker.Stop()
	for {
		select {
		case <-t.stop:
			return
		case <-ticker.C:
			_ = t.Poll(context.Background())
		}
	}
}

// Poll performs one bounded read and is exported for deterministic fixtures.
func (t *OpenCodeTailer) Poll(parent context.Context) (err error) {
	t.pollMu.Lock()
	defer t.pollMu.Unlock()
	// Provider databases are external state. The SQLite driver can panic on an
	// allocation failure (SQLITE_NOMEM) instead of returning an error; contain
	// that failure at the tailer boundary so one oversized conversation cannot
	// terminate the headless control plane during restore.
	defer func() {
		if recovered := recover(); recovered != nil {
			if closer, ok := t.reader.(openCodeReaderCloser); ok {
				_ = closer.Close()
			}
			err = fmt.Errorf("OpenCode tailer poll panic: %v", recovered)
		}
	}()
	if t.reader == nil || t.binding.SessionID == "" {
		return errors.New("OpenCode tailer has no bound reader")
	}
	ctx, cancel := context.WithTimeout(parent, 3*time.Second)
	defer cancel()
	t.mu.Lock()
	updatedSince := t.updatedSince
	t.mu.Unlock()
	messages, err := t.reader.ReadMessages(ctx, t.binding.SessionID, updatedSince)
	if err != nil {
		return err
	}
	incomplete := false
	maxUpdated := updatedSince
	for _, source := range messages {
		envelope, complete := openCodeEnvelopeFromSource(source)
		if !complete || envelope.MessageID == "" {
			incomplete = true
			continue
		}
		// A restored cache starts with an empty SQL time cursor. Advance it for
		// unchanged snapshots too; otherwise every poll would rescan the whole
		// conversation forever after a daemon restart.
		if source.Updated > maxUpdated {
			maxUpdated = source.Updated
		}
		fingerprint := openCodeEnvelopeFingerprint(envelope)
		t.mu.Lock()
		previous := t.seen[envelope.MessageID]
		t.mu.Unlock()
		if previous == fingerprint {
			continue
		}
		envelope.Fingerprint = fingerprint
		if err := t.appendEnvelope(envelope); err != nil {
			// Do not advance seen/updatedSince on a failed append. Retrying the
			// same snapshot is what makes a transient permission/disk error
			// recoverable.
			return err
		}
		t.mu.Lock()
		t.seen[envelope.MessageID] = fingerprint
		t.mu.Unlock()
	}
	// Keep polling the complete set while any message is waiting for its
	// parts. Advancing a SQL time cursor past that row would otherwise make the
	// first committed text invisible forever.
	t.mu.Lock()
	if incomplete {
		t.updatedSince = 0
	} else if maxUpdated > t.updatedSince {
		t.updatedSince = maxUpdated
	}
	t.mu.Unlock()
	return nil
}

func (t *OpenCodeTailer) loadCacheState() {
	if t.cachePath == "" {
		return
	}
	if t.seen == nil {
		t.seen = map[string]string{}
	}
	if t.snapshots == nil {
		t.snapshots = map[string]openCodeEnvelope{}
	}
	file, err := os.Open(t.cachePath)
	if err != nil {
		return
	}
	if info, statErr := file.Stat(); statErr == nil {
		t.cacheBytes = info.Size()
	}
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 64*1024), maxTranscriptLine)
	for scanner.Scan() {
		t.cacheLines++
		var envelope openCodeEnvelope
		if json.Unmarshal(scanner.Bytes(), &envelope) != nil || envelope.MessageID == "" {
			continue
		}
		fingerprint := envelope.Fingerprint
		if fingerprint == "" {
			fingerprint = openCodeEnvelopeFingerprint(envelope)
		}
		t.seen[envelope.MessageID] = fingerprint
		t.snapshots[envelope.MessageID] = envelope
	}
	scanErr := scanner.Err()
	_ = file.Close()
	// A cache may have grown before the daemon was restarted. Compact it before
	// the first poll so the new watcher starts from a bounded file as well.
	if scanErr == nil {
		_ = t.compactCache()
	}
}

func (t *OpenCodeTailer) appendEnvelope(envelope openCodeEnvelope) error {
	if err := os.MkdirAll(filepath.Dir(t.cachePath), 0o700); err != nil {
		return err
	}
	_ = os.Chmod(filepath.Dir(t.cachePath), 0o700)
	payload, err := json.Marshal(envelope)
	if err != nil {
		return err
	}
	file, err := os.OpenFile(t.cachePath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return err
	}
	if err := file.Chmod(0o600); err != nil {
		_ = file.Close()
		return err
	}
	if _, err := file.Write(append(payload, '\n')); err != nil {
		_ = file.Close()
		return err
	}
	if err := file.Close(); err != nil {
		return err
	}
	t.mu.Lock()
	if t.snapshots == nil {
		t.snapshots = map[string]openCodeEnvelope{}
	}
	t.snapshots[envelope.MessageID] = envelope
	t.cacheLines++
	t.cacheBytes += int64(len(payload) + 1)
	shouldCompact := t.cacheLines >= openCodeCacheCompactionLines || t.cacheBytes >= openCodeCacheCompactionBytes
	t.mu.Unlock()
	if shouldCompact {
		// The append itself succeeded. A best-effort compaction failure must not
		// make Poll retry the same snapshot and duplicate it in the cache.
		_ = t.compactCache()
	}
	return nil
}

// compactCache atomically replaces the append-only cache with one latest
// snapshot per message. The map is keyed by provider message ID, so a daemon
// restart can replay the compacted file without losing mutable message state.
func (t *OpenCodeTailer) compactCache() error {
	t.mu.Lock()
	if (t.cacheLines < openCodeCacheCompactionLines && t.cacheBytes < openCodeCacheCompactionBytes) || len(t.snapshots) == 0 {
		t.mu.Unlock()
		return nil
	}
	snapshots := make([]openCodeEnvelope, 0, len(t.snapshots))
	for _, envelope := range t.snapshots {
		snapshots = append(snapshots, envelope)
	}
	t.mu.Unlock()
	sort.SliceStable(snapshots, func(i, j int) bool {
		left, right := snapshots[i].Time.Created, snapshots[j].Time.Created
		if left == right {
			return snapshots[i].MessageID < snapshots[j].MessageID
		}
		return left < right
	})

	directory := filepath.Dir(t.cachePath)
	if err := os.MkdirAll(directory, 0o700); err != nil {
		return err
	}
	_ = os.Chmod(directory, 0o700)
	temporary, err := os.CreateTemp(directory, ".opencode-cache-*")
	if err != nil {
		return err
	}
	temporaryPath := temporary.Name()
	removeTemporary := true
	defer func() {
		_ = temporary.Close()
		if removeTemporary {
			_ = os.Remove(temporaryPath)
		}
	}()
	if err := temporary.Chmod(0o600); err != nil {
		return err
	}
	writer := bufio.NewWriterSize(temporary, 64*1024)
	lineCount := 0
	var byteCount int64
	for _, envelope := range snapshots {
		payload, err := json.Marshal(envelope)
		if err != nil {
			return err
		}
		if _, err := writer.Write(payload); err != nil {
			return err
		}
		if err := writer.WriteByte('\n'); err != nil {
			return err
		}
		lineCount++
		byteCount += int64(len(payload) + 1)
	}
	if err := writer.Flush(); err != nil {
		return err
	}
	if err := temporary.Sync(); err != nil {
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	if err := os.Rename(temporaryPath, t.cachePath); err != nil {
		return err
	}
	removeTemporary = false
	t.mu.Lock()
	t.cacheLines = lineCount
	t.cacheBytes = byteCount
	t.mu.Unlock()
	return nil
}

// RemoveCache is reserved for explicit Warren session deletion. Close keeps
// the cache so a daemon restart can restore the structured conversation.
func (t *OpenCodeTailer) RemoveCache() error {
	t.Close()
	if t.cachePath == "" {
		return nil
	}
	err := os.Remove(t.cachePath)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	return err
}

// RemoveOpenCodeCache removes a persisted cache when no live tailer exists,
// while leaving missing files as a successful cleanup.
func RemoveOpenCodeCache(path string) error {
	if strings.TrimSpace(path) == "" {
		return nil
	}
	err := os.Remove(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	return err
}

func openCodeEnvelopeFromSource(source openCodeSourceMessage) (openCodeEnvelope, bool) {
	message := source.Message
	envelope := openCodeEnvelope{
		MessageID:  message.ID,
		Role:       message.Role,
		Finish:     message.Finish,
		ModelID:    message.ModelID,
		ProviderID: message.ProviderID,
		Time:       message.Time,
		Summary:    message.Summary,
		Error:      message.Error,
		Parts:      append([]openCodePart(nil), source.Parts...),
	}
	// A just-created message can be visible before its parts transaction is
	// committed. Waiting here avoids permanently losing the user prompt or
	// assistant text. Error/final assistant rows are self-contained and may be
	// projected without parts.
	if len(envelope.Parts) == 0 && !openCodeRawValuePresent(envelope.Error) && envelope.Finish == "" &&
		openCodeSummaryTitle(envelope.Summary, maxEventContent) == "" {
		return openCodeEnvelope{}, false
	}
	return envelope, true
}

func openCodeRawValuePresent(raw json.RawMessage) bool {
	value := strings.TrimSpace(string(raw))
	return value != "" && value != "null"
}

func compactOpenCodeSummary(raw json.RawMessage) json.RawMessage {
	if len(raw) == 0 || string(raw) == "null" || string(raw) == "true" || string(raw) == "false" {
		return nil
	}
	var object struct {
		Title string `json:"title"`
		Body  string `json:"body"`
	}
	if json.Unmarshal(raw, &object) == nil && (object.Title != "" || object.Body != "") {
		compact, _ := json.Marshal(struct {
			Title string `json:"title,omitempty"`
			Body  string `json:"body,omitempty"`
		}{
			Title: truncate(object.Title, maxEventContent),
			Body:  truncate(object.Body, maxEventContent),
		})
		return compact
	}
	var textValue string
	if json.Unmarshal(raw, &textValue) == nil && textValue != "" {
		compact, _ := json.Marshal(truncate(textValue, maxEventContent))
		return compact
	}
	return nil
}

func openCodeEnvelopeFingerprint(envelope openCodeEnvelope) string {
	envelope.Fingerprint = ""
	payload, _ := json.Marshal(envelope)
	hash := sha256.Sum256(payload)
	return hex.EncodeToString(hash[:])
}

// openCodeMessageSnapshot is parser-local state used to turn mutable cache
// snapshots into append-only normalized events.
type openCodeMessageSnapshot struct {
	Role    string
	Finish  string
	Error   string
	Summary string
	Parts   map[string]openCodePartSnapshot
}

type openCodePartSnapshot struct {
	Type        string
	Text        string
	CallID      string
	Tool        string
	State       openCodeToolState
	CallEmitted bool
}

func (p *parser) parseOpenCode(line []byte) []api.AgentEvent {
	var envelope openCodeEnvelope
	if json.Unmarshal(line, &envelope) != nil {
		return nil
	}
	messageKey := strings.TrimSpace(envelope.MessageID)
	if messageKey == "" {
		return nil
	}
	previous := p.opencodeMessages[messageKey]
	current := openCodeMessageSnapshot{
		Role: envelope.Role, Finish: envelope.Finish,
		Summary: openCodeSummaryTitle(envelope.Summary, p.contentLimit),
		Parts:   map[string]openCodePartSnapshot{},
	}
	for _, part := range envelope.Parts {
		if part.ID == "" {
			continue
		}
		current.Parts[part.ID] = openCodePartSnapshot{Type: part.Type, Text: part.Text, CallID: part.CallID, Tool: part.Tool, State: part.State}
	}
	current.Error = openCodeErrorContent(envelope.Error, p.contentLimit)
	model := envelope.ModelID
	if envelope.ProviderID != "" && model != "" {
		model = envelope.ProviderID + "/" + model
	}
	timestamp := openCodeMillisTime(envelope.Time.Created)
	var events []api.AgentEvent
	emittedUserText := false
	for _, part := range envelope.Parts {
		if part.ID == "" {
			continue
		}
		old, existed := previous.Parts[part.ID]
		switch part.Type {
		case "text":
			if envelope.Role == "user" {
				emittedUserText = true
			}
			if delta, isDelta := openCodeDelta(old.Text, part.Text, existed); delta != "" {
				eventType := "assistant"
				if envelope.Role == "user" {
					eventType = "user"
				}
				events = append(events, api.AgentEvent{Provider: openCodeProvider, ID: part.ID, Type: eventType, Content: p.clip(delta), ContentDelta: isDelta, Model: model, Timestamp: timestamp})
			}
		case "reasoning":
			previousText := old.Text
			currentText := part.Text
			if delta, isDelta := openCodeDelta(previousText, currentText, existed); delta != "" {
				events = append(events, api.AgentEvent{Provider: openCodeProvider, ID: part.ID, Type: "reasoning", Content: p.clip(delta), ContentDelta: isDelta, Model: model, Timestamp: timestamp})
			}
		case "tool":
			toolName := part.Tool
			if toolName == "" {
				toolName = "tool"
			}
			callID := part.CallID
			if callID == "" {
				callID = part.ID
			}
			callEmitted := existed && old.CallEmitted
			// OpenCode creates a pending tool part before the model has
			// finished streaming its input. Wait for a real input or a
			// non-pending state so the UI receives one useful tool_call rather
			// than an empty card that can never be updated in place.
			if !callEmitted && (strings.ToLower(part.State.Status) != "pending" || openCodeToolInputPresent(part.State.Input)) {
				events = append(events, api.AgentEvent{Provider: openCodeProvider, ID: part.ID, Type: "tool_call", CallID: callID, ToolName: toolName, ToolInput: rawToAny(part.State.Input, p.contentLimit), ToolStatus: normalizeOpenCodeToolStatus(part.State.Status), Timestamp: timestamp})
				callEmitted = true
			}
			currentPart := current.Parts[part.ID]
			currentPart.CallEmitted = callEmitted
			current.Parts[part.ID] = currentPart
			if openCodeToolTerminal(part.State.Status) && (!existed || !openCodeToolTerminal(old.State.Status) || old.State.Status != part.State.Status || !jsonEqual(old.State.Output, part.State.Output) || !jsonEqual(old.State.Error, part.State.Error)) {
				output, errorText := openCodeToolOutput(part.State, p.contentLimit)
				status := normalizeOpenCodeToolStatus(part.State.Status)
				event := api.AgentEvent{Provider: openCodeProvider, ID: part.ID, Type: "tool_output", CallID: callID, ToolName: toolName, ToolStatus: status, Output: output, Timestamp: timestamp}
				if errorText != "" {
					event.Error = errorText
				}
				events = append(events, event)
			}
		}
	}
	if envelope.Role == "user" && !emittedUserText && current.Summary != "" && previous.Summary != current.Summary {
		events = append(events, api.AgentEvent{Provider: openCodeProvider, ID: messageKey, Type: "user", Content: current.Summary, Timestamp: timestamp})
	}
	if current.Error != "" && (!existedOpenCodeError(previous) || previous.Error != current.Error) {
		events = append(events, api.AgentEvent{Provider: openCodeProvider, ID: messageKey, Type: "error", Content: current.Error, Error: current.Error, Model: model, Timestamp: timestamp})
	}
	if envelope.Role == "assistant" {
		if reason, terminal := openCodeFinishReason(envelope.Finish); terminal && previous.Finish != envelope.Finish {
			if len(events) == 0 {
				events = append(events, api.AgentEvent{Provider: openCodeProvider, ID: messageKey, Type: "assistant", Model: model, Timestamp: timestamp})
			}
			events[len(events)-1].StopReason = reason
		}
	}
	p.opencodeMessages[messageKey] = current
	return events
}

func existedOpenCodeError(snapshot openCodeMessageSnapshot) bool { return snapshot.Error != "" }

func openCodeSummaryTitle(raw json.RawMessage, limit int) string {
	if len(raw) == 0 || string(raw) == "null" || string(raw) == "true" || string(raw) == "false" {
		return ""
	}
	var value struct {
		Title string `json:"title"`
		Body  string `json:"body"`
	}
	if json.Unmarshal(raw, &value) == nil {
		if value.Title != "" {
			return truncate(value.Title, limit)
		}
		return truncate(value.Body, limit)
	}
	var text string
	if json.Unmarshal(raw, &text) == nil {
		return truncate(text, limit)
	}
	return ""
}

func openCodeDelta(previous, current string, existed bool) (string, bool) {
	if current == "" || (existed && current == previous) {
		return "", false
	}
	if existed && strings.HasPrefix(current, previous) {
		return current[len(previous):], true
	}
	// A provider edit/rewrite is a replacement, not a delta. The explicit
	// false marker lets clients replace the displayed bubble instead of
	// appending the complete rewritten text a second time.
	return current, false
}

func normalizeOpenCodeToolStatus(status string) string {
	switch strings.ToLower(status) {
	case "completed", "success":
		return "success"
	case "error", "failed":
		return "error"
	case "interrupted", "cancelled", "canceled":
		return "interrupted"
	default:
		return "running"
	}
}

func openCodeToolTerminal(status string) bool {
	switch strings.ToLower(status) {
	case "completed", "success", "error", "failed", "interrupted", "cancelled", "canceled":
		return true
	default:
		return false
	}
}

func openCodeToolInputPresent(raw json.RawMessage) bool {
	value := strings.TrimSpace(string(raw))
	if value == "" || value == "null" || value == "{}" {
		return false
	}
	var parsed any
	if json.Unmarshal(raw, &parsed) == nil {
		if object, ok := parsed.(map[string]any); ok {
			return len(object) > 0
		}
		return parsed != nil
	}
	return true
}

func openCodeFinishReason(finish string) (string, bool) {
	switch strings.ToLower(strings.TrimSpace(finish)) {
	case "stop", "end_turn", "length", "content-filter", "content_filter", "max_tokens", "error", "other":
		return strings.ToLower(strings.TrimSpace(finish)), true
	default:
		// OpenCode keeps tool-calls and unknown messages open while the
		// processor either starts another step or retries the provider.
		return "", false
	}
}

func openCodeErrorContent(raw json.RawMessage, limit int) string {
	if len(raw) == 0 || string(raw) == "null" {
		return ""
	}
	var text string
	if json.Unmarshal(raw, &text) == nil && text != "" {
		return truncate(text, limit)
	}
	var value struct {
		Name string `json:"name"`
		Data struct {
			Message string `json:"message"`
		} `json:"data"`
		Message string `json:"message"`
	}
	if json.Unmarshal(raw, &value) == nil {
		if value.Data.Message != "" {
			return truncate(value.Data.Message, limit)
		}
		if value.Message != "" {
			return truncate(value.Message, limit)
		}
		if value.Name != "" {
			return truncate(value.Name, limit)
		}
	}
	return truncate(string(raw), limit)
}

func openCodeToolOutput(state openCodeToolState, limit int) (output, errorText string) {
	if normalizeOpenCodeToolStatus(state.Status) == "error" {
		errorText = openCodeErrorContent(state.Error, limit)
		if errorText == "" {
			errorText = contentStringLimit(state.Output, limit)
		}
		return "", errorText
	}
	return contentStringLimit(state.Output, limit), ""
}

func jsonEqual(left, right json.RawMessage) bool {
	if len(left) == 0 && len(right) == 0 {
		return true
	}
	var a, b any
	if json.Unmarshal(left, &a) == nil && json.Unmarshal(right, &b) == nil {
		return fmt.Sprintf("%v", a) == fmt.Sprintf("%v", b)
	}
	return string(left) == string(right)
}
