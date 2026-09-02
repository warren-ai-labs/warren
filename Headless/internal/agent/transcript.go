// Package agent watches the JSONL transcripts that Codex and Claude Code
// write while their TUI runs, and projects those files as normalized events.
// The PTY byte stream stays the source of truth; this is a side channel for
// clients (notably Web) that want a structured view of the same process.
package agent

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

const (
	maxEventContent = 256 * 1024
	maxInitialRead  = 32 * 1024 * 1024
	// maxTranscriptLine prevents a malformed or unexpectedly large JSONL
	// record from causing an unbounded allocation while it is read.
	maxTranscriptLine = 16 * 1024 * 1024
	watchInterval     = 500 * time.Millisecond
	maxHistory        = 2000
)

// Finder locates the transcript file for a running Codex or Claude session.
// OpenCode uses BindingFinder to resolve its database-backed conversation and
// returns a Warren-owned cache path through this compatibility method.
// A missing file is not an error: the CLI may not be installed, may not have
// written a transcript yet, or may be running a version with a different
// layout. Callers retry until the file appears.
type Finder interface {
	Find(ctx context.Context, kind, workspacePath string, after time.Time) (string, error)
}

// DefaultFinder implements Finder for the stock Codex and Claude Code layouts.
type DefaultFinder struct {
	// CodexRoot is the Codex sessions directory (default ~/.codex/sessions).
	CodexRoot string
	// ClaudeRoot is the Claude Code projects directory (default ~/.claude/projects).
	ClaudeRoot string
	// OpenCodeRoot overrides OpenCode's current data directory containing
	// opencode.db.
	OpenCodeRoot string
}

func (f DefaultFinder) Find(ctx context.Context, kind, workspacePath string, after time.Time) (string, error) {
	switch strings.ToLower(strings.TrimSpace(kind)) {
	case "codex":
		return f.findCodex(ctx, workspacePath, after)
	case "claude":
		return f.findClaude(ctx, workspacePath, after)
	case "opencode":
		binding, err := f.FindBinding(ctx, "compat", kind, workspacePath, after)
		if err != nil || binding == nil {
			return "", err
		}
		return binding.CachePath, nil
	case "pi":
		// Pi sessions are bound by the deterministic --session-id Warren
		// injects at creation, so the generic cwd+mtime finder has no
		// identity to search with. Dedicated sessions resolve through
		// boundTranscript; this fallback deliberately returns nothing
		// instead of adopting an unrelated conversation.
		return "", nil
	default:
		return "", nil
	}
}

func (f DefaultFinder) findCodex(ctx context.Context, workspacePath string, after time.Time) (string, error) {
	root := f.CodexRoot
	if root == "" {
		root = defaultCodexSessionsRoot()
	}
	return findNewest(ctx, root, after, func(path string) bool {
		name := filepath.Base(path)
		if !strings.HasPrefix(name, "rollout-") || !strings.HasSuffix(name, ".jsonl") {
			return false
		}
		return transcriptCwdMatches(path, workspacePath, codexMetaCwd)
	})
}

func (f DefaultFinder) findClaude(ctx context.Context, workspacePath string, after time.Time) (string, error) {
	root := f.ClaudeRoot
	if root == "" {
		root = defaultClaudeProjectsRoot()
	}
	return findNewest(ctx, root, after, func(path string) bool {
		name := filepath.Base(path)
		if !strings.HasSuffix(name, ".jsonl") || strings.HasPrefix(name, "agent-") {
			return false
		}
		return claudeTranscriptMatchesCwd(path, workspacePath)
	})
}

type fileCandidate struct {
	path string
	mod  time.Time
}

func findNewest(ctx context.Context, root string, after time.Time, matches func(string) bool) (string, error) {
	info, err := os.Lstat(root)
	if err != nil || !info.IsDir() {
		return "", nil
	}
	var candidates []fileCandidate
	walkErr := filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if entry.IsDir() {
			return nil
		}
		// Never inspect or open links and special files while walking a
		// transcript root. A FIFO, for example, would block the finder.
		if entry.Type()&fs.ModeSymlink != 0 {
			return nil
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}
		fileInfo, err := entry.Info()
		if err != nil {
			return nil
		}
		if !fileInfo.Mode().IsRegular() || fileInfo.Mode()&fs.ModeSymlink != 0 {
			return nil
		}
		// A session may only adopt transcripts written after it started.
		// Older files belong to previous conversations in the same workspace.
		if !after.IsZero() && fileInfo.ModTime().Before(after) {
			return nil
		}
		if !matches(path) {
			return nil
		}
		candidates = append(candidates, fileCandidate{path: path, mod: fileInfo.ModTime()})
		return nil
	})
	if walkErr != nil {
		return "", walkErr
	}
	if len(candidates) == 0 {
		return "", nil
	}
	sort.Slice(candidates, func(i, j int) bool { return candidates[i].mod.After(candidates[j].mod) })
	return candidates[0].path, nil
}

func transcriptCwdMatches(path, workspacePath string, readCwd func(string) string) bool {
	cwd := readCwd(path)
	return cwd != "" && samePath(cwd, workspacePath)
}

func codexMetaCwd(path string) string {
	data, err := readFirstLine(path, 1024*1024)
	if err != nil {
		return ""
	}
	var record struct {
		Payload struct {
			Cwd string `json:"cwd"`
		} `json:"payload"`
	}
	if json.Unmarshal(data, &record) != nil {
		return ""
	}
	return record.Payload.Cwd
}

func claudeTranscriptMatchesCwd(path, workspacePath string) bool {
	file, err := openRegularFile(path)
	if err != nil {
		return false
	}
	defer file.Close()
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 64*1024), 512*1024)
	lines := 0
	for scanner.Scan() && lines < 64 {
		lines++
		var record struct {
			Cwd string `json:"cwd"`
		}
		if json.Unmarshal(scanner.Bytes(), &record) == nil && samePath(record.Cwd, workspacePath) {
			return true
		}
	}
	return false
}

func readFirstLine(path string, limit int64) ([]byte, error) {
	if limit <= 0 {
		return nil, fmt.Errorf("first-line limit must be positive")
	}
	file, err := openRegularFile(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	reader := bufio.NewReader(file)
	line, err := readBoundedLine(reader, int(limit))
	if err != nil && len(line) == 0 {
		return nil, err
	}
	return bytes.TrimSpace(line), nil
}

// readBoundedLine reads one complete JSONL line while enforcing a byte cap.
// The cap applies to the line, not to the file: large transcripts remain
// discoverable as long as their metadata line is small.
func readBoundedLine(reader *bufio.Reader, limit int) ([]byte, error) {
	if limit <= 0 {
		return nil, fmt.Errorf("line limit must be positive")
	}
	var line []byte
	for {
		part, err := reader.ReadSlice('\n')
		if len(line)+len(part) > limit {
			return nil, fmt.Errorf("transcript line exceeds %d bytes", limit)
		}
		line = append(line, part...)
		if err == nil {
			return line, nil
		}
		if err == bufio.ErrBufferFull {
			continue
		}
		if err == io.EOF {
			if len(line) == 0 {
				return nil, io.EOF
			}
			return line, io.EOF
		}
		return line, err
	}
}

func openRegularFile(path string) (*os.File, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return nil, err
	}
	if info.Mode()&fs.ModeSymlink != 0 {
		return nil, fmt.Errorf("refusing symlink transcript %q", path)
	}
	if !info.Mode().IsRegular() {
		return nil, fmt.Errorf("transcript %q is not a regular file", path)
	}
	return os.Open(path)
}

