package server

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/agent"
	"github.com/abcdlsj/warren/Headless/internal/api"
)

// ErrAgentNotReady means that a provider is known, but its binding or
// transport has not become observable yet. It is deliberately distinct from
// an unknown provider or a provider failure: the lifecycle reconciler keeps a
// placeholder for this case and retries on its next pass.
var ErrAgentNotReady = errors.New("agent is not ready")

// ErrAgentProviderNotFound is returned when no provider has been registered
// for a Session kind.
var ErrAgentProviderNotFound = errors.New("agent provider is not registered")

// Capability is the typed form used inside Headless. String values are only
// emitted at the protocol boundary.
type Capability string

const (
	CapabilityTimeline     Capability = api.CapabilityAgentTimeline
	CapabilityInteractions Capability = api.CapabilityAgentInteractions
	CapabilityInterrupt    Capability = api.CapabilityAgentInterrupt
	CapabilityAttachments  Capability = api.CapabilityAgentAttachments
)

// Well-known handler names are intentionally transport-oriented. They are
// selected inside an agent family, so a future ACP implementation can sit next
// to the existing TUI handler without creating a second agent kind.
const (
	AgentHandlerTUI = "tui"
	AgentHandlerCLI = "cli"
	AgentHandlerACP = "acp"
)

// CapabilitySet is an immutable-by-convention set of provider/transport
// capabilities. Constructors and set operations always return fresh maps so
// a provider cannot mutate a handle's advertised values through a shared map.
type CapabilitySet map[Capability]struct{}

func NewCapabilitySet(values ...Capability) CapabilitySet {
	result := make(CapabilitySet, len(values))
	for _, value := range values {
		if value != "" {
			result[value] = struct{}{}
		}
	}
	return result
}

func (set CapabilitySet) Has(value Capability) bool {
	_, ok := set[value]
	return ok
}

// Contains is an alias that reads naturally at action call sites.
func (set CapabilitySet) Contains(value Capability) bool { return set.Has(value) }

func (set CapabilitySet) Clone() CapabilitySet {
	result := make(CapabilitySet, len(set))
	for value := range set {
		result[value] = struct{}{}
	}
	return result
}

func (set CapabilitySet) Strings() []string {
	values := make([]string, 0, len(set))
	for value := range set {
		values = append(values, string(value))
	}
	sort.Strings(values)
	return values
}

// CapabilitySetFromStrings is used only when crossing the existing string
// capability boundary (for example a client handshake or a test fixture).
func CapabilitySetFromStrings(values []string) CapabilitySet {
	result := make(CapabilitySet, len(values))
	for _, value := range values {
		value = strings.TrimSpace(value)
		if value != "" {
			result[Capability(value)] = struct{}{}
		}
	}
	return result
}

func IntersectCapabilitySets(sets ...CapabilitySet) CapabilitySet {
	if len(sets) == 0 {
		return NewCapabilitySet()
	}
	result := sets[0].Clone()
	for _, set := range sets[1:] {
		for value := range result {
			if !set.Has(value) {
				delete(result, value)
			}
		}
	}
	return result
}

// AgentMessage and the two request aliases keep the provider boundary tied to
// the established API shapes without exposing filesystem paths on the wire.
type AgentMessage = api.AgentMessageSendRequest
type AgentInterruptRequest = api.AgentTurnInterruptRequest
type AgentInteractionResponse = api.AgentInteractionResponse

// AgentSessionContext is the provider-facing view of one Warren Session. The
// full API Session is retained for forward compatibility; the duplicated
// fields make fake providers and future ACP implementations independent from
// persistence details.
type AgentSessionContext struct {
	Session   api.Session
	SessionID string
	// Kind identifies the agent family (codex, claude, opencode, pi, qoder).
	Kind string
	// Handler selects the transport/runtime implementation inside that agent
	// family (normally tui, acp, or cli). Transport is an alias retained for
	// callers that use protocol terminology.
	Handler        string
	Transport      string
	WorkspacePath  string
	AgentSessionID string
	TranscriptPath string
	Runtime        string
	RuntimeKind    string
	Binding        string
}

// AgentEventSink is intentionally permissive at the package boundary. The
// service accepts both method-based sinks (OnEvents/OnStatus/OnTurns or their
// shorter Events/Status/Turns spellings) and AgentEventSinkFuncs. Keeping the
// type open lets an ACP provider evolve callback details without another
// public interface migration.
type AgentEventSink interface{}

// AgentEventSinkFuncs is the convenience implementation for providers and
// tests. Nil callbacks are allowed.
type AgentEventSinkFuncs struct {
	OnEvents func([]api.AgentEvent, api.AgentStatus)
	OnStatus func(api.AgentStatus)
	OnTurns  func([]api.AgentTurn, bool)
}

func (sink AgentEventSinkFuncs) Events(events []api.AgentEvent, status api.AgentStatus) {
	if sink.OnEvents != nil {
		sink.OnEvents(events, status)
	}
}

func (sink AgentEventSinkFuncs) Status(status api.AgentStatus) {
	if sink.OnStatus != nil {
		sink.OnStatus(status)
	}
}

func (sink AgentEventSinkFuncs) Turns(turns []api.AgentTurn, replay bool) {
	if sink.OnTurns != nil {
		sink.OnTurns(turns, replay)
	}
}

// AgentProvider creates a handle bound to one Warren Session. Providers own
// discovery and provider-specific parsing; the Service owns reconciliation.
type AgentProvider interface {
	Kind() string
	Ensure(context.Context, AgentSessionContext) (AgentHandle, error)
}

// AgentProviderCapabilities is optional to keep the original two-method
// provider contract source-compatible. When present, Service intersects it
// with the selected handle's runtime capabilities before publishing a
// Session-level capability set.
type AgentProviderCapabilities interface {
	Capabilities() CapabilitySet
}

// AgentHandler is the optional finer-grained provider contract. A provider
// family can expose several handlers (for example codex/tui and codex/acp)
// while the lifecycle service continues to depend only on AgentProvider.
type AgentHandler interface {
	HandlerKind() string
	Ensure(context.Context, AgentSessionContext) (AgentHandle, error)
}

// handlerAgentProvider composes one agent family from transport-specific
// handlers. The registry still exposes the stable AgentProvider contract, but
// a caller can add codex/acp beside codex/tui without inventing a second
// provider kind.
type handlerAgentProvider struct {
	kind           string
	defaultHandler string
	handlers       map[string]AgentHandler
}

func NewAgentProviderWithHandlers(kind string, handlers ...AgentHandler) *handlerAgentProvider {
	provider := &handlerAgentProvider{
		kind: normalizeProviderKind(kind), handlers: make(map[string]AgentHandler),
	}
	for _, handler := range handlers {
		if !nonNilInterface(handler) {
			continue
		}
		handlerKind := normalizeProviderKind(handler.HandlerKind())
		if handlerKind == "" {
			continue
		}
		provider.handlers[handlerKind] = handler
		if provider.defaultHandler == "" {
			provider.defaultHandler = handlerKind
		}
	}
	return provider
}

func (provider *handlerAgentProvider) Kind() string {
	if provider == nil {
		return ""
	}
	return provider.kind
}

// HandlerKind returns the family default. It is useful when a roster wants to
// expose the effective handler selected for a Session without leaking the
// registry's internal map.
func (provider *handlerAgentProvider) HandlerKind() string {
	if provider == nil {
		return ""
	}
	return provider.defaultHandler
}

