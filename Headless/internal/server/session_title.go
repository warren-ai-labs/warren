package server

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/agent"
	"github.com/abcdlsj/warren/Headless/internal/api"
	sessiontitle "github.com/abcdlsj/warren/Headless/internal/title"
)

// cliTitleGracePeriod is how long the Host waits for an agent CLI that names
// its own conversations before falling back to its own title request. Every
// CLI Warren integrates reports the name within seconds of the first completed
// turn, so the bound is generous relative to the wait it usually covers.
const cliTitleGracePeriod = 30 * time.Second

// cliTitleUpgradeWindow bounds the lookup after the Host's own request already
// produced a title. A CLI name that arrives late still wins, because it
// describes the thread the agent believes it is running, but a CLI that never
// names the conversation must not be re-read for the life of the Session.
const cliTitleUpgradeWindow = 60 * time.Second

// earlyTitleDelay is how long the first user message may go without an agent
// reply before the title is written from that message alone. The usual title
// replaces it once the reply arrives.
const earlyTitleDelay = 10 * time.Second

// earlyTitleReasoningLimit bounds the thinking gathered for an early title;
// the prompt clips it further.
const earlyTitleReasoningLimit = 4_000

// providerSuppliesTitle reports whether an agent CLI generates a name for its
// own conversation. Those names are preferred over the Host's title request;
// every other provider keeps the Host's request as its only source.
func providerSuppliesTitle(provider string) bool {
	family, _ := splitAgentKey(provider)
	switch family {
	case "claude", "codex", "opencode", "qoder":
		return true
	}
	return false
}

// titleAutomatic reports whether the Host may name a conversation from its own
// model call. It is the user's switch, and it is deliberately not consulted for
// a name the agent CLI generated for itself: that name costs nothing and
// describes the thread the agent is actually running.
func (s *Service) titleAutomatic() bool {
	return s.Settings.OpenAITitleEnabled
}

// titleGenerationConfigured reports whether the Host's own title request is
// possible. An agent CLI that names its own conversation does not need it, so
// this is deliberately narrower than titleAutomatic.
func (s *Service) titleGenerationConfigured() bool {
	return s.titleAutomatic() &&
		strings.TrimSpace(s.Settings.OpenAIBaseURL) != "" &&
		strings.TrimSpace(s.Settings.OpenAIKey) != ""
}

func (s *Service) titleConfig() sessiontitle.Config {
	return sessiontitle.Config{
		BaseURL: s.Settings.OpenAIBaseURL,
		Model:   s.Settings.OpenAIModel,
		APIKey:  s.Settings.OpenAIKey,
	}
}