func samePath(left, right string) bool {
	a, _ := filepath.Abs(left)
	b, _ := filepath.Abs(right)
	return filepath.Clean(a) == filepath.Clean(b)
}

func defaultCodexSessionsRoot() string {
	home := os.Getenv("CODEX_HOME")
	if home == "" {
		userHome, _ := os.UserHomeDir()
		home = filepath.Join(userHome, ".codex")
	}
	return filepath.Join(home, "sessions")
}

func defaultClaudeProjectsRoot() string {
	home := os.Getenv("CLAUDE_CONFIG_DIR")
	if home == "" {
		userHome, _ := os.UserHomeDir()
		home = filepath.Join(userHome, ".claude")
	}
	return filepath.Join(home, "projects")
}

// Watcher tails one transcript file and emits normalized events. The first
// poll replays existing history; later polls only deliver newly appended
// lines. A truncated file restarts from byte zero without re-emitting the
// already-served prefix, which is acceptable for a best-effort side channel.
type Watcher struct {
	sessionID string
	provider  string
	path      string
	interval  time.Duration
	onEvents  func([]api.AgentEvent, api.AgentStatus)
	onStatus  func(api.AgentStatus)
	onTurns   func([]api.AgentTurn, bool)
	parser    *parser

	mu         sync.Mutex
	events     []api.AgentEvent
	lastStatus api.AgentStatus
	stop       chan struct{}
	done       chan struct{}
	ready      chan struct{}
	once       sync.Once
}

// Start begins tailing path immediately in a background goroutine.
func Start(
	sessionID, provider, path string,
	onEvents func([]api.AgentEvent, api.AgentStatus),
	onStatus func(api.AgentStatus),
	onTurns func([]api.AgentTurn, bool),
) *Watcher {
	watcher := &Watcher{
		sessionID: sessionID,
		provider:  provider,
		path:      path,
		interval:  watchInterval,
		onEvents:  onEvents,
		onStatus:  onStatus,
		onTurns:   onTurns,
		parser:    newParser(provider),
		stop:      make(chan struct{}),
		done:      make(chan struct{}),
		ready:     make(chan struct{}),
	}
	go watcher.loop()
	return watcher
}

// Close stops the poll loop and waits for it to finish.
func (w *Watcher) Close() {
	w.once.Do(func() {
		close(w.stop)
		<-w.done
	})
}

// Path returns the transcript file being watched.
func (w *Watcher) Path() string {
	return w.path
}

// WaitReady waits until the initial transcript replay has established the
// current status and turn cursor.
func (w *Watcher) WaitReady(ctx context.Context) error {
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-w.ready:
		return nil
	}
}

// Snapshot returns the retained event history.
func (w *Watcher) Snapshot() []api.AgentEvent {
	w.mu.Lock()
	defer w.mu.Unlock()
	return append([]api.AgentEvent(nil), w.events...)
}

func (w *Watcher) loop() {
	defer close(w.done)
	offset := int64(0)
	sequence := uint64(0)
	var fileInfo os.FileInfo
	events, next, currentFileInfo, err := readNewTracked(w.path, offset, w.parser, fileInfo)
	if err == nil {
		offset = next
		fileInfo = currentFileInfo
		w.lastStatus = w.parser.Status()
		if len(events) > 0 {
			for index := range events {
				sequence++
				events[index].Sequence = sequence
			}
			w.append(events)
			if w.onEvents != nil {
				w.onEvents(events, w.lastStatus)
			}
		}
		// Historical replay establishes the current turn cursor without
		// flooding clients with every old lifecycle transition.
		if turns := w.parser.DrainTurns(); len(turns) > 0 && w.onTurns != nil {
			w.onTurns(turns[len(turns)-1:], true)
		}
	}
	close(w.ready)
	ticker := time.NewTicker(w.interval)
	defer ticker.Stop()
	for {
		select {
		case <-w.stop:
			return
		case <-ticker.C:
			events, next, currentFileInfo, err := readNewTracked(w.path, offset, w.parser, fileInfo)
			if err != nil {
				continue
			}
			offset = next
			fileInfo = currentFileInfo
			status := w.parser.Status()
			if len(events) > 0 {
				for index := range events {
					sequence++
					events[index].Sequence = sequence
				}
				w.append(events)
				w.lastStatus = status
				if w.onEvents != nil {
					w.onEvents(events, status)
				}
			}
			// Events are delivered first so a waiter can retrieve the complete
			// turn as soon as its terminal transition arrives.
			if turns := w.parser.DrainTurns(); len(turns) > 0 && w.onTurns != nil {
				w.onTurns(turns, false)
			}
			w.parser.Tick(time.Now())
			if status := w.parser.Status(); !status.Equal(w.lastStatus) {
				w.lastStatus = status
				if w.onStatus != nil {
					w.onStatus(status)
				}
			}
		}
	}
}

func (w *Watcher) append(events []api.AgentEvent) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.events = append(w.events, events...)
	if len(w.events) > maxHistory {
		w.events = append([]api.AgentEvent(nil), w.events[len(w.events)-maxHistory:]...)
	}
}

// readNew reads complete JSONL lines starting at offset and returns the
// normalized events plus the next byte offset. A trailing partial line is
// left for the next poll so no event is split across reads.
func readNew(path string, offset int64, parser *parser) ([]api.AgentEvent, int64, error) {
	events, next, _, err := readNewTracked(path, offset, parser, nil)
	return events, next, err
}

// readNewTracked is the Watcher's version of readNew. OpenCode compacts its
// cache by atomically replacing the JSONL file; size alone cannot tell whether
// an offset still belongs to the same inode, so a replacement always restarts
// at byte zero. The parser state then suppresses duplicate snapshots and
// projects only any delta that arrived while the watcher was behind.
func readNewTracked(path string, offset int64, parser *parser, previous os.FileInfo) ([]api.AgentEvent, int64, os.FileInfo, error) {
	file, err := openRegularFile(path)
	if err != nil {
		return nil, offset, previous, err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return nil, offset, previous, err
	}
	if previous != nil && !os.SameFile(previous, info) {
		offset = 0
	}
	size := info.Size()
	if size < offset {
		// The CLI rotated or truncated the transcript; start over.
		offset = 0
	}
	align := false
	if offset == 0 && size > maxInitialRead {
		offset = size - maxInitialRead
		align = true
	}
	if _, err := file.Seek(offset, io.SeekStart); err != nil {
		return nil, offset, info, err
	}
	data, err := io.ReadAll(file)
	if err != nil {
		return nil, offset, info, err
	}
	baseOffset := offset
	if align {
		if index := bytes.IndexByte(data, '\n'); index >= 0 {
			baseOffset += int64(index) + 1
			data = data[index+1:]
		} else {
			return nil, baseOffset, info, nil
		}
	}
	var events []api.AgentEvent
	consumed := int64(0)
	for _, line := range bytes.SplitAfter(data, []byte("\n")) {
		if len(line) == 0 {
			continue
		}
		if !bytes.HasSuffix(line, []byte("\n")) {
			break
		}
		if len(line) > maxTranscriptLine {
			return nil, baseOffset + consumed, info, fmt.Errorf("transcript line exceeds %d bytes", maxTranscriptLine)
		}
		consumed += int64(len(line))
		trimmed := bytes.TrimSpace(line[:len(line)-1])
		if len(trimmed) == 0 {
			continue
		}
		events = append(events, parser.parse(trimmed)...)
	}
	return events, baseOffset + consumed, info, nil
}