func (provider *handlerAgentProvider) HandlerKinds() []string {
	if provider == nil {
		return nil
	}
	result := make([]string, 0, len(provider.handlers))
	for kind := range provider.handlers {
		result = append(result, kind)
	}
	sort.Strings(result)
	return result
}

func (provider *handlerAgentProvider) hasHandler(kind string) bool {
	if provider == nil {
		return false
	}
	_, ok := provider.handlers[normalizeProviderKind(kind)]
	return ok
}

// Capabilities returns the union declared by the registered handlers. The
// selected handle still narrows this set at reconciliation time; a nil result
// means that none of the handlers made a provider-level declaration.
func (provider *handlerAgentProvider) Capabilities() CapabilitySet {
	if provider == nil {
		return nil
	}
	var result CapabilitySet
	for _, handler := range provider.handlers {
		advertiser, ok := handler.(AgentProviderCapabilities)
		if !ok {
			continue
		}
		declared := advertiser.Capabilities()
		if declared == nil {
			continue
		}
		if result == nil {
			result = NewCapabilitySet()
		}
		for capability := range declared {
			result[capability] = struct{}{}
		}
	}
	return result
}

func (provider *handlerAgentProvider) Ensure(ctx context.Context, value AgentSessionContext) (AgentHandle, error) {
	if provider == nil {
		return nil, ErrAgentProviderNotFound
	}
	if family, embeddedHandler := splitAgentKey(value.Kind); family == provider.kind && embeddedHandler != "" {
		value.Kind = family
		if strings.TrimSpace(value.Handler) == "" && strings.TrimSpace(value.Transport) == "" {
			value.Handler = embeddedHandler
			value.Transport = embeddedHandler
		}
	}
	handlerKind := normalizeProviderKind(value.Handler)
	if handlerKind == "" {
		handlerKind = normalizeProviderKind(value.Transport)
	}
	if family, embeddedHandler := splitAgentKey(handlerKind); family == provider.kind && embeddedHandler != "" {
		handlerKind = embeddedHandler
	}
	if handlerKind == "" {
		handlerKind = provider.defaultHandler
	}
	handler := provider.handlers[handlerKind]
	if handler == nil {
		return nil, fmt.Errorf("%w: %s/%s", ErrAgentProviderNotFound, provider.kind, handlerKind)
	}
	return handler.Ensure(ctx, value)
}

// AgentHandle is the lifecycle boundary between Service and a concrete PTY or
// ACP implementation. Start and Close must be safe to call more than once.
type AgentHandle interface {
	Start(context.Context, AgentEventSink) error
	Capabilities() CapabilitySet

	SendMessage(context.Context, AgentMessage) error
	Interrupt(context.Context, AgentInterruptRequest) error
	RespondInteraction(context.Context, AgentInteractionResponse) error

	BindingKey() string
	Close() error
}

// AgentProviderRegistry is concurrency-safe so a daemon can register a
// future provider while tests or embedders are reconciling existing sessions.
type AgentProviderRegistry struct {
	mu        sync.RWMutex
	providers map[string]AgentProvider
	handlers  map[string]map[string]AgentProvider
}

// AgentRegistry is a shorter compatibility name for callers that do not need
// to spell out the Provider suffix.
type AgentRegistry = AgentProviderRegistry

func NewAgentProviderRegistry(providers ...AgentProvider) *AgentProviderRegistry {
	registry := &AgentProviderRegistry{providers: make(map[string]AgentProvider), handlers: make(map[string]map[string]AgentProvider)}
	for _, provider := range providers {
		if !nonNilInterface(provider) {
			continue
		}
		_ = registry.Register(provider)
		if _, composed := provider.(*handlerAgentProvider); composed {
			// The composed provider resolves all of its handlers internally.
			// Registering only its default in the outer map would make an
			// explicitly requested secondary handler look unavailable.
			continue
		}
		if handler, ok := provider.(interface{ HandlerKind() string }); ok && strings.TrimSpace(handler.HandlerKind()) != "" {
			_ = registry.RegisterHandler(provider, handler.HandlerKind())
		}
	}
	return registry
}

func NewAgentRegistry(providers ...AgentProvider) *AgentProviderRegistry {
	return NewAgentProviderRegistry(providers...)
}

func normalizeProviderKind(kind string) string {
	return strings.ToLower(strings.TrimSpace(kind))
}

// providerMatchesHandler reports whether a registered family default is the
// transport identified by family/handler. Composed providers deliberately do
// not match here: unregistering an outer direct override should reveal the
// composed provider's own handler rather than remove the family itself.
func providerMatchesHandler(provider AgentProvider, family, handler string) bool {
	if !nonNilInterface(provider) {
		return false
	}
	family = normalizeProviderKind(family)
	handler = normalizeProviderKind(handler)
	if family == "" || handler == "" {
		return false
	}
	registeredFamily, registeredHandler := splitAgentKey(provider.Kind())
	if registeredFamily == family && registeredHandler == handler {
		return true
	}
	if registeredFamily != family || registeredHandler != "" {
		return false
	}
	if _, composed := provider.(*handlerAgentProvider); composed {
		return false
	}
	selected, ok := provider.(interface{ HandlerKind() string })
	return ok && normalizeProviderKind(selected.HandlerKind()) == handler
}

func (registry *AgentProviderRegistry) Register(provider AgentProvider) error {
	if registry == nil {
		return errors.New("agent provider registry is nil")
	}
	if !nonNilInterface(provider) {
		return errors.New("agent provider is nil")
	}
	kind := normalizeProviderKind(provider.Kind())
	if kind == "" {
		return errors.New("agent provider kind is required")
	}
	// Accept the convenient flat spelling (for example codex-tui) in addition
	// to the preferred family-plus-handler registration. This keeps registry
	// callers from having to wrap a handler solely to register one transport.
	family, handler := splitAgentKey(kind)
	registry.mu.Lock()
	defer registry.mu.Unlock()
	if registry.providers == nil {
		registry.providers = make(map[string]AgentProvider)
	}
	if registry.handlers == nil {
		registry.handlers = make(map[string]map[string]AgentProvider)
	}
	if _, exists := registry.providers[kind]; exists {
		// A family may be registered once per handler when each concrete
		// provider advertises the same Kind (for example codex/tui followed by
		// codex/acp). Keep the first family's default provider, but add the new
		// transport under the second-level handler map.
		if family == kind {
			if handlerProvider, ok := provider.(interface{ HandlerKind() string }); ok {
				handlerKind := normalizeProviderKind(handlerProvider.HandlerKind())
				if handlerKind != "" {
					if registry.handlers[family] == nil {
						registry.handlers[family] = make(map[string]AgentProvider)
					}
					if _, duplicate := registry.handlers[family][handlerKind]; duplicate {
						return fmt.Errorf("agent handler %q/%q is already registered", family, handlerKind)
					}
					registry.handlers[family][handlerKind] = provider
					return nil
				}
			}
		}
		return fmt.Errorf("agent provider %q is already registered", kind)
	}
	if family != kind {
		if byHandler := registry.handlers[family]; byHandler != nil {
			if _, exists := byHandler[handler]; exists {
				return fmt.Errorf("agent handler %q/%q is already registered", family, handler)
			}
		}
	}
	registry.providers[kind] = provider
	if family != kind {
		if registry.handlers == nil {
			registry.handlers = make(map[string]map[string]AgentProvider)
		}
		if registry.handlers[family] == nil {
			registry.handlers[family] = make(map[string]AgentProvider)
		}
		registry.handlers[family][handler] = provider
		if _, exists := registry.providers[family]; !exists {
			registry.providers[family] = provider
		}
	} else if _, composed := provider.(*handlerAgentProvider); !composed {
		if handlerProvider, ok := provider.(interface{ HandlerKind() string }); ok {
			// Registering a family provider directly is the common case for a
			// provider that exposes one transport. Record that transport here so
			// callers can inspect HandlerKinds without having to make a second
			// registration call. Composed providers keep their internal dispatch
			// table and are resolved by their own Ensure method.
			if handlerKind := normalizeProviderKind(handlerProvider.HandlerKind()); handlerKind != "" {
				if registry.handlers[family] == nil {
					registry.handlers[family] = make(map[string]AgentProvider)
				}
				if _, exists := registry.handlers[family][handlerKind]; !exists {
					registry.handlers[family][handlerKind] = provider
				}
			}
		}
	}
	return nil
}

