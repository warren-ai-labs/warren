package server

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"strings"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/git"
	"github.com/abcdlsj/warren/Headless/internal/store"
)

// Bounds on what a handoff reads and writes.
const (
	// handoffHistoryPages bounds the journal pages one brief reads, so a very
	// long Session cannot turn the request into a full table scan.
	handoffHistoryPages = 40
	handoffHistoryPage  = 500
	// handoffUserBudget is the characters of the person's own messages an
	// extracted brief carries. The newest messages are kept when it is spent.
	handoffUserBudget  = 6_000
	handoffUserMessage = 1_500
	handoffReplyBudget = 3_000
	handoffFileLimit   = 40
	handoffChangeLimit = 30
	// handoffAgentTimeout bounds the turn in which the source Agent writes
	// its brief.
	handoffAgentTimeout = 5 * time.Minute
	handoffAgentPoll    = 500 * time.Millisecond
	// A new terminal Agent has drawn its prompt once its output has been
	// still for handoffDraftQuiet, and not before handoffDraftMinimum.
	handoffDraftQuiet   = 1500 * time.Millisecond
	handoffDraftMinimum = 2 * time.Second
	handoffDraftTimeout = 45 * time.Second
	handoffDraftPoll    = 50 * time.Millisecond
)

// handoffAgentPrompt is the turn the source Agent answers with its brief.
const handoffAgentPrompt = `Warren is handing this work to a fresh agent session that cannot see this conversation. Write the handoff brief it will start from.

Use these sections. Keep each one short and leave out a section that has nothing in it:

## Goal
## Decisions (each with its reason)
## Files that matter (paths)
## Current state (what works, what is verified, what is not)
## Next steps
## Ruled out (approaches tried or rejected, and why)
## Open questions for the user

Write facts, not narration. Do not run tools or change anything; answer from what you already know. Reply with the brief only.`

// handoffCacheTTL is the prompt-cache lifetime assumed for a provider and
// model, in seconds, and whether that value is an estimate.
//
// Anthropic documents 5 minutes by default (1 hour on request, which the
// transcripts do not reveal), so Claude is counted at the shorter one. OpenAI
// documents 5 to 10 minutes of inactivity; the lower bound is used. Gemini's
// implicit cache has no published lifetime. pi runs whichever model it is
// configured with, so its model family decides.
func handoffCacheTTL(provider, model string) (int, bool) {
	const fiveMinutes = 300
	family := strings.ToLower(provider)
	if family == "pi" || family == "opencode" {
		lowered := strings.ToLower(model)
		switch {
		case strings.Contains(lowered, "claude"):
			family = "claude"
		case strings.Contains(lowered, "gpt") || strings.Contains(lowered, "codex"):
			family = "codex"
		}
	}
	switch family {
	case "claude":
		return fiveMinutes, false
	default:
		return fiveMinutes, true
	}
}

// handoffEvent is the part of a canonical event payload a handoff reads.
// Payloads are decoded through JSON because journal rows and in-memory events
// hold the same fields with different Go types.
type handoffEvent struct {
	Role         string          `json:"role"`
	Content      string          `json:"content"`
	ContentDelta bool            `json:"contentDelta"`
	Model        string          `json:"model"`
	ToolKind     string          `json:"toolKind"`
	ToolInput    map[string]any  `json:"toolInput"`
	Files        []string        `json:"files"`
	Sidechain    bool            `json:"sidechain"`
	Usage        *api.AgentUsage `json:"usage"`
	Diff         *struct {
		File  string   `json:"file"`
		Files []string `json:"files"`
	} `json:"diff"`
}

// editedFiles is the files an edit or write tool names. Providers that report
// no file list, such as pi, name the file in the tool's input.
func (event handoffEvent) editedFiles() []string {
	if len(event.Files) > 0 {
		return event.Files
	}
	for _, key := range []string{"path", "file_path", "filePath", "file"} {
		if path := agentStringValue(event.ToolInput[key]); path != "" {
			return []string{path}
		}
	}
	return nil
}

func decodeHandoffEvent(event api.CanonicalAgentEvent) handoffEvent {
	var value handoffEvent
	if raw, err := json.Marshal(event.Payload); err == nil {
		_ = json.Unmarshal(raw, &value)
	}
	return value
}

func isHandoffMessage(eventType string) bool {
	switch eventType {
	case "message", "message.created", "message.completed":
		return true
	}
	return false
}

