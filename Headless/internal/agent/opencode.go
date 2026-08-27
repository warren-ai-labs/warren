package agent

import (
	"context"
	"encoding/json"
	"io/fs"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

// OpenCode stores sessions as individual JSON files under its XDG data
// directory (mirrored onto the platform data dir on macOS/Windows). The layout
// is documented at https://github.com/anomalyco/opencode and summarized here:
//
//	storage/session/<projectID>/<sessionID>.json
//	storage/message/<sessionID>/<messageID>.json
//	storage/part/<messageID>/<partID>.json
//	storage/project/<projectID>.json   (maps a project id to its worktree)
//
// OpenCode does not emit a single append-only JSONL transcript, so Warren
// mirrors the relevant messages and parts into a managed JSONL cache file
// (see StartOpenCodeTailer) that the stock transcript Watcher can tail.

// OpenCodeStorageRoot returns the directory OpenCode uses for session storage.
// It follows the XDG Base Directory spec, ported onto the platform data dir on
// macOS (~/Library/Application Support) and Windows (%LOCALAPPDATA%). An
// explicit override wins.
func OpenCodeStorageRoot(override string) string {
	if override != "" {
		return override
	}
	if root := os.Getenv("OPENCODE_HOME"); root != "" {
		return filepath.Join(root, "storage")
	}
	if data := xdgDataHome(); data != "" {
		return filepath.Join(data, "opencode", "storage")
	}
	home, _ := os.UserHomeDir()
	if home == "" {
		return ""
	}
	return filepath.Join(home, ".local", "share", "opencode", "storage")
}

func xdgDataHome() string {
	if v := os.Getenv("XDG_DATA_HOME"); v != "" {
		return v
	}
	home, _ := os.UserHomeDir()
	if home == "" {
		return ""
	}
	if runtime.GOOS == "darwin" {
		return filepath.Join(home, "Library", "Application Support")
	}
	if runtime.GOOS == "windows" {
		return filepath.Join(os.Getenv("LOCALAPPDATA"), "opencode")
	}
	return filepath.Join(home, ".local", "share")
}

type openCodeSession struct {
	ID        string `json:"id"`
	ProjectID string `json:"projectID"`
	Directory string `json:"directory"`
	Cwd       string `json:"cwd"`
	Time      struct {
		Created  int64 `json:"created"`
		Updated  int64 `json:"updated"`
		Archived int64 `json:"archived"`
	} `json:"time"`
}

func (s openCodeSession) matchesCwd(root, workspacePath string) bool {
	if s.Directory != "" && samePath(s.Directory, workspacePath) {
		return true
	}
	if s.Cwd != "" && samePath(s.Cwd, workspacePath) {
		return true
	}
	if s.ProjectID != "" && s.ProjectID != "global" {
		projectPath := filepath.Join(root, "project", s.ProjectID+".json")
		if data, err := os.ReadFile(projectPath); err == nil {
			var project struct {
				Worktree string `json:"worktree"`
			}
			if json.Unmarshal(data, &project) == nil && project.Worktree != "" {
				return samePath(project.Worktree, workspacePath)
			}
		}
	}
	return false
}

// findNewestOpenCodeSession returns the path of the most recently updated
// OpenCode session JSON whose cwd matches workspacePath and that was created
// at or after the Warren session start.
func findNewestOpenCodeSession(ctx context.Context, root, workspacePath string, after time.Time) (string, error) {
	sessionDir := filepath.Join(root, "session")
	var candidates []fileCandidate
	walkErr := filepath.WalkDir(sessionDir, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if entry.IsDir() {
			return nil
		}
		if entry.Type()&fs.ModeSymlink != 0 {
			return nil
		}
		name := filepath.Base(path)
		if !strings.HasPrefix(name, "ses_") || !strings.HasSuffix(name, ".json") {
			return nil
		}
		data, rerr := os.ReadFile(path)
		if rerr != nil {
			return nil
		}
		var session openCodeSession
		if json.Unmarshal(data, &session) != nil || session.ID == "" {
			return nil
		}
		if !session.matchesCwd(root, workspacePath) {
			return nil
		}
		if !after.IsZero() && time.UnixMilli(session.Time.Created).Before(after) {
			return nil
		}
		info, ierr := entry.Info()
		if ierr != nil {
			return nil
		}
		candidates = append(candidates, fileCandidate{path: path, mod: info.ModTime()})
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

// openCodeTime is the timestamp envelope used by the mirrored JSONL cache.
type openCodeTime struct {
	Created   int64 `json:"created"`
	Completed int64 `json:"completed"`
}

// openCodePartState is the tool execution state attached to a tool part.
type openCodePartState struct {
	Status string          `json:"status"`
	Input  json.RawMessage `json:"input"`
	Output json.RawMessage `json:"output"`
}

// openCodePart mirrors one OpenCode message part.
type openCodePart struct {
	ID        string            `json:"id"`
	Type      string            `json:"type"`
	Text      string            `json:"text"`
	Reasoning string            `json:"reasoning"`
	Tool      string            `json:"tool"`
	State     openCodePartState `json:"state"`
}

// openCodeEnvelope is the normalized-per-message shape Warren writes into the
// cache file. parseOpenCode reads it back into provider-neutral events.
type openCodeEnvelope struct {
	Role       string       `json:"role"`
	Finish     string       `json:"finish"`
	ModelID    string       `json:"modelId"`
	ProviderID string       `json:"providerId"`
	Time       openCodeTime `json:"time"`
	Summary    struct {
		Title string `json:"title"`
	} `json:"summary"`
	Error json.RawMessage `json:"error"`
	Parts []openCodePart  `json:"parts"`
}

// openCodeMessage is the on-disk OpenCode message record.
type openCodeMessage struct {
	ID         string          `json:"id"`
	SessionID  string          `json:"sessionID"`
	Role       string          `json:"role"`
	Time       openCodeTime    `json:"time"`
	ModelID    string          `json:"modelID"`
	ProviderID string          `json:"providerID"`
	Finish     string          `json:"finish"`
	Error      json.RawMessage `json:"error"`
	Summary    struct {
		Title string `json:"title"`
	} `json:"summary"`
}

// parseOpenCode turns a mirrored OpenCode message envelope into normalized
// events that the shared ActivityTracker folds into an AgentStatus.
func (p *parser) parseOpenCode(line []byte) []api.AgentEvent {
	var env openCodeEnvelope
	if json.Unmarshal(line, &env) != nil {
		return nil
	}
	model := env.ModelID
	if env.ProviderID != "" {
		model = env.ProviderID + "/" + env.ModelID
	}
	timestamp := time.UnixMilli(env.Time.Created)
	switch env.Role {
	case "user":
		return []api.AgentEvent{{
			Provider:  "opencode",
			Type:      "user",
			Content:   p.clip(env.Summary.Title),
			Timestamp: timestamp,
		}}
	case "assistant":
		if len(env.Error) > 0 {
			content := openCodeErrorContent(env.Error, p.contentLimit)
			return []api.AgentEvent{{
				Provider:  "opencode",
				Type:      "error",
				Content:   p.clip(content),
				Error:     p.clip(content),
				Timestamp: timestamp,
			}}
		}
		var events []api.AgentEvent
		for _, part := range env.Parts {
			switch part.Type {
			case "text":
				if part.Text != "" {
					events = append(events, api.AgentEvent{
						Provider:  "opencode",
						Type:      "assistant",
						Content:   p.clip(part.Text),
						Model:     model,
						Timestamp: timestamp,
					})
				}
			case "reasoning":
				if part.Reasoning != "" {
					events = append(events, api.AgentEvent{
						Provider:  "opencode",
						Type:      "reasoning",
						Content:   p.clip(part.Reasoning),
						Model:     model,
						Timestamp: timestamp,
					})
				}
			}
		}
		for _, part := range env.Parts {
			if part.Type != "tool" {
				continue
			}
			toolName := part.Tool
			if toolName == "" {
				toolName = "tool"
			}
			events = append(events, api.AgentEvent{
				Provider:  "opencode",
				Type:      "tool_call",
				ToolName:  toolName,
				ToolInput: rawToAny(part.State.Input, p.contentLimit),
				Timestamp: timestamp,
			})
			output, status, errMsg := openCodeToolOutput(part.State, p.contentLimit)
			toolEvent := api.AgentEvent{
				Provider:   "opencode",
				Type:       "tool_output",
				ToolName:   toolName,
				ToolStatus: status,
				Output:     output,
				Timestamp:  timestamp,
			}
			if errMsg != "" {
				toolEvent.Error = errMsg
			}
			events = append(events, toolEvent)
		}
		if env.Finish == "end_turn" {
			if len(events) == 0 {
				events = append(events, api.AgentEvent{
					Provider:  "opencode",
					Type:      "assistant",
					Model:     model,
					Timestamp: timestamp,
				})
			}
			events[len(events)-1].StopReason = "end_turn"
		}
		return events
	default:
		return nil
	}
}

func openCodeErrorContent(raw json.RawMessage, limit int) string {
	if len(raw) == 0 {
		return ""
	}
	var message string
	if json.Unmarshal(raw, &message) == nil && message != "" {
		return truncate(message, limit)
	}
	var wrapper struct {
		Name    string `json:"name"`
		Message string `json:"message"`
	}
	if json.Unmarshal(raw, &wrapper) == nil {
		if wrapper.Message != "" {
			return truncate(wrapper.Message, limit)
		}
		if wrapper.Name != "" {
			return truncate(wrapper.Name, limit)
		}
	}
	return truncate(string(raw), limit)
}

func openCodeToolOutput(state openCodePartState, limit int) (output, status, errMsg string) {
	status = normalizeToolStatus(state.Status)
	if status == "" {
		status = "success"
	}
	output = contentStringLimit(state.Output, limit)
	if status == "error" {
		errMsg = output
	}
	return output, status, errMsg
}

// OpenCodeTailer mirrors the newest OpenCode session for a Warren session into
// a JSONL cache file that the transcript Watcher tails. It is best-effort: a
// missing or rotated session simply yields no new lines.
type OpenCodeTailer struct {
	cachePath string
	workspace string
	after     time.Time
	interval  time.Duration
	mu        sync.Mutex
	seen      map[string]bool
	stop      chan struct{}
	done      chan struct{}
	once      sync.Once
}

// StartOpenCodeTailer begins mirroring in a background goroutine and returns
// the handle used to stop it.
func StartOpenCodeTailer(cachePath, workspace string, after time.Time) *OpenCodeTailer {
	t := &OpenCodeTailer{
		cachePath: cachePath,
		workspace: workspace,
		after:     after,
		interval:  watchInterval,
		seen:      map[string]bool{},
		stop:      make(chan struct{}),
		done:      make(chan struct{}),
	}
	go t.loop()
	return t
}

// Close stops the mirror and removes the cache file.
func (t *OpenCodeTailer) Close() {
	t.once.Do(func() {
		close(t.stop)
		<-t.done
		os.Remove(t.cachePath)
	})
}

// Path returns the cache file the transcript Watcher tails.
func (t *OpenCodeTailer) Path() string { return t.cachePath }

func (t *OpenCodeTailer) loop() {
	defer close(t.done)
	t.poll()
	ticker := time.NewTicker(t.interval)
	defer ticker.Stop()
	for {
		select {
		case <-t.stop:
			return
		case <-ticker.C:
			t.poll()
		}
	}
}

func (t *OpenCodeTailer) poll() {
	root := OpenCodeStorageRoot("")
	if root == "" {
		return
	}
	sessionPath, err := findNewestOpenCodeSession(context.Background(), root, t.workspace, t.after)
	if err != nil || sessionPath == "" {
		return
	}
	data, err := os.ReadFile(sessionPath)
	if err != nil {
		return
	}
	var session openCodeSession
	if json.Unmarshal(data, &session) != nil || session.ID == "" {
		return
	}
	messagesDir := filepath.Join(root, "message", session.ID)
	entries, err := os.ReadDir(messagesDir)
	if err != nil {
		return
	}
	type indexed struct {
		path string
		msg  openCodeMessage
	}
	var messages []indexed
	for _, entry := range entries {
		if entry.IsDir() || entry.Type()&fs.ModeSymlink != 0 {
			continue
		}
		if !strings.HasPrefix(entry.Name(), "msg_") || !strings.HasSuffix(entry.Name(), ".json") {
			continue
		}
		raw, rerr := os.ReadFile(filepath.Join(messagesDir, entry.Name()))
		if rerr != nil {
			continue
		}
		var msg openCodeMessage
		if json.Unmarshal(raw, &msg) != nil || msg.ID == "" {
			continue
		}
		messages = append(messages, indexed{filepath.Join(messagesDir, entry.Name()), msg})
	}
	sort.Slice(messages, func(i, j int) bool {
		return messages[i].msg.Time.Created < messages[j].msg.Time.Created
	})
	for _, item := range messages {
		t.mu.Lock()
		already := t.seen[item.msg.ID]
		t.mu.Unlock()
		if already {
			continue
		}
		env := t.buildEnvelope(root, item.msg)
		if payload, merr := json.Marshal(env); merr == nil {
			t.appendLine(payload)
		}
		t.mu.Lock()
		t.seen[item.msg.ID] = true
		t.mu.Unlock()
	}
}

func (t *OpenCodeTailer) buildEnvelope(root string, msg openCodeMessage) openCodeEnvelope {
	env := openCodeEnvelope{
		Role:       msg.Role,
		Finish:     msg.Finish,
		ModelID:    msg.ModelID,
		ProviderID: msg.ProviderID,
		Time:       openCodeTime{Created: msg.Time.Created, Completed: msg.Time.Completed},
		Summary:    msg.Summary,
		Error:      msg.Error,
	}
	partsDir := filepath.Join(root, "part", msg.ID)
	entries, err := os.ReadDir(partsDir)
	if err != nil {
		return env
	}
	for _, entry := range entries {
		if entry.IsDir() || entry.Type()&fs.ModeSymlink != 0 {
			continue
		}
		if !strings.HasPrefix(entry.Name(), "prt_") || !strings.HasSuffix(entry.Name(), ".json") {
			continue
		}
		raw, rerr := os.ReadFile(filepath.Join(partsDir, entry.Name()))
		if rerr != nil {
			continue
		}
		var part openCodePart
		if json.Unmarshal(raw, &part) != nil {
			continue
		}
		env.Parts = append(env.Parts, part)
	}
	return env
}

func (t *OpenCodeTailer) appendLine(payload []byte) {
	f, err := os.OpenFile(t.cachePath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return
	}
	defer f.Close()
	if _, err := f.Write(payload); err != nil {
		return
	}
	f.Write([]byte("\n"))
}