// RegisterHandler adds a transport-specific implementation under an agent
// family. The provider's Kind remains the family key; HandlerKind is the
// second-level key and is deliberately not exposed on the wire.
func (registry *AgentProviderRegistry) RegisterHandler(provider AgentProvider, handler string) error {
	if registry == nil {
		return errors.New("agent provider registry is nil")
	}
	if !nonNilInterface(provider) {
		return errors.New("agent provider is nil")
	}
	kind := normalizeProviderKind(provider.Kind())
	embeddedHandler := ""
	if family, embedded := splitAgentKey(kind); family != kind {
		kind = family
		embeddedHandler = embedded
		if handler == "" {
			handler = embedded
		}
	}
	handler = normalizeProviderKind(handler)
	if family, embeddedHandler := splitAgentKey(handler); family == kind && embeddedHandler != "" {
		handler = embeddedHandler
	}
	if embeddedHandler != "" && handler != embeddedHandler {
		return fmt.Errorf("agent handler %q does not match provider %q", handler, kind)
	}
	if kind == "" || handler == "" {
		return errors.New("agent provider and handler kinds are required")
	}
	registry.mu.Lock()
	defer registry.mu.Unlock()
	if registry.handlers == nil {
		registry.handlers = make(map[string]map[string]AgentProvider)
	}
	if registry.handlers[kind] == nil {
		registry.handlers[kind] = make(map[string]AgentProvider)
	}
	if _, exists := registry.handlers[kind][handler]; exists {
		return fmt.Errorf("agent handler %q/%q is already registered", kind, handler)
	}
	registry.handlers[kind][handler] = provider
	if registry.providers == nil {
		registry.providers = make(map[string]AgentProvider)
	}
	if _, exists := registry.providers[kind]; !exists {
		registry.providers[kind] = provider
	}
	return nil
}

// RegisterWithHandler is the explicit form useful when a provider's concrete
// type does not expose HandlerKind.
func (registry *AgentProviderRegistry) RegisterWithHandler(agentKind, handler string, provider AgentProvider) error {
	if !nonNilInterface(provider) {
		return errors.New("agent provider is nil")
	}
	providerKind := normalizeProviderKind(provider.Kind())
	providerFamily, _ := splitAgentKey(providerKind)
	requestedFamily, _ := splitAgentKey(agentKind)
	if requestedFamily != providerKind && requestedFamily != providerFamily {
		return fmt.Errorf("agent provider kind mismatch: %s", agentKind)
	}
	return registry.RegisterHandler(provider, handler)
}

func (registry *AgentProviderRegistry) RegisterAgentHandler(agentKind, handler string, provider AgentProvider) error {
	return registry.RegisterWithHandler(agentKind, handler, provider)
}

func (registry *AgentProviderRegistry) RegisterOrReplace(provider AgentProvider) error {
	if registry == nil {
		return errors.New("agent provider registry is nil")
	}
	if !nonNilInterface(provider) {
		return errors.New("agent provider is nil")
	}
	kind := normalizeProviderKind(provider.Kind())
	if kind == "" {
		return errors.New("agent provider kind is required")
	}
	family, embeddedHandler := splitAgentKey(kind)
	registry.mu.Lock()
	defer registry.mu.Unlock()
	if registry.providers == nil {
		registry.providers = make(map[string]AgentProvider)
	}
	if registry.handlers == nil {
		registry.handlers = make(map[string]map[string]AgentProvider)
	}
	registry.providers[kind] = provider
	if family != kind {
		if registry.handlers[family] == nil {
			registry.handlers[family] = make(map[string]AgentProvider)
		}
		registry.handlers[family][embeddedHandler] = provider
		if current, exists := registry.providers[family]; !exists || providerMatchesHandler(current, family, embeddedHandler) {
			registry.providers[family] = provider
		}
	} else if _, composed := provider.(*handlerAgentProvider); !composed {
		if handler, ok := provider.(interface{ HandlerKind() string }); ok {
			if handlerKind := normalizeProviderKind(handler.HandlerKind()); handlerKind != "" {
				if registry.handlers[kind] == nil {
					registry.handlers[kind] = make(map[string]AgentProvider)
				}
				registry.handlers[kind][handlerKind] = provider
			}
		}
	}
	return nil
}

func (registry *AgentProviderRegistry) Unregister(kind string) {
	if registry == nil {
		return
	}
	registry.mu.Lock()
	defer registry.mu.Unlock()
	kind = normalizeProviderKind(kind)
	family, handler := splitAgentKey(kind)
	if handler != "" {
		defaultIsRemoved := false
		if current, ok := registry.providers[family]; ok && current != nil {
			defaultIsRemoved = providerMatchesHandler(current, family, handler)
		}
		delete(registry.providers, kind)
		if byHandler := registry.handlers[family]; byHandler != nil {
			delete(byHandler, handler)
			if len(byHandler) == 0 {
				delete(registry.handlers, family)
			}
		}
		// If the removed flat provider was also the family's default, promote a
		// remaining handler deterministically. A family provider registered
		// under the plain key is left untouched when it is not the removed one.
		if defaultIsRemoved {
			delete(registry.providers, family)
		}
		if _, ok := registry.providers[family]; !ok {
			if byHandler := registry.handlers[family]; byHandler != nil {
				handlers := make([]string, 0, len(byHandler))
				for name := range byHandler {
					handlers = append(handlers, name)
				}
				sort.Strings(handlers)
				if len(handlers) > 0 {
					registry.providers[family] = byHandler[handlers[0]]
				}
			}
		}
		return
	}
	delete(registry.providers, family)
	delete(registry.handlers, family)
	for registeredKind := range registry.providers {
		registeredFamily, _ := splitAgentKey(registeredKind)
		if registeredFamily == family {
			delete(registry.providers, registeredKind)
		}
	}
}

func (registry *AgentProviderRegistry) Provider(kind string) (AgentProvider, bool) {
	if registry == nil {
		return nil, false
	}
	kind = normalizeProviderKind(kind)
	registry.mu.RLock()
	provider, ok := registry.providers[kind]
	if !ok {
		family, handler := splitAgentKey(kind)
		if handler != "" {
			if byHandler := registry.handlers[family]; byHandler != nil {
				provider, ok = byHandler[handler]
			}
			if !ok {
				if familyProvider, composed := registry.providers[family].(*handlerAgentProvider); composed && familyProvider.hasHandler(handler) {
					provider, ok = familyProvider, true
				}
			}
		}
	}
	registry.mu.RUnlock()
	return provider, ok
}