// handoffSource is one Session's events as a handoff reads them.
type handoffSource struct {
	session    api.Session
	provider   string
	streamID   string
	workspace  string
	events     []api.CanonicalAgentEvent
	truncated  bool
	execution  api.AgentExecution
	hasRuntime bool
}

func (s *Service) handoffSource(ctx context.Context, sessionID string) (handoffSource, error) {
	sessionID = strings.TrimSpace(sessionID)
	session, ok := s.sessionInAnyLifecycle(sessionID)
	if !ok {
		return handoffSource{}, fmt.Errorf("session not found: %s", sessionID)
	}
	source := handoffSource{session: session, provider: agentSessionProvider(session)}
	if !scheduleSessionIsAgent(session) {
		return handoffSource{}, fmt.Errorf("session %s is not an Agent", sessionID)
	}
	source.workspace, _ = sessionWorkingDirectory(s.Store.Snapshot(), session.WorkspaceID)
	if execution, found := s.canonicalExecutionForSession(sessionID); found {
		source.execution = execution
		source.streamID = execution.StreamID
		source.hasRuntime = true
	}
	if source.streamID == "" {
		source.streamID = strings.TrimSpace(session.AgentExecutionID)
	}
	if source.streamID == "" {
		return source, nil
	}
	var before uint64
	for page := 0; page < handoffHistoryPages; page++ {
		result, err := s.canonicalHistoryPage(ctx, source.streamID, 0, before, handoffHistoryPage)
		var boundary *store.CanonicalHistoryBoundary
		if errors.As(err, &boundary) {
			break
		}
		if err != nil {
			return handoffSource{}, err
		}
		source.events = append(append([]api.CanonicalAgentEvent(nil), result.Events...), source.events...)
		if !result.HasMore || len(result.Events) == 0 {
			return source, nil
		}
		before = result.Events[0].Sequence
	}
	source.truncated = true
	return source, nil
}

// HandoffStatus reports the source Session's last model response and the
// cache lifetime to count it against.
func (s *Service) HandoffStatus(ctx context.Context, request api.HandoffStatusRequest) (api.HandoffStatus, error) {
	source, err := s.handoffSource(ctx, request.Session)
	if err != nil {
		return api.HandoffStatus{}, err
	}
	status := api.HandoffStatus{Session: source.session.ID, Provider: source.provider}
	var last time.Time
	for _, event := range source.events {
		eventType := strings.ToLower(event.Type)
		payload := decodeHandoffEvent(event)
		if payload.Sidechain {
			continue
		}
		isReply := isHandoffMessage(eventType) && payload.Role == "assistant"
		if eventType == "config.updated" && payload.Model != "" {
			status.Model = payload.Model
		}
		if isReply && payload.Model != "" {
			status.Model = payload.Model
		}
		if payload.Usage != nil {
			status.ContextTokens = payload.Usage.InputTokens + payload.Usage.CacheReadInputTokens + payload.Usage.CacheCreationInputTokens
		}
		if (isReply || payload.Usage != nil) && event.OccurredAt.After(last) {
			last = event.OccurredAt
		}
	}
	if !last.IsZero() {
		status.LastResponseAt = &last
	}
	status.CacheTTL, status.Estimated = handoffCacheTTL(status.Provider, status.Model)
	status.CanAsk = s.handoffCanAsk(source)
	return status, nil
}

func (s *Service) handoffCanAsk(source handoffSource) bool {
	if source.session.Lifecycle != "running" || !source.hasRuntime {
		return false
	}
	agentStatus := s.agentStatus(source.session.ID)
	switch agentStatus.Activity {
	case api.AgentActivityWorking, api.AgentActivityBlocked, api.AgentActivityExited:
		return false
	}
	return agentStatus.Attention == nil || agentStatus.Attention.Kind != api.AgentAttentionApproval
}

