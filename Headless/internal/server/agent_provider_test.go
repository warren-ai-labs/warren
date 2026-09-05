package server

import (
	"context"
	"errors"
	"sync"
	"testing"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

type lifecycleTestProvider struct {
	mu      sync.Mutex
	kind    string
	ready   bool
	key     string
	ensure  int
	handles []*lifecycleTestHandle
	same    *lifecycleTestHandle
}

func (provider *lifecycleTestProvider) Kind() string { return provider.kind }

func (provider *lifecycleTestProvider) Ensure(context.Context, AgentSessionContext) (AgentHandle, error) {
	provider.mu.Lock()
	defer provider.mu.Unlock()
	provider.ensure++
	if !provider.ready {
		return nil, ErrAgentNotReady
	}
	if provider.same != nil {
		return provider.same, nil
	}
	handle := &lifecycleTestHandle{key: provider.key}
	provider.handles = append(provider.handles, handle)
	return handle, nil
}

func (provider *lifecycleTestProvider) ensureCount() int {
	provider.mu.Lock()
	defer provider.mu.Unlock()
	return provider.ensure
}

type lifecycleTestHandle struct {
	mu      sync.Mutex
	key     string
	started int
	closed  int
	sink    AgentEventSink
	caps    CapabilitySet
}

func (handle *lifecycleTestHandle) Start(_ context.Context, sink AgentEventSink) error {
	handle.mu.Lock()
	handle.started++
	handle.sink = sink
	handle.mu.Unlock()
	return nil
}

func (handle *lifecycleTestHandle) Capabilities() CapabilitySet {
	if handle.caps != nil {
		return handle.caps.Clone()
	}
	return NewCapabilitySet(CapabilityTimeline)
}

func (handle *lifecycleTestHandle) SendMessage(context.Context, api.AgentMessageSendRequest) error {
	return nil
}

func (handle *lifecycleTestHandle) Interrupt(context.Context, api.AgentTurnInterruptRequest) error {
	return nil
}

func (handle *lifecycleTestHandle) RespondInteraction(context.Context, api.AgentInteractionResponse) error {
	return nil
}

func (handle *lifecycleTestHandle) BindingKey() string { return handle.key }

func (handle *lifecycleTestHandle) Close() error {
	handle.mu.Lock()
	handle.closed++
	handle.mu.Unlock()
	return nil
}

func (handle *lifecycleTestHandle) counts() (int, int) {
	handle.mu.Lock()
	defer handle.mu.Unlock()
	return handle.started, handle.closed
}

type capabilityLifecycleProvider struct {
	*lifecycleTestProvider
	caps CapabilitySet
}

func (provider *capabilityLifecycleProvider) Capabilities() CapabilitySet {
	return provider.caps.Clone()
}

func TestAgentProviderRegistrySelectsHandlersWithinFamily(t *testing.T) {
	tui := &flatLifecycleProvider{kind: "codex-tui"}
	acp := &flatLifecycleProvider{kind: "codex-acp"}
	registry := NewAgentProviderRegistry()
	if err := registry.Register(tui); err != nil {
		t.Fatal(err)
	}
	if err := registry.Register(acp); err != nil {
		t.Fatal(err)
	}
	if got := registry.HandlerKinds("codex"); len(got) != 2 || got[0] != AgentHandlerACP || got[1] != AgentHandlerTUI {
		t.Fatalf("handler kinds = %#v, want [acp tui]", got)
	}
	if provider, ok := registry.ProviderFor("codex", "codex-tui"); !ok || provider != tui {
		t.Fatalf("codex-tui provider = %#v, ok=%v", provider, ok)
	}
	if provider, ok := registry.ProviderFor("codex", AgentHandlerACP); !ok || provider != acp {
		t.Fatalf("codex/acp provider = %#v, ok=%v", provider, ok)
	}
	if kinds := registry.Kinds(); len(kinds) != 1 || kinds[0] != "codex" {
		t.Fatalf("registry kinds = %#v, want [codex]", kinds)
	}
	if _, ok := registry.ProviderFor("codex", "missing"); ok {
		t.Fatal("unknown handler unexpectedly selected a provider")
	}
}

type lifecycleTestHandler struct {
	kind   string
	handle AgentHandle
}

func (handler *lifecycleTestHandler) HandlerKind() string { return handler.kind }
func (handler *lifecycleTestHandler) Ensure(context.Context, AgentSessionContext) (AgentHandle, error) {
	return handler.handle, nil
}

func TestAgentProviderFamilyUsesNonTUIDefaultHandler(t *testing.T) {
	handle := &lifecycleTestHandle{key: "cli-binding"}
	family := NewAgentProviderWithHandlers("codex", &lifecycleTestHandler{kind: AgentHandlerCLI, handle: handle})
	registry := NewAgentProviderRegistry(family)
	provider, ok := registry.ProviderFor("codex", "")
	if !ok || provider != family {
		t.Fatalf("default codex provider = %#v, ok=%v", provider, ok)
	}
	selected, ok := registry.ProviderFor("codex", AgentHandlerCLI)
	if !ok || selected != family {
		t.Fatalf("composed family handler provider = %#v, ok=%v", selected, ok)
	}
	state := newStateWithSession(t, "provider-cli-default", "runtime-provider-cli-default")
	session := state.Snapshot().Sessions[0]
	session.Kind = "codex"
	if err := state.Update(func(value *api.State) error { value.Sessions[0] = session; return nil }); err != nil {
		t.Fatal(err)
	}
	service := &Service{Store: state, AgentProviders: registry}
	if _, err := service.ensureAgent(context.Background(), session); err != nil {
		t.Fatal(err)
	}
	if got := service.currentAgentHandle(session.ID); got != handle {
		t.Fatalf("selected default handle = %#v, want %#v", got, handle)
	}
}

type flatLifecycleProvider struct{ kind string }

func (provider *flatLifecycleProvider) Kind() string { return provider.kind }
func (provider *flatLifecycleProvider) Ensure(context.Context, AgentSessionContext) (AgentHandle, error) {
	return &lifecycleTestHandle{key: provider.kind}, nil
}

type familyLifecycleProvider struct {
	kind    string
	handler string
}

func (provider *familyLifecycleProvider) Kind() string        { return provider.kind }
func (provider *familyLifecycleProvider) HandlerKind() string { return provider.handler }
func (provider *familyLifecycleProvider) Ensure(context.Context, AgentSessionContext) (AgentHandle, error) {
	return &lifecycleTestHandle{key: provider.kind + "-" + provider.handler}, nil
}

func TestAgentProviderRegistryAcceptsMultipleHandlersForOneFamily(t *testing.T) {
	tui := &familyLifecycleProvider{kind: "codex", handler: AgentHandlerTUI}
	acp := &familyLifecycleProvider{kind: "codex", handler: AgentHandlerACP}
	registry := NewAgentProviderRegistry()
	if err := registry.Register(tui); err != nil {
		t.Fatal(err)
	}
	if err := registry.Register(acp); err != nil {
		t.Fatal(err)
	}
	if got := registry.HandlerKinds("codex"); len(got) != 2 || got[0] != AgentHandlerACP || got[1] != AgentHandlerTUI {
		t.Fatalf("handler kinds = %#v, want [acp tui]", got)
	}
	if provider, ok := registry.ProviderFor("codex", AgentHandlerACP); !ok || provider != acp {
		t.Fatalf("codex/acp provider = %#v, ok=%v", provider, ok)
	}
}

func TestAgentProviderRegistryUnregistersOneFlatHandler(t *testing.T) {
	tui := &flatLifecycleProvider{kind: "codex-tui"}
	acp := &flatLifecycleProvider{kind: "codex-acp"}
	registry := NewAgentProviderRegistry(tui, acp)
	registry.Unregister("codex-tui")
	if _, ok := registry.ProviderFor("codex", AgentHandlerTUI); ok {
		t.Fatal("unregistered tui handler is still available")
	}
	if provider, ok := registry.ProviderFor("codex", ""); !ok || provider != acp {
		t.Fatalf("default provider after tui removal = %#v, ok=%v; want acp", provider, ok)
	}
}

func TestAgentProviderRegistryReplaceFlatHandlerUpdatesFamilyDefault(t *testing.T) {
	oldTUI := &flatLifecycleProvider{kind: "codex-tui"}
	acp := &flatLifecycleProvider{kind: "codex-acp"}
	newTUI := &flatLifecycleProvider{kind: "codex-tui"}
	registry := NewAgentProviderRegistry(oldTUI, acp)
	if err := registry.RegisterOrReplace(newTUI); err != nil {
		t.Fatal(err)
	}
	if provider, ok := registry.ProviderFor("codex", ""); !ok || provider != newTUI {
		t.Fatalf("default provider after replacement = %#v, ok=%v; want new tui", provider, ok)
	}
	if provider, ok := registry.Provider("codex/acp"); !ok || provider != acp {
		t.Fatalf("slash handler lookup = %#v, ok=%v; want acp", provider, ok)
	}
}

func TestAgentProviderRegistryMixedComposedAndDirectHandlerOverrides(t *testing.T) {
	familyHandle := &lifecycleTestHandle{key: "family-tui"}
	family := NewAgentProviderWithHandlers("codex", &lifecycleTestHandler{kind: AgentHandlerTUI, handle: familyHandle})
	direct := &flatLifecycleProvider{kind: "codex-tui"}
	registry := NewAgentProviderRegistry(family)
	if err := registry.Register(direct); err != nil {
		t.Fatal(err)
	}
	if provider, ok := registry.ProviderFor("codex", AgentHandlerTUI); !ok || provider != direct {
		t.Fatalf("direct handler override = %#v, ok=%v; want direct provider", provider, ok)
	}
	registry.Unregister("codex-tui")
	if provider, ok := registry.ProviderFor("codex", AgentHandlerTUI); !ok || provider != family {
		t.Fatalf("composed handler after override removal = %#v, ok=%v; want family provider", provider, ok)
	}
}

func TestAgentSessionContextSplitsFlatFamilyHandlerKind(t *testing.T) {
	state := newStateWithSession(t, "provider-flat-session", "runtime-provider-flat-session")
	session := state.Snapshot().Sessions[0]
	session.Kind = "codex-acp"
	service := &Service{Store: state}
	value, err := service.agentSessionContext(state.Snapshot(), session)
	if err != nil {
		t.Fatal(err)
	}
	if value.Kind != "codex" || value.Handler != AgentHandlerACP || value.Transport != AgentHandlerACP {
		t.Fatalf("flat session context = %#v, want codex/acp", value)
	}
}

func TestEnsureAgentProviderNotReadyKeepsPlaceholderAndRetries(t *testing.T) {
	state := newStateWithSession(t, "provider-not-ready", "runtime-provider-not-ready")
	session := state.Snapshot().Sessions[0]
	session.Kind = "codex"
	if err := state.Update(func(value *api.State) error {
		value.Sessions[0] = session
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	provider := &lifecycleTestProvider{kind: "codex", key: "thread-1"}
	service := &Service{Store: state, AgentProviders: NewAgentProviderRegistry(provider)}
	first, err := service.ensureAgent(context.Background(), session)
	if err != nil {
		t.Fatal(err)
	}
	if first == nil || service.currentAgentHandle(session.ID) != nil {
		t.Fatal("not-ready ensure must retain a placeholder without a handle")
	}
	provider.ready = true
	second, err := service.ensureAgent(context.Background(), session)
	if err != nil {
		t.Fatal(err)
	}
	if second == nil || service.currentAgentHandle(session.ID) == nil {
		t.Fatal("ready retry must install a handle")
	}
	if provider.ensureCount() != 2 {
		t.Fatalf("provider Ensure calls = %d, want 2", provider.ensureCount())
	}
	service.stopAgent(session.ID)
}

func TestEnsureAgentReusesBindingAndClosesOnlyCandidate(t *testing.T) {
	state := newStateWithSession(t, "provider-reuse", "runtime-provider-reuse")
	session := state.Snapshot().Sessions[0]
	session.Kind = "codex"
	if err := state.Update(func(value *api.State) error { value.Sessions[0] = session; return nil }); err != nil {
		t.Fatal(err)
	}
	provider := &lifecycleTestProvider{kind: "codex", key: "thread-same", ready: true}
	service := &Service{Store: state, AgentProviders: NewAgentProviderRegistry(provider)}
	if _, err := service.ensureAgent(context.Background(), session); err != nil {
		t.Fatal(err)
	}
	first := service.currentAgentHandle(session.ID).(*lifecycleTestHandle)
	if _, err := service.ensureAgent(context.Background(), session); err != nil {
		t.Fatal(err)
	}
	started, closed := first.counts()
	if started != 1 || closed != 0 {
		t.Fatalf("existing handle counts = started %d, closed %d; want 1, 0", started, closed)
	}
	provider.same = first
	if _, err := service.ensureAgent(context.Background(), session); err != nil {
		t.Fatal(err)
	}
	started, closed = first.counts()
	if started != 1 || closed != 0 {
		t.Fatalf("same handle was closed during reuse: started %d, closed %d", started, closed)
	}
	provider.mu.Lock()
	candidate := provider.handles[1]
	provider.mu.Unlock()
	if _, closed := candidate.counts(); closed != 1 {
		t.Fatalf("same-binding candidate close count = %d, want 1", closed)
	}
	service.stopAgent(session.ID)
}

func TestEnsureAgentRebindsBeforeAcceptingStaleCallbacks(t *testing.T) {
	state := newStateWithSession(t, "provider-rebind", "runtime-provider-rebind")
	session := state.Snapshot().Sessions[0]
	session.Kind = "codex"
	if err := state.Update(func(value *api.State) error { value.Sessions[0] = session; return nil }); err != nil {
		t.Fatal(err)
	}
	provider := &lifecycleTestProvider{kind: "codex", key: "thread-a", ready: true}
	service := &Service{Store: state, AgentProviders: NewAgentProviderRegistry(provider)}
	if _, err := service.ensureAgent(context.Background(), session); err != nil {
		t.Fatal(err)
	}
	first := service.currentAgentHandle(session.ID).(*lifecycleTestHandle)
	first.mu.Lock()
	oldSink := first.sink
	first.mu.Unlock()
	if oldSink == nil {
		t.Fatal("first handle did not receive an event sink")
	}
	oldSink.(interface {
		OnEvents([]api.AgentEvent, api.AgentStatus)
	}).OnEvents([]api.AgentEvent{{Provider: "codex", Type: "assistant", Content: "old"}}, api.AgentStatus{Activity: api.AgentActivityWorking})
	if got := len(service.agentHistory(session.ID)); got != 1 {
		t.Fatalf("initial history length = %d, want 1", got)
	}
	provider.key = "thread-b"
	if _, err := service.ensureAgent(context.Background(), session); err != nil {
		t.Fatal(err)
	}
	second := service.currentAgentHandle(session.ID).(*lifecycleTestHandle)
	if second == first {
		t.Fatal("binding change reused the old handle")
	}
	if _, closed := first.counts(); closed != 1 {
		t.Fatalf("old handle close count = %d, want 1", closed)
	}
	if got := len(service.agentHistory(session.ID)); got != 0 {
		t.Fatalf("history after rebind = %d, want reset", got)
	}
	oldSink.(interface {
		OnEvents([]api.AgentEvent, api.AgentStatus)
	}).OnEvents([]api.AgentEvent{{Provider: "codex", Type: "assistant", Content: "stale"}}, api.AgentStatus{Activity: api.AgentActivityWorking})
	if got := len(service.agentHistory(session.ID)); got != 0 {
		t.Fatalf("stale callback repopulated history: %d", got)
	}
	second.mu.Lock()
	newSink := second.sink
	second.mu.Unlock()
	newSink.(interface {
		OnEvents([]api.AgentEvent, api.AgentStatus)
	}).OnEvents([]api.AgentEvent{{Provider: "codex", Type: "assistant", Content: "new"}}, api.AgentStatus{Activity: api.AgentActivityWorking})
	if got := len(service.agentHistory(session.ID)); got != 1 {
		t.Fatalf("new callback history length = %d, want 1", got)
	}
	service.stopAgent(session.ID)
}

func TestAgentCapabilitiesIntersectProviderAndHandle(t *testing.T) {
	state := newStateWithSession(t, "provider-capabilities", "runtime-provider-capabilities")
	session := state.Snapshot().Sessions[0]
	session.Kind = "codex"
	if err := state.Update(func(value *api.State) error { value.Sessions[0] = session; return nil }); err != nil {
		t.Fatal(err)
	}
	base := &lifecycleTestProvider{kind: "codex", key: "thread-capabilities", ready: true}
	provider := &capabilityLifecycleProvider{lifecycleTestProvider: base, caps: NewCapabilitySet(CapabilityTimeline)}
	// The handle claims an extra attachment feature, but the provider family
	// does not. The published session projection must keep only the common bit.
	base.handles = []*lifecycleTestHandle{{key: base.key, caps: NewCapabilitySet(CapabilityTimeline, CapabilityAttachments)}}
	base.same = base.handles[0]
	service := &Service{Store: state, AgentProviders: NewAgentProviderRegistry(provider)}
	if _, err := service.ensureAgent(context.Background(), session); err != nil {
		t.Fatal(err)
	}
	capabilities := service.agentCapabilitiesForSession(session.ID, session)
	if !api.SupportsCapability(capabilities, api.CapabilityAgentTimeline) || api.SupportsCapability(capabilities, api.CapabilityAgentAttachments) {
		t.Fatalf("effective capabilities = %#v, want timeline only", capabilities)
	}
}

func TestAgentHandleReadyAdvancesRosterRevision(t *testing.T) {
	state := newStateWithSession(t, "provider-roster-revision", "runtime-provider-roster-revision")
	session := state.Snapshot().Sessions[0]
	session.Kind = "codex"
	if err := state.Update(func(value *api.State) error { value.Sessions[0] = session; return nil }); err != nil {
		t.Fatal(err)
	}
	provider := &lifecycleTestProvider{kind: "codex", key: "thread-roster", ready: true}
	service := &Service{Store: state, AgentProviders: NewAgentProviderRegistry(provider)}
	before, _ := service.RosterVersion(context.Background())
	if _, err := service.ensureAgent(context.Background(), session); err != nil {
		t.Fatal(err)
	}
	after, _ := service.RosterVersion(context.Background())
	if after.Revision <= before.Revision {
		t.Fatalf("roster revision did not advance: before=%d after=%d", before.Revision, after.Revision)
	}
	if !api.SupportsCapability(after.Sessions[0].AgentCapabilities, api.CapabilityAgentTimeline) {
		t.Fatalf("ready session capabilities = %#v, want timeline", after.Sessions[0].AgentCapabilities)
	}
	service.stopAgent(session.ID)
}

func TestAgentHandleCloseOnDeleteAndShutdown(t *testing.T) {
	t.Run("delete", func(t *testing.T) {
		state := newStateWithSession(t, "provider-delete", "runtime-provider-delete")
		session := state.Snapshot().Sessions[0]
		session.Kind = "codex"
		if err := state.Update(func(value *api.State) error { value.Sessions[0] = session; return nil }); err != nil {
			t.Fatal(err)
		}
		runtime := newMemoryOutputRuntime(t)
		if err := runtime.Create(context.Background(), session.Runtime, "/tmp", "", nil); err != nil {
			t.Fatal(err)
		}
		provider := &lifecycleTestProvider{kind: "codex", key: "thread-delete", ready: true}
		service := &Service{Store: state, Runtime: runtime, AgentProviders: NewAgentProviderRegistry(provider)}
		if _, err := service.ensureAgent(context.Background(), session); err != nil {
			t.Fatal(err)
		}
		handle := service.currentAgentHandle(session.ID).(*lifecycleTestHandle)
		if err := service.DeleteSession(context.Background(), session.ID); err != nil {
			t.Fatal(err)
		}
		if _, closed := handle.counts(); closed != 1 {
			t.Fatalf("deleted handle close count = %d, want 1", closed)
		}
	})
	t.Run("shutdown", func(t *testing.T) {
		state := newStateWithSession(t, "provider-shutdown", "runtime-provider-shutdown")
		session := state.Snapshot().Sessions[0]
		session.Kind = "codex"
		if err := state.Update(func(value *api.State) error { value.Sessions[0] = session; return nil }); err != nil {
			t.Fatal(err)
		}
		provider := &lifecycleTestProvider{kind: "codex", key: "thread-shutdown", ready: true}
		service := &Service{Store: state, AgentProviders: NewAgentProviderRegistry(provider)}
		if _, err := service.ensureAgent(context.Background(), session); err != nil {
			t.Fatal(err)
		}
		handle := service.currentAgentHandle(session.ID).(*lifecycleTestHandle)
		service.Shutdown()
		service.Shutdown()
		if _, closed := handle.counts(); closed != 1 {
			t.Fatalf("shutdown handle close count = %d, want 1", closed)
		}
	})
}

func TestACPAgentProviderRegistrationAndHandle(t *testing.T) {
	service := &Service{}
	registry := NewDefaultAgentProviderRegistry(service)

	// The ACP registration is intentionally present for future transport
	// negotiation, but it must remain not-ready until the wire adapter exists.
	ctx := context.Background()
	_, err := registry.Ensure(ctx, AgentSessionContext{
		SessionID: "sess-acp-1",
		Kind:      "codex",
		Handler:   AgentHandlerACP,
	})
	if !errors.Is(err, ErrAgentNotReady) {
		t.Fatalf("ACP ensure error = %v, want ErrAgentNotReady", err)
	}

	// Also verify embedded handler syntax "codex-acp"
	_, err = registry.Ensure(ctx, AgentSessionContext{
		SessionID: "sess-acp-2",
		Kind:      "codex-acp",
	})
	if !errors.Is(err, ErrAgentNotReady) {
		t.Fatalf("embedded ACP ensure error = %v, want ErrAgentNotReady", err)
	}
}
