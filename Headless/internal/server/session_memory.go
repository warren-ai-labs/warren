package server

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

// sessionHistoryMaxBytes bounds one stopped-Session output payload. The client
// message limit is far larger, but a stopped Tab only needs the last screen,
// and a bounded read keeps a long-lived Session from making a reopening cost
// megabytes.
const sessionHistoryMaxBytes = 2 << 20

// SessionHistory returns the runtime output the Host kept for one Session.
//
// An ended Session has no runtime to subscribe to, so its last output is read
// straight from the output segment Ghostline wrote while it was alive. The read
// starts at the segment's byte zero because a terminal renderer cannot begin
// halfway through an ANSI sequence; Truncated reports the bound instead of
// handing the client a suffix it would draw wrong. This is a fallback, not a
// checkpoint: BestEffort says so.
//
// A Session whose output found nothing readable still answers, with an empty
// payload, because a stopped Tab is useful without it — its Resume or Restart
// action does not depend on the screen.
func (s *Service) SessionHistory(_ context.Context, sessionID string) (api.SessionHistoryResult, error) {
	session, ok := s.durableSession(sessionID)
	if !ok {
		return api.SessionHistoryResult{}, fmt.Errorf("session not found: %s", sessionID)
	}
	result := api.SessionHistoryResult{
		Session:    session.ID,
		Lifecycle:  session.Lifecycle,
		BestEffort: true,
	}
	if session.Lifecycle == "ended" {
		result.EndReason = api.SessionEndReason(session.EndReason)
		result.EndedAt = session.EndedAt
	}
	segment := s.latestOutputSegment(session.Runtime)
	if segment == "" {
		return result, nil
	}
	payload, truncated, err := readOutputSegment(segment, sessionHistoryMaxBytes)
	if err != nil {
		s.logWarn("read stopped session output", "session", session.ID, "error", err)
		return result, nil
	}
	result.Payload = payload
	result.Bytes = len(payload)
	result.Truncated = truncated
	return result, nil
}

// durableSession finds a Session whatever its lifecycle. The ordinary Session
// lookup answers only for running Sessions, which is exactly what a stopped Tab
// must be able to see past.
func (s *Service) durableSession(sessionID string) (api.Session, bool) {
	for _, session := range s.Store.Snapshot().Sessions {
		if session.ID == sessionID {
			return session, true
		}
	}
	return api.Session{}, false
}

// latestOutputSegment names the most recent output segment Ghostline wrote for
// one runtime, or "" when it kept none.
//
// Ghostline gives every Session its own directory named after the runtime and
// appends numbered segments inside it. Only regular files are considered: the
// path is derived from Host state, but a symlink planted there must not become
// a way to read anything else.
func (s *Service) latestOutputSegment(runtimeName string) string {
	root := strings.TrimSpace(s.OutputDir)
	if root == "" || strings.TrimSpace(runtimeName) == "" {
		return ""
	}
	entries, err := os.ReadDir(root)
	if err != nil {
		return ""
	}
	type segment struct {
		path       string
		modifiedAt int64
		generation uint64
	}
	var segments []segment
	prefix := runtimeName + "-"
	for _, entry := range entries {
		if !entry.IsDir() || !strings.HasPrefix(entry.Name(), prefix) {
			continue
		}
		info, err := entry.Info()
		if err != nil {
			continue
		}
		files, err := os.ReadDir(filepath.Join(root, entry.Name()))
		if err != nil {
			continue
		}
		for _, file := range files {
			if !file.Type().IsRegular() {
				continue
			}
			number := strings.TrimSuffix(file.Name(), ".out")
			if number == file.Name() {
				continue
			}
			generation, err := strconv.ParseUint(number, 10, 64)
			if err != nil {
				continue
			}
			segments = append(segments, segment{
				path:       filepath.Join(root, entry.Name(), file.Name()),
				modifiedAt: info.ModTime().UnixNano(),
				generation: generation,
			})
		}
	}
	if len(segments) == 0 {
		return ""
	}
	sort.Slice(segments, func(left, right int) bool {
		if segments[left].modifiedAt != segments[right].modifiedAt {
			return segments[left].modifiedAt < segments[right].modifiedAt
		}
		return segments[left].generation < segments[right].generation
	})
	return segments[len(segments)-1].path
}

// readOutputSegment reads one segment from its first byte, up to limit. It
// reports whether the segment was longer than the limit.
func readOutputSegment(path string, limit int64) ([]byte, bool, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, false, err
	}
	defer func() { _ = file.Close() }()
	info, err := file.Stat()
	if err != nil {
		return nil, false, err
	}
	if !info.Mode().IsRegular() {
		return nil, false, errors.New("output segment is not a regular file")
	}
	size := info.Size()
	read := size
	if read > limit {
		read = limit
	}
	payload := make([]byte, read)
	if _, err := io.ReadFull(file, payload); err != nil && !errors.Is(err, io.ErrUnexpectedEOF) {
		return nil, false, err
	}
	return payload, size > limit, nil
}