// HandoffBrief returns the text a new Session should start from.
func (s *Service) HandoffBrief(ctx context.Context, request api.HandoffBriefRequest) (api.HandoffBriefResult, error) {
	mode := request.Mode
	if mode == "" {
		mode = api.HandoffBriefExtract
	}
	if mode != api.HandoffBriefExtract && mode != api.HandoffBriefAgent {
		return api.HandoffBriefResult{}, fmt.Errorf("unknown handoff mode %q", mode)
	}
	source, err := s.handoffSource(ctx, request.Session)
	if err != nil {
		return api.HandoffBriefResult{}, err
	}
	var brief string
	if mode == api.HandoffBriefAgent {
		if !s.handoffCanAsk(source) {
			return api.HandoffBriefResult{}, errors.New("the Agent cannot write a brief now: it is busy, waiting on you, or not running")
		}
		brief, err = s.askAgentForBrief(ctx, source)
		if err != nil {
			return api.HandoffBriefResult{}, err
		}
	} else {
		brief = extractHandoffBrief(source.events, source.truncated, source.workspace)
	}
	text := composeHandoffText(source, brief, s.handoffWorkspaceSection(ctx, source.workspace))
	return api.HandoffBriefResult{Session: source.session.ID, Mode: mode, Text: text}, nil
}

// askAgentForBrief sends the brief prompt as a turn of the source Agent and
// returns its final reply.
func (s *Service) askAgentForBrief(ctx context.Context, source handoffSource) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, handoffAgentTimeout)
	defer cancel()
	sessionID := source.session.ID
	head := source.execution.HeadSequence
	turnBefore := s.agentTurn(sessionID).ID
	if _, err := s.sendAgentMessage(ctx, api.AgentMessageSendRequest{
		Session:         sessionID,
		ClientMessageID: "handoff-" + store.NewID(),
		Text:            handoffAgentPrompt,
	}); err != nil {
		return "", fmt.Errorf("ask the Agent for a brief: %w", err)
	}
	sawWorking := false
	for {
		execution, _ := s.canonicalExecutionForSession(sessionID)
		turn := s.agentTurn(sessionID)
		if execution.State == api.AgentExecutionWorking {
			sawWorking = true
		}
		done := false
		switch {
		case turn.ID > turnBefore && turn.Status == api.AgentTurnCompleted:
			done = true
		case turn.ID > turnBefore && turn.Status != api.AgentTurnStarted && turn.Status != api.AgentTurnIdle:
			return "", fmt.Errorf("the Agent's brief turn ended as %s", turn.Status)
		case turn.ID == turnBefore && sawWorking && execution.State == api.AgentExecutionReady:
			done = true
		}
		if done {
			reply, err := s.handoffReplyAfter(ctx, source.streamID, head)
			if err != nil {
				return "", err
			}
			if strings.TrimSpace(reply) == "" {
				return "", errors.New("the Agent finished without writing a brief")
			}
			return reply, nil
		}
		timer := time.NewTimer(handoffAgentPoll)
		select {
		case <-ctx.Done():
			timer.Stop()
			return "", fmt.Errorf("waiting for the Agent's brief: %w", ctx.Err())
		case <-timer.C:
		}
	}
}

// handoffReplyAfter returns the last assistant message recorded after head.
// The transcript watcher can trail the turn's end, so an empty read is retried
// briefly before it is reported.
func (s *Service) handoffReplyAfter(ctx context.Context, streamID string, head uint64) (string, error) {
	for attempt := 0; attempt < 10; attempt++ {
		reply := ""
		after := head
		for page := 0; page < handoffHistoryPages; page++ {
			result, err := s.canonicalHistoryPage(ctx, streamID, after, 0, handoffHistoryPage)
			if err != nil {
				return "", err
			}
			for _, event := range result.Events {
				if event.Sequence <= head || !isHandoffMessage(strings.ToLower(event.Type)) {
					continue
				}
				payload := decodeHandoffEvent(event)
				if payload.Role == "assistant" && !payload.Sidechain && strings.TrimSpace(payload.Content) != "" {
					reply = payload.Content
				}
			}
			if !result.HasMore || len(result.Events) == 0 {
				break
			}
			after = result.Events[len(result.Events)-1].Sequence
		}
		if reply != "" {
			return strings.TrimSpace(reply), nil
		}
		timer := time.NewTimer(handoffAgentPoll)
		select {
		case <-ctx.Done():
			timer.Stop()
			return "", ctx.Err()
		case <-timer.C:
		}
	}
	return "", nil
}