type parser struct {
	provider string
	// contentLimit controls parser-level clipping. The live watcher keeps the
	// historical safety cap; transcript --full reads set it to zero.
	contentLimit    int
	tracker         ActivityTracker
	codexModel      string
	codexCallTool   map[string]string
	codexTurnFailed bool
	lastUserContent string
	// Older Codex rollouts write each turn twice: once as response_item and
	// once as a streaming event_msg. These fields deduplicate the twin
	// renderings so the UI does not show every message or thought twice.
	lastAssistantContent string
	lastReasoningContent string
	lastEventType        string
	// OpenCode persists mutable message and part rows. The parser keeps the
	// previous snapshot so a cache update is projected as a text delta (or a
	// single terminal tool transition) instead of duplicating the whole
	// message on every poll.
	opencodeMessages map[string]openCodeMessageSnapshot
	// claudeCallTool mirrors codexCallTool for Claude transcripts. Claude's
	// user-role tool_result blocks do not carry the originating tool name,
	// so the parser records it when the matching tool_use block arrives.
	claudeCallTool map[string]string
	// claudeInteractions tracks the kind of a pending Claude structured
	// interaction (question or permission) by its tool_use id, so the answer
	// tool_result can close the card as resolved instead of leaking a bare
	// tool_output.
	claudeInteractions map[string]string
}

func newParser(provider string) *parser {
	return newParserWithContentLimit(provider, maxEventContent)
}

func newParserWithContentLimit(provider string, contentLimit int) *parser {
	return &parser{
		provider:           provider,
		contentLimit:       contentLimit,
		tracker:            *NewActivityTracker(),
		codexCallTool:      map[string]string{},
		claudeCallTool:     map[string]string{},
		claudeInteractions: map[string]string{},
		opencodeMessages:   map[string]openCodeMessageSnapshot{},
	}
}

func (p *parser) content(value json.RawMessage) string {
	return contentStringLimit(value, p.contentLimit)
}

func (p *parser) clip(value string) string {
	return truncate(value, p.contentLimit)
}

func (p *parser) parse(line []byte) []api.AgentEvent {
	events := compactRenderable(p.parseLine(line))
	for index := range events {
		p.tracker.Observe(events[index])
		if !events[index].Sidechain {
			events[index].Turn = p.tracker.Turn()
		}
	}
	return events
}

// Status is the presentation state after every line parsed so far.
func (p *parser) Status() api.AgentStatus {
	return p.tracker.Status()
}

// Activity returns the lifecycle portion of Status.
func (p *parser) Activity() api.AgentActivity {
	return p.tracker.Activity()
}

// DrainTurns returns explicit lifecycle transitions observed while parsing.
func (p *parser) DrainTurns() []api.AgentTurn {
	return p.tracker.DrainTurns()
}

// Tick lets the tracker notice work that stalled without new transcript
// lines. A stall is a warning, never an inferred approval request.
func (p *parser) Tick(now time.Time) {
	p.tracker.Tick(now)
}

func (p *parser) parseLine(line []byte) []api.AgentEvent {
	switch p.provider {
	case "codex":
		return p.parseCodex(line)
	case "claude":
		return p.parseClaude(line)
	case "opencode":
		return p.parseOpenCode(line)
	case "pi":
		return p.parsePi(line)
	default:
		return nil
	}
}

type codexRecord struct {
	Timestamp string          `json:"timestamp"`
	Type      string          `json:"type"`
	Payload   json.RawMessage `json:"payload"`
}

type codexPayload struct {
	ID        string          `json:"id"`
	Type      string          `json:"type"`
	Role      string          `json:"role"`
	Model     string          `json:"model"`
	Effort    string          `json:"effort"`
	Content   json.RawMessage `json:"content"`
	Name      string          `json:"name"`
	CallID    string          `json:"call_id"`
	Arguments string          `json:"arguments"`
	Input     json.RawMessage `json:"input"`
	Action    struct {
		Command string   `json:"command"`
		Type    string   `json:"type"`
		Queries []string `json:"queries"`
		URL     string   `json:"url"`
	} `json:"action"`
	Output  json.RawMessage `json:"output"`
	Summary json.RawMessage `json:"summary"`
	Text    string          `json:"text"`
	Message string          `json:"message"`
	Error   json.RawMessage `json:"error"`
	Status  string          `json:"status"`
	Item    struct {
		Type    string          `json:"type"`
		Content json.RawMessage `json:"content"`
	} `json:"item"`
	Info struct {
		Model           string          `json:"model"`
		LastTokenUsage  json.RawMessage `json:"last_token_usage"`
		TotalTokenUsage json.RawMessage `json:"total_token_usage"`
	} `json:"info"`
}

var structuredAgentEventTypes = map[string]struct{}{
	"question": {}, "permission": {}, "plan": {}, "todo": {},
	"activity": {}, "plugin": {}, "subagent": {}, "attachment": {},
}

// projectStructuredAgentEvent turns provider-native structured records into
// the small, provider-neutral payload understood by Agent View. Provider
// transcripts contain many internal fields (including tool arguments), so
// only the RFC display fields cross the Host boundary.
func projectStructuredAgentEvent(provider string, fallbackType string, raw json.RawMessage, timestamp time.Time) *api.AgentEvent {
	var object map[string]any
	if len(raw) == 0 || json.Unmarshal(raw, &object) != nil {
		return nil
	}
	outerType := firstStringValue(object["type"], object["eventType"], fallbackType)
	source := object
	if nested, ok := object["payload"].(map[string]any); ok {
		source = nested
	}
	rawType := firstStringValue(source["type"], source["eventType"], outerType)
	normalized := strings.ToLower(strings.NewReplacer("-", "_", ".", "_").Replace(strings.TrimSpace(rawType)))
	kind := normalized
	for _, candidate := range []string{"question", "permission", "plan", "todo", "activity", "plugin", "subagent", "attachment"} {
		if normalized == candidate || strings.HasPrefix(normalized, candidate+"_") {
			kind = candidate
			break
		}
	}
	if _, ok := structuredAgentEventTypes[kind]; !ok {
		return nil
	}
	payload := make(map[string]any)
	copyStructuredField(payload, source, "requestId", "requestId", "request_id")
	copyStructuredField(payload, source, "title", "title")
	copyStructuredField(payload, source, "description", "description")
	copyStructuredField(payload, source, "questions", "questions")
	copyStructuredField(payload, source, "action", "action")
	copyStructuredField(payload, source, "options", "options")
	copyStructuredField(payload, source, "planId", "planId", "plan_id")
	copyStructuredField(payload, source, "todoId", "todoId", "todo_id")
	copyStructuredField(payload, source, "activityId", "activityId", "activity_id")
	copyStructuredField(payload, source, "pluginId", "pluginId", "plugin_id")
	copyStructuredField(payload, source, "subagentId", "subagentId", "subagent_id")
	copyStructuredField(payload, source, "attachmentId", "attachmentId", "attachment_id")
	copyStructuredField(payload, source, "items", "items")
	copyStructuredField(payload, source, "label", "label")
	copyStructuredField(payload, source, "name", "name")
	copyStructuredField(payload, source, "summary", "summary")
	copyStructuredField(payload, source, "detail", "detail")
	copyStructuredField(payload, source, "mime", "mime", "MIME")
	copyStructuredField(payload, source, "size", "size")
	copyStructuredField(payload, source, "state", "state", "status")
	// Provider records also use generic names such as `plan` and
	// `attachment` for internal transcript bookkeeping. Only project a
	// record when it carries at least one RFC display field; otherwise let the
	// provider-specific parser retain its established fallback behaviour.
	if len(payload) == 0 {
		return nil
	}
	if _, ok := payload["state"]; !ok {
		switch {
		case strings.HasSuffix(normalized, "_asked") || strings.HasSuffix(normalized, "_requested"):
			payload["state"] = "pending"
		case strings.HasSuffix(normalized, "_resolved") || strings.HasSuffix(normalized, "_replied") || strings.HasSuffix(normalized, "_rejected"):
			payload["state"] = "resolved"
		}
	}
	requestID := stringValue(payload["requestId"])
	id := firstStringValue(source["id"], source["eventId"], source["event_id"])
	if id == "" {
		switch kind {
		case "question", "permission":
			id = requestID
		case "plan":
			id = stringValue(payload["planId"])
		case "todo":
			id = stringValue(payload["todoId"])
		case "activity":
			id = stringValue(payload["activityId"])
		case "plugin":
			id = stringValue(payload["pluginId"])
		case "subagent":
			id = stringValue(payload["subagentId"])
		case "attachment":
			id = stringValue(payload["attachmentId"])
		}
	}
	return &api.AgentEvent{Provider: provider, ID: id, Type: kind, Payload: payload, Timestamp: timestamp}
}