// ProviderFor resolves an agent family and its selected handler. Empty
// handler falls back to the family default provider.
func (registry *AgentProviderRegistry) ProviderFor(kind, handler string) (AgentProvider, bool) {
	if registry == nil {
		return nil, false
	}
	kind = normalizeProviderKind(kind)
	handler = normalizeProviderKind(handler)
	if family, embeddedHandler := splitAgentKey(kind); embeddedHandler != "" {
		kind = family
		if handler == "" {
			handler = embeddedHandler
		} else {
			if handlerFamily, handlerSuffix := splitAgentKey(handler); handlerFamily == kind && handlerSuffix != "" {
				handler = handlerSuffix
			}
			if handler != embeddedHandler {
				return nil, false
			}
		}
	}
	if family, embeddedHandler := splitAgentKey(handler); family == kind && embeddedHandler != "" {
		handler = embeddedHandler
	}
	registry.mu.RLock()
	if handler != "" {
		if byHandler := registry.handlers[kind]; byHandler != nil {
			if provider, ok := byHandler[handler]; ok {
				registry.mu.RUnlock()
				return provider, true
			}
			if familyProvider, composed := registry.providers[kind].(*handlerAgentProvider); composed && familyProvider.hasHandler(handler) {
				registry.mu.RUnlock()
				return familyProvider, true
			}
			// A family explicitly registered with handlers must not silently
			// fall back to a different transport when a requested handler is
			// unavailable.
			registry.mu.RUnlock()
			return nil, false
		}
		if provider, ok := registry.providers[kind]; ok {
			if familyProvider, composed := provider.(*handlerAgentProvider); composed {
				if familyProvider.hasHandler(handler) {
					registry.mu.RUnlock()
					return familyProvider, true
				}
				registry.mu.RUnlock()
				return nil, false
			}
			if selected, handlerAware := provider.(interface{ HandlerKind() string }); handlerAware &&
				normalizeProviderKind(selected.HandlerKind()) == handler {
				registry.mu.RUnlock()
				return provider, true
			}
		}
		if provider, ok := registry.providers[kind+"-"+handler]; ok {
			registry.mu.RUnlock()
			return provider, true
		}
		registry.mu.RUnlock()
		return nil, false
	}
	provider, ok := registry.providers[kind]
	registry.mu.RUnlock()
	return provider, ok
}

func (registry *AgentProviderRegistry) HandlerKinds(kind string) []string {
	if registry == nil {
		return nil
	}
	kind, _ = splitAgentKey(kind)
	registry.mu.RLock()
	seen := make(map[string]struct{})
	values := make([]string, 0, len(registry.handlers[kind]))
	for handler := range registry.handlers[kind] {
		seen[handler] = struct{}{}
		values = append(values, handler)
	}
	if provider, ok := registry.providers[kind].(*handlerAgentProvider); ok {
		for _, handler := range provider.HandlerKinds() {
			if _, exists := seen[handler]; exists {
				continue
			}
			seen[handler] = struct{}{}
			values = append(values, handler)
		}
	}
	registry.mu.RUnlock()
	sort.Strings(values)
	return values
}

func (registry *AgentProviderRegistry) Get(kind string) AgentProvider {
	provider, _ := registry.Provider(kind)
	return provider
}

func (registry *AgentProviderRegistry) Kinds() []string {
	if registry == nil {
		return nil
	}
	registry.mu.RLock()
	seen := make(map[string]struct{}, len(registry.providers)+len(registry.handlers))
	result := make([]string, 0, len(registry.providers)+len(registry.handlers))
	for kind := range registry.providers {
		family, _ := splitAgentKey(kind)
		if _, ok := seen[family]; ok {
			continue
		}
		seen[family] = struct{}{}
		result = append(result, family)
	}
	for kind := range registry.handlers {
		family, _ := splitAgentKey(kind)
		if _, ok := seen[family]; !ok {
			seen[family] = struct{}{}
			result = append(result, family)
		}
	}
	registry.mu.RUnlock()
	sort.Strings(result)
	return result
}

func (registry *AgentProviderRegistry) Ensure(ctx context.Context, session AgentSessionContext) (AgentHandle, error) {
	if registry == nil {
		return nil, fmt.Errorf("%w: %s", ErrAgentProviderNotFound, normalizeProviderKind(session.Kind))
	}
	if family, embeddedHandler := splitAgentKey(session.Kind); embeddedHandler != "" {
		session.Kind = family
		if strings.TrimSpace(session.Handler) == "" && strings.TrimSpace(session.Transport) == "" {
			session.Handler = embeddedHandler
			session.Transport = embeddedHandler
		}
	}
	handler := session.Handler
	if handler == "" {
		handler = session.Transport
	}
	if family, embeddedHandler := splitAgentKey(handler); family == normalizeProviderKind(session.Kind) && embeddedHandler != "" {
		handler = embeddedHandler
		session.Handler = handler
		session.Transport = handler
	}
	provider, ok := registry.ProviderFor(session.Kind, handler)
	if !ok {
		return nil, fmt.Errorf("%w: %s", ErrAgentProviderNotFound, normalizeProviderKind(session.Kind))
	}
	return provider.Ensure(ctx, session)
}

// splitAgentKey recognizes the optional flat family-handler spelling used by
// registry callers. Ordinary agent names (including custom names) are left
// untouched.
func splitAgentKey(value string) (string, string) {
	value = normalizeProviderKind(value)
	for _, handler := range []string{AgentHandlerTUI, AgentHandlerCLI, AgentHandlerACP} {
		for _, separator := range []string{"-", "/"} {
			suffix := separator + handler
			if strings.HasSuffix(value, suffix) && len(value) > len(suffix) {
				return strings.TrimSuffix(value, suffix), handler
			}
		}
	}
	return value, ""
}

func emitAgentEvents(sink AgentEventSink, events []api.AgentEvent, status api.AgentStatus) {
	switch value := sink.(type) {
	case nil:
		return
	case interface {
		OnEvents([]api.AgentEvent, api.AgentStatus)
	}:
		value.OnEvents(events, status)
	case interface {
		Events([]api.AgentEvent, api.AgentStatus)
	}:
		value.Events(events, status)
	case func([]api.AgentEvent, api.AgentStatus):
		value(events, status)
	}
}

func emitAgentStatus(sink AgentEventSink, status api.AgentStatus) {
	switch value := sink.(type) {
	case nil:
		return
	case interface{ OnStatus(api.AgentStatus) }:
		value.OnStatus(status)
	case interface{ Status(api.AgentStatus) }:
		value.Status(status)
	case func(api.AgentStatus):
		value(status)
	}
}

func emitAgentTurns(sink AgentEventSink, turns []api.AgentTurn, replay bool) {
	switch value := sink.(type) {
	case nil:
		return
	case interface{ OnTurns([]api.AgentTurn, bool) }:
		value.OnTurns(turns, replay)
	case interface{ Turns([]api.AgentTurn, bool) }:
		value.Turns(turns, replay)
	case func([]api.AgentTurn, bool):
		value(turns, replay)
	}
}

func (s *Service) agentProviderRegistry() *AgentProviderRegistry {
	if s == nil {
		return nil
	}
	if s.AgentProviders != nil {
		return s.AgentProviders
	}
	if s.ProviderRegistry != nil {
		return s.ProviderRegistry
	}
	return s.AgentRegistry
}