// extractHandoffBrief assembles a brief from recorded events alone: the
// person's messages verbatim, the files the Agent changed, and its last reply.
func extractHandoffBrief(events []api.CanonicalAgentEvent, truncated bool, workspace string) string {
	type message struct{ id, text string }
	var users []message
	userIndex := map[string]int{}
	var reply string
	var files []string
	fileIndex := map[string]int{}
	addFile := func(path string) {
		path = handoffRelativePath(strings.TrimSpace(path), workspace)
		if path == "" {
			return
		}
		if index, ok := fileIndex[path]; ok {
			files = append(files[:index], files[index+1:]...)
			for key, value := range fileIndex {
				if value > index {
					fileIndex[key] = value - 1
				}
			}
		}
		fileIndex[path] = len(files)
		files = append(files, path)
	}
	for _, event := range events {
		eventType := strings.ToLower(event.Type)
		payload := decodeHandoffEvent(event)
		if payload.Sidechain {
			continue
		}
		switch {
		case isHandoffMessage(eventType):
			text := strings.TrimSpace(payload.Content)
			if text == "" || payload.ContentDelta {
				continue
			}
			switch payload.Role {
			case "user":
				if text == handoffAgentPrompt {
					continue
				}
				id := agentStringValue(event.Payload["messageId"])
				if id == "" {
					id = event.EventID
				}
				if index, ok := userIndex[id]; ok {
					users[index].text = text
					continue
				}
				userIndex[id] = len(users)
				users = append(users, message{id: id, text: text})
			case "assistant":
				reply = text
			}
		case strings.HasPrefix(eventType, "tool."):
			if payload.ToolKind == "edit" || payload.ToolKind == "write" {
				for _, file := range payload.editedFiles() {
					addFile(file)
				}
			}
		case eventType == "diff.updated":
			if payload.Diff != nil {
				addFile(payload.Diff.File)
				for _, file := range payload.Diff.Files {
					addFile(file)
				}
			}
		}
	}

	var builder strings.Builder
	if len(users) > 0 {
		builder.WriteString("## What I asked for\n\nMy messages in the earlier session, oldest first")
		kept := make([]string, 0, len(users))
		budget := handoffUserBudget
		for index := len(users) - 1; index >= 0 && budget > 0; index-- {
			text := clipHandoffText(users[index].text, min(handoffUserMessage, budget))
			budget -= len(text)
			kept = append([]string{text}, kept...)
		}
		if len(kept) < len(users) || truncated {
			builder.WriteString(" (earlier ones left out)")
		}
		builder.WriteString(":\n\n")
		for _, text := range kept {
			builder.WriteString(quoteHandoffText(text))
			builder.WriteString("\n\n")
		}
	}
	if len(files) > 0 {
		builder.WriteString("## Files the agent changed\n\n")
		if len(files) > handoffFileLimit {
			files = files[len(files)-handoffFileLimit:]
		}
		for _, file := range files {
			builder.WriteString("- " + file + "\n")
		}
		builder.WriteString("\n")
	}
	if reply != "" {
		builder.WriteString("## The agent's last reply\n\n")
		builder.WriteString(quoteHandoffText(clipHandoffText(reply, handoffReplyBudget)))
		builder.WriteString("\n\n")
	}
	return strings.TrimSpace(builder.String())
}

// handoffRelativePath names a file inside the Workspace relative to it, the
// way Git status does.
func handoffRelativePath(path, workspace string) string {
	if path == "" || workspace == "" || !filepath.IsAbs(path) {
		return path
	}
	for _, root := range []string{workspace, handoffResolvedPath(workspace)} {
		if relative, err := filepath.Rel(root, path); err == nil && !strings.HasPrefix(relative, "..") {
			return relative
		}
	}
	return path
}

func handoffResolvedPath(path string) string {
	if resolved, err := filepath.EvalSymlinks(path); err == nil {
		return resolved
	}
	return path
}

func clipHandoffText(text string, limit int) string {
	if limit <= 0 {
		return ""
	}
	runes := []rune(text)
	if len(runes) <= limit {
		return text
	}
	return strings.TrimSpace(string(runes[:limit])) + " …"
}

func quoteHandoffText(text string) string {
	lines := strings.Split(text, "\n")
	for index, line := range lines {
		lines[index] = strings.TrimRight("> "+line, " ")
	}
	return strings.Join(lines, "\n")
}

