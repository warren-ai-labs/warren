package agent

import (
	"context"
	"database/sql"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

// Subagent activity is a second transcript surface: the parent transcript only
// records that a child agent was spawned, while the child's own tool calls and
// messages live in a provider-owned file beside it. The Watcher tails those
// child files and merges their events into the parent stream, tagged with the
// child's stable identity so a client can render one row per subagent without
// guessing from text.
//
// Child events never feed the parent parser, so a subagent's turn, activity,
// attention, and usage cannot overwrite the conversation the Session is
// showing. They are marked Sidechain and carry payload.subagentId.

// subagentTailer polls one child transcript file. parser is a private parser for
// that child so its lifecycle state stays isolated from every other agent.
type subagentTailer struct {
	id       string
	path     string
	parser   Parser
	offset   int64
	fileInfo os.FileInfo
}

// claudeSubagentCall remembers a spawned Agent/Task call until its result names
// the child agent, because the spawn observation carries only presentation
// metadata.
type claudeSubagentCall struct {
	Label   string
	Summary string
}

// codexSubagentCall is the Codex equivalent: spawn_agent's arguments are known
// at the call, but the child thread identity arrives in the output.
type codexSubagentCall struct {
	Label   string
	Summary string
}

// collectSubagentEvents starts tailers for any subagent rows in the current
// batch and merges the child events. It repeats a bounded number of times so a
// subagent that spawns a nested subagent is picked up in the same poll.
func (w *Watcher) collectSubagentEvents(events []api.AgentEvent) []api.AgentEvent {
	for depth := 0; depth < 4; depth++ {
		added := w.trackSubagents(events)
		child := w.pollSubagents()
		if len(child) == 0 && added == 0 {
			break
		}
		events = append(events, child...)
	}
	return events
}

// trackSubagents records newly seen subagent rows and starts one tailer each.
// A row whose transcript cannot be resolved yet stays remembered and is retried
// on the next batch, so a provider that publishes the row before the child file
// is not lost. It returns how many tailers were started.
func (w *Watcher) trackSubagents(events []api.AgentEvent) int {
	if w.subagents == nil {
		w.subagents = make(map[string]*subagentTailer)
	}
	if w.seenSubagents == nil {
		w.seenSubagents = make(map[string]struct{})
	}
	for _, event := range events {
		if event.Type != "subagent" {
			continue
		}
		if id, ok := event.Payload["subagentId"].(string); ok {
			if id = strings.TrimSpace(id); id != "" {
				w.seenSubagents[id] = struct{}{}
			}
		}
	}
	added := 0
	for id := range w.seenSubagents {
		if _, exists := w.subagents[id]; exists {
			continue
		}
		path := w.resolveSubagentTranscript(id)
		if path == "" {
			continue
		}
		w.subagents[id] = &subagentTailer{
			id:     id,
			path:   path,
			parser: w.newSubagentParser(path),
		}
		added++
	}
	return added
}

// pollSubagents reads the new lines of every child transcript and tags them.
func (w *Watcher) pollSubagents() []api.AgentEvent {
	if len(w.subagents) == 0 {
		return nil
	}
	ids := make([]string, 0, len(w.subagents))
	for id := range w.subagents {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	var events []api.AgentEvent
	for _, id := range ids {
		tailer := w.subagents[id]
		read, next, info, err := readNewTracked(tailer.path, tailer.offset, tailer.parser, tailer.fileInfo)
		if err != nil {
			continue
		}
		tailer.offset, tailer.fileInfo = next, info
		for index := range read {
			if read[index].Payload == nil {
				read[index].Payload = make(map[string]any)
			}
			// A nested spawn row carries its own grandchild identity; only the
			// child's own activity is attributed to this tailer.
			if _, exists := read[index].Payload["subagentId"]; !exists {
				read[index].Payload["subagentId"] = tailer.id
			}
			read[index].Sidechain = true
			read[index].Turn = 0
			w.noteSubagentInteraction(read[index], tailer.id)
		}
		events = append(events, read...)
	}
	return events
}

// status is the parent parser's status, with a child's pending request lifted
// to the parent when the parent is not already asking. The child never feeds
// the parent parser, so its attention is derived here from the sidechain
// interaction events the tailer reads.
func (w *Watcher) status() api.AgentStatus {
	base := w.parser.Status()
	if base.Attention != nil || len(w.subagentAttention) == 0 {
		return base
	}
	var chosen *api.AgentAttention
	for _, attention := range w.subagentAttention {
		candidate := attention
		if chosen == nil || candidate.Since.Before(chosen.Since) {
			chosen = &candidate
		}
	}
	base.Attention = chosen
	return base
}

// noteSubagentInteraction folds one child event into the parent's waiting
// state. Only an explicit question or permission changes it; a child's tool
// calls and messages do not.
func (w *Watcher) noteSubagentInteraction(event api.AgentEvent, subagentID string) {
	kind, reason, requestID, pending, ok := childInteraction(event)
	if !ok {
		return
	}
	if pending {
		w.subagentAttention[subagentID] = api.AgentAttention{
			Kind:      kind,
			Reason:    reason,
			RequestID: requestID,
			Since:     event.Timestamp,
		}
		return
	}
	delete(w.subagentAttention, subagentID)
}

// childInteraction reports the human-facing request an interaction event
// carries. It reads the provider's pre-canonical spelling (`question`,
// `permission`, `confirmation`) because it runs in the Watcher, before the API
// layer canonicalizes the event.
func childInteraction(event api.AgentEvent) (kind api.AgentAttentionKind, reason, requestID string, pending, ok bool) {
	switch strings.ToLower(strings.TrimSpace(event.Type)) {
	case "question":
		kind, reason = api.AgentAttentionInput, "question"
	case "permission", "approval", "confirmation":
		kind, reason = api.AgentAttentionApproval, "permission"
	default:
		return "", "", "", false, false
	}
	requestID = firstNonEmpty(event.ID, payloadString(event.Payload, "requestId"))
	state := strings.ToLower(strings.TrimSpace(payloadString(event.Payload, "state")))
	switch state {
	case "", "pending", "requested", "asked", "waiting", "in_progress":
		pending = true
	}
	return kind, reason, requestID, pending, true
}

func payloadString(payload map[string]any, key string) string {
	if payload == nil {
		return ""
	}
	value, _ := payload[key].(string)
	return value
}

// newSubagentParser builds a private parser for a child transcript. Codex needs
// its home and thread identity to resolve its own nested threads; every Claude
// child shares the parent's subagents directory.
func (w *Watcher) newSubagentParser(path string) Parser {
	parser := newParser(w.provider)
	switch typed := parser.(type) {
	case *codexParser:
		typed.SetCodexHome(codexHomeFromTranscriptPath(path))
		if threadID := codexThreadIDFromTranscriptPath(path); threadID != "" {
			typed.SetThreadID(threadID)
		}
	case *claudeParser:
		typed.SetSubagentsDir(w.subagentsDir)
		typed.SetChildTranscript(true)
	}
	return parser
}

// resolveSubagentTranscript returns the child transcript for one stable
// subagent identity, or "" when the provider keeps no child transcript.
func (w *Watcher) resolveSubagentTranscript(id string) string {
	switch strings.ToLower(strings.TrimSpace(w.provider)) {
	case "claude":
		dir := w.subagentsDir
		if dir == "" {
			return ""
		}
		return filepath.Join(dir, "agent-"+id+".jsonl")
	case "codex":
		return codexSubagentRolloutPath(w.path, id)
	default:
		return ""
	}
}

// claudeSubagentsDir returns the directory where Claude Code stores the child
// transcripts of one session. Claude writes the parent as
// <project>/<session>.jsonl and every child, at any depth, as
// <project>/<session>/subagents/agent-<agent-id>.jsonl.
func claudeSubagentsDir(transcriptPath string) string {
	if strings.TrimSpace(transcriptPath) == "" {
		return ""
	}
	stem := strings.TrimSuffix(transcriptPath, filepath.Ext(transcriptPath))
	sessionID := filepath.Base(stem)
	if sessionID == "" || sessionID == filepath.Base(transcriptPath) {
		return ""
	}
	return filepath.Join(filepath.Dir(transcriptPath), sessionID, "subagents")
}

// codexSubagentRolloutPath resolves a child thread to its rollout file. The
// thread store is authoritative and names the exact path; a missing store falls
// back to the rollout filename convention, which ends in the thread id.
func codexSubagentRolloutPath(transcriptPath, threadID string) string {
	threadID = strings.TrimSpace(threadID)
	if threadID == "" {
		return ""
	}
	home := codexHomeFromTranscriptPath(transcriptPath)
	if path := readCodexSubagentRollout(home, threadID); path != "" {
		return path
	}
	return findCodexRolloutByThreadID(home, threadID)
}

// readCodexSubagentRollout reads one subagent thread's rollout path from the
// Codex thread store. Only thread_source='subagent' rows are consulted so a
// stale or unrelated row can never redirect the tailer at another conversation.
func readCodexSubagentRollout(home, threadID string) string {
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
	var rollout sql.NullString
	err = db.QueryRowContext(ctx,
		"SELECT rollout_path FROM threads WHERE id = ? AND thread_source = 'subagent'",
		threadID,
	).Scan(&rollout)
	if err != nil || !rollout.Valid {
		return ""
	}
	return strings.TrimSpace(rollout.String)
}

// findCodexRolloutByThreadID is the filename fallback for a thread store that is
// unavailable or predates the rollout_path column.
func findCodexRolloutByThreadID(home, threadID string) string {
	if home == "" || threadID == "" {
		return ""
	}
	suffix := "-" + threadID + ".jsonl"
	var found string
	_ = filepath.WalkDir(filepath.Join(home, "sessions"), func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if entry.IsDir() {
			return nil
		}
		if strings.HasSuffix(entry.Name(), suffix) {
			found = path
			return filepath.SkipAll
		}
		return nil
	})
	return found
}