func (s *Service) agentSessionContext(state api.State, session api.Session) (AgentSessionContext, error) {
	workspacePath, err := sessionWorkingDirectory(state, session.WorkspaceID, session.TerminalGroupID)
	if err != nil {
		return AgentSessionContext{}, err
	}
	kind := normalizeProviderKind(session.Kind)
	if kind == "shell" || kind == "custom" {
		if binding, readErr := agent.ReadBinding(agent.BindPath(session.ID)); readErr == nil && binding != nil {
			kind = normalizeProviderKind(binding.Provider)
		}
	}
	if family, embeddedHandler := splitAgentKey(kind); embeddedHandler != "" {
		kind = family
		if strings.TrimSpace(session.AgentHandler) == "" {
			// Accept a flat Session kind such as codex-acp while keeping the
			// wire representation family-oriented when the roster is projected.
			session.AgentHandler = embeddedHandler
		}
	}
	handler := normalizeProviderKind(session.AgentHandler)
	if family, embeddedHandler := splitAgentKey(handler); family == kind && embeddedHandler != "" {
		handler = embeddedHandler
	}
	return AgentSessionContext{
		Session:        session,
		SessionID:      session.ID,
		Kind:           kind,
		Handler:        handler,
		Transport:      handler,
		WorkspacePath:  workspacePath,
		AgentSessionID: session.AgentSessionID,
		TranscriptPath: session.TranscriptPath,
		Runtime:        session.Runtime,
		RuntimeKind:    session.RuntimeKind,
		Binding:        agent.BindPath(session.ID),
	}, nil
}

func (s *Service) ensureAgentWithRegistry(ctx context.Context, session api.Session, state *api.State, registry *AgentProviderRegistry) (*agentSession, error) {
	if registry == nil {
		return nil, nil
	}
	contextValue, err := s.agentSessionContext(*state, session)
	if err != nil {
		s.stopAgent(session.ID)
		return nil, nil
	}
	if contextValue.Kind == "" {
		return s.ensureAgentPlaceholder(session.ID), nil
	}
	provider, ok := registry.ProviderFor(contextValue.Kind, contextValue.Handler)
	if !ok {
		// A shell/custom Session has no provider until its managed binding is
		// written. Dedicated unknown kinds are surfaced to callers so a typo
		// cannot silently look like a healthy agent.
		if session.Kind == "shell" || session.Kind == "custom" {
			return s.ensureAgentPlaceholder(session.ID), nil
		}
		return nil, fmt.Errorf("%w: %s", ErrAgentProviderNotFound, contextValue.Kind)
	}
	if contextValue.Handler == "" {
		switch selected := provider.(type) {
		case interface{ HandlerKind() string }:
			contextValue.Handler = normalizeProviderKind(selected.HandlerKind())
		case interface{ DefaultHandler() string }:
			contextValue.Handler = normalizeProviderKind(selected.DefaultHandler())
		}
		if contextValue.Handler == "" {
			_, embeddedHandler := splitAgentKey(provider.Kind())
			contextValue.Handler = embeddedHandler
		}
		contextValue.Transport = contextValue.Handler
	}

	s.lazyInit()
	s.agentsMu.Lock()
	entry := s.agents[session.ID]
	if entry == nil {
		entry = &agentSession{}
		s.agents[session.ID] = entry
	}
	s.agentsMu.Unlock()

	handle, ensureErr := provider.Ensure(ctx, contextValue)
	if ensureErr != nil {
		if errors.Is(ensureErr, ErrAgentNotReady) {
			return entry, nil
		}
		return entry, ensureErr
	}
	if handle == nil {
		return entry, fmt.Errorf("agent provider %q returned a nil handle", contextValue.Kind)
	}
	key := strings.TrimSpace(handle.BindingKey())
	if key == "" {
		return entry, errors.New("agent handle binding key is required")
	}

	// Detach the old handle before invoking Close. A callback emitted during
	// Close must fail the identity check below and cannot append stale events.
	s.agentsMu.Lock()
	entry = s.agents[session.ID]
	if entry == nil {
		entry = &agentSession{}
		s.agents[session.ID] = entry
	}
	entry.mu.Lock()
	oldHandle := entry.handle
	oldWatcher := entry.watcher
	oldTailer := entry.tailer
	oldKey := entry.bindingKey
	if oldHandle != nil && oldKey == key {
		entry.mu.Unlock()
		s.agentsMu.Unlock()
		if handle != oldHandle {
			_ = handle.Close()
		}
		return entry, nil
	}
	if oldHandle == nil && oldWatcher != nil && oldWatcher.Path() == contextValue.TranscriptPath && oldKey == key {
		entry.mu.Unlock()
		s.agentsMu.Unlock()
		_ = handle.Close()
		return entry, nil
	}
	if oldHandle != nil || oldWatcher != nil || oldTailer != nil {
		entry.handle = nil
		entry.watcher = nil
		entry.tailer = nil
		entry.bindingKey = ""
		entry.providerKind = ""
		entry.handlerKind = ""
		entry.capabilities = nil
		resetAgentProjectionLocked(entry)
	}
	entry.handle = handle
	entry.bindingKey = key
	entry.providerKind = contextValue.Kind
	entry.handlerKind = contextValue.Handler
	capabilities := handle.Capabilities().Clone()
	if advertiser, advertised := provider.(AgentProviderCapabilities); advertised {
		if declared := advertiser.Capabilities(); declared != nil {
			capabilities = IntersectCapabilitySets(declared, capabilities)
		}
	}
	entry.capabilities = capabilities
	entry.mu.Unlock()
	s.agentsMu.Unlock()

	if oldHandle != nil {
		_ = oldHandle.Close()
	} else {
		if oldWatcher != nil {
			oldWatcher.Close()
		}
		if oldTailer != nil {
			oldTailer.Close()
		}
	}
	if oldHandle != nil || oldWatcher != nil || oldTailer != nil {
		s.bumpAgentEpoch()
		s.bumpAgentRosterRevision()
		s.broadcastAgentReset(session.ID)
	}

	sink := serviceAgentEventSink{service: s, sessionID: session.ID, handle: handle}
	if startErr := handle.Start(ctx, sink); startErr != nil {
		// A failed start is not a binding change. Retain the placeholder so the
		// next reconcile can ask the provider to construct a fresh handle.
		s.agentsMu.Lock()
		if current := s.agents[session.ID]; current != nil {
			current.mu.Lock()
			if current.handle == handle {
				current.handle = nil
				current.bindingKey = ""
				current.providerKind = ""
				current.handlerKind = ""
				current.capabilities = nil
				s.bumpAgentRosterRevision()
			}
			current.mu.Unlock()
		}
		s.agentsMu.Unlock()
		_ = handle.Close()
		return entry, startErr
	}
	agentSessionID, transcriptPath := contextValue.AgentSessionID, contextValue.TranscriptPath
	if metadata, ok := handle.(interface{ BindingMetadata() (string, string) }); ok {
		agentSessionID, transcriptPath = metadata.BindingMetadata()
	}
	if agentSessionID != "" || transcriptPath != "" {
		s.persistAgentMetaWithState(state, session.ID, agentSessionID, transcriptPath)
	}
	s.bumpAgentRosterRevision()
	return entry, nil
}

func (s *Service) ensureAgentPlaceholder(sessionID string) *agentSession {
	s.lazyInit()
	s.agentsMu.Lock()
	defer s.agentsMu.Unlock()
	entry := s.agents[sessionID]
	if entry == nil {
		entry = &agentSession{}
		s.agents[sessionID] = entry
	}
	return entry
}

