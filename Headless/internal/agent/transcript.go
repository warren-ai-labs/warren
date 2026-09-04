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
	case "qoder":
		// Qoder resolves through the injected --session-id binding; the
		// generic finder has no identity to search with.
		return "", nil
	case "antigravity":
		// Antigravity sessions are bound by the per-session lifecycle hook
		// Warren installs in hooks.json. Generic workspace-level DB lookup has
		// no session identity and would erroneously adopt unrelated prior conversations.
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
	file, openErr := openRegularFile(path)
	if openErr != nil {
		return nil, openErr
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
	parser    Parser

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
func readNew(path string, offset int64, parser Parser) ([]api.AgentEvent, int64, error) {
	events, next, _, err := readNewTracked(path, offset, parser, nil)
	return events, next, err
}

// readNewTracked is the Watcher's version of readNew. OpenCode compacts its
// cache by atomically replacing the JSONL file; size alone cannot tell whether
// an offset still belongs to the same inode, so a replacement always restarts
// at byte zero. The parser state then suppresses duplicate snapshots and
// projects only any delta that arrived while the watcher was behind.
func readNewTracked(path string, offset int64, parser Parser, previous os.FileInfo) ([]api.AgentEvent, int64, os.FileInfo, error) {
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
	if _, err := file.Seek(offset, io.SeekStart); err != nil {
		return nil, offset, info, err
	}
	data, err := io.ReadAll(file)
	if err != nil {
		return nil, offset, info, err
	}
	baseOffset := offset
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