// tryStartSessionTitle atomically claims the one automatic naming decision for
// a session once its first user and assistant texts are complete. The decision
// is intentionally asynchronous: an unavailable model must never delay
// terminal or agent event delivery.
//
// For a provider that names its own conversations the claim opens a bounded
// wait; pollAgentTitles resolves it with the CLI's name or, on expiry, with the
// Host's own request.
func (s *Service) tryStartSessionTitle(sessionID string) {
	if s.Store == nil {
		return
	}
	state := s.Store.Snapshot()
	provider := ""
	customTitle := ""
	found := false
	for index := range state.Sessions {
		session := state.Sessions[index]
		if session.ID != sessionID {
			continue
		}
		found = true
		if session.Lifecycle != "running" {
			return
		}
		customTitle = strings.TrimSpace(session.CustomTitle)
		provider = agentProviderForKind(session.AgentProvider)
		if provider == "" {
			provider = agentProviderForKind(session.Kind)
		}
		break
	}
	if !found {
		return
	}
	// An agent CLI that names its own conversation is given the first chance:
	// the name comes from the same first exchange, the agent's own view of the
	// thread rather than a second model call over a transcript Warren only
	// partly sees, and it costs nothing. The user's switch governs only the
	// Host's own request, so an agent name is read whether it is on or off.
	waitForCLI := providerSuppliesTitle(provider)
	if !waitForCLI && !s.titleGenerationConfigured() {
		return
	}
	var input sessiontitle.Input
	s.agentsMu.Lock()
	entry := s.agents[sessionID]
	if entry == nil {
		s.agentsMu.Unlock()
		return
	}
	entry.mu.Lock()
	// Do not spend a request for a session that already has a manual, restored,
	// or agent-supplied title. Only the Host's own early title may be replaced.
	if customTitle != "" && customTitle != entry.aiTitleValue {
		entry.mu.Unlock()
		s.agentsMu.Unlock()
		return
	}
	if entry.titleGenerationStarted || !entry.titleAssistantComplete ||
		strings.TrimSpace(entry.titleUser) == "" || strings.TrimSpace(entry.titleAssistant) == "" {
		entry.mu.Unlock()
		s.agentsMu.Unlock()
		return
	}
	entry.titleGenerationStarted = true
	// Capture the conversation generation so a name that outlives a `/clear`,
	// `/new`, or provider rebind cannot label the replacement conversation.
	generation := strings.TrimSpace(entry.executionID)
	input = sessiontitle.Input{
		User:      entry.titleUser,
		Assistant: entry.titleAssistant,
	}
	if waitForCLI {
		entry.cliTitleDeadline = time.Now().Add(cliTitleGracePeriod)
	}
	entry.mu.Unlock()
	s.agentsMu.Unlock()

	if waitForCLI {
		return
	}
	go s.generateSessionTitle(sessionID, generation, s.titleConfig(), input, false)
}

// pollAgentTitles resolves every conversation whose agent CLI was given the
// first chance to name it. It runs on the lifecycle tick, so the wait is
// bounded in wall-clock time rather than by how many transcript events a
// Session happens to produce.
func (s *Service) pollAgentTitles() {
	s.lazyInit()
	s.syncConversationTitles()
	s.startEarlySessionTitles()
	type titleWait struct {
		sessionID string
		watcher   *agent.Watcher
		tailer    *agent.OpenCodeTailer
		expired   bool
	}
	var waits []titleWait
	// The reporter handles belong to the entry but are published under
	// agentsMu, so they are read there and used after it is released: a title
	// lookup reads another process's state and must not hold the roster lock.
	s.agentsMu.Lock()
	for sessionID, entry := range s.agents {
		if entry == nil {
			continue
		}
		entry.mu.Lock()
		waiting := !entry.cliTitleDeadline.IsZero() && !entry.cliTitleCaptured
		expired := waiting && !time.Now().Before(entry.cliTitleDeadline)
		watcher, tailer := entry.watcher, entry.tailer
		entry.mu.Unlock()
		if !waiting {
			continue
		}
		waits = append(waits, titleWait{sessionID: sessionID, watcher: watcher, tailer: tailer, expired: expired})
	}
	s.agentsMu.Unlock()
	for _, wait := range waits {
		// The provider's own name wins whenever it exists, including inside the
		// upgrade window that follows the Host's own request.
		if s.captureAgentCLITitle(wait.sessionID, wait.watcher, wait.tailer) {
			continue
		}
		if wait.expired {
			s.finishAgentTitleFallback(wait.sessionID)
		}
	}
}

// captureAgentCLITitle applies a name the agent CLI generated for its own
// conversation. It reports whether one was available.
func (s *Service) captureAgentCLITitle(sessionID string, watcher *agent.Watcher, tailer *agent.OpenCodeTailer) bool {
	title := ""
	if watcher != nil {
		title = watcher.TakeTitle()
	}
	if title == "" && tailer != nil {
		title = tailer.TakeTitle()
	}
	title = sessiontitle.Normalize(title)
	if title == "" {
		return false
	}
	s.applyAgentCLITitle(sessionID, title)
	return true
}