// ResumeSession continues an ended Agent Session's provider conversation in a
// new running Session.
//
// The ended record is history and stays untouched: a resume never revives a
// runtime generation, and it never sends the old screen its input. The new
// Session keeps the conversation binding, the workspace, the title, and the pin,
// and records what it continued.
func (s *Service) ResumeSession(ctx context.Context, sessionID string) (api.Session, error) {
	session, ok := s.durableSession(sessionID)
	if !ok {
		return api.Session{}, fmt.Errorf("session not found: %s", sessionID)
	}
	if session.Lifecycle == "running" {
		return api.Session{}, fmt.Errorf("session %s is still running", sessionID)
	}
	if session.Kind == sessionKindBrowser || isACPSession(session) {
		return api.Session{}, fmt.Errorf("session %s has no terminal Agent conversation to resume", sessionID)
	}
	conversationID := strings.TrimSpace(session.AgentSessionID)
	if conversationID == "" {
		return api.Session{}, fmt.Errorf("session %s has no Agent conversation to resume", sessionID)
	}
	if session.WorkspaceID == "" {
		return api.Session{}, fmt.Errorf("session %s has no workspace to resume in", sessionID)
	}
	command, kind, err := resumeCommand(session, conversationID)
	if err != nil {
		return api.Session{}, err
	}
	// One running Session owns a provider conversation at a time. Two writers on
	// one transcript are not recoverable, so this is refused rather than merged.
	// The check below answers the ordinary case; createSessionWith repeats it
	// inside the state transaction, which is what closes the window between two
	// resumes that pass this loop at the same moment.
	for _, other := range s.Store.Snapshot().Sessions {
		if other.ID == session.ID || other.Lifecycle != "running" {
			continue
		}
		if strings.EqualFold(strings.TrimSpace(other.AgentSessionID), conversationID) {
			return api.Session{}, fmt.Errorf("another Session already continues this conversation: %s", other.ID)
		}
	}
	request := sessionCreateRequest{
		workspaceID:          session.WorkspaceID,
		command:              command,
		kind:                 kind,
		title:                session.CustomTitle,
		resumeAgentSessionID: conversationID,
		resumedFromSessionID: session.ID,
	}
	var created api.Session
	if lock := s.lockWorkspaceForSession(session.WorkspaceID); lock != nil {
		created, err = s.createSessionWith(ctx, request)
		lock.RUnlock()
	} else {
		created, err = s.createSessionWith(ctx, request)
	}
	if err != nil {
		return api.Session{}, err
	}
	if session.Pinned {
		if err := s.Store.Update(func(value *api.State) error {
			for index := range value.Sessions {
				if value.Sessions[index].ID == created.ID {
					value.Sessions[index].Pinned = true
				}
			}
			return nil
		}); err == nil {
			created.Pinned = true
		}
	}
	s.logInfo("session resumed", "session", created.ID, "continued", session.ID, "provider", kind)
	return created, nil
}

// resumeTarget is how one provider's TUI continues a named conversation.
type resumeTarget struct {
	executable string
	// arguments is a printf template whose single verb is the conversation ID.
	arguments string
}

// resumeTargets lists the provider TUIs Warren can continue. It deliberately
// holds only providers whose CLI takes a conversation ID on the command line:
// a provider Warren cannot name a conversation for has no resume, and guessing
// one from the old command would replay an arbitrary shell string.
var resumeTargets = map[string]resumeTarget{
	"claude":   {executable: "claude", arguments: "--resume %s"},
	"codex":    {executable: "codex", arguments: "resume %s"},
	"opencode": {executable: "opencode", arguments: "--session %s"},
	"pi":       {executable: "pi", arguments: "--session %s"},
}

// resumeCommand builds the display command that continues one conversation and
// reports the provider family it belongs to.
//
// The executable is preserved from the original launch when it is the provider
// under a user-chosen name (`codex-opgo`), because that name is how the Session
// was started. Nothing else of the old command is reused: the initial prompt and
// any continuation flags belong to the launch that already happened.
func resumeCommand(session api.Session, conversationID string) (string, string, error) {
	provider := agentProviderForKind(session.Kind)
	if provider == "" {
		// A shell or custom Session can be promoted to an Agent after launch;
		// its provider is then the durable binding rather than its kind.
		provider = agentProviderForKind(session.AgentProvider)
	}
	target, ok := resumeTargets[provider]
	if !ok {
		return "", "", fmt.Errorf("resuming a %s conversation is not supported", provider)
	}
	if !acpConversationIDPattern.MatchString(conversationID) {
		return "", "", fmt.Errorf("conversation ID %q cannot be resumed", conversationID)
	}
	executable := target.executable
	if name := launchExecutable(session.Command); name != "" && strings.HasPrefix(name, provider) {
		executable = name
	}
	return executable + " " + fmt.Sprintf(target.arguments, conversationID), provider, nil
}

// launchExecutable is the program word of a launch command, or "" when the
// command starts with shell syntax instead of a program.
func launchExecutable(command string) string {
	fields := strings.Fields(strings.TrimSpace(command))
	if len(fields) == 0 {
		return ""
	}
	word := fields[0]
	if strings.ContainsAny(word, "|&;<>()$`\\\"'") {
		return ""
	}
	name := filepath.Base(word)
	if name == "" || strings.HasPrefix(name, "-") {
		return ""
	}
	return name
}