func (s *Service) agentCapabilitiesForSession(sessionID string, session api.Session) []string {
	result := CapabilitySet{}
	hasHandle := false
	s.lazyInit()
	s.agentsMu.Lock()
	entry := s.agents[sessionID]
	if entry != nil {
		entry.mu.Lock()
		if entry.handle != nil {
			hasHandle = true
			result = entry.capabilities.Clone()
		} else if entry.watcher != nil {
			// The legacy watcher is itself the transcript transport. Keep its
			// provider-neutral timeline capability while the old action bridge
			// remains available for PTY sends.
			result = NewCapabilitySet(CapabilityTimeline)
		}
		entry.mu.Unlock()
	}
	s.agentsMu.Unlock()
	if len(result) > 0 && !hasHandle {
		if nonNilInterface(s.AgentController) {
			result[CapabilityInteractions] = struct{}{}
			result[CapabilityInterrupt] = struct{}{}
		}
		if s.hasRuntimeAdapter() || nonNilInterface(s.AgentController) {
			result[CapabilityAttachments] = struct{}{}
		}
	}
	// A dedicated known agent is still represented before its transcript
	// appears, but optional controls must remain hidden until a handle/watcher
	// is ready. Plain shells without a binding are never agent-backed.
	if result == nil {
		result = CapabilitySet{}
	}
	return result.Strings()
}

func (s *Service) agentHandlerForSession(sessionID string) string {
	if s == nil {
		return ""
	}
	s.lazyInit()
	s.agentsMu.Lock()
	entry := s.agents[sessionID]
	if entry == nil {
		s.agentsMu.Unlock()
		return ""
	}
	entry.mu.Lock()
	handler := entry.handlerKind
	entry.mu.Unlock()
	s.agentsMu.Unlock()
	return handler
}

func (s *Service) bumpAgentRosterRevision() {
	if s == nil {
		return
	}
	base := uint64(1)
	if s.Store != nil {
		_, revision := s.Store.SnapshotVersion()
		base = revision + 1
	}
	for {
		current := s.agentRosterRevision.Load()
		next := current + 1
		if next <= base {
			next = base + 1
		}
		if s.agentRosterRevision.CompareAndSwap(current, next) {
			return
		}
	}
}

// sessionSupportsCapability is the Host-side guard used by every mutating
// Agent action. A nil persisted field denotes a legacy Session record; in
// that case the pre-provider PTY/controller behavior remains available. A
// non-nil empty slice is explicit and must be treated as unsupported.
func (s *Service) sessionSupportsCapability(sessionID string, capability Capability) bool {
	if s == nil {
		return false
	}
	session, found := s.Session(sessionID)
	if !found {
		return false
	}
	if session.AgentCapabilities != nil {
		return api.SupportsCapability(session.AgentCapabilities, string(capability))
	}
	return api.SupportsCapability(s.agentCapabilitiesForSession(sessionID, session), string(capability)) ||
		s.agentProviderRegistry() == nil
}

func (s *Service) currentAgentHandle(sessionID string) AgentHandle {
	if s == nil {
		return nil
	}
	s.lazyInit()
	s.agentsMu.Lock()
	entry := s.agents[sessionID]
	if entry == nil {
		s.agentsMu.Unlock()
		return nil
	}
	entry.mu.Lock()
	handle := entry.handle
	entry.mu.Unlock()
	s.agentsMu.Unlock()
	return handle
}

func resetAgentProjectionLocked(entry *agentSession) {
	entry.events = nil
	entry.status = api.AgentStatus{}
	entry.turn = api.AgentTurn{}
	entry.titleUser = ""
	entry.titleUserProvider = ""
	entry.titleUserID = ""
	entry.titleAssistant = ""
	entry.titleAssistantProvider = ""
	entry.titleAssistantID = ""
	entry.titleAssistantComplete = false
	entry.titleGenerationStarted = false
	entry.hookStateModTime = time.Time{}
}

type serviceAgentEventSink struct {
	service   *Service
	sessionID string
	handle    AgentHandle
}

func (sink serviceAgentEventSink) current() bool {
	if sink.service == nil || sink.handle == nil {
		return false
	}
	sink.service.agentsMu.Lock()
	entry := sink.service.agents[sink.sessionID]
	if entry == nil {
		sink.service.agentsMu.Unlock()
		return false
	}
	entry.mu.Lock()
	current := entry.handle == sink.handle
	entry.mu.Unlock()
	sink.service.agentsMu.Unlock()
	return current
}

func (sink serviceAgentEventSink) OnEvents(events []api.AgentEvent, status api.AgentStatus) {
	if sink.service != nil {
		sink.service.recordAgentEventsForHandle(sink.sessionID, sink.handle, events, status)
	}
}

func (sink serviceAgentEventSink) OnStatus(status api.AgentStatus) {
	if sink.service != nil {
		sink.service.recordAgentStatusForHandle(sink.sessionID, sink.handle, status)
	}
}

func (sink serviceAgentEventSink) OnTurns(turns []api.AgentTurn, replay bool) {
	if sink.service != nil {
		sink.service.recordAgentTurnsForHandle(sink.sessionID, sink.handle, turns, !replay || sink.service.hasAgentPeers(sink.sessionID))
	}
}

// noopAgentHandle is useful to provider adapters that have a binding but no
// optional transport yet. It still satisfies the lifecycle contract and
// advertises only the capabilities the adapter can execute.
type noopAgentHandle struct {
	key          string
	capabilities CapabilitySet
	closeOnce    sync.Once
}

func (handle *noopAgentHandle) Start(context.Context, AgentEventSink) error { return nil }
func (handle *noopAgentHandle) Capabilities() CapabilitySet                 { return handle.capabilities.Clone() }
func (handle *noopAgentHandle) SendMessage(context.Context, AgentMessage) error {
	return errors.New("agent message transport is unavailable")
}
func (handle *noopAgentHandle) Interrupt(context.Context, AgentInterruptRequest) error {
	return errors.New("agent interrupt transport is unavailable")
}
func (handle *noopAgentHandle) RespondInteraction(context.Context, AgentInteractionResponse) error {
	return errors.New("agent interaction transport is unavailable")
}
func (handle *noopAgentHandle) BindingKey() string { return handle.key }
func (handle *noopAgentHandle) Close() error {
	handle.closeOnce.Do(func() {})
	return nil
}

// Ensure this file keeps the provider aliases honest when APIs are changed.
var _ AgentHandle = (*noopAgentHandle)(nil)

// TUIAgentProvider adapts the existing transcript watcher and PTY runtime to
// the provider lifecycle boundary. It intentionally contains no provider
// parser logic: agent.Start still selects the established Codex, Claude,
// OpenCode, Pi, and Qoder normalizers.
type TUIAgentProvider struct {
	service *Service
	kind    string
}

func NewTUIAgentProvider(service *Service, kind string) *TUIAgentProvider {
	return &TUIAgentProvider{service: service, kind: normalizeProviderKind(kind)}
}

// NewTUIAgentProviderRegistry registers every provider currently understood by
// the Host. A future ACP provider can be registered beside these adapters
// without changing Service reconciliation.
func NewTUIAgentProviderRegistry(service *Service) *AgentProviderRegistry {
	registry := NewAgentProviderRegistry()
	for _, kind := range []string{"codex", "claude", "opencode", "pi", "qoder"} {
		tuiProvider := NewTUIAgentProvider(service, kind)
		acpProvider := NewACPAgentProvider(kind, service)
		_ = registry.Register(NewAgentProviderWithHandlers(kind, tuiProvider, acpProvider))
		_ = registry.RegisterHandler(tuiProvider, tuiProvider.HandlerKind())
		_ = registry.RegisterHandler(acpProvider, acpProvider.HandlerKind())
	}
	return registry
}