// handoffWorkspaceSection states the Workspace facts Git can report, so the
// new Agent does not take them from a model's recollection.
func (s *Service) handoffWorkspaceSection(ctx context.Context, dir string) string {
	if strings.TrimSpace(dir) == "" {
		return ""
	}
	var builder strings.Builder
	builder.WriteString("## Workspace\n\n- Path: " + dir + "\n")
	status, err := git.StatusFor(ctx, dir)
	if err != nil {
		return builder.String()
	}
	if status.Branch != "" {
		line := "- Branch: " + status.Branch
		if status.Ahead > 0 || status.Behind > 0 {
			line += fmt.Sprintf(" (ahead %d, behind %d)", status.Ahead, status.Behind)
		}
		builder.WriteString(line + "\n")
	}
	if len(status.Changes) == 0 {
		builder.WriteString("- No uncommitted changes\n")
		return builder.String()
	}
	builder.WriteString("- Uncommitted changes:\n")
	for index, change := range status.Changes {
		if index == handoffChangeLimit {
			builder.WriteString(fmt.Sprintf("  - … and %d more\n", len(status.Changes)-index))
			break
		}
		line := fmt.Sprintf("  - %s %s", change.Status, change.Path)
		if change.Staged {
			line += " (staged)"
		}
		if change.Added > 0 || change.Deleted > 0 {
			line += fmt.Sprintf(" +%d -%d", change.Added, change.Deleted)
		}
		builder.WriteString(line + "\n")
	}
	return builder.String()
}

// composeHandoffText puts the brief, the Workspace facts, and where to find
// the earlier conversation into the first message of the new Session.
func composeHandoffText(source handoffSource, brief, workspace string) string {
	var builder strings.Builder
	builder.WriteString("Continue the work below, handed off from an earlier " + handoffProviderName(source.provider) + " session in this workspace.\n\n")
	if brief = strings.TrimSpace(brief); brief != "" {
		builder.WriteString(brief + "\n\n")
	}
	if workspace = strings.TrimSpace(workspace); workspace != "" {
		builder.WriteString(workspace + "\n\n")
	}
	builder.WriteString("## Earlier conversation\n\n")
	builder.WriteString("Look things up there only when you need a detail; do not read it all.\n\n")
	if path := strings.TrimSpace(source.session.TranscriptPath); path != "" {
		builder.WriteString("- Transcript: " + path + "\n")
	}
	builder.WriteString("- `warren agent read " + source.session.ID + "`\n")
	return strings.TrimSpace(builder.String())
}

func handoffProviderName(provider string) string {
	switch provider {
	case "claude":
		return "Claude Code"
	case "codex":
		return "Codex"
	case "pi":
		return "pi"
	case "antigravity":
		return "Antigravity"
	case "opencode":
		return "OpenCode"
	case "qoder":
		return "Qoder"
	case "":
		return "agent"
	default:
		return provider
	}
}

// TypeSessionDraft types text into a new terminal Agent's input without
// submitting it. It waits until the Agent has drawn its prompt, which shows as
// output that has stopped changing.
func (s *Service) TypeSessionDraft(ctx context.Context, request api.SessionDraftRequest) error {
	text := strings.TrimSpace(request.Text)
	if text == "" {
		return errors.New("text is required")
	}
	session, ok := s.Session(strings.TrimSpace(request.Session))
	if !ok {
		return fmt.Errorf("session not found: %s", request.Session)
	}
	runtime := s.runtimeForKind(s.runtimeKindFor(session))
	if runtime == nil || strings.EqualFold(session.RuntimeKind, "acp") {
		return errors.New("this Session has no terminal to type into")
	}
	ctx, cancel := context.WithTimeout(ctx, handoffDraftTimeout)
	defer cancel()
	if err := s.waitTerminalPromptDrawn(ctx, session.ID); err != nil {
		return err
	}
	unlock := s.lockAgentSessionAction(session.ID)
	defer unlock()
	return runtime.Input(ctx, session.Runtime, encodeTerminalText(text))
}

func (s *Service) waitTerminalPromptDrawn(ctx context.Context, sessionID string) error {
	start := time.Now()
	var baseline uint64
	var changedAt time.Time
	ticker := time.NewTicker(handoffDraftPoll)
	defer ticker.Stop()
	for {
		s.outputMu.Lock()
		output := s.outputs[sessionID]
		s.outputMu.Unlock()
		now := time.Now()
		if output != nil {
			if current := output.upper(); current != baseline {
				baseline = current
				changedAt = now
			}
		}
		if baseline > 0 && now.Sub(start) >= handoffDraftMinimum && now.Sub(changedAt) >= handoffDraftQuiet {
			return nil
		}
		select {
		case <-ctx.Done():
			return fmt.Errorf("the Agent did not draw its prompt: %w", ctx.Err())
		case <-ticker.C:
		}
	}
}
