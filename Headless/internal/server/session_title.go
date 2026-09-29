package server

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
	sessiontitle "github.com/abcdlsj/warren/Headless/internal/title"
)

// tryStartSessionTitle atomically claims the one automatic title request for a
// session once its first user and assistant texts are complete. The request is
// intentionally asynchronous: an unavailable model must never delay terminal
// or agent event delivery.
func (s *Service) tryStartSessionTitle(sessionID string) {
	if !s.titleGenerationConfigured() || s.Store == nil {
		return
	}
	state := s.Store.Snapshot()
	found := false
	for _, session := range state.Sessions {
		if session.ID != sessionID {
			continue
		}
		found = true
		// Do not spend a request for a session that already has a manual or
		// previously generated title, or whose runtime has already ended.
		if strings.TrimSpace(session.CustomTitle) != "" || session.Lifecycle != "running" {
			return
		}
		break
	}
	if !found {
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
	if entry.titleGenerationStarted || !entry.titleAssistantComplete ||
		strings.TrimSpace(entry.titleUser) == "" || strings.TrimSpace(entry.titleAssistant) == "" {
		entry.mu.Unlock()
		s.agentsMu.Unlock()
		return
	}
	entry.titleGenerationStarted = true
	// Capture the conversation generation so a request that outlives a
	// `/clear`, `/new`, or provider rebind cannot name the replacement
	// conversation.
	generation := strings.TrimSpace(entry.executionID)
	input = sessiontitle.Input{
		User:      entry.titleUser,
		Assistant: entry.titleAssistant,
	}
	entry.mu.Unlock()
	s.agentsMu.Unlock()

	config := sessiontitle.Config{
		BaseURL: s.Settings.OpenAIBaseURL,
		Model:   s.Settings.OpenAIModel,
		APIKey:  s.Settings.OpenAIKey,
	}
	go s.generateSessionTitle(sessionID, generation, config, input)
}

func (s *Service) titleGenerationConfigured() bool {
	return s.Settings.OpenAITitleEnabled &&
		strings.TrimSpace(s.Settings.OpenAIBaseURL) != "" &&
		strings.TrimSpace(s.Settings.OpenAIKey) != ""
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

func (s *Service) generateSessionTitle(sessionID, generation string, config sessiontitle.Config, input sessiontitle.Input) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	titleValue, err := (sessiontitle.Generator{Config: config}).Generate(ctx, input)
	if err != nil {
		s.logWarn("generate session title", "session", sessionID, "error", err)
		return
	}
	err = s.Store.Update(func(state *api.State) error {
		for index := range state.Sessions {
			session := &state.Sessions[index]
			if session.ID != sessionID {
				continue
			}
			// CustomTitle is also the durable automatic display override. A
			// manual rename that wins the race must never be overwritten.
			if strings.TrimSpace(session.CustomTitle) != "" || session.Lifecycle != "running" {
				return nil
			}
			// A request captured for a replaced provider conversation must never
			// name the current one after `/clear`, `/new`, or a rebind.
			if generation != "" && strings.TrimSpace(session.AgentExecutionID) != generation {
				return nil
			}
			session.CustomTitle = titleValue
			return nil
		}
		return fmt.Errorf("session not found: %s", sessionID)
	})
	if err != nil {
		s.logWarn("persist session title", "session", sessionID, "error", err)
	} else {
		s.wakeLiveActivity()
	}
}