func copyStructuredField(destination, source map[string]any, name string, aliases ...string) {
	for _, alias := range aliases {
		if value, ok := source[alias]; ok && value != nil {
			destination[name] = value
			return
		}
	}
}

func firstStringValue(values ...any) string {
	for _, value := range values {
		if text, ok := value.(string); ok && strings.TrimSpace(text) != "" {
			return strings.TrimSpace(text)
		}
	}
	return ""
}

func stringValue(value any) string {
	text, _ := value.(string)
	return strings.TrimSpace(text)
}

func (p *parser) parseCodex(line []byte) []api.AgentEvent {
	var record codexRecord
	if json.Unmarshal(line, &record) != nil {
		return nil
	}
	event := api.AgentEvent{
		Provider:  "codex",
		Timestamp: parseTimestamp(record.Timestamp),
	}
	switch record.Type {
	case "session_meta":
		// Session bookkeeping; the conversation itself carries the visible
		// state, so this adds only noise to the UI.
		return nil
	case "turn_context":
		var payload codexPayload
		if json.Unmarshal(record.Payload, &payload) != nil || payload.Model == "" || payload.Model == p.codexModel {
			return nil
		}
		p.codexModel = payload.Model
		return nil
	case "compacted":
		event.Type = "compaction"
		return []api.AgentEvent{event}
	case "response_item":
		var payload codexPayload
		if json.Unmarshal(record.Payload, &payload) != nil {
			event.Type = "unknown"
			event.Content = p.clip(string(record.Payload))
			return []api.AgentEvent{event}
		}
		if structured := projectStructuredAgentEvent("codex", payload.Type, record.Payload, event.Timestamp); structured != nil {
			return []api.AgentEvent{*structured}
		}
		switch payload.Type {
		case "message":
			event.ID = payload.ID
			switch payload.Role {
			case "user":
				event.Type = "user"
			case "developer":
				event.Type = "system_instructions"
			default:
				event.Type = "assistant"
				event.Model = p.codexModel
			}
			event.Content = p.content(payload.Content)
			if event.Content == "" {
				return nil
			}
			if event.Type == "assistant" {
				if event.Content == p.lastAssistantContent {
					return nil
				}
				p.lastAssistantContent = event.Content
			}
			if event.Type == "user" {
				if isSystemInjectedUserContext(event.Content) {
					event.Type = "system_instructions"
				} else {
					p.lastUserContent = event.Content
				}
			}
			if event.Type == "system_instructions" && strings.HasPrefix(event.Content, "Approved command prefix saved") {
				return nil
			}
			p.lastEventType = event.Type
			return []api.AgentEvent{event}
		case "reasoning":
			event.ID = payload.ID
			event.Type = "reasoning"
			event.Content = codexReasoningContent(payload, p.contentLimit)
			if event.Content == "" {
				return nil
			}
			if event.Content == p.lastReasoningContent {
				return nil
			}
			p.lastReasoningContent = event.Content
			p.lastEventType = "reasoning"
			return []api.AgentEvent{event}
		case "function_call", "local_shell_call":
			event.ID = payload.ID
			event.Type = "tool_call"
			event.ToolName = canonicalToolName("codex", payload.Name)
			event.CallID = payload.CallID
			if event.ToolName == "" && payload.Type == "local_shell_call" {
				event.ToolName = "shell"
			}
			if payload.Arguments != "" {
				event.ToolInput = parseArguments(payload.Arguments, p.contentLimit)
			} else if payload.Action.Command != "" {
				event.ToolInput = map[string]any{"command": payload.Action.Command}
			}
			event.Files = codexFiles(payload.Arguments, event.ToolName)
			if event.CallID != "" {
				p.codexCallTool[event.CallID] = event.ToolName
			}
			p.lastEventType = "tool_call"
			return []api.AgentEvent{event}
		case "function_call_output", "custom_tool_call_output":
			event.ID = payload.ID
			event.Type = "tool_output"
			event.CallID = payload.CallID
			event.ToolName = p.codexCallTool[event.CallID]
			event.Output, event.ToolStatus, event.Error = codexOutputDetails(payload.Output, p.contentLimit)
			if event.Output == "" {
				return nil
			}
			p.lastEventType = "tool_output"
			return []api.AgentEvent{event}
		case "web_search_call":
			event.ID = payload.ID
			event.Type = "tool_call"
			event.ToolName = "web_search"
			event.CallID = payload.ID
			event.ToolStatus = normalizeToolStatus(payload.Status)
			input := map[string]any{"type": payload.Action.Type}
			if len(payload.Action.Queries) > 0 {
				input["queries"] = payload.Action.Queries
			}
			if payload.Action.URL != "" {
				input["url"] = payload.Action.URL
			}
			event.ToolInput = input
			p.lastEventType = "tool_call"
			return []api.AgentEvent{event}
		case "custom_tool_call":
			event.ID = payload.ID
			event.Type = "tool_call"
			event.ToolName = canonicalToolName("codex", payload.Name)
			if event.ToolName == "" {
				event.ToolName = "custom_tool"
			}
			event.CallID = payload.CallID
			event.ToolStatus = normalizeToolStatus(payload.Status)
			event.ToolInput = codexCustomToolInput(payload.Input, event.ToolName, p.contentLimit)
			event.Files = codexFilesFromRaw(payload.Input, event.ToolName)
			if event.CallID != "" {
				p.codexCallTool[event.CallID] = event.ToolName
			}
			p.lastEventType = "tool_call"
			return []api.AgentEvent{event}
		default:
			event.Type = "unknown"
			event.ID = payload.ID
			event.Content = codexFallbackContent(payload, record.Payload, p.contentLimit)
			return []api.AgentEvent{event}
		}
	case "event_msg":
		var payload codexPayload
		if json.Unmarshal(record.Payload, &payload) != nil {
			return nil
		}
		if structured := projectStructuredAgentEvent("codex", payload.Type, record.Payload, event.Timestamp); structured != nil {
			return []api.AgentEvent{*structured}
		}
		switch payload.Type {
		case "token_count":
			event.Type = "usage"
			event.Model = payload.Info.Model
			if event.Model == "" {
				event.Model = p.codexModel
			}
			raw := payload.Info.LastTokenUsage
			if len(raw) == 0 {
				raw = payload.Info.TotalTokenUsage
			}
			event.Usage = parseUsage(raw)
			if event.Usage == nil {
				return nil
			}
			event.Content = "Token usage"
			return []api.AgentEvent{event}
		case "turn_aborted":
			p.tracker.TurnAborted()
			p.codexTurnFailed = false
			return nil
		case "error":
			message := codexErrorMessage(payload, p.contentLimit)
			if message == "" {
				return nil
			}
			p.tracker.TurnFailed()
			p.codexTurnFailed = true
			event.Type = "error"
			event.Content = p.clip(message)
			event.Error = event.Content
			return []api.AgentEvent{event}
		case "agent_message":
			content := p.clip(firstNonEmpty(payload.Message, p.content(payload.Content), payload.Text))
			if content == "" {
				return nil
			}
			if content == p.lastAssistantContent {
				return nil
			}
			p.lastAssistantContent = content
			event.Type = "assistant"
			event.Model = p.codexModel
			event.Content = content
			p.lastEventType = "assistant"
			return []api.AgentEvent{event}
		case "agent_reasoning":
			content := p.clip(firstNonEmpty(payload.Text, p.content(payload.Summary), p.content(payload.Content)))
			if content == "" {
				return nil
			}
			if content == p.lastReasoningContent {
				return nil
			}
			p.lastReasoningContent = content
			event.Type = "reasoning"
			event.Content = content
			p.lastEventType = "reasoning"
			return []api.AgentEvent{event}
		case "task_started":
			p.codexTurnFailed = false
			p.tracker.TurnStarted()
			return nil
		case "task_complete":
			if p.codexTurnFailed {
				p.codexTurnFailed = false
				p.tracker.TurnFailed()
				return nil
			}
			if message := codexErrorMessage(payload, p.contentLimit); message != "" {
				p.codexTurnFailed = true
				p.tracker.TurnFailed()
				event.Type = "error"
				event.Content = p.clip(message)
				event.Error = event.Content
				return []api.AgentEvent{event}
			}
			p.tracker.TurnComplete()
			return nil
		case "thread_settings_applied":
			// Internal bookkeeping with no user-visible event.
			return nil
		default:
			if payload.Type == "user_message" {
				content := p.content(payload.Content)
				if content == "" || content == p.lastUserContent {
					return nil
				}
				p.lastUserContent = content
				event.Type = "user"
				event.Content = content
				p.lastEventType = "user"
				return []api.AgentEvent{event}
			}
			return nil
		}
	default:
		return nil
	}
}