// applyAgentCLITitle persists a provider-generated name. A title the user set
// is never replaced; a title the Host generated for this same conversation is,
// because the provider's own name is the more specific one.
func (s *Service) applyAgentCLITitle(sessionID, title string) {
	var generated, generation string
	s.agentsMu.Lock()
	entry := s.agents[sessionID]
	s.agentsMu.Unlock()
	if entry != nil {
		entry.mu.Lock()
		generated = entry.aiTitleValue
		generation = strings.TrimSpace(entry.executionID)
		entry.mu.Unlock()
	}
	if s.Store != nil {
		err := s.Store.Update(func(state *api.State) error {
			for index := range state.Sessions {
				session := &state.Sessions[index]
				if session.ID != sessionID {
					continue
				}
				if session.Lifecycle != "running" {
					return nil
				}
				// A name for a conversation that has been replaced must never
				// label the conversation that replaced it.
				if generation != "" && strings.TrimSpace(session.AgentExecutionID) != generation {
					return nil
				}
				current := strings.TrimSpace(session.CustomTitle)
				if current != "" && (generated == "" || current != generated) {
					return nil
				}
				session.CustomTitle = title
				return nil
			}
			return fmt.Errorf("session not found: %s", sessionID)
		})
		if err != nil {
			s.logWarn("persist agent session title", "session", sessionID, "error", err)
		}
	}
	if entry != nil {
		entry.mu.Lock()
		entry.cliTitleCaptured = true
		entry.cliTitleDeadline = time.Time{}
		entry.mu.Unlock()
	}
	s.wakeLiveActivity()
}

// finishAgentTitleFallback runs the Host's own title request once the CLI has
// had its grace period, then keeps the lookup open for one upgrade window so a
// provider name that lands late still wins.
func (s *Service) finishAgentTitleFallback(sessionID string) {
	s.agentsMu.Lock()
	entry := s.agents[sessionID]
	s.agentsMu.Unlock()
	if entry == nil {
		return
	}
	entry.mu.Lock()
	if entry.titleFallbackFired {
		// The upgrade window elapsed without the CLI naming the conversation.
		entry.cliTitleDeadline = time.Time{}
		entry.mu.Unlock()
		return
	}
	entry.titleFallbackFired = true
	generation := strings.TrimSpace(entry.executionID)
	input := sessiontitle.Input{User: entry.titleUser, Assistant: entry.titleAssistant}
	entry.cliTitleDeadline = time.Now().Add(cliTitleUpgradeWindow)
	entry.mu.Unlock()
	if !s.titleGenerationConfigured() ||
		strings.TrimSpace(input.User) == "" || strings.TrimSpace(input.Assistant) == "" {
		// Nothing to fall back to; the upgrade window stays open so a late CLI
		// name is still applied.
		return
	}
	go s.generateSessionTitle(sessionID, generation, s.titleConfig(), input, false)
}

// TestOpenAITitle makes one best-effort title request without changing
// settings or session state. An empty key uses the key already held by the
// Host so clients can test a saved credential without downloading it.
func (s *Service) TestOpenAITitle(ctx context.Context, baseURL, model, apiKey string) error {
	if strings.TrimSpace(apiKey) == "" {
		apiKey = s.Settings.OpenAIKey
	}
	requestContext, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	_, err := (sessiontitle.Generator{Config: sessiontitle.Config{
		BaseURL: baseURL,
		Model:   model,
		APIKey:  apiKey,
	}}).Generate(requestContext, sessiontitle.Input{
		User:      "Verify that this coding session title endpoint is reachable.",
		Assistant: "The endpoint is responding.",
	})
	return err
}

// isTitleSystemContext filters provider-injected scaffolding that can arrive
// as a user-role event. It must not become the subject of an automatic title.
func isTitleSystemContext(content string) bool {
	content = strings.TrimSpace(content)
	return strings.HasPrefix(strings.ToLower(content), "# agents.md") ||
		strings.HasPrefix(content, "<environment_context>") ||
		strings.HasPrefix(content, "<collaboration_mode>") ||
		strings.Contains(content, "<permissions instructions>")
}

