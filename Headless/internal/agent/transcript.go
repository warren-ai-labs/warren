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
	"errors"
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
	// fastWatchInterval is used while a turn is likely to be producing
	// transcript rows: after Poke and while the parser reports work. Over a
	// relay the idle interval alone added up to half a second to every reply.
	fastWatchInterval = 50 * time.Millisecond
	// fastWatchHold keeps the fast interval for a while after the last poke or
	// new row, covering the gap before the CLI marks the turn as working.
	fastWatchHold = 3 * time.Second
	maxHistory    = 2000
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
	// PiRoot is the Pi sessions directory (default ~/.pi/agent/sessions).
	PiRoot string
}

// HistoricalUsageTranscript identifies one provider transcript that can be
// replayed for the explicit Usage rebuild. WorkspacePath is best effort: it is
// used only to restore project attribution and never determines whether the
// transcript is eligible for token accounting.
type HistoricalUsageTranscript struct {
	Provider      string
	Path          string
	WorkspacePath string
}

// HistoricalUsageTranscripts returns every JSONL transcript under the
// provider-owned history roots, for each provider whose transcripts carry token
// counts. Unlike Find, this deliberately has no "newest" or modification-time
// bound: the caller uses it for a one-shot historical Usage rebuild.
//
// Every provider that reports usage has to appear here. The rebuild replaces
// exactly what this enumerates, so a measured provider left out would keep
// stale aggregates that no maintenance action can ever correct.
func (f DefaultFinder) HistoricalUsageTranscripts(ctx context.Context) ([]HistoricalUsageTranscript, error) {
	codexRoot := firstNonEmptyPath(f.CodexRoot, defaultCodexSessionsRoot())
	roots := []struct {
		provider string
		roots    []string
		matches  func(string) bool
	}{
		{
			provider: "codex",
			// Codex history is not confined to one home. Tools that run several
			// accounts side by side -- codex-alias being the one in use here --
			// give each profile its own CODEX_HOME under <home>/profiles/<name>,
			// so a profile with an isolated sessions directory holds spend that
			// scanning only the primary root never sees.
			roots: append([]string{codexRoot}, codexProfileSessionRoots(codexRoot)...),
			matches: func(path string) bool {
				name := filepath.Base(path)
				return strings.HasPrefix(name, "rollout-") && strings.HasSuffix(name, ".jsonl")
			},
		},
		{
			provider: "claude",
			roots:    []string{firstNonEmptyPath(f.ClaudeRoot, defaultClaudeProjectsRoot())},
			matches: func(path string) bool {
				return strings.HasSuffix(filepath.Base(path), ".jsonl")
			},
		},
		{
			provider: "pi",
			roots:    []string{firstNonEmptyPath(f.PiRoot, defaultPiSessionsRoot())},
			matches: func(path string) bool {
				return strings.HasSuffix(filepath.Base(path), ".jsonl")
			},
		},
	}

	seen := make(map[string]struct{})
	var result []HistoricalUsageTranscript
	for _, root := range roots {
		for _, dir := range root.roots {
			files, err := historicalTranscriptFiles(ctx, dir, root.matches)
			if err != nil {
				return nil, err
			}
			for _, path := range files {
				if _, exists := seen[path]; exists {
					continue
				}
				seen[path] = struct{}{}
				result = append(result, HistoricalUsageTranscript{
					Provider:      root.provider,
					Path:          path,
					WorkspacePath: transcriptWorkspacePath(root.provider, path),
				})
			}
		}
	}
	sort.Slice(result, func(i, j int) bool {
		if result[i].Provider != result[j].Provider {
			return result[i].Provider < result[j].Provider
		}
		return result[i].Path < result[j].Path
	})
	return result, nil
}