// codexErrorMessage extracts the human-readable error from either a legacy
// event_msg error (message/text) or a task_complete error envelope.
func codexErrorMessage(payload codexPayload, limit int) string {
	if payload.Message != "" {
		return payload.Message
	}
	if payload.Text != "" {
		return payload.Text
	}
	if content := contentStringLimit(payload.Content, limit); content != "" {
		return content
	}
	if len(payload.Error) == 0 {
		return ""
	}
	var text string
	if json.Unmarshal(payload.Error, &text) == nil && text != "" {
		return truncate(text, limit)
	}
	var wrapper struct {
		Message string `json:"message"`
	}
	if json.Unmarshal(payload.Error, &wrapper) == nil && wrapper.Message != "" {
		return truncate(wrapper.Message, limit)
	}
	return truncate(string(payload.Error), limit)
}

// codexFallbackContent extracts whatever human-readable text an unrecognized
// response item carries instead of dumping the raw JSON envelope.
func codexFallbackContent(payload codexPayload, raw json.RawMessage, limit int) string {
	for _, candidate := range []string{
		payload.Message,
		payload.Text,
		contentStringLimit(payload.Content, limit),
		contentStringLimit(payload.Summary, limit),
	} {
		if candidate != "" {
			return truncate(candidate, limit)
		}
	}
	return truncate(string(raw), limit)
}

func normalizeToolStatus(status string) string {
	switch status {
	case "completed":
		return "success"
	case "failed":
		return "error"
	case "interrupted", "cancelled":
		return "interrupted"
	default:
		return "running"
	}
}

// isSystemInjectedUserContext detects the startup context Codex injects as a
// user-role message (permissions instructions, AGENTS.md, environment
// context, collaboration mode). It is scaffolding, not a real user turn, so
// the UI collapses it instead of rendering it as a message.
func isSystemInjectedUserContext(content string) bool {
	return strings.HasPrefix(content, "<environment_context>") ||
		strings.HasPrefix(content, "# AGENTS.md") ||
		strings.HasPrefix(content, "<collaboration_mode>") ||
		strings.Contains(content, "<permissions instructions>")
}

func codexReasoningContent(payload codexPayload, limit int) string {
	if value := contentStringLimit(payload.Summary, limit); value != "" {
		return value
	}
	if value := contentStringLimit(payload.Content, limit); value != "" {
		return value
	}
	return truncate(payload.Text, limit)
}

func codexOutputString(value json.RawMessage, limit int) string {
	var text string
	if json.Unmarshal(value, &text) == nil {
		return truncate(text, limit)
	}
	if value := contentStringLimit(value, limit); value != "" {
		return value
	}
	return truncate(string(value), limit)
}

func codexOutputDetails(value json.RawMessage, limit int) (output, status, errorMessage string) {
	var text string
	if json.Unmarshal(value, &text) == nil {
		// Modern Codex wraps structured tool results in a JSON string. Try
		// that envelope first, then fall back to plain stdout.
		output, status, errorMessage = codexOutputDetails([]byte(text), limit)
		if status != "" || errorMessage != "" {
			return output, status, errorMessage
		}
		if output != "" {
			return truncate(text, limit), "success", ""
		}
		return truncate(text, limit), "success", ""
	}
	var wrapper struct {
		Output   string `json:"output"`
		Error    string `json:"error"`
		IsError  bool   `json:"is_error"`
		Metadata struct {
			ExitCode int    `json:"exit_code"`
			Error    string `json:"error"`
		} `json:"metadata"`
	}
	if json.Unmarshal(value, &wrapper) == nil {
		output = truncate(wrapper.Output, limit)
		if output == "" {
			output = contentStringLimit(value, limit)
		}
		switch {
		case wrapper.Error != "":
			errorMessage = wrapper.Error
			status = "error"
		case wrapper.IsError:
			status = "error"
		case wrapper.Metadata.ExitCode != 0:
			errorMessage = wrapper.Metadata.Error
			status = "error"
		default:
			status = "success"
		}
		return output, status, truncate(errorMessage, limit)
	}
	return contentStringLimit(value, limit), "success", ""
}