// appendTitleMessage keeps the first real text message and only appends
// deltas that belong to that same provider message. Provider message IDs are
// present for OpenCode; the empty-ID fallback keeps normalized test and legacy
// events usable without allowing a later complete message to replace it.
func appendTitleMessage(value, provider, messageID *string, event api.AgentEvent) bool {
	content := strings.TrimSpace(event.Content)
	if content == "" {
		return false
	}
	if *value == "" {
		*value = content
		*provider = event.Provider
		*messageID = event.ID
		return true
	}
	if !event.ContentDelta || event.Provider != *provider {
		return false
	}
	if *messageID != "" {
		if event.ID != *messageID {
			return false
		}
	} else if event.ID != "" {
		return false
	}
	*value = strings.TrimSpace(*value + event.Content)
	return true
}

// generateSessionTitle requests one title and applies it. early marks the
// request made before the agent's first reply: it is dropped if the usual
// request has already been claimed, so it can never overwrite that result.
func (s *Service) generateSessionTitle(sessionID, generation string, config sessiontitle.Config, input sessiontitle.Input, early bool) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	titleValue, err := (sessiontitle.Generator{Config: config}).Generate(ctx, input)
	if err != nil {
		s.logWarn("generate session title", "session", sessionID, "error", err)
		return
	}
	s.agentsMu.Lock()
	entry := s.agents[sessionID]
	s.agentsMu.Unlock()
	previous := ""
	if entry != nil {
		entry.mu.Lock()
		superseded := early && (entry.titleGenerationStarted || entry.cliTitleCaptured)
		previous = entry.aiTitleValue
		entry.mu.Unlock()
		if superseded {
			return
		}
	}
	applied := false
	err = s.Store.Update(func(state *api.State) error {
		for index := range state.Sessions {
			session := &state.Sessions[index]
			if session.ID != sessionID {
				continue
			}
			// CustomTitle is also the durable automatic display override. A
			// manual rename that wins the race must never be overwritten; only
			// the Host's own earlier title may be.
			current := strings.TrimSpace(session.CustomTitle)
			if (current != "" && current != previous) || session.Lifecycle != "running" {
				return nil
			}
			// A request captured for a replaced provider conversation must never
			// name the current one after `/clear`, `/new`, or a rebind.
			if generation != "" && strings.TrimSpace(session.AgentExecutionID) != generation {
				return nil
			}
			session.CustomTitle = titleValue
			applied = true
			return nil
		}
		return fmt.Errorf("session not found: %s", sessionID)
	})
	if err != nil {
		s.logWarn("persist session title", "session", sessionID, "error", err)
		return
	}
	if !applied {
		return
	}
	// Remember the Host's own title so a provider name that arrives inside the
	// upgrade window can replace it, while a title the user set can not.
	if entry != nil {
		entry.mu.Lock()
		entry.aiTitleValue = titleValue
		entry.mu.Unlock()
	}
	s.wakeLiveActivity()
}

// tryStartResultSentence starts the one result-sentence request a turn may make.
// It shares the title request's configuration and best-effort contract: when the
// endpoint is missing or fails, the sidebar keeps the counts it already folds.
func (s *Service) tryStartResultSentence(sessionID string) {
	if !s.titleGenerationConfigured() {
		return
	}
	s.agentsMu.Lock()
	entry := s.agents[sessionID]
	if entry == nil {
		s.agentsMu.Unlock()
		return
	}
	entry.mu.Lock()
	if entry.resultGenerationStarted || strings.TrimSpace(entry.turnAssistant) == "" {
		entry.mu.Unlock()
		s.agentsMu.Unlock()
		return
	}
	entry.resultGenerationStarted = true
	generation := strings.TrimSpace(entry.executionID)
	answer := entry.turnAssistant
	entry.mu.Unlock()
	s.agentsMu.Unlock()
	go s.generateResultSentence(sessionID, generation, s.titleConfig(), answer)
}