// codexProfileSessionRoots returns the sessions directories of every Codex
// profile beside the given primary sessions root, resolved and deduplicated.
//
// Profiles routinely share one history: codex-alias links a profile's `sessions`
// to the source home so several accounts see the same conversations. Those links
// are dropped here rather than walked, because enumerating a directory twice
// under two names would read every rollout twice. Deduplication is by resolved
// path and not by file, so the cost is one Lstat per profile instead of a second
// pass over tens of thousands of transcripts.
//
// A profile whose sessions directory is genuinely its own is kept: it holds
// spend that scanning only the primary root cannot see.
func codexProfileSessionRoots(primary string) []string {
	primary = strings.TrimSpace(primary)
	if primary == "" {
		return nil
	}
	// The profile tree is a sibling of the sessions directory inside one
	// CODEX_HOME, which is what makes this work for a relocated home as well.
	entries, err := os.ReadDir(filepath.Join(filepath.Dir(primary), "profiles"))
	if err != nil {
		return nil
	}
	seen := map[string]struct{}{resolvedPath(primary): {}}
	var roots []string
	for _, entry := range entries {
		// A profile directory may itself be a link, so the type is not filtered
		// here; only the sessions path it leads to matters.
		candidate := resolvedPath(filepath.Join(filepath.Dir(primary), "profiles", entry.Name(), "sessions"))
		if candidate == "" {
			continue
		}
		if _, exists := seen[candidate]; exists {
			continue
		}
		seen[candidate] = struct{}{}
		roots = append(roots, candidate)
	}
	sort.Strings(roots)
	return roots
}

// resolvedPath is the path with symlinks followed, or the cleaned path when it
// cannot be resolved. A missing directory keeps its literal form so it still
// deduplicates against an identical sibling rather than collapsing to empty.
func resolvedPath(path string) string {
	if strings.TrimSpace(path) == "" {
		return ""
	}
	if resolved, err := filepath.EvalSymlinks(path); err == nil {
		return filepath.Clean(resolved)
	}
	return filepath.Clean(path)
}

func firstNonEmptyPath(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}

func historicalTranscriptFiles(ctx context.Context, root string, matches func(string) bool) ([]string, error) {
	info, err := os.Lstat(root)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, err
	}
	if !info.IsDir() || info.Mode()&fs.ModeSymlink != 0 {
		return nil, nil
	}
	var files []string
	err = filepath.WalkDir(root, func(path string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}
		if entry.IsDir() {
			return nil
		}
		if entry.Type()&fs.ModeSymlink != 0 || !entry.Type().IsRegular() || !matches(path) {
			return nil
		}
		files = append(files, path)
		return nil
	})
	if err != nil {
		return nil, err
	}
	sort.Strings(files)
	return files, nil
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
	matches := func(path string) bool {
		name := filepath.Base(path)
		if !strings.HasPrefix(name, "rollout-") || !strings.HasSuffix(name, ".jsonl") {
			return false
		}
		return transcriptCwdMatches(path, workspacePath, codexMetaCwd)
	}
	found, err := findNewest(ctx, root, after, matches)
	if err != nil || found != "" {
		return found, err
	}
	// Only once the primary home has nothing: a session running under a
	// profile-specific CODEX_HOME writes its rollout outside that root, so
	// without this it never gets a live transcript at all. Reached only on a
	// miss, so a session whose transcript is where it usually is pays nothing --
	// and the miss path already walks the primary tree, which is far larger than
	// a profile's.
	for _, profileRoot := range codexProfileSessionRoots(root) {
		found, err = findNewest(ctx, profileRoot, after, matches)
		if err != nil || found != "" {
			return found, err
		}
	}
	return "", nil
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

func transcriptWorkspacePath(provider, path string) string {
	switch strings.ToLower(strings.TrimSpace(provider)) {
	case "codex":
		return codexMetaCwd(path)
	case "claude":
		return claudeTranscriptCwd(path)
	case "pi":
		return piTranscriptCwd(path)
	default:
		return ""
	}
}

// piTranscriptCwd reads the workspace out of a pi session header, which is the
// transcript's first line.
func piTranscriptCwd(path string) string {
	data, err := readFirstLine(path, 1024*1024)
	if err != nil {
		return ""
	}
	var record struct {
		Type string `json:"type"`
		Cwd  string `json:"cwd"`
	}
	if json.Unmarshal(data, &record) != nil || record.Type != "session" {
		return ""
	}
	return record.Cwd
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
	cwd := claudeTranscriptCwd(path)
	return cwd != "" && samePath(cwd, workspacePath)
}