func parseArguments(value string, limit int) any {
	var parsed map[string]any
	if json.Unmarshal([]byte(value), &parsed) == nil {
		return parsed
	}
	return map[string]any{"raw": truncate(value, rawToolInputLimit(limit))}
}

func codexFiles(arguments, toolName string) []string {
	var files []string
	var parsed map[string]any
	if json.Unmarshal([]byte(arguments), &parsed) == nil {
		if path, ok := parsed["file_path"].(string); ok && path != "" {
			files = append(files, path)
		}
		if toolName == "apply_patch" {
			if patch, ok := parsed["patch"].(string); ok {
				files = append(files, patchFiles(patch)...)
			}
		}
	}
	return uniqueStrings(files)
}

// codexCustomToolInput turns a custom_tool_call input into the same shape the
// regular function_call path produces, so the UI can render both uniformly.
func codexCustomToolInput(value json.RawMessage, toolName string, limit int) any {
	var parsed any
	if json.Unmarshal(value, &parsed) != nil {
		return map[string]any{"raw": truncate(string(value), rawToolInputLimit(limit))}
	}
	switch input := parsed.(type) {
	case string:
		if toolName == "apply_patch" {
			return map[string]any{"patch": truncate(input, rawToolInputLimit(limit))}
		}
		return map[string]any{"raw": truncate(input, rawToolInputLimit(limit))}
	default:
		return input
	}
}

func rawToolInputLimit(contentLimit int) int {
	if contentLimit == 0 {
		return 0
	}
	return 64 * 1024
}

func codexFilesFromRaw(value json.RawMessage, toolName string) []string {
	var parsed any
	if json.Unmarshal(value, &parsed) != nil {
		return nil
	}
	switch input := parsed.(type) {
	case string:
		if toolName == "apply_patch" {
			return patchFiles(input)
		}
	case map[string]any:
		if path, ok := input["file_path"].(string); ok && path != "" {
			return []string{path}
		}
		if toolName == "apply_patch" {
			if patch, ok := input["patch"].(string); ok {
				return patchFiles(patch)
			}
		}
	}
	return nil
}

func patchFiles(patch string) []string {
	var files []string
	for _, line := range strings.Split(patch, "\n") {
		for _, marker := range []string{"*** Add File: ", "*** Update File: ", "*** Delete File: "} {
			if strings.HasPrefix(line, marker) {
				if name := strings.TrimSpace(strings.TrimPrefix(line, marker)); name != "" {
					files = append(files, name)
				}
				break
			}
		}
	}
	return uniqueStrings(files)
}

type claudeRecord struct {
	Type             string          `json:"type"`
	Subtype          string          `json:"subtype"`
	Timestamp        string          `json:"timestamp"`
	UUID             string          `json:"uuid"`
	DurationMs       int64           `json:"durationMs"`
	IsSidechain      bool            `json:"isSidechain"`
	IsMeta           bool            `json:"isMeta"`
	IsCompactSummary bool            `json:"isCompactSummary"`
	Content          json.RawMessage `json:"content"`
	Message          struct {
		ID         string          `json:"id"`
		Role       string          `json:"role"`
		Model      string          `json:"model"`
		StopReason string          `json:"stop_reason"`
		Content    json.RawMessage `json:"content"`
		Usage      json.RawMessage `json:"usage"`
	} `json:"message"`
	ToolUseResult struct {
		FilePath        string `json:"filePath"`
		StructuredPatch string `json:"structuredPatch"`
		Interrupted     bool   `json:"interrupted"`
	} `json:"toolUseResult"`
	Attachment struct {
		Type      string          `json:"type"`
		HookName  string          `json:"hookName"`
		HookEvent string          `json:"hookEvent"`
		Content   json.RawMessage `json:"content"`
		ExitCode  int             `json:"exitCode"`
	} `json:"attachment"`
}

type claudeBlock struct {
	Type      string          `json:"type"`
	Text      string          `json:"text"`
	Thinking  string          `json:"thinking"`
	Name      string          `json:"name"`
	ID        string          `json:"id"`
	Input     json.RawMessage `json:"input"`
	ToolUseID string          `json:"tool_use_id"`
	Content   json.RawMessage `json:"content"`
	IsError   bool            `json:"is_error"`
}

