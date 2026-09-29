package server

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/store"
)

type acpTestHost struct {
	service     *Service
	state       *store.Store
	journal     *store.AgentEventStore
	workspaceID string
	directory   string
	log         string
}

func newACPTestHost(t *testing.T) *acpTestHost {
	t.Helper()
	t.Setenv(fakeACPAgentEnv, "1")
	directory := t.TempDir()
	log := filepath.Join(directory, "agent.log")
	t.Setenv("WARREN_FAKE_ACP_LOG", log)
	state, err := store.Open(filepath.Join(directory, "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	projectID, workspaceID := store.NewID(), store.NewID()
	if err := state.Update(func(value *api.State) error {
		value.Projects = []api.Project{{ID: projectID, Name: "Project", Path: directory, CreatedAt: time.Now().UTC()}}
		value.Workspaces = []api.Workspace{{ID: workspaceID, ProjectID: projectID, Name: "main", Path: directory, Kind: "root", CreatedAt: time.Now().UTC()}}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	journal, err := store.OpenAgentEventStore(filepath.Join(directory, "agent-events.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = journal.Close() })
	host := &acpTestHost{state: state, journal: journal, workspaceID: workspaceID, directory: directory, log: log}
	host.service = host.newService()
	// Registered after the journal's cleanup, so it runs first: agents stop
	// before their journal closes.
	t.Cleanup(func() {
		// Shutdown leaves agents running in their holders for the next Host;
		// a test ends them.
		for _, session := range host.state.Snapshot().Sessions {
			host.service.stopAgent(session.ID)
		}
		host.service.Shutdown()
		time.Sleep(50 * time.Millisecond)
	})
	return host
}

func (h *acpTestHost) newService() *Service {
	service := &Service{
		Store:      h.state,
		AgentStore: h.journal,
		Runtime:    newMemoryRuntimeForACP(),
		ACPShell:   func() (string, []string) { return "", nil },
	}
	service.AgentProviders = NewTUIAgentProviderRegistry(service)
	service.lazyInit()
	return service
}

func newMemoryRuntimeForACP() Runtime {
	return &processTestRuntime{memoryRuntime: &memoryRuntime{sessions: map[string][]byte{}}, processes: map[string]*testProcess{}}
}

// processTestRuntime runs agent terminals as real child processes, so tests
// see real output and exit statuses.
type processTestRuntime struct {
	*memoryRuntime
	processMu sync.Mutex
	processes map[string]*testProcess
}

type testProcess struct {
	cmd    *exec.Cmd
	output *io.PipeReader
	done   chan struct{}
	exit   RuntimeExit
}

func (r *processTestRuntime) CreateProcess(ctx context.Context, name, directory string, argv, env []string) error {
	if err := r.memoryRuntime.Create(ctx, name, directory, "", env); err != nil {
		return err
	}
	reader, writer := io.Pipe()
	cmd := exec.Command(argv[0], argv[1:]...)
	cmd.Dir = directory
	cmd.Env = append(os.Environ(), env...)
	cmd.Stdout, cmd.Stderr = writer, writer
	if err := cmd.Start(); err != nil {
		return err
	}
	process := &testProcess{cmd: cmd, output: reader, done: make(chan struct{})}
	go func() {
		err := cmd.Wait()
		var exitErr *exec.ExitError
		switch {
		case errors.As(err, &exitErr) && exitErr.ExitCode() < 0:
			process.exit = RuntimeExit{Code: -1, Signal: "SIGKILL"}
		case errors.As(err, &exitErr):
			process.exit = RuntimeExit{Code: exitErr.ExitCode()}
		}
		_ = writer.Close()
		close(process.done)
	}()
	r.processMu.Lock()
	r.processes[name] = process
	r.processMu.Unlock()
	return nil
}

func (r *processTestRuntime) process(name string) (*testProcess, error) {
	r.processMu.Lock()
	defer r.processMu.Unlock()
	process := r.processes[name]
	if process == nil {
		return nil, fmt.Errorf("no process %s", name)
	}
	return process, nil
}

func (r *processTestRuntime) ProcessOutput(_ context.Context, name string) (io.ReadCloser, error) {
	process, err := r.process(name)
	if err != nil {
		return nil, err
	}
	return process.output, nil
}

func (r *processTestRuntime) WaitProcess(ctx context.Context, name string) (RuntimeExit, error) {
	process, err := r.process(name)
	if err != nil {
		return RuntimeExit{}, err
	}
	select {
	case <-process.done:
		return process.exit, nil
	case <-ctx.Done():
		return RuntimeExit{}, ctx.Err()
	}
}

func (r *processTestRuntime) TerminateProcess(_ context.Context, name string) error {
	process, err := r.process(name)
	if err != nil {
		return err
	}
	_ = process.cmd.Process.Kill()
	<-process.done
	return nil
}

func (r *processTestRuntime) Kill(ctx context.Context, name string) error {
	if process, err := r.process(name); err == nil {
		_ = process.cmd.Process.Kill()
	}
	return r.memoryRuntime.Kill(ctx, name)
}

func (h *acpTestHost) create(t *testing.T) api.Session {
	t.Helper()
	session, err := h.service.CreateSessionWithHandler(context.Background(), h.workspaceID, os.Args[0], "opencode", "", "", AgentHandlerACP)
	if err != nil {
		t.Fatal(err)
	}
	return session
}

func (h *acpTestHost) send(t *testing.T, sessionID, text string) {
	t.Helper()
	if _, err := h.service.sendAgentMessage(context.Background(), api.AgentMessageSendRequest{
		Session: sessionID, ClientMessageID: "cmd-" + store.NewID(), Text: text,
	}); err != nil {
		t.Fatal(err)
	}
}

func (h *acpTestHost) waitTurn(t *testing.T, sessionID string, turn uint64) api.AgentTurn {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		current := h.service.agentTurn(sessionID)
		if current.ID == turn && terminalAgentTurnStatus(current.Status) {
			return current
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("turn %d did not finish; current %#v", turn, h.service.agentTurn(sessionID))
	return api.AgentTurn{}
}

func (h *acpTestHost) waitStatus(t *testing.T, sessionID string, want api.AgentActivity) api.AgentStatus {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if status := h.service.agentStatus(sessionID); status.Activity == want {
			return status
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("status did not become %s; current %#v", want, h.service.agentStatus(sessionID))
	return api.AgentStatus{}
}

func (h *acpTestHost) events(t *testing.T, sessionID string) []api.CanonicalAgentEvent {
	t.Helper()
	execution, ok := h.service.canonicalExecutionForSession(sessionID)
	if !ok {
		t.Fatal("no execution")
	}
	page, err := h.service.canonicalHistoryPage(context.Background(), execution.StreamID, 0, 0, 1000)
	if err != nil {
		t.Fatal(err)
	}
	// Clients reject a whole page when one envelope is incomplete, so every
	// row must carry the fields validateCanonicalAgentEvent requires.
	for _, event := range page.Events {
		if event.EventID == "" || event.ExecutionID == "" || event.Origin.Kind == "" || event.Origin.Confidence == "" || event.Payload == nil {
			t.Fatalf("incomplete canonical envelope: %#v", event)
		}
	}
	return page.Events
}

func messageText(events []api.CanonicalAgentEvent, role string) []string {
	byID := map[string]string{}
	var order []string
	for _, event := range events {
		if !strings.HasPrefix(event.Type, "message.") || event.Payload["role"] != role {
			continue
		}
		id, _ := event.Payload["messageId"].(string)
		content, _ := event.Payload["content"].(string)
		if _, seen := byID[id]; !seen {
			order = append(order, id)
		}
		switch event.Type {
		case "message.delta":
			byID[id] += content
		default:
			byID[id] = content
		}
	}
	result := make([]string, 0, len(order))
	for _, id := range order {
		result = append(result, byID[id])
	}
	return result
}

func eventTypes(events []api.CanonicalAgentEvent) []string {
	result := make([]string, 0, len(events))
	for _, event := range events {
		result = append(result, event.Type)
	}
	return result
}

func TestACPSessionHasNoRuntimeAndStreamsATurn(t *testing.T) {
	host := newACPTestHost(t)
	session := host.create(t)
	if session.RuntimeKind != runtimeKindACP || session.Runtime != "" || session.AgentHandler != AgentHandlerACP {
		t.Fatalf("session = %#v, want an acp Session without a runtime", session)
	}
	if got := host.service.agentCapabilitiesForSession(session.ID, session); strings.Join(got, ",") != strings.Join(NewCapabilitySet(CapabilityTimeline, CapabilityInteractions, CapabilityInterrupt, CapabilityAttachments, CapabilityConfig).Strings(), ",") {
		t.Fatalf("capabilities = %v", got)
	}
	host.send(t, session.ID, "hello")
	if turn := host.waitTurn(t, session.ID, 1); turn.Status != api.AgentTurnCompleted {
		t.Fatalf("turn = %#v, want completed", turn)
	}
	host.waitStatus(t, session.ID, api.AgentActivityReady)
	events := host.events(t, session.ID)
	if got := messageText(events, "user"); len(got) != 1 || got[0] != "hello" {
		t.Fatalf("user messages = %q, want [hello]", got)
	}
	if got := messageText(events, "assistant"); len(got) != 1 || got[0] != "Hello there" {
		t.Fatalf("assistant messages = %q, want [Hello there]; types %v", got, eventTypes(events))
	}
	var sawReasoning, sawUsage bool
	for _, event := range events {
		if event.Type == "reasoning.delta" && event.Payload["content"] == "thinking" {
			sawReasoning = true
		}
		if event.Type == "message.completed" && event.Payload["usage"] != nil {
			sawUsage = true
		}
	}
	if !sawReasoning || !sawUsage {
		t.Fatalf("reasoning=%t usage=%t; types %v", sawReasoning, sawUsage, eventTypes(events))
	}
	current, _ := host.service.Session(session.ID)
	if !strings.HasPrefix(current.AgentSessionID, "fake-session-") {
		t.Fatalf("agentSessionId = %q, want the ACP session ID", current.AgentSessionID)
	}
	if err := host.service.DeleteSession(context.Background(), session.ID); err != nil {
		t.Fatal(err)
	}
}

// latestConfig returns the selectors of the last config.updated, keyed by id.
func latestConfig(t *testing.T, events []api.CanonicalAgentEvent) (map[string]map[string]any, int) {
	t.Helper()
	var latest []any
	count := 0
	for _, event := range events {
		if event.Type != "config.updated" {
			continue
		}
		count++
		latest, _ = event.Payload["configOptions"].([]any)
	}
	result := map[string]map[string]any{}
	for _, item := range latest {
		option, _ := item.(map[string]any)
		id, _ := option["id"].(string)
		result[id] = option
	}
	return result, count
}

func waitConfigValue(t *testing.T, host *acpTestHost, sessionID, id, want string) []api.CanonicalAgentEvent {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		events := host.events(t, sessionID)
		if config, _ := latestConfig(t, events); config[id] != nil && config[id]["currentValue"] == want {
			return events
		}
		time.Sleep(20 * time.Millisecond)
	}
	config, _ := latestConfig(t, host.events(t, sessionID))
	t.Fatalf("setting %s did not become %q; config %v", id, want, config)
	return nil
}

func TestACPConfigOptionsAreJournaledAndSettable(t *testing.T) {
	host := newACPTestHost(t)
	session := host.create(t)
	events := waitConfigValue(t, host, session.ID, "model", "small")
	config, count := latestConfig(t, events)
	if count != 1 {
		t.Fatalf("config.updated count = %d, want 1", count)
	}
	model := config["model"]
	choices, _ := model["options"].([]any)
	if model["category"] != "model" || len(choices) != 2 {
		t.Fatalf("model selector = %v", model)
	}
	if large, _ := choices[1].(map[string]any); large["value"] != "large" || large["group"] != "Smart" || large["description"] != "Slower" {
		t.Fatalf("grouped choice was not flattened with its group: %v", choices[1])
	}
	// The fake publishes its mode only as a legacy mode list.
	if mode := config["mode"]; mode == nil || mode["currentValue"] != "ask" || mode["category"] != "mode" {
		t.Fatalf("mode selector = %v, want one synthesized from modes", config["mode"])
	}

	if err := host.service.setAgentConfig(context.Background(), session.ID, "model", "large"); err != nil {
		t.Fatal(err)
	}
	waitConfigValue(t, host, session.ID, "model", "large")
	if err := host.service.setAgentConfig(context.Background(), session.ID, "mode", "code"); err != nil {
		t.Fatal(err)
	}
	waitConfigValue(t, host, session.ID, "mode", "code")
	if log, _ := os.ReadFile(host.log); !strings.Contains(string(log), "session/set_config_option") || !strings.Contains(string(log), "session/set_mode") {
		t.Fatalf("agent log = %q, want set_config_option and set_mode", log)
	}
	if err := host.service.setAgentConfig(context.Background(), session.ID, "model", "huge"); err == nil {
		t.Fatal("an unknown value was accepted")
	}
	if err := host.service.setAgentConfig(context.Background(), session.ID, "speed", "fast"); err == nil {
		t.Fatal("an unknown setting was accepted")
	}

	// An agent-initiated mode change updates the same snapshot.
	if err := host.service.setAgentConfig(context.Background(), session.ID, "mode", "ask"); err != nil {
		t.Fatal(err)
	}
	waitConfigValue(t, host, session.ID, "mode", "ask")
	host.send(t, session.ID, "mode")
	host.waitTurn(t, session.ID, 1)
	events = waitConfigValue(t, host, session.ID, "mode", "code")
	if config, _ := latestConfig(t, events); config["model"]["currentValue"] != "large" {
		t.Fatalf("a mode update lost the model: %v", config["model"])
	}
}

func TestACPToolCallsDiffsAndPlans(t *testing.T) {
	host := newACPTestHost(t)
	session := host.create(t)
	host.send(t, session.ID, "tool")
	host.waitTurn(t, session.ID, 1)
	events := host.events(t, session.ID)
	var started, updated, completed int
	var diff map[string]any
	var plan map[string]any
	for _, event := range events {
		switch event.Type {
		case "tool.started":
			started++
		case "tool.updated":
			updated++
			if event.Payload["callId"] == "call-1" && event.Payload["toolDetail"] != "ls" {
				t.Fatalf("tool detail = %v, want ls", event.Payload["toolDetail"])
			}
		case "tool.completed":
			completed++
			if event.Payload["callId"] == "call-1" && event.Payload["output"] != "a.txt\n" {
				t.Fatalf("tool output = %q", event.Payload["output"])
			}
			if value, ok := event.Payload["diff"].(map[string]any); ok {
				diff = value
			}
		case "plan.updated":
			plan = event.Payload
		}
	}
	if started != 1 || updated != 1 || completed != 2 {
		t.Fatalf("tool events started=%d updated=%d completed=%d; types %v", started, updated, completed, eventTypes(events))
	}
	if diff == nil || fmt.Sprint(diff["additions"]) != "2" || fmt.Sprint(diff["deletions"]) != "1" || !strings.Contains(diff["diff"].(string), "+three") {
		t.Fatalf("diff = %#v", diff)
	}
	if plan == nil || plan["state"] != "in_progress" {
		t.Fatalf("plan = %#v", plan)
	}
	if got := messageText(events, "assistant"); len(got) != 2 || got[0] != "Looking." || got[1] != "Done." {
		t.Fatalf("assistant segments = %q, want text before and after the tools as separate messages", got)
	}
}

func TestACPPermissionIsAnsweredOnce(t *testing.T) {
	host := newACPTestHost(t)
	session := host.create(t)
	host.send(t, session.ID, "permission")
	status := host.waitStatus(t, session.ID, api.AgentActivityBlocked)
	if status.Attention == nil || status.Attention.Kind != api.AgentAttentionApproval {
		t.Fatalf("status = %#v, want approval attention", status)
	}
	var request api.CanonicalAgentEvent
	for _, event := range host.events(t, session.ID) {
		if event.Type == "interaction.requested" {
			request = event
		}
	}
	options, _ := request.Payload["options"].([]any)
	if len(options) != 3 || options[0].(map[string]any)["kind"] != "allow_once" || options[2].(map[string]any)["kind"] != "reject_once" {
		t.Fatalf("options = %#v, want allow before reject", options)
	}
	if request.Payload["toolDetail"] != "rm -rf build" {
		t.Fatalf("permission detail = %v", request.Payload["toolDetail"])
	}
	interactionID := request.Payload["interactionId"].(string)
	if _, err := host.service.respondAgentInteraction(context.Background(), api.AgentInteractionResponse{
		Session: session.ID, RequestID: interactionID, Kind: "permission", Response: map[string]any{"decision": "allow"},
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := host.service.respondAgentInteraction(context.Background(), api.AgentInteractionResponse{
		CommandID: "second", Session: session.ID, RequestID: interactionID, Kind: "permission", Response: map[string]any{"decision": "reject"},
	}); err == nil {
		t.Fatal("a second resolution was accepted")
	}
	host.waitTurn(t, session.ID, 1)
	events := host.events(t, session.ID)
	if got := messageText(events, "assistant"); len(got) != 1 || got[0] != "chose allow" {
		t.Fatalf("assistant = %q", got)
	}
	resolved := 0
	for _, event := range events {
		if event.Type == "interaction.resolved" {
			resolved++
		}
	}
	if resolved != 1 {
		t.Fatalf("resolved events = %d, want 1", resolved)
	}
}

func TestACPCancelExpiresPermissionAndCancelsTurn(t *testing.T) {
	host := newACPTestHost(t)
	session := host.create(t)
	host.send(t, session.ID, "permission")
	host.waitStatus(t, session.ID, api.AgentActivityBlocked)
	if _, err := host.service.interruptAgentTurn(context.Background(), api.AgentTurnInterruptRequest{
		CommandID: "cancel-1", Session: session.ID, Turn: 1, Reason: "cancel",
	}); err != nil {
		t.Fatal(err)
	}
	if turn := host.waitTurn(t, session.ID, 1); turn.Status != api.AgentTurnCancelled {
		t.Fatalf("turn = %#v, want cancelled", turn)
	}
	expired := 0
	for _, event := range host.events(t, session.ID) {
		if event.Type == "interaction.expired" {
			expired++
		}
	}
	if expired != 1 {
		t.Fatalf("expired interactions = %d, want 1", expired)
	}
	host.waitStatus(t, session.ID, api.AgentActivityReady)
}

func TestACPSteerReplacesTheRunningTurn(t *testing.T) {
	host := newACPTestHost(t)
	session := host.create(t)
	host.send(t, session.ID, "wait")
	host.waitStatus(t, session.ID, api.AgentActivityWorking)
	time.Sleep(100 * time.Millisecond)
	if _, err := host.service.interruptAgentTurn(context.Background(), api.AgentTurnInterruptRequest{
		CommandID: "steer-1", Session: session.ID, Turn: 1, Reason: "send_now",
		Replacement: &api.AgentMessageSendRequest{Session: session.ID, ClientMessageID: "replacement", Text: "second"},
	}); err != nil {
		t.Fatal(err)
	}
	if turn := host.waitTurn(t, session.ID, 2); turn.Status != api.AgentTurnCompleted {
		t.Fatalf("turn 2 = %#v", turn)
	}
	events := host.events(t, session.ID)
	var cancelled bool
	for _, event := range events {
		if event.Type == "turn.cancelled" && event.TurnID == "1" {
			cancelled = true
		}
	}
	if !cancelled {
		t.Fatalf("turn 1 was not cancelled; types %v", eventTypes(events))
	}
	if got := messageText(events, "assistant"); got[len(got)-1] != "echo: second" {
		t.Fatalf("assistant = %q", got)
	}
}

func TestACPCrashFailsTurnAndNextPromptResumes(t *testing.T) {
	host := newACPTestHost(t)
	t.Setenv("WARREN_FAKE_ACP_RESUME", "1")
	session := host.create(t)
	host.send(t, session.ID, "crash")
	if turn := host.waitTurn(t, session.ID, 1); turn.Status != api.AgentTurnFailed {
		t.Fatalf("turn = %#v, want failed", turn)
	}
	host.waitStatus(t, session.ID, api.AgentActivityFailed)
	var sawExit bool
	for _, event := range host.events(t, session.ID) {
		if event.Type == "error" && strings.Contains(event.Payload["error"].(string), "exited") {
			sawExit = true
		}
	}
	if !sawExit {
		t.Fatalf("no exit error; types %v", eventTypes(host.events(t, session.ID)))
	}
	before, _ := host.service.Session(session.ID)
	host.send(t, session.ID, "after")
	if turn := host.waitTurn(t, session.ID, 2); turn.Status != api.AgentTurnCompleted {
		t.Fatalf("turn 2 = %#v", turn)
	}
	after, _ := host.service.Session(session.ID)
	if after.AgentSessionID != before.AgentSessionID || after.AgentExecutionID != before.AgentExecutionID {
		t.Fatalf("resume changed identity: before %s/%s after %s/%s", before.AgentSessionID, before.AgentExecutionID, after.AgentSessionID, after.AgentExecutionID)
	}
	log, _ := os.ReadFile(host.log)
	if !strings.Contains(string(log), "session/resume") {
		t.Fatalf("agent log = %q, want session/resume", log)
	}
}

func TestACPHostRestartLoadsWithoutReplayingHistory(t *testing.T) {
	host := newACPTestHost(t)
	t.Setenv("WARREN_FAKE_ACP_LOAD", "1")
	session := host.create(t)
	host.send(t, session.ID, "hello")
	host.waitTurn(t, session.ID, 1)
	before := len(host.events(t, session.ID))
	host.service.stopAgent(session.ID)

	// A new Service over the same state is a restarted Host.
	host.service = host.newService()
	current, _ := host.service.Session(session.ID)
	if _, err := host.service.ensureAgent(context.Background(), current); err != nil {
		t.Fatal(err)
	}
	time.Sleep(200 * time.Millisecond)
	if log, _ := os.ReadFile(host.log); strings.Count(string(log), "initialize") != 1 {
		t.Fatalf("a restarted Host started the agent before a prompt: %q", log)
	}
	host.send(t, session.ID, "again")
	if turn := host.waitTurn(t, session.ID, 2); turn.Status != api.AgentTurnCompleted {
		t.Fatalf("turn 2 = %#v", turn)
	}
	events := host.events(t, session.ID)
	for _, text := range messageText(events, "assistant") {
		if strings.Contains(text, "old answer") {
			t.Fatalf("replayed history reached the journal: %q", messageText(events, "assistant"))
		}
	}
	if len(events) <= before {
		t.Fatalf("no new events after restart")
	}
	log, _ := os.ReadFile(host.log)
	if !strings.Contains(string(log), "session/load") {
		t.Fatalf("agent log = %q, want session/load", log)
	}
}

// restartHost shuts the Host down the way the daemon does and starts a new
// one over the same state.
func (h *acpTestHost) restartHost(t *testing.T, sessionID string) {
	t.Helper()
	h.service.Shutdown()
	h.service = h.newService()
	current, _ := h.service.Session(sessionID)
	if _, err := h.service.ensureAgent(context.Background(), current); err != nil {
		t.Fatal(err)
	}
}

func (h *acpTestHost) agentLog(t *testing.T) string {
	t.Helper()
	log, _ := os.ReadFile(h.log)
	return string(log)
}

func TestACPIdleAgentSurvivesHostRestart(t *testing.T) {
	host := newACPTestHost(t)
	t.Setenv("WARREN_FAKE_ACP_LOAD", "1")
	session := host.create(t)
	host.send(t, session.ID, "hello")
	host.waitTurn(t, session.ID, 1)
	host.restartHost(t, session.ID)

	// The selectors come back with the agent, without asking it again.
	if err := host.service.setAgentConfig(context.Background(), session.ID, "model", "large"); err != nil {
		t.Fatal(err)
	}
	host.send(t, session.ID, "hello")
	if turn := host.waitTurn(t, session.ID, 2); turn.Status != api.AgentTurnCompleted {
		t.Fatalf("turn 2 = %#v", turn)
	}
	log := host.agentLog(t)
	if strings.Count(log, "initialize") != 1 || strings.Contains(log, "session/load") {
		t.Fatalf("the agent was started again: %q", log)
	}
	if got := messageText(host.events(t, session.ID), "assistant"); len(got) != 2 {
		t.Fatalf("assistant = %q", got)
	}
}

func TestACPHostRestartAdoptsTheRunningTurn(t *testing.T) {
	host := newACPTestHost(t)
	session := host.create(t)
	host.send(t, session.ID, "later")
	deadline := time.Now().Add(5 * time.Second)
	for !strings.Contains(strings.Join(messageText(host.events(t, session.ID), "assistant"), ""), "before") {
		if time.Now().After(deadline) {
			t.Fatal("the turn did not start streaming")
		}
		time.Sleep(10 * time.Millisecond)
	}
	// The agent answers while no Host is attached; the holder keeps it.
	host.service.Shutdown()
	time.Sleep(600 * time.Millisecond)
	host.service = host.newService()
	current, _ := host.service.Session(session.ID)
	if _, err := host.service.ensureAgent(context.Background(), current); err != nil {
		t.Fatal(err)
	}
	if turn := host.waitTurn(t, session.ID, 1); turn.Status != api.AgentTurnCompleted {
		t.Fatalf("turn = %#v, want completed", turn)
	}
	events := host.events(t, session.ID)
	if got := strings.Join(messageText(events, "assistant"), "|"); !strings.Contains(got, "before") || !strings.Contains(got, "after") {
		t.Fatalf("assistant = %q", got)
	}
	for _, event := range events {
		if event.Type == "error" {
			t.Fatalf("unexpected error %v", event.Payload)
		}
	}
	if log := host.agentLog(t); strings.Count(log, "initialize") != 1 {
		t.Fatalf("the agent was started again: %q", log)
	}
}

func TestACPHostRestartKeepsAPendingPermission(t *testing.T) {
	host := newACPTestHost(t)
	session := host.create(t)
	host.send(t, session.ID, "permission")
	host.waitStatus(t, session.ID, api.AgentActivityBlocked)
	requested := func() []string {
		var ids []string
		for _, event := range host.events(t, session.ID) {
			if event.Type == "interaction.requested" {
				ids = append(ids, event.Payload["interactionId"].(string))
			}
		}
		return ids
	}
	before := requested()
	host.restartHost(t, session.ID)
	status := host.waitStatus(t, session.ID, api.AgentActivityBlocked)
	after := requested()
	if len(before) != 1 || len(after) == 0 || after[len(after)-1] != before[0] || status.Attention == nil || status.Attention.RequestID != before[0] {
		t.Fatalf("interaction ids before %v after %v, attention %#v", before, after, status.Attention)
	}
	if _, err := host.service.respondAgentInteraction(context.Background(), api.AgentInteractionResponse{
		Session: session.ID, RequestID: before[0], Kind: "permission", Response: map[string]any{"decision": "allow"},
	}); err != nil {
		t.Fatal(err)
	}
	if turn := host.waitTurn(t, session.ID, 1); turn.Status != api.AgentTurnCompleted {
		t.Fatalf("turn = %#v, want completed", turn)
	}
	if got := messageText(host.events(t, session.ID), "assistant"); len(got) != 1 || got[0] != "chose allow" {
		t.Fatalf("assistant = %q", got)
	}
}

func TestACPResumeFailureStartsANewExecution(t *testing.T) {
	host := newACPTestHost(t)
	t.Setenv("WARREN_FAKE_ACP_RESUME", "1")
	session := host.create(t)
	host.send(t, session.ID, "hello")
	host.waitTurn(t, session.ID, 1)
	before, _ := host.service.Session(session.ID)
	host.service.stopAgent(session.ID)
	t.Setenv("WARREN_FAKE_ACP_RESUME_FAIL", "1")
	host.service = host.newService()
	if _, err := host.service.ensureAgent(context.Background(), before); err != nil {
		t.Fatal(err)
	}
	host.send(t, session.ID, "again")
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		after, _ := host.service.Session(session.ID)
		if after.AgentExecutionID != before.AgentExecutionID && after.AgentSessionID != before.AgentSessionID {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	after, _ := host.service.Session(session.ID)
	t.Fatalf("identity did not change after a failed resume: before %s/%s after %s/%s", before.AgentSessionID, before.AgentExecutionID, after.AgentSessionID, after.AgentExecutionID)
}

func TestACPAuthRequiredExplainsHowToSignIn(t *testing.T) {
	host := newACPTestHost(t)
	t.Setenv("WARREN_FAKE_ACP_AUTH", "1")
	session := host.create(t)
	host.waitStatus(t, session.ID, api.AgentActivityFailed)
	var message string
	for _, event := range host.events(t, session.ID) {
		if event.Type == "error" {
			message, _ = event.Payload["error"].(string)
		}
	}
	if !strings.Contains(message, "needs you to sign in") || !strings.Contains(message, "fake login") {
		t.Fatalf("error = %q", message)
	}
}

func TestACPSessionRejectsTerminalOperations(t *testing.T) {
	host := newACPTestHost(t)
	session := host.create(t)
	if _, err := host.service.ensureOutput(context.Background(), session); err == nil {
		t.Fatal("ensureOutput succeeded for an ACP Session")
	}
	if _, err := host.service.resizeRuntime(context.Background(), session, 80, 24); err == nil {
		t.Fatal("resize succeeded for an ACP Session")
	}
	if _, err := host.service.CreateSessionWithHandler(context.Background(), host.workspaceID, "", "pi", "", "", AgentHandlerACP); err == nil {
		t.Fatal("an ACP Session was created for a provider without an ACP server")
	}
	if _, err := host.service.CreateSessionWithHandler(context.Background(), host.workspaceID, "opencode acp; rm -rf /", "opencode", "", "", AgentHandlerACP); err == nil {
		t.Fatal("a command with shell operators was accepted")
	}
}

func TestUnifiedLineDiff(t *testing.T) {
	diff, additions, deletions := unifiedLineDiff("a.txt", "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\n", "a\nB\nc\nd\ne\nf\ng\nh\ni\nJ\nk\n")
	if additions != 3 || deletions != 2 {
		t.Fatalf("counts = +%d -%d", additions, deletions)
	}
	want := "--- a/a.txt\n+++ b/a.txt\n@@ -1,5 +1,5 @@\n a\n-b\n+B\n c\n d\n e\n@@ -7,4 +7,5 @@\n g\n h\n i\n-j\n+J\n+k\n"
	if diff != want {
		t.Fatalf("diff =\n%s\nwant\n%s", diff, want)
	}
	if _, additions, deletions := unifiedLineDiff("new.txt", "", "x\ny\n"); additions != 2 || deletions != 0 {
		t.Fatalf("new file counts = +%d -%d", additions, deletions)
	}
}

// TestACPRealOpenCode runs one prompt through `opencode acp` launched by the
// user's login shell. It needs OpenCode installed and signed in, so it only
// runs with WARREN_ACP_REAL=1.
func TestACPRealOpenCode(t *testing.T) {
	if os.Getenv("WARREN_ACP_REAL") == "" {
		t.Skip("set WARREN_ACP_REAL=1 to run against a real opencode acp")
	}
	host := newACPTestHost(t)
	host.service.ACPShell = nil
	if err := os.WriteFile(filepath.Join(host.directory, "a.txt"), []byte("hello\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	session, err := host.service.CreateSessionWithHandler(context.Background(), host.workspaceID, "", "opencode", "", "", AgentHandlerACP)
	if err != nil {
		t.Fatal(err)
	}
	host.send(t, session.ID, "Read a.txt with your read tool and reply with its exact content only.")
	deadline := time.Now().Add(2 * time.Minute)
	for time.Now().Before(deadline) {
		if turn := host.service.agentTurn(session.ID); turn.ID == 1 && terminalAgentTurnStatus(turn.Status) {
			break
		}
		time.Sleep(200 * time.Millisecond)
	}
	events := host.events(t, session.ID)
	if turn := host.service.agentTurn(session.ID); turn.Status != api.AgentTurnCompleted {
		for _, event := range events {
			if event.Type == "error" {
				t.Logf("error: %v", event.Payload["error"])
			}
		}
		t.Fatalf("turn = %#v; types %v", turn, eventTypes(events))
	}
	answers := messageText(events, "assistant")
	if len(answers) == 0 || !strings.Contains(strings.ToLower(answers[len(answers)-1]), "hello") {
		t.Fatalf("answers = %q; types %v", answers, eventTypes(events))
	}
	var readTool bool
	for _, event := range events {
		if event.Type == "tool.completed" && event.Payload["toolKind"] == "read" {
			readTool = true
		}
	}
	if !readTool {
		t.Fatalf("no completed read tool; types %v", eventTypes(events))
	}
}

func TestStripACPCodeFence(t *testing.T) {
	for input, want := range map[string]string{
		"```console\na.txt\nb.txt\n```": "a.txt\nb.txt",
		"```\n1\thello\n```":            "1\thello",
		"plain":                         "plain",
		"```a\nx\n```\n```b\ny\n```":    "```a\nx\n```\n```b\ny\n```",
	} {
		if got := stripACPCodeFence(input); got != want {
			t.Fatalf("stripACPCodeFence(%q) = %q, want %q", input, got, want)
		}
	}
}

func TestACPHandoffReplacesTheChatWithAResumingTerminal(t *testing.T) {
	host := newACPTestHost(t)
	session := host.create(t)
	waitConfigValue(t, host, session.ID, "model", "small") // the conversation exists
	host.send(t, session.ID, "permission")
	host.waitStatus(t, session.ID, api.AgentActivityBlocked)
	if _, err := host.service.handoffACPSession(context.Background(), session.ID, ""); err == nil || !strings.Contains(err.Error(), "stop the running turn") {
		t.Fatalf("hand-off during a turn: err = %v", err)
	}
	if _, err := host.service.interruptAgentTurn(context.Background(), api.AgentTurnInterruptRequest{
		CommandID: "cancel-1", Session: session.ID, Turn: 1, Reason: "cancel",
	}); err != nil {
		t.Fatal(err)
	}
	host.waitTurn(t, session.ID, 1)
	chat, _ := host.service.Session(session.ID)
	if err := host.state.Update(func(value *api.State) error {
		value.PaneGroups = append(value.PaneGroups, api.PaneGroup{ID: "group-1", WorkspaceID: host.workspaceID, Tree: api.PaneNode{
			Axis: "horizontal", Ratio: 0.5,
			First:  &api.PaneNode{PaneID: "pane-1", SessionID: session.ID},
			Second: &api.PaneNode{PaneID: "pane-2", SessionID: "other"},
		}})
		return nil
	}); err != nil {
		t.Fatal(err)
	}

	if _, err := host.service.handoffACPSession(context.Background(), session.ID, "claude"); err == nil {
		t.Fatal("a terminal command for another provider was accepted")
	}
	terminal, err := host.service.handoffACPSession(context.Background(), session.ID, "")
	if err != nil {
		t.Fatal(err)
	}
	if want := "opencode --session " + chat.AgentSessionID; terminal.Command != want {
		t.Fatalf("command = %q, want %q", terminal.Command, want)
	}
	if terminal.RuntimeKind == runtimeKindACP || terminal.AgentSessionID != chat.AgentSessionID || terminal.Kind != "opencode" {
		t.Fatalf("terminal = %#v, want a TUI Session bound to %s", terminal, chat.AgentSessionID)
	}
	if _, ok := host.service.Session(session.ID); ok {
		t.Fatal("the chat Session is still present, so the conversation has two writers")
	}
	if host.service.currentAgentHandle(session.ID) != nil {
		t.Fatal("the chat Session still has an agent handle")
	}
	state := host.state.Snapshot()
	// The unknown sibling is reconciled away, leaving the terminal as the
	// group's one pane.
	if len(state.PaneGroups) != 1 || state.PaneGroups[0].Tree.SessionID != terminal.ID || state.PaneGroups[0].Tree.PaneID != "pane-1" {
		t.Fatalf("pane groups = %#v, want the terminal in the chat's pane", state.PaneGroups)
	}
}

func TestACPHandoffCommand(t *testing.T) {
	for _, test := range []struct{ kind, base, want string }{
		{"claude", "", "claude --resume abc-1"},
		{"claude", "/opt/bin/claude --model opus", "/opt/bin/claude --model opus --resume abc-1"},
		{"codex", "codex --yolo", "codex --yolo resume abc-1"},
		{"opencode", "", "opencode --session abc-1"},
	} {
		got, err := acpHandoffCommand(test.kind, test.base, "abc-1")
		if err != nil || got != test.want {
			t.Fatalf("%s %q: got %q, %v; want %q", test.kind, test.base, got, err, test.want)
		}
	}
	for _, bad := range []struct{ kind, base, id string }{
		{"claude", "", "abc; rm -rf /"},
		{"claude", "claude && echo", "abc"},
		{"claude", "codex", "abc"},
		{"pi", "", "abc"},
	} {
		if got, err := acpHandoffCommand(bad.kind, bad.base, bad.id); err == nil {
			t.Fatalf("%v accepted as %q", bad, got)
		}
	}
}

func TestACPTerminalRunsInAVisibleSessionAndReportsItsExit(t *testing.T) {
	host := newACPTestHost(t)
	session := host.create(t)
	host.send(t, session.ID, "terminal")
	host.waitTurn(t, session.ID, 1)
	events := host.events(t, session.ID)
	answer := messageText(events, "assistant")
	if len(answer) != 1 || answer[0] != `exit={"exitCode":3,"signal":null} output="one\ntwo\nred\n"` {
		t.Fatalf("assistant = %q", answer)
	}
	var terminalSessionID string
	for _, event := range events {
		if event.Type == "tool.failed" && event.Payload["callId"] == "call-t" {
			terminalSessionID, _ = event.Payload["terminalSessionId"].(string)
			if output, _ := event.Payload["output"].(string); output != "one\ntwo\nred\n" {
				t.Fatalf("tool output = %q, want the terminal's output", output)
			}
		}
	}
	if terminalSessionID == "" {
		t.Fatalf("the tool step does not link its terminal; types %v", eventTypes(events))
	}
	// Released terminals take their Session with them.
	for _, candidate := range host.state.Snapshot().Sessions {
		if candidate.ID == terminalSessionID {
			t.Fatalf("released terminal Session is still present: %#v", candidate)
		}
	}
}

func TestACPTerminalSessionIsVisibleUntilReleased(t *testing.T) {
	host := newACPTestHost(t)
	session := host.create(t)
	host.send(t, session.ID, "terminal keep")
	host.waitTurn(t, session.ID, 1)
	var terminal *api.Session
	for _, candidate := range host.state.Snapshot().Sessions {
		if candidate.Kind == "shell" && candidate.WorkspaceID == host.workspaceID {
			if candidate.Lifecycle != "ended" {
				t.Fatalf("the terminal Session outlived its command: %s", candidate.Lifecycle)
			}
			candidate := candidate
			terminal = &candidate
		}
	}
	if terminal == nil || !strings.HasPrefix(terminal.Command, "sh -c ") || terminal.RuntimeKind == runtimeKindACP {
		t.Fatalf("terminal Session = %#v, want a shell Session running the command", terminal)
	}
	// Deleting the chat releases the agent's terminals.
	if err := host.service.DeleteSession(context.Background(), session.ID); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		found := false
		for _, candidate := range host.state.Snapshot().Sessions {
			found = found || candidate.ID == terminal.ID
		}
		if !found {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("the terminal Session outlived its chat")
}

func TestACPTerminalArgvAndQuoting(t *testing.T) {
	if got := acpTerminalDisplay("sh", []string{"-c", "printf 'x'", "a b", "plain"}); got != `sh -c "printf 'x'" 'a b' plain` {
		t.Fatalf("display = %s", got)
	}
	if got := portableShellQuote(`it's a \ test`); got != `'it'"'"'s a '"\\"' test'` {
		t.Fatalf("quote = %s", got)
	}
	argv := acpTerminalArgv("/bin/zsh", "git", []string{"commit", "-m", "it's"})
	if strings.Join(argv, "|") != `/bin/zsh|-l|-c|exec 'git' 'commit' '-m' 'it'"'"'s'` {
		t.Fatalf("argv = %q", argv)
	}
	argv = acpTerminalArgv("/opt/homebrew/bin/fish", "npm test && echo ok", nil)
	if strings.Join(argv, "|") != `/opt/homebrew/bin/fish|-l|-c|exec /bin/sh -c 'npm test && echo ok'` {
		t.Fatalf("argv = %q", argv)
	}
	for _, shell := range []string{"/bin/sh", "/bin/zsh", "/bin/bash", "/opt/homebrew/bin/fish"} {
		if _, err := os.Stat(shell); err != nil {
			continue
		}
		argv := acpTerminalArgv(shell, "printf", []string{`%s|`, `it's`, `a\b`, `$HOME`, ""})
		out, err := exec.Command(argv[0], argv[1:]...).Output()
		if err != nil {
			t.Fatalf("%s: %v", shell, err)
		}
		if string(out) != `it's|a\b|$HOME||` {
			t.Fatalf("%s printed %q", shell, out)
		}
	}
}

func TestVTStripper(t *testing.T) {
	var stripper vtStripper
	var output []byte
	for _, chunk := range []string{"a\x1b[3", "1mb\x1b[0m\r", "\nprog 10%\rprog 100%\r\n", "pty\r\r\n", "\x1b]0;title\x07done\x1b(B\n"} {
		output = stripper.write(output, []byte(chunk))
	}
	if string(output) != "ab\nprog 100%\npty\ndone\n" {
		t.Fatalf("stripped = %q", output)
	}
}

func TestACPHostNegotiatesAgentConfig(t *testing.T) {
	host := newACPTestHost(t)
	if !api.SupportsCapability(host.service.AgentViewCapabilities(), api.CapabilityAgentConfig) {
		t.Fatalf("welcome capabilities %v lack %s", host.service.AgentViewCapabilities(), api.CapabilityAgentConfig)
	}
}