func claudeTranscriptCwd(path string) string {
	file, err := openRegularFile(path)
	if err != nil {
		return ""
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
		if json.Unmarshal(scanner.Bytes(), &record) == nil && strings.TrimSpace(record.Cwd) != "" {
			return record.Cwd
		}
	}
	return ""
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

// errTranscriptLineTooLong marks a line that exceeded the caller's byte cap.
// readBoundedLine drops the rest of that line before returning it, so a caller
// that chooses to tolerate the line can simply read the next one.
var errTranscriptLineTooLong = errors.New("transcript line too long")

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
			// Drop the rest of the line so the next read starts at a line
			// boundary even when this chunk already ended at the newline.
			if !bytes.HasSuffix(part, []byte("\n")) {
				_ = discardTranscriptLine(reader)
			}
			return nil, fmt.Errorf("transcript line exceeds %d bytes: %w", limit, errTranscriptLineTooLong)
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

// discardTranscriptLine consumes the rest of the line left behind by
// errTranscriptLineTooLong, returning io.EOF when no further line follows.
func discardTranscriptLine(reader *bufio.Reader) error {
	for {
		_, err := reader.ReadSlice('\n')
		switch err {
		case nil, io.EOF:
			return err
		case bufio.ErrBufferFull:
			continue
		default:
			return err
		}
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

// defaultPiSessionsRoot resolves Pi's session directory through the same
// overrides the CLI honors, so a relocated Pi home is still enumerable.
func defaultPiSessionsRoot() string {
	return PiSessionsRoot()
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
	fast      time.Duration
	hold      time.Duration
	poke      chan struct{}
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

	// subagentsDir is where this session's child transcripts live, when the
	// provider keeps them in a fixed location (Claude Code). subagents holds the
	// live child tailers keyed by stable subagent identity; seenSubagents keeps
	// every identity whose transcript was not resolvable yet so it is retried.
	subagentsDir  string
	subagents     map[string]*subagentTailer
	seenSubagents map[string]struct{}
	// subagentAttention holds each child's pending human-facing request, keyed
	// by subagent identity. The parent's reported status lifts one of these when
	// the parent itself is not already asking, so a child's approval turns the
	// parent row's dot orange even though the child never feeds the parent
	// parser.
	//
	// This is a guard, not a feature that currently fires. Measured over the
	// local corpus, no provider produces a child request to lift: Claude 3.x
	// persists no question or permission record inside a subagent transcript
	// (10,720 sidechain records carry an agentId; none is an ask), and Codex
	// spawns its subagent threads with approval disabled — every one of the 952
	// child turn contexts is approval_policy "never" with danger-full-access, so
	// a child never asks, and Codex does not persist approval requests in a
	// rollout at all. A provider that starts asking from a child thread will
	// make this path live again without any change here; until then the parent
	// row turns orange only for the parent's own request.
	subagentAttention map[string]api.AgentAttention
}

// EventPoller is implemented by Parsers that observe asynchronous states outside
// the transcript file (such as database queues).
type EventPoller interface {
	PollEvents() []api.AgentEvent
}

// TitleReporter is implemented by Parsers whose agent CLI names its own
// conversation. The provider already spends a model call on that name and the
// name describes the thread the CLI believes it is running, so Warren prefers
// it over its own title request. TakeTitle returns a pending title once and
// clears it; a provider that has not named the conversation yet returns "".
type TitleReporter interface {
	TakeTitle() string
}

// Start begins tailing path immediately in a background goroutine.
func Start(
	sessionID, provider, path string,
	onEvents func([]api.AgentEvent, api.AgentStatus),
	onStatus func(api.AgentStatus),
	onTurns func([]api.AgentTurn, bool),
) *Watcher {
	p := newParser(provider)
	var subagentsDir string
	if codex, ok := p.(*codexParser); ok {
		// The name Codex generates for a conversation is stored beside its
		// sessions tree, so the rollout path is what identifies the home the
		// name must be read from.
		codex.SetCodexHome(codexHomeFromTranscriptPath(path))
		if threadID := codexThreadIDFromTranscriptPath(path); threadID != "" {
			codex.SetThreadID(threadID)
		}
	}
	if claude, ok := p.(*claudeParser); ok {
		subagentsDir = claudeSubagentsDir(path)
		claude.SetSubagentsDir(subagentsDir)
	}
	watcher := &Watcher{
		sessionID:         sessionID,
		provider:          provider,
		path:              path,
		interval:          watchInterval,
		fast:              fastWatchInterval,
		hold:              fastWatchHold,
		poke:              make(chan struct{}, 1),
		onEvents:          onEvents,
		onStatus:          onStatus,
		onTurns:           onTurns,
		parser:            p,
		subagentsDir:      subagentsDir,
		subagents:         make(map[string]*subagentTailer),
		subagentAttention: make(map[string]api.AgentAttention),
		stop:              make(chan struct{}),
		done:              make(chan struct{}),
		ready:             make(chan struct{}),
	}
	go watcher.loop()
	return watcher
}

// TakeTitle returns a title the agent CLI generated for its own conversation,
// or "" when the provider does not name its own conversations or has not done
// so yet.
func (w *Watcher) TakeTitle() string {
	reporter, ok := w.parser.(TitleReporter)
	if !ok {
		return ""
	}
	return reporter.TakeTitle()
}

// codexHomeFromTranscriptPath returns the Codex configuration directory that
// owns a watched rollout. A rollout always lives in a `sessions` tree, so the
// parent of that tree is the home, whether it is the primary CODEX_HOME or a
// profile directory whose sessions are relocated. A path with no `sessions`
// ancestor falls back to the ambient CODEX_HOME.
func codexHomeFromTranscriptPath(path string) string {
	directory := filepath.Dir(filepath.Clean(path))
	for {
		if filepath.Base(directory) == "sessions" {
			if home := filepath.Dir(directory); home != "" && home != string(filepath.Separator) {
				return home
			}
			break
		}
		parent := filepath.Dir(directory)
		if parent == directory {
			break
		}
		directory = parent
	}
	return CodexHome()
}

// codexThreadIDFromTranscriptPath extracts the Codex conversation ID from a
// rollout filename. Current Codex names files as rollout-<timestamp>-<uuid>.jsonl;
// older/test fixtures may use rollout-<id>.jsonl, so retain that simple suffix
// as a fallback when no UUID-shaped suffix is present.
func codexThreadIDFromTranscriptPath(path string) string {
	base := filepath.Base(path)
	stem := strings.TrimSuffix(base, filepath.Ext(base))
	if !strings.HasPrefix(stem, "rollout-") {
		return ""
	}
	name := strings.TrimPrefix(stem, "rollout-")
	if name == "" {
		return ""
	}
	if len(name) >= 36 {
		candidate := name[len(name)-36:]
		if isUUIDLike(candidate) {
			return candidate
		}
	}
	return name
}

func isUUIDLike(value string) bool {
	if len(value) != 36 {
		return false
	}
	for index, character := range value {
		switch index {
		case 8, 13, 18, 23:
			if character != '-' {
				return false
			}
		default:
			if !((character >= '0' && character <= '9') ||
				(character >= 'a' && character <= 'f') ||
				(character >= 'A' && character <= 'F')) {
				return false
			}
		}
	}
	return true
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
	}
	if poller, ok := w.parser.(EventPoller); ok {
		events = append(events, poller.PollEvents()...)
	}
	events = w.collectSubagentEvents(events)
	w.lastStatus = w.status()
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
	close(w.ready)
	fastUntil := time.Time{}
	lastPoll := time.Now()
	timer := time.NewTimer(w.interval)
	defer timer.Stop()
	for {
		select {
		case <-w.stop:
			return
		case <-w.poke:
			fastUntil = time.Now().Add(w.hold)
			if !timer.Stop() {
				select {
				case <-timer.C:
				default:
				}
			}
			timer.Reset(w.fast)
			continue
		case <-timer.C:
		}
		events, next, currentFileInfo, err := readNewTracked(w.path, offset, w.parser, fileInfo)
		if err == nil {
			offset = next
			fileInfo = currentFileInfo
		}
		// External pollers (Codex's queue database) stay on the idle cadence;
		// only the cheap incremental file read runs at the fast interval.
		if poller, ok := w.parser.(EventPoller); ok && time.Since(lastPoll) >= w.interval {
			lastPoll = time.Now()
			events = append(events, poller.PollEvents()...)
		}
		events = w.collectSubagentEvents(events)
		status := w.status()
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
		if status := w.status(); !status.Equal(w.lastStatus) {
			w.lastStatus = status
			if w.onStatus != nil {
				w.onStatus(status)
			}
		}
		now := time.Now()
		if len(events) > 0 || w.lastStatus.Activity == api.AgentActivityWorking {
			fastUntil = now.Add(w.hold)
		}
		if now.Before(fastUntil) {
			timer.Reset(w.fast)
		} else {
			timer.Reset(w.interval)
		}
	}
}

// Poke tells the watcher that the CLI is about to write, typically because
// input was just submitted. It switches to the fast interval at once; the
// watcher drops back to the idle interval once the turn goes quiet.
func (w *Watcher) Poke() {
	if w == nil {
		return
	}
	select {
	case w.poke <- struct{}{}:
	default:
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