func (p *parser) parseClaude(line []byte) []api.AgentEvent {
	var record claudeRecord
	if json.Unmarshal(line, &record) != nil {
		return nil
	}
	timestamp := parseTimestamp(record.Timestamp)
	if structured := projectStructuredAgentEvent("claude", record.Type, line, timestamp); structured != nil {
		if structured.ID == "" {
			structured.ID = record.UUID
		}
		return []api.AgentEvent{*structured}
	}
	switch record.Type {
	case "summary", "last-prompt", "ai-title", "pr-link", "queue-operation",
		"permission-mode", "mode", "file-history-snapshot":
		return nil
	case "user":
		var blocks []claudeBlock
		if json.Unmarshal(record.Message.Content, &blocks) == nil {
			var events []api.AgentEvent
			sawToolResult := false
			for _, block := range blocks {
				if block.Type != "tool_result" {
					continue
				}
				sawToolResult = true
				// A tool_result answering a Claude structured tool closes the
				// card instead of leaking a bare tool_output. Question and
				// permission answer with a resolved event sharing the original
				// tool_use id; TodoWrite has no display value beyond the list.
				if kind := p.claudeInteractions[block.ToolUseID]; kind != "" {
					delete(p.claudeInteractions, block.ToolUseID)
					if kind == "question" || kind == "permission" {
						state := "resolved"
						if block.IsError {
							state = "cancelled"
						}
						title := "Question"
						if kind == "permission" {
							title = "Permission"
						}
						events = append(events, api.AgentEvent{
							Provider:  "claude",
							ID:        block.ToolUseID,
							Type:      kind,
							Payload:   map[string]any{"requestId": block.ToolUseID, "title": title, "state": state},
							Timestamp: timestamp,
						})
					}
					continue
				}
				output := p.content(block.Content)
				event := api.AgentEvent{
					Provider:  "claude",
					ID:        record.UUID,
					CallID:    block.ToolUseID,
					Type:      "tool_output",
					ToolName:  p.claudeCallTool[block.ToolUseID],
					Output:    output,
					Timestamp: timestamp,
				}
				if record.ToolUseResult.FilePath != "" {
					event.Files = []string{record.ToolUseResult.FilePath}
				}
				if record.ToolUseResult.Interrupted {
					event.ToolStatus = "interrupted"
				} else if block.IsError {
					event.ToolStatus = "error"
					event.Error = output
				} else {
					event.ToolStatus = "success"
				}
				events = append(events, event)
			}
			if sawToolResult {
				return events
			}
		}
		content := p.content(record.Message.Content)
		if content == "" {
			return nil
		}
		if strings.HasPrefix(strings.TrimSpace(content), "[Request interrupted") {
			p.tracker.TurnAborted()
			return []api.AgentEvent{{
				Provider:   "claude",
				ID:         record.UUID,
				Type:       "system",
				Content:    p.clip(content),
				StopReason: "interrupted",
				Sidechain:  record.IsSidechain,
				Timestamp:  timestamp,
			}}
		}
		if record.IsCompactSummary {
			return []api.AgentEvent{{
				Provider:  "claude",
				ID:        record.UUID,
				Type:      "system",
				Content:   p.clip(content),
				Timestamp: timestamp,
			}}
		}
		if record.IsMeta || strings.HasPrefix(strings.TrimSpace(content), "<") {
			return []api.AgentEvent{{
				Provider:  "claude",
				ID:        record.UUID,
				Type:      "system",
				Content:   p.clip(content),
				Timestamp: timestamp,
			}}
		}
		return []api.AgentEvent{{
			Provider:  "claude",
			ID:        record.UUID,
			Type:      "user",
			Content:   p.clip(content),
			Sidechain: record.IsSidechain,
			Timestamp: timestamp,
		}}
	case "assistant":
		var blocks []claudeBlock
		if json.Unmarshal(record.Message.Content, &blocks) != nil {
			content := p.content(record.Message.Content)
			if content == "" {
				return nil
			}
			return []api.AgentEvent{{
				Provider:   "claude",
				ID:         record.UUID,
				Type:       "assistant",
				Content:    p.clip(content),
				Model:      record.Message.Model,
				StopReason: record.Message.StopReason,
				Usage:      parseUsage(record.Message.Usage),
				Sidechain:  record.IsSidechain,
				Timestamp:  timestamp,
			}}
		}
		var events []api.AgentEvent
		for _, block := range blocks {
			event := api.AgentEvent{
				Provider:   "claude",
				ID:         firstNonEmpty(block.ID, record.UUID),
				Model:      record.Message.Model,
				StopReason: record.Message.StopReason,
				Usage:      parseUsage(record.Message.Usage),
				Sidechain:  record.IsSidechain,
				Timestamp:  timestamp,
			}
			switch block.Type {
			case "text":
				if record.IsSidechain {
					// Subagent text becomes a structured subagent event so
					// the UI renders it via the shared RFC 0010 subagent
					// path instead of an inline assistant bubble.
					event.Type = "subagent"
					event.Payload = map[string]any{
						"subagentId": record.UUID,
						"label":      "Subagent",
						"state":      "completed",
						"summary":    p.clip(block.Text),
					}
				} else {
					event.Type = "assistant"
					event.Content = p.clip(block.Text)
				}
			case "thinking", "redacted_thinking":
				event.Type = "reasoning"
				event.Content = p.clip(firstNonEmpty(block.Thinking, "…"))
			case "tool_use":
				canonicalName := canonicalToolName("claude", block.Name)
				switch canonicalName {
				case "ask_user_question":
					input, _ := rawToAny(block.Input, p.contentLimit).(map[string]any)
					event.Type = "question"
					event.Payload = claudeQuestionPayload(block.ID, input)
					if block.ID != "" {
						p.claudeInteractions[block.ID] = "question"
					}
				case "permission_request":
					input, _ := rawToAny(block.Input, p.contentLimit).(map[string]any)
					event.Type = "permission"
					event.Payload = claudePermissionPayload(block.ID, input)
					if block.ID != "" {
						p.claudeInteractions[block.ID] = "permission"
					}
				case "todowrite":
					input, _ := rawToAny(block.Input, p.contentLimit).(map[string]any)
					event.Type = "todo"
					event.ID = "claude-todos"
					event.Payload = claudeTodoPayload(input)
					if block.ID != "" {
						p.claudeInteractions[block.ID] = "todo"
					}
				default:
					event.Type = "tool_call"
					event.ToolName = canonicalName
					event.CallID = block.ID
					event.ToolInput = rawToAny(block.Input, p.contentLimit)
					if event.ToolName != "" && event.CallID != "" {
						p.claudeCallTool[event.CallID] = event.ToolName
					}
					if input, ok := event.ToolInput.(map[string]any); ok {
						if path, ok := input["file_path"].(string); ok && path != "" {
							event.Files = []string{path}
						}
					}
				}
			default:
				event.Type = "unknown"
				event.Content = p.clip(firstNonEmpty(block.Text, block.Thinking, p.content(block.Content), string(record.Message.Content)))
			}
			if event.Content != "" || event.ToolName != "" || event.Payload != nil {
				events = append(events, event)
			}
		}
		return events
	case "system":
		content := p.content(record.Content)
		if content == "" {
			return nil
		}
		if record.Subtype == "api_error" {
			return []api.AgentEvent{{
				Provider:  "claude",
				ID:        record.UUID,
				Type:      "error",
				Content:   p.clip(content),
				Error:     p.clip(content),
				Timestamp: timestamp,
			}}
		}
		return []api.AgentEvent{{
			Provider:   "claude",
			ID:         record.UUID,
			Type:       "system",
			Content:    p.clip(content),
			DurationMs: record.DurationMs,
			Timestamp:  timestamp,
		}}
	case "attachment":
		kind := record.Attachment.Type
		if kind == "" {
			kind = "attachment"
		}
		// Hooks are protocol noise. The state file (WARREN_STATE_FILE) and
		// the activity tracker already reflect hook outcomes, so emitting
		// a system event here would only pollute the agent view timeline
		// and break the tool_call/tool_output folding inside activity
		// groups by inserting a conversation-boundary event between them.
		if strings.HasPrefix(kind, "hook_") {
			return nil
		}
		if kind == "agent_listing_delta" || kind == "skill_listing" {
			content := p.content(record.Attachment.Content)
			if content == "" {
				return nil
			}
			return []api.AgentEvent{{
				Provider:  "claude",
				ID:        record.UUID,
				Type:      "system_instructions",
				Content:   content,
				Timestamp: timestamp,
			}}
		}
		content := p.clip(firstNonEmpty(p.content(record.Attachment.Content), p.content(record.Content)))
		if content == "" {
			return nil
		}
		return []api.AgentEvent{{
			Provider:  "claude",
			ID:        record.UUID,
			Type:      "attachment",
			Content:   content,
			Timestamp: timestamp,
		}}
	default:
		return nil
	}
}

func parseUsage(raw json.RawMessage) *api.AgentUsage {
	if len(raw) == 0 {
		return nil
	}
	var value struct {
		InputTokens              int64 `json:"input_tokens"`
		CacheCreationInputTokens int64 `json:"cache_creation_input_tokens"`
		CacheReadInputTokens     int64 `json:"cache_read_input_tokens"`
		CachedInputTokens        int64 `json:"cached_input_tokens"`
		OutputTokens             int64 `json:"output_tokens"`
		ReasoningOutputTokens    int64 `json:"reasoning_output_tokens"`
		TotalTokens              int64 `json:"total_tokens"`
	}
	if json.Unmarshal(raw, &value) != nil {
		return nil
	}
	if value.InputTokens == 0 && value.OutputTokens == 0 && value.TotalTokens == 0 {
		return nil
	}
	if value.CacheReadInputTokens == 0 {
		value.CacheReadInputTokens = value.CachedInputTokens
	}
	return &api.AgentUsage{
		InputTokens:              value.InputTokens,
		CacheCreationInputTokens: value.CacheCreationInputTokens,
		CacheReadInputTokens:     value.CacheReadInputTokens,
		OutputTokens:             value.OutputTokens,
		ReasoningOutputTokens:    value.ReasoningOutputTokens,
		TotalTokens:              value.TotalTokens,
	}
}