func (s *Service) generateResultSentence(sessionID, generation string, config sessiontitle.Config, answer string) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	result, err := (sessiontitle.Generator{Config: config}).GenerateResult(ctx, sessiontitle.ResultInput{
		Answer: answer,
	})
	if err != nil {
		s.logWarn("generate result sentence", "session", sessionID, "error", err)
		return
	}
	if strings.TrimSpace(result) == "" {
		return
	}
	err = s.Store.Update(func(state *api.State) error {
		for index := range state.Sessions {
			session := &state.Sessions[index]
			if session.ID != sessionID {
				continue
			}
			if session.Lifecycle != "running" {
				return nil
			}
			// A sentence written for a replaced conversation must not describe
			// the current one, exactly as with a title.
			if generation != "" && strings.TrimSpace(session.AgentExecutionID) != generation {
				return nil
			}
			session.ResultSentence = result
			return nil
		}
		return fmt.Errorf("session not found: %s", sessionID)
	})
	if err != nil {
		s.logWarn("persist result sentence", "session", sessionID, "error", err)
		return
	}
	s.wakeLiveActivity()
}

// startEarlySessionTitles writes a first title for every conversation whose
// agent has not replied within earlyTitleDelay of the user's first message.
// It uses that message and any thinking the agent has shown so far; the usual
// title request replaces the result once the reply arrives.
func (s *Service) startEarlySessionTitles() {
	if s.Store == nil || !s.titleGenerationConfigured() {
		return
	}
	type earlyRequest struct {
		sessionID  string
		generation string
		input      sessiontitle.Input
	}
	var requests []earlyRequest
	now := time.Now()
	s.agentsMu.Lock()
	for sessionID, entry := range s.agents {
		if entry == nil {
			continue
		}
		entry.mu.Lock()
		due := !entry.earlyTitleStarted && !entry.titleGenerationStarted && !entry.cliTitleCaptured &&
			strings.TrimSpace(entry.titleUser) != "" && strings.TrimSpace(entry.titleAssistant) == "" &&
			!entry.titleUserAt.IsZero() && now.Sub(entry.titleUserAt) >= earlyTitleDelay
		if due {
			entry.earlyTitleStarted = true
			requests = append(requests, earlyRequest{
				sessionID:  sessionID,
				generation: strings.TrimSpace(entry.executionID),
				input: sessiontitle.Input{
					User:      entry.titleUser,
					Reasoning: earlyTitleReasoning(entry.events),
				},
			})
		}
		entry.mu.Unlock()
	}
	s.agentsMu.Unlock()
	if len(requests) == 0 {
		return
	}
	state := s.Store.Snapshot()
	for _, request := range requests {
		for _, session := range state.Sessions {
			if session.ID != request.sessionID {
				continue
			}
			// A session that already shows a title, including one restored for a
			// resumed conversation, does not need a provisional one.
			if strings.TrimSpace(session.CustomTitle) == "" && session.Lifecycle == "running" {
				go s.generateSessionTitle(request.sessionID, request.generation, s.titleConfig(), request.input, true)
			}
			break
		}
	}
}

// earlyTitleReasoning joins the agent's visible thinking in transcript order.
// Providers that hide or encrypt their thinking contribute nothing, and the
// early title is then written from the user's message alone.
func earlyTitleReasoning(events []api.AgentEvent) string {
	var builder strings.Builder
	for _, event := range events {
		if event.Sidechain || event.Type != "reasoning" || strings.TrimSpace(event.Content) == "" {
			continue
		}
		if event.ContentDelta {
			builder.WriteString(event.Content)
		} else {
			if builder.Len() > 0 {
				builder.WriteString("\n")
			}
			builder.WriteString(event.Content)
		}
		if builder.Len() >= earlyTitleReasoningLimit {
			break
		}
	}
	return strings.TrimSpace(builder.String())
}