func NewDefaultAgentProviderRegistry(service *Service) *AgentProviderRegistry {
	return NewTUIAgentProviderRegistry(service)
}

func (provider *TUIAgentProvider) Kind() string {
	if provider == nil {
		return ""
	}
	return provider.kind
}

func (provider *TUIAgentProvider) HandlerKind() string { return AgentHandlerTUI }

// Capabilities describes what the TUI family can execute on this Host. The
// concrete handle repeats this calculation so a future per-session transport
// can narrow it further without changing the Service contract.
func (provider *TUIAgentProvider) Capabilities() CapabilitySet {
	if provider == nil || provider.service == nil {
		return NewCapabilitySet()
	}
	result := NewCapabilitySet(CapabilityTimeline)
	if provider.service.hasRuntimeAdapter() {
		result[CapabilityAttachments] = struct{}{}
	}
	if nonNilInterface(provider.service.AgentController) {
		result[CapabilityInteractions] = struct{}{}
		result[CapabilityInterrupt] = struct{}{}
	}
	return result
}

func (provider *TUIAgentProvider) Ensure(ctx context.Context, value AgentSessionContext) (AgentHandle, error) {
	if provider == nil || provider.service == nil {
		return nil, ErrAgentNotReady
	}
	kind := normalizeProviderKind(value.Kind)
	if family, _ := splitAgentKey(kind); family != kind {
		kind, _ = splitAgentKey(kind)
	}
	if kind == "" {
		kind = provider.kind
	}
	if kind != provider.kind {
		return nil, fmt.Errorf("provider kind mismatch: %s", kind)
	}
	service := provider.service
	if kind == "opencode" {
		return service.ensureTUIOpenCodeHandle(ctx, value)
	}

	agentSessionID := strings.TrimSpace(value.AgentSessionID)
	transcriptPath := strings.TrimSpace(value.TranscriptPath)
	if binding, err := agent.ReadBinding(agent.BindPath(value.SessionID)); err == nil && binding != nil && normalizeProviderKind(binding.Provider) == kind {
		if binding.SessionID != "" {
			agentSessionID = binding.SessionID
		}
		if binding.TranscriptPath != "" && regularFileExists(binding.TranscriptPath) {
			transcriptPath = binding.TranscriptPath
		}
	}
	if transcriptPath != "" && !regularFileExists(transcriptPath) {
		transcriptPath = ""
	}
	if transcriptPath == "" && kind == "claude" && agentSessionID != "" {
		path := agent.ClaudeTranscriptPath(agent.ClaudeProjectsRoot(), value.WorkspacePath, agentSessionID)
		if regularFileExists(path) {
			transcriptPath = path
		}
	}
	if transcriptPath == "" && kind == "pi" && agentSessionID != "" {
		transcriptPath = agent.FindPiTranscript(agentSessionID)
	}
	if transcriptPath == "" && kind == "qoder" && agentSessionID != "" {
		transcriptPath = agent.FindQoderTranscript(agentSessionID, value.WorkspacePath)
	}
	if transcriptPath == "" && nonNilInterface(service.AgentFinder) {
		found, err := service.AgentFinder.Find(ctx, kind, value.WorkspacePath, value.Session.CreatedAt)
		if err != nil {
			return nil, err
		}
		if found != "" && regularFileExists(found) {
			transcriptPath = found
		}
	}
	if transcriptPath == "" {
		return nil, ErrAgentNotReady
	}
	if service.Store != nil && service.transcriptTakenByOtherInState(service.Store.Snapshot(), transcriptPath, value.SessionID) {
		return nil, ErrAgentNotReady
	}
	if agentSessionID == "" {
		agentSessionID = value.SessionID
	}
	return &tuiAgentHandle{
		service:        service,
		sessionID:      value.SessionID,
		provider:       kind,
		agentSessionID: agentSessionID,
		transcriptPath: transcriptPath,
		runtimeName:    value.Runtime,
		runtimeKind:    value.RuntimeKind,
		key:            tuiBindingKey(kind, agentSessionID, transcriptPath),
	}, nil
}

func (service *Service) ensureTUIOpenCodeHandle(ctx context.Context, value AgentSessionContext) (AgentHandle, error) {
	if service == nil {
		return nil, ErrAgentNotReady
	}
	finder, ok := service.AgentFinder.(agent.BindingFinder)
	if !ok || !nonNilInterface(finder) {
		return nil, ErrAgentNotReady
	}
	service.openCodeBindingMu.Lock()
	defer service.openCodeBindingMu.Unlock()
	var (
		binding *agent.OpenCodeBinding
		err     error
	)
	if value.AgentSessionID != "" {
		binding, err = finder.FindBindingBySessionID(ctx, value.SessionID, value.WorkspacePath, value.AgentSessionID)
	} else {
		binding, err = service.findOpenCodeBinding(ctx, finder, value.SessionID, value.WorkspacePath, value.Session.CreatedAt)
	}
	if err != nil {
		return nil, err
	}
	if binding == nil || !binding.Valid() {
		return nil, ErrAgentNotReady
	}
	if binding.CachePath == "" {
		binding.CachePath = agent.OpenCodeCachePath(value.SessionID, binding.SessionID)
	}
	if service.Store != nil && service.openCodeBindingTakenByOtherInState(service.Store.Snapshot(), binding.SessionID, value.SessionID) {
		return nil, ErrAgentNotReady
	}
	return &tuiAgentHandle{
		service:        service,
		sessionID:      value.SessionID,
		provider:       "opencode",
		agentSessionID: binding.SessionID,
		transcriptPath: binding.CachePath,
		runtimeName:    value.Runtime,
		runtimeKind:    value.RuntimeKind,
		opencode:       binding,
		key:            tuiBindingKey("opencode", binding.SessionID, binding.CachePath),
	}, nil
}

func tuiBindingKey(provider, sessionID, transcriptPath string) string {
	return strings.Join([]string{normalizeProviderKind(provider), strings.TrimSpace(sessionID), filepath.Clean(strings.TrimSpace(transcriptPath))}, "|")
}

type tuiAgentHandle struct {
	service        *Service
	sessionID      string
	provider       string
	agentSessionID string
	transcriptPath string
	runtimeName    string
	runtimeKind    string
	opencode       *agent.OpenCodeBinding

	key       string
	startOnce sync.Once
	startErr  error
	closeOnce sync.Once
	closeErr  error
	stateMu   sync.Mutex
	watcher   *agent.Watcher
	tailer    *agent.OpenCodeTailer
	closed    bool
}

func (handle *tuiAgentHandle) Start(ctx context.Context, sink AgentEventSink) error {
	if handle == nil {
		return ErrAgentNotReady
	}
	handle.startOnce.Do(func() {
		handle.stateMu.Lock()
		defer handle.stateMu.Unlock()
		closed := handle.closed
		if closed {
			handle.startErr = errors.New("agent handle is closed")
			return
		}
		if handle.transcriptPath == "" {
			handle.startErr = ErrAgentNotReady
			return
		}
		if handle.provider == "opencode" {
			if handle.opencode == nil {
				handle.startErr = ErrAgentNotReady
				return
			}
			tailer, err := agent.StartOpenCodeSessionTailer(*handle.opencode)
			handle.tailer, handle.startErr = tailer, err
			if handle.startErr != nil {
				return
			}
		}
		watcher := agent.Start(
			handle.sessionID,
			handle.provider,
			handle.transcriptPath,
			func(events []api.AgentEvent, status api.AgentStatus) { emitAgentEvents(sink, events, status) },
			func(status api.AgentStatus) { emitAgentStatus(sink, status) },
			func(turns []api.AgentTurn, replay bool) { emitAgentTurns(sink, turns, replay) },
		)
		handle.watcher = watcher
	})
	handle.stateMu.Lock()
	err := handle.startErr
	handle.stateMu.Unlock()
	return err
}