// contentString turns either a plain string or an array of text blocks into a
// single string, matching how both CLI transcripts represent message bodies.
func contentString(value json.RawMessage) string {
	return contentStringLimit(value, maxEventContent)
}

func contentStringLimit(value json.RawMessage, limit int) string {
	var text string
	if json.Unmarshal(value, &text) == nil {
		return truncate(text, limit)
	}
	var blocks []struct {
		Type    string          `json:"type"`
		Text    string          `json:"text"`
		Content json.RawMessage `json:"content"`
	}
	if json.Unmarshal(value, &blocks) == nil {
		if limit <= 0 {
			parts := make([]string, 0, len(blocks))
			for _, block := range blocks {
				switch {
				case block.Text != "":
					parts = append(parts, block.Text)
				case block.Type == "image":
					parts = append(parts, "[image]")
				case len(block.Content) > 0:
					parts = append(parts, contentStringLimit(block.Content, 0))
				}
			}
			return strings.Join(parts, "\n")
		}

		var content strings.Builder
		remaining := limit
		hasPart := false
		for _, block := range blocks {
			if block.Text == "" && block.Type != "image" && len(block.Content) == 0 {
				continue
			}
			if hasPart && appendStringPrefix(&content, "\n", &remaining) {
				return content.String() + "…"
			}

			var part string
			switch {
			case block.Text != "":
				part = block.Text
			case block.Type == "image":
				part = "[image]"
			default:
				nestedLimit := remaining
				if nestedLimit == 0 {
					nestedLimit = 1
				}
				part = contentStringLimit(block.Content, nestedLimit)
			}
			hasPart = true
			if appendStringPrefix(&content, part, &remaining) {
				return content.String() + "…"
			}
		}
		return content.String()
	}
	return truncate(string(value), limit)
}

// appendStringPrefix appends at most the remaining rune budget and reports
// whether value contains content beyond that budget.
func appendStringPrefix(builder *strings.Builder, value string, remaining *int) bool {
	if value == "" {
		return false
	}
	if *remaining <= 0 {
		return true
	}

	count := 0
	for index := range value {
		if count == *remaining {
			builder.WriteString(value[:index])
			*remaining = 0
			return true
		}
		count++
	}
	builder.WriteString(value)
	*remaining -= count
	return false
}

func rawToAny(value json.RawMessage, contentLimit int) any {
	var parsed any
	if json.Unmarshal(value, &parsed) == nil {
		return parsed
	}
	return map[string]any{"raw": truncate(string(value), rawToolInputLimit(contentLimit))}
}

func parseTimestamp(value string) time.Time {
	for _, layout := range []string{time.RFC3339Nano, time.RFC3339} {
		if parsed, err := time.Parse(layout, value); err == nil {
			return parsed
		}
	}
	return time.Time{}
}

func truncate(value string, limit int) string {
	if limit <= 0 || len(value) <= limit {
		return value
	}
	count := 0
	for index := range value {
		if count == limit {
			return value[:index] + "…"
		}
		count++
	}
	return value
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if value != "" {
			return value
		}
	}
	return ""
}

func uniqueStrings(values []string) []string {
	seen := make(map[string]bool, len(values))
	result := make([]string, 0, len(values))
	for _, value := range values {
		if value == "" || seen[value] {
			continue
		}
		seen[value] = true
		result = append(result, value)
	}
	return result
}

// asBool reads a JSON boolean that may also arrive as the string "true"/"1"
// from transcripts that store tool input loosely.
func asBool(value any) bool {
	switch typed := value.(type) {
	case bool:
		return typed
	case string:
		return typed == "true" || typed == "1"
	default:
		return false
	}
}

// claudeQuestionPayload maps Claude's AskUserQuestion tool input to the RFC
// 0010 question payload. Claude emits `question`/`header`/`multiSelect` and
// options that carry only a label, while RFC 0010 clients render `prompt`/
// `selection` and need a stable option id to echo back in
// agent.interaction.respond. The option label doubles as the id so the echoed
// answer is already the value Claude expects in its tool_result.
func claudeQuestionPayload(requestID string, input map[string]any) map[string]any {
	questions := make([]any, 0)
	if raw, ok := input["questions"].([]any); ok {
		for index, item := range raw {
			question, ok := item.(map[string]any)
			if !ok {
				continue
			}
			prompt := firstNonEmpty(stringValue(question["question"]), stringValue(question["header"]), "Question")
			selection := "single"
			if asBool(question["multiSelect"]) {
				selection = "multiple"
			}
			options := make([]any, 0)
			if rawOptions, ok := question["options"].([]any); ok {
				for optionIndex, optionItem := range rawOptions {
					option, ok := optionItem.(map[string]any)
					if !ok {
						continue
					}
					entry := map[string]any{
						"id":    firstNonEmpty(stringValue(option["label"]), fmt.Sprintf("option-%d", optionIndex)),
						"label": stringValue(option["label"]),
					}
					if description := stringValue(option["description"]); description != "" {
						entry["description"] = description
					}
					options = append(options, entry)
				}
			}
			questions = append(questions, map[string]any{
				"id":          fmt.Sprintf("q%d", index),
				"prompt":      prompt,
				"selection":   selection,
				"required":    true,
				"allowCustom": false,
				"options":     options,
			})
		}
	}
	return map[string]any{
		"requestId": requestID,
		"title":     "Question",
		"questions": questions,
		"state":     "pending",
	}
}

// claudePermissionPayload maps Claude's PermissionRequest tool input to the
// RFC 0010 permission payload. The tool name becomes the sanitized `action`
// summary and the decision choices become `options`; command arguments and
// other sensitive input are deliberately not copied across the boundary.
func claudePermissionPayload(requestID string, input map[string]any) map[string]any {
	action := stringValue(input["tool"])
	if action == "" {
		action = "tool"
	}
	return map[string]any{
		"requestId":   requestID,
		"title":       "Permission",
		"action":      action,
		"description": "Claude requests permission to run " + action,
		"options": []any{
			map[string]any{"id": "allow", "label": "Allow"},
			map[string]any{"id": "deny", "label": "Deny"},
			map[string]any{"id": "allow_always", "label": "Always allow"},
			map[string]any{"id": "deny_always", "label": "Always deny"},
		},
		"state": "pending",
	}
}

// claudeTodoPayload maps Claude's TodoWrite tool input to the RFC 0010 todo
// payload. Claude manages one todo list per session, so the card uses a stable
// id and each TodoWrite call overwrites the previous list instead of creating
// a duplicate card.
func claudeTodoPayload(input map[string]any) map[string]any {
	items := make([]any, 0)
	if raw, ok := input["todos"].([]any); ok {
		for _, item := range raw {
			todo, ok := item.(map[string]any)
			if !ok {
				continue
			}
			state := strings.ToLower(firstNonEmpty(stringValue(todo["status"]), "pending"))
			items = append(items, map[string]any{
				"label": stringValue(todo["content"]),
				"state": state,
			})
		}
	}
	overall := "completed"
	for _, item := range items {
		if todo, ok := item.(map[string]any); ok {
			if state := stringValue(todo["state"]); state != "completed" && state != "cancelled" {
				overall = "in_progress"
				break
			}
		}
	}
	return map[string]any{
		"todoId": "claude-todos",
		"title":  "Todos",
		"items":  items,
		"state":  overall,
	}
}