func (handle *tuiAgentHandle) Capabilities() CapabilitySet {
	if handle == nil {
		return NewCapabilitySet()
	}
	result := NewCapabilitySet(CapabilityTimeline)
	if handle.service != nil {
		if handle.service.hasRuntimeAdapter() {
			result[CapabilityAttachments] = struct{}{}
		}
		if nonNilInterface(handle.service.AgentController) {
			result[CapabilityInteractions] = struct{}{}
			result[CapabilityInterrupt] = struct{}{}
		}
	}
	return result
}

func (handle *tuiAgentHandle) SendMessage(ctx context.Context, message AgentMessage) error {
	if handle == nil || handle.service == nil {
		return errors.New("agent message transport is unavailable")
	}
	status := handle.service.agentStatus(handle.sessionID)
	if status.Activity == api.AgentActivityBlocked || status.Attention != nil {
		return api.ErrAgentBlocked
	}
	if status.Activity == api.AgentActivityWorking {
		return api.ErrAgentBusy
	}
	if controller := handle.service.AgentController; nonNilInterface(controller) {
		return controller.SendMessage(ctx, message)
	}
	runtime := handle.service.runtimeForKind(handle.runtimeKind)
	if runtime == nil {
		runtime = handle.service.runtimeForKind(handle.service.runtimeKindFor(api.Session{Runtime: handle.runtimeName}))
	}
	if runtime == nil {
		return errors.New("agent message transport is unavailable")
	}
	unlock := handle.service.lockAgentSessionAction(handle.sessionID)
	defer unlock()
	text := message.Text
	if len(message.Attachments) > 0 {
		var err error
		text, err = handle.service.agentMessageTextWithAttachments(message)
		if err != nil {
			return err
		}
	}
	return sendAgentMessageInput(ctx, runtime, handle.runtimeName, text)
}

func (handle *tuiAgentHandle) Interrupt(ctx context.Context, request AgentInterruptRequest) error {
	if handle == nil || handle.service == nil {
		return errors.New("agent interrupt transport is unavailable")
	}
	if controller := handle.service.AgentController; nonNilInterface(controller) {
		if request.Replacement != nil {
			atomicController, ok := controller.(AgentViewAtomicController)
			if !ok || !nonNilInterface(atomicController) {
				return errors.New("agent send_now transport is unavailable")
			}
			return atomicController.InterruptAndSend(ctx, request)
		}
		return controller.InterruptTurn(ctx, request)
	}
	runtime := handle.service.runtimeForKind(handle.runtimeKind)
	if runtime == nil {
		runtime = handle.service.runtimeForKind(handle.service.runtimeKindFor(api.Session{Runtime: handle.runtimeName}))
	}
	if runtime == nil {
		return errors.New("agent interrupt transport is unavailable")
	}
	unlock := handle.service.lockAgentSessionAction(handle.sessionID)
	defer unlock()
	if request.Replacement != nil && len(request.Replacement.Attachments) > 0 {
		text, err := handle.service.agentMessageTextWithAttachments(*request.Replacement)
		if err != nil {
			return err
		}
		return interruptAgentTurnInputText(ctx, runtime, handle.runtimeName, text)
	}
	return interruptAgentTurnInput(ctx, runtime, handle.runtimeName, request)
}

func (handle *tuiAgentHandle) RespondInteraction(ctx context.Context, response AgentInteractionResponse) error {
	if handle == nil || handle.service == nil || !nonNilInterface(handle.service.AgentController) {
		return errors.New("agent interaction transport is unavailable")
	}
	return handle.service.AgentController.RespondInteraction(ctx, response)
}

func (handle *tuiAgentHandle) BindingKey() string {
	if handle == nil {
		return ""
	}
	return handle.key
}

func (handle *tuiAgentHandle) BindingMetadata() (string, string) {
	if handle == nil {
		return "", ""
	}
	return handle.agentSessionID, handle.transcriptPath
}

func (handle *tuiAgentHandle) Close() error {
	if handle == nil {
		return nil
	}
	handle.closeOnce.Do(func() {
		handle.stateMu.Lock()
		handle.closed = true
		watcher, tailer := handle.watcher, handle.tailer
		handle.watcher, handle.tailer = nil, nil
		handle.stateMu.Unlock()
		if watcher != nil {
			watcher.Close()
		}
		if tailer != nil {
			tailer.Close()
		}
	})
	return handle.closeErr
}

var _ AgentProvider = (*TUIAgentProvider)(nil)
var _ AgentHandle = (*tuiAgentHandle)(nil)

// ACPAgentProvider is a stub for the standardized bidirectional Agent Client Protocol (ACP).
// It implements AgentProvider and AgentProviderCapabilities for the "acp" handler kind.
type ACPAgentProvider struct {
	kind    string
	service *Service
}

func NewACPAgentProvider(kind string, service *Service) *ACPAgentProvider {
	return &ACPAgentProvider{
		kind:    normalizeProviderKind(kind),
		service: service,
	}
}

func (provider *ACPAgentProvider) Kind() string {
	if provider == nil {
		return ""
	}
	return provider.kind
}

func (provider *ACPAgentProvider) HandlerKind() string { return AgentHandlerACP }

// Capabilities advertises Track 2 native bidirectional capabilities.
func (provider *ACPAgentProvider) Capabilities() CapabilitySet {
	return NewCapabilitySet(
		CapabilityTimeline,
		CapabilityInteractions,
		CapabilityInterrupt,
		CapabilityAttachments,
	)
}

func (provider *ACPAgentProvider) Ensure(ctx context.Context, value AgentSessionContext) (AgentHandle, error) {
	if provider == nil || provider.service == nil {
		return nil, ErrAgentNotReady
	}
	return &acpAgentHandle{
		provider: provider,
		value:    value,
	}, nil
}

type acpAgentHandle struct {
	provider *ACPAgentProvider
	value    AgentSessionContext
}

func (handle *acpAgentHandle) Start(ctx context.Context, sink AgentEventSink) error {
	// ACP wire transport connection is stubbed and will be implemented when the protocol adapter is ready.
	return nil
}

func (handle *acpAgentHandle) Capabilities() CapabilitySet {
	if handle == nil || handle.provider == nil {
		return NewCapabilitySet()
	}
	return handle.provider.Capabilities()
}

func (handle *acpAgentHandle) SendMessage(ctx context.Context, message AgentMessage) error {
	return errors.New("acp message transport is not implemented yet")
}

func (handle *acpAgentHandle) Interrupt(ctx context.Context, request AgentInterruptRequest) error {
	return errors.New("acp interrupt transport is not implemented yet")
}

func (handle *acpAgentHandle) RespondInteraction(ctx context.Context, response AgentInteractionResponse) error {
	return errors.New("acp interaction transport is not implemented yet")
}

func (handle *acpAgentHandle) BindingKey() string {
	if handle == nil {
		return ""
	}
	return handle.value.SessionID
}

func (handle *acpAgentHandle) Close() error {
	return nil
}

var _ AgentProvider = (*ACPAgentProvider)(nil)
var _ AgentProviderCapabilities = (*ACPAgentProvider)(nil)
var _ AgentHandle = (*acpAgentHandle)(nil)

